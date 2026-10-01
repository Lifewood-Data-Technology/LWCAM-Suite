@echo off
setlocal EnableExtensions

rem Scheduled task target for the standalone Upload service ("LWCam Upload",
rem SYSTEM, /SC ONSTART). Modelled on LWIP\START_LWIP.bat: no window, no
rem operator, so every failure has to land in the log rather than a console.

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
set "CONFIG=%ROOT%\config\upload_config.json"

rem Logs first: a boot task has no console, so a check that only echoed would
rem fail with nothing to show for it.
set "LOG=%ROOT%\logs\service.log"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

if not exist "%PY%" (
    >> "%LOG%" echo [ERROR] Upload Python runtime not found. Run SETUP_UPLOAD.bat first.
    exit /b 1
)
if not exist "%CONFIG%" (
    >> "%LOG%" echo [ERROR] Upload configuration not found: "%CONFIG%"
    exit /b 1
)

rem The embeddable runtime's python313._pth already puts ..\..\backend (this
rem folder) on sys.path, so lwcam_upload is importable without a cd - kept
rem anyway to match every other .bat here and give relative work a sane cwd.
cd /d "%ROOT%\backend"
rem A crash (non-zero exit) is logged and restarted after 30 s; exit 0 is a
rem deliberate stop and ends this script. ping, not timeout: timeout fails
rem without a console, which a SYSTEM boot task never has. The installers end
rem the task (killing this script) before they kill python, so an upgrade or
rem uninstall cannot be undone by this loop. service.log is rolled to
rem service.log.1 (replacing the old one) when it passes 10 MB, before each start.
:run
if exist "%LOG%" for %%F in ("%LOG%") do if %%~zF GTR 10485760 (del "%LOG%.1" 2>nul & ren "%LOG%" service.log.1)
"%ROOT%\runtime\python\python.exe" -m lwcam_upload --config "%CONFIG%" >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto :done
>> "%LOG%" echo [%DATE% %TIME%] service exited with code %RC%, restarting in 30 s
ping -n 31 127.0.0.1 >nul
goto :run
:done
endlocal & exit /b 0
