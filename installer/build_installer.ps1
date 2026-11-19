#Requires -Version 5.1
<#
  Builds the Supermarket Pro Windows installer from an already staged
  payload (stage_payload.ps1).  Exactly one compile mode is selected per
  ISCC invocation via /DREHEARSAL or /DPRODUCTION - setup.iss refuses to
  compile when neither or both are defined.

  Evidence: every build appends one line to <IsoRoot>\build\build_evidence.log
  (timestamp, mode, command, exit code, duration, size, SHA-256) and keeps
  the full ISCC output in <IsoRoot>\build\build_<MODE>.log.

  Authenticode (optional, never hard-coded):
    when SUPERMARKET_SIGN_PFX (or SIGN_PFX) is set, the compiled installer is
    signed with signtool before its SHA-256 is recorded:

      SUPERMARKET_SIGN_PFX        path to the .pfx   (required to sign)
      SUPERMARKET_SIGN_PFX_PASSWORD  its password   (optional)
      SUPERMARKET_SIGN_TIMESTAMP  RFC3161 URL (default http://timestamp.digicert.com)
      SUPERMARKET_SIGNTOOL        signtool.exe path (default: newest Windows Kits)

    With no certificate configured the build still succeeds and prints a
    clear SKIPPED warning - an unsigned installer is a delivery risk, not a
    build failure.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File build_installer.ps1 `
        -IsolationRoot D:\R5Isolation [-Mode All|Rehearsal|Production] [-SkipSign]

  Exit codes: 0 all requested modes compiled, 1 a mode failed, 2 setup error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsolationRoot,

    [ValidateSet('All', 'Rehearsal', 'Production')]
    [string]$Mode = 'All',

    [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'

$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) {
    Write-Error 'run this file with powershell -File (script path unknown)'
    exit 2
}
$installerDir = Split-Path -Parent $scriptPath
$setupIss = Join-Path $installerDir 'setup.iss'
if (-not (Test-Path -LiteralPath $setupIss)) {
    Write-Error "setup.iss not found: $setupIss"
    exit 2
}

$iscc = Join-Path $IsolationRoot 'tools\innosetup-7\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) {
    Write-Error "ISCC.exe not found: $iscc"
    exit 2
}

$outDir = Join-Path $IsolationRoot 'build'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$evidenceLog = Join-Path $outDir 'build_evidence.log'

$modes = if ($Mode -eq 'All') { @('Rehearsal', 'Production') } else { @($Mode) }
$failed = @()

# ── Authenticode (optional, configured only through the environment) ────────
function Get-SignToolPath {
    if ($env:SUPERMARKET_SIGNTOOL -and (Test-Path -LiteralPath $env:SUPERMARKET_SIGNTOOL)) {
        return $env:SUPERMARKET_SIGNTOOL
    }
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $roots) {
        $hit = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-AuthenticodeSign([string]$FilePath) {
    if ($SkipSign) {
        Write-Host '[sign] SKIPPED (-SkipSign)' -ForegroundColor Yellow
        return $false
    }
    $pfx = if ($env:SUPERMARKET_SIGN_PFX) { $env:SUPERMARKET_SIGN_PFX } else { $env:SIGN_PFX }
    if (-not $pfx) {
        Write-Host ('[sign] WARNING: no code-signing certificate configured ' +
            '(set SUPERMARKET_SIGN_PFX); the installer is UNSIGNED and ' +
            'Windows SmartScreen will warn the client') -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $pfx)) {
        Write-Host "[sign] WARNING: certificate not found: $pfx - continuing UNSIGNED" -ForegroundColor Yellow
        return $false
    }
    $signtool = Get-SignToolPath
    if (-not $signtool) {
        Write-Host '[sign] WARNING: signtool.exe not found - continuing UNSIGNED' -ForegroundColor Yellow
        return $false
    }
    $timestamp = if ($env:SUPERMARKET_SIGN_TIMESTAMP) { $env:SUPERMARKET_SIGN_TIMESTAMP } else { 'http://timestamp.digicert.com' }
    $argList = @('sign', '/fd', 'sha256', '/f', $pfx)
    if ($env:SUPERMARKET_SIGN_PFX_PASSWORD) {
        $argList += @('/p', $env:SUPERMARKET_SIGN_PFX_PASSWORD)
    }
    $argList += @('/tr', $timestamp, '/td', 'sha256', $FilePath)

    $shown = $argList -join ' '
    if ($env:SUPERMARKET_SIGN_PFX_PASSWORD) {
        $shown = $shown.Replace($env:SUPERMARKET_SIGN_PFX_PASSWORD, '***')
    }
    Write-Host "[sign] $signtool $shown"
    $out = & $signtool @argList 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "[sign] FAILED (exit $code)" -ForegroundColor Red
        Write-Host $out
        throw "signtool failed with exit $code"
    }
    Write-Host '[sign] signature applied'
    return $true
}


foreach ($m in $modes) {
    $tag = $m.ToUpperInvariant()
    $stage = Join-Path $IsolationRoot "stage\$tag"
    $manifest = Join-Path $stage 'staging-manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Error ("missing staging manifest for ${tag}: $manifest; " +
            "run stage_payload.ps1 -Mode $tag -IsolationRoot $IsolationRoot first")
        exit 2
    }

    $exeName = if ($m -eq 'Rehearsal') {
        'SupermarketPro-Setup-REHEARSAL.exe'
    } else {
        'SupermarketPro-Setup.exe'
    }
    $exe = Join-Path $outDir $exeName
    if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

    $modeDefine = '/D' + $tag
    $stageDefine = "/DSTAGE_DIR=$stage"
    $outDefine = "/O$outDir"
    $cmdLine = 'ISCC {0} {1} {2} setup.iss' -f $modeDefine, $stageDefine, $outDefine

    Write-Host "[build] mode=$tag"
    Write-Host "[build] $cmdLine"
    $started = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $iscc $modeDefine $stageDefine $outDefine $setupIss 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()
    $finished = Get-Date

    $fullLog = Join-Path $outDir "build_$tag.log"
    Set-Content -LiteralPath $fullLog -Value $output -Encoding UTF8

    $sha256 = $null
    $size = $null
    $signed = 'false'
    if (($code -eq 0) -and (Test-Path -LiteralPath $exe)) {
        try {
            if (Invoke-AuthenticodeSign $exe) { $signed = 'true' }
        } catch {
            Write-Host "[sign] $_" -ForegroundColor Red
            $failed += $tag
        }
        # Hash AFTER signing: the signature changes the file bytes.
        $size = (Get-Item -LiteralPath $exe).Length
        $sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        $failed += $tag
    }

    $line = '{0}  mode={1} exit={2} duration_ms={3} bytes={4} sha256={5} signed={8} exe={6} log={7}' -f `
        $finished.ToString('yyyy-MM-dd HH:mm:ss'), $tag, $code, `
        $sw.ElapsedMilliseconds, $size, $sha256, $exe, $fullLog, $signed
    Add-Content -LiteralPath $evidenceLog -Value $line

    if ($code -ne 0) {
        Write-Host ($output -split "`r?`n" | Select-Object -Last 25)
        Write-Error "[build] $tag FAILED (exit $code) - see $fullLog"
    } else {
        Write-Host ("[build] OK {0}  {1:N1} MB  sha256={2}" -f `
            $exeName, ($size / 1MB), $sha256)
    }
}

Write-Host "[build] evidence: $evidenceLog"
if ($failed.Count -gt 0) { exit 1 }
exit 0
