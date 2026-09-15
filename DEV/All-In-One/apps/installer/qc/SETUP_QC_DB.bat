@echo off
setlocal EnableExtensions

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
if defined LWCAM_NODE_CONFIG (
    set "CONFIG=%LWCAM_NODE_CONFIG%"
) else (
    set "CONFIG=%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json"
)

if not exist "%PY%" (
    echo [ERROR] QC Python runtime not found. Reinstall the QC backend.
    endlocal
    exit /b 1
)

"%PY%" "%ROOT%\setup_qc_db.py" --config "%CONFIG%" --database-dir "%ROOT%\database"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%
