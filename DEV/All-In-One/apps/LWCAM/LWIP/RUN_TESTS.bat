@echo off
setlocal EnableExtensions

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
