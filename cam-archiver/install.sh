#!/bin/sh
# SIGMA cam-archiver — installer for a Synology NAS (DSM 7). No Docker, no SSH.
#
# Normally you never run this yourself: run.sh calls it the first time DSM Task
# Scheduler starts the job, and writes its output to install.log in this folder.
#
# Everything goes into .runtime/ next to this file — uv, a Python 3.12 and a
# venv with blinkpy + ring_doorbell. Nothing system-wide, nothing in /root or a
# home folder, so it works whether the task runs as root or as a DSM user
# (DSM ships Python 3.9; blinkpy needs 3.10+).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="$HERE/.runtime"
export UV_INSTALL_DIR="$RT/bin"
export UV_PYTHON_INSTALL_DIR="$RT/python"
export UV_CACHE_DIR="$RT/cache"
export UV_NO_MODIFY_PATH=1
export HOME="${HOME:-$RT}"

echo "=== install $(date '+%Y-%m-%d %H:%M:%S') as $(id -un) on $(uname -m) in $HERE"
mkdir -p "$RT"

if [ ! -x "$RT/bin/uv" ]; then
  echo "installing uv into $RT/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

echo "installing Python 3.12"
"$RT/bin/uv" python install 3.12
"$RT/bin/uv" venv --allow-existing --python 3.12 "$RT/venv"
echo "installing blinkpy + ring_doorbell"
"$RT/bin/uv" pip install --python "$RT/venv/bin/python" -r "$HERE/requirements.txt"

"$RT/venv/bin/python" -c "import blinkpy, ring_doorbell; print('libraries OK')"
echo "=== install finished"
