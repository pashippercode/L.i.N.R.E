@echo off
rem ===========================================================================
rem  Irmia Agent v@@VERSION@@ win-x64 portable package - entry point
rem  Double-click this file. All real work is in start.ps1 next to it.
rem
rem  Two deliberate choices here:
rem   1) ASCII-only text: a fresh Windows console code page is not UTF-8, so any
rem      Chinese written in a .cmd shows up as mojibake. start.ps1 prints all
rem      the Chinese messages instead.
rem   2) Absolute path to powershell.exe (with a bare-name fallback): PATH on a
rem      tester machine is not ours to trust.
rem ===========================================================================
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [launcher] exited with code %RC% - see the messages above.
  echo [launcher] press any key to close this window.
  pause >nul
)
endlocal
