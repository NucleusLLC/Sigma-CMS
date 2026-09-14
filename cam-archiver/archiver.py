#!/usr/bin/env python3
"""
SIGMA cam-archiver — copy Blink and Ring motion clips to the Synology NAS
=========================================================================

Blink and Ring battery cameras cannot be recorded by Surveillance Station: they
serve no RTSP/ONVIF stream and sleep until motion. What they DO produce is a
motion clip per event, kept in the vendor's cloud (Blink subscription, Ring
Protect). This script copies every new clip into the NAS share, one file per
event, and prunes old ones. Run it every 15 minutes from DSM Task Scheduler.

    archiver.py login-blink     one-time, interactive (e-mail, password, 2FA)
    archiver.py login-ring      one-time, interactive (e-mail, password, 2FA)
    archiver.py run             copy new clips, prune old ones (the scheduled job)
    archiver.py status          what is signed in, what is on disk

Layout under DEST (default: the share this folder sits in):

    Blink/<camera>/<YYYY-MM-DD>/<YYYY-MM-DD_HH-MM-SS>_<id>.mp4
    Ring/<camera>/<YYYY-MM-DD>/<YYYY-MM-DD_HH-MM-SS>_<kind>_<id>.mp4

Times are the NAS's local time. A file's modification time is set to the moment
the clip was recorded, so sorting by date in File Station / Explorer is correct.

Secrets (tokens only — passwords are never stored) live in SECRETS_DIR, by
default ~/.cam-archiver on the NAS, NOT in the share: anyone with SMB access to
the share could otherwise read them.

Idempotent: a clip already on disk is never downloaded again, a partial download
is written to *.part and renamed only when complete, and a lock stops two runs
overlapping.
"""

import asyncio
import datetime as dt
import getpass
import json
import os
import re
import sys
import time
import traceback
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SECRETS_DIR = os.environ.get("CAM_ARCHIVER_HOME", os.path.expanduser("~/.cam-archiver"))
DEST = os.environ.get("CAM_ARCHIVER_DEST", os.path.dirname(HERE))
RETENTION_DAYS = int(os.environ.get("CAM_ARCHIVER_RETENTION_DAYS", "14"))
BACKFILL_DAYS = int(os.environ.get("CAM_ARCHIVER_BACKFILL_DAYS", "14"))
OVERLAP_SECONDS = 2 * 3600       # re-scan the last 2h every run: clips upload late
DOWNLOAD_PAUSE = 0.5             # seconds between downloads; gentle on the vendor APIs
RING_PAUSE = float(os.environ.get("CAM_ARCHIVER_RING_PAUSE", "3"))   # Ring answers 429 at 0.5 s
RING_HISTORY_PAGES = 30          # x100 events; stops early once past the window
LOG_FILE = os.environ.get("CAM_ARCHIVER_LOG", os.path.join(HERE, "archiver.log"))
LOG_MAX_BYTES = 5 * 1024 * 1024

BLINK_CREDS = os.path.join(SECRETS_DIR, "blink.json")
RING_TOKEN = os.path.join(SECRETS_DIR, "ring.json")
STATE_FILE = os.path.join(SECRETS_DIR, "state.json")
LOCK_FILE = os.path.join(SECRETS_DIR, "run.lock")

USER_AGENT = "SIGMA-cam-archiver/1.0"


# ---------------------------------------------------------------------------
# small helpers (pure — unit tested)
# ---------------------------------------------------------------------------

_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]+')


def safe_name(name, fallback="camera"):
    """A folder name that is legal on SMB/Windows and ext4 and never empty."""
    s = _BAD.sub("_", str(name or "")).strip().strip(".")
    s = re.sub(r"\s+", " ", s)
    return s[:80] or fallback


def parse_time(value):
    """Blink ISO strings, Ring datetimes or epoch numbers -> aware local datetime."""
    if value is None:
        return None
    if isinstance(value, dt.datetime):
        d = value
    elif isinstance(value, (int, float)):
        d = dt.datetime.fromtimestamp(value / 1000.0 if value > 10**12 else value, dt.timezone.utc)
    else:
        s = str(value).strip().replace("Z", "+00:00")
        try:
            d = dt.datetime.fromisoformat(s)
        except ValueError:
            return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone()


def clip_path(dest, vendor, camera, when, clip_id, kind=None, ext=".mp4"):
    day = when.strftime("%Y-%m-%d")
    stamp = when.strftime("%Y-%m-%d_%H-%M-%S")
    mid = ("_" + safe_name(kind, "event")) if kind else ""
    return os.path.join(dest, vendor, safe_name(camera), day,
                        "%s%s_%s%s" % (stamp, mid, safe_name(str(clip_id), "clip"), ext))


def write_atomic(path, data, when=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    if when is not None:
        ts = when.timestamp()
        os.utime(path, (ts, ts))


def prune(dest, retention_days, now=None, vendors=("Blink", "Ring")):
    """Delete day folders older than the retention window. Returns files removed.

    Only folders this script creates are touched: <vendor>/<camera>/<YYYY-MM-DD>.
    Anything else in the share (e.g. Surveillance Station's own folders) is left alone.
    """
    if retention_days <= 0:
        return 0
    now = now or dt.datetime.now()
    cutoff = (now - dt.timedelta(days=retention_days)).date()
    removed = 0
    for vendor in vendors:
        vroot = os.path.join(dest, vendor)
        if not os.path.isdir(vroot):
            continue
        for cam in os.listdir(vroot):
            croot = os.path.join(vroot, cam)
            if not os.path.isdir(croot):
                continue
            for day in os.listdir(croot):
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
                    continue
                try:
                    d = dt.datetime.strptime(day, "%Y-%m-%d").date()
                except ValueError:
                    continue
                if d >= cutoff:
                    continue
                droot = os.path.join(croot, day)
                for fn in os.listdir(droot):
                    fp = os.path.join(droot, fn)
                    if os.path.isfile(fp):
                        os.remove(fp)
                        removed += 1
                try:
                    os.rmdir(droot)
                except OSError:
                    pass
    return removed


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json_private(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.chmod(os.path.dirname(path), 0o700)
    except OSError:
        pass
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=str)
    os.replace(tmp, path)


def log(msg):
    line = "%s %s" % (dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            os.replace(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def since_epoch(state, key, now):
    last = state.get(key)
    if last:
        return max(0.0, float(last) - OVERLAP_SECONDS)
    return now - BACKFILL_DAYS * 86400


# ---------------------------------------------------------------------------
# Blink
# ---------------------------------------------------------------------------

async def blink_session():
    from aiohttp import ClientSession
    from blinkpy.blinkpy import Blink
    from blinkpy.auth import Auth
    from blinkpy.helpers.util import json_load

    if not os.path.exists(BLINK_CREDS):
        raise RuntimeError("Blink is not signed in — run: archiver.py login-blink")
    session = ClientSession()
    blink = Blink(session=session)
    blink.auth = Auth(await json_load(BLINK_CREDS), no_prompt=True, session=session)

    def save():
        data = dict(blink.auth.login_attributes)
        data.pop("password", None)
        save_json_private(BLINK_CREDS, data)

    blink.auth.callback = save
    ok = await blink.start()
    if ok is False:
        await session.close()
        raise RuntimeError("Blink refused the saved session — run: archiver.py login-blink")
    save()   # start() rotates the refresh token
    return blink, session


async def blink_archive(dest, state, now):
    blink, session = await blink_session()
    got = skipped = failed = 0
    newest = state.get("blink_last")
    oldest_failed = None
    try:
        since = since_epoch(state, "blink_last", now)
        since_str = dt.datetime.fromtimestamp(since).strftime("%Y/%m/%d %H:%M:%S")
        # blinkpy stops at `stop` pages even when more exist; 400 is far past any
        # 14-day window (1,462 clips came back in well under that).
        items = await blink.get_videos_metadata(since=since_str, stop=400)
        for item in items:
            if item.get("deleted"):
                continue
            when = parse_time(item.get("created_at"))
            address = item.get("media")
            if not when or not address:
                continue
            # Blink's "since" is not a filter — it pages back through everything the
            # cloud still holds (a 1-day test pulled 674 clips). Enforce it here.
            if when.timestamp() < since:
                continue
            ext = os.path.splitext(address.split("?")[0])[1] or ".mp4"
            path = clip_path(dest, "Blink", item.get("device_name"), when, item.get("id"), ext=ext)
            if os.path.exists(path):
                skipped += 1
            else:
                try:
                    resp = await blink.do_http_get(address)
                    data = await resp.read()
                    if not data:
                        raise RuntimeError("empty download")
                    write_atomic(path, data, when)
                    got += 1
                    await asyncio.sleep(DOWNLOAD_PAUSE)
                except Exception as e:
                    failed += 1
                    oldest_failed = min(oldest_failed or when.timestamp(), when.timestamp())
                    log("Blink: FAILED %s — %s" % (path, e))
                    continue
            ts = when.timestamp()
            newest = max(float(newest or 0), ts)
    finally:
        await session.close()
    # Never move the bookmark past a clip that failed, or it is skipped for good.
    if oldest_failed is not None and newest:
        newest = min(float(newest), oldest_failed - 1)
    if newest:
        state["blink_last"] = newest
    log("Blink: %d new, %d already on NAS, %d failed" % (got, skipped, failed))
    return failed == 0


async def blink_login():
    from aiohttp import ClientSession
    from blinkpy.blinkpy import Blink, BlinkTwoFARequiredError
    from blinkpy.auth import Auth

    print("Blink sign-in. Your password is used once and NOT stored.")
    user = input("Blink (Amazon) e-mail: ").strip()
    pw = getpass.getpass("Blink password: ")
    session = ClientSession()
    try:
        blink = Blink(session=session)
        blink.auth = Auth({"username": user, "password": pw}, no_prompt=True, session=session)
        try:
            started = await blink.start()
        except BlinkTwoFARequiredError:
            code = input("Enter the Blink 2FA code: ").strip()
            if not await blink.auth.complete_2fa_login(code):
                print("2FA failed — nothing saved. Try again with the newest code.")
                return 1
            blink.setup_urls()   # the 2FA path skips this inside start()
            started = await blink.setup_post_verify()
        if started is False:
            print("Sign-in failed — check e-mail/password. Nothing saved.")
            return 1
        await blink.refresh()
        data = dict(blink.auth.login_attributes)
        data.pop("password", None)
        save_json_private(BLINK_CREDS, data)
        print("Signed in. Cameras: %s" % ", ".join(sorted(n.strip() for n in blink.cameras)))
        return 0
    finally:
        await session.close()


# ---------------------------------------------------------------------------
# Ring
# ---------------------------------------------------------------------------

def _ring_token_saver(extra):
    def save(token):
        save_json_private(RING_TOKEN, {"token": token, **extra})
    return save


async def ring_session():
    from ring_doorbell import Auth, Ring

    saved = load_json(RING_TOKEN, None)
    if not saved or not saved.get("token"):
        raise RuntimeError("Ring is not signed in — run: archiver.py login-ring")
    hw = saved.get("hardware_id")
    auth = Auth(USER_AGENT, saved["token"], _ring_token_saver({"hardware_id": hw}), hardware_id=hw)
    ring = Ring(auth)
    await ring.async_update_data()
    return ring, auth


async def ring_archive(dest, state, now):
    ring, auth = await ring_session()
    got = skipped = failed = no_video = 0
    last = dict(state.get("ring_last") or {})
    try:
        cams = ring.video_devices()
        if not cams:
            log("Ring: no video devices on this account")
        for cam in cams:
            name = getattr(cam, "name", None) or str(getattr(cam, "id", "ring"))
            if not cam.has_subscription:
                log("Ring: %s has no Ring Protect plan — Ring keeps no recordings to copy" % name)
                continue
            since = since_epoch(last, str(cam.id), now)
            # Ring returns at most 100 events per call, newest first. Page back with
            # older_than until the window is covered — one call covered only 100
            # events, so a busy doorbell's older clips were never even requested.
            events, older = [], None
            for _ in range(RING_HISTORY_PAGES):
                page = await cam.async_history(limit=100, older_than=older)
                if not page:
                    break
                events.extend(page)
                older = page[-1].get("id")
                tail = parse_time(page[-1].get("created_at"))
                if older is None or (tail and tail.timestamp() < since):
                    break
            newest = last.get(str(cam.id))
            oldest_failed = None
            rate_limited = False
            for ev in events:
                if rate_limited:
                    break
                when = parse_time(ev.get("created_at"))
                if not when or when.timestamp() < since:
                    continue
                rec = ev.get("recording") or {}
                if rec.get("status") not in (None, "ready"):
                    continue   # still uploading; the overlap window picks it up next run
                path = clip_path(dest, "Ring", name, when, ev.get("id"), kind=ev.get("kind"))
                if os.path.exists(path):
                    skipped += 1
                else:
                    try:
                        data = await cam.async_recording_download(ev["id"])
                        if not data:
                            raise RuntimeError("no recording returned")
                        write_atomic(path, data, when)
                        got += 1
                        await asyncio.sleep(RING_PAUSE)
                    except Exception as e:
                        if "404" in str(e):
                            # Ring lists the event but holds no video for it (expired, never
                            # uploaded, or before Ring Protect). Retrying cannot help, and
                            # holding the bookmark back for it would re-page history forever.
                            no_video += 1
                            newest = max(float(newest or 0), when.timestamp())
                            continue
                        failed += 1
                        oldest_failed = min(oldest_failed or when.timestamp(), when.timestamp())
                        if "429" in str(e) or "Too Many Requests" in str(e):
                            # Ring is throttling. Stop for this run: every clip not yet
                            # copied stays behind the bookmark and is retried in 15 min.
                            rate_limited = True
                            log("Ring: rate-limited by Ring after %d clip(s) — continuing next run" % got)
                            continue
                        log("Ring: FAILED %s — %s" % (path, e))
                        continue
                newest = max(float(newest or 0), when.timestamp())
            if oldest_failed is not None and newest:
                newest = min(float(newest), oldest_failed - 1)
            if newest:
                last[str(cam.id)] = newest
    finally:
        await auth.async_close()
    state["ring_last"] = last
    log("Ring: %d new, %d already on NAS, %d failed, %d listed by Ring without a video"
        % (got, skipped, failed, no_video))
    return failed == 0


async def ring_login():
    from ring_doorbell import Auth, Requires2FAError

    print("Ring sign-in. Your password is used once and NOT stored.")
    user = input("Ring e-mail: ").strip()
    pw = getpass.getpass("Ring password: ")
    hw = str(uuid.uuid4())
    auth = Auth(USER_AGENT, None, _ring_token_saver({"hardware_id": hw}), hardware_id=hw)
    try:
        try:
            await auth.async_fetch_token(user, pw)
        except Requires2FAError:
            code = input("Enter the Ring 2FA code: ").strip()
            await auth.async_fetch_token(user, pw, code)
        from ring_doorbell import Ring
        ring = Ring(auth)
        await ring.async_update_data()
        cams = ring.video_devices()
        print("Signed in. Cameras: %s" % (", ".join(c.name for c in cams) or "(none)"))
        for c in cams:
            print("  %s — Ring Protect: %s" % (c.name, "yes" if c.has_subscription else "NO (nothing to copy)"))
        return 0
    finally:
        await auth.async_close()


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

async def cmd_run():
    os.makedirs(SECRETS_DIR, exist_ok=True)
    lock = open(LOCK_FILE, "w")
    try:
        import fcntl   # the NAS is Linux; imported here so the module loads on Windows for tests
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except ImportError:
        pass
    except OSError:
        log("another run is still going — skipping this one")
        return 0
    if not os.path.isdir(DEST):
        log("DEST %s does not exist — is the share mounted?" % DEST)
        return 2
    state = load_json(STATE_FILE, {})
    now = time.time()
    ok = True
    for vendor, fn, creds in (("Blink", blink_archive, BLINK_CREDS), ("Ring", ring_archive, RING_TOKEN)):
        if not os.path.exists(creds):
            continue
        try:
            ok = await fn(DEST, state, now) and ok
        except Exception as e:
            ok = False
            log("%s: ERROR %s" % (vendor, e))
            log(traceback.format_exc().strip().splitlines()[-1])
        save_json_private(STATE_FILE, state)
    save_json_private(STATE_FILE, state)
    removed = prune(DEST, RETENTION_DAYS)
    if removed:
        log("pruned %d clip(s) older than %d days" % (removed, RETENTION_DAYS))
    return 0 if ok else 1


def cmd_status():
    print("DEST        %s  (exists: %s)" % (DEST, os.path.isdir(DEST)))
    print("secrets     %s" % SECRETS_DIR)
    print("retention   %d days" % RETENTION_DAYS)
    print("Blink       %s" % ("signed in" if os.path.exists(BLINK_CREDS) else "not signed in"))
    print("Ring        %s" % ("signed in" if os.path.exists(RING_TOKEN) else "not signed in"))
    state = load_json(STATE_FILE, {})
    for vendor in ("Blink", "Ring"):
        root = os.path.join(DEST, vendor)
        n = sum(len(fs) for _, _, fs in os.walk(root)) if os.path.isdir(root) else 0
        print("%-11s %d clip(s) on NAS" % (vendor, n))
    if state.get("blink_last"):
        print("last Blink  %s" % dt.datetime.fromtimestamp(state["blink_last"]))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "run"
    if cmd == "run":
        return asyncio.run(cmd_run())
    if cmd == "login-blink":
        return asyncio.run(blink_login())
    if cmd == "login-ring":
        return asyncio.run(ring_login())
    if cmd == "status":
        return cmd_status()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
