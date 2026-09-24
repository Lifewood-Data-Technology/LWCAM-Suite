@echo off
if not exist "%~dp0server.log" (
    echo QC server log does not exist yet.
    pause
    exit /b 0
)
start "" notepad.exe "%~dp0server.log"