// Objective 1 — product import / export UI.
//
// Export: `POST /api/v1/products/export` (JSON body) → bytes → the save
// dialog; Import: pick a CSV/XLSX → dry-run preview (report) → apply
// (report). The page itself is gated on `product_view` — the same scope
// the nav entry uses — and each section renders only with its own scope
// (`export_data`, `product_create`), while the backend enforces the
// scopes again on every request: a hidden button is never the security
// boundary (§10).
//
// Every user-visible string goes through AppStrings.t; format/scope/
// policy labels are existing keys (`export_csv`, `dt_policy_*`, ...).
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../core/widgets/page_title.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/status_chip.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../../network/byte_download.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';

class DataTransferScreen extends ConsumerStatefulWidget {
  const DataTransferScreen({super.key});

  @override
  ConsumerState<DataTransferScreen> createState() =>
      _DataTransferScreenState();
}

class _DataTransferScreenState extends ConsumerState<DataTransferScreen> {
  final TextEditingController _search = TextEditingController();

  String _format = 'csv';
  String _scope = 'all';
  String _status = 'active';
  String _policy = 'skip';

  bool _exportBusy = false;
  bool _importBusy = false;

  Uint8List? _fileBytes;
  String? _filePath;
  String? _fileName;

  /// Inline "choose a file first" note — set without any network call.
  String? _fileError;

  /// Last import report (preview or applied), rendered as a card.
  Map<String, dynamic>? _report;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _loc() => ref.read(localeProvider).flutterLocale.languageCode;

  Dio get _dio => ref.read(apiClientProvider).dio;

  String _messageOf(DioException e) {
    final licenseKey = licenseErrorKeyFrom(e);
    if (licenseKey != null) return AppStrings.t(licenseKey, _loc());
    final message = backendErrorMessage(e);
    if (message != null) return message;
    if (isConnectionError(e)) return AppStrings.t('network_error_retry', _loc());
    return AppStrings.t('api_error_retry', _loc());
  }

  // -------------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------------

  Future<void> _export() async {
    final loc = _loc();
    setState(() {
      _exportBusy = true;
      _fileError = null;
    });
    try {
      final response = await _dio.post<Uint8List>(
        '/api/v1/products/export',
        data: <String, dynamic>{
          'format': _format,
          'scope': _scope,
          'status': _status,
          if (_scope == 'filtered' && _search.text.trim().isNotEmpty)
            'search': _search.text.trim(),
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = bytesOfResponse(response.data);
      final fileName = filenameFromDisposition(
        response.headers.value('content-disposition'),
        'products.$_format',
      );
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: AppStrings.t('dt_export_run', loc),
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted || path == null) return; // cancel is neutral (§16.2)
      showPosToast(
        context,
        message: AppStrings.t('dt_export_success', loc),
        detail: fileName,
        kind: PosToastKind.success,
        key: const Key('data-transfer-toast'),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('dt_export_failed', loc),
        detail: _messageOf(decodeByteErrorEnvelope(e)),
        kind: PosToastKind.error,
        key: const Key('data-transfer-toast'),
      );
    } on Object {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('dt_export_failed', loc),
        kind: PosToastKind.error,
        key: const Key('data-transfer-toast'),
      );
    } finally {
      if (mounted) setState(() => _exportBusy = false);
    }
  }

  // -------------------------------------------------------------------------
  // Import
  // -------------------------------------------------------------------------

  Future<void> _pickFile() async {
    final loc = _loc();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['csv', 'xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return; // cancelled
    final picked = result.files.first;
    if (!mounted) return;
    setState(() {
      _fileBytes = picked.bytes;
      _filePath = picked.path;
      _fileName = picked.name;
      _fileError = (picked.bytes == null && picked.path == null)
          ? AppStrings.t('dt_no_file', loc)
          : null;
      _report = null;
    });
  }

  Future<MultipartFile?> _pickedMultipartFile() async {
    final name = _fileName;
    if (name == null) return null;
    final bytes = _fileBytes;
    if (bytes != null) return MultipartFile.fromBytes(bytes, filename: name);
    final path = _filePath;
    if (path != null) return await MultipartFile.fromFile(path, filename: name);
    return null;
  }

  Future<void> _runImport({required bool dryRun}) async {
    final loc = _loc();
    if (_fileName == null || (_fileBytes == null && _filePath == null)) {
      setState(() => _fileError = AppStrings.t('dt_no_file', loc));
      return;
    }
    setState(() {
      _fileError = null;
      _importBusy = true;
    });
    try {
      final multipart = await _pickedMultipartFile();
      if (multipart == null) {
        setState(() {
          _fileError = AppStrings.t('dt_no_file', loc);
          _importBusy = false;
        });
        return;
      }
      final response = await _dio.post(
        '/api/v1/products/import',
        data: FormData.fromMap(<String, dynamic>{
          'file': multipart,
          'dry_run': dryRun ? 'true' : 'false',
          'on_conflict': _policy,
        }),
      );
      final data = response.data;
      if (!mounted) return;
      setState(() {
        _report = data is Map<String, dynamic> ? data : null;
        _importBusy = false;
      });
      if (!dryRun) {
        showPosToast(
          context,
          message: AppStrings.t('dt_apply_success', loc),
          kind: PosToastKind.success,
          key: const Key('data-transfer-toast'),
        );
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _importBusy = false);
      showPosToast(
        context,
        message: AppStrings.t(
          dryRun ? 'dt_preview_failed' : 'dt_apply_failed',
          loc,
        ),
        detail: _messageOf(e),
        kind: PosToastKind.error,
        key: const Key('data-transfer-toast'),
      );
    } on Object {
      if (!mounted) return;
      setState(() => _importBusy = false);
      showPosToast(
        context,
        message: AppStrings.t(
          dryRun ? 'dt_preview_failed' : 'dt_apply_failed',
          loc,
        ),
        kind: PosToastKind.error,
        key: const Key('data-transfer-toast'),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Fields
  // -------------------------------------------------------------------------

  Widget _scopeField(String loc) => DropdownButtonFormField<String>(
        // ValueKey: the field is rebuilt when the value changes so the
        // displayed item follows the state (`initialValue` alone only
        // seeds the first build) — same pattern as Reports presets.
        key: ValueKey<String>('dt-scope-$_scope'),
        initialValue: _scope,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('dt_export_scope', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'all',
            child: Text(
              AppStrings.t('dt_export_scope_all', loc),
              key: const Key('dt-scope-item-all'),
            ),
          ),
          DropdownMenuItem(
            value: 'filtered',
            child: Text(
              AppStrings.t('dt_export_scope_filtered', loc),
              key: const Key('dt-scope-item-filtered'),
            ),
          ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _scope = value);
        },
      );

  Widget _formatField(String loc) => DropdownButtonFormField<String>(
        key: ValueKey<String>('dt-format-$_format'),
        initialValue: _format,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('dt_export_format', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'csv',
            child: Text(
              AppStrings.t('export_csv', loc),
              key: const Key('dt-format-item-csv'),
            ),
          ),
          DropdownMenuItem(
            value: 'xlsx',
            child: Text(
              AppStrings.t('export_xlsx', loc),
              key: const Key('dt-format-item-xlsx'),
            ),
          ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _format = value);
        },
      );

  Widget _statusField(String loc) => DropdownButtonFormField<String>(
        key: ValueKey<String>('dt-status-$_status'),
        initialValue: _status,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('status', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'active',
            child: Text(
              AppStrings.t('active', loc),
              key: const Key('dt-status-item-active'),
            ),
          ),
          DropdownMenuItem(
            value: 'archived',
            child: Text(
              AppStrings.t('archived', loc),
              key: const Key('dt-status-item-archived'),
            ),
          ),
          DropdownMenuItem(
            value: 'all',
            child: Text(
              AppStrings.t('all', loc),
              key: const Key('dt-status-item-all'),
            ),
          ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _status = value);
        },
      );

  Widget _policyField(String loc, bool canUpdate) =>
      DropdownButtonFormField<String>(
        key: ValueKey<String>('dt-policy-$_policy'),
        initialValue: _policy,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('dt_import_policy', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'skip',
            child: Text(
              AppStrings.t('dt_policy_skip', loc),
              key: const Key('dt-policy-item-skip'),
            ),
          ),
          // `update` needs `product_update` on the backend too — never
          // offer a choice the server would reject (§10).
          if (canUpdate)
            DropdownMenuItem(
              value: 'update',
              child: Text(
                AppStrings.t('dt_policy_update', loc),
                key: const Key('dt-policy-item-update'),
              ),
            ),
          DropdownMenuItem(
            value: 'reject',
            child: Text(
              AppStrings.t('dt_policy_reject', loc),
              key: const Key('dt-policy-item-reject'),
            ),
          ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _policy = value);
        },
      );

  // -------------------------------------------------------------------------
  // Sections
  // -------------------------------------------------------------------------

  Widget _exportCard(String loc) {
    return Card(
      key: const Key('data-transfer-export'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: AppStrings.t('dt_export_title', loc),
              titleKey: 'dt_export_title',
              icon: Icons.upload_file,
              dense: true,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(width: 210, child: _scopeField(loc)),
                SizedBox(width: 170, child: _formatField(loc)),
                SizedBox(width: 150, child: _statusField(loc)),
                if (_scope == 'filtered')
                  SizedBox(
                    width: 230,
                    child: TextField(
                      key: const Key('data-transfer-search'),
                      controller: _search,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('search', loc),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search, size: 18),
                      ),
                    ),
                  ),
                FilledButton.icon(
                  key: const Key('data-transfer-export-go'),
                  onPressed: _exportBusy ? null : _export,
                  icon: _exportBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(AppStrings.t('dt_export_run', loc)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _importCard(String loc, bool canUpdate) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('data-transfer-import'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: AppStrings.t('dt_import_title', loc),
              titleKey: 'dt_import_title',
              icon: Icons.upload_file,
              dense: true,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('data-transfer-pick'),
                  onPressed: _importBusy ? null : _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: Text(AppStrings.t('dt_import_pick', loc)),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    _fileName ?? AppStrings.t('dt_import_file', loc),
                    key: const Key('data-transfer-file'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _fileName == null
                        ? theme.textTheme.bodySmall
                        : theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(width: 240, child: _policyField(loc, canUpdate)),
                OutlinedButton(
                  key: const Key('data-transfer-preview'),
                  onPressed: _importBusy ? null : () => _runImport(dryRun: true),
                  child: Text(AppStrings.t('dt_import_dry_run', loc)),
                ),
                FilledButton(
                  key: const Key('data-transfer-apply'),
                  onPressed:
                      _importBusy ? null : () => _runImport(dryRun: false),
                  child: Text(AppStrings.t('dt_import_apply', loc)),
                ),
              ],
            ),
            if (_fileError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _fileError!,
                  key: const Key('data-transfer-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_importBusy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (_report != null) ...[
              const SizedBox(height: 16),
              _reportCard(loc),
            ],
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Import report
  // -------------------------------------------------------------------------

  static int _asInt(Object? value) => value is num ? value.toInt() : 0;

  Widget _reportCard(String loc) {
    final theme = Theme.of(context);
    final report = _report!;
    final total = _asInt(report['total_rows']);
    final created = _asInt(report['created']);
    final updated = _asInt(report['updated']);
    final skipped = _asInt(report['skipped']);
    final failed = _asInt(report['failed']);
    final valid = created + updated + skipped;
    final dryRun = report['dry_run'] == true;
    final filename = '${report['filename'] ?? ''}';

    final unmapped = ((report['unmapped_columns'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final warnings = ((report['warnings'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false);
    final rows = ((report['rows'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    return Card(
      key: const Key('import-report'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  AppStrings.t('dt_report_title', loc),
                  key: const Key('import-report-title'),
                  style: theme.textTheme.titleMedium,
                ),
                if (dryRun)
                  StatusChip(
                    label: AppStrings.t('preview', loc),
                    tone: StatusTone.info,
                    dense: true,
                    testKey: const Key('import-report-preview'),
                  ),
                if (filename.isNotEmpty)
                  StatusChip(
                    label: filename,
                    tone: StatusTone.neutral,
                    dense: true,
                    testKey: const Key('import-report-file'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('${AppStrings.t('label_total', loc)}: $total'),
                Text('${AppStrings.t('dt_rows_valid', loc)}: $valid'),
                Text('${AppStrings.t('dt_rows_invalid', loc)}: $failed'),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('${AppStrings.t('audit_action_create', loc)}: $created'),
                Text('${AppStrings.t('audit_action_update', loc)}: $updated'),
                Text('${AppStrings.t('dt_policy_skip', loc)}: $skipped'),
                Text('${AppStrings.t('error', loc)}: $failed'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              AppStrings.t('dt_mapping_note', loc),
              key: const Key('import-report-mapping-note'),
              style: theme.textTheme.bodySmall,
            ),
            if (unmapped.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${AppStrings.t('warning', loc)}: ${unmapped.join(', ')}',
                  key: const Key('import-report-unmapped'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  key: const Key('import-report-warnings'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final warning in warnings)
                      Text(
                        '${AppStrings.t('warning', loc)}: $warning',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            if (rows.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  height: (rows.length * 40).clamp(40.0, 280.0).toDouble(),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemExtent: 40,
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        _reportRow(rows[index], loc),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _reportRow(Map<String, dynamic> row, String loc) {
    final theme = Theme.of(context);
    final (String labelKey, StatusTone tone) = switch (row['action']) {
      'create' => ('audit_action_create', StatusTone.success),
      'update' => ('audit_action_update', StatusTone.info),
      'skip' => ('dt_policy_skip', StatusTone.neutral),
      _ => ('error', StatusTone.error),
    };
    final name = '${row['name'] ?? row['barcode'] ?? ''}';
    final messages = ((row['messages'] as List?) ?? const [])
        .whereType<String>()
        .join(' · ');
    return Container(
      key: Key('import-row-${row['row']}'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '#${row['row']}',
              key: Key('import-row-number-${row['row']}'),
              style: theme.textTheme.labelSmall,
            ),
          ),
          StatusChip(
            label: AppStrings.t(labelKey, loc),
            tone: tone,
            dense: true,
            testKey: Key('import-row-action-${row['row']}'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (messages.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                messages,
                key: Key('import-row-messages-${row['row']}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Page
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('product_view'));
    final canExport = ref.watch(hasPermissionProvider('export_data'));
    final canImport = ref.watch(hasPermissionProvider('product_create'));
    final canUpdate = ref.watch(hasPermissionProvider('product_update'));

    if (!canView) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          key: const Key('data-transfer-denied'),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageTitle(
            title: AppStrings.t('nav_data_transfer', loc),
            titleKey: const Key('data-transfer-title'),
          ),
          const SizedBox(height: 4),
          Text(
            AppStrings.t('dt_hint', loc),
            key: const Key('data-transfer-hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (canExport) _exportCard(loc),
          if (canExport && canImport) const SizedBox(height: 16),
          if (canImport) _importCard(loc, canUpdate),
          if (!canExport && !canImport)
            Text(
              AppStrings.t('permission_denied', loc),
              key: const Key('data-transfer-denied'),
            ),
        ],
      ),
    );
  }
}
