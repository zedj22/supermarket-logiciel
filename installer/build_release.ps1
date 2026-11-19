#Requires -Version 5.1
<#
  Release pipeline for SupermarketPro-Setup.exe (one command, in order):

    1. Flutter   build_flutter.ps1        -> release bundle (P2)
    2. stage     stage_payload.ps1        -> <IsolationRoot>\stage\PRODUCTION
    3. gate      verify_payload.ps1       -> FAILS the release on forbidden
                                             files / missing artefacts (P1)
    4. compile   build_installer.ps1      -> build\SupermarketPro-Setup.exe
                                             (+ optional Authenticode)

  Every stage is fatal: a forbidden file, a missing exe or a failed compile
  stops the pipeline with a non-zero exit code, so a broken payload can
  never reach a client.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File build_release.ps1 `
        -IsolationRoot D:\R5Isolation [-Mode Production|Rehearsal] `
        [-SkipFlutter] [-SkipSign]

  Exit codes: 0 release produced, 1 a step failed, 2 setup error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsolationRoot,

    [ValidateSet('Rehearsal', 'Production')]
    [string]$Mode = 'Production',

    [switch]$SkipFlutter,
    [switch]$SkipSign,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$installerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $installerDir
$tag = $Mode.ToUpperInvariant()
$stageDir = Join-Path $IsolationRoot "stage\$tag"

function Step([string]$Name) {
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Invoke-Node([string]$Script, [string[]]$ArgList) {
    $path = Join-Path $installerDir $Script
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "setup error: missing $path" -ForegroundColor Red
        exit 2
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @ArgList
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "FAILED: $Script (exit $code)" -ForegroundColor Red
        exit 1
    }
}

$started = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $SkipFlutter) {
    Step 'P2 Flutter release build'
    Invoke-Node 'build_flutter.ps1' @('-RepoRoot', $repoRoot)
} else {
    Write-Host '[flutter] SKIPPED (-SkipFlutter): reusing the existing release bundle'
}

Step "stage payload ($tag)"
Invoke-Node 'stage_payload.ps1' @('-IsolationRoot', $IsolationRoot, '-Mode', $tag)

Step 'P1 forbidden-file gate'
Invoke-Node 'verify_payload.ps1' @('-StageDir', $stageDir, '-Mode', $tag)

Step "compile installer ($tag)"
$buildArgs = @('-IsolationRoot', $IsolationRoot, '-Mode', $Mode)
if ($SkipSign) { $buildArgs += '-SkipSign' }
Invoke-Node 'build_installer.ps1' $buildArgs

$sw.Stop()

$exe = if ($Mode -eq 'Rehearsal') {
    Join-Path $IsolationRoot 'build\SupermarketPro-Setup-REHEARSAL.exe'
} else {
    Join-Path $IsolationRoot 'build\SupermarketPro-Setup.exe'
}
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "FAILED: expected artefact missing: $exe" -ForegroundColor Red
    exit 1
}
$item = Get-Item -LiteralPath $exe
$sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host ''
Write-Host '=== release ready ===' -ForegroundColor Green
Write-Host ("  mode     : {0}" -f $tag)
Write-Host ("  file     : {0}" -f $item.FullName)
Write-Host ("  bytes    : {0}" -f $item.Length)
Write-Host ("  sha256   : {0}" -f $sha)
Write-Host ("  duration : {0:n1}s" -f $sw.Elapsed.TotalSeconds)
Write-Host 'RELEASE_OK'
exit 0
