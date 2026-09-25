; LWCam Database installer: PostgreSQL (installed here, or an existing server
; anywhere) plus the LWCam schema, opened to the LAN so QC, LWIP and LWCam
; Admin - each its own installer now - can all point at one place.

#define AppNameFull "LWCam Database"
#define AppVer "1.0.0"

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define QcDatabase AppsDir + "\LWCam_QC_Platform\database"
#define QcScripts AppsDir + "\LWCam_QC_Platform\scripts"
#define LwipWheels AppsDir + "\LWIP\wheels"
#define PyEmbedZip "vendor\python-3.13.14-embed-amd64.zip"

[Setup]
AppName={#AppNameFull}
AppId={{6BF83507-3390-4C90-95ED-8B4F581D573D}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LWCam Database
OutputBaseFilename=LWCamDatabaseSetup
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
Source: "{#QcScripts}\setup_qc_db.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#QcDatabase}\*"; DestDir: "{app}\database"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LwipWheels}\pip-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\psycopg-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\psycopg_binary-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\tzdata-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion

; Installer-managed setup scripts.
Source: "db\SETUP_DB_RUNTIME.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "db\SETUP_DATABASE.bat"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime\python"
Name: "{app}\runtime\vc"
Name: "{app}\logs"

#include "postgres.iss"

[Tasks]
; No Flags: a task is checked by default unless marked "unchecked" (see remotedb above).
Name: "openlan"; Description: "Allow other PCs on this network to connect"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_DB_RUNTIME.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline database setup runtime..."

[UninstallRun]
; No scheduled task: this installer runs once and leaves nothing resident.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam Database"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLwcamDatabaseFirewallRule"

[UninstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
Type: files; Name: "{app}\database\.setup_ok"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\logs"
; The private config folder: database.txt holds the PostgreSQL password.
Type: filesandordirs; Name: "{app}\config"
; NEVER PostgreSQL itself or {commonpf64}\PostgreSQL\...\data - other stations
; and other apps on this one may still depend on that server and its data.

[Code]
var
  DatabasePage: TInputQueryWizardPage;

// Reads one `key = value` line back out of database.txt, the same format
// WriteConfigIfMissing writes - used after install to show the finish message
// and decide LAN access, so an upgrade (which keeps the old file) reports the
// values actually in use, not whatever the wizard page happened to hold.
function ConfigValue(const Key, Default: String): String;
var
  Lines: TArrayOfString;
  I, Eq: Integer;
  Line: String;
begin
  Result := Default;
  if not LoadStringsFromFile(ExpandConstant('{app}\config\database.txt'), Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    Eq := Pos('=', Line);
    if (Eq > 0) and (Copy(Line, 1, 1) <> '#') and
       (CompareText(Trim(Copy(Line, 1, Eq - 1)), Key) = 0) then
      Result := Trim(Copy(Line, Eq + 1, Length(Line)));
  end;
end;

function ConfiguredHost(): String;
begin
  Result := ConfigValue('dbHost', 'localhost');
end;

function ConfiguredPort(): String;
var
  Number: Integer;
begin
  Result := '5432';
  Number := StrToIntDef(ConfigValue('dbPort', '5432'), 0);
  if (Number > 0) and (Number < 65536) then
    Result := IntToStr(Number);
end;

// The firewall rule and --open-lan only make sense when THIS PC is the server:
// opening a port here does nothing for a database that lives elsewhere.
function IsLocalDbHost(const Host: String): Boolean;
var
  Normalized: String;
begin
  Normalized := Lowercase(Trim(Host));
  Result := (Normalized = 'localhost') or (Normalized = '127.0.0.1') or (Normalized = '::1') or
    (Normalized = Lowercase(GetComputerNameString()));
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (DatabasePage <> nil) and (PageID = DatabasePage.ID) then
    Result := FileExists(ExpandConstant('{app}\config\database.txt')) or
      (NeedsPostgreSql() and not PgReusedCluster);
end;

// The PostgreSQL install (postgres.iss) is the usual thing to check before a
// single file is written. On a silent install (WizardSilent) also re-run the
// Database page's own validation - NextButtonClick already ran it, but with
// no one there to dismiss a MsgBox it had to leave the page alone (see
// NextButtonClick below), so this is the check that actually stops setup.
// Skipped exactly where the page itself is skipped: an upgrade (config file
// exists) or a fresh local PostgreSQL install (the page's values are unused -
// WriteConfigIfMissing takes the generated password instead).
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PostgreSqlPrepareProblem();
  if (Result = '') and WizardSilent and not ShouldSkipPage(DatabasePage.ID) then
    Result := ValidateDbPage(DatabasePage);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Msg: String;
begin
  Result := True;
  if CurPageID = wpSelectTasks then begin
    PgChecked := False;
    Exit;
  end;
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
    wpSelectTasks,
    'PostgreSQL connection',
    'Connect to an existing PostgreSQL server',
    'For a server on this PC or another, enter its current host, port, user and password.');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Port', False);
  DatabasePage.Add('User', False);
  DatabasePage.Add('Password', True);
  // Defaults come from the command line (/DBHOST=, /DBPORT=, /DBUSER=,
  // /DBPASSWORD=), read here so a silent install picks them up even though
  // nothing ever shows this page.
  DatabasePage.Values[0] := ExpandConstant('{param:DBHOST|localhost}');
  DatabasePage.Values[1] := ExpandConstant('{param:DBPORT|5432}');
  DatabasePage.Values[2] := ExpandConstant('{param:DBUSER|postgres}');
  DatabasePage.Values[3] := ExpandConstant('{param:DBPASSWORD|}');
end;

// database.txt holds the PostgreSQL password, so it lives in its own folder,
// {app}\config, and it is the FOLDER that is private (SYSTEM and
// Administrators, inherited by everything inside) - the same reasoning as the
// QC server's config.txt (see QCPlatform.iss's ProtectQcConfig). Unlike that
// file, nothing rewrites database.txt after install (no console, no save
// button), so there is no interrupted-temp-file case to clean up here.
function ProtectDatabaseConfig(): Boolean;
var
  Dir: String;
begin
  Dir := ExpandConstant('{app}\config');
  Result := ForceDirectories(Dir) and RestrictToAdmins(Dir, True);
  if Result and FileExists(Dir + '\database.txt') then
    Result := RestrictToAdmins(Dir + '\database.txt', False);
end;

function WriteConfigIfMissing(): Boolean;
var
  ConfigPath, Host, PortText, UserName, Password, ConfigText, NL: String;
begin
  ConfigPath := ExpandConstant('{app}\config\database.txt');
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

  ConfigText :=
    '# LWCam Database connection.' + NL +
    '# Enter these same values in QCPlatformSetup, LWIPSetup and LWCam Admin''s Station Setup.' + NL +
    'dbHost = ' + Host + NL +
    'dbPort = ' + PortText + NL +
    'dbName = lwcam' + NL +
    'dbUser = ' + UserName + NL +
    'dbPassword = ' + Password + NL +
    'dbUseSsl = false' + NL;
  Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
end;

procedure AppendIssue(var Issues: String; const Message: String);
begin
  if Issues <> '' then
    Issues := Issues + #13#10;
  Issues := Issues + '- ' + Message;
end;

procedure ConfigureDatabase(var Issues: String; var OpenedLan: Boolean);
var
  Params, Host, Port: String;
  ResultCode: Integer;
  Ok: Boolean;
begin
  OpenedLan := False;
  if not FileExists(ExpandConstant('{app}\runtime\.setup_ok')) then begin
    AppendIssue(Issues, 'The private Python runtime did not build. Run SETUP_DB_RUNTIME.bat as Administrator.');
    Exit;
  end;

  Host := ConfiguredHost();
  OpenedLan := WizardIsTaskSelected('openlan') and IsLocalDbHost(Host);

  // /C "" ... "" quotes the batch path once for cmd and once more so a path
  // containing spaces survives being an argument to that already-quoted /C.
  Params := '/C ""' + ExpandConstant('{app}\SETUP_DATABASE.bat') + '""';
  if OpenedLan then
    Params := Params + ' --open-lan';
  Ok := Exec(ExpandConstant('{cmd}'), Params, ExpandConstant('{app}'),
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if (not Ok) or (ResultCode <> 0) or (not FileExists(ExpandConstant('{app}\database\.setup_ok'))) then
    AppendIssue(Issues, 'Database setup did not complete. Check logs\database-setup.log, fix ' +
      'config\database.txt, then run SETUP_DATABASE.bat as Administrator.');

  if not OpenedLan then
    Exit;

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port.
  Port := ConfiguredPort();
  Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="LWCam Database"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam Database" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=domain,private',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    AppendIssue(Issues, 'The Windows Firewall rule for TCP ' + Port + ' could not be added.');
end;

// Get-NetIPAddress, not ipconfig text-parsing: structured output survives a
// PC with several adapters. No braces in the PowerShell: "{" opens an Inno
// constant.
function LocalIPv4Addresses(): String;
var
  TempFile, Command: String;
  Generated: AnsiString;
  ResultCode: Integer;
begin
  Result := '';
  TempFile := ExpandConstant('{tmp}\lwcam-db-ip.txt');
  Command := '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$a = Get-NetIPAddress -AddressFamily IPv4 | Where-Object AddressState -eq ''Preferred'' | ' +
    'Where-Object IPAddress -notlike ''127.*'' | Where-Object IPAddress -notlike ''169.254.*'' | ' +
    'Select-Object -ExpandProperty IPAddress; ' +
    '$a -join '', '' | Set-Content -NoNewline -Encoding ascii ''' + TempFile + '''"';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
     and (ResultCode = 0) and LoadStringFromFile(TempFile, Generated) then
    Result := Trim(String(Generated));
  DeleteFile(TempFile);
end;

// The finish message and its logged counterpart share every line except the
// password: the real value on screen (an operator needs to type it into the
// next installer), masked in the log - a shared file, unlike the screen, and
// /LOG is never to carry a secret.
function DatabaseClosingText(const IsLocal: Boolean; const OpenedLan: Boolean;
  const PasswordDisplay: String): String;
var
  NL, Text, Ips: String;
begin
  NL := #13#10;
  Text := 'LWCam Database is installed.' + NL + NL +
    'Enter these in QCPlatformSetup, LWIPSetup and LWCam Admin''s Station Setup:' + NL;
  // "localhost" is only right on this PC; other PCs need its name or address.
  // A server elsewhere is shown exactly as configured.
  if IsLocal then begin
    Text := Text + 'Host: ' + GetComputerNameString();
    Ips := LocalIPv4Addresses();
    if Ips <> '' then
      Text := Text + ' (' + Ips + ')';
  end else
    Text := Text + 'Host: ' + ConfiguredHost();
  Text := Text + NL +
    'Port: ' + ConfiguredPort() + NL +
    'Database: ' + ConfigValue('dbName', 'lwcam') + NL +
    'User: ' + ConfigValue('dbUser', '') + NL +
    'Password: ' + PasswordDisplay;
  if IsLocal and not OpenedLan then
    Text := Text + NL + NL +
      'Other PCs cannot reach this server: the "Allow other PCs on this network to' + NL +
      'connect" task was unchecked.';
  Result := Text;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, PgMessage, Closing, LoggedClosing, NL: String;
  OpenedLan, IsLocal: Boolean;
begin
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  // Private folder first, secrets second: the file inherits the folder's
  // restricted permissions when it is created, so there is no moment when it
  // is readable.
  if not ProtectDatabaseConfig() then begin
    Log('LWCam Database: the config folder could not be restricted; nothing was written.');
    SuppressibleMsgBox('The config folder could not be restricted to SYSTEM and Administrators, so no' + NL +
      'config file was written and the database was not set up: that file holds the' + NL +
      'PostgreSQL password. Check the folder''s permissions, then run setup again.',
      mbError, MB_OK, IDOK);
    Exit;
  end;
  if not WriteConfigIfMissing() then begin
    Log('LWCam Database: the config file could not be written.');
    SuppressibleMsgBox('The database config file could not be written. Setup did not continue.',
      mbError, MB_OK, IDOK);
    Exit;
  end;

  Issues := '';
  ConfigureDatabase(Issues, OpenedLan);
  PgMessage := PostgreSqlClosingMessage(
    'LWCam Database',
    'The connection is stored in config\database.txt. Correct it there if needed,' + NL +
    'then run SETUP_DATABASE.bat as Administrator.');
  IsLocal := IsLocalDbHost(ConfiguredHost());

  Closing := DatabaseClosingText(IsLocal, OpenedLan, ConfigValue('dbPassword', ''));
  LoggedClosing := DatabaseClosingText(IsLocal, OpenedLan, '(hidden - see config\database.txt)');
  if PgMessage <> '' then begin
    Closing := Closing + NL + NL + PgMessage;
    LoggedClosing := LoggedClosing + NL + NL + PgMessage;
  end;
  if Issues <> '' then begin
    Closing := Closing + NL + NL + 'Setup needs attention:' + NL + Issues;
    LoggedClosing := LoggedClosing + NL + NL + 'Setup needs attention:' + NL + Issues;
  end;
  Log('LWCam Database finished:' + NL + LoggedClosing);
  SuppressibleMsgBox(Closing, mbInformation, MB_OK, IDOK);
end;

// The script's own bytecode cache; everything else the runtime writes lives
// under {app}\runtime, already removed wholesale by [UninstallDelete] above.
// Must run BEFORE that removal (usUninstall, not the later steps), or the
// tracked files vanish first and this folder is left as an empty shell -
// exactly the trap QCPlatform.iss's DeleteRuntimeLeftovers documents.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    DelTree(ExpandConstant('{app}\scripts\__pycache__'), True, True, True);
end;
