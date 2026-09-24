; LWCam QC Platform installer: standalone LAN server and Vue console.

#define AppNameFull "LWCam QC Platform"
#define AppVer "1.0.0"

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define QcBackend AppsDir + "\LWCam_QC_Platform\backend"
#define QcDatabase AppsDir + "\LWCam_QC_Platform\database"
#define QcScripts AppsDir + "\LWCam_QC_Platform\scripts"
#define QcDist AppsDir + "\LWCam_QC_Platform\frontend\dist"
#define PyEmbedZip "vendor\python-3.13.14-embed-amd64.zip"

[Setup]
AppName={#AppNameFull}
AppId={{A2B7EBA5-010D-4AB8-A431-CA9E4FE0EA74}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LWCam QC Platform
OutputBaseFilename=QCPlatformSetup
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
; Ship runtime code and the offline wheelhouse, but no development state.
Source: "{#QcBackend}\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs; Excludes: ".venv\*,.cache\*,*.pyc,__pycache__\*,.pytest_cache\*,.env,tests\*,conftest.py,Dockerfile,.dockerignore,.gitignore,pyproject.toml,.env.example,requirements-dev.txt,app\Luminance Correction\README.txt,app\Luminance Correction\requirements.txt"
Source: "{#QcDatabase}\*"; DestDir: "{app}\database"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#QcScripts}\setup_qc_db.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#QcDist}\*"; DestDir: "{app}\frontend\dist"; Flags: ignoreversion recursesubdirs createallsubdirs

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion

; Installer-managed launch and recovery scripts.
Source: "qc\SETUP_QC.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "qc\SETUP_DB.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "qc\START_QC_SERVER.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "qc\OPEN_QC_LOG.bat"; DestDir: "{app}\logs"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime\python"
Name: "{app}\runtime\vc"
Name: "{app}\Export"
Name: "{app}\Export Work"
Name: "{app}\Uploaded"
Name: "{app}\Upload Reports"
Name: "{app}\logs"

#include "postgres.iss"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_QC.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline QC server runtime..."

[Icons]
; The port comes from config\config.txt when one already exists (an upgrade), else 8080.
Name: "{autoprograms}\LWCam QC Platform\QC Console"; Filename: "{code:ConsoleUrl}"
Name: "{autoprograms}\LWCam QC Platform\QC server log"; Filename: "{app}\logs\OPEN_QC_LOG.bat"

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""LWCam QC Server"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveQcServerTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam QC Server"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveQcFirewallRule"

[UninstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
Type: files; Name: "{app}\database\.setup_ok"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\backend\.cache"
; The private config folder: config.txt holds the database password.
Type: filesandordirs; Name: "{app}\config"

[Code]
var
  DatabasePage: TInputQueryWizardPage;

// Stops the server before anything under {app} changes. Returns how many of
// its python processes are still alive afterwards (0 = safe to replace files).
function StopQcServer(): Integer;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\schtasks.exe'),
       '/End /TN "LWCam QC Server"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := PythonProcessesUnder(ExpandConstant('{app}'), True);
end;

// Runs before a single file is written or deleted, so a server that will not
// stop aborts setup cleanly instead of leaving new files under old code.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PostgreSqlPrepareProblem();
  if Result <> '' then
    Exit;
  if StopQcServer() <> 0 then
    Result := 'The running LWCam QC server could not be stopped, so its files were not ' +
      'replaced. Close anything running from ' + ExpandConstant('{app}') +
      ' (or restart the PC) and run setup again.';
end;

// The port the server listens on: `port = N` in config.txt, else 8080. Used
// for the firewall rule and the console URL, so both follow a changed port.
function ConfiguredPort(): String;
var
  Lines: TArrayOfString;
  I, Eq, Number: Integer;
  Line: String;
begin
  Result := '8080';
  if not LoadStringsFromFile(ExpandConstant('{app}\config\config.txt'), Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    Eq := Pos('=', Line);
    if (Eq > 0) and (Copy(Line, 1, 1) <> '#') and
       (CompareText(Trim(Copy(Line, 1, Eq - 1)), 'port') = 0) then begin
      Number := StrToIntDef(Trim(Copy(Line, Eq + 1, Length(Line))), 0);
      if (Number > 0) and (Number < 65536) then
        Result := IntToStr(Number);
    end;
  end;
end;

function ConsoleUrl(Param: String): String;
begin
  Result := 'http://localhost:' + ConfiguredPort() + '/';
end;

function HasConfigControl(const Value: String): Boolean;
var
  I, C: Integer;
begin
  Result := False;
  for I := 1 to Length(Value) do begin
    C := Ord(Value[I]);
    if (C < 32) or (C = 127) or (C = 133) or (C = 8232) or (C = 8233) then begin
      Result := True;
      Exit;
    end;
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (DatabasePage <> nil) and (PageID = DatabasePage.ID) then
    Result := FileExists(ExpandConstant('{app}\config\config.txt')) or
      (NeedsPostgreSql() and not PgReusedCluster);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Host, PortText, UserName, Password: String;
  PortNumber: Integer;
begin
  Result := True;
  if CurPageID = wpSelectTasks then begin
    PgChecked := False;
    Exit;
  end;
  if (DatabasePage = nil) or (CurPageID <> DatabasePage.ID) then
    Exit;

  // Taken as typed, never trimmed: config.txt's reader trims values, so a
  // password that really starts or ends with a space could not be stored and
  // would silently become a different password. Refuse it instead.
  Host := DatabasePage.Values[0];
  PortText := DatabasePage.Values[1];
  UserName := DatabasePage.Values[2];
  Password := DatabasePage.Values[3];
  if (Trim(Host) = '') or (Trim(UserName) = '') or (Password = '') then begin
    MsgBox('Enter the PostgreSQL host, user, and password.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if (Host <> Trim(Host)) or (PortText <> Trim(PortText)) or
     (UserName <> Trim(UserName)) or (Password <> Trim(Password)) then begin
    MsgBox('Database settings cannot start or end with a space. If the PostgreSQL ' +
      'password really does, change it on the server first.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if HasConfigControl(Host) or HasConfigControl(UserName) or HasConfigControl(Password) then begin
    MsgBox('Database settings cannot contain line breaks or control characters.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  PortNumber := StrToIntDef(PortText, 0);
  if (PortNumber < 1) or (PortNumber > 65535) then begin
    MsgBox('Enter a PostgreSQL port from 1 to 65535.', mbError, MB_OK);
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  DatabasePage := CreateInputQueryPage(
    wpSelectTasks,
    'PostgreSQL connection',
    'Connect this QC server to the PostgreSQL database',
    'For a remote database, enter the host used by this PC. For a local server that already exists, enter its current password.');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Port', False);
  DatabasePage.Add('User', False);
  DatabasePage.Add('Password', True);
  DatabasePage.Values[0] := 'localhost';
  DatabasePage.Values[1] := '5432';
  DatabasePage.Values[2] := 'postgres';
end;

// config.txt holds the database password and the login secret, so it lives in
// its own folder, {app}\config, and it is the FOLDER that is private (SYSTEM
// and Administrators, inherited by everything inside). Securing only the file
// was not enough: the console saves by writing .config.txt.tmp beside it and
// renaming it over the original, and a new file takes its folder's
// permissions - in {app} that meant every user could read the password again
// after the first save. Inside a private folder the temporary file is private
// from the moment it exists. The rest of {app} keeps Program Files' defaults
// (users read, admins write): the server runs as SYSTEM, and reviewers may read
// logs and exports.
//
// Runs on every install and BEFORE config.txt is written, so a fresh file is
// private the moment it exists. It never passes through open permissions: the
// folder's permission list is replaced outright with SYSTEM + Administrators
// (RestrictToAdmins, which also verifies the result), and an existing
// config.txt (an upgrade) gets the same, so a grant anyone once added to
// either does not survive. A leftover temp file from an interrupted console
// save is removed rather than trusted.
function ProtectQcConfig(): Boolean;
var
  Dir: String;
begin
  Dir := ExpandConstant('{app}\config');
  Result := ForceDirectories(Dir) and RestrictToAdmins(Dir, True);
  if not Result then
    Exit;
  // A temp file from an interrupted console save may hold the secrets. Secure
  // it, then remove it; if it cannot be removed, stop rather than trust it.
  if FileExists(Dir + '\.config.txt.tmp') then begin
    RestrictToAdmins(Dir + '\.config.txt.tmp', False);
    if not DeleteFile(Dir + '\.config.txt.tmp') then begin
      Log('Could not remove a leftover ' + Dir + '\.config.txt.tmp');
      Result := False;
      Exit;
    end;
  end;
  if FileExists(Dir + '\config.txt') then
    Result := RestrictToAdmins(Dir + '\config.txt', False);
end;

function NewJwtSecret(): String;
var
  TempFile, Command: String;
  Generated: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  TempFile := ExpandConstant('{tmp}\qc-jwt.txt');
  Command := '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$b = New-Object byte[] 32; ' +
    '[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ' +
    '[Convert]::ToBase64String($b) | Set-Content -NoNewline -Encoding ascii ''' +
    TempFile + '''"';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
     and (ResultCode = 0) and LoadStringFromFile(TempFile, Generated) then
    Result := Trim(String(Generated));
  DeleteFile(TempFile);
  if Length(Result) < 32 then
    RaiseException('Could not generate the QC login secret. Re-run this installer.');
end;

function WriteConfigIfMissing(): Boolean;
var
  ConfigPath, Host, PortText, UserName, Password, Jwt, ConfigText, NL: String;
begin
  ConfigPath := ExpandConstant('{app}\config\config.txt');
  ForceDirectories(ExtractFileDir(ConfigPath));
  if FileExists(ConfigPath) then begin
    Result := True;
    Exit;
  end;

  NL := #13#10;
  if PgNeeded and not PgReusedCluster then begin
    Host := 'localhost';
    PortText := '5432';
    UserName := 'postgres';
    Password := PgPassword;
  end else begin
    // Already validated on the page: no surrounding spaces, no line breaks.
    Host := DatabasePage.Values[0];
    PortText := DatabasePage.Values[1];
    UserName := DatabasePage.Values[2];
    Password := DatabasePage.Values[3];
  end;
  if Password = '' then begin
    Result := False;
    Exit;
  end;

  Jwt := NewJwtSecret();
  ConfigText :=
    '# LWCam QC server configuration. The console preserves these values when it saves.' + NL +
    '# Keep this file private; it contains the PostgreSQL password and login secret.' + NL +
    'dbHost = ' + Host + NL +
    'dbPort = ' + PortText + NL +
    'dbName = lwcam' + NL +
    'dbUser = ' + UserName + NL +
    'dbPassword = ' + Password + NL +
    'dbUseSsl = false' + NL +
    'jwtSecret = ' + Jwt + NL +
    'bindHost = 0.0.0.0' + NL +
    'port = 8080' + NL +
    'qcImagesRoot = ' + NL +
    'qcInputRoot = ' + ExpandConstant('{app}\Export Work') + NL +
    'qcOutputRoot = ' + ExpandConstant('{app}\Export') + NL +
    'exportZipOutput = true' + NL +
    'exportTiffOutput = true' + NL +
    'luminanceEnabled = false' + NL +
    'previewCacheMaxMb = 2048' + NL +
    'exportAutoEnabled = true' + NL +
    'exportWorkerCount = 0' + NL +
    'exportTempRetentionHours = 24' + NL +
    'jwtExpireMinutes = 480' + NL +
    'uploadEnabled = false' + NL +
    'uploadS3Path = ' + NL +
    'uploadS3Region = ' + NL +
    'uploadS3AccessKey = ' + NL +
    'uploadS3SecretKey = ' + NL +
    'uploadDoneRoot = ' + ExpandConstant('{app}\Uploaded') + NL +
    'uploadSummaryRoot = ' + ExpandConstant('{app}\Upload Reports') + NL +
    'aiReviewEnabled = false' + NL +
    'aiPreanalysisEnabled = false' + NL +
    'openrouterApiKey = ' + NL +
    'openrouterExtractModel = ' + NL +
    'openrouterCompareModel = ' + NL;
  Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
end;

procedure AppendIssue(var Issues: String; const Message: String);
begin
  if Issues <> '' then
    Issues := Issues + #13#10;
  Issues := Issues + '- ' + Message;
end;

procedure ConfigureQcServer(var Issues: String);
var
  Params, StartCommand, Port: String;
  ResultCode: Integer;
  Ok: Boolean;
begin
  if not FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then
    AppendIssue(Issues, 'The private Python runtime did not build. Run SETUP_QC.bat as Administrator.');
  if FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then begin
    Ok := Exec(ExpandConstant('{cmd}'),
      '/C ""' + ExpandConstant('{app}\SETUP_DB.bat') + '""',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if (not Ok) or (ResultCode <> 0) or
       (not FileExists(ExpandConstant('{app}\database\.setup_ok'))) then
      AppendIssue(Issues, 'Database setup did not complete. Check logs\database-setup.log, fix config\config.txt, then run SETUP_DB.bat as Administrator.');
  end;

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port. The delete
  // "fails" harmlessly on a first install, when there is no rule yet.
  Port := ConfiguredPort();
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LWCam QC Server"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam QC Server" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=domain,private',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The Windows Firewall rule for TCP ' + Port + ' could not be added.');

  // /TR takes the whole command as ONE argument, and the path has spaces, so it
  // is quoted inside the quoted argument: /TR "\"C:\...\START_QC_SERVER.bat\"".
  StartCommand := ExpandConstant('{app}\START_QC_SERVER.bat');
  Params := '/Create /TN "LWCam QC Server" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "\"' +
    StartCommand + '\"" /F';
  if not Exec(ExpandConstant('{sys}\schtasks.exe'), Params, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The LWCam QC Server startup task could not be registered.')
  else if not Exec(ExpandConstant('{sys}\schtasks.exe'),
       '/Run /TN "LWCam QC Server"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
       (ResultCode <> 0) then
    AppendIssue(Issues, 'The server startup task was registered but could not be started.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, PgMessage, Closing, NL: String;
begin
  // The server was already stopped in PrepareToInstall, before any file changed.
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  // Private folder first, secrets second: the file inherits the folder's
  // restricted permissions when it is created, so there is no moment when it
  // is readable. If the folder cannot be secured, nothing is written.
  if not ProtectQcConfig() then begin
    MsgBox('The config folder could not be restricted to SYSTEM and Administrators, so no' +
      NL + 'config file was written and the server was not started: that file holds' + NL +
      'the database password. Check the folder''s permissions, then run setup again.',
      mbError, MB_OK);
    Exit;
  end;
  if not WriteConfigIfMissing() then begin
    MsgBox('The QC config file could not be written. The server was not started.',
      mbError, MB_OK);
    Exit;
  end;

  Issues := '';
  ConfigureQcServer(Issues);
  PgMessage := PostgreSqlClosingMessage(
    'QC Platform',
    'The connection is stored in config\config.txt. Correct dbHost/dbPassword there if' + #13#10 +
    'needed, then run SETUP_DB.bat as Administrator. The remote PostgreSQL host' + #13#10 +
    'must allow this PC in pg_hba.conf and its firewall on port 5432.');
  Closing := 'QC Platform is installed.' + #13#10 + #13#10 +
    'Console: ' + ConsoleUrl('') + '  (from other PCs: http://' +
    GetComputerNameString() + ':' + ConfiguredPort() + '/)' + #13#10 +
    'The firewall rule covers Domain and Private networks, not Public ones.' + #13#10 +
    'Create the first account in LWCam Admin User Management.' + #13#10 +
    'On a split site, set qcImagesRoot in config\config.txt and grant the SYSTEM account' +
    NL + 'access to the capture share.';
  if PgMessage <> '' then
    Closing := Closing + #13#10 + #13#10 + PgMessage;
  if Issues <> '' then
    Closing := Closing + #13#10 + #13#10 + 'Setup needs attention:' + #13#10 + Issues;
  MsgBox(Closing, mbInformation, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    if StopQcServer() <> 0 then
      Log('Uninstall: a QC server process under the install folder did not stop.');
end;