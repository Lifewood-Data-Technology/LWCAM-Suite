; Shared PostgreSQL setup, used by the LWCam Database installer (Database.iss).
; LWIP.iss, LWCam.iss and QCPlatform.iss no longer install PostgreSQL themselves
; (Database.iss owns that job now); kept generic so any of them could include
; it again later without changes here.

#include "common.iss"

#define PgSetupMask "postgresql-18.*-windows-x64.exe"
#define PgMajor "18"

[Tasks]
Name: "remotedb"; Description: "Use an existing PostgreSQL server (on this PC or another) instead of installing one"; Flags: unchecked

[Run]
; dontlogparameters: the superuser password is on this command line, and Inno
; writes [Run] parameters to the setup log whenever setup runs with /LOG.
Filename: "{code:PgSetupPath}"; Parameters: "--mode unattended --unattendedmodeui minimal --superpassword ""{code:GetPgPassword}"" --serverport {code:GetPgPort} --enable-components server,commandlinetools --disable-components pgAdmin,stackbuilder"; StatusMsg: "Installing PostgreSQL 18 (none was found on this PC)..."; Check: NeedsPostgreSql; Flags: dontlogparameters

[Code]
var
  PgPassword: String;
  PgPort: String;  // the port the operator chose; Database.iss sets it before [Run]
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

// The port for a fresh PostgreSQL install (EDB --serverport).
function GetPgPort(Param: String): String;
begin
  if PgPort = '' then
    Result := '5432'
  else
    Result := PgPort;
end;

// The port an existing local server listens on: `port = N` in the postgresql.conf
// of the highest-numbered PostgreSQL under Program Files, else 5432. Only used
// to prefill the wizard, so a wrong guess is harmless (the operator can edit it).
function PgConfPort(): String;
var
  Find: TFindRec;
  Base, Best, Conf, Line: String;
  Lines: TArrayOfString;
  I, Eq, Hash, Number: Integer;
begin
  Result := '5432';
  Base := ExpandConstant('{commonpf64}\PostgreSQL');
  Best := '';
  if FindFirst(Base + '\*', Find) then begin
    try
      repeat
        if (Find.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0)
           and (Find.Name <> '.') and (Find.Name <> '..') then
          if FileExists(Base + '\' + Find.Name + '\data\postgresql.conf') and
             ((Best = '') or (CompareText(Find.Name, Best) > 0)) then
            Best := Find.Name;
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
  end;
  if Best = '' then
    Exit;
  Conf := Base + '\' + Best + '\data\postgresql.conf';
  if not LoadStringsFromFile(Conf, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    Eq := Pos('=', Line);
    if (Eq > 0) and (CompareText(Trim(Copy(Line, 1, Eq - 1)), 'port') = 0) then begin
      Line := Trim(Copy(Line, Eq + 1, Length(Line)));
      Hash := Pos('#', Line);
      if Hash > 0 then
        Line := Trim(Copy(Line, 1, Hash - 1));
      Number := StrToIntDef(Line, 0);
      if (Number > 0) and (Number < 65536) then
        Result := IntToStr(Number);
    end;
  end;
end;

// True when something on this PC is already listening on the TCP port. Asked of
// PowerShell (no braces in the command: "{" opens an Inno constant). If it
// cannot even ask, report "free": the EDB installer then fails visibly instead.
function PortInUse(const Port: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "exit [int]((Get-NetTCPConnection -State Listen ' +
    '-LocalPort ' + Port + ' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 1);
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

// Common post-install guidance; product-specific details are supplied by the
// caller, while the local/remote/reused/failure decision stays shared.
function PostgreSqlClosingMessage(ProductName, NextStep: String): String;
var
  NL: String;
begin
  Result := '';
  NL := #13#10;
  // Only what went wrong or needs acting on: a server on another PC chosen on
  // purpose is not news.
  if WizardIsTaskSelected('remotedb') then
    Result := ''
  else if PgNeeded and not PsqlOnDisk() then
    Result := 'PostgreSQL could not be installed automatically.' + NL + NL +
      'Install PostgreSQL manually, then finish ' + ProductName + ' setup:' +
      NL + NL + NextStep
  else if PgReusedCluster then
    Result := 'An existing PostgreSQL data cluster was kept. It has its own password.' +
      NL + NL + NextStep;
end;