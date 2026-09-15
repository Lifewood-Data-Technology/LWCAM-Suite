@echo off
setlocal EnableExtensions

rem Serves the prebuilt QC console on port 5174 and proxies /api to the backend,
rem using serve_frontend.py (standard library only - no Node on this PC).
rem
rem When the backend runs on another machine, pass its address:
rem   START_QC_FRONTEND.bat --api-target http://10.0.0.5:8080

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"

if not exist "%PY%" (
    echo [ERROR] The private Python runtime was not found.
    echo         Run SETUP_QC.bat first.
    pause
    exit /b 1
)
if not exist "%ROOT%\dist\index.html" (
    echo [ERROR] The frontend bundle is missing: %ROOT%\dist
    pause
    exit /b 1
)

echo [QC] Console on http://0.0.0.0:5174
"%PY%" "%ROOT%\serve_frontend.py" --dist "%ROOT%\dist" --host 0.0.0.0 --port 5174 --api-target http://127.0.0.1:8080 %*

if errorlevel 1 (
    echo.
    echo [ERROR] The frontend server stopped with an error.
    pause
)

endlocal
