// Invoice detail dialog (Phase 8 facturation): historical lines,
// server totals, amount in words, edit (mutable fields only) and PDF
// download actions.
//
// No delete / void: historical fiscal documents are never deleted by
// the application (Phase 0 rule). The printed PDF is always the
// server-rendered A4 (POST /factures/{id}/pdf).
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/byte_download.dart';
import '../auth/auth_provider.dart' show apiClientProvider;
import '../pos/pos_toast.dart';
import '../pos/pos_providers.dart' show posDeviceIdProvider;
import 'facturation_error.dart';
import 'facturation_format.dart';
import 'facturation_models.dart';
import 'facturation_providers.dart';
import 'invoice_form_dialog.dart';

String _timestampOf(DateTime? value) {
  if (value == null) return '';
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final h = value.hour.toString().padLeft(2, '0');
  final min = value.minute.toString().padLeft(2, '0');
  final s = value.second.toString().padLeft(2, '0');
  return '${value.year}-$m-$d $h:$min:$s';
}

Future<void> showInvoiceDetailDialog(
  BuildContext context, {
  required String documentId,
}) {
  return showDialog(
    context: context,
    builder: (_) => InvoiceDetailDialog(documentId: documentId),
  );
}

class InvoiceDetailDialog extends ConsumerStatefulWidget {
  final String documentId;

  const InvoiceDetailDialog({super.key, required this.documentId});

  @override
  ConsumerState<InvoiceDetailDialog> createState() =>
      _InvoiceDetailDialogState();
}

class _InvoiceDetailDialogState extends ConsumerState<InvoiceDetailDialog> {
  bool _exporting = false;

  Future<void> _reload() async {
    ref
        .read(facturationDetailProvider(widget.documentId).notifier)
        .load(silent: true);
    ref.read(facturationProvider.notifier).refresh();
  }

  Future<void> _edit(InvoiceDocumentModel doc) async {
    await showInvoiceFormDialog(context, document: doc);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _downloadPdf(
    InvoiceDocumentModel doc,
    String loc, {
    String? pdfLocale,
  }) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    String? deviceId;
    try {
      deviceId = await ref.read(posDeviceIdProvider.future);
    } catch (_) {
      deviceId = null;
    }
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.post<List<int>>(
        '$kFacturesPath/${doc.id}/pdf',
        queryParameters: {'locale': pdfLocale ?? loc},
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, dynamic>{
            if (deviceId != null && deviceId.isNotEmpty)
              'X-Device-ID': deviceId,
          },
        ),
      );
      final bytes = bytesOfResponse(response.data);
      final fileName = filenameFromDisposition(
        response.headers.value('content-disposition'),
        '${doc.number}.pdf',
      );
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: AppStrings.t('export_pdf', loc),
        fileName: fileName,
        bytes: bytes,
      );
      if (path == null || !mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('export_done', loc),
        detail: fileName,
        kind: PosToastKind.success,
        key: const Key('invoice-pdf-toast'),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      final error = facturationApiError(decodeByteErrorEnvelope(e), loc);
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('invoice-pdf-error-toast'),
      );
    } on Object catch (_) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('export_failed', loc),
        kind: PosToastKind.error,
        key: const Key('invoice-pdf-error-toast'),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final pdfLocale = ref.watch(effectiveInvoiceLanguageProvider);
    final detail = ref.watch(facturationDetailProvider(widget.documentId));

    return AlertDialog(
      key: const Key('invoice-detail-dialog'),
      title: Text(
        AppStrings.t('document_details', loc),
        key: const Key('invoice-detail-title'),
      ),
      content: SizedBox(
        width: 760,
        child: detail.when(
          loading: () => const SizedBox(
            height: 200,
            child: Center(
              key: Key('invoice-detail-loading'),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (error, _) => SizedBox(
            height: 200,
            child: Center(
              key: const Key('invoice-detail-error'),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(facturationApiMessage(error, loc)),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    key: const Key('invoice-detail-retry'),
                    onPressed: () => ref
                        .read(
                          facturationDetailProvider(widget.documentId).notifier,
                        )
                        .load(),
                    child: Text(AppStrings.t('retry', loc)),
                  ),
                ],
              ),
            ),
          ),
          data: (doc) {
            if (doc == null) {
              return SizedBox(
                height: 200,
                child: Center(
                  key: const Key('invoice-detail-empty'),
                  child: Text(AppStrings.t('document_not_found', loc)),
                ),
              );
            }
            return SingleChildScrollView(
              key: const Key('invoice-detail-body'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Identity ────────────────────────────────────
                  Row(
                    children: [
                      Chip(
                        key: const Key('invoice-detail-doctype'),
                        label: Text(
                          AppStrings.t(
                            'doc_type_${doc.docType.toLowerCase()}',
                            loc,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          doc.number,
                          key: const Key('invoice-detail-number'),
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    [
                      '${AppStrings.t('document_date', loc)}: ${formatDisplayDate(doc.documentDate, loc)}',
                      '${AppStrings.t('payment_method', loc)}: '
                          '${AppStrings.t('payment_${doc.paymentMethod}', loc)}',
                      if (doc.client != null)
                        '${AppStrings.t('invoice_client', loc)}: ${doc.client!.name}',
                      if (doc.createdAt != null)
                        _timestampOf(doc.createdAt),
                    ].join('\n'),
                    key: const Key('invoice-detail-meta'),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (doc.notes != null && doc.notes!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${AppStrings.t('note', loc)}: ${doc.notes}',
                      key: const Key('invoice-detail-notes'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  // ── Lines table ─────────────────────────────────
                  Text(
                    AppStrings.t('lines', loc),
                    key: const Key('invoice-detail-lines-label'),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      key: const Key('invoice-detail-lines'),
                      columns: [
                      DataColumn(
                        label: Text(AppStrings.t('description', loc)),
                      ),
                      DataColumn(
                        label: Text(AppStrings.t('quantity', loc)),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(AppStrings.t('unit_price', loc)),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(AppStrings.t('tva_rate', loc)),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(AppStrings.t('discount_pct', loc)),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(AppStrings.t('total_ht', loc)),
                        numeric: true,
                      ),
                    ],
                    rows: [
                      for (final line in doc.lines)
                        DataRow(
                          key: ValueKey('invoice-detail-line-${line.id}'),
                          cells: [
                            DataCell(Text(line.description)),
                            DataCell(Text(formatMoney(line.quantity))),
                            DataCell(
                              Text(formatDisplayMoney(line.unitPriceHt, loc)),
                            ),
                            DataCell(Text('${formatMoney(line.tvaRate)}%')),
                            DataCell(Text('${formatMoney(line.discountPct)}%')),
                            DataCell(
                              Text(formatDisplayMoney(line.totalHt, loc)),
                            ),
                          ],
                        ),
                    ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ── Totals ──────────────────────────────────────
                  Material(
                    key: const Key('invoice-detail-totals'),
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          _row(
                            theme,
                            loc,
                            'total_ht',
                            formatDisplayMoney(doc.totals.totalHt, loc),
                          ),
                          _row(
                            theme,
                            loc,
                            'total_tva',
                            formatDisplayMoney(doc.totals.totalTva, loc),
                          ),
                          _row(
                            theme,
                            loc,
                            'total_ttc',
                            formatDisplayMoney(doc.totals.totalTtc, loc),
                          ),
                          if (doc.showTimbre)
                            _row(
                              theme,
                              loc,
                              'timbre',
                              formatDisplayMoney(doc.totals.timbre, loc),
                            ),
                          _row(
                            theme,
                            loc,
                            'net_a_payer',
                            formatDisplayMoney(doc.totals.netAPayer, loc),
                            emphasis: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (doc.showAmountWords && doc.amountInWords.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      doc.amountInWords,
                      key: const Key('invoice-detail-words'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('invoice-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        if (detail.hasValue && detail.value != null) ...[
          OutlinedButton.icon(
            key: const Key('invoice-detail-edit'),
            onPressed: _exporting
                ? null
                : () => _edit(detail.value as InvoiceDocumentModel),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: Text(AppStrings.t('edit', loc)),
          ),
          ElevatedButton.icon(
            key: const Key('invoice-detail-pdf'),
            onPressed: _exporting
                ? null
                : () => _downloadPdf(
                      detail.value as InvoiceDocumentModel,
                      loc,
                      pdfLocale: pdfLocale,
                    ),
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(AppStrings.t('export_pdf', loc)),
          ),
        ],
      ],
    );
  }

  Widget _row(
    ThemeData theme,
    String loc,
    String labelKey,
    String value, {
    bool emphasis = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            AppStrings.t(labelKey, loc),
            style: emphasis ? theme.textTheme.titleSmall : null,
          ),
          Text(
            value,
            key: Key('invoice-detail-total-$labelKey'),
            style: emphasis
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
