import asyncio, json, os, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(tempfile.mkdtemp())
import blink_helper as bh
from aiohttp.test_utils import TestServer, TestClient

fails = 0
def check(cond, label):
    global fails
    print(("PASS " if cond else "FAIL ") + label)
    if not cond: fails += 1

now = time.time()
# thumb_ts
check(bh.thumb_ts("/x/thumbnail.jpg?ts=%d&ext=" % int(now - 120), now) == int(now - 120), "ts seconds parsed")
check(abs(bh.thumb_ts("/x.jpg?ts=%d&ext=" % int((now - 60) * 1000), now) - (now - 60)) < 1, "ts millis parsed")
check(bh.thumb_ts("/x.jpg?ts=%d" % int(now + 9999), now) is None, "future ts rejected")
check(bh.thumb_ts("/x.jpg?ts=12345", now) is None, "short ts rejected")
check(bh.thumb_ts("https://x/media/production/account/1/thumb", now) is None, "no ts = None")
check(bh.thumb_ts(None, now) is None, "None url")

# note_image honesty
bh._seen.clear()
c, s = bh.note_image("A", b"img1", None, now)
check((c, s) == (None, "unknown"), "first still w/o ts is UNKNOWN, not now")
c, s = bh.note_image("A", b"img1", None, now + 50)
check((c, s) == (None, "unknown"), "same bytes later stays unknown (no fresh claim)")
c, s = bh.note_image("A", b"img2", None, now + 60)
check((c, s) == (now + 60, "observed"), "changed bytes while watching = observed")
c, s = bh.note_image("A", b"img2", None, now + 500)
check((c, s) == (now + 60, "observed"), "stale repeat keeps ORIGINAL capture time")
c, s = bh.note_image("B", b"x", "/t.jpg?ts=%d&ext=" % int(now - 3 * 86400), now)
check(s == "blink" and c == int(now - 3 * 86400), "3-day-old ts reported as 3 days old")

# save_tokens strips password, atomic
class FakeAuth:
    def __init__(self):
        self.token = "t1"; self.refresh_token = "r1"
        self.login_attributes = {"username": "u", "password": "SECRET", "token": "t1", "refresh_token": "r1"}
class FakeBlink:
    def __init__(self): self.auth = FakeAuth()
fb = FakeBlink()
bh._saved_tokens = None
bh.save_tokens(fb)
d = json.load(open(bh.CREDS))
check("password" not in d and d["refresh_token"] == "r1", "creds saved without password")
check("password" in fb.auth.login_attributes, "in-memory login data untouched")
os.remove(bh.CREDS); bh.save_tokens(fb)
check(not os.path.exists(bh.CREDS), "unchanged tokens not rewritten")
fb.auth.refresh_token = "r2"; fb.auth.login_attributes["refresh_token"] = "r2"; bh.save_tokens(fb)
check(json.load(open(bh.CREDS))["refresh_token"] == "r2", "rotated token saved")

# HTTP: key gate, headers, snap throttle
class Cam:
    def __init__(self, n, img, thumb):
        self.name = n; self._cached_image = img; self.thumbnail = thumb
        self.network_id = "1"; self.camera_id = n; self.camera_type = ""; self.attributes = {}
triggers = []
async def fake_request_new_image(blink, net, cid, camera_type=""):
    triggers.append(cid)
bh.api.request_new_image = fake_request_new_image
async def fake_refresh_now(blink): pass
bh._refresh_now = fake_refresh_now

class B: pass
blink = B()
blink.cameras = {"Cam1": Cam("Cam1", b"\xff\xd8jpeg", "/t.jpg?ts=%d&ext=" % int(now - 30))}
bh._blink = blink; bh._seen.clear(); bh._trigger_at.clear()

async def http():
    app = bh.build_app("KEY123")
    async with TestClient(TestServer(app)) as cl:
        r = await cl.get("/api/cameras"); j = await r.json()
        check(r.status == 200 and "error" in j and "cameras" not in j, "no key: error, no camera list")
        r = await cl.get("/api/snapshot?cam=Cam1"); body = await r.read()
        check(b"jpeg" not in body, "no key: no image bytes")
        r = await cl.get("/k/WRONG/api/snapshot?cam=Cam1"); body = await r.read()
        check(b"jpeg" not in body, "wrong key: no image bytes")
        r = await cl.get("/k/KEY123/api/snapshot?cam=Cam1"); body = await r.read()
        check(r.status == 200 and body == b"\xff\xd8jpeg", "keyed snapshot served")
        check(r.headers["X-Blink-Captured"] == str(int(now - 30)) and r.headers["X-Blink-Capture-Source"] == "blink", "real capture header")
        check("X-Blink-Captured" in r.headers["Access-Control-Expose-Headers"], "header exposed to CORS")
        check(r.headers["Access-Control-Allow-Origin"] == "*", "CORS origin")
        await asyncio.sleep(0.05)
        for _ in range(5):
            await cl.get("/k/KEY123/api/snapshot?cam=Cam1")
        await asyncio.sleep(0.05)
        check(triggers == ["Cam1"], "6 rapid requests = 1 Amazon snap (got %d)" % len(triggers))
        r = await cl.get("/k/KEY123/api/snapshot?cam=Nope"); j = await r.json()
        check(r.status == 200 and "error" in j, "unknown cam: 200 + error")
        r = await cl.get("/k/KEY123/api/cameras"); j = await r.json()
        check(j["count"] == 1 and j["cameras"][0]["captured_at"] == int(now - 30) and j["snap_every"] == 60, "cameras list carries capture time")
        r = await cl.options("/k/KEY123/api/snapshot")
        check(r.status == 204, "OPTIONS 204")
asyncio.run(http())


# ---- Ring (fake account) -----------------------------------------------------
check(bh.ring_ts_seconds(int(now * 1000) - 90000, now) == (int(now * 1000) - 90000) / 1000.0, "Ring ms timestamp -> seconds")
check(bh.ring_ts_seconds(0, now) is None and bh.ring_ts_seconds("x", now) is None, "bad Ring timestamps rejected")

class RResp:
    def __init__(self, js=None, content=b"", status=200): self._js, self.content, self.status_code = js, content, status
    def json(self): return self._js

class FakeRingDev:
    name = "Back Yard"; battery_life = 71
    _attrs = {"id": 777}

ring_calls = []
class FakeRing:
    async def async_query(self, url, method="GET", json=None, **kw):
        ring_calls.append((method, url))
        if "timestamps" in url:
            return RResp({"timestamps": [{"doorbot_id": 777, "timestamp": int((now - 120) * 1000)}]})
        return RResp(content=b"\xff\xd8RINGJPEG")

async def fake_ensure_ring():
    bh._ring = FakeRing()
    bh._ring_devices = {bh.ring_display_name("Back Yard "): FakeRingDev()}
    return bh._ring
bh._ensure_ring = fake_ensure_ring

async def ring_http():
    app = bh.build_app("KEY123")
    async with TestClient(TestServer(app)) as cl:
        r = await cl.get("/k/KEY123/api/cameras"); j = await r.json()
        names = [c["name"] for c in j["cameras"]]
        check("Ring · Back Yard" in names and "Cam1" in names, "Blink + Ring listed together (%s)" % names)
        r = await cl.get("/k/KEY123/api/snapshot?cam=" + "Ring%20%C2%B7%20Back%20Yard"); body = await r.read()
        check(r.status == 200 and body == b"\xff\xd8RINGJPEG", "Ring snapshot served")
        check(r.headers["X-Blink-Captured"] == str(int(now - 120)) and r.headers["X-Blink-Capture-Source"] == "ring", "Ring real capture time in header")
        n = len(ring_calls)
        await cl.get("/k/KEY123/api/snapshot?cam=" + "Ring%20%C2%B7%20Back%20Yard")
        check(len(ring_calls) == n, "Ring snapshot cached (no second Ring API call inside SNAP_EVERY)")
        r = await cl.get("/k/KEY123/api/snapshot?cam=" + "Ring%20%C2%B7%20Nope"); j = await r.json()
        check("error" in j, "unknown Ring camera -> error")
        r = await cl.get("/api/snapshot?cam=" + "Ring%20%C2%B7%20Back%20Yard"); body = await r.read()
        check(b"RINGJPEG" not in body, "Ring still needs the key")
asyncio.run(ring_http())

# Blink broken, Ring fine -> still lists Ring, reports blink_error
async def broken_blink(): raise RuntimeError("Blink refused the saved session")
bh._ensure_blink = broken_blink
async def ring_only():
    app = bh.build_app("KEY123")
    async with TestClient(TestServer(app)) as cl:
        r = await cl.get("/k/KEY123/api/cameras"); j = await r.json()
        check(j.get("count") == 1 and "blink_error" in j and "error" not in j, "Blink down does not hide Ring cameras")
asyncio.run(ring_only())
k1 = bh.load_key(); k2 = bh.load_key()
check(k1 == k2 and len(k1) >= 20, "key generated once and reused")
print("FAILS", fails)
sys.exit(1 if fails else 0)
