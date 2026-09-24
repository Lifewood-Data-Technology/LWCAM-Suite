<#
.SYNOPSIS
  Build LWCam, the QC Platform, or both installers.

.DESCRIPTION
  Builds the QC console when QC is selected, checks the staged offline inputs,
  compiles the requested Inno Setup scripts, and places the matching PostgreSQL
  installer beside the output in the repository root.
#>
[CmdletBinding()]
param(
    [ValidateSet('LWCam', 'QC', 'All')]
    [string] $Target = 'All',

    [string] $ScrcpyDir,

    [switch] $ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Newest {
    param([string[]] $Candidates)
    Get-Item -Path $Candidates -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Require-File {
    param([string] $Path, [string] $Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
}

function Require-Directory {
    param([string] $Path, [string] $Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description not found: $Path"
    }
}

$installerDir = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $installerDir '..'))
$targets = if ($Target -eq 'All') { @('LWCam', 'QC') } else { @($Target) }
$scriptByTarget = @{ LWCam = 'LWCam.iss'; QC = 'QCPlatform.iss' }
$iscc = Resolve-Newest @(
    "$env:LOCALAPPDATA\Programs\Inno Setup*\ISCC.exe"
    "$([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))\Inno Setup*\ISCC.exe"
    "$env:ProgramFiles\Inno Setup*\ISCC.exe"
)
if (-not $iscc) {
    throw 'ISCC.exe not found. Install Inno Setup 6.'
}

$scrcpy = $null
if ($targets -contains 'LWCam') {
    if ($ScrcpyDir) {
        Require-Directory $ScrcpyDir '-ScrcpyDir'
        $scrcpy = Get-Item -LiteralPath $ScrcpyDir
    } else {
        $inRepo = Join-Path $repoRoot 'LWCAM\scrcpy'
        $scrcpy = if (Test-Path -LiteralPath (Join-Path $inRepo 'scrcpy.exe')) {
            Get-Item -LiteralPath $inRepo
        } else {
            Resolve-Newest @(
                "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Genymobile.scrcpy_*\scrcpy-win64-*"
            )
        }
        if (-not $scrcpy) {
            throw 'scrcpy not found. Put a Windows build in LWCAM\scrcpy, install it, or pass -ScrcpyDir.'
        }
    }
    Require-File (Join-Path $scrcpy.FullName 'scrcpy.exe') 'scrcpy.exe'
}

$pgSource = Get-ChildItem -LiteralPath (Join-Path $installerDir 'vendor\postgresql') -Filter 'postgresql-18.*-windows-x64.exe' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $pgSource) {
    throw 'No PostgreSQL 18 installer found under installer\vendor\postgresql.'
}

Require-File (Join-Path $installerDir 'postgres.iss') 'Shared PostgreSQL include'
foreach ($targetName in $targets) {
    Require-File (Join-Path $installerDir $scriptByTarget[$targetName]) "$targetName installer script"
}

Write-Host "ISCC   : $($iscc.FullName)"
if ($scrcpy) { Write-Host "scrcpy : $($scrcpy.FullName)" }
Write-Host "Target : $Target"

if ($ResolveOnly) {
    Write-Host 'ResolveOnly: nothing built.'
    return
}

$pythonZip = Join-Path $installerDir 'vendor\python-3.13.14-embed-amd64.zip'
Require-File $pythonZip 'Embeddable Python archive'
$vcRuntime = Join-Path $installerDir 'vendor\vcruntime'
Require-Directory $vcRuntime 'Visual C++ runtime folder'
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Require-File (Join-Path $vcRuntime $name) 'Visual C++ runtime DLL'
}

if ($targets -contains 'LWCam') {
    Require-File (Join-Path $repoRoot 'LWCamAdmin\build\windows\x64\runner\Release\lwcam_admin.exe') 'LWCam Admin release build'
    Require-File (Join-Path $repoRoot 'LWCAM\build\windows\x64\runner\Release\lwcam.exe') 'LWCam release build'
    foreach ($name in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        Require-File (Join-Path $installerDir "vendor\adb\$name") "ADB input $name"
    }
    Require-File (Join-Path $repoRoot 'LWCAM\LWIP\tools\jpegtran.exe') 'LWIP jpegtran'
    Require-Directory (Join-Path $repoRoot 'LWCAM\LWIP\wheels') 'LWIP wheelhouse'
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCAM\LWIP\wheels') -Filter 'pip-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {         throw 'The LWIP wheelhouse has no pip wheel.'     }     Require-File (Join-Path $repoRoot 'LWCAM\LWIP\SETUP_DESKEW_CROP.bat') 'LWIP runtime setup script'
    Require-File (Join-Path $scrcpy.FullName 'scrcpy.exe') 'scrcpy.exe'
}

if ($targets -contains 'QC') {
    $frontendDir = Join-Path $repoRoot 'LWCam_QC_Platform\frontend'
    Push-Location $frontendDir
    try {
        Write-Host 'Building QC console (npm run build)...'
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\backend\requirements.txt') 'QC backend requirements'
    Require-Directory (Join-Path $repoRoot 'LWCam_QC_Platform\backend\wheels') 'QC backend wheelhouse'
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\backend\wheels') -Filter 'pip-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC backend wheelhouse has no pip wheel.'
    }
    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\frontend\dist\index.html') 'Built QC console'
    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\scripts\setup_qc_db.py') 'QC database setup script'
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database') -Filter 'LWCam_database_unified_*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no unified schema SQL.'
    }
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database\migrations') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no migrations.'
    }
    foreach ($name in @('SETUP_QC.bat', 'SETUP_DB.bat', 'START_QC_SERVER.bat', 'OPEN_QC_LOG.bat')) {
        Require-File (Join-Path $installerDir "qc\$name") "QC helper $name"
    }
}

foreach ($targetName in $targets) {
    $iss = Join-Path $installerDir $scriptByTarget[$targetName]
    $arguments = @("/DAppsDir=$repoRoot")
    if ($targetName -eq 'LWCam') {
        $arguments += "/DScrcpyDir=$($scrcpy.FullName)"
    }
    $arguments += $iss

    Write-Host "Compiling $targetName..."
    & $iscc.FullName @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ISCC failed for $targetName with exit code $LASTEXITCODE."
    }

    $outputName = if ($targetName -eq 'LWCam') { 'LWCamSetup.exe' } else { 'QCPlatformSetup.exe' }
    $built = Join-Path $repoRoot $outputName
    Require-File $built "$targetName installer output"
    $sizeMb = [math]::Round((Get-Item -LiteralPath $built).Length / 1MB, 1)
    Write-Host "Built  : $built ($sizeMb MB)"
}

$pgTarget = Join-Path $repoRoot $pgSource.Name
if (-not (Test-Path -LiteralPath $pgTarget) -or
    (Get-Item -LiteralPath $pgTarget).Length -ne $pgSource.Length) {
    Copy-Item -LiteralPath $pgSource.FullName -Destination $pgTarget -Force
}
$pgMb = [math]::Round((Get-Item -LiteralPath $pgTarget).Length / 1MB, 1)
Write-Host "Beside : $pgTarget ($pgMb MB)"
Write-Host 'Ship each setup file with the PostgreSQL installer. A PC with PostgreSQL already installed needs only the setup file.'