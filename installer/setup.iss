; Supermarket Pro — Windows Desktop installer (R5)
;
; Build modes — EXACTLY ONE of these is passed by build_installer.ps1:
;   ISCC /DREHEARSAL  /DSTAGE_DIR=... setup.iss   -> SupermarketPro-Setup-REHEARSAL.exe
;   ISCC /DPRODUCTION /DSTAGE_DIR=... setup.iss   -> SupermarketPro-Setup.exe
;
; The rehearsal behaviour is compiled OUT of a production build (design §6):
; a production installer cannot reach the isolated paths, ports or the
; --rehearse-instance provisioning shim even if someone edits .env.

#if Defined(REHEARSAL) && Defined(PRODUCTION)
  #error REHEARSAL and PRODUCTION are mutually exclusive
#endif
#if !Defined(REHEARSAL) && !Defined(PRODUCTION)
  #error a build mode must be selected explicitly (define REHEARSAL or PRODUCTION)
#endif
#ifndef STAGE_DIR
  #error STAGE_DIR must point at the staged payload directory
#endif

#define MyAppName "Supermarket Pro"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Supermarket Pro"

#if Defined(REHEARSAL)
  #define ModeTag "REHEARSAL"
  #define OutName "SupermarketPro-Setup-REHEARSAL"
  #define AppIdGuid "{{6F2B9D4E-1C7A-4E5B-9A03-77D2C4E8B110}"
  #define InstallDir "D:\R5Isolation\app"
  #define DataDir "D:\R5Isolation\data"
  #define HttpPort "18000"
  #define PgPort "15432"
  #define PgBinDir "D:\R5Isolation\pg\pgsql\bin"
  #define AdminPwFile "D:\R5Isolation\pg\superuser_password.txt"
#else
  #define ModeTag "PRODUCTION"
  #define OutName "SupermarketPro-Setup"
  #define AppIdGuid "{{9E41A7C2-5B3F-4D18-B6E9-0C5A2F7D3301}"
  #define InstallDir "{autopf}\Supermarket Pro"
  #define DataDir "{commonappdata}\SupermarketPro"
  #define HttpPort "8000"
  #define PgPort "5432"
  #define PgInstallDir "{autopf}\SupermarketPro\PostgreSQL\18"
  #define PgDataDir "{commonappdata}\SupermarketPro\postgres\data"
  #define PgInstallerName "postgresql-18.6-5-windows-x64.exe"
  #define PgInstallerSha "227e2bc08091b4c2b8338c7d61b11d057f895711480b006f90bfcfcd2410a58a"
  ; R6 contract 7: official Microsoft VC++ 2015-2022 x64 redistributable
  ; (aka.ms/vs/17/release/vc_redist.x64.exe, FileVersion 14.44.35211.0,
  ;  Authenticode Valid / CN=Microsoft Corporation).  See R6 evidence
  ;  D:\R5Isolation\R6\evidence\VC_RUNTIME_DECISION.md.
  #define VcRedistName "vc_redist.x64.exe"
  #define VcRedistSha "CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B"
#endif

[Setup]
AppId={#AppIdGuid}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={#InstallDir}
DefaultGroupName={#MyAppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
#if Defined(REHEARSAL)
PrivilegesRequired=lowest
#else
PrivilegesRequired=admin
#endif
OutputBaseFilename={#OutName}
Compression=lzma2/fast
SolidCompression=no
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupLogging=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\app\supermarket_pos.exe
; P10: pre-install information (80 mm receipt-printer driver, ports, data
; paths). Third-party licences stay staged in vendor\THIRD_PARTY_NOTICES.md.
InfoBeforeFile={#STAGE_DIR}\vendor\INSTALL_NOTES.txt
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}

[Files]
Source: "{#STAGE_DIR}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\app\supermarket_pos.exe"; WorkingDir: "{app}\app"
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\app\supermarket_pos.exe"; WorkingDir: "{app}\app"

[UninstallDelete]
; The uninstall log only knows the [Files] entries.  Runtime-created
; files inside the install tree (.venv, pip bytecode, install.txt,
; the WinSW XML copy) must go with it — install.txt in particular MUST
; leave, or a reinstall would be mistaken for an upgrade (contract 10).
; The whole install tree is program files by contract (R1): every
; writable state lives under the data root and survives uninstall (M5).
Type: filesandordirs; Name: "{app}"

[Code]
{ Inno has no built-in environment setter; Exec'd children (venv, pip,
  installer_provision, run_production --check) inherit whatever this
  process has, so DATA_DIR must land here first. }
function SetEnvironmentVariable(lpName: String; lpValue: String): Boolean;
external 'SetEnvironmentVariableW@kernel32.dll stdcall';

var
  StepLog: string;
  UpgradeMode: Boolean;
  PendingDbName: string;
  PendingSeq: Integer;
  { Wizard page for the maintenance (superuser) password of a PostgreSQL
    server that already exists on this PC (reuse path). }
  { Inno Setup 7 still exposes the wizard page as TInputQueryWizardPage;
    the short TInputQueryPage alias is not defined by its Pascal Script. }
  PgAdminPage: TInputQueryWizardPage;
  PgAdminPassword: string;
  { Fresh-install database name chosen by the wizard when the default name
    is already taken on the reused server (wins over the /DBNAME default). }
  PgDbNameOverride: string;
  PgDbList: string;
  { Cached readiness detection (ShouldSkipPage is called repeatedly). }
  PgDetectDone: Boolean;
  PgDetectResult: Boolean;
  { True once the wizard authenticated against the existing server: the
    backend then plans from THAT endpoint instead of rediscovering. }
  PgAdminVerified: Boolean;
  { PostgresBinDir() cached before ProvisionArgs needs it (functions may
    only be called after their definition in this script). }
  PgBinDirRun: string;
  { True when the post-install self-check (ACLs or health) failed: the
    wizard must never then say the installation succeeded. }
  SelfCheckFailed: Boolean;
  SelfCheckReason: string;

function DataRoot: string;
begin
  Result := ExpandConstant('{#DataDir}');
end;

function AppRoot: string;
begin
  Result := ExpandConstant('{#InstallDir}');
end;

procedure LogStep(const Msg: string);
begin
  Log(Msg);
  if StepLog <> '' then
    SaveStringToFile(StepLog,
      GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '  ' + Msg + #13#10, True);
end;

function RunExe(const StepName, Exe, Args, WorkDir: string): Integer;
var
  ResultCode: Integer;
begin
  LogStep(StepName + ' start: ' + Exe + ' ' + Args);
  if Exec(Exe, Args, WorkDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    LogStep(Format('%s exit=%d', [StepName, ResultCode]));
    Result := ResultCode;
  end else begin
    LogStep(StepName + ' launch failed (process could not be started)');
    Result := -1;
  end;
end;

procedure RequireOk(const StepName: string; Rc: Integer);
begin
  if Rc <> 0 then
    RaiseException(Format(
      'Step "%s" failed with exit code %d. See %s for details.', [StepName, Rc, StepLog]));
end;

function ReadAllText(const FileName: string): string;
var
  S: AnsiString;
begin
  Result := '';
  if LoadStringFromFile(FileName, S) then
    Result := Trim(String(S));
end;

function ReadKeyValue(const FileName, Key: string): string;
var
  Lines: TArrayOfString;
  I: Integer;
  Prefix: string;
begin
  Result := '';
  Prefix := Key + '=';
  if LoadStringsFromFile(FileName, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if Copy(Lines[I], 1, Length(Prefix)) = Prefix then begin
        Result := Copy(Lines[I], Length(Prefix) + 1,
          Length(Lines[I]) - Length(Prefix));
        exit;
      end;
end;

procedure CreateDataDirs;
begin
  ForceDirectories(DataRoot + '\config');
  ForceDirectories(DataRoot + '\license');
  ForceDirectories(DataRoot + '\data');
  ForceDirectories(DataRoot + '\backups');
  ForceDirectories(DataRoot + '\logs');
  ForceDirectories(DataRoot + '\installers');
end;

{ M1/M3/M4 identity (C1): an upgrade keeps its database; a reinstall after
  uninstall picks a NEW empty name, because install.txt leaves with the
  install tree while install_seq.txt survives in the data root. }
procedure ResolveIdentity;
var
  InstallFile, SeqFile, OldDb, RequestedDb: string;
  Seq: Integer;
begin
  InstallFile := AppRoot + '\install.txt';
  SeqFile := DataRoot + '\install_seq.txt';
  UpgradeMode := FileExists(InstallFile);
  if UpgradeMode then begin
    OldDb := ReadKeyValue(InstallFile, 'database');
    if OldDb = '' then
      RaiseException(InstallFile + ' exists but has no "database" key');
    PendingDbName := OldDb;
    PendingSeq := StrToIntDef(ReadKeyValue(InstallFile, 'seq'), 1);
    LogStep('identity: upgrade, database=' + PendingDbName);
  end else begin
    Seq := StrToIntDef(ReadAllText(SeqFile), 0) + 1;
    if Seq = 1 then
      PendingDbName := 'supermarket_pro'
    else
      PendingDbName := Format('supermarket_pro_%d', [Seq]);
    { Escape hatch for a shared PostgreSQL server: when the default name
      already belongs to another database, provisioning refuses to touch it
      and tells the operator to re-run with /DBNAME=<name>. Only a plain
      identifier is accepted here; the backend validates it again. }
    RequestedDb := Trim(ExpandConstant('{param:DBNAME|}'));
    if RequestedDb <> '' then begin
      if Pos(' ', RequestedDb) > 0 then
        RaiseException('/DBNAME must not contain spaces: ' + RequestedDb);
      PendingDbName := RequestedDb;
    end;
    if PgDbNameOverride <> '' then
      PendingDbName := PgDbNameOverride;
    PendingSeq := Seq;
    LogStep(Format('identity: fresh/reinstall seq=%d database=%s', [Seq, PendingDbName]));
  end;
end;

procedure CommitIdentity;
var
  InstallFile: string;
begin
  SaveStringToFile(DataRoot + '\install_seq.txt', IntToStr(PendingSeq), False);
  InstallFile := AppRoot + '\install.txt';
  SaveStringToFile(InstallFile,
    'seq=' + IntToStr(PendingSeq) + #13#10 +
    'database=' + PendingDbName + #13#10 +
    'mode={#ModeTag}' + #13#10 +
    'version={#MyAppVersion}' + #13#10 +
    'installed=' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + #13#10,
    False);
  LogStep('identity committed: ' + InstallFile);
end;

function BuildEnvContent(const DbName: string): string;
begin
  { DATABASE_URL carries no password: the launcher assembles it from
    <DATA_DIR>\config\database.env (R4 §5 / R5 contract 3). }
  Result :=
    'APP_ENV=production' + #13#10 +
    'DATABASE_URL=postgresql://app_user@127.0.0.1:{#PgPort}/' + DbName + #13#10 +
    'LICENSE_ENFORCEMENT=on' + #13#10 +
    'TRIAL_DAYS=10' + #13#10 +
    'LICENSE_STATE_DIR=' + #13#10 +
    'LICENSE_VERIFICATION_KEYS_FILE=' + #13#10 +
    'LOG_DIR=' + #13#10 +
    'LOG_FILE_ENABLED=' + #13#10 +
    'LOG_FILE_NAME=backend.log' + #13#10 +
    'LOG_MAX_BYTES=5242880' + #13#10 +
    'LOG_BACKUP_COUNT=10' + #13#10 +
    'LAN_MODE=0' + #13#10 +
    'DISCOVERY_ENABLED=0' + #13#10 +
    'DISCOVERY_PORT={#HttpPort}' + #13#10 +
    'PG_INSTALL_DIR=' + #13#10 +
    'PG_BIN_DIR=' + #13#10 +
    'PG_DATA_DIR=' + #13#10 +
    'PG_SERVICE_NAME=' + #13#10 +
    'PG_PORT={#PgPort}' + #13#10 +
    'SERVER_ID=' + #13#10 +
    'SERVER_ID_FILE=data/server_id' + #13#10 +
    'STORE_NAME=Supermarket Pro' + #13#10 +
    'HOST=127.0.0.1' + #13#10 +
    'PORT={#HttpPort}' + #13#10 +
    'LOG_LEVEL=INFO' + #13#10;
end;

procedure EnsureEnvFile(const DbName: string);
var
  EnvFile: string;
begin
  EnvFile := DataRoot + '\config\.env';
  if UpgradeMode and FileExists(EnvFile) then begin
    LogStep('.env preserved (upgrade): ' + EnvFile);
    exit;
  end;
  if SaveStringToFile(EnvFile, BuildEnvContent(DbName), False) then
    LogStep('.env written: ' + EnvFile)
  else
    RaiseException('failed to write ' + EnvFile);
end;

function PgAdminPasswordFile: string;
begin
  Result := ExpandConstant('{tmp}\pg_admin_password.txt');
end;

function ProvisionArgs(const DbName: string): string;
begin
  Result :=
    '"' + AppRoot + '\backend\installer_provision.py"' +
    ' --data-dir "' + DataRoot + '"' +
    ' --db-name ' + DbName +
    ' --db-port {#PgPort}';
  if UpgradeMode then
    Result := Result + ' --backup-dir "' + DataRoot + '\backups"';
  // Inno constants are only expanded in [Files]/[Icons] and by
  // ExpandConstant(). A bare define expands at COMPILE time to its literal
  // text (autopf plus a backslash path), which the backend then received
  // verbatim on the second install attempt -- the reported bug.
  if PgAdminPassword <> '' then
    Result := Result +
      ' --admin-password-file "' + PgAdminPasswordFile + '"' +
      ' --save-admin-password';
  { Plan from the endpoint the wizard authenticated against, never from a
    fresh discovery pass. }
  if PgAdminVerified then
    Result := Result + ' --admin-host 127.0.0.1 --verified-server';
  if PgBinDirRun <> '' then
    Result := Result + ' --pg-bin-dir "' + PgBinDirRun + '"';
#if Defined(REHEARSAL)
  { contract 14: the explicit-instance shim exists ONLY in this branch;
    the production build never passes it. }
  Result := Result +
    ' --rehearse-instance 127.0.0.1:{#PgPort}' +
    ' --rehearse-major 18' +
    ' --rehearse-pg-bin "{#PgBinDir}"' +
    ' --admin-password-file "{#AdminPwFile}"';
#else
  if not UpgradeMode then
    Result := Result + ' --fresh-install';
  Result := Result +
    ' --installer-path "' + AppRoot + '\vendor\{#PgInstallerName}"' +
    ' --installer-sha256 {#PgInstallerSha}' +
    ' --pg-install-dir "' + ExpandConstant('{#PgInstallDir}') + '"' +
    ' --pg-data-dir "' + ExpandConstant('{#PgDataDir}') + '"';
#endif
end;

procedure WritePgAdminPasswordFile;
begin
  if PgAdminPassword = '' then
    exit;
  { Written into the installer's temporary folder, passed by path only, and
    deleted as soon as the provisioning pass returns. The password is never
    logged and never appears on a command line an operator can screenshot. }
  if not SaveStringToFile(PgAdminPasswordFile, PgAdminPassword, False) then
    RaiseException('could not write the maintenance password file');
  LogStep('maintenance password captured from the wizard (value not logged)');
end;

#if Defined(PRODUCTION)
function EnvFileValue(const Key: string): string;
begin
  Result := ReadKeyValue(DataRoot + '\config\.env', Key);
end;

{ R6 contract 7: guarantee the VC++ 2015-2022 runtime BEFORE the Flutter app
  can ever be launched and before the service registers.  Runs AFTER the R3
  provisioning step (whose EDB --install_runtimes 1 runs first on a clean
  machine).  Exit 0 = success; 3010 = success, reboot requested (files are
  already usable on a clean machine); 1638 = a version is already present
  (runtime guaranteed).  Any other code aborts the install — no assumption
  is ever made about the EDB runtime step. }
procedure ProductionVcRedist;
var
  Rc: Integer;
  Redist: string;
  Actual: string;
begin
  Redist := AppRoot + '\vendor\{#VcRedistName}';
  if not FileExists(Redist) then
    RaiseException('missing ' + Redist);
  Actual := GetSHA256OfFile(Redist);
  if CompareText(Actual, '{#VcRedistSha}') <> 0 then
    RaiseException(Format('SHA-256 mismatch for %s: %s', [Redist, Actual]));
  LogStep('vc-redist sha256 verified: ' + Actual);
  Rc := RunExe('vc-redist', Redist, '/install /quiet /norestart', AppRoot);
  if (Rc <> 0) and (Rc <> 3010) and (Rc <> 1638) then
    RequireOk('vc-redist', Rc);
  LogStep(Format('vc-redist accepted exit=%d', [Rc]));
end;

procedure ProductionFirewall;
var
  Rc: Integer;
begin
  { Gate G-FW: only when the operator enabled LAN_MODE; this procedure
    does not exist in a REHEARSAL build. }
  if EnvFileValue('LAN_MODE') <> '1' then begin
    LogStep('firewall skipped (LAN_MODE=0)');
    exit;
  end;
  Rc := RunExe('firewall-tcp', 'netsh.exe',
    'advfirewall firewall add rule name="Supermarket Pro HTTP" dir=in ' +
    'action=allow protocol=TCP localport={#HttpPort}', AppRoot);
  RequireOk('firewall-tcp', Rc);
  Rc := RunExe('firewall-udp', 'netsh.exe',
    'advfirewall firewall add rule name="Supermarket Pro Discovery" dir=in ' +
    'action=allow protocol=UDP localport={#HttpPort}', AppRoot);
  RequireOk('firewall-udp', Rc);
end;

procedure ProductionServiceRegister;
var
  Rc: Integer;
begin
  { P6: never copy the XML verbatim — its paths are the template defaults.
    Render it for THIS install (install dir + data root, validated XML)
    so a non-default installation location still produces a working
    service definition. }
  Rc := RunExe('winsw-xml', 'powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -File "' +
    AppRoot + '\backend\winsw\render_service_xml.ps1" -OutFile "' +
    AppRoot + '\SupermarketProBackend.xml" -InstallDir "' + AppRoot +
    '" -DataDir "' + DataRoot + '"', AppRoot);
  RequireOk('winsw-xml', Rc);

  Rc := RunExe('acl', 'powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -File "' +
    AppRoot + '\backend\winsw\grant_data_dir_acl.ps1" -DataDir "' +
    DataRoot + '" -InstallDir "' + AppRoot + '"', AppRoot);
  RequireOk('acl', Rc);

  { Re-register when upgrading over an existing install: stop and remove
    are best-effort (fresh machine: no service yet), install/start must
    succeed. }
  RunExe('winsw-stop-pre', AppRoot + '\SupermarketProBackend.exe',
    'stop', AppRoot);
  RunExe('winsw-uninstall-pre', AppRoot + '\SupermarketProBackend.exe',
    'uninstall', AppRoot);

  Rc := RunExe('winsw-install', AppRoot + '\SupermarketProBackend.exe',
    'install', AppRoot);
  RequireOk('winsw-install', Rc);

  Rc := RunExe('winsw-start', AppRoot + '\SupermarketProBackend.exe',
    'start', AppRoot);
  RequireOk('winsw-start', Rc);
end;
#endif

{ ── P5: port pre-flight ──────────────────────────────────────────────
  Runs BEFORE anything is written.  Two very different situations:

    * 5432 already owned by postgres.exe -> the supported "reuse the
      existing server" path; nothing is installed or touched there.
    * 8000 owned by our own service -> upgrade; the service is stopped at
      ssInstall before files are replaced.

  Anything else is a real conflict, and the operator gets the offending
  process name on screen instead of a failed service start 6 minutes later. }

function ServiceQueryText: string;
var
  TmpFile, CmdLine: string;
  Rc: Integer;
begin
  Result := '';
  TmpFile := ExpandConstant('{tmp}\sc-query.txt');
  if FileExists(TmpFile) then DeleteFile(TmpFile);
  CmdLine := '/C sc query SupermarketProBackend > "' + TmpFile + '" 2>NUL';
  if not Exec(ExpandConstant('{cmd}'), CmdLine, '', SW_HIDE,
      ewWaitUntilTerminated, Rc) then
    exit;
  Result := Uppercase(ReadAllText(TmpFile));
end;

function OurServiceExists: Boolean;
begin
  Result := Pos('SERVICE_NAME', ServiceQueryText) > 0;
end;

function ProcessNameForPid(const Pid: string): string;
var
  TmpFile, CmdLine, Output: string;
  Rc, P: Integer;
begin
  Result := '';
  TmpFile := ExpandConstant('{tmp}\tasklist.txt');
  if FileExists(TmpFile) then DeleteFile(TmpFile);
  CmdLine := '/C tasklist /FI "PID eq ' + Pid + '" /FO CSV /NH > "' +
    TmpFile + '" 2>NUL';
  if not Exec(ExpandConstant('{cmd}'), CmdLine, '', SW_HIDE,
      ewWaitUntilTerminated, Rc) then
    exit;
  Output := ReadAllText(TmpFile);
  if (Output = '') or (Copy(Output, 1, 1) <> '"') then
    exit;
  Delete(Output, 1, 1);
  P := Pos('"', Output);
  if P > 0 then
    Result := Copy(Output, 1, P - 1);
end;

{ Name of the process LISTENING on Port ('' when the port is free). }
function PortOwner(const Port: string): string;
var
  TmpFile, CmdLine, Line, Tail, Pid: string;
  Lines: TArrayOfString;
  I, Rc, P: Integer;
begin
  Result := '';
  TmpFile := ExpandConstant('{tmp}\netstat.txt');
  if FileExists(TmpFile) then DeleteFile(TmpFile);
  CmdLine := '/C netstat -ano -p tcp > "' + TmpFile + '" 2>NUL';
  if not Exec(ExpandConstant('{cmd}'), CmdLine, '', SW_HIDE,
      ewWaitUntilTerminated, Rc) then
    exit;
  if not LoadStringsFromFile(TmpFile, Lines) then
    exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Lines[I];
    { Locale-proof: netstat localizes its state column (LISTENING / ÉCOUTE /
      ABHÖREN), so a listener is recognised by its FOREIGN address being the
      wildcard port 0, never by the state word. ":8000 " cannot match
      ":18000 " because of the trailing space. }
    if (Pos(':' + Port + ' ', Line) > 0) and (Pos(':0 ', Line) > 0) then begin
      Tail := Trim(Line);
      P := Length(Tail);
      while (P > 0) and (Tail[P] <> ' ') do
        P := P - 1;
      Pid := Trim(Copy(Tail, P + 1, Length(Tail) - P));
      Result := ProcessNameForPid(Pid);
      if Result = '' then
        Result := 'unknown process (pid ' + Pid + ')'
      else
        Result := Result + ' (pid ' + Pid + ')';
      exit;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Owner: string;
begin
  Result := '';
  NeedsRestart := False;
#if Defined(PRODUCTION)
  Owner := PortOwner('{#HttpPort}');
  if Owner <> '' then begin
    if (Pos('SupermarketProBackend.exe', Owner) = 1) or
       ((Pos('python.exe', Owner) = 1) and OurServiceExists) then
      Log('P5: port {#HttpPort} held by this installation (' + Owner +
        ') — upgrade path, the service is stopped before files are copied')
    else begin
      Result := 'Port {#HttpPort} (used by the Supermarket Pro service) is ' +
        'already in use by: ' + Owner + '.' + #13#10#13#10 +
        'Close that programme (or stop its service), then run this ' +
        'installer again. If you are not sure which programme it is, open ' +
        'Task Manager, find it in the Details tab and end it.';
      exit;
    end;
  end;

  Owner := PortOwner('{#PgPort}');
  if Owner <> '' then begin
    if Pos('postgres.exe', Owner) = 1 then
      Log('P5: an existing PostgreSQL already owns {#PgPort} (' + Owner +
        ') — the installer will REUSE that server and will not touch its ' +
        'databases')
    else begin
      Result := 'Port {#PgPort} (the database port) is already in use by: ' +
        Owner + ', which is not PostgreSQL.' + #13#10#13#10 +
        'Free that port (or stop that programme) and run this installer ' +
        'again. Supermarket Pro cannot share the database port with an ' +
        'unrelated programme.';
      exit;
    end;
  end;
#endif
end;

{ ── Existing-PostgreSQL wizard page (reuse path) ─────────────────────
  A reused server is somebody else's PostgreSQL: creating our role and
  database needs its superuser credentials. Without them the pass can only
  fail with "password authentication failed for user app_user", which tells
  an operator nothing. Ask, explain, and pass it by file. }

{ ISPP treats a line that starts with '#' as a directive, so a Pascal
  '#13#10' continuation must never begin a line: use this constant. }
function NL: string;
begin
  Result := #13#10;
end;

function PostgresRegistryPresent: Boolean;
var
  Names: TArrayOfString;
begin
  Result := RegGetSubkeyNames(HKLM, 'SOFTWARE\PostgreSQL\Installations', Names);
end;

{ Directory holding psql.exe of an installed PostgreSQL (EDB writes
  "Base Directory" per registered installation). Used only to TEST the
  superuser password before it is accepted. }
function PostgresBinDir: string;
var
  Names: TArrayOfString;
  Base: string;
  I: Integer;
begin
  Result := '';
  if not RegGetSubkeyNames(HKLM, 'SOFTWARE\PostgreSQL\Installations', Names) then
    exit;
  for I := 0 to GetArrayLength(Names) - 1 do begin
    if RegQueryStringValue(HKLM,
        'SOFTWARE\PostgreSQL\Installations\' + Names[I],
        'Base Directory', Base) then
      if FileExists(Base + '\bin\psql.exe') then begin
        Result := Base + '\bin';
        exit;
      end;
  end;
end;

{ One pg_isready attempt: 0 means the server ACCEPTS connections on our
  port. -1 when no pg_isready is available (nothing can be concluded). }
function PgIsReadyOnce: Integer;
var
  Bin: string;
begin
  Bin := PostgresBinDir();
  if Bin = '' then begin
    Result := -1;
    exit;
  end;
  Result := RunExe('pg-isready', Bin + '\pg_isready.exe',
    '-h 127.0.0.1 -p {#PgPort} -q -t 3', ExpandConstant('{tmp}'));
end;

{ Waits for a server that is still starting: a RUNNING service can still
  refuse connections for a few seconds (postmaster replay/recovery), which
  is exactly how the previous check raced a healthy PostgreSQL. }
function WaitForPostgres(const Attempts: Integer): Boolean;
var
  I, Rc: Integer;
begin
  Result := False;
  if PostgresBinDir() = '' then
    exit;
  for I := 1 to Attempts do begin
    Rc := PgIsReadyOnce;
    if Rc = 0 then begin
      if I > 1 then
        Log(Format('PostgreSQL accepted connections after %d attempt(s)', [I]));
      Result := True;
      exit;
    end;
    { The array must stay on one line: a line beginning with `[` is read
      as a section tag by the Inno preprocessor. }
    Log(Format('pg_isready attempt %d/%d: not accepting yet (exit %d)', [I, Attempts, Rc]));
    if I < Attempts then
      Sleep(1500);
  end;
end;

function ExistingPostgresDetected: Boolean;
var
  Owner: string;
begin
  if PgDetectDone then begin
    Result := PgDetectResult;
    exit;
  end;
  { Service state alone is not proof: `sc query` may report RUNNING while
    the postmaster still refuses connections, and a healthy server may be
    reported as anything by a localized netstat. Ask the server itself, and
    give a starting one a few seconds. }
  Result := WaitForPostgres(5);
  if not Result then begin
    Owner := PortOwner('{#PgPort}');
    if Pos('postgres.exe', Owner) = 1 then begin
      Log('{#PgPort} is owned by ' + Owner +
        ' but pg_isready did not accept yet: the password test decides');
      Result := True;
    end;
  end;
  if (not Result) and PostgresRegistryPresent then
    Log('a PostgreSQL installation is registered but nothing accepts ' +
      'connections on {#PgPort}: provisioning will consider a dedicated ' +
      'instance');
  if PostgresBinDir() = '' then
    Log('pg_isready/psql not found: password verification and readiness ' +
      'checks are unavailable, the backend will verify');
  PgDetectDone := True;
  PgDetectResult := Result;
end;

{ Connects as the maintenance user to `postgres` on 127.0.0.1:{#PgPort}.
  Returns True when the password is accepted; on failure [ErrorText] holds
  psql's own message. When no psql can be found the check cannot run: it
  reports success (verified=False) and the backend still refuses to persist
  anything until provisioning itself has succeeded. }
function VerifyPgAdminPassword(const Password: string; var ErrorText: string;
  var Checked: Boolean): Boolean;
var
  Bin, Bat, OutFile, CmdLine: string;
  Rc: Integer;
begin
  Result := True;
  Checked := False;
  ErrorText := '';
  Bin := PostgresBinDir();
  if Bin = '' then begin
    Log('password test skipped: no psql.exe found');
    exit;
  end;

  Bat := ExpandConstant('{tmp}\pg_admin_check.bat');
  OutFile := ExpandConstant('{tmp}\pg_admin_check.txt');
  DeleteFile(OutFile);
  { The password travels in the environment, never on a command line and
    never in this .bat file, so neither can leak into a log. The redirect
    lives inside the .bat so cmd needs no nested quoting. }
  if not SaveStringToFile(Bat,
      '@echo off' + NL +
      '"' + Bin + '\psql.exe" -h 127.0.0.1 -p {#PgPort} -U postgres ' +
      '-d postgres -w -tAc "select 1" > "' + OutFile + '" 2>&1' + NL +
      'exit /b %ERRORLEVEL%' + NL, False) then begin
    Log('password test skipped: could not write ' + Bat);
    exit;
  end;

  SetEnvironmentVariable('PGPASSWORD', Password);
  SetEnvironmentVariable('PGCONNECT_TIMEOUT', '5');
  SetEnvironmentVariable('PGCLIENTENCODING', 'UTF8');
  CmdLine := '/C "' + Bat + '"';
  Rc := RunExe('pg-password-test', ExpandConstant('{cmd}'), CmdLine,
    ExpandConstant('{tmp}'));
  SetEnvironmentVariable('PGPASSWORD', '');
  DeleteFile(Bat);

  Checked := True;
  if Rc = 0 then begin
    Log('password test: accepted');
    LogStep('maintenance password verified against 127.0.0.1:{#PgPort}');
    exit;
  end;
  Result := False;
  ErrorText := Trim(ReadAllText(OutFile));
  if ErrorText = '' then
    ErrorText := Format('psql exited with code %d', [Rc]);
  { Never log psql's stderr verbatim: it can quote the user name and host,
    which is harmless, but the password itself is never echoed by psql. }
  Log('password test: REJECTED - ' + ErrorText);
end;

{ Existing database names on the server that owns {#PgPort}, one per line.
  Empty when the list cannot be read (then no name is auto-chosen). }
function PgQueryDatabases(const Password: string): string;
var
  Bin, Bat, OutFile, CmdLine: string;
  Rc: Integer;
begin
  Result := '';
  Bin := PostgresBinDir();
  if Bin = '' then
    exit;
  Bat := ExpandConstant('{tmp}\pg_db_list.bat');
  OutFile := ExpandConstant('{tmp}\pg_db_list.txt');
  DeleteFile(OutFile);
  if not SaveStringToFile(Bat,
      '@echo off' + NL +
      '"' + Bin + '\psql.exe" -h 127.0.0.1 -p {#PgPort} -U postgres ' +
      '-d postgres -w -tA -c "select datname from pg_database" > "' +
      OutFile + '" 2>&1' + NL +
      'exit /b %ERRORLEVEL%' + NL, False) then begin
    Log('database list skipped: could not write ' + Bat);
    exit;
  end;
  SetEnvironmentVariable('PGPASSWORD', Password);
  SetEnvironmentVariable('PGCONNECT_TIMEOUT', '5');
  CmdLine := '/C "' + Bat + '"';
  Rc := RunExe('pg-db-list', ExpandConstant('{cmd}'), CmdLine,
    ExpandConstant('{tmp}'));
  SetEnvironmentVariable('PGPASSWORD', '');
  DeleteFile(Bat);
  if Rc <> 0 then begin
    Log(Format('database list failed (psql exit %d)', [Rc]));
    exit;
  end;
  Result := ReadAllText(OutFile);
end;

function DbNameInList(const DbName, List: string): Boolean;
begin
  Result := List <> '';
  if Result then
    Result := Pos(NL + DbName + NL, NL + List + NL) > 0;
end;

function PickFreeDbName(const Base, List: string): string;
var
  I: Integer;
  Candidate: string;
begin
  Result := Base;
  if not DbNameInList(Result, List) then
    exit;
  for I := 2 to 50 do begin
    Candidate := Base + '_' + IntToStr(I);
    if not DbNameInList(Candidate, List) then begin
      Result := Candidate;
      exit;
    end;
  end;
end;

{ Fresh install on a shared server: never let the default name collide with
  a database that is not ours. Picks a free name for the operator, explains
  why, and honours /DBNAME. Returns False only when an explicitly requested
  name is already taken (the operator must choose another). }
function CheckFreshDatabaseName(const Password: string): Boolean;
var
  Requested, Candidate: string;
begin
  Result := True;
  PgDbNameOverride := '';
  if FileExists(AppRoot + '\install.txt') then begin
    Log('database name check skipped: upgrade keeps its database');
    exit;
  end;
  PgDbList := PgQueryDatabases(Password);
  if PgDbList = '' then begin
    Log('database name check skipped: could not list databases');
    exit;
  end;

  Requested := Trim(ExpandConstant('{param:DBNAME|}'));
  if Requested <> '' then begin
    if DbNameInList(Requested, PgDbList) then begin
      Result := False;
      LogStep('requested database already exists on the server: ' + Requested +
        ' (nothing created; the operator must choose another name)');
      MsgBox('The database "' + Requested + '" already exists on this ' +
        'PostgreSQL server. Supermarket Pro never reuses or modifies a ' +
        'database it did not create.' + NL + NL +
        'Choose another name, e.g. /DBNAME=' + Requested + '_install, ' +
        'or leave /DBNAME out and the installer will pick one for you.',
        mbError, MB_OK);
    end;
    exit;
  end;

  if not DbNameInList('supermarket_pro', PgDbList) then
    exit;

  Candidate := PickFreeDbName('supermarket_pro_install', PgDbList);
  PgDbNameOverride := Candidate;
  LogStep('database name switched: supermarket_pro belongs to another ' +
    'installation; this install will use ' + Candidate);
  MsgBox('This PostgreSQL server already has a database named ' +
    '"supermarket_pro". It does not belong to this installation and will ' +
    'NOT be touched.' + NL + NL +
    'Supermarket Pro will create and use its own database "' + Candidate +
    '" instead (plus its own login role).' + NL + NL +
    'To use a different name, re-run the installer with /DBNAME=<name>.',
    mbInformation, MB_OK);
end;

procedure DiscardStoredAdminPassword;
var
  Src, Dst: string;
begin
  Src := DataRoot + '\config\pg_admin.env';
  if not FileExists(Src) then
    exit;
  Dst := Src + '.rejected-' + GetDateTimeString('yyyymmdd-hhnnss', '', '');
  if RenameFile(Src, Dst) then
    LogStep('stored maintenance password rejected; moved aside to ' + Dst)
  else
    LogStep('stored maintenance password rejected; could not move ' + Src);
end;

procedure InitializeWizard;
begin
  PgBinDirRun := PostgresBinDir();
#if Defined(PRODUCTION)
  PgAdminPage := CreateInputQueryPage(wpInfoBefore,
    'Existing PostgreSQL server',
    'This PC already has PostgreSQL',
    'Supermarket Pro will REUSE the PostgreSQL server that is already ' +
    'installed and running on this PC instead of installing a second copy. ' +
    'It creates only its own role and its own database and never reads, ' +
    'alters or drops any other database.' + NL + NL +
    'Enter the password of that server''s superuser account (usually ' +
    '"postgres"). Next TESTS the connection: a wrong password is refused ' +
    'here, not in the middle of the installation.' + NL + NL +
    'On an upgrade, leave the field empty to reuse the password stored by ' +
    'the previous installation - if it no longer works you will be asked ' +
    'to type the current one.' + NL + NL +
    'The password is stored (and then only after it has been verified) in ' +
    'C:\ProgramData\SupermarketPro\config for upgrades and backups.' + NL +
    'New PC with no PostgreSQL? This page is skipped.');
  PgAdminPage.Add('Superuser (postgres) password:', True);
#endif
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
#if Defined(PRODUCTION)
  if (PgAdminPage <> nil) and (PageID = PgAdminPage.ID) then
    Result := not ExistingPostgresDetected;
#endif
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Entered, Stored, ErrorText, PwUsed: string;
  Checked: Boolean;
begin
  Result := True;
#if Defined(PRODUCTION)
  if (PgAdminPage <> nil) and (CurPageID = PgAdminPage.ID) then begin
    { Never Trim() the password: a trailing space or '@' is part of the
      credential the operator typed, psql already verified it exactly, and
      the file handoff must carry the same bytes. Trim() is used only to
      decide whether the field is empty. }
    Entered := PgAdminPage.Values[0];
    if Trim(Entered) = '' then begin
      { Upgrade path: reuse the stored password, but only if it still works. }
      Stored := ReadKeyValue(DataRoot + '\config\pg_admin.env',
        'PG_ADMIN_PASSWORD');
      if Stored = '' then begin
        Result := False;
        MsgBox('Enter the password of the existing PostgreSQL server (user ' +
          '"postgres"). It is needed once, to create this application''s own ' +
          'role and database.', mbError, MB_OK);
        exit;
      end;
      if VerifyPgAdminPassword(Stored, ErrorText, Checked) then begin
        PgAdminPassword := '';
        PgAdminVerified := True;
        if not CheckFreshDatabaseName(Stored) then
          Result := False;
        exit;
      end;
      { The stored credential no longer works: move it out of the way so it
        can never be reused, and ask for the current password. }
      DiscardStoredAdminPassword;
      Result := False;
      MsgBox('The PostgreSQL password stored by the previous installation ' +
        'was rejected by the server:' + NL + NL + ErrorText + NL + NL +
        'It has been moved aside. Type the current superuser password.',
        mbError, MB_OK);
      exit;
    end;

    if VerifyPgAdminPassword(Entered, ErrorText, Checked) then begin
      PgAdminPassword := Entered;
      PgAdminVerified := True;
      PwUsed := Entered;
      if not CheckFreshDatabaseName(PwUsed) then
        Result := False;
      exit;
    end;
    Result := False;
    MsgBox('Cannot connect to the PostgreSQL server on port {#PgPort} as ' +
      '"postgres" with that password:' + NL + NL + ErrorText + NL + NL +
      'Check the password (and that the server is running) and try again.',
      mbError, MB_OK);
  end;
#endif
end;

{ The provision step's stdout cannot be captured by Exec, so the backend
  writes the real reason to provision_error.txt / provision_report.json;
  copy it into install_steps.log before failing. }
procedure LogProvisionFailure(const Rc: Integer);
var
  ErrPath, ReportPath, Detail: string;
begin
  ErrPath := DataRoot + '\logs\provision_error.txt';
  ReportPath := DataRoot + '\logs\provision_report.json';
  Detail := '';
  if FileExists(ErrPath) then
    Detail := ReadAllText(ErrPath);
  if Detail <> '' then
    LogStep('provision reason: ' + Detail)
  else if FileExists(ReportPath) then
    LogStep('provision report (truncated): ' +
      Copy(ReadAllText(ReportPath), 1, 1500))
  else
    LogStep('provision produced no report; see the backend log');
  LogStep(Format('provision FAILED exit=%d (reason above; details in %s)', [Rc, ReportPath]));
end;

{ Appends a whole file to install_steps.log (bounded: the installer log
  is what a technician reads first). }
procedure AppendLogFile(const Path, Title: string);
var
  Lines: TArrayOfString;
  I: Integer;
begin
  if not FileExists(Path) then begin
    LogStep('--- ' + Title + ': file missing: ' + Path + ' ---');
    exit;
  end;
  if not LoadStringsFromFile(Path, Lines) then begin
    LogStep('--- ' + Title + ': unreadable: ' + Path + ' ---');
    exit;
  end;
  LogStep('--- ' + Title + ': ' + Path + ' ---');
  for I := 0 to GetArrayLength(Lines) - 1 do
    if I < 200 then
      LogStep('  ' + Lines[I]);
  if GetArrayLength(Lines) > 200 then
    LogStep('  ... (' + IntToStr(GetArrayLength(Lines) - 200) + ' more lines)');
end;

{ P7: ACLs applied LAST, immediately before the service starts, by SID and
  per file.  In the sandbox the config files ended up with a DACL that
  granted nothing and the NetworkService backend crash-looped on
  PermissionError, while the installer reported success. }
procedure HardenConfigAcls(const VenvPy, BackendDir: string);
var
  Rc: Integer;
begin
  Rc := RunExe('config-acl', VenvPy,
    '"' + BackendDir + '\installer_selfcheck.py" --data-dir "' + DataRoot +
    '" --phase pre-service', BackendDir);
  if Rc <> 0 then begin
    SelfCheckFailed := True;
    SelfCheckReason := 'the configuration files could not be secured for the ' +
      'service account (ACL self-check failed)';  
    AppendLogFile(DataRoot + '\logs\selfcheck.txt', 'ACL self-check');
    LogStep(Format('config ACL self-check FAILED (exit %d) - see above', [Rc]));
    RaiseException(SelfCheckReason + '.' + #13#10#13#10 +
      'Diagnostics were written to ' + DataRoot + '\logs\install_steps.log');
  end;
  LogStep('config ACL self-check OK');
end;

{ P7: the installation is only a success when the API answers with the
  database connected.  A failed start keeps the files in place (a retry
  resumes) but the wizard says so and never claims success. }
procedure WaitBackendHealth(const VenvPy, BackendDir: string);
var
  Rc: Integer;
begin
  Rc := RunExe('health', VenvPy,
    '"' + BackendDir + '\installer_selfcheck.py" --data-dir "' + DataRoot +
    '" --phase post-service --url "http://127.0.0.1:{#HttpPort}/api/v1/health"' +
    ' --health-timeout 60', BackendDir);
  if Rc <> 0 then begin
    SelfCheckFailed := True;
    SelfCheckReason := 'the backend did not report a connected database on ' +
      'http://127.0.0.1:{#HttpPort}/api/v1/health within 60 seconds';
    AppendLogFile(DataRoot + '\logs\selfcheck.txt', 'health self-check');
    AppendLogFile(DataRoot + '\logs\backend.log', 'backend.log');
    AppendLogFile(DataRoot + '\logs\SupermarketProBackend.err.log',
      'WinSW error log');
    LogStep('=== health self-check FAILED ===');
    LogStep(SelfCheckReason);
  end else
    LogStep('health self-check OK (database connected)');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Message: string;
begin
  if (CurPageID = wpFinished) and SelfCheckFailed then begin
    { A line beginning with '#' would be read as a preprocessor directive,
      so the line breaks come from NL instead of inline #13#10 codes. }
    Message := 'The files were installed, but the installation is NOT working yet.';
    Message := Message + NL + NL + SelfCheckReason + '.';
    Message := Message + NL + NL + 'Diagnostics: ' + DataRoot +
      '\logs\install_steps.log, ' + DataRoot + '\logs\selfcheck.txt, ' +
      DataRoot + '\logsackend.log.';
    Message := Message + NL + 'Run this installer again once the cause is ' +
      'fixed; the database and the PostgreSQL instance are reused.';
    WizardForm.FinishedLabel.Caption := Message;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  VenvPy, BackendDir: string;
  Rc: Integer;
begin
  if CurStep = ssInstall then begin
#if Defined(PRODUCTION)
    { M3: stop the service BEFORE files are replaced (python.exe is
      locked while the service runs). Ignore failures: a fresh machine
      has no service yet. }
    if FileExists(AppRoot + '\SupermarketProBackend.exe') then begin
      RunExe('winsw-stop-precopy', AppRoot + '\SupermarketProBackend.exe',
        'stop', AppRoot);
    end;
#endif
    exit;
  end;

  if CurStep <> ssPostInstall then
    exit;

  CreateDataDirs;
  StepLog := DataRoot + '\logs\install_steps.log';
  LogStep('=== install begin ({#ModeTag} {#MyAppVersion}) ===');

  ResolveIdentity;
  EnsureEnvFile(PendingDbName);

  { Child-process environment: DATA_DIR is what makes every backend
    process resolve <DATA_DIR>\config (R1/R2/R3). }
  SetEnvironmentVariable('DATA_DIR', DataRoot);
  SetEnvironmentVariable('PYTHONUTF8', '1');
  SetEnvironmentVariable('PIP_DISABLE_PIP_VERSION_CHECK', '1');
#if Defined(PRODUCTION)
  { Second R3 execution gate — production only, never in rehearsal. }
  SetEnvironmentVariable('R3_ALLOW_POSTGRESQL_INSTALL', '1');
#endif

  BackendDir := AppRoot + '\backend';
  VenvPy := BackendDir + '\.venv\Scripts\python.exe';

  { The wizard stays on the progress page during these long steps: tell the
    operator what is happening instead of leaving a frozen bar. }
  WizardForm.StatusLabel.Caption :=
    'Preparing the application runtime (first run only, a few minutes)...';

  { Step 1: venv from the staged runtime (idempotent). }
  Rc := RunExe('venv', BackendDir + '\python\python.exe',
    '-m venv "' + BackendDir + '\.venv"', BackendDir);
  RequireOk('venv', Rc);

  { Step 2: offline wheelhouse (contract 13). }
  Rc := RunExe('pip', VenvPy,
    '-m pip install --disable-pip-version-check --no-index ' +
    '--find-links "' + BackendDir + '\wheelhouse" ' +
    '-r "' + BackendDir + '\requirements.lock.txt"', BackendDir);
  RequireOk('pip', Rc);

  { Step 3: R3 provisioning pass (create-if-absent, migrate, RBAC,
    database.env; M3 backup first when upgrading). }
  WizardForm.StatusLabel.Caption :=
    'Setting up the database. If PostgreSQL has to be installed this can ' +
    'take 10-20 minutes; the installer writes a log to ' +
    DataRoot + '\logs\install_steps.log';
  WritePgAdminPasswordFile;
  Rc := RunExe('provision', VenvPy, ProvisionArgs(PendingDbName), BackendDir);
  DeleteFile(PgAdminPasswordFile);
  if Rc <> 0 then begin
    LogProvisionFailure(Rc);
    RequireOk('provision', Rc);
  end;

#if Defined(PRODUCTION)
  { Step 3b: VC++ runtime guarantee (R6 contract 7) — after EDB provisioning,
    before the health gate and before service registration. }
  ProductionVcRedist;
#endif

  WizardForm.StatusLabel.Caption := 'Starting the service and checking the API...';

  { Step 3c: ACLs for the credential files and logs — last step that
    touches config, immediately before the service is registered. }
  HardenConfigAcls(VenvPy, BackendDir);

  { Step 4: launcher health gate — --check must exit 0 (R2). }
  Rc := RunExe('check', VenvPy,
    '"' + BackendDir + '\run_production.py" --check', BackendDir);
  RequireOk('check', Rc);

#if Defined(PRODUCTION)
  ProductionServiceRegister;
  ProductionFirewall;
  { Step 5: prove the installation works, not just that files were copied. }
  WaitBackendHealth(VenvPy, BackendDir);
#endif

  if not SelfCheckFailed then begin
    CommitIdentity;
    LogStep('=== install OK ===');
  end else
    LogStep('=== install FAILED: self-check (see above) ===');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usUninstall then
    exit;

  { M4/licensing T8: uninstalling resets the licence state so the next
    install starts a new trial.  The database, backups and install_seq
    stay untouched (M5: data preserved by default). }
  DelTree(DataRoot + '\license', True, True, True);
  Log('license state removed; data root preserved: ' + DataRoot);

#if Defined(PRODUCTION)
  if FileExists(AppRoot + '\SupermarketProBackend.exe') then begin
    RunExe('uninstall-winsw-stop', AppRoot + '\SupermarketProBackend.exe',
      'stop', AppRoot);
    RunExe('uninstall-winsw', AppRoot + '\SupermarketProBackend.exe',
      'uninstall', AppRoot);
  end;
  { Best effort: rules only exist when LAN_MODE=1 created them. }
  RunExe('uninstall-fw-tcp', 'netsh.exe',
    'advfirewall firewall delete rule name="Supermarket Pro HTTP"', AppRoot);
  RunExe('uninstall-fw-udp', 'netsh.exe',
    'advfirewall firewall delete rule name="Supermarket Pro Discovery"',
    AppRoot);
#endif
end;
