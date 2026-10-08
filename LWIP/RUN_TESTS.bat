@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PYTHON_EXE=%ROOT%\runtime\python\python.exe"

if not exist "%PYTHON_EXE%" (
    echo [ERROR] Run SETUP_DESKEW_CROP.bat first.
    pause
    exit /b 1
)

cd /d "%ROOT%\backend"
"%PYTHON_EXE%" -m unittest discover -s tests -v
set "TEST_EXIT=%ERRORLEVEL%"
if not "%TEST_EXIT%"=="0" pause
endlocal & exit /b %TEST_EXIT%
