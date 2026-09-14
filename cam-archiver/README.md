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
  _archiver\            <- this folder (code, run.sh, archiver.log, install.log)
```

Existing folders in the share (e.g. `FLoodLight Rear Cam`) are never touched.
No Docker, **no SSH**, nothing system-wide.

## 1. Sign in (once) — on the PC

Double-click **`login-on-pc.cmd`** (in `sigma-deploy\cam-archiver` on the PC).
It asks for the Blink e-mail, password and 2FA code, then the same for Ring.
Passwords are used once and never saved. Only tokens are written, into your
**private** NAS home folder `\\Zencave\home\.cam-archiver` — not into the
Surveillance share, where anyone with access could read them.

Ring prints, per camera, whether it has **Ring Protect** — without it Ring keeps
no recordings for that camera and there is nothing to copy.

The NAS gets its **own** Blink session; the SIGMA camera helper is unaffected.

## 2. Schedule it — in DSM

DSM › Control Panel › **Task Scheduler** › Create › Scheduled Task › **User-defined script**

- **General:** Task `SIGMA cam-archiver`. User: **greg** if listed, otherwise **root**.
- **Schedule:** Run on the following days: Daily. Time: first run `00:00`,
  Frequency **every 15 minutes**, last run `23:45`.
- **Task Settings › Run command:**
  ```
  sh "$(ls -d /volume*/Surveillance/_archiver | head -1)/run.sh"
  ```
- Save. Select the task › **Run** once to start now.

The first run installs Python and the libraries into `_archiver\.runtime`
(a few minutes, see `install.log`), then copies the last 30 days of clips
(`archiver.log`). Later runs take seconds.

> If the task runs as **root**: anyone who can WRITE to the Surveillance share
> could change `run.sh` and have it run as root. Keep write access to that share
> limited to admins, or run the task as your own user.

If your DSM user is not called `greg`, add `ARCHIVER_OWNER=youruser ` in front of
`sh` in the run command.

## Settings

Set in front of `sh` in the run command, e.g. `CAM_ARCHIVER_RETENTION_DAYS=180 sh …`

| Variable | Default | |
|---|---|---|
| `CAM_ARCHIVER_RETENTION_DAYS` | 90 | 0 = keep forever |
| `CAM_ARCHIVER_BACKFILL_DAYS` | 30 | first run only |
| `ARCHIVER_OWNER` | greg | whose home folder holds the tokens |

## When it stops copying

- `archiver.log` says **not signed in / refused the saved session** → double-click
  `login-on-pc.cmd` again (tokens lapse if the job does not run for weeks, or after
  a password change).
- **no Ring Protect plan** → that Ring camera has no cloud recordings.
- **install failed** → read `install.log`.
- Unofficial vendor APIs: Amazon or Ring can change them. Delete `_archiver\.runtime`
  and the next run reinstalls the latest pinned libraries.

## Test (on any PC)

```
python test_archiver.py
```
