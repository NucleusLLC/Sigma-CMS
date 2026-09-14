@echo off
REM ============================================================================
REM  STEP 3 (optional) -- sign the camera helper in to RING, once.
REM  E-mail, password and the 2FA code are typed here. The password is NOT saved;
REM  only a token, in ring-session\ring.json (git-ignored). This is the helper's
REM  OWN Ring sign-in, separate from the NAS archiver's, on purpose: Ring rotates
REM  tokens and two programs sharing one would sign each other out.
REM ============================================================================
cd /d "%~dp0"
set "CAM_ARCHIVER_HOME=%~dp0ring-session"
".venv\Scripts\python.exe" "..\cam-archiver\archiver.py" login-ring
echo.
echo Done. Ring cameras now appear in SIGMA ^> CAM Security as "Ring - name". Tell Claude "ring done".
pause