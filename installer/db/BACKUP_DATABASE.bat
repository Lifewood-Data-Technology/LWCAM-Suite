@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

rem Nightly (and on-demand) database backup. Run by the "LWCam Database Backup"
rem scheduled task as SYSTEM; safe to run by hand as Administrator too.
for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
if not exist "%PY%" (
    echo [ERROR] Database Python runtime not found: %PY%
    endlocal & exit /b 1
)
"%PY%" "%ROOT%\scripts\backup_db.py"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%
