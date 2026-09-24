@echo off
setlocal EnableExtensions

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
cd /d "%ROOT%\backend"
"%PY%" "%ROOT%\backend\run_server.py" >> "%ROOT%\logs\server.log" 2>&1
endlocal & exit /b %ERRORLEVEL%