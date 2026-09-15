@echo off
setlocal EnableExtensions

rem Starts the QC backend on port 8080 using the private runtime built by
rem SETUP_QC.bat. Pass extra uvicorn arguments through, e.g.
rem   START_QC_BACKEND.bat --port 9090

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"

if not exist "%PY%" (
    echo [ERROR] The private Python runtime was not found.
    echo         Run SETUP_QC.bat first.
    pause
    exit /b 1
)
if not defined LWCAM_NODE_CONFIG set "LWCAM_NODE_CONFIG=%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json"
if not exist "%LWCAM_NODE_CONFIG%" (
    echo [ERROR] LWCam configuration not found: %LWCAM_NODE_CONFIG%
    echo         Open LWCam Admin and complete Station Setup first.
    pause
    exit /b 1
)

cd /d "%ROOT%\backend"
echo [QC] Backend starting on port 8080 unless overridden above. API docs at /docs.
"%PY%" -m uvicorn app.main:app --host 127.0.0.1 --port 8080 %*

if errorlevel 1 (
    echo.
    echo [ERROR] The backend stopped with an error.
    pause
)

endlocal
