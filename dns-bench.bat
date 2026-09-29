@echo off
rem Wrapper klik-dua-kali untuk dns-bench.ps1
rem Menjalankan benchmark DNS dengan execution policy bypass tanpa mengubah setting sistem.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dns-bench.ps1" %*
pause
