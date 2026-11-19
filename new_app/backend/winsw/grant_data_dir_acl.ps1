<#
.SYNOPSIS
  Least-privilege ACLs for the Supermarket Pro data root (R2/R5).

.DESCRIPTION
  Grants exactly two things and nothing else:

    1. Modify on the writable data root — C:\ProgramData\SupermarketPro by
       default — for the service account, with SYSTEM and
       BUILTIN\Administrators at Full control so an admin can back up,
       repair or uninstall.

    2. ReadAndExecute (OI)(CI) on the installation tree for the same
       account — the minimum needed to import the code.  Write/Modify is
       NEVER granted there: the backend runs without write access to
       Program Files (docs/R1_DATA_PATHS.md §4).

  R5 hardening (sandbox evidence, 2026-11-14)
  -------------------------------------------
  The previous version ran `icacls <data root> … /T` and then
  `icacls <data root> /inheritance:r /T`.  That single recursive pass:

    * stripped inheritance from EVERY object under the data root, including
      `postgres\data`, whose ACL belongs to PostgreSQL — it broke
      `postgresql.conf` access and stopped the service;
    * left `config\.env`, `config\secrets.env` and `config\database.env`
      with a protected DACL that granted nothing, so the NetworkService
      backend crash-looped on PermissionError.

  Therefore: NO recursion (`/T`) over the data root, ever, and NO
  inheritance strip.  This script only touches the directories it names,
  one at a time, and skips `postgres` entirely.

  The per-file ACLs of the credential files (`config\.env`,
  `secrets.env`, `database.env`, `pg_admin.env`) and of `logs\` are set by
  `app.core.acl` (run through `installer_selfcheck.py --phase
  pre-service`), because they need a different DACL per file.

  Locale safety: every well-known principal is granted by SID
  (`icacls /grant *S-1-5-…`), never by name — on French Windows a name
  lookup fails with icacls exit 1332.

  The script refuses to run when the data root is inside Program Files.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File grant_data_dir_acl.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File grant_data_dir_acl.ps1 `
      -Account 'NT AUTHORITY\LocalService' `
      -DataDir 'D:\SupermarketPro\data'
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $env:ProgramData 'SupermarketPro'),
    [string]$InstallDir = (Join-Path ${env:ProgramFiles} 'Supermarket Pro'),
    [string]$Account = 'NT AUTHORITY\NetworkService'
)

$ErrorActionPreference = 'Stop'

# Well-known SIDs (locale-proof; icacls accepts the "*S-1-…" form on any
# Windows language — English group NAMES do not resolve everywhere).
$SID_SYSTEM = '*S-1-5-18'
$SID_ADMINISTRATORS = '*S-1-5-32-544'
$SID_NETWORK_SERVICE = '*S-1-5-20'
$SID_LOCAL_SERVICE = '*S-1-5-19'

#: Directories this script configures, relative to the data root.  An
#: ACL is applied to each one individually; nothing below them is touched.
$DataSubdirs = @('config', 'license', 'data', 'backups', 'logs', 'installers')

#: Never touched: PostgreSQL owns these ACLs (initdb / pg_ctl set them).
$SkippedSubdirs = @('postgres')

function Resolve-AccountSid {
    param([string]$Name)
    if ($Name -match '^S-1-\d+(-\d+)+$') { return "*$Name" }
    switch ($Name) {
        'NT AUTHORITY\SYSTEM' { return $SID_SYSTEM }
        'BUILTIN\Administrators' { return $SID_ADMINISTRATORS }
        'NT AUTHORITY\NetworkService' { return $SID_NETWORK_SERVICE }
        'NT AUTHORITY\LocalService' { return $SID_LOCAL_SERVICE }
    }
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Name)).Translate(
            [System.Security.Principal.SecurityIdentifier])
        return "*$($sid.Value)"
    }
    catch {
        throw "Cannot resolve account '$Name' to a SID on this system: $($_.Exception.Message)"
    }
}

$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$resolvedData = [System.IO.Path]::GetFullPath($DataDir)

if ($resolvedData.StartsWith($programFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to configure '$resolvedData': the data root must live OUTSIDE the installation tree (Program Files)."
}

function Invoke-Icacls {
    param([string[]]$Arguments)
    & icacls @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$accountSid = Resolve-AccountSid -Name $Account

if (-not (Test-Path -LiteralPath $resolvedData)) {
    New-Item -ItemType Directory -Path $resolvedData -Force | Out-Null
}

Write-Host "Protecting data root : $resolvedData (per directory, never recursive)"
Write-Host "Service account      : $Account ($($accountSid.TrimStart('*')))"
Write-Host "Skipped (PostgreSQL) : $($SkippedSubdirs -join ', ')"

# The data root itself and each known sub-directory, one icacls call each:
# no /T and no /inheritance:r anywhere, so PostgreSQL's own ACLs and any
# file created later keep a working, inheritable DACL.
Invoke-Icacls @($resolvedData, '/grant', "${SID_SYSTEM}:(OI)(CI)F")
Invoke-Icacls @($resolvedData, '/grant', "${SID_ADMINISTRATORS}:(OI)(CI)F")
Invoke-Icacls @($resolvedData, '/grant', "${accountSid}:(OI)(CI)M")

foreach ($name in $SkippedSubdirs) {
    $skipped = Join-Path $resolvedData $name
    if (Test-Path -LiteralPath $skipped) {
        Write-Host "Leaving '$skipped' untouched: PostgreSQL sets and needs its own ACLs."
    }
}

foreach ($name in $DataSubdirs) {
    $dir = Join-Path $resolvedData $name
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Invoke-Icacls @($dir, '/grant', "${SID_SYSTEM}:(OI)(CI)F")
    Invoke-Icacls @($dir, '/grant', "${SID_ADMINISTRATORS}:(OI)(CI)F")
    Invoke-Icacls @($dir, '/grant', "${accountSid}:(OI)(CI)M")
}

# Installation tree: read + execute only, never write.  This one IS
# recursive — it is the install tree, not the data root, and no
# PostgreSQL or per-install secrets live there.
if ($InstallDir -and (Test-Path -LiteralPath $InstallDir)) {
    Write-Host "Read+execute on      : $InstallDir (no write permission is granted)"
    Invoke-Icacls @($InstallDir, '/grant', "${accountSid}:(OI)(CI)RX", '/T', '/C')
}
elseif ($InstallDir) {
    Write-Host "Install dir '$InstallDir' not present yet - skipping the read grant."
}

Write-Host 'Done. Per-file credential ACLs are applied by installer_selfcheck.py'
Write-Host '      (python -m app.core.acl --data-dir "<data dir>").'
