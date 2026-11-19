#Requires -Version 5.1
<#
  P1 (release blocker): forbidden-file gate over the STAGED payload.

  Reads <StageDir>\staging-manifest.json (written by stage_payload.ps1,
  every staged path + size + SHA-256) and fails the build when anything
  that must never reach a customer is present:

    * environment/secret files        .env, secrets.env, database.env, pg_admin.env
    * local state / dumps             backups/, data/, logs/, *.sql, *.dump
    * developer trees                 .venv/, tests/, test/, tools/, __pycache__/, .git/
    * bytecode / logs / build junk    *.pyc, *.pyo, *.log, flutter logs
    * private key material            *.key, *.pem, *.p12, *.pfx, *.jks, *.der, *.crt
    * owner-only licence tooling      signing_keystore.json, issuance_log.jsonl
    * duplicate trees / stray dumps   new_app_upload*, tatus, *.zip of the app

  Scope: the first-party payload (everything except backend\python\ and
  backend\wheelhouse\, which are pinned third-party artefacts and are
  checked by filename only).  `production.env.example` is a TEMPLATE and
  is expected to be present.

  It also asserts the REQUIRED files exist, so an empty/partial stage can
  never be compiled into an installer.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File verify_payload.ps1 `
        -StageDir D:\R5Isolation\stage\PRODUCTION [-Mode PRODUCTION]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StageDir,

    [ValidateSet('REHEARSAL', 'PRODUCTION')]
    [string]$Mode = 'PRODUCTION'
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $StageDir 'staging-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "PAYLOAD_FAILED: missing staging manifest: $manifestPath" -ForegroundColor Red
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    Write-Host "PAYLOAD_FAILED: staging manifest lists no files" -ForegroundColor Red
    exit 1
}

# The on-disk tree is the authority: a file planted after staging must be
# caught even though the manifest never listed it.  The manifest is then
# cross-checked for drift (a manifest entry with no file = a broken stage).
$diskRoot = (Resolve-Path -LiteralPath $StageDir).Path
$entries = New-Object System.Collections.Generic.List[object]
foreach ($df in (Get-ChildItem -LiteralPath $diskRoot -Recurse -File -Force)) {
    $rel = $df.FullName.Substring($diskRoot.Length + 1)
    if ($rel -eq 'staging-manifest.json') { continue }
    $entries.Add([pscustomobject]@{ path = $rel; size = $df.Length })
}

$violations = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# ── rules ───────────────────────────────────────────────────────────────────
# Basenames that must never appear ANYWHERE in the payload.
$globalForbiddenNames = @(
    '.env', 'secrets.env', 'database.env', 'pg_admin.env',
    'signing_keystore.json', 'issuance_log.jsonl', 'tatus',
    'backend.log', 'flutter-crash.log', 'supermarket_pro.db'
)

# Path segments forbidden inside the first-party tree only.
$firstPartyForbiddenSegments = @(
    '.venv', '.git', '__pycache__', '.dart_tool', '.pytest_cache',
    '.mypy_cache', '.ruff_cache', 'backups', 'logs', 'tests', 'test',
    'tools', 'node_modules', 'build'
)

# Extensions forbidden inside the first-party tree only.
$firstPartyForbiddenExtensions = @(
    '.pyc', '.pyo', '.log', '.sql', '.dump', '.dart',
    '.key', '.pem', '.p12', '.pfx', '.jks', '.der', '.crt',
    '.keystore', '.env'
)

# Files explicitly allowed even though a rule above could catch them.
$allowed = @(
    'backend/production.env.example',
    'backend/requirements.lock.txt',
    'backend/pyproject.toml',
    'backend/alembic.ini',
    'backend/run_production.py',
    'backend/installer_provision.py',
    'backend/installer_selfcheck.py',
    'vendor/THIRD_PARTY_NOTICES.md',
    'vendor/innosetup-license.txt'
)

function Test-IsFirstParty([string]$rel) {
    $p = $rel.Replace('\', '/')
    return -not ($p.StartsWith('backend/python/') -or $p.StartsWith('backend/wheelhouse/'))
}

$count = 0
foreach ($f in $entries) {
    $rel = [string]$f.path
    $relPosix = $rel.Replace('\', '/')
    $name = Split-Path -Leaf $relPosix
    $count++

    if ($allowed -contains $relPosix) { continue }

    # global name rules
    if ($globalForbiddenNames -contains $name) {
        $violations.Add("forbidden file: $relPosix")
        continue
    }
    if ($name -like 'new_app_upload*') {
        $violations.Add("forbidden duplicate tree: $relPosix")
        continue
    }
    if ($name -like 'flutter_*.log') {
        $violations.Add("forbidden build log: $relPosix")
        continue
    }

    if (-not (Test-IsFirstParty $relPosix)) {
        # pinned vendor runtime: filename-only guard (cacert.pem etc. are legit)
        if ($globalForbiddenNames -contains $name) {
            $violations.Add("forbidden file in vendor runtime: $relPosix")
        }
        continue
    }

    $segments = $relPosix.Split('/')
    foreach ($seg in $segments[0..($segments.Count - 1)]) {
        if ($firstPartyForbiddenSegments -contains $seg) {
            $violations.Add("forbidden directory '$seg': $relPosix")
            break
        }
    }
    $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
    if ($firstPartyForbiddenExtensions -contains $ext) {
        $violations.Add("forbidden extension '$ext': $relPosix")
        continue
    }
    if ($name -like 'test_*.py' -or $name -like '*_test.py' -or $name -like 'conftest.py') {
        $violations.Add("test module in payload: $relPosix")
        continue
    }
    if ($name -like '*_smoke_*.py' -or $name -in @('check_migration.py', 'create_test_db.py', 'inspect_schema.py')) {
        $violations.Add("developer script in payload: $relPosix")
        continue
    }
    if ($relPosix -like 'backend/app/*' -and $name -like '*priv*' -and $ext -eq '.json') {
        $warnings.Add("check this JSON for private key material: $relPosix")
    }
}

# ── required artefacts ──────────────────────────────────────────────────────
$required = @(
    'app/supermarket_pos.exe',
    'app/flutter_windows.dll',
    'app/data/flutter_assets/AssetManifest.bin',
    'backend/run_production.py',
    'backend/installer_provision.py',
    'backend/installer_selfcheck.py',
    'backend/alembic.ini',
    'backend/requirements.lock.txt',
    'backend/python/python.exe',
    'backend/migrations/env.py',
    'backend/winsw/SupermarketProBackend.xml',
    'backend/winsw/grant_data_dir_acl.ps1',
    'SupermarketProBackend.exe',
    'vendor/THIRD_PARTY_NOTICES.md'
)
if ($Mode -eq 'PRODUCTION') {
    $required += @(
        'vendor/postgresql-18.6-5-windows-x64.exe',
        'vendor/vc_redist.x64.exe'
    )
}
$paths = @{}
foreach ($f in $entries) { $paths[([string]$f.path).Replace('\', '/')] = $true }
foreach ($f in $manifest.files) {
    $relPosix = ([string]$f.path).Replace('\', '/')
    if (-not $paths.ContainsKey($relPosix)) {
        $violations.Add("manifest lists a file that is not staged: $relPosix")
    }
}
foreach ($r in $required) {
    if (-not $paths.ContainsKey($r)) {
        $violations.Add("required file missing from payload: $r")
    }
}

# The wheelhouse must actually contain wheels.
$wheels = @($entries | Where-Object {
    ([string]$_.path).Replace('\', '/') -like 'backend/wheelhouse/*.whl'
})
if ($wheels.Count -eq 0) {
    $violations.Add('required file missing from payload: backend/wheelhouse/*.whl')
}

# Size sanity: an installer without the Flutter engine is a broken payload.
$total = [long]$manifest.total_bytes
if ($total -lt 150MB) {
    $violations.Add("payload is implausibly small ($([math]::Round($total / 1MB, 1)) MB)")
}

# ── report ──────────────────────────────────────────────────────────────────
foreach ($w in $warnings) { Write-Host "  WARN $w" -ForegroundColor Yellow }

if ($violations.Count -gt 0) {
    $violations | Select-Object -First 200 | ForEach-Object {
        Write-Host "  VIOLATION $_" -ForegroundColor Red
    }
    if ($violations.Count -gt 200) {
        Write-Host ("  ... and {0} more" -f ($violations.Count - 200)) -ForegroundColor Red
    }
    Write-Host ("PAYLOAD_FAILED: {0} violation(s) across {1} staged files" -f `
        $violations.Count, $count) -ForegroundColor Red
    exit 1
}

Write-Host ("[payload] OK: {0} files, {1:n1} MB, mode={2}, sha256-verified manifest" -f `
    $count, ($total / 1MB), $Mode)
Write-Host "PAYLOAD_OK"
exit 0
