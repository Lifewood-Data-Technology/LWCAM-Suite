@echo off
setlocal EnableExtensions

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
set "CONFIG=%ROOT%\config\database.txt"
set "DATABASE=%ROOT%\database"
set "READY=%DATABASE%\.setup_ok"
set "LOG=%ROOT%\logs\database-setup.log"
rem Extra flags from the installer: --open-lan, --close-lan.
set "EXTRA=%*"
rem The shared LWCam login is appUser / appPassword in database.txt. appPassword is
rem DPAPI-encrypted there; setup_qc_db.py decrypts it itself (the LWCAM_APP_PASSWORD
rem environment variable, which the installer sets for its own run, wins). It is
rem never echoed and never on a command line.

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

set "APPUSER="
for /f "usebackq tokens=1,* delims== " %%A in (`findstr /b /c:"appUser" "%CONFIG%"`) do set "APPUSER=%%B"
if not defined APPUSER (
    echo [ERROR] appUser is missing from %CONFIG%. Run LWCamDatabaseSetup again and fill in the LWCam database login page.
    endlocal
    exit /b 1
)
"%PY%" "%ROOT%\scripts\setup_qc_db.py" --server-config "%CONFIG%" --database-dir "%DATABASE%" --app-login "%APPUSER%" %EXTRA% > "%LOG%" 2>&1
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo [ERROR] Database setup failed. See "%LOG%".
    endlocal & exit /b %RESULT%
)
> "%READY%" echo ready
echo [DB] Database ready.
endlocal
