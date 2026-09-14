# SIGMA cam-archiver — Blink + Ring clips onto the NAS

Blink and Ring **battery** cameras cannot be recorded by Synology Surveillance
Station: they serve no RTSP/ONVIF stream and sleep until motion. They do produce a
**motion clip per event** in the vendor cloud — Blink (subscription) and Ring
(Ring Protect). This job copies every new clip into `\\Zencave\Surveillance`,
every 15 minutes, and deletes clips older than 90 days.

```
\\Zencave\Surveillance\
  Blink\<camera>\2026-09-14\2026-09-14_03-14-52_123456789.mp4
  Ring\<camera>\2026-09-14\2026-09-14_07-02-11_motion_7412....mp4
  _archiver\            <- this folder (code, run.sh, archiver.log)
```

Existing folders in the share (e.g. `FLoodLight Rear Cam`) are never touched.

No Docker. Nothing system-wide. Passwords are used once at sign-in and never
stored; only tokens, in `~/.cam-archiver` on the NAS (not in the share).

## 1. Install (once)

DSM › Control Panel › Terminal & SNMP › **Enable SSH** (already on).
DSM › Control Panel › User & Group › Advanced › **Enable user home service** (if not on).

From Windows Terminal / PowerShell:

```
ssh YOUR_DSM_USER@192.168.0.41
cd "/volume1/Surveillance/_archiver"
sh install.sh
```

(If `cd` fails, the share is on another volume: `ls -d /volume*/Surveillance`.)

## 2. Sign in (once each, interactive)

```
~/.cam-archiver/venv/bin/python archiver.py login-blink
~/.cam-archiver/venv/bin/python archiver.py login-ring
```

Each asks for e-mail, password and the 2FA code. Ring also prints, per camera,
whether it has **Ring Protect** — without it Ring keeps no recordings and there is
nothing to copy for that camera.

The NAS gets its **own** Blink session; the PC camera helper for SIGMA is
unaffected.

## 3. First run by hand

```
sh run.sh
```

The first run copies the last 30 days (Blink had 400+ clips) — let it finish.
Check `archiver.log` or run `~/.cam-archiver/venv/bin/python archiver.py status`.

## 4. Schedule it

DSM › Control Panel › **Task Scheduler** › Create › Scheduled Task › **User-defined script**

- General: Task `SIGMA cam-archiver`, User **your DSM user** (not root)
- Schedule: Daily, every **15 minutes**, first run 00:00, last run 23:45
- Task Settings › Run command:
  ```
  sh "/volume1/Surveillance/_archiver/run.sh"
  ```
- Optional: Send run details by email › only when the script terminates abnormally.

## Settings (environment variables, set in run.sh)

| Variable | Default | |
|---|---|---|
| `CAM_ARCHIVER_RETENTION_DAYS` | 90 | 0 = keep forever |
| `CAM_ARCHIVER_BACKFILL_DAYS` | 30 | first run only |
| `CAM_ARCHIVER_DEST` | the share this folder is in | |

## When it stops copying

- `archiver.log` says **not signed in / refused the saved session** → run the login
  command again (tokens expire if the job does not run for weeks, or after a
  password change).
- **no Ring Protect plan** → that Ring camera has no cloud recordings.
- Unofficial vendor APIs: Amazon or Ring can change them. Update with
  `~/.local/bin/uv pip install --python ~/.cam-archiver/venv/bin/python -U blinkpy ring_doorbell`.

## Test (on any PC)

```
python test_archiver.py
```
