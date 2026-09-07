# SIGMA-CMS · Blink snapshot helper

Blink cameras are **cloud-only**. They serve no local stream — no RTSP, no
ONVIF, nothing a browser or a go2rtc bridge can reach. The only way to see them
outside Amazon's app is through Amazon's cloud, and this helper is the small
service that does it and hands SIGMA a still image per camera.

**What you get:** each Blink camera as a tile on the dashboard's CAM Security
tab, showing a **still that refreshes every ~15 seconds**, clearly labelled
`CLOUD · NOT LIVE`. It is not video — Blink does not offer video to anything but
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
them. It writes `creds.json` (a session token; git-ignored) and lists the
cameras it found.

## 3. Run the helper

```
python blink_helper.py
```

It listens on `http://127.0.0.1:8765` and serves:

| Endpoint | What |
|---|---|
| `GET /api/health` | is it up, are creds present, is it connected |
| `GET /api/cameras` | JSON list of your Blink cameras |
| `GET /api/snapshot?cam=<name>` | the latest still for one camera (JPEG) |

## 4. Give it an https:// address

SIGMA is served over `https://`, and a browser will not let an `https://` page
read from a `http://192.168.x.x` helper (mixed content + Private Network Access —
the same walls the go2rtc bridge hits). So the helper needs an `https://` name.
Free, one command:

```
cloudflared tunnel --url http://localhost:8765
```

It prints an `https://<random>.trycloudflare.com` URL.

> **Security note:** a quick tunnel URL is public — anyone with it can pull your
> stills. Fine to prove it works. For anything lasting, use a *named* Cloudflare
> tunnel with Cloudflare Access in front, so only you can reach it.

## 5. Point SIGMA at it

Dashboard → **CAM Security** → **⚙ SETUP** → **Blink cloud helper** → paste the
`https://…trycloudflare.com` URL → **Test**. Then on the tab, under
**BLINK — CLOUD**, press **CONNECT** and **OPEN** each camera.

---

## Why not live?

Because Blink will not serve a local stream to anything. This is a decision
Amazon made, not a limitation of SIGMA. If you want genuine **live** tiles on the
same wall, add any camera that serves local RTSP — Reolink, Amcrest, Hikvision,
Dahua, TP-Link Tapo, UniFi — and it connects through the go2rtc bridge with no
cloud, no account and no refresh delay.

## Privacy

No frame is stored, logged or forwarded by this helper beyond a ~12-second
in-memory cache that stops a burst of browser refreshes from hammering Amazon.
SIGMA shows the stills and nothing leaves your machine except the calls to
Amazon that Blink itself requires.
