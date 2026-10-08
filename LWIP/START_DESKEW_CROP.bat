@echo off
setlocal EnableExtensions
rem The private runtime must never see a per-user site-packages (whoever runs setup may have
rem their own Python of the same version): pip would skip packages and the runtime break.
set "PYTHONNOUSERSITE=1"

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PYTHON_EXE=%ROOT%\runtime\python\python.exe"
rem The standalone install owns exactly one config, written by the installer
rem and otherwise edited by hand - see config\deskew_crop_config.json. There
rem is no separate Station Setup copy any more; the scheduled task "LWCam LWIP"
rem (START_LWIP.bat) reads this same file.
set "TOOL_CONFIG=%ROOT%\config\deskew_crop_config.json"

if not exist "%PYTHON_EXE%" (
    echo [ERROR] The private Python runtime was not found.
    echo         Run SETUP_DESKEW_CROP.bat first.
    pause
    exit /b 1
)

if not exist "%TOOL_CONFIG%" (
    echo [ERROR] Configuration not found:
    echo         %TOOL_CONFIG%
    pause
    exit /b 1
)

echo [DeskewCrop] Starting folder orchestrator.
echo [DeskewCrop] Configuration: %TOOL_CONFIG%
cd /d "%ROOT%\backend"
"%PYTHON_EXE%" -m deskew_crop_tool --config "%TOOL_CONFIG%" %*

if errorlevel 1 (
    echo.
    echo [ERROR] The orchestrator stopped with an error.
    pause
)

endlocal
