@echo off
cd /d "%~dp0"
echo.
echo   today-tasks widget (Windows)
echo   needs the local server running; start it first if the window is empty
echo.
powershell -sta -NoProfile -ExecutionPolicy Bypass -File "desktop-widget.ps1"
echo.
echo   widget closed. check trace.log / error.log in this folder if it did not appear.
pause
