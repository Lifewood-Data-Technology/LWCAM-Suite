@echo off
setlocal EnableExtensions

rem Build the Database installer's own embeddable Python runtime offline -
rem the same technique as the QC server's SETUP_QC.bat, but this runtime only
rem ever runs setup_qc_db.py, so it needs psycopg and nothing else.
for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "ZIP_NAME=python-3.13.14-embed-amd64.zip"
rem At install the archive sits at ROOT; in a source checkout it sits under vendor.
set "PY_ZIP="
if exist "%ROOT%\%ZIP_NAME%" set "PY_ZIP=%ROOT%\%ZIP_NAME%"
if not defined PY_ZIP if exist "%ROOT%\vendor\%ZIP_NAME%" set "PY_ZIP=%ROOT%\vendor\%ZIP_NAME%"
set "PY_DIR=%ROOT%\runtime\python"
set "PY=%PY_DIR%\python.exe"
set "SITE=%PY_DIR%\Lib\site-packages"
set "SETUP_OK=%ROOT%\runtime\.setup_ok"
set "WHEELS=%ROOT%\wheels"

if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
del /q "%SETUP_OK%" >nul 2>&1

echo [DB] Setup root: %ROOT%

if exist "%PY%" goto python_ready
if not exist "%PY_ZIP%" (
    echo [ERROR] Bundled Python runtime not found: %PY_ZIP%
    exit /b 1
)
echo [DB] Extracting the private Python runtime.
if not exist "%PY_DIR%" mkdir "%PY_DIR%"
"%SystemRoot%\System32\tar.exe" -xf "%PY_ZIP%" -C "%PY_DIR%"
if errorlevel 1 (
    echo [ERROR] Could not extract the private Python runtime.
    exit /b 1
)

:python_ready
rem Restore the staged VC runtime after extraction; psycopg[binary] needs msvcp140.dll.
for %%F in ("%ROOT%\runtime\vc\*.dll") do (
    copy /Y "%%~fF" "%PY_DIR%\" >nul
    if errorlevel 1 (
        echo [ERROR] Could not copy the Visual C++ runtime into Python.
        exit /b 1
    )
)
if not exist "%SITE%" mkdir "%SITE%"
> "%PY_DIR%\python313._pth" (
    echo python313.zip
    echo .
    echo Lib\site-packages
    echo import site
)

set "PIP_WHL="
for %%W in ("%WHEELS%\pip-*.whl") do set "PIP_WHL=%%~fW"
if not defined PIP_WHL (
    echo [ERROR] No pip wheel in %WHEELS%.
    exit /b 1
)

echo [DB] Installing psycopg from the offline wheelhouse.
"%PY%" "%PIP_WHL%\pip" install --disable-pip-version-check --no-index --find-links "%WHEELS%" "psycopg[binary]==3.3.4"
if errorlevel 1 (
    echo [ERROR] Dependency installation failed.
    exit /b 1
)

echo [DB] Verifying the runtime.
cd /d "%ROOT%"
"%PY%" -c "import psycopg; print('Database setup runtime OK')"
if errorlevel 1 (
    echo [ERROR] Runtime verification failed.
    exit /b 1
)

> "%SETUP_OK%" echo ok
echo.
echo [DB] Setup completed successfully.
endlocal
