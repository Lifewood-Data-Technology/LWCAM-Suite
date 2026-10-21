; LWCam LWIP installer: the deskew/crop image-processing service.
; Runs as a SYSTEM scheduled task, watching an input share and writing to an
; output share the QC server reads from. Never installs PostgreSQL - it only
; needs a login to a database LWCamDatabaseSetup already created.

#define AppNameFull "LWCam LWIP"
#ifndef AppVer
  #define AppVer "1.0.0"
#endif
#ifndef BuildId
  #define BuildId "dev"
#endif

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define LwipDir AppsDir + "\LWIP"
#define PyEmbedZip "vendor\python-3.14.8-embed-amd64.zip"

[Setup]
AppName={#AppNameFull}
AppId={{6C1E9F44-2B7A-4D3E-8F51-9C2A6E7B4D10}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LWCam LWIP
OutputBaseFilename=LWIPSetup
OutputDir=..
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableDirPage=no
DisableProgramGroupPage=yes
ChangesAssociations=no
ShowLanguageDialog=yes
WizardStyle=modern
UninstallDisplayIcon={app}\runtime\python\python.exe
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Written by build-installer.ps1: "<version>+<commit>". Each part shows it and sends it in its heartbeat.
Source: "vendor\VERSION.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "Trust this LWCam server.cmd"; DestDir: "{app}"; Flags: ignoreversion
; LWIP source only, no tests/benchmark (siblings of this folder, so a Source
; rooted at deskew_crop_tool\* never picks them up) and no runtime bytecode.
Source: "{#LwipDir}\backend\deskew_crop_tool\*"; DestDir: "{app}\backend\deskew_crop_tool"; Flags: ignoreversion recursesubdirs; Excludes: "*.pyc,__pycache__\*"
Source: "{#LwipDir}\backend\run_calibration_task.py"; DestDir: "{app}\backend"; Flags: ignoreversion
Source: "{#LwipDir}\backend\color_cal_tool\*"; DestDir: "{app}\backend\color_cal_tool"; Flags: ignoreversion recursesubdirs; Excludes: "*.pyc,__pycache__\*"
Source: "{#LwipDir}\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LwipDir}\wheels\*"; DestDir: "{app}\wheels"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LwipDir}\requirements.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LwipDir}\SETUP_DESKEW_CROP.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LwipDir}\START_LWIP.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LwipDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#LwipDir}\README.zh-CN.md"; DestDir: "{app}"; Flags: ignoreversion

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion deleteafterinstall
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion
; jpegtran (in tools\) needs its own copy - it is not on runtime\vc's search path.
Source: "vendor\vcruntime\vcruntime140.dll"; DestDir: "{app}\tools"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime"
Name: "{app}\logs"
; No users-modify: only installers write lwip.stop here; LockProgramFolder
; (post-install) also strips the write access an older install granted.
Name: "{commonappdata}\LWCAM"

#include "common.iss"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_DESKEW_CROP.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline LWIP runtime..."

[Icons]
; The port comes from config\deskew_crop_config.json when one already exists
; (an upgrade), else 8090 - see ConfiguredUiPort in [Code].
Name: "{autoprograms}\LWIP Console"; Filename: "{code:ConsoleUrl}"

[UninstallRun]
; End before delete: deleting a running task leaves its restart loop alive.
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN ""LWCam LWIP"""; Flags: runhidden waituntilterminated; RunOnceId: "EndLwipTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""LWCam LWIP"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLwipTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam LWIP"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLwipFirewallRule"

[InstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"

[UninstallDelete]
Type: files; Name: "{app}\python-3.14.8-embed-amd64.zip"
; runtime\ is NOT removed wholesale: state.json (+ .bak) is the journal of every
; folder already processed, and without it a reinstall would reprocess them all
; over QC's edits. Only what Setup or the service can rebuild goes.
Type: filesandordirs; Name: "{app}\runtime\python"
Type: filesandordirs; Name: "{app}\runtime\vc"
Type: filesandordirs; Name: "{app}\runtime\work"
Type: filesandordirs; Name: "{app}\runtime\logs"
Type: files; Name: "{app}\runtime\.setup_ok"
Type: files; Name: "{app}\runtime\status.json"
Type: files; Name: "{app}\runtime\state.json.tmp"
Type: filesandordirs; Name: "{app}\logs"
; The private config folder: deskew_crop_config.json holds the database password.
Type: filesandordirs; Name: "{app}\config"
Type: files; Name: "{app}\LWCam server certificate.crt"
; Never the input/output folders: those are the operator's data, outside {app}.

[Code]
var
  FoldersPage: TInputDirWizardPage;
  DatabasePage: TInputQueryWizardPage;

// Used only to tell a local fixed disk from a mapped network drive letter -
// SYSTEM (this task's account) cannot see a drive mapped in someone's logon
// session, so a folder chosen that way would silently look empty to LWIP.
function GetDriveType(lpRootPathName: string): Integer;
external 'GetDriveTypeW@kernel32.dll stdcall';

// True for a UNC path (always visible to SYSTEM) or a drive-letter path whose
// root is a real local fixed disk (GetDriveType = 3 = DRIVE_FIXED). False for
// everything else, including a mapped drive letter (DRIVE_REMOTE), removable
// media, or a malformed/relative path.
function IsFixedOrUncPath(const Path: String): Boolean;
var
  Root: String;
begin
  if (Length(Path) >= 2) and (Path[1] = '\') and (Path[2] = '\') then begin
    Result := True;
    Exit;
  end;
  if (Length(Path) >= 3) and (Path[2] = ':') and (Path[3] = '\') then begin
    Root := Copy(Path, 1, 3);
    Result := GetDriveType(Root) = 3;
    Exit;
  end;
  Result := False;
end;

// True when Inner is Outer itself or somewhere below it, compared
// case-insensitively (Windows paths) with trailing backslashes normalised.
function IsPathWithin(const Inner, Outer: String): Boolean;
var
  A, B: String;
begin
  A := Lowercase(RemoveBackslash(Inner));
  B := Lowercase(RemoveBackslash(Outer));
  Result := (Length(A) > Length(B)) and (Copy(A, 1, Length(B)) = B) and (A[Length(B) + 1] = '\');
end;

procedure AppendIssue(var Issues: String; const Message: String);
begin
  if Issues <> '' then
    Issues := Issues + #13#10;
  Issues := Issues + '- ' + Message;
end;

// Minimal JSON string literal: only backslash and double-quote need escaping
// for the values this config ever holds (Windows paths, host names, logins).
function JsonString(const Value: String): String;
var
  Escaped: String;
begin
  Escaped := Value;
  StringChangeEx(Escaped, '\', '\\', True);
  StringChangeEx(Escaped, '"', '\"', True);
  Result := '"' + Escaped + '"';
end;

// Stops LWIP before its .py files are overwritten. Graceful first: the stop
// file (config.py's STOP_FILE_SHARED) makes LWIP finish the folder it is
// publishing and exit clean. Task end and process termination are the
// fallback for a wedged process. Ported from LWCam.iss's StopLwip, pointed at
// this install's own root instead of {app}\LWCAM\LWIP, plus ending the
// scheduled task LWCam.iss never had to manage.
// Returns how many LWIP processes are still alive afterwards.
function StopLwip(): Integer;
var
  Command, AppDir, StopFile: String;
  ResultCode: Integer;
begin
  Result := 0;
  AppDir := ExpandConstant('{app}');
  if not DirExists(AppDir) then
    Exit;

  StopFile := ExpandConstant('{commonappdata}\LWCAM\lwip.stop');
  ForceDirectories(ExpandConstant('{commonappdata}\LWCAM'));
  SaveStringToFile(StopFile, 'stop', False);

  // Wait up to 90 s for the graceful exit. No braces: "{" opens a constant.
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$p = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + AppDir + '*''); ' +
    'Wait-Process -Id @($p | Select-Object -ExpandProperty ProcessId) ' +
    '-Timeout 90 -ErrorAction SilentlyContinue; exit 0"';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Belt-and-braces: end the scheduled task too, in case Task Scheduler
  // restarted LWIP while the wait above was running.
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/End /TN "LWCam LWIP"', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Result := PythonProcessesUnder(AppDir, True);
  // Consume the request if LWIP was not running to read it, so it cannot
  // stop the NEXT start.
  DeleteFile(StopFile);
end;

// The Folders page's own validation, shared between NextButtonClick (the
// interactive wizard) and PrepareToInstall (a silent install - see
// NextButtonClick below for why that call site cannot use a MsgBox). Returns
// '' when both folders are usable, else the message to show.
function ValidateFoldersPage(): String;
var
  InputRoot, OutputRoot: String;
begin
  Result := '';
  InputRoot := FoldersPage.Values[0];
  OutputRoot := FoldersPage.Values[1];
  if (Trim(InputRoot) = '') or (Trim(OutputRoot) = '') then begin
    Result := 'Enter both the input and output folders.';
    Exit;
  end;
  if not IsFixedOrUncPath(InputRoot) or not IsFixedOrUncPath(OutputRoot) then begin
    Result := 'Neither folder can be on a mapped network drive letter: SYSTEM (the account ' +
      'LWIP runs as) cannot see a drive mapped in a user''s logon session. Use a UNC path ' +
      '(\\server\share) or a local fixed drive instead.';
    Exit;
  end;
  if CompareText(RemoveBackslash(InputRoot), RemoveBackslash(OutputRoot)) = 0 then begin
    Result := 'The input and output folders must be different.';
    Exit;
  end;
  if IsPathWithin(OutputRoot, InputRoot) or IsPathWithin(InputRoot, OutputRoot) then
    Result := 'The input and output folders cannot be inside one another.';
end;

// Both wizard pages only make sense on a fresh install; an upgrade keeps the
// existing config file untouched (WriteLwipConfigIfMissing already does this
// for the file itself - this just saves the operator re-typing it).
// PageID first: Inno asks this for EVERY page, including the ones before the
// directory page, and expanding {app} before a directory is chosen raises
// "An attempt was made to expand the app constant before it was initialized"
// - an error box on the wizard's first screen.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = FoldersPage.ID) or (PageID = DatabasePage.ID) then
    Result := FileExists(ExpandConstant('{app}\config\deskew_crop_config.json'));
end;

// Runs before a single file is written or deleted, so a service that will not
// stop aborts setup cleanly instead of leaving new files under old code. On a
// silent install (WizardSilent) also re-run both pages' own validation -
// NextButtonClick already ran them, but with no one there to dismiss a MsgBox
// it had to leave the pages alone (see NextButtonClick below), so this is the
// check that actually stops setup. Skipped exactly where a page itself is
// skipped: an upgrade, when deskew_crop_config.json exists.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if StopLwip() <> 0 then begin
    Result := 'The LWIP image-processing service could not be stopped, so its files ' +
      'were not replaced. Restart the PC and run setup again.';
    Exit;
  end;
  if not WizardSilent then
    Exit;
  if not ShouldSkipPage(FoldersPage.ID) then
    Result := ValidateFoldersPage();
  if (Result = '') and not ShouldSkipPage(DatabasePage.ID) then
    Result := ValidateDbPage(DatabasePage);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Msg: String;
begin
  Result := True;
  // Setup simulates every click on a silent install too, but there is no one
  // to dismiss a MsgBox - leave both pages alone and let PrepareToInstall's
  // silent-only check fail setup cleanly instead.
  if WizardSilent then
    Exit;

  if (FoldersPage <> nil) and (CurPageID = FoldersPage.ID) then begin
    Msg := ValidateFoldersPage();
    if Msg <> '' then begin
      MsgBox(Msg, mbError, MB_OK);
      Result := False;
    end;
    Exit;
  end;

  if (DatabasePage = nil) or (CurPageID <> DatabasePage.ID) then
    Exit;
  Msg := ValidateDbPage(DatabasePage);
  if Msg <> '' then begin
    MsgBox(Msg, mbError, MB_OK);
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  FoldersPage := CreateInputDirPage(wpSelectDir,
    'LWIP folders', 'Where LWIP reads captures and writes results',
    'Input folder is where LWCAM copies finished captures for LWIP to watch, usually a ' +
    'network share. Output folder is where LWIP writes deskewed, cropped results - set this ' +
    'as the QC server''s QC input root. Recommend UNC paths (\\server\share) so capture PCs, ' +
    'LWIP and QC all agree on the same path; a mapped drive letter is refused.',
    False, '');
  FoldersPage.Add('Input folder (LWCAM copies captures here)');
  FoldersPage.Add('Output folder (LWIP output, read by QC)');
  // Defaults come from the command line (/INPUTROOT=, /OUTPUTROOT=), read
  // here so a silent install picks them up even though nothing ever shows
  // this page.
  FoldersPage.Values[0] := ExpandConstant('{param:INPUTROOT|}');
  FoldersPage.Values[1] := ExpandConstant('{param:OUTPUTROOT|}');

  DatabasePage := CreateInputQueryPage(FoldersPage.ID,
    'PostgreSQL connection',
    'Connect LWIP to the PostgreSQL database',
    'LWIP reports each finished folder to the database itself, so a batch reaches the QC ' +
    'queue even while LWCAM is closed. Enter the host this PC uses and the one database login ' +
    'LWCamDatabaseSetup''s finish page shows (database, user and password).');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Port', False);
  DatabasePage.Add('Database', False);
  DatabasePage.Add('User', False);
  DatabasePage.Add('Password', True);
  // Defaults come from the command line (/DBHOST=, /DBPORT=, /DBNAME=,
  // /DBUSER=, /DBPASSWORD=), read here for the same reason. The port is
  // always filled in (5432) and can be edited.
  DatabasePage.Values[0] := ExpandConstant('{param:DBHOST|}');
  DatabasePage.Values[1] := ExpandConstant('{param:DBPORT|5432}');
  DatabasePage.Values[2] := ExpandConstant('{param:DBNAME|lwcam}');
  DatabasePage.Values[3] := ExpandConstant('{param:DBUSER|lwcam_user}');
  DatabasePage.Values[4] := ExpandConstant('{param:DBPASSWORD|}');
end;

// config.json holds the database password, so it lives in its own folder,
// {app}\config, and it is the FOLDER that is private (SYSTEM and
// Administrators, inherited by everything inside) - ported from
// QCPlatform.iss's ProtectQcConfig. Unlike that config, nothing rewrites this
// file after setup (there is no console save), so there is no live temp file
// to worry about.
function ProtectLwipConfig(): Boolean;
var
  Dir: String;
begin
  Dir := ExpandConstant('{app}\config');
  Result := ForceDirectories(Dir) and RestrictToAdmins(Dir, True);
  if not Result then
    Exit;
  if FileExists(Dir + '\deskew_crop_config.json') then
    Result := RestrictToAdmins(Dir + '\deskew_crop_config.json', False);
end;

// Writes config\deskew_crop_config.json only if it does not already exist, so
// an upgrade never touches settings an operator may have hand-edited since.
// Keys not written here (recursive, extensions, jpeg_quality,
// deskew_min_degrees, poll/stable/age intervals, thumbnail_quality/dirname)
// are left to config.py's own defaults, which already match what
// lwip_config_writer.dart's buildLwipConfig writes for them today.
function WriteLwipConfigIfMissing(): Boolean;
var
  ConfigPath, ConfigText, NL: String;
begin
  ConfigPath := ExpandConstant('{app}\config\deskew_crop_config.json');
  ForceDirectories(ExtractFileDir(ConfigPath));
  if FileExists(ConfigPath) then begin
    Result := True;
    Exit;
  end;

  NL := #13#10;
  ConfigText :=
    '{' + NL +
    '  "input_root": ' + JsonString(FoldersPage.Values[0]) + ',' + NL +
    '  "output_root": ' + JsonString(FoldersPage.Values[1]) + ',' + NL +
    '  "work_root": ' + JsonString(ExpandConstant('{app}\runtime\work')) + ',' + NL +
    '  "state_file": ' + JsonString(ExpandConstant('{app}\runtime\state.json')) + ',' + NL +
    '  "log_file": ' + JsonString(ExpandConstant('{app}\logs\lwip.log')) + ',' + NL +
    '  "workers": 0,' + NL +
    '  "crop_padding": 200,' + NL +
    '  "folder_depth": 2,' + NL +
    '  "completion_marker": "lwcam_capture_marker.json",' + NL +
    '  "thumbnail_width": 512,' + NL +
    '  "presence_check_interval_seconds": 315360000,' + NL +
    '  "checksum_check_interval_seconds": 315360000,' + NL +
    '  "cloud_report": true,' + NL +
    '  "db_host": ' + JsonString(DatabasePage.Values[0]) + ',' + NL +
    '  "db_port": ' + IntToStr(StrToIntDef(DatabasePage.Values[1], 5432)) + ',' + NL +
    '  "db_name": ' + JsonString(DatabasePage.Values[2]) + ',' + NL +
    '  "db_user": ' + JsonString(DatabasePage.Values[3]) + ',' + NL +
    '  "db_password": ' + JsonString(DatabasePage.Values[4]) + ',' + NL +
    '  "db_use_ssl": false,' + NL +
    // The console's own port/bind - written once here so a fresh install has
    // a value to read back; ConfiguredUiPort() re-reads this on every upgrade
    // so an operator's later edit survives.
    '  "ui_port": 8090,' + NL +
    '  "ui_bind": "0.0.0.0"' + NL +
    '}' + NL;
  Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
end;

// The console's port: ui_port in config\deskew_crop_config.json, else 8090.
// A tolerant TEXT search, not JSON parsing, because this must still return an
// answer (for the firewall rule and the shortcut) when the file has been
// hand-edited into something config.py's real loader would reject. Finds the
// key, the ':' after it, and the digits after that - good enough for the
// plain, LWIP-written form "ui_port": 8090 and tolerant of surrounding
// whitespace either side of the colon.
function ConfiguredUiPort(): String;
var
  Raw: AnsiString;
  Content, Digits: String;
  P: Integer;
begin
  Result := '8090';
  if not LoadStringFromFile(ExpandConstant('{app}\config\deskew_crop_config.json'), Raw) then
    Exit;
  Content := String(Raw);
  P := Pos('"ui_port"', Content);
  if P = 0 then
    Exit;
  P := P + Length('"ui_port"');
  while (P <= Length(Content)) and (Content[P] <> ':') do
    P := P + 1;
  P := P + 1;
  while (P <= Length(Content)) and (Content[P] = ' ') do
    P := P + 1;
  Digits := '';
  while (P <= Length(Content)) and (Content[P] >= '0') and (Content[P] <= '9') do begin
    Digits := Digits + Content[P];
    P := P + 1;
  end;
  if (Length(Digits) > 0) and (StrToIntDef(Digits, 0) >= 1) and (StrToIntDef(Digits, 0) <= 65535) then
    Result := Digits;
end;

function ConsoleUrl(Param: String): String;
begin
  Result := 'https://localhost:' + ConfiguredUiPort() + '/';
end;

// Runtime and task registration; problems are collected rather than raised so
// one failure (e.g. a runtime that failed to build) does not hide another.
procedure ConfigureLwip(var Issues: String);
var
  Port: String;
  ResultCode: Integer;
begin
  if not FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then
    AppendIssue(Issues, 'The private Python runtime did not build. Run SETUP_DESKEW_CROP.bat as Administrator.');

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port. The delete
  // "fails" harmlessly on a first install, when there is no rule yet.
  Port := ConfiguredUiPort();
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LWCam LWIP"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam LWIP" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=any remoteip=localsubnet,100.64.0.0/10,fd7a:115c:a1e0::/48',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The Windows Firewall rule for TCP ' + Port + ' could not be added.');

  // No run-time limit, restart after a failure: see RegisterBootTask.
  if not RegisterBootTask('LWCam LWIP', ExpandConstant('{app}\START_LWIP.bat')) then
    AppendIssue(Issues, 'The LWCam LWIP startup task could not be registered.')
  else if not Exec(ExpandConstant('{sys}\schtasks.exe'),
       '/Run /TN "LWCam LWIP"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
       (ResultCode <> 0) then
    AppendIssue(Issues, 'The task was registered but could not be started.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, Closing, NL: String;
begin
  // LWIP was already stopped in PrepareToInstall, before any file changed.
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  Issues := '';
  // Program folders first, before the task exists: code that runs as SYSTEM
  // must not be replaceable by an ordinary user, and the shared stop-file
  // folder must not be writable by one (an old install made it users-modify).
  // config\ and network-logins\ keep their own lists.
  if not LockProgramFolder(ExpandConstant('{app}')) then
    AppendIssue(Issues, 'The install folder could not be locked to Administrators; check its permissions.');
  if not LockProgramFolder(ExpandConstant('{commonappdata}\LWCAM')) then
    AppendIssue(Issues, 'The shared folder ' + ExpandConstant('{commonappdata}\LWCAM') +
      ' could not be locked to Administrators.');
  // Private folder first, secrets second: the file inherits the folder's
  // restricted permissions when it is created, so there is no moment when it
  // is readable.
  if not ProtectLwipConfig() then begin
    Log('LWCam LWIP: the config folder could not be restricted; nothing was written.');
    SuppressibleMsgBox('The config folder could not be restricted to SYSTEM and Administrators, so no' +
      NL + 'config file was written and LWIP was not started: that file holds the database' +
      NL + 'password. Check the folder''s permissions, then run setup again.',
      mbError, MB_OK, IDOK);
    Exit;
  end;
  if not WriteLwipConfigIfMissing() then begin
    Log('LWCam LWIP: the config file could not be written.');
    SuppressibleMsgBox('The LWIP config file could not be written. LWIP was not started.',
      mbError, MB_OK, IDOK);
    Exit;
  end;

  // https certificate for the web page; without it the page stays plain http.
  if not SetUpTls(ExpandConstant('{app}\runtime\python\python.exe'), 'deskew_crop_tool.tls',
       ExpandConstant('{app}\backend'), ExpandConstant('{app}\config\deskew_crop_config.json')) then
    AppendIssue(Issues, 'The https certificate could not be created, so the page is plain http. Run setup again as Administrator.');

  if not ProtectConfigSecrets(ExpandConstant('{app}\runtime\python\python.exe'), '-m deskew_crop_tool.lwcam_secrets',
       ExpandConstant('{app}\backend'), ExpandConstant('{app}\config\deskew_crop_config.json'), 'db_password') then
    AppendIssue(Issues, PlainSecretsWarning('config\deskew_crop_config.json') + ' LWIP encrypts them itself when it starts.');

  ConfigureLwip(Issues);

  Closing := 'LWCam LWIP is installed.' + NL + NL +
    'Console: https://' + GetComputerNameString() + ':' + ConfiguredUiPort() + '/' + NL + NL + TlsClosingNote();
  if Issues <> '' then
    Closing := Closing + NL + NL + 'Setup needs attention:' + NL + Issues;
  Log('LWCam LWIP finished:' + NL + Closing);
  SuppressibleMsgBox(Closing, mbInformation, MB_OK, IDOK);
end;

// Bytecode LWIP writes at runtime, never installed by Setup and so never
// tracked by it. Removed BEFORE the uninstaller's own folder cleanup: that
// cleanup only removes a folder it created if it ends up EMPTY, and a
// leftover __pycache__ would otherwise leave {app}\backend\deskew_crop_tool
// behind as an empty shell (see QCPlatform.iss's DeleteRuntimeLeftovers,
// which this mirrors - deskew_crop_tool has no sub-packages of its own, so
// there is only the one path).
procedure DeleteLwipRuntimeLeftovers();
begin
  DelTree(ExpandConstant('{app}\backend\deskew_crop_tool\__pycache__'), True, True, True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    if StopLwip() <> 0 then
      Log('Uninstall: an LWIP process under the install folder did not stop.');
    DeleteLwipRuntimeLeftovers();
  end;
end;
