@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

rem Builds LWIP's private Python runtime from the bundled EMBEDDABLE package.
rem
rem It used to run the full CPython installer (python-3.13.14-amd64.exe) into a
rem private folder and build a venv from it. That is now gone, because the
rem installer refuses to run at all when the machine already has a NEWER 3.13:
rem
rem   Error 0x80070666: Cannot install a product when a newer version is installed.
rem
rem The check is machine-wide, not per-TargetDir, so a private install is refused
rem regardless. Any PC with a Python newer than the bundled one was silently left
rem without an image-processing runtime - and Inno's [Run] discards exit codes, so
rem the install still reported success.
rem
rem The embeddable package has no such problem: it is a folder of files, with no
rem product registration and nothing to conflict with. This mirrors what
rem installer\qc\SETUP_QC.bat already does for the QC backend, which is why that
rem runtime built correctly on the very machine where this one failed.

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PY_DIR=%ROOT%\runtime\python"
set "PY=%PY_DIR%\python.exe"
set "SITE=%PY_DIR%\Lib\site-packages"
set "WHEELS=%ROOT%\wheels"
set "ZIP_NAME=python-3.14.8-embed-amd64.zip"

rem Proof-of-success sentinel, checked by the installer's MissingRuntimes().
rem
rem Inno DISCARDS a [Run] entry's exit code, so every `exit /b 1` below goes
rem nowhere. The installer used to compensate by testing that
rem runtime\python\python.exe exists - but that file is extracted BEFORE any of
rem the work here, so a station whose ._pth was left stock and whose wheels
rem never installed still reported a clean install and then could not process a
rem single image. Deleted first so a sentinel from an earlier, successful run
rem can never vouch for a failed re-run: runtime\ survives an upgrade (it is
rem excluded from [Files]), so a stale one would otherwise persist.
set "SETUP_OK=%ROOT%\runtime\.setup_ok"
if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
del /q "%SETUP_OK%" >nul 2>&1

echo [DeskewCrop] Setup root: %ROOT%

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

rem The standalone LWIP install is its own install root ({autopf}\LWCam LWIP),
rem with the zip shipped once, at that root - no QC or LWCAM sibling to fall
rem back to any more.
set "PY_ZIP="
if exist "%ROOT%\%ZIP_NAME%" set "PY_ZIP=%ROOT%\%ZIP_NAME%"
if not defined PY_ZIP (
    echo [ERROR] Bundled Python runtime not found. Looked for %ZIP_NAME% in:
    echo         %ROOT%
    exit /b 1
)

echo [DeskewCrop] Extracting the private Python runtime.
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
rem drops the current directory from sys.path - so backend is listed explicitly
rem (relative to python.exe) instead of relying on a working directory. LWIP's
rem modules use relative imports, so backend MUST be importable, and a Run-key
rem launch has no working directory at all.
rem
rem ..\..\backend is correct because the depth matches QC's: runtime\python is
rem two levels below LWIP, and backend sits beside runtime.
rem The NAME matters: python314._pth pairs with python314.dll, so it applies to
rem pythonw.exe too - which is what the logon entry launches. Renamed to
rem python._pth, pythonw.exe silently loses every path below and LWIP fails only
rem in the autostart path, never when run from this folder by hand.
> "%PY_DIR%\python314._pth" (
    echo python314.zip
    echo .
    echo Lib\site-packages
    echo ..\..\backend
    echo import site
)

rem cv2.pyd links MSVCP140.dll. Neither the embeddable zip nor the OpenCV wheel
rem carries it (verified), and a clean Windows image has no C++ redistributable
rem either - so `import cv2` would fail on exactly the machines this suite is
rem built for. The installer stages the redistributable's DLLs in runtime\vc,
rem which is not on the DLL search path of an interpreter two folders below -
rem restored here the same way installer\qc\SETUP_QC.bat does for QC.
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

echo [DeskewCrop] Installing bundled offline dependencies.
"%PY%" "%PIP_WHL%\pip" install --disable-pip-version-check --no-index --find-links "%WHEELS%" -r "%ROOT%\requirements.txt"
if errorlevel 1 (
    echo [ERROR] Dependency installation failed.
    exit /b 1
)

if not exist "%ROOT%\runtime\logs" mkdir "%ROOT%\runtime\logs"

rem cd into backend so `import deskew_crop_tool` resolves the same way it will at
rem runtime. opencv under an embeddable interpreter is the one dependency with no
rem precedent in this suite, so this import is the check that it actually loads.
echo [DeskewCrop] Verifying installation.
cd /d "%ROOT%\backend"
"%PY%" -c "import cv2, numpy, PIL, cryptography; import deskew_crop_tool; print('OpenCV', cv2.__version__, '| NumPy', numpy.__version__, '| Pillow', PIL.__version__)"
if errorlevel 1 (
    echo [ERROR] Installation verification failed.
    exit /b 1
)

rem Only now, past the verification import above: the sentinel means "this
rem runtime imported cv2, numpy, Pillow and deskew_crop_tool", not merely
rem "an interpreter was unpacked".
> "%SETUP_OK%" echo ok

echo.
echo [DeskewCrop] Setup completed successfully.
echo.
endlocal
