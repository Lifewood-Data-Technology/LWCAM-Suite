<#
.SYNOPSIS
  Build LWCam, the QC Platform, LWIP, Upload, the Database installer, or all five.

.DESCRIPTION
  Builds the QC console when QC is selected, checks the staged offline inputs,
  compiles the requested Inno Setup scripts, and for Database places the
  PostgreSQL installer beside the output in the repository root.
#>
[CmdletBinding()]
param(
    [ValidateSet('LWCam', 'QC', 'LWIP', 'Upload', 'Database', 'All')]
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

function Require-Wheel {
    param([string] $WheelDir, [string] $Filter, [string] $Description)
    if (-not (Get-ChildItem -LiteralPath $WheelDir -Filter $Filter -File -ErrorAction SilentlyContinue |
              Select-Object -First 1)) {
        throw "$Description has no $Filter wheel."
    }
}

$installerDir = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $installerDir '..'))
$targets = if ($Target -eq 'All') { @('LWCam', 'QC', 'LWIP', 'Upload', 'Database') } else { @($Target) }
$scriptByTarget = @{ LWCam = 'LWCam.iss'; QC = 'QCPlatform.iss'; LWIP = 'LWIP.iss'; Upload = 'Upload.iss'; Database = 'Database.iss' }
$outputByTarget = @{ LWCam = 'LWCamSetup.exe'; QC = 'QCPlatformSetup.exe'; LWIP = 'LWIPSetup.exe'; Upload = 'LWCamUploadSetup.exe'; Database = 'LWCamDatabaseSetup.exe' }
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

# common.iss (PythonProcessesUnder, RestrictToAdmins) is included by every
# target, directly or (for Database) through postgres.iss.
Require-File (Join-Path $installerDir 'common.iss') 'Shared Inno helpers include'
foreach ($targetName in $targets) {
    Require-File (Join-Path $installerDir $scriptByTarget[$targetName]) "$targetName installer script"
}

# Only Database.iss installs PostgreSQL - LWCam, QC and LWIP just connect to
# a server LWCamDatabaseSetup already created.
$pgSource = $null
if ($targets -contains 'Database') {
    Require-File (Join-Path $installerDir 'postgres.iss') 'Shared PostgreSQL include'
    $pgSource = Get-ChildItem -LiteralPath (Join-Path $installerDir 'vendor\postgresql') -Filter 'postgresql-18.*-windows-x64.exe' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $pgSource) {
        throw 'No PostgreSQL 18 installer found under installer\vendor\postgresql.'
    }
}

Write-Host "ISCC   : $($iscc.FullName)"
if ($scrcpy) { Write-Host "scrcpy : $($scrcpy.FullName)" }
Write-Host "Target : $Target"

if ($ResolveOnly) {
    Write-Host 'ResolveOnly: nothing built.'
    return
}

# QC, LWIP and Database all build a private Python runtime from the same
# embeddable archive and vcruntime DLLs; LWCam no longer needs either (LWIP
# moved out of it). The DLL folder itself is still checked unconditionally -
# LWCam's own Flutter apps ship a copy beside their exes too.
$vcRuntime = Join-Path $installerDir 'vendor\vcruntime'
Require-Directory $vcRuntime 'Visual C++ runtime folder'
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    Require-File (Join-Path $vcRuntime $name) 'Visual C++ runtime DLL'
}
if (($targets -contains 'QC') -or ($targets -contains 'LWIP') -or ($targets -contains 'Upload') -or ($targets -contains 'Database')) {
    Require-File (Join-Path $installerDir 'vendor\python-3.13.14-embed-amd64.zip') 'Embeddable Python archive'
}

if ($targets -contains 'LWCam') {
    Require-File (Join-Path $repoRoot 'LWCamAdmin\build\windows\x64\runner\Release\lwcam_admin.exe') 'LWCam Admin release build'
    Require-File (Join-Path $repoRoot 'LWCAM\build\windows\x64\runner\Release\lwcam.exe') 'LWCam release build'
    foreach ($name in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        Require-File (Join-Path $installerDir "vendor\adb\$name") "ADB input $name"
    }
}

if ($targets -contains 'LWIP') {
    Require-File (Join-Path $repoRoot 'LWIP\tools\jpegtran.exe') 'LWIP jpegtran'
    Require-Directory (Join-Path $repoRoot 'LWIP\wheels') 'LWIP wheelhouse'
    Require-Wheel (Join-Path $repoRoot 'LWIP\wheels') 'pip-*.whl' 'The LWIP wheelhouse'
    # The console's login checks passwords with bcrypt, same as the QC server.
    Require-Wheel (Join-Path $repoRoot 'LWIP\wheels') 'bcrypt-*.whl' 'The LWIP wheelhouse'
    Require-File (Join-Path $repoRoot 'LWIP\SETUP_DESKEW_CROP.bat') 'LWIP runtime setup script'
    Require-File (Join-Path $repoRoot 'LWIP\START_LWIP.bat') 'LWIP service launcher script'
    Require-File (Join-Path $repoRoot 'LWIP\backend\deskew_crop_tool\web\index.html') 'LWIP console page'
}

if ($targets -contains 'Upload') {
    Require-Directory (Join-Path $repoRoot 'LWCam_Upload\wheels') 'Upload wheelhouse'
    foreach ($wheel in @('pip-*.whl', 'boto3-*.whl', 'botocore-*.whl', 's3transfer-*.whl', 'psycopg-*.whl', 'psycopg_binary-*.whl', 'bcrypt-*.whl')) {
        Require-Wheel (Join-Path $repoRoot 'LWCam_Upload\wheels') $wheel 'The Upload wheelhouse'
    }
    Require-File (Join-Path $repoRoot 'LWCam_Upload\requirements.txt') 'Upload requirements'
    Require-File (Join-Path $repoRoot 'LWCam_Upload\SETUP_UPLOAD.bat') 'Upload runtime setup script'
    Require-File (Join-Path $repoRoot 'LWCam_Upload\START_UPLOAD.bat') 'Upload service launcher script'
    Require-File (Join-Path $repoRoot 'LWCam_Upload\backend\lwcam_upload\web\index.html') 'Upload console page'
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
    Require-Wheel (Join-Path $repoRoot 'LWCam_QC_Platform\backend\wheels') 'pip-*.whl' 'The QC backend wheelhouse'
    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\frontend\dist\index.html') 'Built QC console'
    foreach ($name in @('SETUP_QC.bat', 'START_QC_SERVER.bat', 'OPEN_QC_LOG.bat')) {
        Require-File (Join-Path $installerDir "qc\$name") "QC helper $name"
    }
}

if ($targets -contains 'Database') {
    # Database.iss ships these straight out of the LWIP wheelhouse - it needs
    # only the DB driver and pip itself, not the image-processing libraries.
    foreach ($wheel in @('pip-*.whl', 'psycopg-*.whl', 'psycopg_binary-*.whl', 'tzdata-*.whl')) {
        Require-Wheel (Join-Path $repoRoot 'LWIP\wheels') $wheel 'The LWIP wheelhouse'
    }
    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\scripts\setup_qc_db.py') 'QC database setup script'
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database') -Filter 'LWCam_database_unified_*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no unified schema SQL.'
    }
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database\migrations') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no migrations.'
    }
    foreach ($name in @('SETUP_DB_RUNTIME.bat', 'SETUP_DATABASE.bat')) {
        Require-File (Join-Path $installerDir "db\$name") "Database helper $name"
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

    $built = Join-Path $repoRoot $outputByTarget[$targetName]
    Require-File $built "$targetName installer output"
    $sizeMb = [math]::Round((Get-Item -LiteralPath $built).Length / 1MB, 1)
    Write-Host "Built  : $built ($sizeMb MB)"
}

if ($targets -contains 'Database') {
    $pgTarget = Join-Path $repoRoot $pgSource.Name
    if (-not (Test-Path -LiteralPath $pgTarget) -or
        (Get-Item -LiteralPath $pgTarget).Length -ne $pgSource.Length) {
        Copy-Item -LiteralPath $pgSource.FullName -Destination $pgTarget -Force
    }
    $pgMb = [math]::Round((Get-Item -LiteralPath $pgTarget).Length / 1MB, 1)
    Write-Host "Beside : $pgTarget ($pgMb MB)"
    Write-Host 'Ship LWCamDatabaseSetup.exe with the PostgreSQL installer. A PC with PostgreSQL already installed needs only the setup file.'
}
