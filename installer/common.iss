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

// Shared validation for the "PostgreSQL connection" page every installer that
// needs a database login asks for (Database, QCPlatform, LWIP, Upload) - same
// four fields, same rules, so one copy replaces four. Returns '' when Page's
// values are usable, else the message to show.
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
  Host, PortText, UserName, Password: String;
  PortNumber: Integer;
begin
  Result := '';
  // Taken as typed, never trimmed: the config file reader trims values, so a
  // password that really starts or ends with a space could not be stored and
  // would silently become a different password. Refuse it instead.
  Host := Page.Values[0];
  PortText := Page.Values[1];
  UserName := Page.Values[2];
  Password := Page.Values[3];
  if (Trim(Host) = '') or (Trim(UserName) = '') or (Password = '') then begin
    Result := 'Enter the PostgreSQL host, user, and password.';
    Exit;
  end;
  if (Host <> Trim(Host)) or (PortText <> Trim(PortText)) or
     (UserName <> Trim(UserName)) or (Password <> Trim(Password)) then begin
    Result := 'Database settings cannot start or end with a space. If the PostgreSQL ' +
      'password really does, change it on the server first.';
    Exit;
  end;
  if HasConfigControl(Host) or HasConfigControl(UserName) or HasConfigControl(Password) then begin
    Result := 'Database settings cannot contain line breaks or control characters.';
    Exit;
  end;
  PortNumber := StrToIntDef(PortText, 0);
  if (PortNumber < 1) or (PortNumber > 65535) then
    Result := 'Enter a PostgreSQL port from 1 to 65535.';
end;
