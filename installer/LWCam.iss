; LWCam offline installer: LWCam Capture and LWCam Admin, for capture PCs.
; LWIP and the database are separate installers now (LWIPSetup.exe,
; LWCamDatabaseSetup.exe); QC review runs from the QC Platform installer.

#define AppNameFull "LWCam"
#ifndef AppVer
  #define AppVer "1.0.1"
#endif
#ifndef BuildId
  #define BuildId "dev"
#endif

#ifndef AppsDir
  #define AppsDir ".."
#endif
#define AdminRelease AppsDir + "\LWCamAdmin\build\windows\x64\runner\Release"
#define LwcamRelease AppsDir + "\LWCAM\build\windows\x64\runner\Release"

#ifndef ScrcpyDir
  #define ScrcpyDir AppsDir + "\LWCAM\scrcpy"
#endif

[Setup]
AppName={#AppNameFull}
; Preserve the shipped GUID so existing LW Suite stations upgrade in place.
AppId={{B41D7E60-8C2A-4F17-9E3B-5A6D0C9F2E48}
AppVersion={#AppVer}
AppPublisher=Lifewood, Inc.
AppPublisherURL=https://lifewood.com/
AppSupportURL=https://lifewood.com/
AppUpdatesURL=https://lifewood.com/
DefaultDirName={autopf}\LWCam
OutputBaseFilename=LWCamSetup
OutputDir=..
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Keep the directory page available. UsePreviousAppDir pre-fills an upgrade
; with the current path; changing it does not move the capture folders configured
; in LWCam Admin or any paths already stored in the database.
DisableDirPage=no
DisableProgramGroupPage=yes
ChangesAssociations=no
ShowLanguageDialog=yes
WizardStyle=modern
UninstallDisplayIcon={app}\LWCamAdmin\lwcam_admin.exe
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[InstallDelete]
; Left by an old all-in-one install: a database password in plain text.
Type: files; Name: "{commonappdata}\LWCAM\station-seed.json"
Type: files; Name: "{app}\station-seed.json"
Type: files; Name: "{app}\postgres-password.txt"
; Remove old LWIP environments before installing the embeddable runtime.
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\venv"
Type: filesandordirs; Name: "{app}\LWCAM\LWIP\python"
Type: files; Name: "{app}\LWCAM\LWIP\python-3.13.14-amd64.exe"
; LWIP is a separate install now (LWIPSetup.exe). An all-in-one station's old
; copy under here is stopped by PrepareToInstall's StopLwip, then removed
; outright - LWCam.iss ships none of it any more.
Type: filesandordirs; Name: "{app}\LWCAM\LWIP"
; The database is set up by LWCamDatabaseSetup.exe now, and LWIP was the only
; user of the Python archive, so an upgrade drops what older versions shipped.
Type: filesandordirs; Name: "{app}\Database"
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
; The former all-in-one installer stored the QC engine here. PrepareToInstall
; has already stopped it (or aborted setup); QC data folders are left untouched.
Type: filesandordirs; Name: "{app}\QC"
; LWCam Admin is Start-menu only now. The all-in-one put a shortcut on the
; desktop via {autodesktop}; it was PrivilegesRequired=admin, so that always
; resolved to the all-users desktop, and an upgraded station must lose it.
Type: files; Name: "{commondesktop}\LWCam Admin.lnk"

[Files]
; Written by build-installer.ps1: "<version>+<commit>", beside each exe (and in {app}).
Source: "vendor\VERSION.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "vendor\VERSION.txt"; DestDir: "{app}\LWCAM"; Flags: ignoreversion
Source: "vendor\VERSION.txt"; DestDir: "{app}\LWCamAdmin"; Flags: ignoreversion
; LWCam Admin
Source: "{#AdminRelease}\*"; DestDir: "{app}\LWCamAdmin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "vendor\vcruntime\*"; DestDir: "{app}\LWCamAdmin"; Flags: ignoreversion

; LWCam Capture and its bundled phone tools
Source: "{#LwcamRelease}\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "vendor\vcruntime\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion
Source: "vendor\adb\*"; DestDir: "{app}\LWCAM"; Flags: ignoreversion
Source: "{#ScrcpyDir}\*"; DestDir: "{app}\LWCAM\scrcpy"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
; These two are the capture pipeline folders. The QC export folders belong to
; the separate QC Platform install.
Name: "{app}\LWCam Capture\1.Images"; Permissions: users-modify
Name: "{app}\LWCam Capture\2.Batches"; Permissions: users-modify
; No users-modify: only installers write lwip.stop here. Post-install
; LockProgramFolder also strips the write access an older install granted.
Name: "{commonappdata}\LWCAM"

#include "common.iss"

[Run]
; Admin is the station configuration tool, so offer it after setup.
Filename: "{app}\LWCamAdmin\lwcam_admin.exe"; Description: "{cm:LaunchProgram,LWCam Admin}"; Flags: postinstall skipifsilent nowait

[Icons]
Name: "{autoprograms}\LWCam\LWCAM"; Filename: "{app}\LWCAM\lwcam.exe"
Name: "{autoprograms}\LWCam\LWCam Admin"; Filename: "{app}\LWCamAdmin\lwcam_admin.exe"
Name: "{autodesktop}\LWCAM"; Filename: "{app}\LWCAM\lwcam.exe"

[UninstallDelete]
Type: files; Name: "{app}\python-3.13.14-embed-amd64.zip"
Type: files; Name: "{app}\postgres-password.txt"
Type: files; Name: "{app}\station-seed.json"
Type: files; Name: "{commonappdata}\LWCAM\station-seed.json"
Type: filesandordirs; Name: "{app}\QC"

[Code]
var
  StoppedQcBackends: Integer;

// Stops the all-in-one's QC engine under {app}\QC, which this upgrade deletes.
// Returns how many of its processes are still alive afterwards.
function StopQcBackend(): Integer;
var
  QcDir: String;
begin
  QcDir := ExpandConstant('{app}\QC');
  StoppedQcBackends := PythonProcessesUnder(QcDir, False);
  Result := PythonProcessesUnder(QcDir, True);
end;

// Stops LWIP before its .py files are overwritten. Graceful first: the stop
// file makes LWIP finish the folder it is publishing and exit clean (dropped
// folders are not journalled, so the next run redoes them). Terminate is the
// fallback for a wedged process, and every kill window recovers the same way.
// Returns how many LWIP processes are still alive afterwards.
function StopLwip(): Integer;
var
  Command, LwipDir, StopFile: String;
  ResultCode: Integer;
begin
  Result := 0;
  LwipDir := ExpandConstant('{app}\LWCAM\LWIP');
  if not DirExists(LwipDir) then
    Exit;

  StopFile := ExpandConstant('{commonappdata}\LWCAM\lwip.stop');
  ForceDirectories(ExpandConstant('{commonappdata}\LWCAM'));
  SaveStringToFile(StopFile, 'stop', False);

  // Wait up to 90 s for the graceful exit. No braces: "{" opens a constant.
  Command :=
    '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$p = @(Get-CimInstance Win32_Process -Filter ''Name LIKE ''''python%.exe'''''' | ' +
    'Where-Object CommandLine -like ''*' + LwipDir + '*''); ' +
    'Wait-Process -Id @($p | Select-Object -ExpandProperty ProcessId) ' +
    '-Timeout 90 -ErrorAction SilentlyContinue; exit 0"';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := PythonProcessesUnder(LwipDir, True);
  // Consume the request if LWIP was not running to read it, so it cannot
  // stop the NEXT start.
  DeleteFile(StopFile);
end;

// Runs before a single file is written or deleted. A process that will not
// stop aborts setup cleanly: overwriting a live Python's .py files succeeds
// silently (nothing locks them) and leaves the old code running. LWIP is a
// separate install now, but an all-in-one station upgrading in place may
// still have the old copy running under {app}\LWCAM\LWIP - stop it before
// [InstallDelete] removes that folder.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if StopQcBackend() <> 0 then
    Result := 'The old QC engine under ' + ExpandConstant('{app}\QC') +
      ' could not be stopped, so it was not removed. Restart the PC and run setup again.'
  else if StopLwip() <> 0 then
    Result := 'The image-processing worker (LWIP) could not be stopped, so its files ' +
      'were not replaced. Restart the PC and run setup again.';
end;

function PreviousInstallDir(): String;
var
  Value: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM,
       'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B41D7E60-8C2A-4F17-9E3B-5A6D0C9F2E48}_is1',
       'InstallLocation', Value) then
    Result := RemoveBackslash(Value);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Previous: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;
  Previous := PreviousInstallDir();
  if (Previous = '') or (CompareText(Previous, RemoveBackslash(WizardDirValue)) = 0) then
    Exit;
  // Setup simulates this click on a silent install too, but there is no one
  // to answer a Yes/No MsgBox - default to the same answer /SUPPRESSMSGBOXES
  // gives every other confirmation (Yes, continue) rather than hang.
  if WizardSilent then
    Exit;
  Result := MsgBox(
    'LWCam is already installed here:' + #13#10 + #13#10 +
    '    ' + Previous + #13#10 + #13#10 +
    'You chose to install it here instead:' + #13#10 + #13#10 +
    '    ' + RemoveBackslash(WizardDirValue) + #13#10 + #13#10 +
    'The capture paths are stored in LWCam Admin and are not moved with the' +
    ' application. After setup, check Station Setup and move any data folders' +
    ' yourself if you want them to follow this install.' + #13#10 + #13#10 +
    'Install to the new folder anyway?',
    mbConfirmation, MB_YESNO) = IDYES;
end;

// Deletes the old all-in-one's per-user LWIP autostart entry. It used to
// launch LWIP itself from LWCAM's own logon; the standalone install runs
// LWIP as a SYSTEM scheduled task instead (LWIPSetup.exe on the LWIP PC), so
// a station upgrading from that layout must not go on starting a second,
// now-deleted copy from here every time someone logs on.
function RemoveLwipAutostart(): Boolean;
begin
  Result := True;
  if RegValueExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'LWCamLWIP') then
    Result := RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'LWCamLWIP');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  NL, Closing: String;
begin
  // QC engine and LWIP were stopped in PrepareToInstall, before any file changed.
  if CurStep <> ssPostInstall then
    Exit;

  NL := #13#10;
  RemoveLwipAutostart();
  // The shared stop-file folder: only installers write it. Also strips the
  // users-modify an older install granted. Its network-logins sub-folder keeps
  // its own protected list (LWIP/Upload/QC restrict it themselves).
  if not LockProgramFolder(ExpandConstant('{commonappdata}\LWCAM')) then
    Log('LWCam: ' + ExpandConstant('{commonappdata}\LWCAM') + ' could not be locked to Administrators.');

  // Only the fact of the install: the setup steps live in installer\README.txt.
  Closing := 'LWCam is installed.';
  if StoppedQcBackends > 0 then
    Log('LWCam: the old QC engine was stopped and removed.');

  Log('LWCam finished:' + NL + Closing);
  SuppressibleMsgBox(Closing, mbInformation, MB_OK, IDOK);
end;