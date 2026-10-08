; LWCam QC Platform installer: standalone LAN server and Vue console.

#define AppNameFull "LWCam QC Platform"
#ifndef AppVer
  #define AppVer "1.0.0"
#endif
#ifndef BuildId
  #define BuildId "dev"
#endif

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define QcBackend AppsDir + "\LWCam_QC_Platform\backend"
#define QcDist AppsDir + "\LWCam_QC_Platform\frontend\dist"
#define PyEmbedZip "vendor\python-3.14.8-embed-amd64.zip"

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

[InstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
; Database setup moved to LWCamDatabaseSetup.exe. An upgrade drops the copy
; older QC installers shipped, so nobody runs a stale schema script from here.
Type: files; Name: "{app}\SETUP_DB.bat"
Type: filesandordirs; Name: "{app}\scripts"
Type: filesandordirs; Name: "{app}\database"

[Files]
; Written by build-installer.ps1: "<version>+<commit>". Each part shows it and sends it in its heartbeat.
Source: "vendor\VERSION.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "Trust this LWCam server.cmd"; DestDir: "{app}"; Flags: ignoreversion
; Ship runtime code and the offline wheelhouse, but no development state.
Source: "{#QcBackend}\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs; Excludes: ".venv\*,.cache\*,*.pyc,__pycache__\*,.pytest_cache\*,.env,tests\*,conftest.py,Dockerfile,.dockerignore,.gitignore,pyproject.toml,.env.example,requirements-dev.txt,app\Luminance Correction\README.txt,app\Luminance Correction\requirements.txt"
Source: "{#QcDist}\*"; DestDir: "{app}\frontend\dist"; Flags: ignoreversion recursesubdirs createallsubdirs

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion deleteafterinstall
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion

; Installer-managed launch and recovery scripts.
Source: "qc\SETUP_QC.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "qc\START_QC_SERVER.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "qc\OPEN_QC_LOG.bat"; DestDir: "{app}\logs"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime\python"
Name: "{app}\runtime\vc"
Name: "{app}\Export"
Name: "{app}\Export Work"
Name: "{app}\logs"
; No Uploaded / Upload Reports here any more: upload moved to LWCam Upload,
; its own installer. An upgrade's existing folders (from before the split)
; are left alone - they may still hold an operator's data - see
; DeleteRuntimeLeftovers, which never touches them either.

#include "common.iss"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_QC.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline QC server runtime..."

[Icons]
; The port comes from config\config.txt when one already exists (an upgrade), else 8080.
Name: "{autoprograms}\LWCam QC Platform\QC Console"; Filename: "{code:ConsoleUrl}"
Name: "{autoprograms}\LWCam QC Platform\QC server log"; Filename: "{app}\logs\OPEN_QC_LOG.bat"

[UninstallRun]
; End before delete: deleting a running task leaves its restart loop alive.
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN ""LWCam QC Server"""; Flags: runhidden waituntilterminated; RunOnceId: "EndQcServerTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""LWCam QC Server"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveQcServerTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam QC Server"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveQcFirewallRule"

[UninstallDelete]
Type: files; Name: "{app}\python-3.14.8-embed-amd64.zip"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\backend\.cache"
; Runtime bytecode and export scratch are removed in CurUninstallStepChanged,
; not here: this section runs last, after setup's own folders were already
; skipped as not empty, which left them behind as empty shells.
; The private config folder: config.txt holds the database password.
Type: filesandordirs; Name: "{app}\config"
Type: files; Name: "{app}\LWCam server certificate.crt"

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
  Result := 'https://localhost:' + ConfiguredPort() + '/';
end;

// Shown on every fresh install: the QC server always needs SOME connection,
// and (unlike the old all-in-one flow) this installer never creates a
// database itself - it only ever reuses one LWCamDatabaseSetup already made.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (DatabasePage <> nil) and (PageID = DatabasePage.ID) then
    Result := FileExists(ExpandConstant('{app}\config\config.txt'));
end;

// Runs before a single file is written or deleted, so a server that will not
// stop aborts setup cleanly instead of leaving new files under old code. On a
// silent install (WizardSilent) also re-run the Database page's own
// validation - NextButtonClick already ran it, but with no one there to
// dismiss a MsgBox it had to leave the page alone (see NextButtonClick
// below), so this is the check that actually stops setup. Skipped exactly
// where the page itself is skipped: an upgrade, when config.txt exists.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if StopQcServer() <> 0 then begin
    Result := 'The running LWCam QC server could not be stopped, so its files were not ' +
      'replaced. Close anything running from ' + ExpandConstant('{app}') +
      ' (or restart the PC) and run setup again.';
    Exit;
  end;
  if WizardSilent and not ShouldSkipPage(DatabasePage.ID) then
    Result := ValidateDbPage(DatabasePage);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Msg: String;
begin
  Result := True;
  if (DatabasePage = nil) or (CurPageID <> DatabasePage.ID) then
    Exit;
  // Setup simulates this click on a silent install too, but there is no one
  // to dismiss the MsgBox below - leave the page alone and let
  // PrepareToInstall's silent-only check fail setup cleanly instead.
  if WizardSilent then
    Exit;

  Msg := ValidateDbPage(DatabasePage);
  if Msg <> '' then begin
    MsgBox(Msg, mbError, MB_OK);
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  DatabasePage := CreateInputQueryPage(
    wpSelectDir,
    'PostgreSQL connection',
    'Connect this QC server to the PostgreSQL database',
    'The database must already exist - run LWCamDatabaseSetup once on the database PC, ' +
    'then enter the host, port, database, user and password its finish page shows ' +
    '(the same login every LWCam part uses).');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Port', False);
  DatabasePage.Add('Database', False);
  DatabasePage.Add('User', False);
  DatabasePage.Add('Password', True);
  // Defaults come from the command line (/DBHOST=, /DBPORT=, /DBNAME=,
  // /DBUSER=, /DBPASSWORD=), read here so a silent install picks them up even
  // though nothing ever shows this page. The port is always filled in (5432)
  // and can be edited.
  DatabasePage.Values[0] := ExpandConstant('{param:DBHOST|localhost}');
  DatabasePage.Values[1] := ExpandConstant('{param:DBPORT|5432}');
  DatabasePage.Values[2] := ExpandConstant('{param:DBNAME|lwcam}');
  DatabasePage.Values[3] := ExpandConstant('{param:DBUSER|lwcam_user}');
  DatabasePage.Values[4] := ExpandConstant('{param:DBPASSWORD|}');
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
  ConfigPath, Host, PortText, DbName, UserName, Password, Jwt, ConfigText, NL: String;
begin
  ConfigPath := ExpandConstant('{app}\config\config.txt');
  ForceDirectories(ExtractFileDir(ConfigPath));
  if FileExists(ConfigPath) then begin
    Result := True;
    Exit;
  end;

  NL := #13#10;
  // Already validated on the page: no surrounding spaces, no line breaks.
  Host := DatabasePage.Values[0];
  PortText := DatabasePage.Values[1];
  DbName := DatabasePage.Values[2];
  UserName := DatabasePage.Values[3];
  Password := DatabasePage.Values[4];
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
    'dbName = ' + DbName + NL +
    'dbUser = ' + UserName + NL +
    'dbPassword = ' + Password + NL +
    'dbUseSsl = false' + NL +
    'jwtSecret = ' + Jwt + NL +
    'bindHost = 0.0.0.0' + NL +
    'port = 8080' + NL +
    'qcInputRoot = ' + NL +
    'exportWorkRoot = ' + ExpandConstant('{app}\Export Work') + NL +
    'qcOutputRoot = ' + ExpandConstant('{app}\Export') + NL +
    'exportZipOutput = true' + NL +
    'exportTiffOutput = true' + NL +
    'luminanceEnabled = false' + NL +
    'previewCacheMaxMb = 2048' + NL +
    'exportAutoEnabled = true' + NL +
    'exportWorkerCount = 0' + NL +
    'exportTempRetentionHours = 24' + NL +
    'jwtExpireMinutes = 480' + NL +
    // Upload moved to its own installer, LWCamUploadSetup - the QC server no
    // longer sends anything to S3, so a fresh config.txt no longer carries
    // upload* keys. An old config.txt that still has them keeps working:
    // server_settings.py already skips keys it does not recognise.
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
  Port: String;
  ResultCode: Integer;
begin
  if not FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then
    AppendIssue(Issues, 'The private Python runtime did not build. Run SETUP_QC.bat as Administrator.');

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port. The delete
  // "fails" harmlessly on a first install, when there is no rule yet.
  Port := ConfiguredPort();
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LWCam QC Server"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam QC Server" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=any remoteip=localsubnet,100.64.0.0/10,fd7a:115c:a1e0::/48',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The Windows Firewall rule for TCP ' + Port + ' could not be added.');

  // No run-time limit, restart after a failure: see RegisterBootTask.
  if not RegisterBootTask('LWCam QC Server', ExpandConstant('{app}\START_QC_SERVER.bat')) then
    AppendIssue(Issues, 'The LWCam QC Server startup task could not be registered.')
  else if not Exec(ExpandConstant('{sys}\schtasks.exe'),
       '/Run /TN "LWCam QC Server"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
       (ResultCode <> 0) then
    AppendIssue(Issues, 'The server startup task was registered but could not be started.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, Closing, NL: String;
begin
  // The server was already stopped in PrepareToInstall, before any file changed.
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  Issues := '';
  // Program folder first, before the task exists: code that runs as SYSTEM
  // must not be replaceable by an ordinary user. config\ keeps its own list.
  if not LockProgramFolder(ExpandConstant('{app}')) then
    AppendIssue(Issues, 'The install folder could not be locked to Administrators; check its permissions.');
  // Private folder first, secrets second: the file inherits the folder's
  // restricted permissions when it is created, so there is no moment when it
  // is readable. If the folder cannot be secured, nothing is written.
  if not ProtectQcConfig() then begin
    Log('LWCam QC Platform: the config folder could not be restricted; nothing was written.');
    SuppressibleMsgBox('The config folder could not be restricted to SYSTEM and Administrators, so no' +
      NL + 'config file was written and the server was not started: that file holds' + NL +
      'the database password. Check the folder''s permissions, then run setup again.',
      mbError, MB_OK, IDOK);
    Exit;
  end;
  if not WriteConfigIfMissing() then begin
    Log('LWCam QC Platform: the config file could not be written.');
    SuppressibleMsgBox('The QC config file could not be written. The server was not started.',
      mbError, MB_OK, IDOK);
    Exit;
  end;

  // https certificate for the web page; without it the page stays plain http.
  if not SetUpTls(ExpandConstant('{app}\runtime\python\python.exe'), 'app.core.tls',
       ExpandConstant('{app}\backend'), ExpandConstant('{app}\config\config.txt')) then
    AppendIssue(Issues, 'The https certificate could not be created, so the page is plain http. Run setup again as Administrator.');

  // Encrypt the passwords/keys just written (or left by an older version). The
  // server also does this itself when it starts, so a failure here is not fatal.
  if not ProtectConfigSecrets(ExpandConstant('{app}\runtime\python\python.exe'), '-m app.core.lwcam_secrets',
       ExpandConstant('{app}\backend'), ExpandConstant('{app}\config\config.txt'),
       'dbPassword,jwtSecret,openrouterApiKey') then
    AppendIssue(Issues, PlainSecretsWarning('config\config.txt') + ' The server encrypts them itself when it starts.');

  ConfigureQcServer(Issues);
  Closing := 'QC Platform is installed.' + NL + NL +
    'Console: https://' + GetComputerNameString() + ':' + ConfiguredPort() + '/' + NL + NL + TlsClosingNote();
  if Issues <> '' then
    Closing := Closing + #13#10 + #13#10 + 'Setup needs attention:' + #13#10 + Issues;
  Log('LWCam QC Platform finished:' + #13#10 + Closing);
  SuppressibleMsgBox(Closing, mbInformation, MB_OK, IDOK);
end;

// Files the running server created that setup never installed: the bytecode
// its Python writes beside each package it imports, and the export's own
// scratch. They must go BEFORE the uninstaller removes its own files - a
// folder still holding them is not empty then, and is left behind as an empty
// shell. [UninstallDelete] runs last, which is too late (seen on 2026-09-24).
// One line per package folder in backend\app - a new package needs a line.
// Only the default Export Work: a work folder moved elsewhere in Settings is
// not the uninstaller's to touch.
procedure DeleteRuntimeLeftovers();
var
  App: String;
begin
  App := ExpandConstant('{app}');
  DelTree(App + '\backend\app\__pycache__', True, True, True);
  DelTree(App + '\backend\app\core\__pycache__', True, True, True);
  DelTree(App + '\backend\app\db\__pycache__', True, True, True);
  DelTree(App + '\backend\app\db\migrations\__pycache__', True, True, True);
  DelTree(App + '\backend\app\models\__pycache__', True, True, True);
  DelTree(App + '\backend\app\routers\__pycache__', True, True, True);
  DelTree(App + '\backend\app\schemas\__pycache__', True, True, True);
  DelTree(App + '\backend\app\services\__pycache__', True, True, True);
  DelTree(App + '\backend\app\Luminance Correction\__pycache__', True, True, True);
  DelTree(App + '\Export Work\.lwcam-export', True, True, True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    // Stop first: a running server would hold files and write new bytecode.
    if StopQcServer() <> 0 then
      Log('Uninstall: a QC server process under the install folder did not stop.');
    DeleteRuntimeLeftovers();
  end;
end;