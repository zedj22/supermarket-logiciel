<#
.SYNOPSIS
  Render the WinSW service definition for the actual install (P6).

.DESCRIPTION
  `SupermarketProBackend.xml` in this folder is the canonical template: it
  carries the production defaults

      C:\Program Files\Supermarket Pro     (installation tree, read-only)
      C:\ProgramData\SupermarketPro        (DATA_DIR, all writes)

  The installer must never copy it verbatim, because the install dir and the
  data root are installer decisions (they differ in a rehearsal build, on a
  non-C: system drive, or when an operator picks another location).  This
  script writes a rendered copy next to the WinSW wrapper with:

    * every `C:\Program Files\Supermarket Pro` replaced by -InstallDir
    * every `C:\ProgramData\SupermarketPro`  replaced by -DataDir
    * an optional <depend> on the PostgreSQL service (-PgService)
    * a validated XML document (the script fails if parsing breaks)

  It only READS the template and WRITES -OutFile; it never edits the
  repository file, so `tests/unit/test_service_winsw.py` keeps validating
  the canonical production defaults.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File render_service_xml.ps1 `
      -OutFile "C:\Program Files\Supermarket Pro\SupermarketProBackend.xml" `
      -InstallDir "C:\Program Files\Supermarket Pro" `
      -DataDir "C:\ProgramData\SupermarketPro"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$DataDir,
    [string]$Template = '',
    [string]$PgService = ''
)

$ErrorActionPreference = 'Stop'

# Resolved here, not in the param default: PowerShell 5.1 evaluates parameter
# defaults before $PSScriptRoot is bound, which silently yields an empty path.
if (-not $Template) {
    $Template = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'SupermarketProBackend.xml'
}

# Canonical defaults written into the template (must match the XML).
$TEMPLATE_INSTALL = 'C:\Program Files\Supermarket Pro'
$TEMPLATE_DATA = 'C:\ProgramData\SupermarketPro'

if (-not (Test-Path -LiteralPath $Template)) {
    throw "render_service_xml: template not found: $Template"
}
foreach ($p in @($InstallDir, $DataDir)) {
    if (-not $p -or -not [System.IO.Path]::IsPathRooted($p)) {
        throw "render_service_xml: '$p' is not an absolute path"
    }
}
if ($DataDir.TrimEnd('\').StartsWith($InstallDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "render_service_xml: the data root must not live inside the installation tree"
}

$install = $InstallDir.TrimEnd('\')
$data = $DataDir.TrimEnd('\')

$xml = [System.IO.File]::ReadAllText($Template, [System.Text.Encoding]::UTF8)
$before = $xml
$xml = $xml.Replace($TEMPLATE_INSTALL, $install)
$xml = $xml.Replace($TEMPLATE_DATA, $data)

if ($xml -eq $before -and ($install -ne $TEMPLATE_INSTALL -or $data -ne $TEMPLATE_DATA)) {
    throw 'render_service_xml: no template path was substituted (template drifted from the expected defaults)'
}

if ($PgService) {
    if ($xml -notmatch '</service>') { throw 'render_service_xml: template has no </service> element' }
    $xml = $xml.Replace('</service>', "  <depend>$PgService</depend>`r`n</service>")
}

# Validate before writing: a malformed service XML makes WinSW fail at boot.
try {
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xml)
} catch {
    throw "render_service_xml: rendered XML is invalid: $($_.Exception.Message)"
}
# NOTE: use LocalName, never .Name — PowerShell's XML adapter exposes XML
# *attributes* as properties, so `<name>`/`name="…"` shadow `$el.Name`.
$root = $doc.SelectSingleNode('/service')
if (-not $root) {
    throw "render_service_xml: root element is '$($doc.DocumentElement.LocalName)', expected 'service'"
}
$exe = $doc.SelectSingleNode('/service/executable')
if (-not $exe -or -not $exe.InnerText.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "render_service_xml: <executable> does not live under $install"
}

$parent = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
# UTF-8 without BOM (WinSW's XML parser rejects a BOM in some versions).
[System.IO.File]::WriteAllText($OutFile, $xml, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[winsw] rendered $OutFile"
Write-Host "[winsw]   install=$install"
Write-Host "[winsw]   data=$data"
if ($PgService) { Write-Host "[winsw]   depend=$PgService" }
exit 0
