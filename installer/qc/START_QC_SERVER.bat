@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
if not exist "%PY%" (
    echo [ERROR] QC Python runtime not found. Run SETUP_QC.bat first.
    exit /b 1
)
if not exist "%ROOT%\config\config.txt" (
    echo [ERROR] QC configuration not found: "%ROOT%\config\config.txt"
    exit /b 1
)

set "LWCAM_QC_SERVER_CONFIG=%ROOT%\config\config.txt"
set "CONSOLE=%ROOT%\logs\console.log"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"
cd /d "%ROOT%\backend"
rem A crash (non-zero exit) is logged and restarted after 30 s; exit 0 is a
rem deliberate stop and ends this script. ping, not timeout: timeout fails
rem without a console, which a SYSTEM boot task never has. The installers end
rem the task (killing this script) before they kill python, so an upgrade or
rem uninstall cannot be undone by this loop.
rem The server writes its own rotating logs\server.log (run_server.py); what
rem python prints to stdout/stderr (startup lines, crash tracebacks) goes to
rem logs\console.log, rolled to console.log.1 here when it passes 10 MB.
:run
if exist "%CONSOLE%" for %%F in ("%CONSOLE%") do if %%~zF GTR 10485760 move /y "%CONSOLE%" "%CONSOLE%.1" >nul
"%PY%" "%ROOT%\backend\run_server.py" >> "%CONSOLE%" 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto :done
>> "%CONSOLE%" echo [%DATE% %TIME%] service exited with code %RC%, restarting in 30 s
ping -n 31 127.0.0.1 >nul
goto :run
:done
endlocal & exit /b 0
