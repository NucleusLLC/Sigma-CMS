# SIGMA-CMS · Blink snapshot helper

Blink cameras are **cloud-only**. They serve no local stream — no RTSP, no
ONVIF, nothing a browser or a go2rtc bridge can reach. The only way to see them
outside Amazon's app is through Amazon's cloud, and this helper is the small
service that does it and hands SIGMA a still image per camera.

**What you get:** each Blink camera as a tile on the dashboard's CAM Security
tab, showing a **still, stamped with the time it was really taken**, clearly
labelled `CLOUD · NOT LIVE`. It is not video — Blink does not offer video to anything but
its own app.

**What it costs:** an always-on machine to run the helper, a one-time Amazon
sign-in you do yourself, and acceptance that this is an *unofficial* path Amazon
can change at any time.

---

## 1. Install (once)

```
cd blink-helper
python -m venv .venv
.venv\Scripts\activate            # Windows;  source .venv/bin/activate on mac/linux
pip install -r requirements.txt
```

## 2. Sign in (once, interactive)

```
python login.py
```

You enter your Blink (Amazon) e-mail, password and the 2FA code Blink sends you.
**These are entered here, at your terminal, and nowhere else** — SIGMA never sees
them. It writes `creds.json` (session tokens only — **not** your password; git-ignored)
and lists the cameras it found. The helper writes rotated tokens back to it, so
restarting does not need a new 2FA code. It lasts until Blink ends the session
(then run `1-LOGIN.cmd` again).

## 3. Run the helper

```
python blink_helper.py
```

It listens on `http://127.0.0.1:8765`. Every route sits under a secret key
(`helper-key.txt`, created on first run, git-ignored), because the tunnel
address is public:

| Endpoint | What |
|---|---|
| `GET /k/<key>/api/health` | is it up, are creds present, is it connected |
| `GET /k/<key>/api/cameras` | JSON list of cameras, each with `captured_at` |
| `GET /k/<key>/api/snapshot?cam=<name>` | latest still (JPEG) + `X-Blink-Captured` |

Anything without the key gets an error and no image.

**Capture time.** `X-Blink-Captured` is when the picture was *taken* — Blink's
own timestamp, or the moment the helper saw it change — never when it was served.
No evidence = empty header, and SIGMA shows `CAPTURE TIME UNKNOWN`.

**Battery.** A new picture is requested at most once per camera every 60 s
(`BLINK_SNAP_EVERY`), and only while SIGMA is asking. With the tab closed the
helper makes no Amazon calls. SIGMA can poll faster; it gets the same still back.

`2-START.cmd` does steps 3–4 and prints the full address to paste.

## 4. Give it an https:// address

SIGMA is served over `https://`, and a browser will not let an `https://` page
read from a `http://192.168.x.x` helper (mixed content + Private Network Access —
the same walls the go2rtc bridge hits). So the helper needs an `https://` name.
Free, one command:

```
cloudflared tunnel --url http://localhost:8765
```

It prints an `https://<random>.trycloudflare.com` URL that **changes on every
restart**. SIGMA needs it with the key: `https://<random>.trycloudflare.com/k/<key>`.

### Fixed address (paste once)

A named tunnel keeps the same address. One-time, needs a Cloudflare sign-in to
the account that holds `sigma-cms.com`:

```
cloudflared.exe tunnel login                       # browser: pick sigma-cms.com, Authorize
cloudflared.exe tunnel create sigma-cam
cloudflared.exe tunnel route dns sigma-cam cam.sigma-cms.com
```

Then create `tunnel.yml` here (git-ignored):

```
# hostname: cam.sigma-cms.com
tunnel: sigma-cam
credentials-file: C:/Users/<you>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: cam.sigma-cms.com
    service: http://localhost:8765
  - service: http_status:404
```

`2-START.cmd` uses it when present and prints `https://cam.sigma-cms.com/k/<key>`.

## 5. Point SIGMA at it

Dashboard → **CAM Security** → **⚙ SETUP** → **Blink cloud helper** → paste the
full address `2-START.cmd` printed, including `/k/<key>` → **Test**. Then on the tab, under
**BLINK — CLOUD**, press **CONNECT** and **OPEN** each camera.

---

## Why not live?

Because Blink will not serve a local stream to anything. This is a decision
Amazon made, not a limitation of SIGMA. If you want genuine **live** tiles on the
same wall, add any camera that serves local RTSP — Reolink, Amcrest, Hikvision,
Dahua, TP-Link Tapo, UniFi — and it connects through the go2rtc bridge with no
cloud, no account and no refresh delay.

## Privacy

No frame is stored, logged or forwarded by this helper beyond the latest still
per camera, held in memory.
SIGMA shows the stills and nothing leaves your machine except the calls to
Amazon that Blink itself requires.
