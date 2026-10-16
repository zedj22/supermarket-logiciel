// Return detail dialog (Phase 12): header + lines + refund split.
//
// Everything displayed here is what the server persisted — historical
// snapshots on the lines, server-owned money on the header. The document
// is read-only (Phase 12 has no draft/cancel return state, GATE 2).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_toast.dart';
import 'return_models.dart';
import 'return_providers.dart';

/// Loads the document from the API, then shows it.
Future<void> showReturnDetailDialog(
  BuildContext context, {
  required String returnId,
  ReturnDoc? initial,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ReturnDetailDialog(returnId: returnId, initial: initial),
  );
}

class ReturnDetailDialog extends ConsumerStatefulWidget {
  final String returnId;
  final ReturnDoc? initial;

  const ReturnDetailDialog({
    super.key,
    required this.returnId,
    this.initial,
  });

  @override
  ConsumerState<ReturnDetailDialog> createState() =>
      _ReturnDetailDialogState();
}

class _ReturnDetailDialogState extends ConsumerState<ReturnDetailDialog> {
  ReturnDoc? _doc;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _doc = widget.initial;
    if (_doc == null) Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (doc, error) = await ref
        .read(returnsApiProvider)
        .get(widget.returnId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (error != null) {
        _error = error.message;
      } else {
        _doc = doc;
      }
    });
  }

  Future<void> _copyNumber() async {
    final number = _doc?.returnNumber ?? '';
    if (number.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: number));
    if (!mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('return_number_copied', loc),
      kind: PosToastKind.success,
      key: const Key('return-number-copied-toast'),
    );
  }

  String _fmtMoney(String raw) {
    final v = double.tryParse(raw);
    return v == null ? formatGrouped(raw) : formatGroupedFixed(v, 2);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final doc = _doc;

    return AlertDialog(
      key: const Key('return-detail-dialog'),
      title: Text(
        doc?.returnNumber ?? '',
        key: const Key('return-detail-title'),
      ),
      content: SizedBox(
        width: 620,
        height: 460,
        child: _loading
            ? const Center(
                key: Key('return-detail-loading'),
                child: CircularProgressIndicator(),
              )
            : _error != null
                ? Center(
                    key: const Key('return-detail-error'),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : doc == null
                    ? Center(
                        child: Text(AppStrings.t('return_not_found', loc)),
                      )
                    : SingleChildScrollView(
                        key: const Key('return-detail-body'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _header(theme, loc, doc),
                            const SizedBox(height: 8),
                            Text(
                              AppStrings.t('return_lines', loc),
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            for (var i = 0; i < doc.lines.length; i++)
                              _lineRow(theme, loc, doc.lines[i], i),
                            const Divider(height: 16),
                            _moneyRow(
                              theme,
                              loc,
                              'return_refund_total',
                              _fmtMoney(doc.total),
                              const Key('return-detail-total'),
                            ),
                            if ((double.tryParse(doc.discount) ?? 0) > 0)
                              _moneyRow(
                                theme,
                                loc,
                                'discount',
                                _fmtMoney(doc.discount),
                                const Key('return-detail-discount'),
                              ),
                            if (doc.note != null && doc.note!.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '${AppStrings.t('return_note', loc)}: ${doc.note}',
                                key: const Key('return-detail-note'),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
      ),
      actions: [
        TextButton(
          key: const Key('return-detail-copy'),
          onPressed: doc == null ? null : _copyNumber,
          child: Text(AppStrings.t('copy_return_number', loc)),
        ),
        ElevatedButton(
          key: const Key('return-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('close', loc)),
        ),
      ],
    );
  }

  Widget _header(ThemeData theme, String loc, ReturnDoc doc) {
    final reasonLabel = doc.reason.isNotEmpty
        ? AppStrings.t(returnReasonKey(doc.reason), loc)
        : AppStrings.t('return_reason_none', loc);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${AppStrings.t('return_reason', loc)}: $reasonLabel',
          key: const Key('return-detail-reason'),
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          '${AppStrings.t('return_date', loc)}: '
          '${doc.returnDate.toLocal().toString().substring(0, 16)}',
          key: const Key('return-detail-date'),
          style: theme.textTheme.bodySmall,
        ),
        if (doc.invoiceNumber != null && doc.invoiceNumber!.isNotEmpty)
          Text(
            '${AppStrings.t('invoice_number', loc)}: ${doc.invoiceNumber}',
            key: const Key('return-detail-invoice'),
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  Widget _lineRow(
    ThemeData theme,
    String loc,
    ReturnLine line,
    int index,
  ) {
    final unit = (line.sellingUnitName != null &&
            line.sellingUnitName!.isNotEmpty)
        ? line.sellingUnitName!
        : AppStrings.unitLabel(line.productUnit, loc);
    final title = (line.variantName != null && line.variantName!.isNotEmpty)
        ? '${line.productName} (${line.variantName})'
        : line.productName;
    return Padding(
      key: Key('return-detail-line-$index'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                // Bidi: the grouped quantity+unit and the grouped price +
                // currency are each ONE LTR isolate (both would swap in
                // the mixed RTL sentence — W7).
                Text(
                  '${bidiIsolateLtr('${formatGrouped(line.quantity)} $unit')} × '
                  '${bidiIsolateLtr('${_fmtMoney(line.unitPrice)} '
                      '${AppStrings.t('currency', loc)}')}',
                  key: Key('return-detail-line-qty-$index'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          numericText(
            _fmtMoney(line.lineTotal),
            key: Key('return-detail-line-total-$index'),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _moneyRow(
    ThemeData theme,
    String loc,
    String labelKey,
    String value,
    Key key,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(AppStrings.t(labelKey, loc), style: theme.textTheme.bodySmall),
          numericText(value, key: key, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
