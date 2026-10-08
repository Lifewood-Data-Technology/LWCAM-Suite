; LWCam Database installer: PostgreSQL (installed here, or an existing server
; anywhere) plus the LWCam schema, opened to the LAN so QC, LWIP, Upload and
; LWCam Admin / LWCAM - each its own installer - can all point at one place.
; The operator picks ONE database login (name, user, password, port) here; every
; part uses it.

#define AppNameFull "LWCam Database"
#ifndef AppVer
  #define AppVer "1.0.0"
#endif
#ifndef BuildId
  #define BuildId "dev"
#endif

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define QcDatabase AppsDir + "\LWCam_QC_Platform\database"
#define QcScripts AppsDir + "\LWCam_QC_Platform\scripts"
#define LwipWheels AppsDir + "\LWIP\wheels"
#define PyEmbedZip "vendor\python-3.14.8-embed-amd64.zip"

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
; Written by build-installer.ps1: "<version>+<commit>". Each part shows it and sends it in its heartbeat.
Source: "vendor\VERSION.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#QcScripts}\setup_qc_db.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#QcDatabase}\*"; DestDir: "{app}\database"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LwipWheels}\pip-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\psycopg-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\psycopg_binary-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\tzdata-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
; cryptography (+ cffi, pycparser) makes the server's TLS certificate (--open-lan).
Source: "{#LwipWheels}\cryptography-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\cffi-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion
Source: "{#LwipWheels}\pycparser-*.whl"; DestDir: "{app}\wheels"; Flags: ignoreversion

; Build the private runtime on the target; its archive is staged once at the root.
Source: "{#PyEmbedZip}"; DestDir: "{app}"; Flags: ignoreversion deleteafterinstall
Source: "vendor\vcruntime\*"; DestDir: "{app}\runtime\vc"; Flags: ignoreversion

; Installer-managed setup scripts.
Source: "db\SETUP_DB_RUNTIME.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "db\SETUP_DATABASE.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "db\BACKUP_DATABASE.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "db\RESTORE_DATABASE.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "db\backup_db.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
; Decrypts/encrypts the passwords in config\database.txt (Windows DPAPI); an identical copy ships with every module.
Source: "db\lwcam_secrets.py"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Dirs]
Name: "{app}\runtime\python"
Name: "{app}\runtime\vc"
Name: "{app}\logs"

#include "postgres.iss"

[Tasks]
; No Flags: a task is checked by default unless marked "unchecked" (see remotedb above).
Name: "openlan"; Description: "Allow other PCs on this network (and Tailscale) to connect. Unticking closes access that an earlier run opened"

[Run]
Filename: "{cmd}"; Parameters: "/C ""{app}\SETUP_DB_RUNTIME.bat"" <NUL"; WorkingDir: "{app}"; StatusMsg: "Building the offline database setup runtime..."

[Run]
Filename: "{app}\BACKUP_DATABASE.bat"; Description: "Run a backup now (proves the backup folder works)"; Flags: postinstall skipifsilent shellexec

[InstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
; Retired: logins.txt (the five per-part logins) is read by nothing; pgpass.conf held the database
; password in plain text and backup_db.py now passes it through the environment instead.
Type: files; Name: "{app}\config\logins.txt"
Type: files; Name: "{app}\config\pgpass.conf"

[UninstallRun]
; The only resident piece is the nightly backup task. End before delete, like the services.
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN ""LWCam Database Backup"""; Flags: runhidden waituntilterminated; RunOnceId: "EndDatabaseBackupTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""LWCam Database Backup"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveDatabaseBackupTask"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LWCam Database"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLwcamDatabaseFirewallRule"

[UninstallDelete]
Type: files; Name: "{app}\python-3.14.8-embed-amd64.zip"
Type: files; Name: "{app}\database\.setup_ok"
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\logs"
; {app}\config (database.txt, backup.txt) is deliberately KEPT: the PostgreSQL password is
; not recoverable from the server, and the folder stays SYSTEM + Administrators
; only. A reinstall's WriteConfigIfMissing reuses the file as it stands.
; NEVER PostgreSQL itself or {commonpf64}\PostgreSQL\...\data - other stations
; and other apps on this one may still depend on that server and its data.

[Code]
var
  DatabasePage: TInputQueryWizardPage;  // existing server only: Host, User, Password
  LoginPage: TInputQueryWizardPage;     // the shared login: Database, Port, User, Password, Confirm
  BackupPage: TInputQueryWizardPage;
  BackupPrefilled: Boolean;
  LoginPrefilled: Boolean;
  // The shared password for this run, captured BEFORE database.txt is encrypted:
  // AppPasswordEnv goes to setup_qc_db.py ('' = it reads and decrypts the file
  // itself, a re-run that kept the saved password); AppPasswordShown is for the finish page.
  AppPasswordEnv: String;
  AppPasswordShown: String;

// Sets a variable in THIS process. The setup script inherits it (Exec passes the
// environment on), so the shared login's password reaches setup_qc_db.py
// without ever being on a command line, in the Inno log or in a temp file.
function Win32SetEnv(lpName, lpValue: string): Integer;
external 'SetEnvironmentVariableW@kernel32.dll stdcall';

// Tells a local fixed disk from a mapped network drive letter: SYSTEM (the
// backup task's account) cannot see a drive mapped in someone's logon session.
function GetDriveType(lpRootPathName: string): Integer;
external 'GetDriveTypeW@kernel32.dll stdcall';

// True for a UNC path or a drive-letter path on a real fixed disk (3 =
// DRIVE_FIXED). False for a mapped drive letter, removable media, or anything
// relative.
function IsFixedOrUncPath(const Path: String): Boolean;
begin
  Result := False;
  if (Length(Path) >= 3) and (Path[1] = '\') and (Path[2] = '\') then
    Result := True
  else if (Length(Path) >= 3) and (Path[2] = ':') and (Path[3] = '\') then
    Result := GetDriveType(Copy(Path, 1, 3)) = 3;
end;

function DefaultBackupDir(): String;
begin
  if GetDriveType('D:\') = 3 then
    Result := 'D:\LWCam Backups'
  else
    Result := ExpandConstant('{commonappdata}\LWCam\Backups');
end;

// Reads one `key = value` line back out of database.txt, the same format
// WriteConfigIfMissing writes - used after install to show the finish message
// and decide LAN access, so an upgrade (which keeps the old file) reports the
// values actually in use, not whatever the wizard page happened to hold.
function KeyValue(const FileName, Key, Default: String): String;
var
  Lines: TArrayOfString;
  I, Eq: Integer;
  Line: String;
begin
  Result := Default;
  if not LoadStringsFromFile(FileName, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    Eq := Pos('=', Line);
    if (Eq > 0) and (Copy(Line, 1, 1) <> '#') and
       (CompareText(Trim(Copy(Line, 1, Eq - 1)), Key) = 0) then
      Result := Trim(Copy(Line, Eq + 1, Length(Line)));
  end;
end;

function ConfigValue(const Key, Default: String): String;
begin
  Result := KeyValue(ExpandConstant('{app}\config\database.txt'), Key, Default);
end;

function BackupConfigValue(const Key, Default: String): String;
begin
  Result := KeyValue(ExpandConstant('{app}\config\backup.txt'), Key, Default);
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

// A re-run shows what is saved in config\backup.txt; /BACKUPDIR= and /BACKUPKEEP=
// win over it. {app} is not known while the wizard is built, so this runs when
// the page is first shown, or in PrepareToInstall on a silent install (page
// never shown). Fills only what the command line did not name.
procedure PrefillBackupPage();
begin
  if BackupPrefilled then
    Exit;
  BackupPrefilled := True;
  if ExpandConstant('{param:BACKUPDIR|}') = '' then
    BackupPage.Values[0] := BackupConfigValue('backupDir', BackupPage.Values[0]);
  if ExpandConstant('{param:BACKUPKEEP|}') = '' then
    BackupPage.Values[1] := BackupConfigValue('backupKeep', BackupPage.Values[1]);
end;

// True when Dir holds something that is NOT a backup folder an earlier run
// made (no lwcam-*.dump among its files).
function FolderIsForeign(const Dir: String): Boolean;
var
  Find: TFindRec;
  Any, Backups: Boolean;
begin
  Any := False;
  Backups := False;
  if FindFirst(Dir + '\*', Find) then begin
    try
      repeat
        if (Find.Name <> '.') and (Find.Name <> '..') then begin
          Any := True;
          if (Copy(Lowercase(Find.Name), 1, 6) = 'lwcam-') and
             (CompareText(ExtractFileExt(Find.Name), '.dump') = 0) then
            Backups := True;
        end;
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
  Result := Any and not Backups;
end;

// The backup folder is locked to SYSTEM + Administrators, so a system folder
// or someone's working folder must never be picked: locking C:\ or C:\Windows
// would break the PC. Drive roots, Windows, Program Files, ProgramData,
// C:\Users, and any non-empty folder that is not already a backup folder.
function BackupFolderProblem(const RawDir: String): String;
var
  Dir: String;
begin
  Result := '';
  Dir := RemoveBackslash(RawDir);
  if (Length(Dir) = 2) and (Dir[2] = ':') or ((Length(Dir) = 3) and (Dir[2] = ':') and (Dir[3] = '\')) then
    Result := 'Pick a folder, not a whole drive: the backup folder is locked to Administrators.'
  else if (CompareText(Dir, ExpandConstant('{win}')) = 0) or
          (CompareText(Copy(Dir, 1, Length(ExpandConstant('{win}')) + 1), ExpandConstant('{win}') + '\') = 0) or
          (CompareText(Dir, ExpandConstant('{commonpf64}')) = 0) or
          (CompareText(Dir, ExpandConstant('{commonpf32}')) = 0) or
          (CompareText(Dir, ExpandConstant('{commonappdata}')) = 0) or
          (CompareText(Dir, ExpandConstant('{sd}') + '\Users') = 0) then
    Result := 'That is a system folder. Pick a new folder of its own, for example D:\LWCam Backups.'
  else if FolderIsForeign(Dir) then
    Result := 'That folder already holds other files, and the backup folder is locked to Administrators. ' +
      'Pick a new, empty folder (or one that already holds LWCam backups).';
end;

function ValidateBackupPage(): String;
var
  Dir: String;
  Keep: Integer;
begin
  Result := '';
  Dir := BackupPage.Values[0];
  Keep := StrToIntDef(BackupPage.Values[1], 0);
  if (Dir = '') or (Dir <> Trim(Dir)) or HasConfigControl(Dir) or (Pos('"', Dir) > 0) then
    Result := 'Enter the backup folder (no line breaks, quotes, or spaces at either end).'
  else if not IsFixedOrUncPath(Dir) then
    Result := 'The backup folder must be on a local disk or a network share written as \\server\share. ' +
      'A mapped drive letter cannot be used: the backup runs as SYSTEM, which cannot see it.'
  else if BackupFolderProblem(Dir) <> '' then
    Result := BackupFolderProblem(Dir)
  else if (Keep < 1) or (Keep > 365) then
    Result := 'Keep between 1 and 365 backups.';
end;

// True when the backup folder is on the same drive as the PostgreSQL data
// (assumed under Program Files, EDB's default), so one dead disk would lose
// both. Only meaningful when PostgreSQL runs on this PC.
// ponytail: assumes the default data dir; add a "SHOW data_directory" lookup if stations move it.
function BackupOnDataDrive(): Boolean;
var
  Host: String;
begin
  if FileExists(ExpandConstant('{app}\config\database.txt')) then
    Host := ConfiguredHost()
  else if NeedsPostgreSql() then
    Host := 'localhost'
  else
    Host := DatabasePage.Values[0];
  Result := IsLocalDbHost(Host) and (Copy(BackupPage.Values[0], 2, 1) = ':') and
    (CompareText(ExtractFileDrive(BackupPage.Values[0]), ExtractFileDrive(ExpandConstant('{commonpf64}'))) = 0);
end;

// The password to use: what was typed, or - a re-run where both boxes were left
// blank - the one saved in database.txt.
function LoginPassword(): String;
begin
  Result := LoginPage.Values[3];
  if (Result = '') and (LoginPage.Values[4] = '') then
    Result := ConfigValue('appPassword', '');
end;

// A re-run shows what is saved in config\database.txt; /APPDB=, /DBPORT=,
// /APPUSER= and /APPPASSWORD= win over it. {app} is unknown while the wizard is
// built, so this runs when the page is first shown, or in PrepareToInstall on a
// silent install (page never shown). With no saved file the port is the existing
// local server's, else 5432.
procedure PrefillLoginPage();
var
  Port: String;
begin
  if LoginPrefilled then
    Exit;
  LoginPrefilled := True;
  if ExpandConstant('{param:APPDB|}') = '' then
    LoginPage.Values[0] := ConfigValue('dbName', LoginPage.Values[0]);
  if ExpandConstant('{param:DBPORT|}') = '' then begin
    Port := '';
    if FileExists(ExpandConstant('{app}\config\database.txt')) then
      Port := ConfigValue('dbPort', '')
    else if (not NeedsPostgreSql()) and (not WizardIsTaskSelected('remotedb')) then
      Port := PgConfPort();
    if Port <> '' then
      LoginPage.Values[1] := Port;
  end;
  if ExpandConstant('{param:APPUSER|}') = '' then
    LoginPage.Values[2] := ConfigValue('appUser', LoginPage.Values[2]);
  if ExpandConstant('{param:APPPASSWORD|}') = '' then begin
    LoginPage.Values[3] := ConfigValue('appPassword', '');
    LoginPage.Values[4] := LoginPage.Values[3];
  end;
end;

// The connection page (an existing server): its host, user and password. Kept
// to plain ASCII because database.txt is rewritten on a re-run.
function ValidateConnPage(): String;
var
  Host, UserName, Password: String;
  I: Integer;
begin
  Result := '';
  Host := DatabasePage.Values[0];
  UserName := DatabasePage.Values[1];
  Password := DatabasePage.Values[2];
  if (Trim(Host) = '') or (Trim(UserName) = '') or (Password = '') then begin
    Result := 'Enter the PostgreSQL host, administrator user, and password.';
    Exit;
  end;
  if (Host <> Trim(Host)) or (UserName <> Trim(UserName)) or (Password <> Trim(Password)) then begin
    Result := 'Database settings cannot start or end with a space. If the PostgreSQL ' +
      'password really does, change it on the server first.';
    Exit;
  end;
  if HasConfigControl(Host) or HasConfigControl(UserName) or HasConfigControl(Password) then begin
    Result := 'Database settings cannot contain line breaks or control characters.';
    Exit;
  end;
  for I := 1 to Length(Password) do
    if Ord(Password[I]) > 126 then begin
      Result := 'The PostgreSQL password must use plain characters only (no accented or non-English letters).';
      Exit;
    end;
end;

// The shared LWCam login page. Same rules setup_qc_db.py --app-login enforces,
// so nothing accepted here is refused later, plus the fresh-install port check.
function ValidateLoginPage(): String;
var
  Db, Port, UserName, Password, AdminUser: String;
  Number, I: Integer;
begin
  Result := '';
  Db := LoginPage.Values[0];
  Port := LoginPage.Values[1];
  UserName := LoginPage.Values[2];
  Password := LoginPassword();
  if (not IsIdentifier(Db)) or (Db = 'postgres') or (Db = 'template0') or (Db = 'template1') then begin
    Result := 'The database name uses only lowercase letters, digits and underscores, starts with a letter ' +
      'or underscore, and is not postgres (for example lwcam).';
    Exit;
  end;
  Number := StrToIntDef(Port, 0);
  if (Number < 1024) or (Number > 65535) or (IntToStr(Number) <> Port) then begin
    Result := 'Enter a PostgreSQL port from 1024 to 65535 (the usual one is 5432).';
    Exit;
  end;
  if (not IsIdentifier(UserName)) or (UserName = 'postgres') or (UserName = 'lwcam_app') then begin
    Result := 'The user name uses only lowercase letters, digits and underscores, starts with a letter or ' +
      'underscore, and cannot be postgres or lwcam_app (for example lwcam_user).';
    Exit;
  end;
  if FileExists(ExpandConstant('{app}\config\database.txt')) then
    AdminUser := ConfigValue('dbUser', 'postgres')
  else if NeedsPostgreSql() and (not PgReusedCluster) then
    AdminUser := 'postgres'
  else
    AdminUser := DatabasePage.Values[1];
  if UserName = AdminUser then begin
    Result := 'The LWCam user must be a different name from the PostgreSQL administrator (' + AdminUser + ').';
    Exit;
  end;
  if Password = '' then begin
    Result := 'Enter a password for the LWCam user (a silent install needs /APPPASSWORD=).';
    Exit;
  end;
  if Length(Password) < 12 then begin
    Result := 'The password must be at least 12 characters.';
    Exit;
  end;
  if Password <> Trim(Password) then begin
    Result := 'The password cannot start or end with a space.';
    Exit;
  end;
  for I := 1 to Length(Password) do
    if (Ord(Password[I]) < 32) or (Ord(Password[I]) > 126) or (Password[I] = '"') then begin
      Result := 'The password can use letters, digits and symbols, but not a double quote (") and no ' +
        'accented or other non-English characters.';
      Exit;
    end;
  if (not WizardSilent) and (LoginPage.Values[3] <> LoginPage.Values[4]) then begin
    Result := 'The two passwords do not match.';
    Exit;
  end;
  // A fresh PostgreSQL will be installed on this port: refuse one already taken.
  if NeedsPostgreSql() and (not PgReusedCluster) and PortInUse(Port) then
    Result := 'Port ' + Port + ' is already in use on this PC by another program. Pick another port ' +
      '(or stop that program), then continue.';
end;

const
  SameDriveWarning = 'The backup folder is on the same drive as the database itself. If that disk fails, ' +
    'the database AND its backups are lost together. Use another drive or a network share.';

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
// The connection check is skipped exactly where the page itself is skipped: an
// upgrade (config file exists) or a fresh local PostgreSQL install (the page's
// values are unused - WriteConfigIfMissing takes the generated password instead).
// The shared-login page is never skipped and is always re-checked here, which
// also catches a port taken since the page was shown.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := PostgreSqlPrepareProblem();
  if (Result = '') and WizardSilent and not ShouldSkipPage(DatabasePage.ID) then
    Result := ValidateConnPage();
  PrefillLoginPage();
  if Result = '' then
    Result := ValidateLoginPage();
  // The EDB installer ([Run], postgres.iss) reads this for --serverport.
  PgPort := LoginPage.Values[1];
  PrefillBackupPage();
  if (Result = '') and WizardSilent then begin
    Result := ValidateBackupPage();
    // No one to click Yes/No: log it and carry on.
    if (Result = '') and BackupOnDataDrive() then
      Log('WARNING: ' + SameDriveWarning);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (LoginPage <> nil) and (CurPageID = LoginPage.ID) then
    PrefillLoginPage();
  if (BackupPage <> nil) and (CurPageID = BackupPage.ID) then
    PrefillBackupPage();
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
  if (BackupPage <> nil) and (CurPageID = BackupPage.ID) then begin
    if WizardSilent then
      Exit;  // PrepareToInstall validates a silent install
    Msg := ValidateBackupPage();
    if Msg <> '' then begin
      MsgBox(Msg, mbError, MB_OK);
      Result := False;
    end else if BackupOnDataDrive() then
      Result := MsgBox(SameDriveWarning + #13#10#13#10 + 'Continue anyway?',
        mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    Exit;
  end;
  if (DatabasePage = nil) or (LoginPage = nil) then
    Exit;
  if (CurPageID <> DatabasePage.ID) and (CurPageID <> LoginPage.ID) then
    Exit;
  // Setup simulates this click on a silent install too, but there is no one
  // to dismiss the MsgBox below - leave the page alone and let
  // PrepareToInstall's checks fail setup cleanly instead.
  if WizardSilent then
    Exit;

  if CurPageID = DatabasePage.ID then
    Msg := ValidateConnPage()
  else begin
    PrefillLoginPage();
    Msg := ValidateLoginPage();
  end;
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
    'For a server on this PC or another, enter its host and its administrator user and password ' +
    '(its port is on the next page).');
  DatabasePage.Add('Host', False);
  DatabasePage.Add('Administrator user', False);
  DatabasePage.Add('Administrator password', True);
  // Defaults come from the command line (/DBHOST=, /DBUSER=, /DBPASSWORD=),
  // read here so a silent install picks them up even though nothing ever shows
  // this page.
  DatabasePage.Values[0] := ExpandConstant('{param:DBHOST|localhost}');
  DatabasePage.Values[1] := ExpandConstant('{param:DBUSER|postgres}');
  DatabasePage.Values[2] := ExpandConstant('{param:DBPASSWORD|}');

  LoginPage := CreateInputQueryPage(
    DatabasePage.ID,
    'LWCam database login',
    'The one login every LWCam part will use',
    'Choose the database name, port, user and password. QC, LWIP, Upload, LWCam Admin and every ' +
    'capture PC all connect with this same login, so note it: the last page shows it again. ' +
    'The port is where PostgreSQL listens (a new PostgreSQL is installed on it).');
  LoginPage.Add('Database name', False);
  LoginPage.Add('Port (1024-65535)', False);
  LoginPage.Add('User', False);
  LoginPage.Add('Password (at least 12 characters)', True);
  LoginPage.Add('Confirm password', True);
  // Defaults, and the silent parameters: /APPDB=, /DBPORT=, /APPUSER=,
  // /APPPASSWORD=. A re-run overlays what database.txt holds (PrefillLoginPage).
  LoginPage.Values[0] := ExpandConstant('{param:APPDB|lwcam}');
  LoginPage.Values[1] := ExpandConstant('{param:DBPORT|5432}');
  LoginPage.Values[2] := ExpandConstant('{param:APPUSER|lwcam_user}');
  LoginPage.Values[3] := ExpandConstant('{param:APPPASSWORD|}');
  LoginPage.Values[4] := LoginPage.Values[3];

  BackupPage := CreateInputQueryPage(
    LoginPage.ID,
    'Database backups',
    'Where the nightly backup goes',
    'A backup is made every night at 02:00 into this folder (a local disk or a network share). ' +
    'Keep it on a different drive from the database.');
  BackupPage.Add('Backup folder', False);
  BackupPage.Add('Keep the newest (1-365)', False);
  BackupPage.Values[0] := ExpandConstant('{param:BACKUPDIR|}');
  if BackupPage.Values[0] = '' then
    BackupPage.Values[0] := DefaultBackupDir();
  BackupPage.Values[1] := ExpandConstant('{param:BACKUPKEEP|14}');
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

procedure AppendIssue(var Issues: String; const Message: String);
begin
  if Issues <> '' then
    Issues := Issues + #13#10;
  Issues := Issues + '- ' + Message;
end;

// backup.txt always takes the wizard's values (prefilled from the saved file).
// The backup folder is locked to SYSTEM and Administrators - a dump holds every
// password hash in the database. A share cannot be locked from here.
procedure ConfigureBackups(var Issues: String; ProgramFolderLocked: Boolean);
var
  Dir, NL: String;
begin
  NL := #13#10;
  Dir := RemoveBackslash(BackupPage.Values[0]);
  if not SaveStringToFile(ExpandConstant('{app}\config\backup.txt'),
       Utf8Encode('# Nightly backup settings (LWCamDatabaseSetup).' + NL +
         'backupDir = ' + Dir + NL + 'backupKeep = ' + IntToStr(StrToIntDef(BackupPage.Values[1], 14)) + NL), False) then
    AppendIssue(Issues, 'config\backup.txt could not be written.');
  if not ForceDirectories(Dir) then
    AppendIssue(Issues, 'The backup folder ' + Dir + ' could not be created.')
  else if Copy(Dir, 1, 2) = '\\' then
    Log('Backup folder is a share; not locking it. The share must grant this PC''s computer account write access.')
  else if not RestrictToAdmins(Dir, True) then
    AppendIssue(Issues, 'The backup folder could not be restricted to SYSTEM and Administrators.');

  // No pgpass.conf any more: backup_db.py decrypts database.txt and hands the password to
  // pg_dump / pg_restore through the child's environment only.
  // The task runs a .bat as SYSTEM: never register it while the folder that
  // holds that .bat could still be writable by ordinary users.
  if not ProgramFolderLocked then
    AppendIssue(Issues, 'The program folder could not be locked, so the nightly backup task was NOT registered.')
  else if not RegisterScheduledTask('LWCam Database Backup', ExpandConstant('{app}\BACKUP_DATABASE.bat'), True) then
    AppendIssue(Issues, 'The nightly backup task could not be registered.');
end;

// Sets `Key = Value` in Lines: replaces the line that has that key, else appends.
procedure SetConfigLine(var Lines: TArrayOfString; const Key, Value: String);
var
  I, Eq, N: Integer;
  Line: String;
begin
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    Eq := Pos('=', Line);
    if (Eq > 0) and (Copy(Line, 1, 1) <> '#') and
       (CompareText(Trim(Copy(Line, 1, Eq - 1)), Key) = 0) then begin
      Lines[I] := Key + ' = ' + Value;
      Exit;
    end;
  end;
  N := GetArrayLength(Lines);
  SetArrayLength(Lines, N + 1);
  Lines[N] := Key + ' = ' + Value;
end;

// Creates database.txt, or - on a re-run - keeps it and updates only what the
// wizard owns: dbPort, dbName, appUser, appPassword. The administrator login
// (dbHost/dbUser/dbPassword) stays as it was unless PostgreSQL was just
// reinstalled with a new password.
function WriteConfigIfMissing(): Boolean;
var
  ConfigPath, Host, UserName, Password, ConfigText, NL: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  ConfigPath := ExpandConstant('{app}\config\database.txt');
  ForceDirectories(ExtractFileDir(ConfigPath));
  NL := #13#10;
  if FileExists(ConfigPath) then begin
    if not (PgNeeded and not PgReusedCluster) then begin
      // Kept file: update the wizard-owned keys only.
      if not LoadStringsFromFile(ConfigPath, Lines) then begin
        Result := False;
        Exit;
      end;
      SetConfigLine(Lines, 'dbPort', LoginPage.Values[1]);
      SetConfigLine(Lines, 'dbName', LoginPage.Values[0]);
      SetConfigLine(Lines, 'appUser', LoginPage.Values[2]);
      SetConfigLine(Lines, 'appPassword', LoginPassword());
      ConfigText := '';
      for I := 0 to GetArrayLength(Lines) - 1 do begin
        if Copy(Lines[I], 1, 22) = '# Administrator login:' then
          Lines[I] := '# Administrator login: setup and backups only. appUser/appPassword is the ONE login every part uses.';
        ConfigText := ConfigText + Lines[I] + NL;
      end;
      Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
      Exit;
    end;
    // A file kept by an uninstall, but PostgreSQL was installed just now with a NEW
    // password: the old login no longer opens anything. Keep the old file for reference.
    Log('A fresh PostgreSQL cluster was created; replacing the kept config\database.txt (old copy kept as .bak).');
    if not RenameFile(ConfigPath, ConfigPath + '.bak-' + GetDateTimeString('yyyymmdd-hhnnss', #0, #0)) then begin
      Result := False;
      Exit;
    end;
  end;

  if PgNeeded and not PgReusedCluster then begin
    Host := 'localhost';
    UserName := 'postgres';
    Password := PgPassword;
  end else begin
    // Already validated on the page: no surrounding spaces, no line breaks.
    Host := DatabasePage.Values[0];
    UserName := DatabasePage.Values[1];
    Password := DatabasePage.Values[2];
  end;
  if Password = '' then begin
    Result := False;
    Exit;
  end;

  ConfigText :=
    '# LWCam Database connection.' + NL +
    '# Administrator login: setup and backups only. appUser/appPassword is the ONE login every part uses.' + NL +
    'dbHost = ' + Host + NL +
    'dbPort = ' + LoginPage.Values[1] + NL +
    'dbName = ' + LoginPage.Values[0] + NL +
    'dbUser = ' + UserName + NL +
    'dbPassword = ' + Password + NL +
    'appUser = ' + LoginPage.Values[2] + NL +
    'appPassword = ' + LoginPassword() + NL +
    'dbUseSsl = false' + NL;
  Result := SaveStringToFile(ConfigPath, Utf8Encode(ConfigText), False);
end;

// The last line starting with Tag ("[ERROR]" or "[NOTE]") that setup_qc_db.py
// wrote to logs\database-setup.log (a refused --app-login, a lock timeout, the
// old samenet rule kept ...), so the finish page says WHY instead of only
// pointing at the log.
function SetupLogLine(Tag: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := '';
  if LoadStringsFromFile(ExpandConstant('{app}\logs\database-setup.log'), Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if Pos(Tag, Lines[I]) = 1 then
        Result := Trim(Copy(Lines[I], Length(Tag) + 1, 600));
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
  // The batch always adds --app-login <appUser> and reads the password from the
  // LWCAM_APP_PASSWORD environment variable set just below - never a command
  // line. Unticking openlan on this PC's own server takes back what an earlier
  // run opened (--close-lan).
  Params := '/C ""' + ExpandConstant('{app}\SETUP_DATABASE.bat') + '""';
  if OpenedLan then
    Params := Params + ' --open-lan'
  else if IsLocalDbHost(Host) then
    Params := Params + ' --close-lan';
  Win32SetEnv('LWCAM_APP_PASSWORD', AppPasswordEnv);
  try
    Ok := Exec(ExpandConstant('{cmd}'), Params, ExpandConstant('{app}'),
      SW_HIDE, ewWaitUntilTerminated, ResultCode);
  finally
    Win32SetEnv('LWCAM_APP_PASSWORD', '');
  end;
  if (not Ok) or (ResultCode <> 0) or (not FileExists(ExpandConstant('{app}\database\.setup_ok'))) then
  begin
    AppendIssue(Issues, 'Database setup did not complete. ' + SetupLogLine('[ERROR]'));
    AppendIssue(Issues, 'Fix the cause named above (details: logs\database-setup.log), then run this installer ' +
      'again. A lock timeout means the site was busy and nothing was changed: just run it again.');
  end;

  // Delete first: "add rule" never replaces, so every upgrade would otherwise
  // stack another copy - and a copy still open on an old port. Also the whole
  // job when openlan is unticked on this PC's own server: no rule, no access.
  Port := ConfiguredPort();
  if IsLocalDbHost(Host) then
    Exec(ExpandConstant('{sys}\netsh.exe'),
      'advfirewall firewall delete rule name="LWCam Database"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not OpenedLan then
    Exit;
  // profile=any: Tailscale's adapter is often labelled "Public". remoteip keeps
  // it to the local subnet and Tailscale's own ranges (IPv4 CGNAT + IPv6 ULA).
  if not Exec(ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall add rule name="LWCam Database" dir=in action=allow protocol=TCP localport=' +
    Port + ' profile=any remoteip=localsubnet,100.64.0.0/10,fd7a:115c:a1e0::/48',
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
// next installers), masked in the log - a shared file, unlike the screen, and
// /LOG is never to carry a secret.
function DatabaseClosingText(const IsLocal: Boolean;
  const PasswordDisplay: String): String;
var
  NL, Text, Ips: String;
begin
  NL := #13#10;
  Text := 'LWCam Database is installed.' + NL + NL;
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
    'User: ' + ConfigValue('appUser', '') + NL +
    'Password: ' + PasswordDisplay + NL + NL +
    'Enter these same five values (Host, Port, Database, User, Password) in QCPlatformSetup, ' +
    'LWIPSetup, LWCamUploadSetup and in LWCam Admin''s Station Setup on every capture PC.' + NL +
    'The PostgreSQL administrator password is kept in ' + ExpandConstant('{app}\config\database.txt') +
    ' for setup and backups.';
  Result := Text;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Issues, PgMessage, Closing, LoggedClosing, NL, OldRuleNote: String;
  OpenedLan, IsLocal, ProgramLocked: Boolean;
begin
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  // First of all: this folder holds a .bat that a SYSTEM task will run, and
  // scripts that read the database password. It must not be user-writable.
  ProgramLocked := LockProgramFolder(ExpandConstant('{app}'));
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

  // A saved password is already "dpapi:..." (a re-run that kept it): then there is
  // nothing to hand over or show, setup_qc_db.py decrypts the file itself.
  AppPasswordEnv := ConfigValue('appPassword', '');
  AppPasswordShown := AppPasswordEnv;
  if Pos('dpapi:', AppPasswordEnv) = 1 then begin
    AppPasswordEnv := '';
    AppPasswordShown := '(unchanged - kept encrypted in config\database.txt)';
  end;

  Issues := '';
  // Encrypt both passwords right away (Windows DPAPI, tied to this PC). This
  // installer has no service to do it later, so a failure is reported loudly.
  if not ProtectConfigSecrets(ExpandConstant('{app}\runtime\python\python.exe'),
       '"' + ExpandConstant('{app}\scripts\lwcam_secrets.py') + '"', ExpandConstant('{app}'),
       ExpandConstant('{app}\config\database.txt'), 'dbPassword,appPassword') then
    AppendIssue(Issues, PlainSecretsWarning('config\database.txt'));
  ConfigureDatabase(Issues, OpenedLan);
  ConfigureBackups(Issues, ProgramLocked);
  // setup_qc_db.py keeps the old samenet rule while other logins still use it.
  OldRuleNote := SetupLogLine('[NOTE]');
  PgMessage := PostgreSqlClosingMessage(
    'LWCam Database',
    'The connection is stored in config\database.txt. Correct it there if needed,' + NL +
    'then run SETUP_DATABASE.bat as Administrator.');
  IsLocal := IsLocalDbHost(ConfiguredHost());

  Closing := DatabaseClosingText(IsLocal, AppPasswordShown);
  LoggedClosing := DatabaseClosingText(IsLocal, '(hidden - see config\database.txt)');
  if PgMessage <> '' then begin
    Closing := Closing + NL + NL + PgMessage;
    LoggedClosing := LoggedClosing + NL + NL + PgMessage;
  end;
  if OldRuleNote <> '' then begin
    Closing := Closing + NL + NL + OldRuleNote;
    LoggedClosing := LoggedClosing + NL + NL + OldRuleNote;
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
