@echo off
setlocal
rem Adds this LWCam server's certificate to YOUR Windows account, so its web pages
rem (https://...) open in the browser without a warning. No administrator needed.
rem Keep this file and "LWCam server certificate.crt" together.
set "CRT=%~dp0LWCam server certificate.crt"
if not exist "%CRT%" (
    echo Could not find "LWCam server certificate.crt" next to this file.
    echo Copy both files together and run this again.
    pause
    exit /b 1
)
certutil -user -addstore Root "%CRT%" >nul
if errorlevel 1 (
    echo.
    echo That did not work. Close and reopen this window, then try again.
    echo If it still fails, ask your administrator for help.
    pause
    exit /b 1
)
echo.
echo Done. This PC now trusts the LWCam server.
echo Close your browser completely and open it again, then use the https:// address.
echo Windows may ask you to confirm once - choose Yes.
echo.
echo Chrome and Edge are covered. FIREFOX has its own store: Settings, Privacy and
echo Security, Certificates, View Certificates, Authorities, Import this .crt file,
echo and tick "Trust this CA to identify websites".
pause
