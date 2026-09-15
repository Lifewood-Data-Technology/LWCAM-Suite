@echo off
setlocal EnableExtensions

for %%I in ("%~dp0.") do set "ROOT=%%~fI"
set "PYTHON_EXE=%ROOT%\runtime\python\python.exe"
set "TOOL_CONFIG=%ROOT%\config\deskew_crop_config.json"

rem Station Setup owns the real configuration and writes it here. Prefer it,
rem so a manual run uses the same crop padding, folders and quality as the
rem LWIP service does. The bundled config\ copy is only the fallback for a
rem machine that has never had Station Setup run on it.
set "STATION_CONFIG=%USERPROFILE%\LWCAM_DBs\lwip\deskew_crop_config.json"
if exist "%STATION_CONFIG%" set "TOOL_CONFIG=%STATION_CONFIG%"

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
