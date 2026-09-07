@echo off
REM ============================================================================
REM  STEP 2 of 2 -- bring the cameras online.  Run this whenever you want the
REM  Blink tiles to work in SIGMA. It starts the helper and opens an https://
REM  tunnel, then prints the address to paste into SIGMA.
REM  Leave this window OPEN while you use the cameras. Close it to stop them.
REM ============================================================================
cd /d "%~dp0"

if not exist creds.json (
  echo.
  echo   creds.json not found -- run  1-LOGIN.cmd  first to sign in to Blink.
  echo.
  pause
  exit /b 1
)

echo Starting the Blink helper on http://127.0.0.1:8765 ...
start "SIGMA Blink helper" /min ".venv\Scripts\python.exe" blink_helper.py

echo Opening the https:// tunnel (this prints a trycloudflare.com address) ...
echo.
echo ============================================================================
echo   COPY the https://SOMETHING.trycloudflare.com line below, then in SIGMA:
echo   Dashboard -^> CAM Security -^> SETUP -^> Blink helper address -^> paste -^> Test
echo   Then on the tab, under BLINK -- CLOUD, press CONNECT and OPEN each camera.
echo ============================================================================
echo.
cloudflared.exe tunnel --url http://localhost:8765
