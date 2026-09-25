LWCam installers
================

This folder builds five Windows installers from the source tree:

  LWCamDatabaseSetup.exe  PostgreSQL (installed here, or an existing server),
                          the LWCam schema, opened to the LAN
  QCPlatformSetup.exe     Standalone QC server, Vue console, review and export
  LWIPSetup.exe           LWIP: deskew/crop image processing, as a SYSTEM service
  LWCamUploadSetup.exe    Upload: sends QC's exported packages to S3, as a
                          SYSTEM service
  LWCamSetup.exe          LWCam Capture and LWCam Admin, for capture PCs

Site install order: LWCamDatabaseSetup first (once, on the database PC), then
QCPlatformSetup, LWIPSetup and LWCamUploadSetup (once each, on their own PCs,
in any order), then LWCamSetup on every capture PC. Each of the other four
needs the database's host, port, user and password, which
LWCamDatabaseSetup's finish page shows; LWCamSetup and QCPlatformSetup also
need LWIP's output folder, which LWIPSetup's finish page shows; and Upload
needs the QC server's export output folder, which QCPlatformSetup's finish
page shows. QC no longer uploads anything itself - it only reviews and
exports; Upload is the only app that talks to S3.

Only LWCamDatabaseSetup installs PostgreSQL, when a local server is needed, or
uses an existing server on another PC. The PostgreSQL installer is a separate
file beside LWCamDatabaseSetup.exe. Ship them together; a PC that already has
PostgreSQL needs only the setup executable.

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

Compile one installer or all five:

  .\build-installer.ps1 -Target Database
  .\build-installer.ps1 -Target QC
  .\build-installer.ps1 -Target LWIP
  .\build-installer.ps1 -Target Upload
  .\build-installer.ps1 -Target LWCam
  .\build-installer.ps1 -Target All

The QC target runs npm run build in LWCam_QC_Platform\frontend before compiling.
Outputs land at the repository root, beside LWCAM\ and installer\. The script
checks each target's release/build inputs, and for Database copies the newest
staged postgresql-18.*-windows-x64.exe beside LWCamDatabaseSetup.exe. It does
not run an installer.

Use -ResolveOnly to print the selected ISCC and scrcpy paths without building.
The LWCam target uses LWCAM\scrcpy when it contains scrcpy.exe, or resolves the
installed scrcpy package. Pass -ScrcpyDir to select another Windows build.

Products
--------

LWCamDatabaseSetup.exe

  Installs PostgreSQL 18 (unless a server is already present or the "use an
  existing server" choice is made), then creates or upgrades the LWCam schema
  and, when the "Allow other PCs on this network to connect" task is ticked
  and the database is on this PC, opens PostgreSQL to the LAN (listen_addresses,
  pg_hba.conf, and a "LWCam Database" firewall rule on Domain and Private
  networks). The connection is written to config\database.txt (private folder,
  SYSTEM and Administrators only) and shown on the finish page - host, port,
  database name, user and password - to be typed into QCPlatformSetup,
  LWIPSetup and LWCam Admin's Station Setup. It never removes PostgreSQL or its
  data on uninstall: other stations and apps may still depend on it.

QCPlatformSetup.exe

  Installs the FastAPI backend, built Vue console, and an offline Python
  runtime. It writes config\config.txt only on a fresh install, always asking
  for the database connection (the database must already exist, from
  LWCamDatabaseSetup - this installer no longer creates one). The config folder
  is restricted to SYSTEM and Administrators on every install - it holds the
  database password and the login secret, and a console save replaces the file
  with a new one that takes the folder's permissions; the rest of the install
  keeps Program Files' defaults. It creates the "LWCam QC Server" task to run
  at system startup, replaces the "LWCam QC Server" firewall rule for the port
  set in config\config.txt (8080 unless changed) on Domain and Private
  networks, and starts the task.

  Open the console at http://localhost:8080. The first account must be created
  in LWCam Admin User Management. On a split site, set qcInputRoot in
  config\config.txt (or the console's Settings) to the same UNC path LWIPSetup
  writes its output to. QC no longer uploads anything to S3 - that moved to
  LWCamUploadSetup, which watches QC's own export output (qcOutputRoot).

LWIPSetup.exe

  Installs LWIP - the deskew/crop image-processing tool - as its own offline
  Python runtime, run by the "LWCam LWIP" scheduled task (SYSTEM, at system
  startup). The wizard asks for the input folder (where LWCAM copies finished
  captures) and the output folder (LWIP's result, what the QC server reads
  from), then the database connection; both wizard pages are skipped on an
  upgrade, once config\deskew_crop_config.json exists. A mapped network drive
  letter is refused for either folder - SYSTEM cannot see a drive mapped in a
  user's logon session - use a UNC path (\\server\share) or a local fixed
  drive. LWIP reports each finished folder to the database itself, so a batch
  reaches the QC queue even while LWCAM is closed.

  It also serves a small console over HTTP, on port 8090 by default
  (config\deskew_crop_config.json's ui_port) - a "LWIP Console" Start-menu
  shortcut opens it, and the "LWCam LWIP" firewall rule opens that port on
  Domain and Private networks. Sign in with an Admin or SuperAdmin database
  account (the same accounts the QC console uses). If the database cannot be
  reached, settings can still be changed, but only from a browser open on this
  PC itself - a remote browser gets a read-only status/log view instead.

  Taking over folders an older LWIP already processed: stop the new service,
  copy the old journal (%USERPROFILE%\LWCAM_DBs\lwip\runtime\state.json on an
  all-in-one station) to {app}\runtime\state.json, then start it again. It
  only matches when input_root is the SAME path string as before. Without it,
  LWIP re-adopts every finished folder whose pages still match its manifest,
  which is safe; but a folder whose page files were replaced since, for
  example by a QC page replacement, fails that check and is processed again
  from the originals.

LWCamUploadSetup.exe

  Installs Upload - the S3 upload service - as its own offline Python
  runtime, run by the "LWCam Upload" scheduled task (SYSTEM, at system
  startup). The wizard asks for the watch folder (QC's export output -
  qcOutputRoot), the Uploaded folder (where a sent package is moved to) and
  the Upload Reports folder (where Upload_Summary.db3 is written) - all three
  required by the wizard, since Inno's folder page refuses a blank path; either
  of the last two can be cleared later in the console (blank = leave packages
  in place / write no summary), then the S3
  destination (s3://bucket/prefix, region, access key, secret key), then the
  database connection; all three wizard pages are skipped on an upgrade, once
  config\upload_config.json exists. A mapped network drive letter is refused
  for the watch, Uploaded or Upload Reports folders - SYSTEM cannot see a
  drive mapped in a user's logon session - use a UNC path (\\server\share) or
  a local fixed drive. Rework republished under the same Group ID is
  detected by a content fingerprint and uploaded again, replacing what is
  already in the bucket.

  It also serves a small console over HTTP, on port 8091 by default
  (config\upload_config.json's ui_port) - an "Upload Console" Start-menu
  shortcut opens it, and the "LWCam Upload" firewall rule opens that port on
  Domain and Private networks. Sign in with an Admin or SuperAdmin database
  account (the same accounts the QC console and LWIP console use); this
  login is only for the console, Upload's PUTs to S3 use the access key and
  secret entered in the wizard (or later, in Settings). Settings are re-read
  at the start of every scan, so a console save applies without a restart.

LWCamSetup.exe

  Installs LWCam Capture and LWCam Admin only - no LWIP, no PostgreSQL. It
  keeps the shipped AppId so an existing LW Suite (or split-era LWCam) install
  upgrades in place; an old copy of LWIP under {app}\LWCAM\LWIP and a former
  all-in-one {app}\QC engine are both stopped and removed during upgrade
  (existing capture data is left in place), and the old per-user LWIP logon
  entry is deleted. This station connects to the database and to LWIP over the
  LAN - open LWCam Admin, complete Station Setup with the values
  LWCamDatabaseSetup and LWIPSetup show, and press Save.

  Every installer that runs a background process stops it before any file is
  replaced (LWCamSetup: an old all-in-one QC engine and any old LWIP;
  QCPlatformSetup: the QC server; LWIPSetup: LWIP; LWCamUploadSetup: Upload)
  and aborts with a message if one will not stop.

Unattended install
------------------

Every installer above accepts Inno Setup's standard silent switches, so mass
deployment and automated tests can run it with no one watching:

  Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\path\to\x.log" /PARAM=value ...

/VERYSILENT hides both the wizard and the progress window; /SUPPRESSMSGBOXES
answers every suppressible message box the way the docs say it would if a
person clicked through (Yes to continue, the recommended choice, etc.);
/NORESTART stops Setup rebooting the PC on its own; /LOG writes a detailed
log, which is the only way to see what an unattended run actually did.
Parameter names below (/DBHOST, /INPUTROOT, and so on) are case-insensitive,
as Inno treats every /NAME=value pair.

A silent run gets each custom wizard page's values from these parameters
instead of typed input, validated the SAME WAY and with the SAME WORDING the
wizard would show - a missing or invalid value fails setup before a single
file is written, with that wording appearing in the log (Setup exit code 7 =
"Preparing to Install decided Setup cannot proceed", the same code a
validation failure of Inno's own would return). A page that the wizard would
skip anyway (an upgrade, once its config file already exists; the Database
page, on a fresh LOCAL PostgreSQL install with no /TASKS=remotedb - Setup
invents its own password there) is skipped unattended too, so its parameters
are simply ignored.

LWCamDatabaseSetup.exe (fresh local server, opened to the LAN):

  LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\db.log" /TASKS="openlan"

LWCamDatabaseSetup.exe (an existing server elsewhere):

  LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\db.log" /TASKS="remotedb" ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBUSER=postgres /DBPASSWORD=CorrectHorseBattery1

  Parameters: DBHOST (default localhost), DBPORT (default 5432), DBUSER
  (default postgres), DBPASSWORD (default empty - must be supplied whenever
  the Database page would not be skipped). /TASKS names: openlan (checked by
  default - "Allow other PCs on this network to connect"; drop it from
  /TASKS to leave the server on loopback only) and remotedb (unchecked by
  default - "Use an existing PostgreSQL server instead of installing one";
  /TASKS replaces the whole selection, so pass "openlan,remotedb" to keep
  both). A fresh local install with neither task also needs the PostgreSQL
  18 installer beside LWCamDatabaseSetup.exe, exactly as an attended run does.

QCPlatformSetup.exe:

  QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\qc.log" ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBUSER=postgres /DBPASSWORD=CorrectHorseBattery1

  Parameters: DBHOST, DBPORT (default 5432), DBUSER (default postgres),
  DBPASSWORD (default empty) - the database LWCamDatabaseSetup already made.

LWIPSetup.exe:

  LWIPSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\lwip.log" ^
    /INPUTROOT="\\FILESERVER\lwcam-input" /OUTPUTROOT="\\FILESERVER\lwcam-output" ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBUSER=postgres /DBPASSWORD=CorrectHorseBattery1

  Parameters: INPUTROOT, OUTPUTROOT (both default empty - the same "neither
  folder can be on a mapped drive letter" rule applies), plus DBHOST, DBPORT
  (default 5432), DBUSER (default postgres), DBPASSWORD (default empty).

LWCamUploadSetup.exe:

  LWCamUploadSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\upload.log" ^
    /WATCHROOT="\\FILESERVER\lwcam-output" /DONEROOT="\\FILESERVER\lwcam-uploaded" ^
    /SUMMARYROOT="\\FILESERVER\lwcam-reports" ^
    /S3PATH="s3://my-bucket/lwcam" /S3REGION=us-east-1 ^
    /S3ACCESSKEY=AKIAEXAMPLE /S3SECRET=ExampleSecretKey ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBUSER=postgres /DBPASSWORD=CorrectHorseBattery1

  Parameters: WATCHROOT, DONEROOT and SUMMARYROOT (all three required - a
  blank one fails with Inno's "You must enter a full path" before anything is
  installed, exactly as in the wizard; clear them afterwards in the console),
  S3PATH, S3REGION, S3ACCESSKEY, S3SECRET (all default empty), plus DBHOST,
  DBPORT (default 5432), DBUSER (default postgres), DBPASSWORD (default
  empty).

LWCamSetup.exe takes no product-specific parameters - it has no database or
folder page any more, just the standard silent switches (and /DIR= if the
default install location is wrong for the fleet).

Command-line values are not private. While Setup runs, any other process on
the same PC can read its full command line (Task Manager's Command line
column, WMI, Get-CimInstance Win32_Process, and so on) - a password or S3 key
passed this way is exposed for as long as that install takes. Inno also
writes Setup's ENTIRE command line, verbatim, as the first few lines of a
/LOG file ("Setup command line: ...") - confirmed by running a test build
with a dummy secret parameter and reading it back out of the log, so
/DBPASSWORD, /S3ACCESSKEY and /S3SECRET land in the log in plain text too.
([Run] entries are the one thing Inno does NOT log this way when marked
dontlogparameters - see postgres.iss - but that flag has no effect on
Setup's own command line.) Run unattended installs from a script only an
administrator can read, over a connection only an administrator can see, and
delete or otherwise secure the /LOG file afterwards - do not leave it where
an unprivileged account (or a backup of the install folder) can read it.

Inputs staged outside git
-------------------------

  installer\vendor\python-3.13.14-embed-amd64.zip
  installer\vendor\vcruntime\             Visual C++ runtime DLLs
  installer\vendor\adb\                   adb.exe and its two support DLLs
  installer\vendor\postgresql\             PostgreSQL 18 installer
  LWCAM\scrcpy\                            scrcpy Windows build
  LWIP\tools\                              jpegtran
  LWIP\wheels\                             offline LWIP dependencies (also
                                            supplies pip/psycopg/tzdata to
                                            LWCamDatabaseSetup)
  LWCam_QC_Platform\backend\wheels\         offline QC backend dependencies
  LWCam_QC_Platform\frontend\dist\          built by the QC target
  LWCam_Upload\wheels\                      offline Upload dependencies
                                            (boto3, botocore, s3transfer,
                                            psycopg, bcrypt)

The Python runtimes are built from the embeddable zip and the relevant
wheelhouse on the target with --no-index. A missing wheel is a hard install
failure, not a network download fallback.

SYSTEM account and UNC shares
------------------------------

LWIPSetup, QCPlatformSetup and LWCamUploadSetup all run their service as
SYSTEM, which cannot see a drive mapped in a user's logon session - use UNC
paths (\\server\share) for LWIP's input/output folders, the QC input root,
and Upload's watch/Uploaded/Upload Reports folders, never a mapped drive
letter (all three installers refuse one where they ask for a folder). A UNC
share also needs the machine account, not just a user account, granted
access: add "<COMPUTERNAME>$" to the share and NTFS permissions on the folder
the same way you would add a user, for every PC whose SYSTEM service reads or
writes it.

Installer sources
-----------------

  Database.iss           Database installer: PostgreSQL, schema, LAN access
  QCPlatform.iss          QC server installer
  LWIP.iss                LWIP installer
  Upload.iss               Upload installer
  LWCam.iss                LWCam Capture + LWCam Admin installer
  common.iss               Shared helpers (PythonProcessesUnder, RestrictToAdmins)
                            - included by every installer, directly or (for
                            Database) through postgres.iss
  postgres.iss             PostgreSQL detection, install, and recovery -
                            included by Database.iss only
  build-installer.ps1      Input checks, frontend build, ISCC compile, sidecar copy
  db\SETUP_DB_RUNTIME.bat  Build the Database installer's offline Python runtime
  db\SETUP_DATABASE.bat    Create/upgrade the schema from config\database.txt
  qc\SETUP_QC.bat          Build and verify the offline QC Python runtime
  qc\START_QC_SERVER.bat   Start run_server.py from the installed backend
  qc\OPEN_QC_LOG.bat       Open the server log

The old START_QC_BACKEND.bat, SETUP_QC_DB.bat, and START_QC_FRONTEND.bat
were removed: all three depended on LWCam Admin's node config, and the first
forwarded its arguments past the host that config.txt sets. START_QC_SERVER.bat
takes no arguments for that reason. qc\SETUP_DB.bat (the QC installer's own,
now-unused database setup wrapper) was removed the same way when database
setup moved to its own installer - db\SETUP_DATABASE.bat is its replacement,
run by Database.iss instead.
