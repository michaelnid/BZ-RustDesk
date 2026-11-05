@echo off
rem BZ RustDesk Server - Deploy (Windows): startet deploy.ps1, auch wenn die
rem PowerShell-Ausführungsrichtlinie Scripts blockiert (Bypass gilt nur für diesen Aufruf).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
exit /b %ERRORLEVEL%
