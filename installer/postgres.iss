; Shared PostgreSQL setup for LWCam.iss and QCPlatform.iss.
; Keep the detector and password handling here so both products make the same
; install/remote/reuse decision and show the same recovery guidance.

#define PgSetupMask "postgresql-18.*-windows-x64.exe"
#define PgMajor "18"

[Tasks]
Name: "remotedb"; Description: "This station uses a PostgreSQL server on another PC (do not install one here)"; Flags: unchecked

[Run]
; dontlogparameters: the superuser password is on this command line, and Inno
; writes [Run] parameters to the setup log whenever setup runs with /LOG.
Filename: "{code:PgSetupPath}"; Parameters: "--mode unattended --unattendedmodeui minimal --superpassword ""{code:GetPgPassword}"" --serverport 5432 --enable-components server,commandlinetools --disable-components pgAdmin,stackbuilder"; StatusMsg: "Installing PostgreSQL 18 (none was found on this PC)..."; Check: NeedsPostgreSql; Flags: dontlogparameters

[Code]
var
  PgPassword: String;
  PgChecked: Boolean;
  PgNeeded: Boolean;
  PgReusedCluster: Boolean;
  PgSetupCached: String;
  PgSetupSearched: Boolean;

// Any PostgreSQL with a real psql.exe counts. The apps need a server, not a
// specific major; the unified schema and migrations are plain SQL.
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

// EnterpriseDB reuses a matching data directory after an interrupted removal.
// In that case --superpassword is ignored, so ask for the cluster's real
// password instead of saving the generated one.
function StalePgDataDir(): Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf64}\PostgreSQL\{#PgMajor}\data\PG_VERSION'));
end;

function NeedsPostgreSql(): Boolean;
begin
  if not PgChecked then begin
    PgNeeded := (not PsqlOnDisk()) and (not WizardIsTaskSelected('remotedb'));
    PgReusedCluster := PgNeeded and StalePgDataDir();
    PgChecked := True;
    if PgNeeded then
      Log('PostgreSQL: no server found, the bundled installer will run.')
    else if WizardIsTaskSelected('remotedb') then
      Log('PostgreSQL: using a server on another PC; skipping local installation.')
    else
      Log('PostgreSQL: a local server is already present; skipping installation.');
  end;
  Result := PgNeeded;
end;

// Finds the highest-named PostgreSQL 18 installer beside the setup executable.
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

// Called from each installer's own PrepareToInstall, which also has product
// work to do there (stopping its running processes), so the event function
// itself cannot live in this shared file.
function PostgreSqlPrepareProblem(): String;
begin
  Result := '';
  if NeedsPostgreSql() and (PgSetupPath('') = '') then
    Result := 'This PC has no PostgreSQL server and no PostgreSQL 18 installer ' +
      '(postgresql-18.*-windows-x64.exe) is beside this setup file.';
end;

// 24 random bytes from the system CSPRNG, encoded to shell-safe text. The
// password travels through a command line to the EDB installer.
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
    if PgPassword = '' then
      RaiseException('Could not generate a PostgreSQL password. Install PostgreSQL manually and re-run this installer.');
  end;
  Result := PgPassword;
end;

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

// Replaces Path's permission list with EXACTLY two entries - SYSTEM and
// Administrators, full control (inherited by children when Path is a folder)
// - makes Administrators the owner, then reads both back and returns True
// only if exactly those two entries and that owner remain. icacls cannot do
// this: /grant:r only replaces the grants it names, so a grant a technician
// once gave a named user would survive. The owner matters too: an owner can
// always rewrite the permissions, so a file some user created would not stay
// private. The owner is set with `icacls /setowner` first - the standard tool,
// which uses the take-ownership right an elevated admin has - and the
// PowerShell step then replaces the DACL and verifies owner and DACL together.
// SIDs, not names: any Windows language.
function RestrictToAdmins(const Path: String; IsFolder: Boolean): Boolean;
var
  Command, Kind, Flags, Quoted: String;
  ResultCode: Integer;
begin
  Quoted := Path;
  StringChangeEx(Quoted, '''', '''''', True);  // ' -> '' inside a PowerShell '...' string
  if IsFolder then begin
    Kind := 'DirectorySecurity';
    Flags := '''ContainerInherit, ObjectInherit''';
  end else begin
    Kind := 'FileSecurity';
    Flags := '''None''';
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
      '[System.Security.Principal.SecurityIdentifier]''S-1-5-32-544'', $r, $i, $n, $t))); ' +
    'Set-Acl -LiteralPath $p -AclObject $a; ' +
    '$back = Get-Acl -LiteralPath $p; ' +
    '$rules = @($back.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])); ' +
    '$got = @($rules | ForEach-Object IdentityReference | ForEach-Object Value | Sort-Object -Unique); ' +
    '$owner = $back.GetOwner([System.Security.Principal.SecurityIdentifier]).Value; ' +
    'exit [int](($rules.Count -ne 2) -or (($got -join '','') -ne ''S-1-5-18,S-1-5-32-544'') ' +
      '-or ($owner -ne ''S-1-5-32-544''))"';
  Result :=
    Exec(ExpandConstant('{sys}\icacls.exe'), '"' + Path + '" /setowner *S-1-5-32-544 /C', '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) and
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
      SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  if not Result then
    Log('Could not restrict ' + Path + ' to SYSTEM and Administrators (exit ' +
      IntToStr(ResultCode) + ').');
end;

// Common post-install guidance; product-specific details are supplied by the
// caller, while the local/remote/reused/failure decision stays shared.
function PostgreSqlClosingMessage(ProductName, NextStep: String): String;
var
  NL: String;
begin
  Result := '';
  NL := #13#10;
  if WizardIsTaskSelected('remotedb') then
    Result := ProductName + ' is installed. No PostgreSQL server was installed here.' +
      NL + NL + NextStep
  else if PgNeeded and not PsqlOnDisk() then
    Result := 'PostgreSQL could not be installed automatically.' + NL + NL +
      'Install PostgreSQL manually, then finish ' + ProductName + ' setup:' +
      NL + NL + NextStep
  else if PgReusedCluster then
    Result := 'An existing PostgreSQL data cluster was kept. It has its own password.' +
      NL + NL + NextStep;
end;