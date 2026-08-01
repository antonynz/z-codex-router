@echo off
:: z-codex-router-entrypoint-v1
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0zcr.ps1" %*
exit /b %ERRORLEVEL%
