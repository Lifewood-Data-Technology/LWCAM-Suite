@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

rem Build the QC server's embeddable Python runtime offline.
for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "ZIP_NAME=python-3.14.8-embed-amd64.zip"
rem At install the archive sits at ROOT; in a source checkout it sits under vendor.
set "PY_ZIP="
if exist "%ROOT%\%ZIP_NAME%" set "PY_ZIP=%ROOT%\%ZIP_NAME%"
if not defined PY_ZIP if exist "%ROOT%\vendor\%ZIP_NAME%" set "PY_ZIP=%ROOT%\vendor\%ZIP_NAME%"
set "PY_DIR=%ROOT%\runtime\python"
set "PY=%PY_DIR%\python.exe"
set "SITE=%PY_DIR%\Lib\site-packages"
set "BACKEND=%ROOT%\backend"
set "SETUP_OK=%ROOT%\runtime\.setup_ok"
set "WHEELS=%BACKEND%\wheels"

if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
del /q "%SETUP_OK%" >nul 2>&1

echo [QC] Setup root: %ROOT%

rem A runtime of another Python version (an upgrade from 3.13) is rebuilt, not reused:
rem the bundled wheels are built for 3.14 only.
if exist "%PY%" (
    "%PY%" -c "import sys; raise SystemExit(sys.version_info[:2] != (3, 14))" >nul 2>&1
    if errorlevel 1 rmdir /s /q "%PY_DIR%"
)
if exist "%PY%" if not exist "%PY_DIR%\python314.dll" (
    echo [ERROR] The old Python runtime in %PY_DIR% could not be removed. Close what uses it and run setup again.
    exit /b 1
)
if exist "%PY%" goto python_ready
if not exist "%PY_ZIP%" (
    echo [ERROR] Bundled Python runtime not found: %PY_ZIP%
    exit /b 1
)
echo [QC] Extracting the private Python runtime.
if not exist "%PY_DIR%" mkdir "%PY_DIR%"
"%SystemRoot%\System32\tar.exe" -xf "%PY_ZIP%" -C "%PY_DIR%"
if errorlevel 1 (
    echo [ERROR] Could not extract the private Python runtime.
    exit /b 1
)

:python_ready
rem Restore the staged VC runtime after extraction; OpenCV needs msvcp140.dll.
for %%F in ("%ROOT%\runtime\vc\*.dll") do (
    copy /Y "%%~fF" "%PY_DIR%\" >nul
    if errorlevel 1 (
        echo [ERROR] Could not copy the Visual C++ runtime into Python.
        exit /b 1
    )
)
if not exist "%SITE%" mkdir "%SITE%"
> "%PY_DIR%\python314._pth" (
    echo python314.zip
    echo .
    echo Lib\site-packages
    echo ..\..\backend
    echo import site
)

if not exist "%BACKEND%\requirements.txt" (
    echo [ERROR] QC backend requirements.txt is missing.
    exit /b 1
)

set "PIP_WHL="
for %%W in ("%WHEELS%\pip-*.whl") do set "PIP_WHL=%%~fW"
if not defined PIP_WHL (
    echo [ERROR] No pip wheel in %WHEELS%.
    exit /b 1
)

echo [QC] Installing bundled offline dependencies.
"%PY%" "%PIP_WHL%\pip" install --disable-pip-version-check --no-index --find-links "%WHEELS%" -r "%BACKEND%\requirements.txt"
if errorlevel 1 (
    echo [ERROR] Dependency installation failed.
    exit /b 1
)

echo [QC] Verifying the backend runtime.
cd /d "%BACKEND%"
"%PY%" -c "import fastapi, uvicorn, sqlalchemy, psycopg, jwt, bcrypt, PIL, numpy, multipart, cryptography; print('QC backend runtime OK')"
if errorlevel 1 (
    echo [ERROR] Backend verification failed.
    exit /b 1
)

> "%SETUP_OK%" echo ok
echo.
echo [QC] Setup completed successfully.
echo [QC] Server settings are stored in config\config.txt under the QC Platform folder.
endlocal