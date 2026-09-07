@echo off
REM ============================================================================
REM  STEP 1 of 2 -- sign in to Blink.  Run this ONCE.
REM  You will be asked for your Blink (Amazon) e-mail, password and 2FA code.
REM  These are entered HERE, at your terminal, and never leave this machine
REM  except to Amazon's own login. A session token is written to creds.json.
REM ============================================================================
cd /d "%~dp0"
".venv\Scripts\python.exe" login.py
echo.
echo If you saw "creds.json written" above, you are done with step 1.
echo Next, double-click  2-START.cmd  to bring the cameras online.
pause
