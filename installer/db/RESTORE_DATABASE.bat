@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

rem Restore the LWCam database from a backup made by BACKUP_DATABASE.bat.
rem   RESTORE_DATABASE.bat "D:\LWCam Backups\lwcam-20260930-0200.dump" [/y]
rem Run as Administrator. Replaces the CURRENT contents of the database, in ONE
rem transaction (a failed restore changes nothing). A safety dump of the current
rem database (pre-restore-YYYYMMDD-HHMM.dump, in the backup folder) is taken first.
rem Roles/logins are NOT in the .dump: to rebuild on a NEW PC apply the matching
rem lwcam-globals-*.sql first (see docs\INSTALL.md, "Backups and restore").
for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY=%ROOT%\runtime\python\python.exe"
set "FILE=%~1"
set "CONFIRM=%~2"

fltmc >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run this as Administrator.
    endlocal & exit /b 1
)
if "%FILE%"=="" (
    echo Usage: RESTORE_DATABASE.bat "path\to\lwcam-YYYYMMDD-HHMM.dump" [/y]
    endlocal & exit /b 1
)
if not exist "%FILE%" (
    echo [ERROR] Backup file not found: "%FILE%"
    endlocal & exit /b 1
)
if not exist "%PY%" (
    echo [ERROR] Database Python runtime not found: "%PY%"
    endlocal & exit /b 1
)
if /i not "%CONFIRM%"=="/y" (
    echo This REPLACES the current LWCam database with:
    echo   "%FILE%"
    echo Anything saved after that backup was made is lost.
    echo.
    echo Every OTHER PC that uses this database - capture PCs, and QC/LWIP/Upload if
    echo they run on other PCs - must be stopped or paused first: a restore under a
    echo running service corrupts its work or fails on open connections.
    set "ANSWER="
    set /p "ANSWER=Type YES to continue: "
    if not "%ANSWER%"=="YES" (
        echo Cancelled.
        endlocal & exit /b 1
    )
)

echo Stopping the LWCam services on this PC (only those running^)...
set "WAS=|"
call :stoptask "LWCam QC Server"
call :stoptask "LWCam LWIP"
call :stoptask "LWCam Upload"
if not "%WAS%"=="|" timeout /t 5 /nobreak >nul

rem backup_db.py --restore: safety dump first (a failure restores NOTHING), then pg_restore in ONE
rem transaction. The password is decrypted from database.txt into that child's environment only.
"%PY%" "%ROOT%\scripts\backup_db.py" --restore "%FILE%"
set "RESULT=%ERRORLEVEL%"

echo Starting again the services that were running...
call :starttask "LWCam QC Server"
call :starttask "LWCam LWIP"
call :starttask "LWCam Upload"

if "%RESULT%"=="2" (
    echo [ERROR] The safety dump failed, so NOTHING was restored. See logs\backup.log.
) else if not "%RESULT%"=="0" (
    echo [ERROR] pg_restore failed (exit %RESULT%^). The restore ran as one transaction, so the
    echo         database is unchanged. The safety dump is in the backup folder if you need it.
    echo         Details: logs\backup.log.
) else (
    echo [DB] Restore finished. Now start the services on the other PCs.
)
endlocal & exit /b %RESULT%

:stoptask
schtasks /Query /TN %1 /FO CSV /NH 2>nul | findstr /i "Running" >nul
if errorlevel 1 goto :eof
schtasks /End /TN %1 >nul 2>&1
set "WAS=%WAS%%~1|"
goto :eof

:starttask
setlocal EnableDelayedExpansion
set "T=%~1"
if not "!WAS:|%T%|=!"=="!WAS!" schtasks /Run /TN "%T%" >nul 2>&1
endlocal
goto :eof
