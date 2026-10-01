; Inno helpers shared by every LWCam installer. Included by postgres.iss,
; and directly by the installers that do not install PostgreSQL.

[Code]
// Counts, and optionally ends, python processes whose command line contains
// Dir - by command line, never by process name, so a station's unrelated Python
// survives. Returns how many are still running afterwards, so a caller can
// refuse to replace files under a process that did not stop: Python closes a
// .py after reading it, so nothing locks the files and an overwrite "works"
// while the old code keeps serving. No braces in the PowerShell: "{" opens an
// Inno constant.
function PythonProcessesUnder(const Dir: String; Terminate: Boolean): Integer;
var
  Command: String;
  ResultCode: Integer;
begin
  Result := 0;
  if (Dir = '') or not DirExists(Dir) then
    Exit;
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    // Stop on any error: a failed CIM query must not read as "0 running".
    // PowerShell then exits 1, which the callers treat as still running.
    '$ErrorActionPreference = ''Stop''; ' +
    '$f = ''Name LIKE ''''python%.exe''''''; ' +
    '$p = @(Get-CimInstance Win32_Process -Filter $f | Where-Object CommandLine -like ''*' + Dir + '*''); ';
  if Terminate then
    Command := Command +
      '$p | Invoke-CimMethod -MethodName Terminate | Out-Null; ' +
      'Start-Sleep -Milliseconds ([Math]::Min($p.Count, 1) * 1500); ' +
      '$p = @(Get-CimInstance Win32_Process -Filter $f | Where-Object CommandLine -like ''*' + Dir + '*''); ';
  Command := Command + 'exit $p.Count"';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
          SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := -1;  // could not even ask: treat as "may still be running"
end;

// "C:\dir\" -> "C:\dir": a trailing backslash before the closing quote of an
// icacls/PowerShell argument turns that quote into an escaped one. A drive root
// ("C:\") is left alone.
function NoTrailingBackslash(const Path: String): String;
begin
  Result := Path;
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

// Replaces Path's permission list with EXACTLY the entries wanted - SYSTEM and
// Administrators, full control, plus (WithUsers) Users, read and run only - all
// inherited by children when Path is a folder. Makes Administrators the owner,
// then reads everything back and returns True only if exactly those entries and
// that owner remain. icacls cannot do this: /grant:r only replaces the grants it
// names, so a grant a technician once gave a named user would survive. The owner
// matters too: an owner can always rewrite the permissions, so a file some user
// created would not stay private. The owner is set with `icacls /setowner` first
// - the standard tool, which uses the take-ownership right an elevated admin has
// - and the PowerShell step then replaces the DACL and verifies owner and DACL
// together. SIDs, not names: any Windows language.
function SetExactAcl(const RawPath: String; IsFolder, WithUsers: Boolean): Boolean;
var
  Command, Kind, Flags, Quoted, Path, Want: String;
  Count, ResultCode: Integer;
begin
  Path := NoTrailingBackslash(RawPath);
  Quoted := Path;
  StringChangeEx(Quoted, '''', '''''', True);  // ' -> '' inside a PowerShell '...' string
  if IsFolder then begin
    Kind := 'DirectorySecurity';
    Flags := '''ContainerInherit, ObjectInherit''';
  end else begin
    Kind := 'FileSecurity';
    Flags := '''None''';
  end;
  if WithUsers then begin
    Count := 3;
    Want := 'S-1-5-18,S-1-5-32-544,S-1-5-32-545';
  end else begin
    Count := 2;
    Want := 'S-1-5-18,S-1-5-32-544';
  end;
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$ErrorActionPreference = ''Stop''; $p = ''' + Quoted + '''; ' +
    '$a = New-Object System.Security.AccessControl.' + Kind + '; ' +
    '$a.SetAccessRuleProtection($true, $false); ' +
    '$r = [System.Security.AccessControl.FileSystemRights]::FullControl; ' +
    '$i = [System.Security.AccessControl.InheritanceFlags]' + Flags + '; ' +
    '$n = [System.Security.AccessControl.PropagationFlags]::None; ' +
    '$t = [System.Security.AccessControl.AccessControlType]::Allow; ' +
    '$a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(' +
      '[System.Security.Principal.SecurityIdentifier]''S-1-5-18'', $r, $i, $n, $t))); ' +
    '$a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(' +
      '[System.Security.Principal.SecurityIdentifier]''S-1-5-32-544'', $r, $i, $n, $t))); ';
  if WithUsers then
    Command := Command +
      '$a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(' +
        '[System.Security.Principal.SecurityIdentifier]''S-1-5-32-545'', ' +
        '[System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $i, $n, $t))); ';
  Command := Command +
    'Set-Acl -LiteralPath $p -AclObject $a; ' +
    '$back = Get-Acl -LiteralPath $p; ' +
    '$rules = @($back.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])); ' +
    '$got = @($rules | ForEach-Object IdentityReference | ForEach-Object Value | Sort-Object -Unique); ' +
    '$owner = $back.GetOwner([System.Security.Principal.SecurityIdentifier]).Value; ' +
    'exit [int](($rules.Count -ne ' + IntToStr(Count) + ') -or (($got -join '','') -ne ''' + Want + ''') ' +
      '-or ($owner -ne ''S-1-5-32-544''))"';
  Result :=
    Exec(ExpandConstant('{sys}\icacls.exe'), '"' + Path + '" /setowner *S-1-5-32-544 /C', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) and
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log('Could not set the permissions of ' + Path + ' (exit ' + IntToStr(ResultCode) + ').');
end;

// Private: SYSTEM and Administrators only.
function RestrictToAdmins(const Path: String; IsFolder: Boolean): Boolean;
begin
  Result := SetExactAcl(Path, IsFolder, False);
end;

// Registers TaskName to run BatPath at system start as SYSTEM, replacing any
// existing task of that name. schtasks /Create cannot set these: it leaves
// Task Scheduler's default 72-hour run limit (a healthy service was killed
// every three days), no restart after a failure, and no start on battery.
// Here: no time limit, restart once a minute up to 999 times if the task
// itself fails, start late if the boot trigger was missed, one instance only.
// The command is NEVER passed through ExpandConstant - it has braces, and "{"
// opens an Inno constant. Only the caller's paths were expanded already.
function RegisterScheduledTask(const TaskName, BatPath: String; Daily: Boolean): Boolean;
var
  Name, Bat, Trigger, Settings: String;
  ResultCode: Integer;
begin
  Name := TaskName;
  Bat := BatPath;
  StringChangeEx(Name, '''', '''''', True);  // ' -> '' inside a PowerShell '...' string
  StringChangeEx(Bat, '''', '''''', True);
  if Daily then begin
    // A nightly job: 02:00, at most 4 hours, retried 3 times 10 minutes apart.
    Trigger := '(New-ScheduledTaskTrigger -Daily -At 02:00)';
    Settings := '(New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) ' +
      '-RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10) -StartWhenAvailable ' +
      '-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew)';
  end else begin
    Trigger := '(New-ScheduledTaskTrigger -AtStartup)';
    Settings := '(New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) ' +
      '-RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable ' +
      '-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew)';
  end;
  Result :=
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -Command "' +
      '$ErrorActionPreference = ''Stop''; try { ' +
      'Register-ScheduledTask -TaskName ''' + Name + ''' ' +
      '-Action (New-ScheduledTaskAction -Execute ''' + Bat + ''') ' +
      '-Trigger ' + Trigger + ' ' +
      '-Principal (New-ScheduledTaskPrincipal -UserId ''SYSTEM'' -LogonType ServiceAccount -RunLevel Highest) ' +
      '-Settings ' + Settings + ' ' +
      '-Force | Out-Null; exit 0 } catch { exit 1 }"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log('Could not register the "' + TaskName + '" task (exit ' + IntToStr(ResultCode) + ').');
end;

function RegisterBootTask(const TaskName, BatPath: String): Boolean;
begin
  Result := RegisterScheduledTask(TaskName, BatPath, False);
end;

// Makes a program folder read-and-run for ordinary users and writable only by
// SYSTEM and Administrators, owned by Administrators. Program Files already
// does this, but a folder a technician relocated or an old installer opened
// (ProgramData\LWCAM was users-modify) would let any user replace code that
// runs as SYSTEM, or plant a stop file. The same read-back-verified Set-Acl as
// RestrictToAdmins, so any other explicit grant (a named user's Modify, say) is
// REMOVED, not merely outvoted. Deliberately not recursive: a sub-folder with
// its own protected list (the private config folder from RestrictToAdmins,
// network-logins) keeps it.
function LockProgramFolder(const Dir: String): Boolean;
begin
  Result := SetExactAcl(Dir, True, True);
end;

// Rejects control characters (including a bare CR or LF) in a value bound for
// a `key = value` config file, so a pasted value cannot inject an extra line.
// Shared because every installer that writes free-text settings (hosts,
// users, passwords, an S3 key) into one needs the same check.
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

// True for a PostgreSQL identifier this suite accepts for a database or login
// name: [a-z_][a-z0-9_]{0,62}. Same rule as setup_qc_db.py --app-login, so a
// name that passes here is never refused later, and nothing odd can reach a
// pg_hba.conf line.
function IsIdentifier(const S: String): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Length(S) >= 1) and (Length(S) <= 63);
  if not Result then
    Exit;
  for I := 1 to Length(S) do begin
    C := S[I];
    if not (((C >= 'a') and (C <= 'z')) or (C = '_') or ((I > 1) and (C >= '0') and (C <= '9'))) then begin
      Result := False;
      Exit;
    end;
  end;
end;

// Shared validation for the "PostgreSQL connection" page every installer that
// needs the shared LWCam database login asks for (QCPlatform, LWIP, Upload) -
// same five fields (Host, Port, Database, User, Password), same rules, so one
// copy replaces three. Returns '' when Page's values are usable, else the
// message to show.
//
// Called twice per installer: from NextButtonClick, for the interactive
// wizard (MsgBox, stay on the page); and from PrepareToInstall, but ONLY when
// WizardSilent - an unattended install simulates every NextButtonClick too,
// with no one there to dismiss a MsgBox, so that call site must leave the
// page alone (see each installer's own NextButtonClick) and let
// PrepareToInstall fail the install cleanly instead, before any file is
// written, with this same wording written to the log.
function ValidateDbPage(const Page: TInputQueryWizardPage): String;
var
  Host, PortText, DbName, UserName, Password: String;
  PortNumber: Integer;
begin
  Result := '';
  // Taken as typed, never trimmed: the config file reader trims values, so a
  // password that really starts or ends with a space could not be stored and
  // would silently become a different password. Refuse it instead.
  Host := Page.Values[0];
  PortText := Page.Values[1];
  DbName := Page.Values[2];
  UserName := Page.Values[3];
  Password := Page.Values[4];
  if (Trim(Host) = '') or (Trim(DbName) = '') or (Trim(UserName) = '') or (Password = '') then begin
    Result := 'Enter the database host, database name, user, and password.';
    Exit;
  end;
  if (Host <> Trim(Host)) or (PortText <> Trim(PortText)) or (DbName <> Trim(DbName)) or
     (UserName <> Trim(UserName)) or (Password <> Trim(Password)) then begin
    Result := 'Database settings cannot start or end with a space. If the PostgreSQL ' +
      'password really does, change it on the server first.';
    Exit;
  end;
  if HasConfigControl(Host) or HasConfigControl(DbName) or HasConfigControl(UserName) or
     HasConfigControl(Password) then begin
    Result := 'Database settings cannot contain line breaks or control characters.';
    Exit;
  end;
  if not IsIdentifier(DbName) then begin
    Result := 'The database name uses only lowercase letters, digits and underscores, and starts with a letter or underscore (for example lwcam).';
    Exit;
  end;
  PortNumber := StrToIntDef(PortText, 0);
  if (PortNumber < 1) or (PortNumber > 65535) then
    Result := 'Enter a PostgreSQL port from 1 to 65535.';
end;

// ---- https for the web pages (tls.py, one copy per service) ----

function TlsFolder(): String;
begin
  Result := ExpandConstant('{commonappdata}\LWCAM\tls');
end;

// One certificate folder per PC, shared by the QC, LWIP and Upload pages. It
// holds the CA and server PRIVATE keys, so it is locked to SYSTEM and
// Administrators BEFORE anything is written into it (files inherit that), and
// its parent is locked so the folder cannot be swapped. The service's own
// Python then creates or renews the certificates (the CA is never replaced, so
// a PC trusts once) and points ConfigPath at them if it names none yet - an
// upgrade adds the keys, a hand-edited choice is kept. The public CA
// certificate is copied next to the program for "Trust this LWCam server.cmd".
function SetUpTls(const Python, Package, WorkDir, ConfigPath: String): Boolean;
var
  Dir: String;
  ResultCode: Integer;
begin
  Dir := TlsFolder();
  Result :=
    ForceDirectories(Dir) and LockProgramFolder(ExtractFileDir(Dir)) and RestrictToAdmins(Dir, True) and
    Exec(Python, '-m ' + Package + ' ensure "' + Dir + '" --config "' + ConfigPath + '"',
      WorkDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) and
    CopyFile(Dir + '\lwcam-ca.crt', ExpandConstant('{app}\LWCam server certificate.crt'), False);
  if not Result then
    Log('Could not set up the https certificate in ' + Dir + ' (exit ' + IntToStr(ResultCode) + ').');
end;

// The plain-English part of every finish page.
function TlsClosingNote(): String;
begin
  Result := 'The page uses https. On every PC that opens it, double-click "Trust this LWCam server.cmd" ' +
    '(in ' + ExpandConstant('{app}') + ') once, then reopen the browser. Copy that file together with ' +
    '"LWCam server certificate.crt". Firefox has its own store: import that .crt under ' +
    'Settings > Privacy & Security > Certificates > View Certificates > Authorities. ' +
    'Old http:// bookmarks no longer work.';
end;

// ---- passwords at rest (lwcam_secrets.py, one identical copy per module) ----

// Encrypts the secret Keys (comma separated) of a config file IN PLACE with the
// module's own runtime: Windows DPAPI, machine scope, so the file is useless
// when copied to another PC (it does NOT hide anything from an administrator
// on this PC). Target is `-m <package>.lwcam_secrets` or a quoted script path.
// Already-protected values are left alone, so a re-run or an upgrade is safe.
// Returns False when it could not be done: the caller must then say loudly that
// the file still holds PLAIN TEXT (the service encrypts it the next time it
// starts; the Database tools have no service, so only a re-run fixes that one).
function ProtectConfigSecrets(const Python, Target, WorkDir, ConfigPath, Keys: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := FileExists(Python) and
    Exec(Python, Target + ' protect-file "' + ConfigPath + '" --keys ' + Keys,
      WorkDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log('Could not encrypt the passwords in ' + ConfigPath + ' (exit ' + IntToStr(ResultCode) + ').');
end;

function PlainSecretsWarning(const ConfigName: String): String;
begin
  Result := 'The passwords in ' + ConfigName + ' could NOT be encrypted and are still stored as PLAIN TEXT. ' +
    'Run setup again as Administrator.';
end;
