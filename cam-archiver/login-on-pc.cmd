@echo off
REM ============================================================================
REM  SIGMA cam-archiver -- ONE-TIME sign-in, run on this PC (no SSH needed).
REM  Signs in to Blink and Ring with e-mail, password and 2FA code. Passwords are
REM  used once and NOT saved; only tokens are written, into your PRIVATE NAS home
REM  folder \\Zencave\home\.cam-archiver, where the NAS job picks them up.
REM ============================================================================
cd /d "%~dp0"
set "CAM_ARCHIVER_HOME=\\Zencave\home\.cam-archiver"

if not exist ".venv-pc\Scripts\python.exe" (
  echo Preparing Python on this PC ...
  py -3.12 -m venv .venv-pc || python -m venv .venv-pc
  ".venv-pc\Scripts\python.exe" -m pip install -q -r requirements.txt
)

if not exist "\\Zencave\home\" (
  echo.
  echo   Cannot reach \\Zencave\home -- is the NAS on and are you signed in to it in Explorer?
  pause
  exit /b 1
)

echo.
echo ======================= 1 of 2 : BLINK =======================
".venv-pc\Scripts\python.exe" archiver.py login-blink
echo.
echo ======================= 2 of 2 : RING ========================
echo (Press Ctrl+C to skip Ring if you do not want it.)
".venv-pc\Scripts\python.exe" archiver.py login-ring
echo.
".venv-pc\Scripts\python.exe" archiver.py status
echo.
echo Done. Tell Claude "signed in".
pause
