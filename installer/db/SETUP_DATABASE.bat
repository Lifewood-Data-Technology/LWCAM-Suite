@echo off
setlocal EnableExtensions

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
set "CONFIG=%ROOT%\config\database.txt"
set "DATABASE=%ROOT%\database"
set "READY=%DATABASE%\.setup_ok"
set "LOG=%ROOT%\logs\database-setup.log"
set "OPENLAN="
if /I "%~1"=="--open-lan" set "OPENLAN=--open-lan"

del /q "%READY%" >nul 2>&1
if not exist "%PY%" (
    echo [ERROR] Database Python runtime not found. Run SETUP_DB_RUNTIME.bat first.
    endlocal
    exit /b 1
)
if not exist "%CONFIG%" (
    echo [ERROR] Database configuration not found: %CONFIG%
    endlocal
    exit /b 1
)

"%PY%" "%ROOT%\scripts\setup_qc_db.py" --server-config "%CONFIG%" --database-dir "%DATABASE%" %OPENLAN% > "%LOG%" 2>&1
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo [ERROR] Database setup failed. See "%LOG%".
    endlocal & exit /b %RESULT%
)
> "%READY%" echo ready
echo [DB] Database ready.
endlocal
