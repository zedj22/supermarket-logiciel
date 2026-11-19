#Requires -Version 5.1
<#
  R5 rehearsal harness - runs the ACTUAL compiled installer
  SupermarketPro-Setup-REHEARSAL.exe against an isolated environment
  (D:\R5Isolation only: isolated ports, isolated PostgreSQL cluster,
  never the development database, never Program Files, no UAC).

  Milestones:
    M0  prep   portable PostgreSQL extracted, cluster initdb, server up
    M1  install      silent install, identity/.env/provisioning asserts
    M2  backend      launcher start, /health/live + /health/ready = 200
    M3  flutter      packaged app launches and stays alive
    M4  upgrade      second install: same DB, preserved .env, pg_dump backup
    M5  uninstall    uninstaller: program files gone, data/DB preserved,
                     licence state reset
    M5b reinstall    NEW database (supermarket_pro_2), both DBs exist,
                     backend healthy again, fresh licence state

  Tags recorded per step: [REAL EXECUTED] / [SIMULATED] / [NOT TESTED].
  Evidence: D:\R5Isolation\build\rehearsal_evidence.log

  Exit codes: 0 all steps passed, 1 step failed, 2 setup/environment error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsolationRoot
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths (setup.iss REHEARSAL branch hardcodes D:\R5Isolation; keep in sync)
# ---------------------------------------------------------------------------
if ($IsolationRoot -ne 'D:\R5Isolation') {
    Write-Error ('setup.iss hardcodes D:\R5Isolation for the rehearsal ' +
        'install/data roots; pass -IsolationRoot D:\R5Isolation')
    exit 2
}

$setupExe    = Join-Path $IsolationRoot 'build\SupermarketPro-Setup-REHEARSAL.exe'
$appRoot     = Join-Path $IsolationRoot 'app'
$dataRoot    = Join-Path $IsolationRoot 'data'
$pgRoot      = Join-Path $IsolationRoot 'pg'
$pgBin       = Join-Path $pgRoot 'pgsql\bin'
$pgData      = Join-Path $pgRoot 'rehearsal-data'
$pgPwFile    = Join-Path $pgRoot 'superuser_password.txt'
$pgZip       = Join-Path $IsolationRoot 'vendor\postgresql-18.6-5-windows-x64-binaries.zip'
$pgZipSha    = 'e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2'
$buildDir    = Join-Path $IsolationRoot 'build'
$evidenceLog = Join-Path $buildDir 'rehearsal_evidence.log'
$backendUrl  = 'http://127.0.0.1:18000'
$pgPort      = 15432
$httpPort    = 18000

$script:EvLines   = New-Object System.Collections.Generic.List[string]
$script:StepList  = New-Object System.Collections.Generic.List[object]
$script:Failed    = $false
$script:BackendProc = $null
$script:PgPassword  = $null

function Write-Ev([string]$Line) {
    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Line
    $script:EvLines.Add($entry)
    Write-Host $entry
}

function Save-Evidence {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines($evidenceLog, $script:EvLines, $enc)
}

function Assert-Ev([bool]$Cond, [string]$Msg) {
    if ($Cond) {
        Write-Ev ('  PASS  ' + $Msg)
    } else {
        Write-Ev ('  FAIL  ' + $Msg)
        throw ('assertion failed: ' + $Msg)
    }
}

function Invoke-Step {
    param([string]$Name, [string]$Tag, [scriptblock]$Body)
    if ($script:Failed) {
        Write-Ev ('==== SKIP ' + $Name + ' (previous step failed) ====')
        $script:StepList.Add(@{ Name = $Name; Ok = $false; Skipped = $true })
        return
    }
    Write-Ev ('==== STEP ' + $Name + '  [' + $Tag + '] ====')
    $ok = $false
    try {
        & $Body
        $ok = $true
        Write-Ev ('---- ' + $Name + ' PASSED ----')
    } catch {
        Write-Ev ('---- ' + $Name + ' FAILED: ' + $_.Exception.Message + ' ----')
        $script:Failed = $true
    }
    $script:StepList.Add(@{ Name = $Name; Ok = $ok; Skipped = $false })
    Save-Evidence
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Invoke-Exe {
    # Runs an exe, captures combined output to a log file, returns exit code.
    # ONLY for short-lived children: a pipeline waits for pipe EOF, and a
    # child that inherits the pipe write handle (pg_ctl -> postgres) would
    # hang the statement forever even after the exe itself exits.
    param([string]$Exe, [string[]]$Arguments, [string]$OutFile, [string]$Label)
    Write-Ev ('  RUN  ' + $Label + ': ' + $Exe + ' ' + ($Arguments -join ' '))
    $output = & $Exe @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $output -Encoding UTF8 }
    Write-Ev ('  EXIT ' + $Label + ' = ' + $code)
    return $code
}

function Invoke-Native {
    # Bare call, no pipeline: the statement completes when the process
    # exits, regardless of grandchildren that inherit its std handles.
    param([string]$Exe, [string[]]$Arguments, [string]$Label)
    Write-Ev ('  RUN  ' + $Label + ': ' + $Exe + ' ' + ($Arguments -join ' '))
    & $Exe @Arguments
    $code = $LASTEXITCODE
    Write-Ev ('  EXIT ' + $Label + ' = ' + $code)
    return $code
}

function Invoke-Uninstaller {
    # Inno's uninstaller shows the same early-return/stale-exit behavior
    # observed with Setup.exe: the first process returns while the real
    # uninstall keeps running in the background.  Neither the exit code nor
    # the statement timing is trusted -- completion is the ground truth:
    # the wait target (install tree) is gone.  Returns 0 when gone within
    # the timeout, 1 otherwise.
    param([string]$Label, [string]$UninsPath, [string]$WaitPath, [int]$TimeoutSec = 600)
    Write-Ev ('  RUN  ' + $Label + ': ' + $UninsPath + ' /VERYSILENT /SUPPRESSMSGBOXES')
    $proc = Start-Process -FilePath $UninsPath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES') `
        -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $gone = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $WaitPath)) { $gone = $true; break }
        Start-Sleep -Seconds 2
    }
    $proc.Refresh()
    $firstExit = 'still-running'
    if ($proc.HasExited) { $firstExit = [string]$proc.ExitCode }
    Write-Ev ('  EXIT ' + $Label + ' first-process=' + $firstExit +
        ' wait-target-gone=' + $gone + ' (' + $WaitPath + ')')
    if ($gone) { return 0 }
    return 1
}

function Invoke-PgCtl {
    # pg_ctl through Start-Process with FILE redirection: file handles do
    # not have pipe-EOF semantics, so a statement can never hang waiting
    # for inherited std handles.  Only used where pg_ctl has no long-lived
    # descendants of its own (stop); the server itself is started directly.
    param([string[]]$Arguments, [string]$Label)
    $outF = Join-Path $buildDir ($Label + '.log')
    $errF = Join-Path $buildDir ($Label + '.err.log')
    Remove-Item -LiteralPath $outF, $errF -Force -ErrorAction SilentlyContinue
    Write-Ev ('  RUN  ' + $Label + ': pg_ctl ' + ($Arguments -join ' '))
    $p = Start-Process -FilePath (Join-Path $pgBin 'pg_ctl.exe') -ArgumentList $Arguments `
        -RedirectStandardOutput $outF -RedirectStandardError $errF `
        -WindowStyle Hidden -PassThru -Wait
    $code = $p.ExitCode
    $merged = ''
    foreach ($f in @($outF, $errF)) {
        if (Test-Path -LiteralPath $f) { $merged += [IO.File]::ReadAllText($f) }
    }
    foreach ($line in ($merged -split "`r?`n")) {
        if ($line.Trim()) { Write-Ev ('    | ' + $line.Trim()) }
    }
    Write-Ev ('  EXIT ' + $Label + ' = ' + $code)
    return $code
}

function Invoke-Setup {
    param([string]$Label)
    # Inno writes its own authoritative log via /LOG= (no shared file with
    # a capture stream); wizard output goes to the harness console log.
    $innoLog = Join-Path $buildDir ($Label + '_inno.log')
    Remove-Item -LiteralPath $innoLog -Force -ErrorAction SilentlyContinue
    Write-Ev ('  RUN  ' + $Label + ': ' + $setupExe +
        ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=' + $innoLog)
    Start-Process -FilePath $setupExe -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG=' + $innoLog)) `
        -PassThru -WindowStyle Hidden | Out-Null
    # $LASTEXITCODE is NOT usable here: observed to be stale (statement
    # returned in <1s carrying the previous native command's code while
    # the real installer kept running for 44s in the background). The Inno
    # log's "Log closed." line marks completion of the real installer.
    $deadline = (Get-Date).AddMinutes(15)
    $closed = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $innoLog) {
            try {
                $tail = [IO.File]::ReadAllText($innoLog)
                if ($tail -match 'Log closed') { $closed = $true; break }
            } catch { }
        }
    }
    $content = ''
    if (Test-Path -LiteralPath $innoLog) {
        try { $content = [IO.File]::ReadAllText($innoLog) } catch { }
    }
    $ok = $closed -and ($content -match 'Installation process succeeded') -and
        ($content -notmatch 'raised an exception') -and ($content -notmatch 'Runtime error')
    $code = 0
    if (-not $ok) { $code = 1 }
    Write-Ev ('  EXIT ' + $Label + ' = ' + $code + ' (inno log: ' + $innoLog + ')')
    if (-not $closed) {
        Write-Ev ('    FAIL: installer log never closed within timeout')
    }
    if ($content -match '(Runtime error[^\r\n]*)') {
        Write-Ev ('    | ' + $Matches[1].Trim())
    }
    return $code
}

function Invoke-Psql {
    param([string]$Query, [string]$Label, [string]$Database = 'postgres')
    $psql = Join-Path $pgBin 'psql.exe'
    $env:PGPASSWORD = $script:PgPassword
    try {
        $out = & $psql -h 127.0.0.1 -p $pgPort -U postgres -w -tA -d $Database -c $Query 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
    Write-Ev ('  PSQL ' + $Label + ' exit=' + $code + ' out=' + $out.Trim())
    if ($code -ne 0) { throw ('psql failed: ' + $out) }
    return $out.Trim()
}

function Get-DbCount([string]$DbName) {
    $q = "select count(*) from pg_database where datname='" + $DbName + "'"
    return [int](Invoke-Psql -Query $q -Label ('db_exists:' + $DbName))
}

function Get-TableCount([string]$DbName = 'supermarket_pro') {
    $q = "select count(*) from information_schema.tables where table_schema='public'"
    return [int](Invoke-Psql -Query $q -Label ('table_count:' + $DbName) -Database $DbName)
}

function Start-Backend {
    $py = Join-Path $appRoot 'backend\.venv\Scripts\python.exe'
    $backendDir = Join-Path $appRoot 'backend'
    $stdout = Join-Path $dataRoot 'logs\harness_backend_stdout.log'
    $stderr = Join-Path $dataRoot 'logs\harness_backend_stderr.log'
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $env:DATA_DIR = $dataRoot
    $script:BackendProc = Start-Process -FilePath $py -ArgumentList @('run_production.py') `
        -WorkingDirectory $backendDir -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Write-Ev ('  backend started pid=' + $script:BackendProc.Id)
}

function Wait-Health {
    param([int]$TimeoutSec = 120, [string]$Label = 'ready')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ok = $false
    $body = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri ($backendUrl + '/api/v1/health/ready') `
                -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $ok = $true; $body = $r.Content; break }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if ($ok) {
        Write-Ev ('  HEALTH ready=200 (' + $Label + ') body=' + $body.Substring(0, [Math]::Min(400, $body.Length)))
        try {
            $live = Invoke-WebRequest -Uri ($backendUrl + '/api/v1/health/live') `
                -UseBasicParsing -TimeoutSec 5
            Write-Ev ('  HEALTH live=' + $live.StatusCode)
        } catch {
            Write-Ev ('  HEALTH live FAILED: ' + $_.Exception.Message)
            $ok = $false
        }
    } else {
        Write-Ev ('  HEALTH timeout after ' + $TimeoutSec + 's (' + $Label + ')')
    }
    return $ok
}

function Stop-Backend {
    if ($script:BackendProc -ne $null) {
        $id = $script:BackendProc.Id
        $out = & taskkill.exe /PID $id /T /F 2>&1 | Out-String
        Write-Ev ('  STOP backend pid=' + $id + ' exit=' + $LASTEXITCODE + ' [' +
            'SIMULATED service stop: process kill, WinSW stop is production-only] out=' + $out.Trim())
        Start-Sleep -Seconds 2
        $script:BackendProc = $null
    }
}

function Get-FileSha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# M0 prep
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M0-prep' -Tag 'REAL EXECUTED' -Body {
    Write-Ev ('  isolation root: ' + $IsolationRoot)
    Write-Ev ('  evidence log:   ' + $evidenceLog)

    # Protected development artifacts (must remain untouched end-to-end).
    $protected = @(
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app_upload',
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app_upload.zip',
        'C:\Users\MSI\Desktop\supermarket_logiciel\tatus',
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend\.env'
    )
    foreach ($p in $protected) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            Write-Ev ('  protected artifact: ' + $p + ' mtime=' + $item.LastWriteTimeUtc.ToString('o'))
        } else {
            Write-Ev ('  protected artifact MISSING (recorded): ' + $p)
        }
    }
    # Dev PostgreSQL must stay untouched.
    $svc = & sc.exe query postgresql-x64-18 2>&1 | Out-String
    Write-Ev ('  dev PG service state: ' + (($svc -split "`n" | Select-String 'STATE') -join ' ').Trim())

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Stop OUR leftovers from an interrupted previous run first: the
    # rehearsal postmaster holds the dedicated port and a live backend
    # would lock the install tree.  Only our own data dir / app path are
    # touched -- never the development PostgreSQL service.
    $pgIsReady = Join-Path $pgBin 'pg_isready.exe'
    $readyCode = 99
    if (Test-Path -LiteralPath $pgIsReady) {
        & $pgIsReady -h 127.0.0.1 -p $pgPort -q | Out-Null
        $readyCode = $LASTEXITCODE
    }
    if ($readyCode -eq 0) {
        $stopCode = Invoke-PgCtl -Label 'pg_stop_previous' `
            -Arguments @('-D', $pgData, '-m', 'fast', 'stop')
        Write-Ev ('  previous rehearsal PG stopped exit=' + $stopCode)
    }
    if (Test-Path -LiteralPath $pgData) {
        Rename-Item -LiteralPath $pgData -NewName ('rehearsal-data.prev-' + $ts)
        Write-Ev ('  archived previous PG cluster -> rehearsal-data.prev-' + $ts + ' (preserved, not deleted)')
    }
    $leftoverBackends = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -and
            $_.CommandLine -like ('*' + $appRoot + '*') -and
            $_.CommandLine -like '*run_production.py*' })
    foreach ($proc in $leftoverBackends) {
        Write-Ev ('  stopping leftover backend pid=' + $proc.ProcessId)
        & taskkill.exe /PID $proc.ProcessId /T /F 2>&1 | Out-Null
    }

    # Ports must be free.  Our own leftovers are stopped above, so any
    # remaining LISTENING socket on them is a foreign squatter.
    $busy = & netstat.exe -ano | Select-String -Pattern 'LISTENING' |
        Select-String -Pattern (':' + $httpPort + ' '), (':' + $pgPort + ' ')
    Assert-Ev (-not $busy) ('ports ' + $httpPort + '/' + $pgPort + ' are free')

    # Installer present; record its identity.
    Assert-Ev (Test-Path -LiteralPath $setupExe) ('installer exists: ' + $setupExe)
    $setupSha = Get-FileSha $setupExe
    $setupLen = (Get-Item -LiteralPath $setupExe).Length
    Write-Ev ('  installer sha256=' + $setupSha + ' bytes=' + $setupLen)

    # Fresh state: uninstall leftovers, then ARCHIVE (never delete) any
    # previous rehearsal state so M1 starts from a clean seq=1 install.
    $unins = Join-Path $appRoot 'Unins000.exe'
    if (Test-Path -LiteralPath $unins) {
        $code = Invoke-Uninstaller -Label 'pre-uninstall' -UninsPath $unins -WaitPath $appRoot
        Assert-Ev ($code -eq 0) 'pre-uninstall completed (install tree removed)'
    }
    if (Test-Path -LiteralPath $appRoot) {
        Rename-Item -LiteralPath $appRoot -NewName ('app.prev-' + $ts)
        Write-Ev ('  archived previous install tree -> app.prev-' + $ts)
    }
    if (Test-Path -LiteralPath $dataRoot) {
        Rename-Item -LiteralPath $dataRoot -NewName ('data.prev-' + $ts)
        Write-Ev ('  archived previous data root -> data.prev-' + $ts + ' (preserved, not deleted)')
    }

    # PostgreSQL: verify zip pin, extract if needed.
    Assert-Ev (Test-Path -LiteralPath $pgZip) ('pg binaries zip exists: ' + $pgZip)
    $zipSha = Get-FileSha $pgZip
    Assert-Ev ($zipSha -eq $pgZipSha) 'pg binaries zip sha256 matches the verified pin'
    $initdb = Join-Path $pgBin 'initdb.exe'
    if (-not (Test-Path -LiteralPath $initdb)) {
        Write-Ev '  extracting portable PostgreSQL (first run, ~385 MB)...'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Expand-Archive -LiteralPath $pgZip -DestinationPath $pgRoot -Force
        $sw.Stop()
        Write-Ev ('  extraction done in ' + $sw.Elapsed.TotalSeconds.ToString('0.0') + 's')
    }
    Assert-Ev (Test-Path -LiteralPath $initdb) 'initdb.exe available'

    # Superuser password file (created once, reused across runs).
    if (-not (Test-Path -LiteralPath $pgPwFile)) {
        $pw = ([Guid]::NewGuid().ToString('N')) + ([Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($pgPwFile, $pw)
        Write-Ev '  generated superuser password file'
    }
    $script:PgPassword = [IO.File]::ReadAllText($pgPwFile).Trim()
    Assert-Ev ($script:PgPassword.Length -ge 16) 'superuser password file readable'

    # initdb (fresh cluster) + start on the dedicated port.
    $initLog = Join-Path $buildDir 'm0_initdb.log'
    $initArgs = @('-D', $pgData, '-U', 'postgres', ('--pwfile=' + $pgPwFile),
        '--auth-host=scram-sha-256', '--auth-local=trust', '-E', 'UTF8', '--locale=C')
    $code = Invoke-Exe -Exe $initdb -Arguments $initArgs -OutFile $initLog -Label 'initdb'
    Assert-Ev ($code -eq 0) 'initdb exit=0'

    # Start the postmaster DIRECTLY with file redirection.  pg_ctl (or any
    # PS statement that waits on std handles) hangs: the long-lived
    # postmaster inherits PowerShell's stdout/stderr pipe write handles,
    # so the statement waits for a pipe EOF that never arrives  - the
    # server itself is already up in that case (observed twice).  File
    # handles have no such EOF semantics, and -PassThru without -Wait
    # returns immediately.
    $pgOut = Join-Path $pgRoot 'postgres_stdout.log'
    $pgErr = Join-Path $pgRoot 'postgres_stderr.log'
    Remove-Item -LiteralPath $pgOut, $pgErr -Force -ErrorAction SilentlyContinue
    $pm = Start-Process -FilePath (Join-Path $pgBin 'postgres.exe') `
        -ArgumentList @('-D', $pgData, '-p', [string]$pgPort,
            '-c', 'listen_addresses=127.0.0.1') `
        -RedirectStandardOutput $pgOut -RedirectStandardError $pgErr `
        -WindowStyle Hidden -PassThru
    Write-Ev ('  postmaster pid=' + $pm.Id + ' (direct start; stderr log: ' + $pgErr + ')')

    $readyOk = $false
    for ($i = 0; $i -lt 30; $i++) {
        & $pgIsReady -h 127.0.0.1 -p $pgPort -q
        if ($LASTEXITCODE -eq 0) { $readyOk = $true; break }
        Start-Sleep -Seconds 1
    }
    Assert-Ev $readyOk ('pg_isready on 127.0.0.1:' + $pgPort + ' within 30s')

    $ver = Invoke-Psql -Query 'select version()' -Label 'version'
    Assert-Ev ($ver -like '*PostgreSQL 18*') 'superuser password auth works over TCP (scram)'

    # Nothing of ours is running yet.
    $scOut = & sc.exe query SupermarketProBackend 2>&1 | Out-String
    Assert-Ev ($LASTEXITCODE -ne 0) 'no SupermarketProBackend service registered before install'
}

# ---------------------------------------------------------------------------
# M1 install (silent, actual Setup.exe)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M1-install' -Tag 'REAL EXECUTED' -Body {
    $code = Invoke-Setup -Label 'M1-setup'
    Assert-Ev ($code -eq 0) 'M1 setup exit=0'

    # Identity (contract 10 / C1): fresh install = seq 1, plain DB name.
    $installTxt = Join-Path $appRoot 'install.txt'
    Assert-Ev (Test-Path -LiteralPath $installTxt) 'install.txt created'
    $idRaw = [IO.File]::ReadAllText($installTxt)
    Write-Ev ('  install.txt: ' + ($idRaw -replace "`r?`n", ' | '))
    Assert-Ev ($idRaw -match '(?m)^seq=1\r?$') 'install.txt seq=1'
    Assert-Ev ($idRaw -match '(?m)^database=supermarket_pro\r?$') 'install.txt database=supermarket_pro'

    # Launcher contract: .env without password, rehearsal ports.
    $envFile = Join-Path $dataRoot 'config\.env'
    Assert-Ev (Test-Path -LiteralPath $envFile) '.env created under data root'
    $envRaw = [IO.File]::ReadAllText($envFile)
    Assert-Ev ($envRaw -match '(?m)^LICENSE_ENFORCEMENT=on\r?$') '.env LICENSE_ENFORCEMENT=on'
    Assert-Ev ($envRaw -match ('(?m)^DATABASE_URL=postgresql://app_user@127\.0\.0\.1:' + $pgPort + '/supermarket_pro\r?$')) ('.env DATABASE_URL without password, port ' + $pgPort)
    Assert-Ev ($envRaw -match ('(?m)^PORT=' + $httpPort + '\r?$')) ('.env PORT=' + $httpPort)
    Assert-Ev ($envRaw -match '(?m)^APP_ENV=production\r?$') '.env APP_ENV=production'

    # R3 published app credentials (contract 3): database.env holds the
    # generated DATABASE_PASSWORD; run_production assembles DATABASE_URL
    # from .env's passwordless URL + this password (env-over-dotenv).
    $dbEnv = Join-Path $dataRoot 'config\database.env'
    Assert-Ev (Test-Path -LiteralPath $dbEnv) 'database.env created by provisioning'
    $dbRaw = [IO.File]::ReadAllText($dbEnv)
    Assert-Ev ($dbRaw -match '(?m)^DATABASE_PASSWORD=\S+') 'database.env carries DATABASE_PASSWORD (app role)'

    # Provisioning report + step log.
    $reportFile = Join-Path $dataRoot 'logs\provision_report.json'
    Assert-Ev (Test-Path -LiteralPath $reportFile) 'provision_report.json written'
    $reportRaw = [IO.File]::ReadAllText($reportFile)
    Write-Ev ('  provision report: ' + ($reportRaw -replace "`r?`n", ' ').Substring(0, [Math]::Min(300, ($reportRaw -replace "`r?`n", ' ').Length)))
    Assert-Ev ($reportRaw -match '"ok": true') 'provision report ok=true'
    $stepLog = Join-Path $dataRoot 'logs\install_steps.log'
    Assert-Ev (Test-Path -LiteralPath $stepLog) 'install_steps.log written'
    Assert-Ev (([IO.File]::ReadAllText($stepLog)) -match 'install OK') 'install_steps.log contains install OK'
    Write-Ev ('  install_steps.log tail: ' + ((Get-Content -LiteralPath $stepLog | Select-Object -Last 6) -join ' // '))

    # Staged payload landed.
    Assert-Ev (Test-Path -LiteralPath (Join-Path $appRoot 'backend\.venv\Scripts\python.exe')) 'venv python staged'
    Assert-Ev (Test-Path -LiteralPath (Join-Path $appRoot 'backend\run_production.py')) 'launcher staged'
    Assert-Ev (Test-Path -LiteralPath (Join-Path $appRoot 'backend\installer_provision.py')) 'provision driver staged'
    Assert-Ev (Test-Path -LiteralPath (Join-Path $appRoot 'app\supermarket_pos.exe')) 'flutter app staged'
    Assert-Ev (Test-Path -LiteralPath (Join-Path $appRoot 'vendor\THIRD_PARTY_NOTICES.md')) 'third-party notices shipped (contract 8)'

    # Database created in the ISOLATED cluster.
    Assert-Ev ((Get-DbCount 'supermarket_pro') -eq 1) 'database supermarket_pro exists in isolated cluster'
    Assert-Ev ((Get-TableCount) -gt 0) 'migrations applied (public tables > 0)'

    # Backups only on upgrade: fresh install must not create one.
    $backupDir = Join-Path $dataRoot 'backups'
    $bak = @(Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue)
    Assert-Ev ($bak.Count -eq 0) 'no backup on fresh install (M3 backup is upgrade-only)'

    # Compile-time separation: rehearsal must never touch SCM/firewall/XML.
    $scOut = & sc.exe query SupermarketProBackend 2>&1 | Out-String
    Assert-Ev ($LASTEXITCODE -ne 0) 'NO service registered by the rehearsal installer'
    Assert-Ev (-not (Test-Path -LiteralPath (Join-Path $appRoot 'SupermarketProBackend.xml'))) 'no WinSW XML in rehearsal install (production-only)'
    $fw = & netsh.exe advfirewall firewall show rule name='Supermarket Pro HTTP' 2>&1 | Out-String
    Assert-Ev ($fw -match 'No rules match') 'NO firewall rule created by the rehearsal installer'
}

# ---------------------------------------------------------------------------
# M2 backend start + health (actual launcher, actual HTTP)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M2-backend-health' -Tag 'REAL EXECUTED' -Body {
    Start-Backend
    Assert-Ev (Wait-Health -TimeoutSec 120 -Label 'M2 first boot') 'backend /health/ready returned 200'
}

# ---------------------------------------------------------------------------
# M3 Flutter launch (actual packaged app)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M3-flutter-launch' -Tag 'REAL EXECUTED (launch only; app-to-backend pairing NOT TESTED)' -Body {
    $exe = Join-Path $appRoot 'app\supermarket_pos.exe'
    Assert-Ev (Test-Path -LiteralPath $exe) 'flutter executable present'
    $p = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 8
    $p.Refresh()
    Assert-Ev (-not $p.HasExited) 'flutter process alive after 8s (exit code would be visible otherwise)'
    Write-Ev ('  flutter window title="' + $p.MainWindowTitle + '" pid=' + $p.Id)
    Assert-Ev ($p.MainWindowTitle -ne '') 'flutter main window exists'
    $null = $p.CloseMainWindow()
    Start-Sleep -Seconds 3
    $p.Refresh()
    if (-not $p.HasExited) {
        $out = & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-String
        Write-Ev ('  flutter close: force-kill exit=' + $LASTEXITCODE + ' out=' + $out.Trim())
        Start-Sleep -Seconds 2
        $p.Refresh()
    }
    Assert-Ev ($p.HasExited) 'flutter process terminated'
    Write-Ev ('  NOTE: first-run wizard defaults to http://localhost:8000; pairing to port ' + $httpPort + ' was NOT automated - app-to-backend connection NOT TESTED')
}

# ---------------------------------------------------------------------------
# M4 upgrade (second install over the first)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M4-upgrade' -Tag 'REAL EXECUTED (backup+identity) / SIMULATED (service stop = process kill)' -Body {
    $installTxt = Join-Path $appRoot 'install.txt'
    $envFile = Join-Path $dataRoot 'config\.env'
    $seqFile = Join-Path $dataRoot 'install_seq.txt'

    $envShaBefore = Get-FileSha $envFile
    $seqBefore = [IO.File]::ReadAllText($seqFile).Trim()
    $tablesBefore = Get-TableCount
    Write-Ev ('  pre-upgrade: tables=' + $tablesBefore + ' seq=' + $seqBefore + ' env_sha=' + $envShaBefore)

    Stop-Backend

    $code = Invoke-Setup -Label 'M4-setup'
    Assert-Ev ($code -eq 0) 'M4 setup exit=0 (upgrade)'

    # Same identity: upgrade must keep DB name and seq.
    $idRaw = [IO.File]::ReadAllText($installTxt)
    Write-Ev ('  install.txt after upgrade: ' + ($idRaw -replace "`r?`n", ' | '))
    Assert-Ev ($idRaw -match '(?m)^database=supermarket_pro\r?$') 'upgrade kept database=supermarket_pro'
    Assert-Ev ($idRaw -match '(?m)^seq=1\r?$') 'upgrade kept seq=1'
    Assert-Ev ([IO.File]::ReadAllText($seqFile).Trim() -eq '1') 'install_seq.txt still 1'

    # .env must be preserved byte-for-byte on upgrade.
    $envShaAfter = Get-FileSha $envFile
    Assert-Ev ($envShaAfter -eq $envShaBefore) '.env byte-identical after upgrade'

    # M3: pre-migration pg_dump backup exists and is non-empty.
    $backupDir = Join-Path $dataRoot 'backups'
    $bak = @(Get-ChildItem -LiteralPath $backupDir -Filter 'pre_migrate_*.sql' -File -ErrorAction SilentlyContinue)
    Assert-Ev ($bak.Count -ge 1) 'pre_migrate backup created on upgrade'
    foreach ($f in $bak) {
        Write-Ev ('  backup: ' + $f.Name + ' bytes=' + $f.Length)
        Assert-Ev ($f.Length -gt 0) ('backup non-empty: ' + $f.Name)
    }

    # Data survived: same DB, tables not lost, report fresh.
    Assert-Ev ((Get-DbCount 'supermarket_pro') -eq 1) 'supermarket_pro still exists after upgrade'
    Assert-Ev ((Get-DbCount 'supermarket_pro_2') -eq 0) 'no new DB name on upgrade'
    $tablesAfter = Get-TableCount
    Assert-Ev ($tablesAfter -ge $tablesBefore) ('table count preserved (' + $tablesBefore + ' -> ' + $tablesAfter + ')')
    $reportRaw = [IO.File]::ReadAllText((Join-Path $dataRoot 'logs\provision_report.json'))
    Assert-Ev ($reportRaw -match '"ok": true') 'provision report ok=true after upgrade'

    # Backend healthy again on the upgraded install.
    Start-Backend
    Assert-Ev (Wait-Health -TimeoutSec 120 -Label 'M4 post-upgrade') 'backend healthy after upgrade'
}

# ---------------------------------------------------------------------------
# M5 uninstall + reinstall (contract 10: reinstall picks a NEW DB name)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M5-uninstall' -Tag 'REAL EXECUTED' -Body {
    Stop-Backend

    $unins = Join-Path $appRoot 'Unins000.exe'
    Assert-Ev (Test-Path -LiteralPath $unins) 'uninstaller present'
    $code = Invoke-Uninstaller -Label 'M5-uninstall' -UninsPath $unins -WaitPath $appRoot
    Assert-Ev ($code -eq 0) 'uninstall completed within timeout'

    # Program files gone (incl. runtime-created install.txt/.venv).
    Assert-Ev (-not (Test-Path -LiteralPath $appRoot)) 'install tree removed'

    # Data root preserved (M5 default), except licence state (M4/T8).
    $seqFile = Join-Path $dataRoot 'install_seq.txt'
    Assert-Ev (Test-Path -LiteralPath $seqFile) 'install_seq.txt preserved'
    Assert-Ev ([IO.File]::ReadAllText($seqFile).Trim() -eq '1') 'install_seq.txt still 1'
    Assert-Ev (Test-Path -LiteralPath (Join-Path $dataRoot 'config\.env')) '.env preserved'
    $backupDir = Join-Path $dataRoot 'backups'
    $bak = @(Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue)
    Assert-Ev ($bak.Count -ge 1) 'backups preserved'
    Write-Ev ('  preserved backups: ' + (($bak | ForEach-Object { $_.Name + '(' + $_.Length + ')' }) -join ', '))
    Assert-Ev (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'license'))) 'licence state removed on uninstall (fresh trial on reinstall)'

    # Database preserved.
    Assert-Ev ((Get-DbCount 'supermarket_pro') -eq 1) 'database supermarket_pro still exists after uninstall'

    # No service ever existed / none left.
    $scOut = & sc.exe query SupermarketProBackend 2>&1 | Out-String
    Assert-Ev ($LASTEXITCODE -ne 0) 'no backend service after uninstall'
}

Invoke-Step -Name 'M5b-reinstall-new-db' -Tag 'REAL EXECUTED' -Body {
    $code = Invoke-Setup -Label 'M5b-setup'
    Assert-Ev ($code -eq 0) 'reinstall setup exit=0'

    # Contract 10: reinstall after uninstall = NEW empty database.
    $installTxt = Join-Path $appRoot 'install.txt'
    $idRaw = [IO.File]::ReadAllText($installTxt)
    Write-Ev ('  install.txt after reinstall: ' + ($idRaw -replace "`r?`n", ' | '))
    Assert-Ev ($idRaw -match '(?m)^seq=2\r?$') 'reinstall seq=2'
    Assert-Ev ($idRaw -match '(?m)^database=supermarket_pro_2\r?$') 'reinstall database=supermarket_pro_2'
    Assert-Ev ([IO.File]::ReadAllText((Join-Path $dataRoot 'install_seq.txt')).Trim() -eq '2') 'install_seq.txt now 2'

    # Both databases exist: old preserved, new created.
    Assert-Ev ((Get-DbCount 'supermarket_pro') -eq 1) 'OLD database supermarket_pro preserved'
    Assert-Ev ((Get-DbCount 'supermarket_pro_2') -eq 1) 'NEW database supermarket_pro_2 created'

    # New .env points at the new DB; old backups still there.
    $envRaw = [IO.File]::ReadAllText((Join-Path $dataRoot 'config\.env'))
    Assert-Ev ($envRaw -match ('(?m)^DATABASE_URL=postgresql://app_user@127\.0\.0\.1:' + $pgPort + '/supermarket_pro_2\r?$')) '.env now targets supermarket_pro_2'
    $bak = @(Get-ChildItem -LiteralPath (Join-Path $dataRoot 'backups') -File -ErrorAction SilentlyContinue)
    Assert-Ev ($bak.Count -ge 1) 'pre-reinstall backups preserved'

    # Fresh licence state after backend start.
    Start-Backend
    Assert-Ev (Wait-Health -TimeoutSec 120 -Label 'M5b reinstall') 'backend healthy after reinstall (new DB)'
    $licDir = Join-Path $dataRoot 'license'
    Assert-Ev (Test-Path -LiteralPath $licDir) 'licence state directory recreated (fresh trial)'
    $licFiles = @(Get-ChildItem -LiteralPath $licDir -File -ErrorAction SilentlyContinue)
    Write-Ev ('  licence files: ' + (($licFiles | ForEach-Object { $_.Name }) -join ', '))
}

# ---------------------------------------------------------------------------
# Final: stop backend, protected-artifact re-check, summary
# ---------------------------------------------------------------------------
Invoke-Step -Name 'M6-cleanup-and-verify' -Tag 'REAL EXECUTED' -Body {
    Stop-Backend

    $protected = @(
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app_upload',
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app_upload.zip',
        'C:\Users\MSI\Desktop\supermarket_logiciel\tatus',
        'C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend\.env'
    )
    foreach ($p in $protected) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            Write-Ev ('  protected artifact still present: ' + $p + ' mtime=' + $item.LastWriteTimeUtc.ToString('o'))
        }
    }
    $svc = & sc.exe query postgresql-x64-18 2>&1 | Out-String
    Write-Ev ('  dev PG service state at end: ' + (($svc -split "`n" | Select-String 'STATE') -join ' ').Trim())
    # The just-killed backend's listening socket needs a moment to close;
    # poll briefly, then require no LISTENING row (time-wait remnants of
    # health-check connections do not count as occupancy).
    $deadline = (Get-Date).AddSeconds(15)
    $busy = $true
    while ((Get-Date) -lt $deadline) {
        $busy = & netstat.exe -ano | Select-String -Pattern 'LISTENING' |
            Select-String -Pattern (':' + $httpPort + ' ')
        if (-not $busy) { break }
        Start-Sleep -Seconds 1
    }
    Assert-Ev (-not $busy) ('port ' + $httpPort + ' released after cleanup')
    Write-Ev '  rehearsal environment left in place for inspection: PG cluster, data root, archived *.prev-* dirs'
}

Save-Evidence

Write-Host ''
Write-Host '==================== REHEARSAL SUMMARY ===================='
$allOk = $true
foreach ($s in $script:StepList) {
    $state = if ($s.Ok) { 'PASS' } elseif ($s.Skipped) { 'SKIP' } else { 'FAIL' }
    if (-not $s.Ok) { $allOk = $false }
    Write-Host ('  [{0}] {1}' -f $state, $s.Name)
}
Write-Host ('Evidence: ' + $evidenceLog)
if ($allOk) {
    Write-Host 'RESULT: ALL STEPS PASSED'
    exit 0
} else {
    Write-Host 'RESULT: FAILURES PRESENT'
    exit 1
}
