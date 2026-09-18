@echo off
rem today-tasks launcher (Windows / macOS / Linux all have their own; see start.sh)
rem
rem What this does:
rem   1. runs the local server in a minimized window
rem   2. pops the desktop widget from THIS process
rem
rem Why step 2 matters: the widget must be started from a normal desktop session.
rem If the server process starts it instead, and that server happens to run under a
rem service/sandbox/other session, the window is created on an invisible window
rem station -- the log says "window shown" but you never see it. Starting it from
rem the shortcut you double-clicked avoids that whole class of problem.

cd /d "%~dp0"

echo.
echo   today-tasks
echo.
echo   web UI :  http://127.0.0.1:17850/
echo   server :  runs in a minimized window -- close that window to stop it
echo.

start "" /min python server.py --no-open --no-widget

rem give the server a moment to bind the port
ping -n 3 127.0.0.1 >nul

start "" powershell -sta -NoProfile -ExecutionPolicy Bypass -File "desktop\desktop-widget.ps1"

echo   widget launched. this window closes by itself.
ping -n 4 127.0.0.1 >nul
exit
