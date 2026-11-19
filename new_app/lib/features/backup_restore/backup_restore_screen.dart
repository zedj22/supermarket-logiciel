// Objective 2 — portable backup & restore catalogue (§17.2).
//
// Settings keeps the one-click create/restore card; this screen is the
// full surface: per-backup integrity inspection (`GET /{id}/inspect`)
// shown *before* every restore confirmation, portable ZIP download,
// archive upload, and a restore confirm button that is disabled when
// the dump file is missing or its recorded SHA-256 no longer matches.
//
// List/create/restore go through `backupProvider` — the same state the
// Settings card uses — while inspect/download/upload live here. Nothing
// is announced as success before the server answers 2xx.
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../core/widgets/page_title.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/status_chip.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../../network/byte_download.dart';
import '../about/about_providers.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../licensing/backup_license_policy.dart';
import '../pos/pos_toast.dart';
import '../settings/backup_models.dart';
import '../settings/backup_provider.dart';

class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  ConsumerState<BackupRestoreScreen> createState() =>
      _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends ConsumerState<BackupRestoreScreen> {
  /// Id of the backup whose inspect/download is in flight (row spinner).
  int? _busyId;
  bool _uploadBusy = false;
  bool _createBusy = false;

  /// Set once so the licence refresh below runs on the first frame only.
  bool _licenseRefreshed = false;

  @override
  void initState() {
    super.initState();
    // Deferred so the permission gate below can decide first: a
    // non-admin must never trigger a catalogue request (§17).
    Future.microtask(() async {
      if (!ref.read(hasPermissionProvider(backupRestoreScope))) return;
      if (!mounted) return;
      await ref.read(backupProvider.notifier).load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh the licence snapshot through the existing system-info flow
    // (Phase L1-C) before build() watches it: one request either way — a
    // never-loaded provider builds on that watch, a cached one is re-read.
    // No new endpoint, no polling. `didChangeDependencies` (not initState)
    // because reaching the container needs an inherited lookup.
    if (_licenseRefreshed) return;
    _licenseRefreshed = true;
    ref.invalidate(systemInfoProvider);
  }

  String _loc() => ref.read(localeProvider).flutterLocale.languageCode;

  Dio get _dio => ref.read(apiClientProvider).dio;

  String _messageOf(DioException e) {
    // A licensing rejection is its own category: never fall back to
    // `permission_denied` or a generic retry for it (§4.4 / L1-D).
    final licenseKey = licenseErrorKeyFrom(e);
    if (licenseKey != null) return AppStrings.t(licenseKey, _loc());
    final message = backendErrorMessage(e);
    if (message != null) return message;
    if (isConnectionError(e)) return AppStrings.t('network_error_retry', _loc());
    return AppStrings.t('api_error_retry', _loc());
  }

  void _toast(
    String message, {
    required PosToastKind kind,
    String? detail,
  }) {
    if (!mounted) return;
    showPosToast(
      context,
      message: message,
      detail: detail,
      kind: kind,
      key: const Key('backup-restore-toast'),
    );
  }

  // -------------------------------------------------------------------------
  // Inspect / restore
  // -------------------------------------------------------------------------

  Future<void> _openInspect(
    BackupInfo backup, {
    required bool confirmMode,
  }) async {
    // Licence backstop (L1-D): the buttons are already disabled by the
    // gate, so this is unreachable from the UI — the server still owns
    // the decision either way.
    final perms = backupPermissionsFor(ref.read(backupLicenseGateProvider));
    if (confirmMode ? !perms.canRestore : !perms.canInspect) return;
    final loc = _loc();
    setState(() => _busyId = backup.id);
    Map<String, dynamic>? inspect;
    try {
      final response =
          await _dio.get('${BackupInfo.backupsPath}/${backup.id}/inspect');
      final data = response.data;
      if (data is Map<String, dynamic>) inspect = data;
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      // Cannot verify the file → never offer the confirm button.
      if (confirmMode) {
        _toast(
          AppStrings.t('backup_restore_failed', loc),
          detail: _messageOf(decodeByteErrorEnvelope(e)),
          kind: PosToastKind.error,
        );
      } else {
        _toast(_messageOf(e), kind: PosToastKind.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busyId = null);
    if (inspect == null) {
      _toast(AppStrings.t('api_error_retry', loc), kind: PosToastKind.error);
      return;
    }
    final confirmed = await _showInspectDialog(
      backup,
      inspect,
      confirmMode: confirmMode,
    );
    if (confirmed != true || !mounted) return;

    final ok = await ref.read(backupProvider.notifier).restore(backup.id);
    if (!mounted) return;
    if (ok) {
      _toast(
        AppStrings.t('backup_restored', loc),
        detail: backup.filename,
        kind: PosToastKind.success,
      );
    } else {
      _toast(
        AppStrings.t('backup_restore_failed', loc),
        detail: ref.read(backupProvider).errorMessage,
        kind: PosToastKind.error,
      );
    }
  }

  Future<bool?> _showInspectDialog(
    BackupInfo backup,
    Map<String, dynamic> inspect, {
    required bool confirmMode,
  }) {
    final loc = _loc();
    final theme = Theme.of(context);
    final filePresent = inspect['file_present'];
    final shaOk = inspect['sha256_ok'];
    final schemaOk = inspect['schema_compatible'];
    final warnings = ((inspect['warnings'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);

    // The confirm button refuses a missing file or a hash mismatch —
    // the backend would refuse them anyway (422), but the operator
    // should see *why* before pressing anything.
    final blocked = filePresent == false || shaOk == false;

    final (String integrityKey, StatusTone integrityTone) = switch (shaOk) {
      true => ('br_integrity_ok', StatusTone.success),
      false => ('br_integrity_bad', StatusTone.error),
      _ => ('br_integrity_unknown', StatusTone.neutral),
    };

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          AppStrings.t(
            confirmMode ? 'backup_restore_confirm' : 'br_inspect',
            loc,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                backup.filename,
                key: const Key('inspect-filename'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '${AppStrings.t('date', loc)}: '
                '${formatBackupDate(backup.createdAt)}   '
                '${formatBytes(backup.size)}',
                key: const Key('inspect-meta'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              StatusChip(
                label: AppStrings.t(integrityKey, loc),
                tone: integrityTone,
                testKey: const Key('inspect-integrity'),
              ),
              if (filePresent == false)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: StatusChip(
                    label: AppStrings.t('br_file_missing', loc),
                    tone: StatusTone.error,
                    testKey: const Key('inspect-file-missing'),
                  ),
                ),
              if (schemaOk != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: StatusChip(
                    label: AppStrings.t(
                      schemaOk ? 'br_schema_ok' : 'br_schema_mismatch',
                      loc,
                    ),
                    tone: schemaOk ? StatusTone.success : StatusTone.warning,
                    testKey: const Key('inspect-schema'),
                  ),
                ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  AppStrings.t('br_warnings', loc),
                  key: const Key('inspect-warnings-title'),
                  style: theme.textTheme.titleSmall,
                ),
                for (final warning in warnings)
                  Text(
                    warning,
                    key: Key('inspect-warning-$warning'),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 10),
              Text(
                AppStrings.t('br_safety_notice', loc),
                key: const Key('inspect-safety'),
                style: theme.textTheme.bodySmall,
              ),
              if (confirmMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.t('backup_restore_warning', loc),
                        key: const Key('inspect-restore-warning'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // §8: the operator must see the full blast radius
                      // (users/sessions/devices) before confirming.
                      Text(
                        AppStrings.t('backup_restore_side_effects', loc),
                        key: const Key('inspect-side-effects'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('restore-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          if (confirmMode)
            FilledButton(
              key: const Key('restore-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              onPressed: blocked
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: Text(AppStrings.t('confirm', loc)),
            )
          else
            FilledButton(
              key: const Key('inspect-close'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppStrings.t('close', loc)),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Download / upload / create
  // -------------------------------------------------------------------------

  Future<void> _download(BackupInfo backup) async {
    final loc = _loc();
    setState(() => _busyId = backup.id);
    try {
      final response = await _dio.get(
        '${BackupInfo.backupsPath}/${backup.id}/download',
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = bytesOfResponse(response.data);
      final lower = backup.filename.toLowerCase();
      final fallback = lower.endsWith('.sql')
          ? '${backup.filename.substring(0, backup.filename.length - 4)}.zip'
          : '${backup.filename}.zip';
      final fileName = filenameFromDisposition(
        response.headers.value('content-disposition'),
        fallback,
      );
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: AppStrings.t('br_download', loc),
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted || path == null) return; // cancel is neutral (§16.2)
      _toast(
        AppStrings.t('br_download_ready', loc),
        detail: fileName,
        kind: PosToastKind.success,
      );
    } on DioException catch (e) {
      _toast(
        AppStrings.t('br_download_failed', loc),
        detail: _messageOf(decodeByteErrorEnvelope(e)),
        kind: PosToastKind.error,
      );
    } on Object {
      _toast(
        AppStrings.t('br_download_failed', loc),
        kind: PosToastKind.error,
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _upload() async {
    // Licence backstop (L1-D) — see _openInspect.
    if (!backupPermissionsFor(ref.read(backupLicenseGateProvider)).canUpload) {
      return;
    }
    final loc = _loc();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['zip', 'sql'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return; // cancelled
    final picked = result.files.first;
    final MultipartFile multipart;
    final bytes = picked.bytes;
    final path = picked.path;
    if (bytes != null) {
      multipart = MultipartFile.fromBytes(bytes, filename: picked.name);
    } else if (path != null) {
      multipart = await MultipartFile.fromFile(path, filename: picked.name);
    } else {
      _toast(
        AppStrings.t('br_upload_failed', loc),
        kind: PosToastKind.error,
      );
      return;
    }
    setState(() => _uploadBusy = true);
    try {
      await _dio.post(
        '${BackupInfo.backupsPath}/upload',
        data: FormData.fromMap(<String, dynamic>{'file': multipart}),
      );
      _toast(
        AppStrings.t('br_upload_success', loc),
        detail: picked.name,
        kind: PosToastKind.success,
      );
      await ref.read(backupProvider.notifier).load();
    } on DioException catch (e) {
      _toast(
        AppStrings.t('br_upload_failed', loc),
        detail: _messageOf(e),
        kind: PosToastKind.error,
      );
    } on Object {
      _toast(
        AppStrings.t('br_upload_failed', loc),
        kind: PosToastKind.error,
      );
    } finally {
      if (mounted) setState(() => _uploadBusy = false);
    }
  }

  Future<void> _create() async {
    // Licence backstop (L1-D) — see _openInspect.
    if (!backupPermissionsFor(ref.read(backupLicenseGateProvider)).canCreate) {
      return;
    }
    final loc = _loc();
    setState(() => _createBusy = true);
    final ok = await ref.read(backupProvider.notifier).create();
    if (!mounted) return;
    setState(() => _createBusy = false);
    if (ok) {
      _toast(
        AppStrings.t('backup_created', loc),
        kind: PosToastKind.success,
      );
    } else {
      _toast(
        AppStrings.t('backup_create_failed', loc),
        detail: ref.read(backupProvider).errorMessage,
        kind: PosToastKind.error,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Rows
  // -------------------------------------------------------------------------

  Widget _backupRow(
    BackupInfo backup, {
    required bool busy,
    required BackupPermissions perms,
    String? loc,
  }) {
    final locale = loc ?? _loc();
    return Card(
      key: Key('backup-${backup.id}'),
      child: ListTile(
        title: Text(
          backup.filename,
          key: Key('backup-filename-${backup.id}'),
        ),
        subtitle: Text(
          '${formatBackupDate(backup.createdAt)} · ${formatBytes(backup.size)}',
        ),
        trailing: busy
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    key: Key('backup-busy-${backup.id}'),
                  ),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: Key('inspect-${backup.id}'),
                    tooltip: AppStrings.t('br_inspect', locale),
                    iconSize: 20,
                    icon: const Icon(Icons.info_outline),
                    onPressed: perms.canInspect
                        ? () => _openInspect(backup, confirmMode: false)
                        : null,
                  ),
                  IconButton(
                    key: Key('download-${backup.id}'),
                    tooltip: AppStrings.t('br_download', locale),
                    iconSize: 20,
                    icon: const Icon(Icons.download),
                    onPressed: () => _download(backup),
                  ),
                  IconButton(
                    key: Key('restore-${backup.id}'),
                    tooltip: AppStrings.t('backup_restore', locale),
                    iconSize: 20,
                    icon: const Icon(Icons.settings_backup_restore),
                    onPressed: perms.canRestore
                        ? () => _openInspect(backup, confirmMode: true)
                        : null,
                  ),
                ],
              ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Page
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canManage = ref.watch(hasPermissionProvider(backupRestoreScope));
    final state = ref.watch(backupProvider);
    final theme = Theme.of(context);

    if (!canManage) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          key: const Key('backup-restore-denied'),
        ),
      );
    }

    // Licence snapshot, refreshed through the existing system-info flow
    // (the shared client hands every /system/info body to the licensing
    // layer — Phase L1-C). Watching it here both fetches it if nothing
    // else has and rebuilds the restrictions when it changes.
    ref.watch(systemInfoProvider);
    final gate = ref.watch(backupLicenseGateProvider);
    final perms = backupPermissionsFor(gate);

    final loadFailed = state.hasError && !state.failedDuringAction;

    return RefreshIndicator(
      onRefresh: () => ref.read(backupProvider.notifier).load(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              title: AppStrings.t('nav_backup_restore', loc),
              titleKey: const Key('backup-restore-title'),
              trailing: OutlinedButton.icon(
                key: const Key('backup-restore-refresh'),
                onPressed: state.busy
                    ? null
                    : () => ref.read(backupProvider.notifier).load(),
                icon: const Icon(Icons.refresh),
                label: Text(AppStrings.t('refresh', loc)),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              key: const Key('backup-restore-safety'),
              color: AppColors.info.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.shield_outlined, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        AppStrings.t('br_safety_notice', loc),
                        key: const Key('backup-restore-safety-text'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (gate != BackupLicenseGate.unknown)
              Card(
                key: const Key('backup-restore-license-notice'),
                color: AppColors.warning.withValues(alpha: 0.12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          AppStrings.t(perms.noticeKeyFor(gate)!, loc),
                          key: const Key('backup-restore-license-text'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('backup-restore-create'),
                  onPressed:
                      (_createBusy || state.busy || !perms.canCreate)
                          ? null
                          : _create,
                  icon: _createBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: Text(AppStrings.t('backup_create', loc)),
                ),
                OutlinedButton.icon(
                  key: const Key('backup-restore-upload'),
                  onPressed:
                      (_uploadBusy || !perms.canUpload) ? null : _upload,
                  icon: _uploadBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_upload_outlined),
                  label: Text(AppStrings.t('br_upload', loc)),
                ),
              ],
            ),
            if (state.errorMessage != null && loadFailed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  state.errorMessage!,
                  key: const Key('backup-restore-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            SectionHeader(
              title: AppStrings.t('backups', loc),
              titleKey: 'backups',
              icon: Icons.storage_outlined,
            ),
            if (state.isLoading && state.items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.items.isEmpty && !loadFailed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  AppStrings.t('backup_empty', loc),
                  key: const Key('backup-restore-empty'),
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              for (final backup in state.items)
                _backupRow(
                  backup,
                  loc: loc,
                  perms: perms,
                  busy: _busyId == backup.id ||
                      state.pendingRestoreId == backup.id,
                ),
          ],
        ),
      ),
    );
  }
}
