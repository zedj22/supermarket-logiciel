// Return creation dialog (Phase 12, GATE 22) — LINKED (invoice) returns.
//
// Opened from invoice detail with the sale already in hand. Remaining
// quantity per source line is DERIVED FROM SERVER DATA (sold from the
// invoice, already returned from GET /api/v1/returns?sale_id=...) and the
// quantity input STARTS at the remaining returnable quantity — a
// previously partially returned line starts at what is left, a fully
// returned line starts disabled at 0 (Phase 12 fix round 1). The refund
// money is NOT estimated here: the server prices every line from the
// persisted sale economics (GATE 5) and the split is shown from the
// authoritative response.
//
// Reason is OPTIONAL (product-owner decision): blank = no reason; the
// server accepts omitted/null/blank. Void reason stays mandatory and is
// collected by return_void_dialog.dart instead.
//
// One `client_request_id` per dialog open makes double-submit and retry
// idempotent (GATE 16): a replay returns the original document.
//
// Independent multi-product returns live in return_products_dialog.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_models.dart';
import 'return_models.dart';
import 'return_providers.dart';

/// Opens the LINKED return dialog for one invoice.
Future<ReturnCreateResult?> showReturnCreateDialog(
  BuildContext context, {
  required SaleDetail sale,
}) {
  return showDialog<ReturnCreateResult>(
    context: context,
    builder: (_) => ReturnCreateDialog(sale: sale),
  );
}

class ReturnCreateDialog extends ConsumerStatefulWidget {
  final SaleDetail sale;

  const ReturnCreateDialog({super.key, required this.sale});

  @override
  ConsumerState<ReturnCreateDialog> createState() =>
      _ReturnCreateDialogState();
}

class _ReturnCreateDialogState extends ConsumerState<ReturnCreateDialog> {
  late final String _clientRequestId;
  final _note = TextEditingController();
  final Map<String, TextEditingController> _qty = {};

  String _reason = '';
  List<ReturnDoc> _existing = const [];

  bool _loading = false;
  bool _submitting = false;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _loadExisting();
  }

  @override
  void dispose() {
    _note.dispose();
    for (final controller in _qty.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _qtyFor(String key) {
    return _qty.putIfAbsent(key, () => TextEditingController());
  }

  // -------------------------------------------------------------------------
  // Data
  // -------------------------------------------------------------------------

  Future<void> _loadExisting() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (items, error) =
        await ref.read(returnsApiProvider).forSale(widget.sale.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (error != null) {
        _error = error.message;
        _errorDetail = error.detail;
      } else {
        _existing = items ?? const [];
      }
      _initializeQuantities();
    });
  }

  /// Initialize every editable quantity to the REMAINING returnable
  /// quantity (sold − already returned), never to the raw sold quantity
  /// when prior returns exist. Never overwrites an operator edit.
  void _initializeQuantities() {
    for (final line in _returnableLines) {
      final controller = _qtyFor('line-${line.id}');
      if (controller.text.isNotEmpty) continue;
      controller.text = _fmtQty(_remaining(line));
    }
  }

  // -------------------------------------------------------------------------
  // Derived (server data only)
  // -------------------------------------------------------------------------

  /// Lines that CAN be returned: product lines and charged pack summary
  /// lines. Pack component lines are hidden — the server rejects them
  /// (`RETURN_LINE_INVALID`) because a pack is returned whole.
  List<SaleDetailLine> get _returnableLines {
    return widget.sale.lines.where((line) {
      if (line.packId == null || line.packId!.isEmpty) return true;
      return line.productId.isEmpty; // pack summary (charged) line
    }).toList();
  }

  double _returnedFor(String saleLineId) {
    var total = 0.0;
    for (final doc in _existing) {
      for (final line in doc.lines) {
        if (line.saleLineId != saleLineId) continue;
        total += double.tryParse(line.quantity) ?? 0;
      }
    }
    return total;
  }

  /// Remaining returnable quantity in the source line's own unit.
  double _remaining(SaleDetailLine line) {
    final sold = double.tryParse(line.quantity) ?? 0;
    final returned = _returnedFor(line.id);
    final left = sold - returned;
    return left > 0 ? left : 0;
  }

  // -------------------------------------------------------------------------
  // Validation + submit
  // -------------------------------------------------------------------------

  String? _localValidation(String loc) {
    var any = false;
    for (final line in _returnableLines) {
      final text = _qtyFor('line-${line.id}').text.trim();
      if (text.isEmpty) continue;
      final qty = double.tryParse(text);
      if (qty == null || qty < 0) return AppStrings.t('invalid_qty', loc);
      if (qty == 0) continue;
      if (qty > _remaining(line) + 1e-9) {
        return AppStrings.t('return_qty_exceeds_sold', loc);
      }
      any = true;
    }
    if (!any) return AppStrings.t('return_no_quantity', loc);
    return null;
  }

  Map<String, dynamic> _payload() {
    final note = _note.text.trim();
    final lines = <Map<String, dynamic>>[];
    for (final line in _returnableLines) {
      final text = _qtyFor('line-${line.id}').text.trim();
      if (text.isEmpty) continue;
      final qty = double.tryParse(text) ?? 0;
      if (qty <= 0) continue;
      lines.add({'sale_line_id': line.id, 'quantity': text});
    }
    return {
      'client_request_id': _clientRequestId,
      'sale_id': widget.sale.id,
      // Reason is optional: blank is simply omitted (no fake default).
      if (_reason.trim().isNotEmpty) 'reason': _reason.trim(),
      if (note.isNotEmpty) 'note': note,
      'lines': lines,
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final problem = _localValidation(loc);
    if (problem != null) {
      setState(() {
        _error = problem;
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _errorDetail = null;
    });

    final (result, error) = await ref
        .read(returnsApiProvider)
        .create(payload: _payload());

    if (!mounted) return;
    if (result == null) {
      setState(() {
        _submitting = false;
        _error = error?.message;
        _errorDetail = error?.detail;
      });
      return;
    }
    Navigator.pop(context, result);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('return-create-dialog'),
      title: Text(
        AppStrings.t('return_mode_linked', loc),
        key: const Key('return-create-title'),
      ),
      content: SizedBox(
        width: 620,
        height: 480,
        child: _loading
            ? const Center(
                key: Key('return-create-loading'),
                child: CircularProgressIndicator(),
              )
            : SingleChildScrollView(
                key: const Key('return-create-body'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _invoiceHeader(theme, loc),
                    const SizedBox(height: 12),
                    _lineList(theme, loc),
                    const SizedBox(height: 12),
                    _reasonField(theme, loc),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('return-note-input'),
                      controller: _note,
                      maxLength: 2000,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(2000),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t('return_note', loc),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        key: const Key('return-create-error'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    if (_errorDetail != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _errorDetail!,
                        key: const Key('return-create-error-detail'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const Key('return-cancel'),
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('return-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('return_submit', loc)),
        ),
      ],
    );
  }

  Widget _invoiceHeader(ThemeData theme, String loc) {
    final sale = widget.sale;
    final voided = sale.voidedAt != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                sale.invoiceNumber,
                key: const Key('return-create-invoice'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (voided)
              Chip(
                key: const Key('return-create-voided'),
                label: Text(AppStrings.t('status_void', loc)),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t('return_lines', loc),
          key: const Key('return-lines-title'),
          style: theme.textTheme.titleSmall,
        ),
      ],
    );
  }

  Widget _lineList(ThemeData theme, String loc) {
    final lines = _returnableLines;
    if (lines.isEmpty) {
      return Text(
        AppStrings.t('return_no_lines', loc),
        key: const Key('return-no-lines'),
        style: theme.textTheme.bodyMedium,
      );
    }
    return Column(
      children: [
        for (var i = 0; i < lines.length; i++)
          _lineRow(theme, loc, lines[i], i),
      ],
    );
  }

  Widget _lineRow(
    ThemeData theme,
    String loc,
    SaleDetailLine line,
    int index,
  ) {
    final sold = double.tryParse(line.quantity) ?? 0;
    final returned = _returnedFor(line.id);
    final remaining = _remaining(line);
    final disabled = remaining <= 0;
    final controller = _qtyFor('line-${line.id}');
    final title = (line.variantName != null && line.variantName!.isNotEmpty)
        ? '${line.productName} (${line.variantName})'
        : line.productName;
    final unit = (line.sellingUnitName != null &&
            line.sellingUnitName!.isNotEmpty)
        ? line.sellingUnitName!
        : AppStrings.unitLabel(line.productUnit, loc);

    return Padding(
      key: Key('return-line-$index'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                // Bidi: Arabic labels stay natural; each (possibly
                // grouped) quantity is one LTR isolate (a forced-LTR
                // whole-string still reverses digits after an Arabic
                // label — W7).
                Text(
                  '${AppStrings.t('return_sold_quantity', loc)}: '
                  '${bidiIsolateLtr(_fmtQty(sold))} $unit',
                  key: Key('return-line-sold-$index'),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${AppStrings.t('return_already', loc)}: '
                  '${bidiIsolateLtr(_fmtQty(returned))} $unit',
                  key: Key('return-line-returned-$index'),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${AppStrings.t('return_returnable', loc)}: '
                  '${bidiIsolateLtr(_fmtQty(remaining))} $unit',
                  key: Key('return-line-remaining-$index'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (disabled)
                  Text(
                    AppStrings.t('return_fully_returned', loc),
                    key: Key('return-line-fully-$index'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              key: Key('return-line-qty-$index'),
              controller: controller,
              enabled: !disabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: '0',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reasonField(ThemeData theme, String loc) {
    return DropdownButtonFormField<String>(
      key: const Key('return-reason-select'),
      initialValue: _reason,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: AppStrings.t('return_reason_optional', loc),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(
            AppStrings.t('return_reason_none', loc),
            key: const Key('return-reason-none'),
          ),
        ),
        for (final reason in kReturnReasons)
          DropdownMenuItem(
            value: reason,
            child: Text(
              AppStrings.t(returnReasonKey(reason), loc),
              key: Key('return-reason-$reason'),
            ),
          ),
      ],
      onChanged: (value) => setState(() {
        _reason = value ?? '';
        _error = null;
      }),
    );
  }

  static String _fmtQty(double value) {
    if (value == value.roundToDouble()) {
      return formatGrouped(value.toInt().toString());
    }
    final fixed = value.toStringAsFixed(3);
    return formatGrouped(
      fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), ''),
    );
  }
}
