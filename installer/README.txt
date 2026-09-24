LWCam installers
================

This folder builds two Windows installers from the source tree:

  LWCamSetup.exe       LWCam Capture, LWCam Admin, and LWIP
  QCPlatformSetup.exe  Standalone QC server, Vue console, export, and upload

Both can install PostgreSQL 18 when a local server is needed, or use an existing
server on another PC. The PostgreSQL installer is a separate file beside each
setup executable. Ship the setup executable and the PostgreSQL installer
together; a PC that already has PostgreSQL needs only the setup executable.

Build
-----

Prerequisites:

  Inno Setup 6
  Flutter release build output for LWCAM and LWCamAdmin
  Node.js and npm
  The staged, gitignored inputs listed below

Build the Flutter apps:

  cd ..\LWCAM      && flutter build windows --release
  cd ..\LWCamAdmin && flutter build windows --release

Compile one installer or both:

  .\build-installer.ps1 -Target LWCam
  .\build-installer.ps1 -Target QC
  .\build-installer.ps1 -Target All

The QC target runs npm run build in LWCam_QC_Platform\frontend before compiling.
Outputs land at the repository root, beside LWCAM\ and installer\. The script
checks each target's release/build inputs and copies the newest staged
postgresql-18.*-windows-x64.exe beside the setup outputs. It does not run an
installer.

Use -ResolveOnly to print the selected ISCC and scrcpy paths without building.
The LWCam target uses LWCAM\scrcpy when it contains scrcpy.exe, or resolves the
installed scrcpy package. Pass -ScrcpyDir to select another Windows build.

Products
--------

LWCamSetup.exe

  Installs LWCam Capture and LWCam Admin with LWIP, adb, scrcpy, and the
  database setup script plus the shared SQL migrations. It keeps the shipped
  AppId so an existing LW Suite install upgrades in place. Admin has a
  Start-menu shortcut only; LWCAM has a Start-menu and desktop shortcut.

  The former {app}\QC engine is stopped and removed during upgrade. Existing
  capture data is left in place. QC review now runs from the separate QC
  Platform installer.

QCPlatformSetup.exe

  Installs the FastAPI backend, built Vue console, SQL schema and migrations,
  plus an offline Python runtime. It writes config\config.txt only on a fresh
  install. The config folder is restricted to SYSTEM and Administrators on
  every install - it holds the database password and the login secret, and a
  console save replaces the file with a new one that takes the folder's
  permissions; the rest of the install keeps Program Files' defaults. It creates the "LWCam QC Server" task
  to run at system startup, replaces the "LWCam QC Server" firewall rule for
  the port set in config\config.txt (8080 unless changed) on Domain and Private
  networks, and starts the task.

  Both installers stop their running processes before any file is replaced
  (the QC server; for LWCam, LWIP and an old all-in-one QC engine) and abort
  with a message if one will not stop.

  The database page is shown when the installer will use a remote PostgreSQL
  server or an existing local server. A fresh local PostgreSQL install gets a
  generated password. If schema setup fails, the rest of the platform still
  installs; see logs\database-setup.log, fix config\config.txt, then run
  SETUP_DB.bat as Administrator.

  Open the console at http://localhost:8080. The first account must be created
  in LWCam Admin User Management. On a split site, set qcImagesRoot in
  config\config.txt (or in the console's Settings). The service runs as SYSTEM, so use a UNC path and grant the QC
  server PC's machine account access to the capture share; mapped drives from a
  user's session are not visible to SYSTEM.

Inputs staged outside git
-------------------------

  installer\vendor\python-3.13.14-embed-amd64.zip
  installer\vendor\vcruntime\             Visual C++ runtime DLLs
  installer\vendor\adb\                   adb.exe and its two support DLLs
  installer\vendor\postgresql\             PostgreSQL 18 installer
  LWCAM\scrcpy\                            scrcpy Windows build
  LWCAM\LWIP\tools\                        jpegtran
  LWCAM\LWIP\wheels\                       offline LWIP dependencies
  LWCam_QC_Platform\backend\wheels\         offline QC backend dependencies
  LWCam_QC_Platform\frontend\dist\          built by the QC target

The QC Python runtime is built from the embeddable zip and wheelhouse on the
target with --no-index. A missing wheel is a hard install failure, not a
network download fallback.

Installer sources
-----------------

  LWCam.iss              LWCam installer; retains the old LW Suite AppId
  QCPlatform.iss         New standalone QC server installer
  postgres.iss           Shared PostgreSQL detection, install, and recovery
  build-installer.ps1    Input checks, frontend build, ISCC compile, sidecar copy
  qc\SETUP_QC.bat        Build and verify the offline QC Python runtime
  qc\SETUP_DB.bat        Create/upgrade the database from config\config.txt
  qc\START_QC_SERVER.bat Start run_server.py from the installed backend
  qc\OPEN_QC_LOG.bat     Open the server log

The old START_QC_BACKEND.bat, SETUP_QC_DB.bat, and START_QC_FRONTEND.bat
were removed: all three depended on LWCam Admin's node config, and the first
forwarded its arguments past the host that config.txt sets. START_QC_SERVER.bat
takes no arguments for that reason.