@echo off
setlocal EnableExtensions

rem First-time setup for the QC backend and/or frontend, offline.
rem
rem Creates a private Python runtime from the bundled embeddable package and
rem installs the vendored wheels. Runtime configuration is written by LWCam
rem Admin to %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json.

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "ZIP_NAME=python-3.13.14-embed-amd64.zip"
rem The zip ships ONCE at the install root now, shared with the LWIP runtime,
rem so it is searched rather than assumed beside this script - which also keeps
rem this working from a source tree, where it sits under vendor\ instead.
set "PY_ZIP="
if exist "%ROOT%\%ZIP_NAME%" set "PY_ZIP=%ROOT%\%ZIP_NAME%"
if not defined PY_ZIP if exist "%ROOT%\..\%ZIP_NAME%" set "PY_ZIP=%ROOT%\..\%ZIP_NAME%"
if not defined PY_ZIP if exist "%ROOT%\vendor\%ZIP_NAME%" set "PY_ZIP=%ROOT%\vendor\%ZIP_NAME%"
set "PY_DIR=%ROOT%\runtime\python"
set "PY=%PY_DIR%\python.exe"
set "SITE=%PY_DIR%\Lib\site-packages"
set "BACKEND=%ROOT%\backend"
rem Proof-of-success sentinel — see the matching block in
rem LWCAM\LWIP\SETUP_DESKEW_CROP.bat for why python.exe's existence is not a
rem usable health check. Deleted first so an earlier run cannot vouch for this
rem one; runtime\ survives an upgrade.
set "SETUP_OK=%ROOT%\runtime\.setup_ok"
set "WHEELS=%BACKEND%\wheels"
set "CACHE=%LOCALAPPDATA%\LWCam\QC"

if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
del /q "%SETUP_OK%" >nul 2>&1

echo [QC] Setup root: %ROOT%

if exist "%PY%" goto python_ready
if not exist "%PY_ZIP%" (
    echo [ERROR] Bundled Python runtime not found: %PY_ZIP%
    exit /b 1
)
echo [QC] Extracting the private Python runtime.
if not exist "%PY_DIR%" mkdir "%PY_DIR%"
rem Full path on purpose: bsdtar ships with Windows, but a Git or MSYS `tar`
rem earlier on PATH reads C:\... as a remote host and fails.
"%SystemRoot%\System32\tar.exe" -xf "%PY_ZIP%" -C "%PY_DIR%"
if errorlevel 1 (
    echo [ERROR] Could not extract the private Python runtime.
    exit /b 1
)

:python_ready
if not exist "%SITE%" mkdir "%SITE%"
rem The embeddable package ignores site-packages until its ._pth says so, and it
rem drops the current directory from sys.path - so the backend package is listed
rem explicitly (relative to python.exe) instead of relying on the launcher's cwd.
> "%PY_DIR%\python313._pth" (
    echo python313.zip
    echo .
    echo Lib\site-packages
    echo ..\..\backend
    echo import site
)

if not exist "%BACKEND%\requirements.txt" (
    echo [QC] Frontend-only install - the stdlib server needs no packages.
    goto verify_frontend
)

rem The embeddable package ships without pip, but pip runs straight out of its
rem own wheel via zipimport, which is enough to resolve the vendored wheels
rem offline instead of unpacking them by hand.
set "PIP_WHL="
for %%W in ("%WHEELS%\pip-*.whl") do set "PIP_WHL=%%~fW"
if not defined PIP_WHL (
    echo [ERROR] No pip wheel in %WHEELS%. Re-stage the wheels with build_installers.ps1.
    exit /b 1
)

echo [QC] Installing bundled offline dependencies.
"%PY%" "%PIP_WHL%\pip" install --disable-pip-version-check --no-index --find-links "%WHEELS%" -r "%BACKEND%\requirements.txt"
if errorlevel 1 (
    echo [ERROR] Dependency installation failed.
    exit /b 1
)

rem Caches under LOCALAPPDATA, not under Program Files: the servers run as a
rem normal user and cannot write beside the program files.
for %%D in (previews qc_work qc_audit) do if not exist "%CACHE%\%%D" mkdir "%CACHE%\%%D"

echo [QC] Verifying the backend runtime.
cd /d "%BACKEND%"
"%PY%" -c "import fastapi, uvicorn, sqlalchemy, psycopg, jwt, bcrypt, PIL, numpy, multipart; print('QC backend runtime OK')"
if errorlevel 1 (
    echo [ERROR] Backend verification failed.
    exit /b 1
)
goto done

:verify_frontend
"%PY%" -c "import http.server; print('QC frontend runtime OK')"
if errorlevel 1 (
    echo [ERROR] Frontend runtime verification failed.
    exit /b 1
)

:done
rem Reached only past a verification import (backend or frontend), so the
rem sentinel means the runtime actually loads its dependencies.
> "%SETUP_OK%" echo ok

echo.
echo [QC] Setup completed successfully.
echo [QC] Configure this PC from LWCam Admin Station Setup.
endlocal
