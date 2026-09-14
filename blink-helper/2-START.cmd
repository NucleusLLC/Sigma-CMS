@echo off
REM ============================================================================
REM  STEP 2 of 2 -- bring the cameras online.  Run this whenever you want the
REM  Blink tiles to work in SIGMA. It starts the helper, opens an https:// tunnel
REM  and prints the FULL address (including the secret /k/... key) for SIGMA.
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

REM The key is the secret part of the address. Created once, reused after.
if not exist helper-key.txt ".venv\Scripts\python.exe" -c "import blink_helper; blink_helper.load_key()"
set /p HELPERKEY=<helper-key.txt

REM Already running? Do not start a second helper on the same port.
powershell -NoProfile -Command "try{ $c=New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',8765); $c.Close(); exit 0 }catch{ exit 1 }"
if errorlevel 1 (
  echo Starting the Blink helper on http://127.0.0.1:8765 ...
  start "SIGMA Blink helper" /min ".venv\Scripts\python.exe" blink_helper.py
) else (
  echo The Blink helper is already running on port 8765 -- not starting another.
)

if exist tunnel.yml (
  REM Fixed address: a named Cloudflare tunnel (see README, "Fixed address").
  for /f "tokens=2" %%H in ('findstr /b /c:"# hostname:" tunnel.yml') do set CAMHOST=%%H
  echo.
  echo ============================================================================
  echo   SIGMA address ^(the same every time -- paste it once^):
  echo.
  echo      https://%CAMHOST%/k/%HELPERKEY%
  echo.
  echo ============================================================================
  echo.
  cloudflared.exe tunnel --config tunnel.yml run
  goto :eof
)

REM Temporary address: a quick tunnel. The hostname changes on every start, so
REM a watcher asks cloudflared for it and prints the full SIGMA address.
echo Opening a temporary https:// tunnel ...
start "" /b powershell -NoProfile -Command "for($i=0;$i -lt 60;$i++){ Start-Sleep 1; try{ $h=(Invoke-RestMethod http://127.0.0.1:20299/quicktunnel -TimeoutSec 2).hostname; if($h){ Write-Host ''; Write-Host '============================================================================'; Write-Host '  PASTE THIS into SIGMA: Dashboard > CAM Security > SETUP > Blink helper address'; Write-Host ''; Write-Host ('     https://' + $h + '/k/%HELPERKEY%'); Write-Host ''; Write-Host '  It changes every time this window is restarted.'; Write-Host '============================================================================'; break } }catch{} }"
cloudflared.exe tunnel --metrics 127.0.0.1:20299 --url http://localhost:8765
