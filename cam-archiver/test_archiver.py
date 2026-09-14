"""Offline tests for archiver.py — fake Blink and Ring accounts, a temp DEST.

    python test_archiver.py
"""
import asyncio
import datetime as dt
import os
import shutil
import sys
import tempfile
import time

TMP = tempfile.mkdtemp()
os.environ["CAM_ARCHIVER_HOME"] = os.path.join(TMP, "secrets")
os.environ["CAM_ARCHIVER_DEST"] = os.path.join(TMP, "Surveillance")
os.environ["CAM_ARCHIVER_LOG"] = os.path.join(TMP, "archiver.log")
os.makedirs(os.environ["CAM_ARCHIVER_DEST"])
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import archiver as A  # noqa: E402

fails = 0


def check(cond, label):
    global fails
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        fails += 1


# ---- pure helpers ----------------------------------------------------------
check(A.safe_name("Front office ") == "Front office", "trailing space stripped")
check(A.safe_name('a<b>:c"/d\\e|f?g*') == "a_b_c_d_e_f_g_", "illegal SMB chars replaced")
check(A.safe_name("   ") == "camera", "empty name falls back")
check(A.safe_name("..") == "camera", "dots-only name falls back")

t = A.parse_time("2026-09-14T03:14:52-04:00")
check(t is not None and t.tzinfo is not None and abs(t.timestamp() - 1789370092) < 1, "Blink ISO parsed to the right instant")
check(A.parse_time("2026-09-14T07:14:52Z").timestamp() == t.timestamp(), "Z suffix handled")
check(A.parse_time(1789370092000).timestamp() == 1789370092, "epoch millis handled")
check(A.parse_time("garbage") is None and A.parse_time(None) is None, "bad times -> None")

p = A.clip_path("/d", "Blink", "Front office ", t, 123)
check(p.replace("\\", "/").endswith("Blink/Front office/%s/%s_123.mp4" % (t.strftime("%Y-%m-%d"), t.strftime("%Y-%m-%d_%H-%M-%S"))), "Blink path layout")
p = A.clip_path("/d", "Ring", "Back Yard", t, 99, kind="motion")
check("_motion_99.mp4" in p, "Ring path carries kind")

f = os.path.join(TMP, "x", "y.mp4")
A.write_atomic(f, b"abc", t)
check(open(f, "rb").read() == b"abc" and not os.path.exists(f + ".part"), "atomic write, no .part left")
check(abs(os.path.getmtime(f) - t.timestamp()) < 2, "mtime = recording time")

# ---- prune only touches our day folders -------------------------------------
dest = os.environ["CAM_ARCHIVER_DEST"]
old = os.path.join(dest, "Blink", "Cam", "2026-01-01"); os.makedirs(old)
open(os.path.join(old, "a.mp4"), "wb").write(b"1")
new = os.path.join(dest, "Blink", "Cam", dt.date.today().strftime("%Y-%m-%d")); os.makedirs(new)
open(os.path.join(new, "b.mp4"), "wb").write(b"1")
foreign = os.path.join(dest, "FLoodLight Rear Cam", "2020-01-01"); os.makedirs(foreign)
open(os.path.join(foreign, "keep.mp4"), "wb").write(b"1")
odd = os.path.join(dest, "Blink", "Cam", "notes"); os.makedirs(odd)
open(os.path.join(odd, "keep.txt"), "wb").write(b"1")
n = A.prune(dest, 90)
check(n == 1 and not os.path.exists(old), "old Blink day folder pruned")
check(os.path.exists(os.path.join(new, "b.mp4")), "recent clip kept")
check(os.path.exists(os.path.join(foreign, "keep.mp4")), "foreign folder (Surveillance Station) untouched")
check(os.path.exists(os.path.join(odd, "keep.txt")), "non-date folder untouched")
check(A.prune(dest, 0) == 0, "retention 0 = never prune")
shutil.rmtree(os.path.join(dest, "Blink"))

# ---- Blink archive with a fake account --------------------------------------
now = time.time()
iso = lambda s_ago: dt.datetime.fromtimestamp(now - s_ago, dt.timezone.utc).isoformat()


class Resp:
    def __init__(self, data): self.data = data
    async def read(self): return self.data


class FakeBlink:
    def __init__(self):
        self.downloads = []
        self.since = None
        self.items = [
            {"id": 1, "created_at": iso(600), "device_name": "Front office ", "media": "/api/v2/m/1.mp4", "deleted": False},
            {"id": 2, "created_at": iso(300), "device_name": "StudioCam1", "media": "/api/v2/m/2.mp4", "deleted": False},
            {"id": 3, "created_at": iso(200), "device_name": "StudioCam1", "media": "/api/v2/m/3.mp4", "deleted": True},
            {"id": 4, "created_at": iso(100), "device_name": "StudioCam2", "media": "/api/v2/m/bad.mp4", "deleted": False},
        ]
    async def get_videos_metadata(self, since=None, stop=10):
        self.since = since
        return self.items
    async def do_http_get(self, address):
        self.downloads.append(address)
        if "bad" in address:
            raise RuntimeError("HTTP 500")
        return Resp(b"MP4" + address.encode())


class FakeSession:
    closed = False
    async def close(self): self.closed = True


fb, fs = FakeBlink(), FakeSession()
async def fake_blink_session(): return fb, fs
A.blink_session = fake_blink_session
A.DOWNLOAD_PAUSE = 0
A.RING_PAUSE = 0

state = {}
ok = asyncio.run(A.blink_archive(dest, state, now))
files = sorted(os.path.relpath(os.path.join(r, x), dest).replace("\\", "/") for r, _, fl in os.walk(os.path.join(dest, "Blink")) for x in fl)
check(len(files) == 2, "2 good clips written (got %d)" % len(files))
check(all(not x.endswith(".part") for x in files), "no partial files")
check(not any("_3.mp4" in x for x in files), "deleted clip skipped")
check(ok is False, "a failed download makes the run report failure")
check(fs.closed, "Blink HTTP session closed")
check(abs(state["blink_last"] - (now - 300)) < 2, "state = newest SUCCESSFUL clip, not the failed one")
# an OLDER failure must hold the bookmark back so it is retried
fb2 = FakeBlink(); fb2.items = [{"id": 7, "created_at": iso(5000), "device_name": "X", "media": "/m/bad7.mp4", "deleted": False}, {"id": 8, "created_at": iso(50), "device_name": "X", "media": "/m/8.mp4", "deleted": False}]
async def fb2s(): return fb2, FakeSession()
_orig = A.blink_session; A.blink_session = fb2s; st2 = {}
asyncio.run(A.blink_archive(os.path.join(TMP, "d2"), st2, now)); A.blink_session = _orig
check(st2["blink_last"] < now - 5000, "older failed clip holds the bookmark back for retry")
first_since = fb.since
# Blink ignores "since": clips older than the window must be skipped by us
fb3 = FakeBlink(); fb3.items = [{"id": 9, "created_at": iso(40 * 86400), "device_name": "Y", "media": "/m/9.mp4", "deleted": False}]
async def fb3s(): return fb3, FakeSession()
_o = A.blink_session; A.blink_session = fb3s
asyncio.run(A.blink_archive(os.path.join(TMP, "d3"), {}, now)); A.blink_session = _o
check(fb3.downloads == [], "clip older than the backfill window is not downloaded")
check(dt.datetime.strptime(first_since, "%Y/%m/%d %H:%M:%S").timestamp() < now - 13 * 86400, "first run backfills 14 days")

fb.downloads.clear(); fb.items = fb.items[:2]
ok = asyncio.run(A.blink_archive(dest, state, now + 900))
check(ok and fb.downloads == [], "second run downloads nothing already on NAS")
since2 = dt.datetime.strptime(fb.since, "%Y/%m/%d %H:%M:%S").timestamp()
check(abs(since2 - (state["blink_last"] - A.OVERLAP_SECONDS)) < 2, "next run re-scans a 2h overlap")

# ---- Ring archive with a fake account ---------------------------------------
class FakeRingCam:
    def __init__(self, cid, name, sub, events):
        self.id, self.name, self.has_subscription, self.events = cid, name, sub, events
        self.dl = []
    async def async_history(self, limit=30, older_than=None):
        evs = sorted(self.events, key=lambda e: e["created_at"], reverse=True)
        if older_than is not None:
            idx = [e["id"] for e in evs].index(older_than)
            evs = evs[idx + 1:]
        return evs[:limit]
    async def async_recording_download(self, rid):
        self.dl.append(rid)
        return b"RING%d" % rid


def ev(rid, s_ago, kind="motion", status="ready"):
    return {"id": rid, "kind": kind, "created_at": dt.datetime.fromtimestamp(now - s_ago, dt.timezone.utc),
            "recording": {"status": status}}


cam1 = FakeRingCam(11, "Back Yard", True, [ev(501, 400), ev(502, 60, status="processing"), ev(503, 40 * 86400)])
cam2 = FakeRingCam(12, "Side Gate", False, [ev(601, 100)])


class FakeRing:
    def video_devices(self): return [cam1, cam2]


class FakeAuth:
    closed = False
    async def async_close(self): self.closed = True


fa = FakeAuth()
async def fake_ring_session(): return FakeRing(), fa
A.ring_session = fake_ring_session
state = {}
ok = asyncio.run(A.ring_archive(dest, state, now))
ring_files = [x for x in (os.path.relpath(os.path.join(r, y), dest) for r, _, fl in os.walk(os.path.join(dest, "Ring")) for y in fl)]
check(ok and cam1.dl == [501], "Ring: ready clip downloaded; processing and >30d-old skipped (got %s)" % cam1.dl)
check(cam2.dl == [], "Ring: camera without Ring Protect is not downloaded")
check(len(ring_files) == 1 and "_motion_501.mp4" in ring_files[0], "Ring file layout")
check(fa.closed, "Ring auth closed")
check(str(11) in state["ring_last"], "Ring state per camera")

# paging: 250 events in the window must all be requested, not just the newest 100
many = [ev(1000 + i, 600 + i * 60) for i in range(250)]
cam3 = FakeRingCam(13, "Busy Door", True, many)
class FakeRing3:
    def video_devices(self): return [cam3]
async def rs3(): return FakeRing3(), FakeAuth()
A.ring_session = rs3
asyncio.run(A.ring_archive(os.path.join(TMP, "r3"), {}, now))
check(len(cam3.dl) == 250, "Ring pages past 100 events (got %d)" % len(cam3.dl))

# 429: stop at once, keep the bookmark behind the first throttled clip
class ThrottledCam(FakeRingCam):
    async def async_recording_download(self, rid):
        if len(self.dl) >= 2:
            raise RuntimeError("HTTP error with status code 429 ... Too Many Requests")
        self.dl.append(rid)
        return b"R"
cam4 = ThrottledCam(14, "Throttled", True, [ev(2000 + i, 600 + i * 60) for i in range(10)])
class FakeRing4:
    def video_devices(self): return [cam4]
async def rs4(): return FakeRing4(), FakeAuth()
A.ring_session = rs4
st4 = {}
ok4 = asyncio.run(A.ring_archive(os.path.join(TMP, "r4"), st4, now))
check(len(cam4.dl) == 2 and ok4 is False, "Ring 429 stops the run instead of hammering (downloaded %d)" % len(cam4.dl))
third = now - (600 + 2 * 60)
check(st4["ring_last"]["14"] < third, "bookmark stays behind the throttled clip so it is retried")

# 404: Ring lists the event but has no video -> not a failure, bookmark moves on
class GoneCam(FakeRingCam):
    async def async_recording_download(self, rid):
        if rid == 3001:
            raise RuntimeError("HTTP error with status code 404 during query of url .../recording")
        self.dl.append(rid)
        return b"R"
cam5 = GoneCam(15, "Gone", True, [ev(3001, 5000), ev(3002, 900)])
class FakeRing5:
    def video_devices(self): return [cam5]
async def rs5(): return FakeRing5(), FakeAuth()
A.ring_session = rs5
st5 = {}
ok5 = asyncio.run(A.ring_archive(os.path.join(TMP, "r5"), st5, now))
check(ok5 is True and cam5.dl == [3002], "404 (no video at Ring) is not a failure")
check(abs(st5["ring_last"]["15"] - (now - 900)) < 2, "404 does not pin the bookmark")

# ---- run() with nothing signed in is a no-op, not a crash --------------------
rc = asyncio.run(A.cmd_run())
check(rc == 0, "run with no accounts signed in exits 0")
check(os.path.exists(A.STATE_FILE), "state file written in secrets dir")

log = open(os.environ["CAM_ARCHIVER_LOG"], encoding="utf-8").read()
check("no Ring Protect plan" in log, "log explains the Ring Protect gap")

shutil.rmtree(TMP, ignore_errors=True)
print("FAILS", fails)
sys.exit(1 if fails else 0)
