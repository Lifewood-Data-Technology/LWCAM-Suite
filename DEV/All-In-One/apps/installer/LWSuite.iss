; LW Suite - offline installer (All-In-One tree)
;
; Recovered 2026-08-18 from Downloads\LWCAM Deploy\LWSuite.exe with innounp 2.70.1,
; because the build script existed only inside that binary. Compile with:
;
;   iscc LWSuite.iss
;   iscc /DScrcpyDir="C:\path\to\scrcpy-win64" LWSuite.iss
;
; Three things a reconstruction cannot give back, re-stated here deliberately:
;
;   1. Permissions: users-modify on the data folders. They live under Program Files,
;      but LWCAM, LWIP and the QC servers all write to them as a NORMAL user. Without
;      it every capture write fails on a fresh install. innounp does not recover
;      permissions, so their absence in the extraction is an artefact, not the truth.
;      See LWCamAdmin/lib/controllers/station_setup_controller.dart, which documents
;      that the installer grants this.
;   2. AppId below is byte-for-byte the shipped GUID. Change it and new installers
;      stop upgrading existing stations and start stacking beside them.
;   3. Wildcards. The extraction emitted one line per file, 217 of them, with Source
;      pointing at INSTALLED paths. Those are rewritten here to build outputs.

#define AppNameFull    "LW Suite"
#define AppVer         "1.0.1"

; Build inputs, relative to this file unless overridden with /D on the command line.
#ifndef AppsDir
  #define AppsDir      ".."
#endif
#define AdminRelease   AppsDir + "\LWCamAdmin\build\windows\x64\runner\Release"
#define LwcamRelease   AppsDir + "\LWCAM\build\windows\x64\runner\Release"
#define LwipDir        AppsDir + "\LWCAM\LWIP"
#define QcBackend      AppsDir + "\LWCam_QC_Platform\backend"
#define QcDatabase     AppsDir + "\LWCam_QC_Platform\database"
#define QcScripts      AppsDir + "\LWCam_QC_Platform\scripts"
; No QcDist. The Vue console on port 5174 is no longer shipped - see [Components].

; scrcpy is deliberately NOT in the repository (licence + size). Point at a Windows
; build. The winget package installs one under
; %LOCALAPPDATA%\Microsoft\WinGet\Packages\Genymobile.scrcpy_*\scrcpy-win64-*
#ifndef ScrcpyDir
  #define ScrcpyDir    AppsDir + "\LWCAM\scrcpy"
#endif

; Offline Python for the QC runtime, recovered alongside this script.
#define PyEmbedZip     "vendor\python-3.13.14-embed-amd64.zip"

; PostgreSQL server. The one prerequisite the suite cannot supply from its own
; source: SETUP_QC_DB.bat applies a schema to a server that already exists, so a
; station without one has no QC at all.
;
; NOT bundled. At 359 MB it was 72% of a 500 MB LWSuite.exe, and only a PC
; WITHOUT a server ever uses it - the Check below already skipped installing it
; everywhere else, but every copy of the installer still carried it. It now
; ships as a loose file BESIDE LWSuite.exe and is run from there ({src}), which
; leaves the installer at ~150 MB: a station that already has PostgreSQL needs
; nothing but the exe. PrepareToInstall refuses, by name, if this PC needs the
; server and the file is not there - the one failure this split introduces, and
; it fails before anything is written rather than half way through.
; Any PostgreSQL 18 build of EDB's installer is accepted (PgSetupPath below
; picks the highest-named match beside the exe): 18.6-1 was shipped first, EDB
; then published 18.6-3, and the unattended flags, service name and paths are
; identical across 18.x point releases. The major is what the suite depends on.
#define PgSetupMask    "postgresql-18.*-windows-x64.exe"
#define PgMajor        "18"

[Setup]
AppName={#AppNameFull}
AppId={{B41D7E60-8C2A-4F17-9E3B-5A6D0C9F2E48}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LW Suite
OutputBaseFilename=LWSuite
; The All-In-One folder root, beside START-HERE.md - not a subfolder and not the
; default Output\. An operator deploying a station should find LWSuite.exe at the
; top of the folder they were handed, without opening apps\installer\.
OutputDir=..\..
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; ALWAYS offer the folder, never only on a first install. "auto" hides the page
; whenever UsePreviousAppDir finds an earlier install, so after the very first
; setup on a PC the operator could no longer move the suite - onto a data drive,
; or off a small system SSD - without uninstalling first. Nothing downstream
; requires {autopf}: every [Dirs]/[Files]/[Icons]/[Run] entry is {app}-relative,
; the top-level SETUP_QC_DB.bat resolves the install from the registry's
; InstallLocation, and LWCam Admin derives its own roots from where its exe
; actually sits (station_setup_controller.dart, defaultCaptureRoot).
;
; UsePreviousAppDir stays on (the default), so the page opens PRE-FILLED with
; the existing location and an upgrade is still just Next - see the warning in
; NextButtonClick for the one case that needs care.
DisableDirPage=no
DisableProgramGroupPage=yes
ChangesAssociations=no
ShowLanguageDialog=yes
WizardStyle=modern
UninstallDisplayIcon={app}\LWCamAdmin\lwcam_admin.exe
; Writing into {autopf} needs elevation. The data folders below are then opened up
; again with users-modify so the apps can run unelevated.
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

; The one thing setup cannot work out for itself.
;
; Whether to install PostgreSQL was decided purely by whether this PC already
; has a psql.exe. That is right for a single-station site and wrong for every
; multi-PC one: a station that does QC, export and upload against the database
; on ANOTHER PC has no local server, so setup demanded the 358 MB installer and
; then installed a server the station never connects to - and wrote a
; station-seed.json pointing LWCam Admin at localhost, which is precisely the
; wrong answer to pre-fill on that machine.
;
; Ticking this makes NeedsPostgreSql false: no install, no seed, no password
; dialog, and PrepareToInstall stops asking for the file. The operator then
; types the server's host into Station Setup, which is the one thing only they
; know. Unticked - the default - behaves exactly as before.
[Tasks]
Name: "remotedb"; Description: "This station uses a PostgreSQL server on another PC (do not install one here)"; Flags: unchecked

; The Vue console (component "qcfront", port 5174) is gone. QC review moved into
; LWCAM itself - see LWCAM/lib/pages/qc_review_page.dart, reached via route /qc and
; gated on UserRole.qc (app_user.dart, `canQc`). One binary is now both the capture
; station and the QC review station, split by role at login.
;
; Two consequences, both deliberate:
;
;   1. There is no QC-only type any more. The review UI ships inside lwcam.exe, so a
;      machine that reviews also receives LWIP and scrcpy. That is the intent here:
;      this tree is the all-in-one bundle and every PC gets the whole thing.
;   2. "full" and the old "qc" type became identical once the console was dropped -
;      the console was the only thing that distinguished them - so "qc" is removed
;      rather than left as a duplicate label.
; No [Types] and no [Components], deliberately.
;
; This is the All-In-One product: every PC gets the whole suite. A selection
; page is one more decision for a non-technical operator to get wrong, and the
; only choice it ever offered was whether to leave the QC server off a station
; that might later need it. Installing everything costs disk space; a station
; missing a component costs a site visit.
;
; Consequence for [Code]: nothing is conditional on a component any more, so
; NeedsPostgreSql asks only whether a server is already present.

; Pre-embeddable LWIP runtimes, removed BEFORE the new files land.
;
; Not tidying - correctness. An upgraded station still has a stale HKCU Run
; entry pointing at venv\Scripts\pythonw.exe. If that interpreter survives, it
; starts at logon, takes the orchestrator lock first, and the newly built
; runtime loses that race every time - from an interpreter nobody maintains.
; Deleting it would turn a silently-wrong station into an obviously-idle one
; until the first Save in LWCam Admin rewrote the Run entry - so setup now
; repoints that entry itself (RepointLwipAutostart, at ssPostInstall) and the
; station is neither wrong nor idle after an upgrade.
[InstallDelete]
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\venv"
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\python"
Type: files; Name: "{app}\LWCAM\LWIP\python-3.13.14-amd64.exe"

[Files]
; --- LWCam Admin -----------------------------------------------------------------
Source: "{#AdminRelease}\*"; DestDir: "{app}\LWCamAdmin"; Flags: ignoreversion recursesubdirs createallsubdirs
; Visual C++ runtime. `flutter build` does NOT emit these, and without them the app
; dies at startup with a missing-DLL error on any PC that has never had a VC++
; redistributable installed - which is most clean Windows images. The shipped
; installer carried them; keep doing that.
Source: "vendor\vcruntime\*"; DestDir: "{app}\LWCamAdmin"; Flags: ignoreversion

; --- LWCAM capture plus bundled tooling ------------------------------------------
Source: "{#LwcamRelease}\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "vendor\vcruntime\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion
; jpegtran (libjpeg-turbo) does LWIP's lossless crop of straight pages. It is
; linked against the same VC runtime, and a Windows exe only finds that DLL
; beside itself or in System32, so it gets its own copy in tools\.
Source: "vendor\vcruntime\vcruntime140.dll"; DestDir: "{app}\LWCAM\LWIP\tools"; Flags: ignoreversion
; adb, beside the exe. LWCAM resolves it next-to-exe FIRST (gallery_page.dart
; _resolveAdbPath), so bundling it means capture works on a PC with no Android
; platform-tools installed and nothing on PATH.
Source: "vendor\adb\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion
Source: "{#ScrcpyDir}\*"; DestDir: "{app}\LWCAM\scrcpy"; Flags: ignoreversion recursesubdirs createallsubdirs
; LWIP source only. The venv is built on the target by SETUP_DESKEW_CROP.bat, so
; never ship venv or python - they hard-code absolute paths from the build machine.
; tests\ and RUN_TESTS.bat DO ship, deliberately: RUN_TESTS.bat is the on-target
; check that the venv built correctly, and it discovers backend\tests.
; No createallsubdirs here: it creates a subdirectory on the target even when the
; Excludes emptied it, which shipped bare venv\ and __pycache__\ folders. Without it
; recursesubdirs still creates every directory that actually has a file in it.
Source: "{#LwipDir}\*"; DestDir: "{app}\LWCAM\LWIP"; Flags: ignoreversion recursesubdirs; Excludes: "venv\*,python\*,python-3.13.14-amd64.exe,runtime\*,*.pyc,__pycache__\*,.pytest_cache\*,.gitignore,backend\benchmark_lwip.py"

; --- QC server -------------------------------------------------------------------
; The Excludes list is two things. First, build/runtime state that must never leave
; this machine (.venv, caches, .env). Second, files that are repository furniture
; with no job on a target: the test suite, the Docker build (this deployment is
; deliberately Docker-free), .gitignore, and pyproject.toml - SETUP_QC.bat puts the
; backend on sys.path through python313._pth and never pip-installs it as a package.
;
; wheels\ is NOT excluded: SETUP_QC.bat installs from it with --no-index, so a
; missing wheelhouse is a hard failure on the target.
; alembic.ini stays too - app\db\migrations\env.py ships and is its config, even
; though setup_qc_db.py applies raw SQL rather than running alembic.
; createallsubdirs omitted deliberately - see the LWIP entry below.
Source: "{#QcBackend}\*"; DestDir: "{app}\QC\backend"; Flags: ignoreversion recursesubdirs; Excludes: ".venv\*,.cache\*,*.pyc,__pycache__\*,.pytest_cache\*,.env,tests\*,conftest.py,Dockerfile,.dockerignore,.gitignore,pyproject.toml,.env.example,requirements-dev.txt,app\Luminance Correction\README.txt,app\Luminance Correction\requirements.txt"
Source: "{#QcDatabase}\*"; DestDir: "{app}\QC\database"; Flags: ignoreversion recursesubdirs createallsubdirs

; QC launchers and helpers. setup_qc_db.py is the repository copy. The .bat files
; live beside this script because they exist nowhere else.
;
; START_QC_FRONTEND.bat and serve_frontend.py are NOT shipped: both exist only to
; serve the Vue console's dist folder, which no longer ships. They stay in the
; repository as the recovered originals.
Source: "qc\SETUP_QC.bat";          DestDir: "{app}\QC"; Flags: ignoreversion
Source: "qc\SETUP_QC_DB.bat";       DestDir: "{app}\QC"; Flags: ignoreversion
Source: "qc\START_QC_BACKEND.bat";  DestDir: "{app}\QC"; Flags: ignoreversion
Source: "{#QcScripts}\setup_qc_db.py"; DestDir: "{app}\QC"; Flags: ignoreversion
; Shared by BOTH offline runtimes (QC and LWIP), so it ships once at the root
; rather than twice beside each script. Both setup .bat files search for it.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion
; No [Files] entry for the PostgreSQL server: it lives beside this installer
; and [Run] launches it in place, so nothing copies 359 MB into {tmp} first.

[Dirs]
; The pipeline folders. users-modify is load-bearing - see the header.
Name: "{app}\LWCam Capture\1.Images"; Permissions: users-modify
Name: "{app}\LWCam Capture\2.Batches"; Permissions: users-modify
Name: "{app}\LWCam Capture\3.Export"; Permissions: users-modify
Name: "{app}\LWCam Capture\4.Uploaded"; Permissions: users-modify
; The QC engine (unelevated) creates and writes Upload_Summary.db3 here.
Name: "{app}\Upload Reports"; Permissions: users-modify
; The QC runtime and the LWIP venv are built in place after install, by the same
; unelevated user that later runs them.
Name: "{app}\QC\runtime"; Permissions: users-modify
; The seed lives here, not under {app}, because LWCam Admin has to DELETE it
; once consumed - it holds the PostgreSQL superuser password. Program Files is
; admin-write and Admin runs unelevated, so a seed there could be read forever
; but never cleared. users-modify makes consuming it actually possible.
Name: "{commonappdata}\LWCAM"; Permissions: users-modify
Name: "{app}\LWCAM\LWIP\runtime"; Permissions: users-modify

[Run]
; The redirect answers the pause prompt in these scripts so an unattended install
; cannot hang waiting for a keypress.
; PostgreSQL first: it is the prerequisite, and its unattended install is the
; slowest step. --unattendedmodeui minimal shows a progress window, so a long
; silent gap does not look like a hung installer. pgAdmin and Stack Builder are
; dropped deliberately: nothing in the suite uses them and Stack Builder wants
; the internet this deployment does not assume.
Filename: "{code:PgSetupPath}"; Parameters: "--mode unattended --unattendedmodeui minimal --superpassword ""{code:GetPgPassword}"" --serverport 5432 --enable-components server,commandlinetools --disable-components pgAdmin,stackbuilder"; StatusMsg: "Installing PostgreSQL 18 (none was found on this PC)..."; Check: NeedsPostgreSql
; SETUP_DESKEW_CROP.bat now builds an embeddable runtime instead of running a
; full CPython installer, which a machine with a newer 3.13 refuses outright.
Filename: "{cmd}"; Parameters: "/C ""{app}\LWCAM\LWIP\SETUP_DESKEW_CROP.bat"" <NUL"; WorkingDir: "{app}\LWCAM\LWIP"; StatusMsg: "Installing the offline image-processing runtime..."
Filename: "{cmd}"; Parameters: "/C ""{app}\QC\SETUP_QC.bat"" <NUL"; WorkingDir: "{app}\QC"; StatusMsg: "Installing the offline QC runtime..."
; Admin last: it is the only configuration tool, so Station Setup is step one for the
; operator.
Filename: "{app}\LWCamAdmin\lwcam_admin.exe"; Description: "{cm:LaunchProgram,LWCam Admin}"; Flags: postinstall skipifsilent nowait

[Icons]
Name: "{autodesktop}\LWCam Admin"; Filename: "{app}\LWCamAdmin\lwcam_admin.exe"
; One icon for both jobs: lwcam.exe opens capture or QC review depending on the
; signed-in user's role, so there is no separate QC console shortcut to make.
Name: "{autodesktop}\LWCAM"; Filename: "{app}\LWCAM\lwcam.exe"
; No icon for START_QC_BACKEND.bat. LWCam Admin registers the backend to start
; at logon when QC is installed (qc_backend_autostart_service.dart), so there is
; nothing for an operator to launch by hand. The .bat still ships: it is the way
; to run the server in a console when something needs diagnosing.

[UninstallDelete]
; 1.0.1 shipped the embeddable zip inside {app}\QC. It now lives at the root,
; and a file that leaves [Files] is orphaned at uninstall unless it is named.
Type: files; Name: "{app}\QC\python-3.13.14-embed-amd64.zip"
; Setup writes these two after the file list is laid down, so the uninstaller
; does not know about them. A superuser password surviving an uninstall is not
; acceptable, and a stale seed would be read by the next install as if it were
; current.
Type: files; Name: "{app}\postgres-password.txt"
Type: files; Name: "{app}\station-seed.json"
Type: files; Name: "{commonappdata}\LWCAM\station-seed.json"
; Built on the target, so not tracked by the installer file list.
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\venv"
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\python"
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\runtime"
Type: filesandordirs; Name: "{app}\QC\runtime"
Type: filesandordirs; Name: "{app}\QC\backend\__pycache__"

; PostgreSQL is the only prerequisite this installer cannot satisfy by copying
; files, so it detects a server and runs the bundled one when there is none.
;
; Detection is deliberately two-pronged. The registry key is what EnterpriseDB's
; installer writes and is authoritative, but an uninstall can leave the key behind
; while removing the binaries, so a psql.exe on disk has to confirm it. Checking
; only for the directory would be wrong the other way: an uninstall leaves
; C:\Program Files\PostgreSQL standing and empty, which would silently skip the
; install and hand the operator a QC station with no database.
[Code]
var
  PgPassword: String;
  PgChecked: Boolean;
  PgNeeded: Boolean;
  PgReusedCluster: Boolean;
  StoppedQcBackends: Integer;

// Stops any QC engine running out of THIS installation, before its files are
// replaced.
//
// The engine is registered to start at logon, so it survives an upgrade: setup
// happily overwrites the backend's .py files underneath a live server, which
// keeps serving the code it imported at startup. The result is a station that
// looks freshly installed and is not - new apps talking to an engine running the
// previous version, with no error anywhere to say so. That cost a full debugging
// session to find once already.
//
// Restart Manager does not catch this. Python reads a .py and closes it, so
// nothing holds a lock for Inno to detect, which is also why the overwrite
// succeeds silently.
//
// Matched by COMMAND LINE against this install's QC folder, never by process
// name: a station may be running unrelated Python, and killing that would be a
// far worse bug than the one being fixed. Both launch paths match - the logon
// launcher (pythonw) and START_QC_BACKEND.bat / LWCAM's sidecar (python -m
// uvicorn), since all of them name a path inside {app}\QC.
//
// LWIP is deliberately NOT stopped, though it has the same shape: it is a worker
// mid-folder rather than a server, so killing it needs its journal thought
// through first.
procedure StopQcBackend();
var
  Command, QcDir: String;
  ResultCode: Integer;
begin
  StoppedQcBackends := 0;
  QcDir := ExpandConstant('{app}\QC');
  if not DirExists(QcDir) then
    Exit;

  // No braces anywhere in the PowerShell: "{" opens a constant in an Inno
  // string and would have to be doubled throughout. Where-Object's comparison
  // form and Invoke-CimMethod avoid script blocks entirely, and the settle
  // delay is arithmetic (700 ms when anything was stopped, else 0) for the
  // same reason. The name filter is WQL so WMI does it, not PowerShell over
  // the whole process table. The exit code carries the count back, so the
  // message below is only shown when something was actually running.
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$p = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + QcDir + '*''); ' +
    '$p | Invoke-CimMethod -MethodName Terminate | Out-Null; ' +
    'Start-Sleep -Milliseconds ([Math]::Min($p.Count, 1) * 700); ' +
    'exit $p.Count"';

  if Exec('powershell.exe', Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    StoppedQcBackends := ResultCode;
end;


// Stops LWIP before its .py files are overwritten.
//
// Setup used to leave LWIP alone deliberately - it is a worker mid-folder, not
// a server - so an upgrade overwrote the backend underneath a live process
// that then kept serving the code it imported at startup. A station ran
// pre-upgrade code through TWO reinstalls that way, with nothing in any log,
// because Python closes a .py after reading it and holds no lock. Station
// Setup's save could not fix it either: startLwipNow only STARTS one, and the
// live instance holds work_root\orchestrator.lock, so the replacement exits
// immediately.
//
// Graceful first. The stop file makes LWIP finish the folder it is already
// publishing, cancel the rest and exit clean; dropped folders are simply not
// journalled, so the next run reprocesses them (proven in
// tests/test_long_paths.py). Terminate is the fallback for a wedged process,
// and it is safe for the same reason: every kill window recovers - work_root is
// rmtree'd per folder, a stale .publishing is rmtree'd by name, and an output
// published but not yet journalled is re-adopted after a deep verify.
//
// Matched by COMMAND LINE against {app}\LWCAM\LWIP, never by name, so the
// station's other Python - the QC engine above all - is untouched.
//
// No braces anywhere in the PowerShell, same constraint as StopQcBackend:
// "{" opens a constant in an Inno string. Wait-Process -Timeout replaces what
// would otherwise be a polling loop, which would need a script block.
procedure StopLwip();
var
  Command, LwipDir, StopFile: String;
  ResultCode: Integer;
begin
  LwipDir := ExpandConstant('{app}\LWCAM\LWIP');
  if not DirExists(LwipDir) then
    Exit;

  StopFile := ExpandConstant('{commonappdata}\LWCAM\lwip.stop');
  ForceDirectories(ExpandConstant('{commonappdata}\LWCAM'));
  SaveStringToFile(StopFile, 'stop', False);

  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$p = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + LwipDir + '*''); ' +
    'Wait-Process -Id @($p | Select-Object -ExpandProperty ProcessId) ' +
    '-Timeout 90 -ErrorAction SilentlyContinue; ' +
    '$left = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + LwipDir + '*''); ' +
    '$left | Invoke-CimMethod -MethodName Terminate | Out-Null; ' +
    'exit $p.Count"';

  Exec('powershell.exe', Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Consume our own request if LWIP was not running to read it, so the file
  // cannot linger and stop the NEXT start.
  DeleteFile(StopFile);
end;


// Any PostgreSQL major version with a real psql.exe counts. The suite needs a
// server, not a specific one - the schema is plain SQL.
function PsqlOnDisk(): Boolean;
var
  Find: TFindRec;
  Base: String;
begin
  Result := False;
  Base := ExpandConstant('{commonpf64}\PostgreSQL');
  if FindFirst(Base + '\*', Find) then begin
    try
      repeat
        if (Find.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0)
           and (Find.Name <> '.') and (Find.Name <> '..') then
          if FileExists(Base + '\' + Find.Name + '\bin\psql.exe') then begin
            Result := True;
            Break;
          end;
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
end;

// True when a data directory from a previous install of THE SAME major
// version is still on disk where EnterpriseDB's installer would look. Only
// that one is reused: a leftover 16\data beside a fresh 18 install is
// ignored by the installer, so it must not count here either - or setup
// would take the reused-cluster exit and discard a password that IS the
// new cluster's.
//
// This is the trap that made the first real test fail. A half-removed
// PostgreSQL leaves data\ behind with its own ACLs, so it survives an
// uninstall. EnterpriseDB's installer then REUSES that cluster instead of
// running initdb - and --superpassword only applies to a cluster being
// initialised, so it is silently ignored. Setup installed a working server,
// printed a freshly generated password, and that password was never the
// cluster's: the old one still was. Nothing in the install failed, which is
// exactly what made it hard to see.
function StalePgDataDir(): Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf64}\PostgreSQL\{#PgMajor}\data\PG_VERSION'));
end;

// The two offline Python runtimes built after install, by SETUP_QC.bat and
// SETUP_DESKEW_CROP.bat.
//
// Checked because Inno DISCARDS the exit code of a [Run] entry. Both scripts
// exit /b 1 on every failure path and it goes nowhere - which is exactly how a
// station shipped with no image-processing runtime at all and reported a clean
// install. Same reasoning as the PostgreSQL probe above: verify the outcome on
// disk rather than trust the step.
//
// The probe is the `.setup_ok` sentinel each script writes as its LAST action,
// past its own verification import, and deletes at the start of every run.
//
// It used to test runtime\python\python.exe instead, and that was the wrong
// file: the embeddable package is extracted BEFORE the ._pth is fixed up and
// the wheels are installed, so python.exe exists from the first seconds of a
// run that then fails. A station was found (2026-09-09) with python.exe
// present, a STOCK ._pth that puts Lib\site-packages on no path at all, and
// psycopg missing - reported as a clean install, and unable to process a
// single image. Whatever is checked here has to be something that only exists
// once the work actually finished.
function MissingRuntimes(): String;
begin
  Result := '';
  if not FileExists(ExpandConstant('{app}\QC\runtime\.setup_ok')) then
    Result := Result + #13#10 + '    QC server        (re-run QC\SETUP_QC.bat)';
  if not FileExists(ExpandConstant('{app}\LWCAM\LWIP\runtime\.setup_ok')) then
    Result := Result + #13#10 + '    Image processing (re-run LWCAM\LWIP\SETUP_DESKEW_CROP.bat)';
end;

// Cached: Inno calls a Check function once per [Files] and [Run] entry, and this
// one walks the filesystem.
function NeedsPostgreSql(): Boolean;
begin
  if not PgChecked then begin
    // The "remotedb" task is the operator saying the database lives on another
    // PC. Setup cannot detect that - a station with no local server looks
    // identical whether it wants one or points at a LAN host - so it is the one
    // decision the wizard has to ask for. Checked here rather than at each call
    // site so [Run], PrepareToInstall, the seed and the password dialog all
    // follow from one answer.
    PgNeeded := (not PsqlOnDisk()) and (not WizardIsTaskSelected('remotedb'));
    // Captured HERE, before the server installs: afterwards a data directory
    // exists either way and the question can no longer be asked.
    PgReusedCluster := PgNeeded and StalePgDataDir();
    PgChecked := True;
    if PgNeeded then
      Log('PostgreSQL: no server found, the bundled installer will run.')
    else if WizardIsTaskSelected('remotedb') then
      Log('PostgreSQL: this station was marked as using a server on another ' +
          'PC - not installing one, and writing no connection seed.')
    else
      Log('PostgreSQL: already present, skipping.');
  end;
  Result := PgNeeded;
end;

// Everything Setup needs that is not inside it. Runs after the wizard and
// Where an earlier install of this suite lives, or '' when there is none.
// Same registry value the top-level SETUP_QC_DB.bat reads, and the same AppId
// GUID as line 66 - keep all three together if it ever changes.
function PreviousInstallDir(): String;
var
  Value: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM,
       'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B41D7E60-8C2A-4F17-9E3B-5A6D0C9F2E48}_is1',
       'InstallLocation', Value) then
    Result := RemoveBackslash(Value);
end;

// Moving the install on an UPGRADE needs saying out loud, but NOT because the
// data moves with it - it does not, and that is the point.
//
// The folders the pipeline actually uses are absolute paths in
// lwcam_node_config.json, written by LWCam Admin's Station Setup, and every
// consumer reads them from there: LWCAM's destinationPath, LWIP's processing
// roots, the QC engine's qcInputRoot/qcOutputRoot, the upload and summary
// roots. {app}\LWCam Capture is only the folder set the installer CREATES and
// the value Station Setup offers on a fresh station.
//
// So after an upgrade into a new location that config is untouched and still
// names the OLD folders. The station keeps working against them, which may be
// exactly right - or the operator may want the pipeline to follow the suite,
// which means repointing Station Setup AND moving the existing folders across.
// Either is fine; choosing neither, and not knowing which is in force, is not.
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Previous: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;
  Previous := PreviousInstallDir();
  if (Previous = '') or (CompareText(Previous, RemoveBackslash(WizardDirValue)) = 0) then
    Exit;
  Result := MsgBox(
    'LW Suite is already installed here:' + #13#10 + #13#10 +
    '    ' + Previous + #13#10 + #13#10 +
    'You have chosen to install it here instead:' + #13#10 + #13#10 +
    '    ' + RemoveBackslash(WizardDirValue) + #13#10 + #13#10 +
    'The capture, export and upload folders are NOT decided by where the suite ' +
    'is installed. They are the paths saved in LWCam Admin - Station Setup, and ' +
    'those still point at the old location, so the station will go on using the ' +
    'folders it uses today.' + #13#10 + #13#10 +
    'After setup finishes, open Station Setup and check every folder. If you ' +
    'want the pipeline to follow the suite to the new location, move the ' +
    'existing folders across FIRST, then set the new paths there.' + #13#10 + #13#10 +
    'Install to the new folder anyway?',
    mbConfirmation, MB_YESNO) = IDYES;
end;

// before a single file is written, so a station missing the PostgreSQL
// installer is told which file to fetch instead of failing part-installed.
//
// Only a PC with no server needs it: NeedsPostgreSql is the same probe [Run]
// uses, and calling it here caches the pre-install answer exactly as the first
// Check call used to.
var
  PgSetupCached: String;
  PgSetupSearched: Boolean;

// The PostgreSQL 18 installer beside LWSuite.exe, or '' when there is none.
// Searched once and cached: [Run] expands it as {code:PgSetupPath} and
// PrepareToInstall asks first. With more than one match the highest name wins,
// which orders EDB's point releases correctly (18.6-1 < 18.6-3).
function PgSetupPath(Param: String): String;
var
  FindRec: TFindRec;
  Best: String;
begin
  if not PgSetupSearched then begin
    PgSetupSearched := True;
    Best := '';
    if FindFirst(ExpandConstant('{src}\{#PgSetupMask}'), FindRec) then begin
      try
        repeat
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
            if (Best = '') or (CompareText(FindRec.Name, Best) > 0) then
              Best := FindRec.Name;
        until not FindNext(FindRec);
      finally
        FindClose(FindRec);
      end;
    end;
    if Best <> '' then
      PgSetupCached := ExpandConstant('{src}\') + Best;
    Log('PostgreSQL setup beside the installer: "' + PgSetupCached + '"');
  end;
  Result := PgSetupCached;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if NeedsPostgreSql() and (PgSetupPath('') = '') then
    // Operator's exact wording, kept deliberately short. Inno appends its own
    // "Setup cannot continue. Please click Cancel to exit." below whatever is
    // returned here - do NOT add that line, or it appears twice.
    Result :=
      'This PC has no PostgreSQL server and no PostgreSQL 18 installer ' +
      '(postgresql-18.*-windows-x64.exe) is beside this setup file.';
end;

// The superuser password for a freshly installed server. Generated with the
// system CSPRNG through PowerShell, because Pascal Script's Random is seeded
// from the clock and must not choose a database credential. Base64 with + and /
// mapped out: the value crosses a command line into the PostgreSQL installer and
// then gets typed into Station Setup by hand, so it stays shell- and
// keyboard-safe.
function GetPgPassword(Param: String): String;
var
  TempFile, Command: String;
  Generated: AnsiString;
  ResultCode: Integer;
begin
  if PgPassword = '' then begin
    TempFile := ExpandConstant('{tmp}\pgpw.txt');
    Command := '-NoProfile -ExecutionPolicy Bypass -Command "' +
      '$b = New-Object byte[] 24; ' +
      '[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ' +
      '[Convert]::ToBase64String($b).Replace(''+'',''w'').Replace(''/'',''r'').Replace(''='','''') ' +
      '| Set-Content -NoNewline -Encoding ascii ''' + TempFile + '''"';
    if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
            Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
       and (ResultCode = 0) and LoadStringFromFile(TempFile, Generated) then
      PgPassword := Trim(String(Generated));
    DeleteFile(TempFile);
    // A password we cannot generate must stop the install, not fall back to a
    // guessable one: a predictable superuser password on every station is worse
    // than a failed setup that says so.
    if PgPassword = '' then
      RaiseException('Could not generate a PostgreSQL password. Install PostgreSQL '
        + 'manually (winget install PostgreSQL.PostgreSQL.18) and re-run this installer.');
  end;
  Result := PgPassword;
end;

// The operator has to type this password into Station Setup once, so it is both
// written beside the app and shown on screen. Program Files is admin-write and
// user-read, which is the same exposure the password already has in
// lwcam_node_config.json once Station Setup saves it.
// Two jobs, both after the server install has run: confirm it actually landed,
// then leave the connection details where LWCam Admin can pick them up without
// anyone typing a password.
//
// The confirmation is not paranoia. The unattended switches passed in [Run] are
// EnterpriseDB's documented ones but cannot be verified on a build machine that
// already has PostgreSQL - the installer needs elevation even to print its help,
// and its option strings are inside a compressed payload. So the outcome is
// checked against the filesystem instead of trusted: a switch EnterpriseDB
// renames would otherwise leave a station with no database and no complaint,
// and that failure would only appear later as an authentication error.
//
// The seed file is the point of this whole procedure. Setup knows the password
// it just gave PostgreSQL, and Admin needs it to create the database and write
// its config. Routing that through the operator - showing 32 random characters
// in a dialog and asking them to retype them - was the biggest single source of
// failure in this install, not least because a MsgBox cannot be copied from. So
// setup writes the details down, Admin reads them once, and Admin deletes them.
//
// Machine-wide under {app}, NOT into a user profile: setup runs elevated, so
// {userprofile} resolves to whichever admin approved the UAC prompt, who is
// often not the operator that will use the station.
// An upgraded station's HKCU Run entry for LWIP still names the deleted
// venv\Scripts\pythonw.exe. LWCam Admin writes the entry as
//   "<pythonw>" "<launcher>"
// so only the first quoted path needs replacing; the launcher lives under the
// user's profile and survives the upgrade. Anything not matching that shape is
// left alone for Admin's Save to rewrite. Returns True when it changed the value.
function RepointLwipAutostart(): Boolean;
var
  Cmd, NewExe, Rest: String;
  P: Integer;
begin
  Result := False;
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
                             'LWCamLWIP', Cmd) then
    Exit;
  if Pos('\lwip\venv\scripts\pythonw.exe', Lowercase(Cmd)) = 0 then
    Exit;
  // Cmd is "<exe>" "<launcher>": the exe ends at the first '" ' after the
  // opening quote.
  if (Length(Cmd) < 2) or (Cmd[1] <> '"') then
    Exit;
  P := Pos('" ', Cmd);
  if P = 0 then
    Exit;
  Rest := Copy(Cmd, P + 1, Length(Cmd));
  NewExe := ExpandConstant('{app}\LWCAM\LWIP\runtime\python\pythonw.exe');
  if RegWriteStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
                         'LWCamLWIP', '"' + NewExe + '"' + Rest) then begin
    Log('Repointed the LWIP logon entry from the removed venv to ' + NewExe);
    Result := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PasswordFile, SeedFile, NL, Missing: String;
begin
  // Before the file copy: the running engine has to stop BEFORE its code is
  // replaced underneath it, not after.
  if CurStep = ssInstall then begin
    StopQcBackend();
    // LWIP too, since 2026-09-09. It used to be left running on purpose - a
    // worker mid-folder, not a server - but that let an upgrade overwrite its
    // .py underneath a live process, which then kept serving the code it
    // imported at startup. StopLwip drains it instead of killing it.
    StopLwip();
    Exit;
  end;

  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;

  RepointLwipAutostart();

  // Only when one was actually running, and only ever an upgrade. Saying so
  // matters because nothing restarts it here: Station Setup's save is what
  // rewrites the logon launcher and starts the engine again, and that save is
  // needed after an upgrade anyway.
  if StoppedQcBackends > 0 then
    MsgBox('The QC engine was running the previous version, so setup stopped it.' + NL + NL +
           'Open LWCam Admin, go to Station Setup and press Save to start it' + NL +
           'again on this version. Until then QC review has no server.',
           mbInformation, MB_OK);

  // Runtime check runs regardless of whether PostgreSQL was needed: these two
  // are built on every install.
  Missing := MissingRuntimes();
  if Missing <> '' then
    MsgBox('LW Suite is installed, but an offline runtime did not build:' + NL +
           Missing + NL + NL +
           'The apps will start, but the part listed above will not run until' + NL +
           'that script is run again. It needs no arguments.',
           mbError, MB_OK);

  // No server was installed because the operator said one already exists
  // elsewhere. There is no seed to hand them and no generated password to show,
  // so the closing word has to be what to type and where.
  if WizardIsTaskSelected('remotedb') then begin
    MsgBox('LW Suite is installed. No database server was installed here.' + NL + NL +
           'Open LWCam Admin - Station Setup and fill in the connection to the' + NL +
           'PC that hosts the database:' + NL + NL +
           '    Host      the hosting PC''s name or IP address' + NL +
           '    Port      5432' + NL +
           '    Database  lwcam' + NL +
           '    User      postgres' + NL +
           '    Password  the password set on THAT PC' + NL + NL +
           'Press Test connection before saving. If it fails, the host still' + NL +
           'has to allow this PC: a pg_hba.conf line for the subnet and a' + NL +
           'firewall rule for port 5432.',
           mbInformation, MB_OK);
    Exit;
  end;

  if not PgNeeded then
    Exit;

  if not PsqlOnDisk() then begin
    MsgBox('PostgreSQL could not be installed automatically.' + NL + NL +
           'Everything else is installed. QC needs a database, so install' + NL +
           'PostgreSQL yourself, then open LWCam Admin to finish setup:' + NL + NL +
           '    winget install PostgreSQL.PostgreSQL.18',
           mbError, MB_OK);
    Exit;
  end;

  // A reused cluster keeps its own password, which setup does not know, so
  // there is nothing to seed. Admin asks for it rather than inventing one.
  if PgReusedCluster then begin
    MsgBox('PostgreSQL is installed, but an existing database cluster was found' + NL +
           'on this PC and has been kept.' + NL + NL +
           'That cluster keeps its OWN password, which this setup does not know.' + NL +
           'LWCam Admin will ask you for it when it opens.',
           mbInformation, MB_OK);
    Exit;
  end;

  if PgPassword = '' then
    Exit;

  // Read by LWCam Admin on first launch, which then deletes it. Deliberately
  // minimal - just the connection. Everything else about a station Admin
  // already defaults for itself.
  SeedFile := ExpandConstant('{commonappdata}\LWCAM\station-seed.json');
  SaveStringToFile(SeedFile,
    '{' + NL +
    '  "pgHost": "localhost",' + NL +
    '  "pgPort": 5432,' + NL +
    '  "pgDatabase": "lwcam",' + NL +
    '  "pgUser": "postgres",' + NL +
    '  "pgPassword": "' + PgPassword + '"' + NL +
    '}' + NL, False);

  // Also written in plain text as the human-readable record of what setup
  // chose, for the day someone has to reach the database with another tool.
  // Program Files is admin-write and user-read, the same exposure this password
  // ends up with in lwcam_node_config.json once Admin saves it.
  PasswordFile := ExpandConstant('{app}\postgres-password.txt');
  SaveStringToFile(PasswordFile,
    'PostgreSQL 18 was installed by LW Suite setup on this PC.' + NL + NL +
    'Database user : postgres' + NL +
    'Password      : ' + PgPassword + NL + NL +
    'You should not need this. LWCam Admin picks the connection up by itself' + NL +
    'the first time it opens: it creates the database, loads the schema and' + NL +
    'saves its own settings.' + NL,
    False);
end;
