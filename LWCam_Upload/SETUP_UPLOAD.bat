@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

rem Builds the Upload console's private Python runtime from the bundled
rem EMBEDDABLE package - see LWIP\SETUP_DESKEW_CROP.bat for why this
rem (not the full CPython installer) is what every LWCam offline runtime is
rem built from now: the installer refuses to run at all on a machine that
rem already has a newer 3.13, and Inno's [Run] discards the exit code, so that
rem failure used to look like a clean install.

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY_DIR=%ROOT%\runtime\python"
set "PY=%PY_DIR%\python.exe"
set "SITE=%PY_DIR%\Lib\site-packages"
set "WHEELS=%ROOT%\wheels"
set "ZIP_NAME=python-3.14.8-embed-amd64.zip"

rem Proof-of-success sentinel, checked by the installer. Inno DISCARDS a [Run]
rem entry's exit code, so every `exit /b 1` below goes nowhere on its own;
rem deleted first so a sentinel from an earlier, successful run can never
rem vouch for a failed re-run.
set "SETUP_OK=%ROOT%\runtime\.setup_ok"
if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
del /q "%SETUP_OK%" >nul 2>&1

echo [Upload] Setup root: %ROOT%

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

set "PY_ZIP="
if exist "%ROOT%\%ZIP_NAME%" set "PY_ZIP=%ROOT%\%ZIP_NAME%"
if not defined PY_ZIP (
    echo [ERROR] Bundled Python runtime not found. Looked for %ZIP_NAME% in:
    echo         %ROOT%
    exit /b 1
)

echo [Upload] Extracting the private Python runtime.
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
rem The embeddable package ignores site-packages until its ._pth says so, and
rem it drops the current directory from sys.path - so backend is listed
rem explicitly (relative to python.exe) instead of relying on a working
rem directory, since a scheduled-task launch has none. ..\..\backend is
rem correct because runtime\python sits two levels below LWCam_Upload, and
rem backend sits beside runtime - same depth as LWIP and QC.
> "%PY_DIR%\python314._pth" (
    echo python314.zip
    echo .
    echo Lib\site-packages
    echo ..\..\backend
    echo import site
)

rem psycopg[binary]'s C extension links the Visual C++ runtime, and a clean
rem Windows image has no redistributable installed - so the installer stages
rem it in runtime\vc, restored here the same way LWIP and QC's setup scripts do.
for %%F in ("%ROOT%\runtime\vc\*.dll") do (
    copy /y "%%~fF" "%PY_DIR%" >nul
    if errorlevel 1 (
        echo [ERROR] Could not copy the Visual C++ runtime into Python.
        exit /b 1
    )
)

if not exist "%WHEELS%" (
    echo [ERROR] No wheelhouse at %WHEELS%.
    exit /b 1
)

rem The embeddable package ships without pip, but pip runs straight out of its
rem own wheel via zipimport, which is enough to resolve the vendored wheels
rem offline instead of unpacking them by hand.
set "PIP_WHL="
for %%W in ("%WHEELS%\pip-*.whl") do set "PIP_WHL=%%~fW"
if not defined PIP_WHL (
    echo [ERROR] No pip wheel in %WHEELS%. Re-stage the wheels - see
    echo         docs\RELEASING.md.
    exit /b 1
)

echo [Upload] Installing bundled offline dependencies.
"%PY%" "%PIP_WHL%\pip" install --disable-pip-version-check --no-index --find-links "%WHEELS%" -r "%ROOT%\requirements.txt"
if errorlevel 1 (
    echo [ERROR] Dependency installation failed.
    exit /b 1
)

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

rem cd into backend so `import lwcam_upload` resolves the same way it will at
rem runtime.
echo [Upload] Verifying installation.
cd /d "%ROOT%\backend"
"%PY%" -c "import boto3, psycopg, bcrypt, cryptography; import lwcam_upload; print('boto3', boto3.__version__, '| psycopg', psycopg.__version__, '| bcrypt', bcrypt.__version__)"
if errorlevel 1 (
    echo [ERROR] Installation verification failed.
    exit /b 1
)

rem Only now, past the verification import above: the sentinel means "this
rem runtime imported boto3, psycopg, bcrypt and lwcam_upload", not merely
rem "an interpreter was unpacked".
> "%SETUP_OK%" echo ok

echo.
echo [Upload] Setup completed successfully.
echo.
endlocal
