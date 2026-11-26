@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash-sbe1v1k.ps1" %*
echo.
pause
