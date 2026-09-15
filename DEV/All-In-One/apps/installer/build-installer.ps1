<#
.SYNOPSIS
  Compile LWSuite.exe from LWSuite.iss.

.DESCRIPTION
  Resolves the two build inputs that are NOT in this repository and whose paths
  move on their own, then calls ISCC:

    ISCC.exe   Inno Setup is a winget package here, so it installs under
               %LOCALAPPDATA%\Programs\Inno Setup 6 and puts nothing on PATH.
    scrcpy     Deliberately not in the repository (licence + size). The winget
               package folder carries the version in its name
               (scrcpy-win64-v4.1), so a `winget upgrade` renames it and any
               hard-coded /DScrcpyDir path silently breaks the compile with a
               missing-source error.

  Both are resolved by glob and the newest match wins. Anything missing is a
  hard failure here, with the fix named, rather than a confusing ISCC error.

.PARAMETER ScrcpyDir
  Override the auto-resolved scrcpy folder.

.PARAMETER ResolveOnly
  Print the resolved paths and exit without compiling. Use this to check the
  resolution still works after a winget upgrade.

.EXAMPLE
  .\build-installer.ps1
  .\build-installer.ps1 -ResolveOnly
  .\build-installer.ps1 -ScrcpyDir D:\tools\scrcpy-win64-v3.1
#>
[CmdletBinding()]
param(
    [string] $ScrcpyDir,
    [switch] $ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Newest match wins, so a winget upgrade is picked up without editing anything.
function Resolve-Newest {
    param([string[]] $Candidates)
    Get-Item -Path $Candidates -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

$here = $PSScriptRoot
$iss = Join-Path $here 'LWSuite.iss'
if (-not (Test-Path -LiteralPath $iss)) {
    throw "LWSuite.iss not found beside this script ($here)."
}

$iscc = Resolve-Newest @(
    "$env:LOCALAPPDATA\Programs\Inno Setup*\ISCC.exe"
    "${env:ProgramFiles(x86)}\Inno Setup*\ISCC.exe"
    "$env:ProgramFiles\Inno Setup*\ISCC.exe"
)
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup: winget install JRSoftware.InnoSetup"
}

if ($ScrcpyDir) {
    if (-not (Test-Path -LiteralPath $ScrcpyDir)) {
        throw "-ScrcpyDir does not exist: $ScrcpyDir"
    }
    $scrcpy = Get-Item -LiteralPath $ScrcpyDir
} else {
    # The in-repo copy first: it is what LWSuite.iss falls back to when no
    # /DScrcpyDir is passed, so resolving anything else here would silently
    # build a different scrcpy than a plain ISCC run would. The winget package
    # is the fallback, for a checkout that has no scrcpy folder yet.
    # Resolve-Newest would pick by mtime, which is wrong here: the repo copy has
    # to win outright, or this script builds a different scrcpy than the bare
    # `ISCC LWSuite.iss` the .iss's own #ifndef default produces.
    $inRepo = Join-Path $here '..\LWCAM\scrcpy'
    $scrcpy = if (Test-Path -LiteralPath (Join-Path $inRepo 'scrcpy.exe')) {
        Get-Item -LiteralPath $inRepo
    } else {
        Resolve-Newest @(
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Genymobile.scrcpy_*\scrcpy-win64-*"
        )
    }
    if (-not $scrcpy) {
        throw "scrcpy not found. Put a Windows build in apps\LWCAM\scrcpy, install it (winget install Genymobile.scrcpy), or pass -ScrcpyDir."
    }
}

# The [Files] entry is "{#ScrcpyDir}\*", so an scrcpy folder without scrcpy.exe
# would compile happily and ship a capture station that cannot mirror a phone.
if (-not (Test-Path -LiteralPath (Join-Path $scrcpy.FullName 'scrcpy.exe'))) {
    throw "No scrcpy.exe in $($scrcpy.FullName) - wrong folder, pass -ScrcpyDir."
}

Write-Host "ISCC   : $($iscc.FullName)"
Write-Host "scrcpy : $($scrcpy.FullName)"

if ($ResolveOnly) {
    Write-Host 'ResolveOnly: nothing compiled.'
    return
}

& $iscc.FullName "/DScrcpyDir=$($scrcpy.FullName)" $iss
if ($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit code $LASTEXITCODE."
}

# Must track OutputDir in LWSuite.iss (the All-In-One folder root, two levels up).
$out = Join-Path $here '..\..\LWSuite.exe'
$built = Get-Item -LiteralPath $out
$mb = [math]::Round($built.Length / 1MB, 1)
Write-Host "Built  : $($built.FullName) ($mb MB)"

# The PostgreSQL server is no longer inside LWSuite.exe (see LWSuite.iss). It
# has to travel BESIDE it, so put it next to the freshly built installer rather
# than leaving the operator to find it under installer\vendor.
# Any 18.x point release: LWSuite.iss accepts postgresql-18.*-windows-x64.exe
# and takes the highest name, so do the same here.
$pgSource = Get-ChildItem -LiteralPath (Join-Path $here 'vendor\postgresql') -Filter 'postgresql-18.*-windows-x64.exe' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
if ($pgSource) {
    $pgTarget = Join-Path (Split-Path -Parent $built.FullName) $pgSource.Name
    if (-not (Test-Path -LiteralPath $pgTarget) -or
        (Get-Item -LiteralPath $pgTarget).Length -ne $pgSource.Length) {
        Copy-Item -LiteralPath $pgSource.FullName -Destination $pgTarget -Force
    }
    $pgMb = [math]::Round((Get-Item -LiteralPath $pgTarget).Length / 1MB, 1)
    Write-Host "Beside : $pgTarget ($pgMb MB)"
    Write-Host 'Ship BOTH files together. A PC that already has PostgreSQL needs only the installer.'
} else {
    Write-Warning "No postgresql-18.*-windows-x64.exe under installer\vendor\postgresql - a clean PC will refuse to install unless one is put beside LWSuite.exe."
}
