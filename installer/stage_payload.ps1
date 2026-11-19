#Requires -Version 5.1
<#
  R5 payload staging (contract: installer staging honours customer_package.json).

  Assembles the installable payload into a clean staging directory:

    <out>\SupermarketProBackend.exe     renamed WinSW wrapper (pinned SHA-256)
    <out>\app\                          Flutter Release folder, as-is
    <out>\backend\                      first-party backend per customer_package.json
      python\                           official CPython runtime (Doc/include/libs/test stripped)
      wheelhouse\                       offline wheels (requirements.lock.txt)
      run_production.py alembic.ini pyproject.toml production.env.example
      requirements.lock.txt app\ migrations\ winsw\
    <out>\vendor\                       THIRD_PARTY_NOTICES.md, INSTALL_NOTES.txt,
                                        innosetup-license.txt,
                                        PostgreSQL licences extracted from the binaries zip,
                                        the verified PG binaries zip (+ installer exe in PRODUCTION)
    <out>\staging-manifest.json         per-file size + SHA-256 evidence manifest

  Verification (any failure throws, non-zero exit):
    1. vendor artefacts match their pinned SHA-256 before being copied;
    2. customer_package.json include/exclude/forbidden rules over the first-party
       backend tree (python\ and wheelhouse\ are pinned vendor artefacts and are
       scanned only for forbidden FILENAMES, never content);
    3. offline install smoke: a venv is created from the STAGED runtime and the
       STAGED wheelhouse installs requirements.lock.txt with --no-index;
    4. every staged file is hashed into staging-manifest.json.

  The Flutter `../lib` source root of customer_package.json is intentionally NOT
  staged: the installer ships the compiled Release folder (design §4 step 5);
  `must_include` dart entries are verified against the repo sources instead.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsolationRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('REHEARSAL', 'PRODUCTION')]
    [string]$Mode,

    [string]$RepoRoot = '',
    [string]$OutDir = '',
    [string]$InnoLicenseFile = ''
)

if (-not $RepoRoot) {
    # this script lives in <repo>\installer\ → repo root is one level up
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ── pinned vendor artefacts (verified in design §1; re-verified here) ────────
$PINS = @{
    'WinSW-x64-v2.12.0.exe' =
        '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA'
    'postgresql-18.6-5-windows-x64-binaries.zip' =
        'E2246BA91D22345BC3D017586C09EDE52D9DF180B1EEB480F050445F1CAD84E2'
    'postgresql-18.6-5-windows-x64.exe' =
        '227E2BC08091B4C2B8338C7D61B11D057F895711480B006F90BFCFCD2410A58A'
    # R6 (contract 7): official Microsoft VC++ 2015-2022 x64 redistributable,
    # downloaded from https://aka.ms/vs/17/release/vc_redist.x64.exe,
    # Authenticode = Valid / CN=Microsoft Corporation, FileVersion 14.44.35211.0.
    'vc_redist.x64.exe' =
        'CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B'
}

$BACKEND      = Join-Path $RepoRoot 'new_app\backend'
$FLUTTER_LIB  = Join-Path $RepoRoot 'new_app\lib'
$FLUTTER_REL  = Join-Path $RepoRoot 'new_app\build\windows\x64\runner\Release'
$PYTHON_RT    = Join-Path $IsolationRoot 'tools\py313'
$WHEELHOUSE   = Join-Path $IsolationRoot 'runtime\wheelhouse'
$VENDOR_DIR   = Join-Path $IsolationRoot 'vendor'
$NOTICES_SRC  = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'THIRD_PARTY_NOTICES.md'
# P10: pre-install information page (receipt printer driver + ports + data paths).
$InstallNotesSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'INSTALL_NOTES.txt'
$MANIFEST_SRC = Join-Path $BACKEND 'customer_package.json'
$LOCK_SRC     = Join-Path $BACKEND 'requirements.lock.txt'

if (-not $OutDir)    { $OutDir = Join-Path $IsolationRoot "stage\$Mode" }
if (-not $InnoLicenseFile) { $InnoLicenseFile = Join-Path $IsolationRoot 'tools\innosetup-7\license.txt' }

function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '')
    } finally { $fs.Close() }
}

function Test-FilePin([string]$Path, [string]$Pin) {
    $actual = Get-FileSha256 $Path
    if ($actual -ne $Pin) {
        throw "SHA-256 PIN MISMATCH for $Path`n  expected $Pin`n  actual   $actual"
    }
    return $actual
}

function Copy-Tree([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src)) { throw "missing source: $Src" }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    & robocopy $Src $Dst /E /R:1 /W:1 /XD '__pycache__' /XF '*.pyc' '*.pyo' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $Src -> $Dst" }
}

function Copy-One([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src)) { throw "missing source: $Src" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dst) | Out-Null
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

# ── 1. preflight ────────────────────────────────────────────────────────────
Write-Host "[stage] mode=$Mode out=$OutDir"
$required = @(
    $MANIFEST_SRC, $LOCK_SRC, $NOTICES_SRC, $InnoLicenseFile, $InstallNotesSrc,
    (Join-Path $BACKEND 'run_production.py'),
    (Join-Path $BACKEND 'app'),
    (Join-Path $BACKEND 'migrations'),
    (Join-Path $BACKEND 'winsw\SupermarketProBackend.xml'),
    (Join-Path $BACKEND 'alembic.ini'),
    (Join-Path $BACKEND 'pyproject.toml'),
    (Join-Path $BACKEND 'production.env.example'),
    (Join-Path $FLUTTER_REL 'supermarket_pos.exe'),
    (Join-Path $PYTHON_RT 'python.exe'),
    (Join-Path $PYTHON_RT 'LICENSE.txt'),
    (Join-Path $PYTHON_RT 'Lib\venv'),
    (Join-Path $PYTHON_RT 'Lib\site-packages\pip'),
    (Join-Path $PYTHON_RT 'Lib\ensurepip'),
    $WHEELHOUSE,
    (Join-Path $VENDOR_DIR 'WinSW-x64-v2.12.0.exe'),
    (Join-Path $VENDOR_DIR 'postgresql-18.6-5-windows-x64-binaries.zip'),
    $FLUTTER_LIB
)
foreach ($p in $required) {
    if (-not (Test-Path -LiteralPath $p)) { throw "preflight: missing $p" }
}
if ($Mode -eq 'PRODUCTION') {
    $pgExe = Join-Path $VENDOR_DIR 'postgresql-18.6-5-windows-x64.exe'
    if (-not (Test-Path -LiteralPath $pgExe)) { throw "preflight: missing $pgExe" }
    $vcRedist = Join-Path $VENDOR_DIR 'vc_redist.x64.exe'
    if (-not (Test-Path -LiteralPath $vcRedist)) { throw "preflight: missing $vcRedist" }
}

Write-Host '[stage] verifying vendor SHA-256 pins...'
$pinResults = @{}
$pinResults['WinSW-x64-v2.12.0.exe'] = Test-FilePin `
    (Join-Path $VENDOR_DIR 'WinSW-x64-v2.12.0.exe') $PINS['WinSW-x64-v2.12.0.exe']
$pinResults['postgresql-18.6-5-windows-x64-binaries.zip'] = Test-FilePin `
    (Join-Path $VENDOR_DIR 'postgresql-18.6-5-windows-x64-binaries.zip') $PINS['postgresql-18.6-5-windows-x64-binaries.zip']
if ($Mode -eq 'PRODUCTION') {
    $pinResults['postgresql-18.6-5-windows-x64.exe'] = Test-FilePin `
        (Join-Path $VENDOR_DIR 'postgresql-18.6-5-windows-x64.exe') $PINS['postgresql-18.6-5-windows-x64.exe']
    $pinResults['vc_redist.x64.exe'] = Test-FilePin `
        (Join-Path $VENDOR_DIR 'vc_redist.x64.exe') $PINS['vc_redist.x64.exe']
}

# ── 2. clean output ─────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stageBackend = Join-Path $OutDir 'backend'
$stageVendor  = Join-Path $OutDir 'vendor'

# ── 3. copy ─────────────────────────────────────────────────────────────────
Write-Host '[stage] copying backend (customer_package.json rules)...'
Copy-Tree (Join-Path $BACKEND 'app') (Join-Path $stageBackend 'app')
foreach ($d in @('migrations', 'winsw')) {
    Copy-Tree (Join-Path $BACKEND $d) (Join-Path $stageBackend $d)
}
foreach ($f in @('pyproject.toml', 'run_production.py', 'production.env.example',
                 'alembic.ini', 'requirements.lock.txt')) {
    Copy-One (Join-Path $BACKEND $f) (Join-Path $stageBackend $f)
}
# installer-only provisioning driver (never imported by the application;
# production never passes --rehearse-instance — contract 14)
Copy-One (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'installer_provision.py') `
    (Join-Path $stageBackend 'installer_provision.py')
# installer-only self-check (ACLs before the service starts, health after)
Copy-One (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'installer_selfcheck.py') `
    (Join-Path $stageBackend 'installer_selfcheck.py')

Write-Host '[stage] copying Flutter Release folder...'
Copy-Tree $FLUTTER_REL (Join-Path $OutDir 'app')

Write-Host '[stage] copying CPython runtime (stripping Doc/include/libs/test)...'
Copy-Tree $PYTHON_RT (Join-Path $stageBackend 'python')
foreach ($strip in @('Doc', 'include', 'libs', (Join-Path 'Lib' 'test'))) {
    $p = Join-Path (Join-Path $stageBackend 'python') $strip
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}

Write-Host '[stage] copying offline wheelhouse...'
Copy-Tree $WHEELHOUSE (Join-Path $stageBackend 'wheelhouse')

Write-Host '[stage] staging WinSW wrapper + notices + PostgreSQL payloads...'
Copy-One (Join-Path $VENDOR_DIR 'WinSW-x64-v2.12.0.exe') (Join-Path $OutDir 'SupermarketProBackend.exe')
Copy-One $NOTICES_SRC (Join-Path $stageVendor 'THIRD_PARTY_NOTICES.md')
Copy-One $InnoLicenseFile (Join-Path $stageVendor 'innosetup-license.txt')
$pgZipName = 'postgresql-18.6-5-windows-x64-binaries.zip'
# NOTE (size): the 385 MB binaries zip is a BUILD-TIME licence source only —
# the installer never reads it (setup.iss installs the EDB .exe instead).
# Shipping it added ~385 MB to every SupermarketPro-Setup.exe, so it is
# extracted here and deliberately NOT copied into the staged payload.
Copy-One $InstallNotesSrc (Join-Path $stageVendor 'INSTALL_NOTES.txt')
if ($Mode -eq 'PRODUCTION') {
    Copy-One (Join-Path $VENDOR_DIR 'postgresql-18.6-5-windows-x64.exe') `
        (Join-Path $stageVendor 'postgresql-18.6-5-windows-x64.exe')
    # R6 contract 7: official Microsoft VC++ redistributable (pinned above);
    # setup.iss runs it silently on the target before service registration.
    Copy-One (Join-Path $VENDOR_DIR 'vc_redist.x64.exe') `
        (Join-Path $stageVendor 'vc_redist.x64.exe')
}

# extract the licence texts EDB bundles inside the binaries zip
Add-Type -AssemblyName System.IO.Compression.FileSystem
$licOut = Join-Path $stageVendor 'postgres-licences'
New-Item -ItemType Directory -Force -Path $licOut | Out-Null
$wantLic = @(
    'pgsql/server_license.txt',
    'pgsql/pgAdmin_license.txt',
    'pgsql/commandlinetools_3rd_party_licenses.txt',
    'pgsql/pgAdmin_3rd_party_licenses.txt',
    'pgsql/StackBuilder_3rd_party_licenses.txt'
)
$zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $VENDOR_DIR $pgZipName))
try {
    foreach ($entryName in $wantLic) {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryName } | Select-Object -First 1
        if (-not $entry) { throw "PG zip is missing $entryName" }
        $target = Join-Path $licOut (Split-Path -Leaf $entryName)
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    }
} finally { $zip.Dispose() }

# ── 4. customer_package.json boundary verification on the staged tree ───────
Write-Host '[stage] verifying customer_package.json boundary...'
$manifest = Get-Content -LiteralPath $MANIFEST_SRC -Raw -Encoding UTF8 | ConvertFrom-Json

function Test-Excluded([string]$Rel, [string[]]$Patterns) {
    $name = Split-Path -Leaf $Rel
    foreach ($pattern in $Patterns) {
        if ($pattern.EndsWith('/')) {
            if ($Rel.Replace('\', '/').StartsWith($pattern)) { return $true }
        } elseif ($name -eq $pattern -or ($name -like $pattern)) { return $true }
    }
    return $false
}

$violations = @()
# first-party backend tree: everything under stage\backend except python\ + wheelhouse\
$firstParty = Get-ChildItem -LiteralPath $stageBackend -Recurse -File -Force |
    Where-Object {
        $rel = $_.FullName.Substring($stageBackend.Length + 1)
        -not ($rel.StartsWith('python\') -or $rel.StartsWith('wheelhouse\'))
    }
foreach ($file in $firstParty) {
    $rel = $file.FullName.Substring($stageBackend.Length + 1)
    $relPosix = $rel.Replace('\', '/')
    if ($relPosix -in @('pyproject.toml', 'run_production.py', 'production.env.example',
                        'alembic.ini', 'requirements.lock.txt',
                        'installer_provision.py', 'installer_selfcheck.py')) { continue }
    if (Test-Excluded $relPosix $manifest.must_exclude) {
        $violations += "must_exclude: backend/$relPosix"
    }
    if ($file.Name -in $manifest.forbidden_filenames) {
        $violations += "forbidden_filename: backend/$relPosix"
    }
    if ($file.Extension.ToLower() -in $manifest.forbidden_extensions) {
        $violations += "forbidden_extension: backend/$relPosix"
    }
    if ($file.Length -le 5MB) {
        try { $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) }
        catch { continue }
        foreach ($marker in $manifest.forbidden_content) {
            if ($text.Contains($marker)) {
                $violations += "forbidden_content '$marker': backend/$relPosix"
            }
        }
    }
}
# vendor runtime / wheelhouse: filename-only scan (pinned vendor artefacts)
$vendorNames = Get-ChildItem -LiteralPath $stageBackend -Recurse -File -Force |
    Where-Object {
        $rel = $_.FullName.Substring($stageBackend.Length + 1)
        $rel.StartsWith('python\') -or $rel.StartsWith('wheelhouse\')
    }
foreach ($file in $vendorNames) {
    if ($file.Name -in $manifest.forbidden_filenames) {
        $violations += "forbidden_filename: backend/$($file.FullName.Substring($stageBackend.Length + 1))"
    }
}
# whole tree: no .env anywhere
$envFiles = Get-ChildItem -LiteralPath $OutDir -Recurse -File -Force -Filter '.env'
foreach ($e in $envFiles) { $violations += ".env present: $($e.FullName)" }

# must_include: backend entries against the stage, ../lib entries against repo sources
foreach ($entry in $manifest.must_include) {
    if ($entry.StartsWith('../')) {
        $src = Join-Path $BACKEND ($entry -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { $violations += "must_include missing in repo: $entry" }
    } else {
        $staged = Join-Path $stageBackend ($entry -replace '/', '\')
        if (-not (Test-Path -LiteralPath $staged)) { $violations += "must_include missing in stage: $entry" }
    }
}
if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Host "  VIOLATION $_" -ForegroundColor Red }
    throw "customer_package boundary: $($violations.Count) violation(s)"
}
Write-Host ("[stage] boundary OK ({0} first-party files scanned)" -f $firstParty.Count)

# ── 5. offline install smoke from the STAGED artefacts ─────────────────────
Write-Host '[stage] offline install smoke (staged runtime + staged wheelhouse)...'
$smokeVenv = Join-Path $env:TEMP "r5-stage-smoke-$Mode"
if (Test-Path -LiteralPath $smokeVenv) { Remove-Item -LiteralPath $smokeVenv -Recurse -Force }
try {
    & (Join-Path $stageBackend 'python\python.exe') -m venv $smokeVenv
    if ($LASTEXITCODE -ne 0) { throw "venv creation failed ($LASTEXITCODE)" }
    & (Join-Path $smokeVenv 'Scripts\python.exe') -m pip install --quiet --disable-pip-version-check `
        --no-index --find-links (Join-Path $stageBackend 'wheelhouse') `
        -r (Join-Path $stageBackend 'requirements.lock.txt')
    if ($LASTEXITCODE -ne 0) { throw "offline pip install failed ($LASTEXITCODE)" }
    & (Join-Path $smokeVenv 'Scripts\python.exe') -c 'import fastapi, sqlalchemy, uvicorn, psycopg2, dotenv, cryptography'
    if ($LASTEXITCODE -ne 0) { throw "smoke import failed ($LASTEXITCODE)" }
} finally {
    if (Test-Path -LiteralPath $smokeVenv) { Remove-Item -LiteralPath $smokeVenv -Recurse -Force }
}
Write-Host '[stage] offline install smoke OK'

# ── 6. evidence manifest (size + SHA-256 per file) ──────────────────────────
Write-Host '[stage] hashing staged files into staging-manifest.json...'
$sha = [System.Security.Cryptography.SHA256]::Create()
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('{')
[void]$sb.AppendLine(('  "format": "supermarket-pro/staging-manifest",'))
[void]$sb.AppendLine(('  "version": 1,'))
[void]$sb.AppendLine(('  "mode": "{0}",' -f $Mode))
[void]$sb.AppendLine(('  "generated_utc": "{0}",' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
[void]$sb.AppendLine(('  "repo_root": "{0}",' -f ($RepoRoot -replace '\\', '\\')))
[void]$sb.AppendLine(('  "vendor_pins": {'))
$first = $true
foreach ($k in $pinResults.Keys) {
    $comma = if ($first) { '' } else { ',' }
    $first = $false
    [void]$sb.AppendLine(('    {0}"{1}": "{2}"' -f $comma, $k, $pinResults[$k]))
}
[void]$sb.AppendLine('  },')
[void]$sb.Append(('  "files": ['))
$all = Get-ChildItem -LiteralPath $OutDir -Recurse -File -Force |
    Where-Object { $_.FullName -ne (Join-Path $OutDir 'staging-manifest.json') } |
    Sort-Object FullName
$totalBytes = [long]0
$idx = 0
foreach ($f in $all) {
    $fs = [System.IO.File]::OpenRead($f.FullName)
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') }
    finally { $fs.Close() }
    $totalBytes += $f.Length
    $rel = $f.FullName.Substring($OutDir.Length + 1).Replace('\', '\\')
    $sep = if ($idx -lt $all.Count - 1) { ',' } else { '' }
    [void]$sb.Append(('{{"path": "{0}", "size": {1}, "sha256": "{2}"}}{3}' -f $rel, $f.Length, $hash, $sep))
    $idx++
    if ($idx % 2000 -eq 0) { Write-Host "  ... $idx files" }
}
[void]$sb.AppendLine('],')
[void]$sb.AppendLine(('  "file_count": {0},' -f $all.Count))
[void]$sb.AppendLine(('  "total_bytes": {0}' -f $totalBytes))
[void]$sb.AppendLine('}')
$manifestPath = Join-Path $OutDir 'staging-manifest.json'
[System.IO.File]::WriteAllText($manifestPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ── 7. summary ──────────────────────────────────────────────────────────────
Write-Host ('[stage] DONE in {0:n1}s' -f $sw.Elapsed.TotalSeconds)
Write-Host ("[stage] files={0} total={1:n1} MB manifest={2}" -f `
    $all.Count, ($totalBytes / 1MB), $manifestPath)
Write-Host "STAGING_OK"
exit 0
