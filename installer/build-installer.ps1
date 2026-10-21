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

    [switch] $ResolveOnly,

    # Rewrite installer\SHA256SUMS.txt from the bundled files on disk (all targets) and exit.
    [switch] $UpdateChecksums
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
$targets = if ($Target -eq 'All' -or $UpdateChecksums) { @('LWCam', 'QC', 'LWIP', 'Upload', 'Database') } else { @($Target) }
# Consumer code is bundled locally; never load it from a peer installation.
# Use .NET: PowerShell 5.1 may inherit a PS7 module path without Get-FileHash.
function Calibration-Hash([string] $Path) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path))) }
    finally { $algorithm.Dispose() }
}
foreach ($name in @('__init__.py', 'apply.py', 'profile.py', 'reference_data.py', 'contract.py')) {
    $canonical = Join-Path $repoRoot "LWIP\backend\color_cal_tool\$name"
    $expected = Calibration-Hash $canonical
    foreach ($consumer in @('LWCam_QC_Platform')) {
        $copy = Join-Path $repoRoot "$consumer\backend\color_cal_tool\$name"
        if ((Calibration-Hash $copy) -ne $expected) {
            throw "Calibration consumer differs: $copy"
        }
    }
}
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

# lwcam_secrets.py (DPAPI for the passwords in each config file) ships inside every
# server module and with the Database installer. The copies must be byte-identical.
$secretsCopy = @{
    QC       = 'LWCam_QC_Platform\backend\app\core\lwcam_secrets.py'
    LWIP     = 'LWIP\backend\deskew_crop_tool\lwcam_secrets.py'
    Upload   = 'LWCam_Upload\backend\lwcam_upload\lwcam_secrets.py'
    Database = 'installer\db\lwcam_secrets.py'
}
$secretsHash = @{}
foreach ($targetName in $targets) {
    if ($secretsCopy.ContainsKey($targetName)) {
        $copy = Join-Path $repoRoot $secretsCopy[$targetName]
        Require-File $copy "$targetName lwcam_secrets.py"
        $secretsHash[[Convert]::ToBase64String([System.IO.File]::ReadAllBytes($copy))] = $copy
    }
}
if ($secretsHash.Count -gt 1) {
    throw ('lwcam_secrets.py copies differ (they must be byte-identical): ' + ($secretsHash.Values -join '; '))
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

# Bundled third-party inputs (not built from our source) are pinned in
# SHA256SUMS.txt: "<sha256>  <path relative to repo root>", sorted, LF.
# Scopes per target = exactly what that target's .iss / this script consumes.
function Get-BundledInputs {
    param([string[]] $TargetNames)
    $vc = @{ Dir = 'installer/vendor/vcruntime' }
    $py = @{ Dir = 'installer/vendor'; Names = @('python-3.14.8-embed-amd64.zip') }
    $scopes = @()
    foreach ($t in $TargetNames) {
        switch ($t) {
            'LWCam'    { $scopes += $vc, @{ Dir = 'installer/vendor/adb' }, @{ Dir = 'LWCAM/scrcpy'; Abs = $scrcpy.FullName } }
            'QC'       { $scopes += $vc, $py, @{ Dir = 'LWCam_QC_Platform/backend/wheels' } }
            'LWIP'     { $scopes += $vc, $py, @{ Dir = 'LWIP/tools' }, @{ Dir = 'LWIP/wheels' } }
            'Upload'   { $scopes += $vc, $py, @{ Dir = 'LWCam_Upload/wheels' } }
            'Database' { $scopes += $vc, $py, @{ Dir = 'installer/vendor/postgresql'; Names = @('postgresql-18.*-windows-x64.exe') },
                                    @{ Dir = 'LWIP/wheels'; Names = @('pip-*.whl', 'psycopg-*.whl', 'psycopg_binary-*.whl', 'tzdata-*.whl', 'cryptography-*.whl', 'cffi-*.whl', 'pycparser-*.whl') } }
        }
    }
    $found = @{}   # key -> full path
    $seen = @{}
    foreach ($sc in $scopes) {
        if (-not $sc.ContainsKey('Names')) { $sc.Names = @('*') }
        if ($seen.ContainsKey($sc.Dir + '|' + ($sc.Names -join ','))) { continue }
        $seen[$sc.Dir + '|' + ($sc.Names -join ',')] = 1
        $abs = if ($sc.ContainsKey('Abs')) { $sc.Abs } else { Join-Path $repoRoot $sc.Dir }
        $names = $sc.Names
        # The python zip scope must not recurse into vendor's subfolders.
        $recurse = $sc.Dir -ne 'installer/vendor'
        if (Test-Path -LiteralPath $abs -PathType Container) {
            $files = Get-ChildItem -LiteralPath $abs -File -Recurse:$recurse |
                Where-Object { $n = $_.Name; @($names | Where-Object { $n -like $_ }).Count -gt 0 }
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($abs.TrimEnd([char]92).Length + 1).Replace([string][char]92, '/')
                $found[$sc.Dir + '/' + $rel] = $f.FullName
            }
        }
        $sc.Prefix = $sc.Dir + '/'
        $sc.Like = $names
    }
    [pscustomobject]@{ Found = $found; Scopes = $scopes }
}

function Get-Sha256Map {
    param([hashtable] $Found)
    $map = @{}
    # .NET directly, not Get-FileHash: Windows PowerShell 5.1 started with a
    # PowerShell 7 PSModulePath (e.g. from Git Bash) cannot autoload it.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($k in $Found.Keys) {
            $stream = [System.IO.File]::OpenRead($Found[$k])
            try { $map[$k] = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
            finally { $stream.Dispose() }
        }
    } finally { $sha.Dispose() }
    $map
}

$sumsFile = Join-Path $installerDir 'SHA256SUMS.txt'
if ($UpdateChecksums) {
    $map = Get-Sha256Map (Get-BundledInputs $targets).Found
    $keys = [string[]]$map.Keys
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $lines = @($keys | ForEach-Object { "$($map[$_])  $_" })
    [System.IO.File]::WriteAllText($sumsFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $sumsFile ($($lines.Count) files)."
    return
}

function Test-BundledChecksums {
    param([string[]] $TargetNames)
    if (-not (Test-Path -LiteralPath $sumsFile -PathType Leaf)) {
        Write-Host 'installer\SHA256SUMS.txt is missing. Run build-installer.ps1 -UpdateChecksums and commit it.'
        return $false
    }
    $listed = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($sumsFile)) {
        if ($line -match '^([0-9a-f]{64})  (.+)$') { $listed[$Matches[2]] = $Matches[1] }
    }
    $in = Get-BundledInputs $TargetNames
    $actual = Get-Sha256Map $in.Found
    $bad = New-Object System.Collections.Generic.List[string]
    $hint = 'If this change is intended, run build-installer.ps1 -UpdateChecksums and commit SHA256SUMS.txt.'
    foreach ($k in ($actual.Keys | Sort-Object)) {
        if (-not $listed.ContainsKey($k)) { $bad.Add("Bundled file is not in SHA256SUMS.txt: $k. $hint") }
        elseif ($listed[$k] -ne $actual[$k]) { $bad.Add("Bundled file changed: $k. $hint") }
    }
    foreach ($k in ($listed.Keys | Sort-Object)) {
        if ($actual.ContainsKey($k)) { continue }
        $inScope = $false
        foreach ($sc in $in.Scopes) {
            if ($k.StartsWith($sc.Prefix)) {
                $leaf = $k.Substring($sc.Prefix.Length)
                if ($sc.Dir -eq 'installer/vendor' -and $leaf.Contains('/')) { continue }
                if (@($sc.Like | Where-Object { ($leaf.Split('/')[-1]) -like $_ }).Count -gt 0) { $inScope = $true }
            }
        }
        if ($inScope) { $bad.Add("Bundled file is listed in SHA256SUMS.txt but missing: $k. $hint") }
    }
    foreach ($m in $bad) { Write-Host $m }
    return ($bad.Count -eq 0)
}

Write-Host "ISCC   : $($iscc.FullName)"
if ($scrcpy) { Write-Host "scrcpy : $($scrcpy.FullName)" }
Write-Host "Target : $Target"

if ($ResolveOnly) {
    Write-Host 'ResolveOnly: nothing built.'
    return
}

Write-Host 'Checking bundled files against SHA256SUMS.txt...'
if (-not (Test-BundledChecksums $targets)) {
    Write-Host 'Build stopped: bundled files do not match SHA256SUMS.txt.'
    exit 1
}
Write-Host 'Bundled files match SHA256SUMS.txt.'

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
    Require-File (Join-Path $installerDir 'vendor\python-3.14.8-embed-amd64.zip') 'Embeddable Python archive'
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
        # npm ci: exactly the versions in package-lock.json, not whatever is in a stale node_modules.
        if (Test-Path -LiteralPath (Join-Path $frontendDir 'package-lock.json')) {
            Write-Host 'Installing QC console packages (npm ci)...'
            & npm.cmd ci
            if ($LASTEXITCODE -ne 0) {
                throw "npm ci failed with exit code $LASTEXITCODE."
            }
        }
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
    # only the DB driver, pip and cryptography (the server TLS certificate),
    # not the image-processing libraries.
    foreach ($wheel in @('pip-*.whl', 'psycopg-*.whl', 'psycopg_binary-*.whl', 'tzdata-*.whl', 'cryptography-*.whl', 'cffi-*.whl', 'pycparser-*.whl')) {
        Require-Wheel (Join-Path $repoRoot 'LWIP\wheels') $wheel 'The LWIP wheelhouse'
    }
    Require-File (Join-Path $repoRoot 'LWCam_QC_Platform\scripts\setup_qc_db.py') 'QC database setup script'
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database') -Filter 'LWCam_database_unified_*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no unified schema SQL.'
    }
    if (-not (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'LWCam_QC_Platform\database\migrations') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'The QC database folder has no migrations.'
    }
    foreach ($name in @('SETUP_DB_RUNTIME.bat', 'SETUP_DATABASE.bat', 'BACKUP_DATABASE.bat', 'RESTORE_DATABASE.bat', 'backup_db.py')) {
        Require-File (Join-Path $installerDir "db\$name") "Database helper $name"
    }
}

# Suite version: root VERSION plus the commit. Every installer gets it as
# /DAppVer and /DBuildId, and ships it as {app}\VERSION.txt (vendor\ is ignored).
$appVer = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -TotalCount 1).Trim()
$buildId = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $buildId) { $buildId = 'dev' }
elseif (& git -C $repoRoot status --porcelain 2>$null) { $buildId = "$buildId-dirty" }  # uncommitted changes went into this build
[System.IO.File]::WriteAllText((Join-Path $installerDir 'vendor\VERSION.txt'), "$appVer+$buildId", [System.Text.Encoding]::ASCII)
Write-Host "Version: $appVer+$buildId"

foreach ($targetName in $targets) {
    $iss = Join-Path $installerDir $scriptByTarget[$targetName]
    $arguments = @("/DAppsDir=$repoRoot", "/DAppVer=$appVer", "/DBuildId=$buildId")
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
