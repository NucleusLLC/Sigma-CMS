#!/usr/bin/env python3
"""
SIGMA-CMS · Blink snapshot helper
=================================

Blink cameras are cloud-only. They serve no local stream — no RTSP, no ONVIF,
nothing a browser or a go2rtc bridge can reach. The ONLY way to see them outside
Amazon's own app is Amazon's cloud, through the unofficial `blinkpy` library.

This helper is the small always-on service SIGMA needs because a static browser
page cannot hold an Amazon session or run Python. It does three things and no
more:

  1. Holds a Blink session, loaded from a credentials file you created ONCE with
     login.py (which is where the Amazon e-mail, password and 2FA are entered —
     they are NEVER entered here, and never reach SIGMA).
  2. Serves a JSON list of your cameras at   GET /k/<key>/api/cameras
  3. Serves the latest still for one camera at GET /k/<key>/api/snapshot?cam=<name>

Every route sits behind a secret path segment (<key>, kept in helper-key.txt).
The tunnel address is public — anyone who has the bare hostname must NOT get the
stills. SIGMA is given the whole address including /k/<key>, so its existing
"base + /api/..." URLs work unchanged.

HONEST CAPTURE TIME (v2.518 §CAM-BLINK-TRUTH). The still served is whatever Blink
last uploaded, which can be minutes or days old if a snap was refused, the camera
is asleep, or Amazon throttled us. So every still carries the time it was really
taken, in X-Blink-Captured (epoch seconds):
  - "blink"    — read from the ts= Blink puts in the thumbnail address;
  - "observed" — the image changed while this helper was watching, so it was
                 taken no later than the moment we first saw it;
  - "unknown"  — empty header. SIGMA says so rather than invent a time.
The old helper stamped the time it SERVED the file, so a days-old picture was
labelled "CAPTURED 12s ago".

BATTERY. A Blink snap wakes a battery camera. A new picture is requested at most
once per BLINK_SNAP_EVERY seconds per camera (default 60), and only while SIGMA
is actually asking — when nobody has the tab open for BLINK_IDLE seconds, the
helper makes no Amazon calls at all. SIGMA may poll faster; it just gets the
same still back.

TOKENS. Blink rotates the refresh token on use. The helper writes the new tokens
back to creds.json whenever they change, so a restart does not need a fresh 2FA
sign-in. The Amazon password is NOT written back — only tokens.

CORS: every response carries Access-Control-Allow-Origin, and app errors are
returned as 200-with-{error}: a tunnel/CDN in front replaces any 5xx with its own
page that has no CORS header, so the browser could not read the message.

Run:   python blink_helper.py           (after login.py has written creds.json)
"""

import asyncio
import hashlib
import json
import os
import re
import secrets
import time

from aiohttp import web, ClientSession
from blinkpy import api
from blinkpy.blinkpy import Blink
from blinkpy.auth import Auth
from blinkpy.helpers.util import json_load

CREDS = os.environ.get("BLINK_CREDS", "creds.json")
KEYFILE = os.environ.get("BLINK_KEYFILE", "helper-key.txt")
HOST = os.environ.get("BLINK_HELPER_HOST", "127.0.0.1")
PORT = int(os.environ.get("BLINK_HELPER_PORT", "8765"))
SIGMA_ORIGIN = os.environ.get("SIGMA_ORIGIN", "*")

# Seconds between NEW pictures per camera. Floor 30: below that Blink refuses the
# snap as busy and the battery pays for nothing.
SNAP_EVERY = max(30.0, float(os.environ.get("BLINK_SNAP_EVERY", "60")))
# Seconds between metadata refreshes while someone is watching.
POLL_EVERY = max(10.0, float(os.environ.get("BLINK_POLL_EVERY", "15")))
# No request for this long = nobody watching = no Amazon calls.
IDLE_AFTER = float(os.environ.get("BLINK_IDLE", "90"))

_blink = None
_blink_lock = asyncio.Lock()
_refresh_lock = asyncio.Lock()
_last_view = 0.0
_trigger_at = {}   # camera name -> epoch of our last snap request
_seen = {}         # camera name -> {"hash", "captured", "source"}
_saved_tokens = None

# --- Ring (optional) --------------------------------------------------------
# Ring battery cameras, like Blink, serve no local stream. Ring keeps a periodic
# snapshot per camera (Ring app > camera > Snapshot Capture) with its own
# timestamp. They join the same camera list as "Ring · <name>", so SIGMA's
# snapshot tiles and their honest capture time work with no page change.
# The helper has its OWN Ring sign-in (ring-session/ring.json, written by
# 3-RING-LOGIN.cmd): Ring rotates refresh tokens, and sharing one with the NAS
# archiver would sign each other out.
RING_PREFIX = "Ring · "
RING_TOKEN = os.path.join(os.environ.get("RING_SESSION_DIR", "ring-session"), "ring.json")
RING_USER_AGENT = "SIGMA-cam-helper/1.0"
_ring = None
_ring_auth = None
_ring_lock = asyncio.Lock()
_ring_devices = {}     # display name -> device
_ring_devices_at = 0.0
_ring_cache = {}       # display name -> {"at", "jpeg", "captured"}


# ---------------------------------------------------------------------------
# key
# ---------------------------------------------------------------------------

def load_key() -> str:
    env = os.environ.get("BLINK_HELPER_KEY", "").strip()
    if env:
        return env
    if os.path.exists(KEYFILE):
        with open(KEYFILE, "r", encoding="utf-8") as f:
            k = f.read().strip()
        if k:
            return k
    k = secrets.token_urlsafe(18)
    with open(KEYFILE, "w", encoding="utf-8") as f:
        f.write(k + "\n")
    return k


# ---------------------------------------------------------------------------
# capture time
# ---------------------------------------------------------------------------

_TS_RE = re.compile(r"[?&]ts=(\d{9,13})(?:&|$)")


def thumb_ts(url, now=None):
    """Capture epoch from a Blink thumbnail address, or None if it has none we trust."""
    if not url:
        return None
    m = _TS_RE.search(str(url))
    if not m:
        return None
    ts = int(m.group(1))
    if ts > 10**12:          # milliseconds
        ts = ts / 1000.0
    now = time.time() if now is None else now
    # Not in the future, not older than ~13 months: anything else is not a time.
    if ts > now + 300 or ts < now - 400 * 86400:
        return None
    return float(ts)


def note_image(name, jpeg, thumb_url, now=None):
    """Record a still for a camera; return (captured_epoch_or_None, source).

    A capture time is only ever claimed from evidence: Blink's own ts=, or having
    watched the bytes change. The first image seen at startup with no ts= is
    "unknown" — it may be days old.
    """
    now = time.time() if now is None else now
    if not jpeg:
        prev = _seen.get(name)
        return (prev["captured"], prev["source"]) if prev else (None, "unknown")
    h = hashlib.sha1(jpeg).hexdigest()
    prev = _seen.get(name)
    if prev and prev["hash"] == h:
        return prev["captured"], prev["source"]
    ts = thumb_ts(thumb_url, now)
    if ts is not None:
        rec = {"hash": h, "captured": ts, "source": "blink"}
    elif prev is not None:
        rec = {"hash": h, "captured": now, "source": "observed"}
    else:
        rec = {"hash": h, "captured": None, "source": "unknown"}
    _seen[name] = rec
    return rec["captured"], rec["source"]


def _cam_jpeg(cam):
    data = getattr(cam, "_cached_image", None)
    return bytes(data) if isinstance(data, (bytes, bytearray)) else b""


def _note_all(blink):
    for name, cam in blink.cameras.items():
        note_image(name, _cam_jpeg(cam), getattr(cam, "thumbnail", None))


# ---------------------------------------------------------------------------
# session
# ---------------------------------------------------------------------------

def _token_view(auth):
    return (auth.token, auth.refresh_token)


def save_tokens(blink):
    """Write the current tokens back to creds.json — never the password."""
    global _saved_tokens
    view = _token_view(blink.auth)
    if view == _saved_tokens or not blink.auth.refresh_token:
        return
    data = dict(blink.auth.login_attributes)
    data.pop("password", None)
    tmp = CREDS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, CREDS)
    _saved_tokens = view


async def _ensure_blink() -> Blink:
    global _blink
    if _blink is not None:
        return _blink
    async with _blink_lock:
        if _blink is not None:
            return _blink
        if not os.path.exists(CREDS):
            raise RuntimeError(
                "no credentials file (%s). Run login.py once to sign in to Blink." % CREDS
            )
        session = ClientSession()
        blink = Blink(session=session)
        blink.auth = Auth(await json_load(CREDS), no_prompt=True, session=session)
        # blinkpy calls this after every token refresh.
        blink.auth.callback = lambda: save_tokens(blink)
        ok = await blink.start()
        if ok is False:
            await session.close()
            raise RuntimeError(
                "Blink refused the saved session. Run 1-LOGIN.cmd again to sign in."
            )
        # start() refreshes the token, which rotates it. Save before anything else,
        # or the next restart presents a token Blink has already retired.
        save_tokens(blink)
        await blink.refresh()
        _note_all(blink)
        _blink = blink
        return blink


async def _refresh_now(blink):
    """One metadata refresh that downloads only thumbnails that changed."""
    async with _refresh_lock:
        blink.last_refresh = 0   # pass blinkpy's throttle without force_cache downloads
        await blink.refresh()
        _note_all(blink)


async def _trigger_snap(blink, cam):
    """Ask the camera for a new picture, then look for it as it uploads."""
    try:
        await api.request_new_image(
            blink, cam.network_id, cam.camera_id, camera_type=getattr(cam, "camera_type", "")
        )
    except Exception:
        return   # refused/busy: the tile keeps the last still and its real age
    for wait in (8, 12, 20):
        await asyncio.sleep(wait)
        try:
            await _refresh_now(blink)
        except Exception:
            return


async def _poller(app):
    while True:
        await asyncio.sleep(POLL_EVERY)
        if _blink is None or time.time() - _last_view > IDLE_AFTER:
            continue
        try:
            await _refresh_now(_blink)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Ring
# ---------------------------------------------------------------------------

def ring_display_name(device_name):
    return RING_PREFIX + str(device_name or "camera").strip()


def _ring_save_token(token, hardware_id):
    data = {"token": token, "hardware_id": hardware_id}
    tmp = RING_TOKEN + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, RING_TOKEN)


async def _ensure_ring():
    """The Ring session, or None when Ring was never signed in on this PC."""
    global _ring, _ring_auth, _ring_devices, _ring_devices_at
    if not os.path.exists(RING_TOKEN):
        return None
    async with _ring_lock:
        if _ring is None:
            from ring_doorbell import Auth as RingAuth, Ring
            with open(RING_TOKEN, "r", encoding="utf-8") as f:
                saved = json.load(f)
            hw = saved.get("hardware_id")
            auth = RingAuth(RING_USER_AGENT, saved.get("token"),
                            lambda tok: _ring_save_token(tok, hw), hardware_id=hw)
            ring = Ring(auth)
            await ring.async_update_data()
            _ring, _ring_auth = ring, auth
            _ring_devices_at = 0.0
        if time.time() - _ring_devices_at > 600:
            await _ring.async_update_devices()
            _ring_devices = {ring_display_name(d.name): d for d in _ring.video_devices()}
            _ring_devices_at = time.time()
    return _ring


def ring_ts_seconds(value, now=None):
    """Ring snapshot timestamps are epoch milliseconds; reject anything implausible."""
    try:
        ts = float(value)
    except (TypeError, ValueError):
        return None
    if ts > 10**12:
        ts = ts / 1000.0
    now = time.time() if now is None else now
    if ts <= 0 or ts > now + 300 or ts < now - 400 * 86400:
        return None
    return ts


async def ring_snapshot(name, now=None):
    """(jpeg, captured_epoch_or_None) for a Ring camera, cached for SNAP_EVERY."""
    from ring_doorbell.const import SNAPSHOT_ENDPOINT, SNAPSHOT_TIMESTAMP_ENDPOINT
    now = time.time() if now is None else now
    hit = _ring_cache.get(name)
    if hit and now - hit["at"] < SNAP_EVERY and hit["jpeg"]:
        return hit["jpeg"], hit["captured"]
    dev = _ring_devices.get(name)
    if dev is None:
        raise KeyError(name)
    dev_id = dev._attrs.get("id")
    captured = None
    try:
        resp = await _ring.async_query(SNAPSHOT_TIMESTAMP_ENDPOINT, method="POST",
                                       json={"doorbot_ids": [dev_id]})
        stamps = (resp.json() or {}).get("timestamps") or []
        if stamps:
            captured = ring_ts_seconds(stamps[0].get("timestamp"), now)
    except Exception:
        captured = None
    resp = await _ring.async_query(SNAPSHOT_ENDPOINT.format(dev_id))
    jpeg = resp.content if getattr(resp, "status_code", 200) == 200 else b""
    if jpeg:
        _ring_cache[name] = {"at": now, "jpeg": jpeg, "captured": captured}
    elif hit:
        return hit["jpeg"], hit["captured"]
    return jpeg, captured


# ---------------------------------------------------------------------------
# http
# ---------------------------------------------------------------------------

def _cors(resp: web.StreamResponse) -> web.StreamResponse:
    resp.headers["Access-Control-Allow-Origin"] = SIGMA_ORIGIN
    resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    resp.headers["Access-Control-Expose-Headers"] = (
        "X-Blink-Captured, X-Blink-Capture-Source, X-Blink-Requested, X-Blink-Snap-Every"
    )
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _err(msg: str) -> web.Response:
    return _cors(web.json_response({"error": msg}))


async def handle_cameras(request: web.Request) -> web.Response:
    global _last_view
    _last_view = time.time()
    try:
        blink = await _ensure_blink()
        cams = []
        for name, cam in blink.cameras.items():
            attrs = getattr(cam, "attributes", {}) or {}
            captured, source = note_image(name, _cam_jpeg(cam), getattr(cam, "thumbnail", None))
            cams.append({
                "name": name,
                "network": attrs.get("network_id"),
                "armed": attrs.get("armed"),
                "battery": attrs.get("battery"),
                "temperature": attrs.get("temperature"),
                "last_record": attrs.get("last_record"),
                "captured_at": captured,
                "capture_source": source,
            })
        cams.sort(key=lambda c: c["name"].lower())
    except Exception as e:
        blink_error = str(e)
        cams = []
    else:
        blink_error = None
    ring_error = None
    try:
        if await _ensure_ring() is not None:
            for dname, dev in sorted(_ring_devices.items()):
                hit = _ring_cache.get(dname) or {}
                cams.append({
                    "name": dname, "vendor": "ring",
                    "battery": getattr(dev, "battery_life", None),
                    "captured_at": hit.get("captured"),
                    "capture_source": "ring" if hit.get("captured") else "unknown",
                })
    except Exception as e:
        ring_error = str(e)
    if not cams and (blink_error or ring_error):
        return _err(blink_error or ring_error)
    body = {"cameras": cams, "count": len(cams), "snap_every": SNAP_EVERY}
    if blink_error:
        body["blink_error"] = blink_error
    if ring_error:
        body["ring_error"] = ring_error
    return _cors(web.json_response(body))


async def handle_snapshot(request: web.Request) -> web.Response:
    global _last_view
    now = time.time()
    _last_view = now
    name = request.query.get("cam", "")
    if not name:
        return _err("cam query parameter is required")
    if name.startswith(RING_PREFIX):
        try:
            if await _ensure_ring() is None:
                return _err("Ring is not signed in on this PC — run 3-RING-LOGIN.cmd")
            jpeg, captured = await ring_snapshot(name, now)
            if not jpeg:
                return _err("Ring has no snapshot for %r — turn on Snapshot Capture for it in the Ring app" % name)
            resp = web.Response(body=jpeg, content_type="image/jpeg")
            resp.headers["X-Blink-Captured"] = "" if captured is None else str(int(captured))
            resp.headers["X-Blink-Capture-Source"] = "ring" if captured else "unknown"
            resp.headers["X-Blink-Snap-Every"] = str(int(SNAP_EVERY))
            return _cors(resp)
        except KeyError:
            return _err("no Ring camera named %r" % name)
        except Exception as e:
            return _err(str(e))
    try:
        blink = await _ensure_blink()
        cam = blink.cameras.get(name)
        if cam is None:
            return _err("no camera named %r" % name)

        if now - _trigger_at.get(name, 0) >= SNAP_EVERY:
            _trigger_at[name] = now
            asyncio.ensure_future(_trigger_snap(blink, cam))

        jpeg = _cam_jpeg(cam)
        if not jpeg:
            return _err("no image available yet for %r" % name)
        captured, source = note_image(name, jpeg, getattr(cam, "thumbnail", None))
        resp = web.Response(body=jpeg, content_type="image/jpeg")
        resp.headers["X-Blink-Captured"] = "" if captured is None else str(int(captured))
        resp.headers["X-Blink-Capture-Source"] = source
        resp.headers["X-Blink-Requested"] = str(int(_trigger_at.get(name, 0)))
        resp.headers["X-Blink-Snap-Every"] = str(int(SNAP_EVERY))
        return _cors(resp)
    except Exception as e:
        return _err(str(e))


async def handle_storage(request: web.Request) -> web.Response:
    """Where Blink keeps motion clips: USB on the Sync Module and/or the cloud.

    Read-only, counts and flags only — no clip content, no addresses. Answers
    "is there anything to archive?" before an archiver is built.
    """
    try:
        blink = await _ensure_blink()
        modules = []
        for name, sync in blink.sync.items():
            ls = getattr(sync, "_local_storage", {}) or {}
            modules.append({
                "name": name,
                "usb_enabled": bool(ls.get("enabled")),
                "usb_compatible": bool(ls.get("compatible")),
                "usb_active": bool(ls.get("status")),
                "usb_clips_in_manifest": len(ls.get("manifest") or []),
            })
        days = max(1, min(60, int(request.query.get("days", "30"))))
        since = time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(time.time() - days * 86400))
        try:
            vids = await blink.get_videos_metadata(since=since, stop=400)
            per_cam = {}
            for v in vids:
                if v.get("deleted"):
                    continue
                name = str(v.get("device_name") or "?").strip()
                c = per_cam.setdefault(name, {"clips": 0, "oldest": None, "newest": None})
                c["clips"] += 1
                ca = v.get("created_at") or ""
                c["oldest"] = min(c["oldest"] or ca, ca)
                c["newest"] = max(c["newest"] or ca, ca)
            cloud = {"days": days, "items_returned": len(vids), "per_camera": per_cam,
                     "newest": max((v.get("created_at") or "" for v in vids), default=None)}
        except Exception as e:
            cloud = {"error": str(e)}
        return _cors(web.json_response({"sync_modules": modules, "cloud": cloud}))
    except Exception as e:
        return _err(str(e))


async def handle_health(request: web.Request) -> web.Response:
    return _cors(web.json_response({
        "helper": "sigma-blink",
        "creds_present": os.path.exists(CREDS),
        "connected": _blink is not None,
        "snap_every": SNAP_EVERY,
        "watching": time.time() - _last_view <= IDLE_AFTER,
    }))


async def handle_options(request: web.Request) -> web.Response:
    return _cors(web.Response(status=204))


async def handle_nokey(request: web.Request) -> web.Response:
    # Readable by SIGMA (CORS, 200) so the setup card can say what is wrong, but
    # reveals nothing: no camera names, no stills.
    return _err("this address is missing the helper key — paste the FULL address "
                "2-START.cmd printed, including /k/…")


def build_app(key: str) -> web.Application:
    app = web.Application()
    base = "/k/" + key
    app.router.add_get(base + "/api/health", handle_health)
    app.router.add_get(base + "/api/cameras", handle_cameras)
    app.router.add_get(base + "/api/snapshot", handle_snapshot)
    app.router.add_get(base + "/api/storage", handle_storage)
    app.router.add_route("OPTIONS", "/{tail:.*}", handle_options)
    app.router.add_get("/{tail:.*}", handle_nokey)

    async def start_bg(app):
        app["poller"] = asyncio.ensure_future(_poller(app))

    async def stop_bg(app):
        app["poller"].cancel()
        if _ring_auth is not None:
            try:
                await _ring_auth.async_close()
            except Exception:
                pass
        if _blink is not None:
            try:
                save_tokens(_blink)
                await _blink.auth.session.close()
            except Exception:
                pass

    app.on_startup.append(start_bg)
    app.on_cleanup.append(stop_bg)
    return app


if __name__ == "__main__":
    key = load_key()
    print("SIGMA Blink helper on http://%s:%d/k/<key>  (creds: %s, key: %s)" % (HOST, PORT, CREDS, KEYFILE))
    print("New picture per camera at most every %ds, only while SIGMA is watching." % SNAP_EVERY)
    if not os.path.exists(CREDS):
        print("  ! no %s yet — run:  python login.py" % CREDS)
    web.run_app(build_app(key), host=HOST, port=PORT)
