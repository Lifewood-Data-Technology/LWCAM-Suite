; LWCam Upload installer: the standalone S3 upload service.
; Runs as a SYSTEM scheduled task, watching the QC server's export output and
; sending published packages to S3. Never installs PostgreSQL - it only needs
; a login to a database LWCamDatabaseSetup already created, and only to check
; who is signed in to its own console.

#define AppNameFull "LWCam Upload"
#define AppVer "1.0.0"

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define UploadDir AppsDir + "\LWCam_Upload"
#define PyEmbedZip "vendor\python-3.13.14-embed-amd64.zip"

[Setup]
AppName={#AppNameFull}
AppId={{88E475D0-0555-4581-8943-DC3B78BA5F49}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LWCam Upload
OutputBaseFilename=LWCamUploadSetup
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
; Upload source only, no tests, and no runtime bytecode.
Source: "{#UploadDir}\backend\lwcam_upload\*"; DestDir: "{app}\backend\lwcam_upload"; Flags: ignoreversion recursesubdirs; Excludes: "*.pyc,__pycache__\*"
Source: "{#UploadDir}\wheels\*"; DestDir: "{app}\wheels"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#UploadDir}\requirements.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#UploadDir}\SETUP_UPLOAD.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#UploadDir}\START_UPLOAD.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#UploadDir}\README.txt"; DestDir: "{app}"; Flags: ignoreversion

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime"
Name: "{app}\logs"

#include "common.iss"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_UPLOAD.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline Upload runtime..."

[Icons]
; The port comes from config\upload_config.json when one already exists
; (an upgrade), else 8091 - see ConfiguredUiPort in [Code].
Name: "{autoprograms}\Upload Console"; Filename: "{code:ConsoleUrl}"

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""LWCam Upload"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveUploadTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam Upload"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveUploadFirewallRule"

[UninstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\logs"
; The private config folder: upload_config.json holds the database password
; and the S3 secret key.
Type: filesandordirs; Name: "{app}\config"
; Never the watched/done/summary folders: those are the operator's data,
; outside {app}.

[Code]
var
  FoldersPage: TInputDirWizardPage;
  S3Page: TInputQueryWizardPage;
  DatabasePage: TInputQueryWizardPage;

// Used only to tell a local fixed disk from a mapped network drive letter -
// SYSTEM (this task's account) cannot see a drive mapped in someone's logon
// session, so a folder chosen that way would silently look empty to Upload.
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
// for the values this config ever holds (Windows paths, host names, logins,
// an S3 key).
function JsonString(const Value: String): String;
var
  Escaped: String;
begin
  Escaped := Value;
  StringChangeEx(Escaped, '\', '\\', True);
  StringChangeEx(Escaped, '"', '\"', True);
  Result := '"' + Escaped + '"';
end;

// Stops Upload before its .py files are overwritten. Graceful first: the stop
// file (engine.py's own poll, between packages and every second while idle)
// makes Upload finish the package it is sending and exit clean. Task end and
// process termination are the fallback for a wedged process. Modelled on
// LWIP.iss's StopLwip, but the stop file lives under this install's own
// runtime folder - Upload has no {commonappdata} marker to share with anyone
// else. Returns how many Upload processes are still alive afterwards.
function StopUpload(): Integer;
var
  Command, AppDir, StopFile: String;
  ResultCode: Integer;
begin
  Result := 0;
  AppDir := ExpandConstant('{app}');
  if not DirExists(AppDir) then
    Exit;

  StopFile := ExpandConstant('{app}\runtime\stop.request');
  ForceDirectories(ExpandConstant('{app}\runtime'));
  SaveStringToFile(StopFile, 'stop', False);

  // Wait up to 60 s for the graceful exit. No braces: "{" opens a constant.
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$p = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + AppDir + '*''); ' +
    'Wait-Process -Id @($p | Select-Object -ExpandProperty ProcessId) ' +
    '-Timeout 60 -ErrorAction SilentlyContinue; exit 0"';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Belt-and-braces: end the scheduled task too, in case Task Scheduler
  // restarted Upload while the wait above was running.
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/End /TN "LWCam Upload"', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Result := PythonProcessesUnder(AppDir, True);
  // Consume the request if Upload was not running to read it, so it cannot
  // stop the NEXT start.
  DeleteFile(StopFile);
end;

// Runs before a single file is written or deleted, so a service that will not
// stop aborts setup cleanly instead of leaving new files under old code.
// The Folders page's own validation, shared between NextButtonClick (the
// interactive wizard) and PrepareToInstall (a silent install - see
// NextButtonClick below for why that call site cannot use a MsgBox). Returns
// '' when the three folders are usable, else the message to show.
function ValidateFoldersPage(): String;
var
  WatchRoot, DoneRoot, SummaryRoot: String;
begin
  Result := '';
  WatchRoot := FoldersPage.Values[0];
  DoneRoot := FoldersPage.Values[1];
  SummaryRoot := FoldersPage.Values[2];
  if Trim(WatchRoot) = '' then begin
    Result := 'Enter the watch folder.';
    Exit;
  end;
  if not IsFixedOrUncPath(WatchRoot) then begin
    Result := 'The watch folder cannot be on a mapped network drive letter: SYSTEM (the ' +
      'account Upload runs as) cannot see a drive mapped in a user''s logon session. Use ' +
      'a UNC path (\\server\share) or a local fixed drive instead.';
    Exit;
  end;
  if Trim(DoneRoot) <> '' then begin
    if not IsFixedOrUncPath(DoneRoot) then begin
      Result := 'The Uploaded folder cannot be on a mapped network drive letter. Use a UNC ' +
        'path (\\server\share) or a local fixed drive, or leave it blank.';
      Exit;
    end;
    if IsPathWithin(DoneRoot, WatchRoot) then begin
      Result := 'The Uploaded folder cannot be inside the watch folder.';
      Exit;
    end;
  end;
  if Trim(SummaryRoot) <> '' then begin
    if not IsFixedOrUncPath(SummaryRoot) then begin
      Result := 'The Upload Reports folder cannot be on a mapped network drive letter. Use a ' +
        'UNC path (\\server\share) or a local fixed drive, or leave it blank.';
      Exit;
    end;
    if IsPathWithin(SummaryRoot, WatchRoot) then
      Result := 'The Upload Reports folder cannot be inside the watch folder.';
  end;
end;

// The S3 page's own validation, shared the same way as ValidateFoldersPage.
function ValidateS3Page(): String;
var
  S3Path, S3Region, S3AccessKey, S3SecretKey: String;
begin
  Result := '';
  S3Path := S3Page.Values[0];
  S3Region := S3Page.Values[1];
  S3AccessKey := S3Page.Values[2];
  S3SecretKey := S3Page.Values[3];
  if (Trim(S3Path) = '') or (Trim(S3Region) = '') or (Trim(S3AccessKey) = '') or (S3SecretKey = '') then begin
    Result := 'Enter the S3 path, region, access key and secret key.';
    Exit;
  end;
  if Copy(S3Path, 1, 5) <> 's3://' then begin
    Result := 'The S3 path must start with s3:// (for example s3://my-bucket/prefix).';
    Exit;
  end;
  if (S3Path <> Trim(S3Path)) or (S3Region <> Trim(S3Region)) or
     (S3AccessKey <> Trim(S3AccessKey)) or (S3SecretKey <> Trim(S3SecretKey)) then begin
    Result := 'S3 settings cannot start or end with a space.';
    Exit;
  end;
  if HasConfigControl(S3Path) or HasConfigControl(S3Region) or HasConfigControl(S3AccessKey) or
     HasConfigControl(S3SecretKey) then
    Result := 'S3 settings cannot contain line breaks or control characters.';
end;

// All three wizard pages only make sense on a fresh install; an upgrade keeps
// the existing config file untouched (WriteUploadConfigIfMissing already does
// this for the file itself - this just saves the operator re-typing it).
// PageID first: Inno asks this for EVERY page, including the ones before the
// directory page, and expanding {app} before a directory is chosen raises
// "An attempt was made to expand the app constant before it was initialized"
// - an error box on the wizard's first screen.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = FoldersPage.ID) or (PageID = S3Page.ID) or (PageID = DatabasePage.ID) then
    Result := FileExists(ExpandConstant('{app}\config\upload_config.json'));
end;

// Runs before a single file is written or deleted, so a service that will not
// stop aborts setup cleanly instead of leaving new files under old code. On a
// silent install (WizardSilent) also re-run all three pages' own validation -
// NextButtonClick already ran them, but with no one there to dismiss a MsgBox
// it had to leave the pages alone (see NextButtonClick below), so this is the
// check that actually stops setup. Skipped exactly where a page itself is
// skipped: an upgrade, when upload_config.json exists.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if StopUpload() <> 0 then begin
    Result := 'The LWCam Upload service could not be stopped, so its files ' +
      'were not replaced. Restart the PC and run setup again.';
    Exit;
  end;
  if not WizardSilent then
    Exit;
  if not ShouldSkipPage(FoldersPage.ID) then
    Result := ValidateFoldersPage();
  if (Result = '') and not ShouldSkipPage(S3Page.ID) then
    Result := ValidateS3Page();
  if (Result = '') and not ShouldSkipPage(DatabasePage.ID) then
    Result := ValidateDbPage(DatabasePage);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Msg: String;
begin
  Result := True;
  // Setup simulates every click on a silent install too, but there is no one
  // to dismiss a MsgBox - leave every page alone and let PrepareToInstall's
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

  if (S3Page <> nil) and (CurPageID = S3Page.ID) then begin
    Msg := ValidateS3Page();
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
    'Upload folders', 'Where Upload watches for packages and files them away',
    'Watch folder is the QC server''s export output - the same path as its QC output root - ' +
    'where Upload looks for finished packages to send to S3. Uploaded folder is where a sent ' +
    'package is moved to; leave it blank to leave packages in place. Upload Reports folder ' +
    'holds Upload_Summary.db3; leave it blank for no summary. Recommend UNC paths ' +
    '(\\server\share) so the QC server and Upload agree on the same watch folder; a mapped ' +
    'drive letter is refused.',
    False, '');
  FoldersPage.Add('Watch folder (QC server''s export output)');
  FoldersPage.Add('Uploaded folder (optional - blank leaves packages in place)');
  FoldersPage.Add('Upload Reports folder (optional - blank writes no summary)');
  // Defaults come from the command line (/WATCHROOT=, /DONEROOT=,
  // /SUMMARYROOT=), read here so a silent install picks them up even though
  // nothing ever shows this page.
  FoldersPage.Values[0] := ExpandConstant('{param:WATCHROOT|}');
  FoldersPage.Values[1] := ExpandConstant('{param:DONEROOT|}');
  FoldersPage.Values[2] := ExpandConstant('{param:SUMMARYROOT|}');

  S3Page := CreateInputQueryPage(FoldersPage.ID,
    'S3 destination',
    'Where Upload sends finished packages',
    'Enter the S3 bucket (and optional prefix) and the credentials Upload signs its PUTs ' +
    'with.');
  S3Page.Add('S3 path (s3://bucket/optional-prefix)', False);
  S3Page.Add('Region', False);
  S3Page.Add('Access key', False);
  S3Page.Add('Secret key', True);
  // Defaults come from the command line (/S3PATH=, /S3REGION=,
  // /S3ACCESSKEY=, /S3SECRET=), read here for the same reason.
  S3Page.Values[0] := ExpandConstant('{param:S3PATH|}');
  S3Page.Values[1] := ExpandConstant('{param:S3REGION|}');
  S3Page.Values[2] := ExpandConstant('{param:S3ACCESSKEY|}');
  S3Page.Values[3] := ExpandConstant('{param:S3SECRET|}');

  DatabasePage := CreateInputQueryPage(S3Page.ID,
    'PostgreSQL connection',
    'Connect the Upload console to the PostgreSQL database',
    'Upload signs console users in against the same accounts the QC server and LWIP use. ' +
    'Enter the host this PC uses and the login created by LWCamDatabaseSetup.');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Port', False);
  DatabasePage.Add('User', False);
  DatabasePage.Add('Password', True);
  // Defaults come from the command line (/DBHOST=, /DBPORT=, /DBUSER=,
  // /DBPASSWORD=), read here for the same reason.
  DatabasePage.Values[0] := ExpandConstant('{param:DBHOST|}');
  DatabasePage.Values[1] := ExpandConstant('{param:DBPORT|5432}');
  DatabasePage.Values[2] := ExpandConstant('{param:DBUSER|postgres}');
  DatabasePage.Values[3] := ExpandConstant('{param:DBPASSWORD|}');
end;

// upload_config.json holds the database password and the S3 secret key, so it
// lives in its own folder, {app}\config, and it is the FOLDER that is private
// (SYSTEM and Administrators, inherited by everything inside) - ported from
// QCPlatform.iss's ProtectQcConfig. Unlike LWIP's config, the console DOES
// rewrite this file on save (POST /api/settings), so a save's temp file needs
// the same protection: secured here, and any leftover from an interrupted
// save is removed rather than trusted.
function ProtectUploadConfig(): Boolean;
var
  Dir: String;
begin
  Dir := ExpandConstant('{app}\config');
  Result := ForceDirectories(Dir) and RestrictToAdmins(Dir, True);
  if not Result then
    Exit;
  if FileExists(Dir + '\.upload_config.json.tmp') then begin
    RestrictToAdmins(Dir + '\.upload_config.json.tmp', False);
    if not DeleteFile(Dir + '\.upload_config.json.tmp') then begin
      Log('Could not remove a leftover ' + Dir + '\.upload_config.json.tmp');
      Result := False;
      Exit;
    end;
  end;
  if FileExists(Dir + '\upload_config.json') then
    Result := RestrictToAdmins(Dir + '\upload_config.json', False);
end;

// Writes config\upload_config.json only if it does not already exist, so an
// upgrade never touches settings an operator (or a console save) may have
// changed since.
function WriteUploadConfigIfMissing(): Boolean;
var
  ConfigPath, ConfigText, NL: String;
begin
  ConfigPath := ExpandConstant('{app}\config\upload_config.json');
  ForceDirectories(ExtractFileDir(ConfigPath));
  if FileExists(ConfigPath) then begin
    Result := True;
    Exit;
  end;

  NL := #13#10;
  ConfigText :=
    '{' + NL +
    '  "watch_root": ' + JsonString(FoldersPage.Values[0]) + ',' + NL +
    '  "done_root": ' + JsonString(FoldersPage.Values[1]) + ',' + NL +
    '  "summary_root": ' + JsonString(FoldersPage.Values[2]) + ',' + NL +
    '  "enabled": true,' + NL +
    '  "s3_path": ' + JsonString(S3Page.Values[0]) + ',' + NL +
    '  "s3_region": ' + JsonString(S3Page.Values[1]) + ',' + NL +
    '  "s3_access_key": ' + JsonString(S3Page.Values[2]) + ',' + NL +
    '  "s3_secret_key": ' + JsonString(S3Page.Values[3]) + ',' + NL +
    '  "interval_seconds": 60,' + NL +
    '  "state_file": ' + JsonString(ExpandConstant('{app}\runtime\uploads.json')) + ',' + NL +
    '  "log_file": ' + JsonString(ExpandConstant('{app}\logs\upload.log')) + ',' + NL +
    '  "db_host": ' + JsonString(DatabasePage.Values[0]) + ',' + NL +
    '  "db_port": ' + IntToStr(StrToIntDef(DatabasePage.Values[1], 5432)) + ',' + NL +
    '  "db_name": "lwcam",' + NL +
    '  "db_user": ' + JsonString(DatabasePage.Values[2]) + ',' + NL +
    '  "db_password": ' + JsonString(DatabasePage.Values[3]) + ',' + NL +
    '  "db_use_ssl": false,' + NL +
    // The console's own port/bind - written once here so a fresh install has
    // a value to read back; ConfiguredUiPort() re-reads this on every upgrade
    // so an operator's later edit survives.
    '  "ui_port": 8091,' + NL +
    '  "ui_bind": "0.0.0.0"' + NL +
    '}' + NL;
  Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
end;

// The console's port: ui_port in config\upload_config.json, else 8091. A
// tolerant TEXT search, not JSON parsing, because this must still return an
// answer (for the firewall rule and the shortcut) when the file has been
// hand-edited into something config.py's real loader would reject. Finds the
// key, the ':' after it, and the digits after that - good enough for the
// plain, Upload-written form "ui_port": 8091 and tolerant of surrounding
// whitespace either side of the colon.
function ConfiguredUiPort(): String;
var
  Raw: AnsiString;
  Content, Digits: String;
  P: Integer;
begin
  Result := '8091';
  if not LoadStringFromFile(ExpandConstant('{app}\config\upload_config.json'), Raw) then
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
  Result := 'http://localhost:' + ConfiguredUiPort() + '/';
end;

// Runtime and task registration; problems are collected rather than raised so
// one failure (e.g. a runtime that failed to build) does not hide another.
procedure ConfigureUpload(var Issues: String);
var
  Params, StartCommand, Port: String;
  ResultCode: Integer;
begin
  if not FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then
    AppendIssue(Issues, 'The private Python runtime did not build. Run SETUP_UPLOAD.bat as Administrator.');

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port. The delete
  // "fails" harmlessly on a first install, when there is no rule yet.
  Port := ConfiguredUiPort();
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LWCam Upload"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam Upload" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=domain,private',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The Windows Firewall rule for TCP ' + Port + ' could not be added.');

  // /TR takes the whole command as ONE argument, and the path has spaces, so it
  // is quoted inside the quoted argument: /TR "\"C:\...\START_UPLOAD.bat\"".
  StartCommand := ExpandConstant('{app}\START_UPLOAD.bat');
  Params := '/Create /TN "LWCam Upload" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"' +
    StartCommand + '\"" /F';
  if not Exec(ExpandConstant('{sys}\schtasks.exe'), Params, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The LWCam Upload startup task could not be registered.')
  else if not Exec(ExpandConstant('{sys}\schtasks.exe'),
       '/Run /TN "LWCam Upload"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
       (ResultCode <> 0) then
    AppendIssue(Issues, 'The task was registered but could not be started.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, Closing, NL: String;
begin
  // Upload was already stopped in PrepareToInstall, before any file changed.
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  // Private folder first, secrets second: the file inherits the folder's
  // restricted permissions when it is created, so there is no moment when it
  // is readable.
  if not ProtectUploadConfig() then begin
    Log('LWCam Upload: the config folder could not be restricted; nothing was written.');
    SuppressibleMsgBox('The config folder could not be restricted to SYSTEM and Administrators, so no' +
      NL + 'config file was written and Upload was not started: that file holds the' +
      NL + 'database password and the S3 secret key. Check the folder''s permissions, then' +
      NL + 'run setup again.',
      mbError, MB_OK, IDOK);
    Exit;
  end;
  if not WriteUploadConfigIfMissing() then begin
    Log('LWCam Upload: the config file could not be written.');
    SuppressibleMsgBox('The Upload config file could not be written. Upload was not started.',
      mbError, MB_OK, IDOK);
    Exit;
  end;

  Issues := '';
  ConfigureUpload(Issues);

  Closing := 'LWCam Upload is installed.' + NL + NL +
    'Config : ' + ExpandConstant('{app}\config\upload_config.json') + NL +
    'Logs   : ' + ExpandConstant('{app}\logs') +
      ' (upload.log from the tool itself, service.log from the task wrapper)' + NL + NL +
    'Console: http://' + GetComputerNameString() + ':' + ConfiguredUiPort() +
      '/ (sign in with an Admin or SuperAdmin account)' + NL + NL +
    'This PC''s computer account needs modify access to the watched share, the Uploaded' + NL +
    'folder and the Upload Reports folder if either is set - SYSTEM cannot use a drive' + NL +
    'letter mapped in someone''s logon session.';
  if Issues <> '' then
    Closing := Closing + NL + NL + 'Setup needs attention:' + NL + Issues;
  Log('LWCam Upload finished:' + NL + Closing);
  SuppressibleMsgBox(Closing, mbInformation, MB_OK, IDOK);
end;

// Bytecode Upload writes at runtime, never installed by Setup and so never
// tracked by it. Removed BEFORE the uninstaller's own folder cleanup: that
// cleanup only removes a folder it created if it ends up EMPTY, and a
// leftover __pycache__ would otherwise leave {app}\backend\lwcam_upload
// behind as an empty shell (see QCPlatform.iss's DeleteRuntimeLeftovers,
// which this mirrors - lwcam_upload has no sub-packages of its own, so there
// is only the one path).
procedure DeleteUploadRuntimeLeftovers();
begin
  DelTree(ExpandConstant('{app}\backend\lwcam_upload\__pycache__'), True, True, True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    if StopUpload() <> 0 then
      Log('Uninstall: an Upload process under the install folder did not stop.');
    DeleteUploadRuntimeLeftovers();
  end;
end;
