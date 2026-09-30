@echo off
rem Double-click launcher for dns-bench.ps1
rem Runs DNS benchmark with bypass execution policy without altering system settings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dns-bench.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
pause
exit /b %EXITCODE%
