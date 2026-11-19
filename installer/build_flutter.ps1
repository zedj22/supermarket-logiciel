#Requires -Version 5.1
<#
  P2 (release blocker): build the Flutter Windows release bundle.

  Runs `flutter pub get` then `flutter build windows --release` inside
  <repo>\new_app and verifies the artefacts the installer payload needs:

    build\windows\x64\runner\Release\supermarket_pos.exe
    build\windows\x64\runner\Release\data\flutter_assets\...
    build\windows\x64\runner\Release\flutter_windows.dll

  Fails loudly (exit 1) when Flutter is missing, the build fails, or an
  expected artefact is absent.  Never runs `dart analyze` or tests: this
  script exists to produce the release bundle, nothing else.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File build_flutter.ps1
    powershell ... -File build_flutter.ps1 -SkipPubGet -FlutterExe C:\flutter\bin\flutter.bat
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$FlutterExe = '',
    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$AppRoot = Join-Path $RepoRoot 'new_app'
$ReleaseDir = Join-Path $AppRoot 'build\windows\x64\runner\Release'
$ExePath = Join-Path $ReleaseDir 'supermarket_pos.exe'

if (-not (Test-Path -LiteralPath (Join-Path $AppRoot 'pubspec.yaml'))) {
    Write-Error "build_flutter: $AppRoot\pubspec.yaml not found (wrong -RepoRoot?)"
    exit 1
}

# ── locate flutter ──────────────────────────────────────────────────────────
if (-not $FlutterExe) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) {
        $FlutterExe = $cmd.Source
    }
}
if (-not $FlutterExe -or -not (Test-Path -LiteralPath $FlutterExe)) {
    Write-Error ("build_flutter: flutter.exe not found. Install the Flutter SDK " +
        "and put its bin directory on PATH, or pass -FlutterExe <path to flutter.bat>.")
    exit 1
}

Push-Location $AppRoot
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Write-Host "[flutter] using $FlutterExe"
    & $FlutterExe --version
    if ($LASTEXITCODE -ne 0) { throw "flutter --version failed ($LASTEXITCODE)" }

    if (-not $SkipPubGet) {
        Write-Host '[flutter] pub get'
        & $FlutterExe pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
    }

    Write-Host '[flutter] build windows --release'
    & $FlutterExe build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows --release failed ($LASTEXITCODE)" }
}
catch {
    Write-Host "BUILD_FLUTTER_FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Pop-Location
    exit 1
}
finally {
    Pop-Location
}

# ── verify the artefacts the staging step consumes ──────────────────────────
$missing = @()
foreach ($rel in @(
        'supermarket_pos.exe',
        'flutter_windows.dll',
        'data\flutter_assets\AssetManifest.bin',
        'data\icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) {
    Write-Host ("BUILD_FLUTTER_FAILED: release bundle is incomplete, missing: " +
        ($missing -join ', ')) -ForegroundColor Red
    Write-Host "  expected under: $ReleaseDir"
    exit 1
}

$exe = Get-Item -LiteralPath $ExePath
$sha = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$files = Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File
$bytes = ($files | Measure-Object -Property Length -Sum).Sum

$sw.Stop()
Write-Host ("[flutter] OK {0} files, {1:n1} MB, exe {2:n0} bytes sha256={3} in {4:n1}s" -f `
    $files.Count, ($bytes / 1MB), $exe.Length, $sha, $sw.Elapsed.TotalSeconds)
Write-Host ("FLUTTER_BUILD_OK exe={0} sha256={1} bytes={2} total_bytes={3}" -f `
    $ExePath, $sha, $exe.Length, $bytes)
exit 0
