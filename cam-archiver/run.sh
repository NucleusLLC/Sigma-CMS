#!/bin/sh
# SIGMA cam-archiver — the ONE command DSM Task Scheduler runs every 15 minutes:
#
#     sh "$(ls -d /volume*/Surveillance/_archiver | head -1)/run.sh"
#
# First run: installs itself (install.log). Every run: copies new Blink/Ring clips
# into the Surveillance share and prunes old ones (archiver.log).

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/.runtime/venv/bin/python"

# Whose private NAS home folder holds the sign-in tokens (written there from the
# PC by login-on-pc.cmd, via \\Zencave\home\.cam-archiver).
ARCHIVER_OWNER="${ARCHIVER_OWNER:-greg}"

if [ ! -x "$PY" ]; then
  sh "$HERE/install.sh" >> "$HERE/install.log" 2>&1 || { echo "install failed — see install.log"; exit 1; }
fi

if [ -z "$CAM_ARCHIVER_HOME" ]; then
  OWNER_HOME="$(ls -d /volume*/homes/"$ARCHIVER_OWNER" 2>/dev/null | head -1)"
  if [ -z "$OWNER_HOME" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') no home folder for $ARCHIVER_OWNER under /volume*/homes" >> "$HERE/archiver.log"
    exit 1
  fi
  export CAM_ARCHIVER_HOME="$OWNER_HOME/.cam-archiver"
fi

exec "$PY" "$HERE/archiver.py" run
