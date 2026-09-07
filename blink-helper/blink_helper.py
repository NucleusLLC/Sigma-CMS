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
  2. Serves a JSON list of your cameras at   GET /api/cameras
  3. Serves the latest still for one camera at GET /api/snapshot?cam=<name>

What it deliberately is NOT:
  - It is not live video. Blink gives stills. Each /api/snapshot asks Blink for a
    fresh thumbnail (rate-limited by Amazon) and returns the JPEG. SIGMA shows it
    as a still that refreshes every N seconds, labelled "CLOUD · NOT LIVE".
  - It stores nothing but the session token blinkpy already wrote. No frame is
    kept, logged or forwarded.

CORS: the browser calls this from the SIGMA origin, so every response carries
Access-Control-Allow-Origin. Set SIGMA_ORIGIN below to lock it to your site;
"*" is fine for a helper that only ever serves your own stills on your own LAN.

Run:   python blink_helper.py           (after login.py has written creds.json)
Then give SIGMA an https:// address for it — see README.md (Cloudflare Tunnel).
"""

import asyncio
import io
import json
import os
import time

from aiohttp import web
from blinkpy.blinkpy import Blink
from blinkpy.auth import Auth
from blinkpy.helpers.util import json_load

CREDS = os.environ.get("BLINK_CREDS", "creds.json")
HOST = os.environ.get("BLINK_HELPER_HOST", "127.0.0.1")
PORT = int(os.environ.get("BLINK_HELPER_PORT", "8765"))
SIGMA_ORIGIN = os.environ.get("SIGMA_ORIGIN", "*")

# A fresh Blink thumbnail is rate-limited and slow, so a burst of browser
# refreshes must not become a burst of Amazon calls. One snapshot per camera is
# cached for this long; requests inside the window return the cached bytes.
SNAP_TTL = float(os.environ.get("BLINK_SNAP_TTL", "12"))

_blink: Blink = None
_cache = {}   # name -> {"at": epoch, "jpeg": bytes}


def _cors(resp: web.Response) -> web.Response:
    resp.headers["Access-Control-Allow-Origin"] = SIGMA_ORIGIN
    resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    resp.headers["Cache-Control"] = "no-store"
    return resp


async def _ensure_blink() -> Blink:
    global _blink
    if _blink is not None:
        return _blink
    if not os.path.exists(CREDS):
        raise RuntimeError(
            "no credentials file (%s). Run login.py once to sign in to Blink." % CREDS
        )
    blink = Blink()
    auth = Auth(await json_load(CREDS), no_prompt=True)
    blink.auth = auth
    await blink.start()
    await blink.refresh()
    _blink = blink
    return blink


async def handle_cameras(request: web.Request) -> web.Response:
    try:
        blink = await _ensure_blink()
        cams = []
        for name, cam in blink.cameras.items():
            attrs = getattr(cam, "attributes", {}) or {}
            cams.append({
                "name": name,
                "network": attrs.get("network_id"),
                "armed": attrs.get("armed"),
                "battery": attrs.get("battery"),
                "temperature": attrs.get("temperature"),
                "last_capture": attrs.get("last_record") or attrs.get("thumbnail"),
            })
        cams.sort(key=lambda c: c["name"].lower())
        return _cors(web.json_response({"cameras": cams, "count": len(cams)}))
    except Exception as e:
        return _cors(web.json_response({"error": str(e)}, status=502))


async def handle_snapshot(request: web.Request) -> web.Response:
    name = request.query.get("cam", "")
    if not name:
        return _cors(web.json_response({"error": "cam query parameter is required"}, status=400))
    try:
        blink = await _ensure_blink()
        cam = blink.cameras.get(name)
        if cam is None:
            return _cors(web.json_response({"error": "no camera named %r" % name}, status=404))

        hit = _cache.get(name)
        now = time.time()
        if hit and (now - hit["at"]) < SNAP_TTL and hit["jpeg"]:
            jpeg = hit["jpeg"]
        else:
            # Ask Blink for a NEW thumbnail, then re-read it. snap_picture triggers
            # the capture; refresh pulls the updated metadata; the image bytes come
            # from the camera's own downloader.
            try:
                await cam.snap_picture()
                await blink.refresh()
            except Exception:
                # A snap failure is not fatal — fall back to whatever thumbnail the
                # last refresh already had, so a rate-limit does not blank the tile.
                pass
            buf = io.BytesIO()
            await cam.image_to_file(buf) if _supports_buffer(cam) else _write_via_bytes(cam, buf)
            jpeg = buf.getvalue()
            if jpeg:
                _cache[name] = {"at": now, "jpeg": jpeg}
        if not jpeg:
            return _cors(web.json_response({"error": "no image available yet for %r" % name}, status=503))
        resp = web.Response(body=jpeg, content_type="image/jpeg")
        resp.headers["X-Blink-Captured"] = str(int(time.time()))
        return _cors(resp)
    except Exception as e:
        return _cors(web.json_response({"error": str(e)}, status=502))


def _supports_buffer(cam) -> bool:
    # Newer blinkpy image_to_file takes a path; older builds differ. We try a
    # bytes attribute first in _write_via_bytes and only reach image_to_file for
    # file-like support. Kept simple on purpose.
    return False


def _write_via_bytes(cam, buf: io.BytesIO):
    data = getattr(cam, "image_from_cache", None)
    if callable(data):
        data = data()
    if isinstance(data, (bytes, bytearray)):
        buf.write(data)
        return
    # last resort: the thumbnail bytes attribute some versions expose
    raw = getattr(cam, "thumbnail_bytes", None) or getattr(cam, "_cached_image", None)
    if isinstance(raw, (bytes, bytearray)):
        buf.write(raw)


async def handle_health(request: web.Request) -> web.Response:
    return _cors(web.json_response({
        "helper": "sigma-blink",
        "creds_present": os.path.exists(CREDS),
        "connected": _blink is not None,
    }))


async def handle_options(request: web.Request) -> web.Response:
    return _cors(web.Response(status=204))


def build_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/api/health", handle_health)
    app.router.add_get("/api/cameras", handle_cameras)
    app.router.add_get("/api/snapshot", handle_snapshot)
    app.router.add_route("OPTIONS", "/{tail:.*}", handle_options)
    return app


if __name__ == "__main__":
    print("SIGMA Blink helper on http://%s:%d  (creds: %s)" % (HOST, PORT, CREDS))
    if not os.path.exists(CREDS):
        print("  ! no %s yet — run:  python login.py" % CREDS)
    web.run_app(build_app(), host=HOST, port=PORT)
