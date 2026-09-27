// Purchase editor dialog (Phase 11): create a new purchase or edit an
// existing DRAFT.
//
// Editor owns the draft state: supplier picker, staged lines (each via
// the line dialog), discount / paid / note fields, and a live
// subtotal → total → remaining summary. Totals are DOCUMENT ARITHMETIC
// ONLY (integer milli math, display) — Flutter never computes PMP;
// all valuation comes from the server.
//
// Actions: Save draft (receive=false / PUT) and Save & receive
// (receive=true atomic create, or PUT then POST receive for drafts).
// One client_request_id per dialog open makes retry submissions
// idempotent (POS pendingClientRequestId pattern).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_toast.dart';
import 'purchase_line_dialog.dart';
import 'purchase_models.dart';
import 'purchase_pickers.dart';
import 'purchases_providers.dart';

Future<void> showPurchaseFormDialog(
  BuildContext context, {
  PurchaseModel? draft,
}) {
  return showDialog(
    context: context,
    builder: (_) => PurchaseFormDialog(draft: draft),
  );
}

class PurchaseFormDialog extends ConsumerStatefulWidget {
  final PurchaseModel? draft;

  const PurchaseFormDialog({super.key, this.draft});

  @override
  ConsumerState<PurchaseFormDialog> createState() => _PurchaseFormDialogState();
}

class _PurchaseFormDialogState extends ConsumerState<PurchaseFormDialog> {
  String? _supplierId;
  String? _supplierName;
  final List<DraftLine> _lines = [];

  late final TextEditingController _discount;
  late final TextEditingController _paid;
  late final TextEditingController _note;

  late final String _clientRequestId;
  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.draft != null;

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    _supplierId = draft?.supplierId;
    _supplierName = draft?.supplierName;
    if (draft != null) {
      _lines.addAll(
        draft.lines.map(
          (l) => DraftLine(
            productId: l.productId,
            productName: l.productName,
            variantId: l.variantId,
            purchaseUnitId: l.purchaseUnitId,
            purchaseUnitName: l.purchaseUnitName,
            multiplier: l.unitMultiplier,
            quantity: l.quantity,
            unitCost: l.unitCost,
          ),
        ),
      );
    }
    _discount = TextEditingController(
      text: draft != null && formatMoney(draft.discount) != '0'
          ? formatMoney(draft.discount)
          : '',
    );
    _paid = TextEditingController(
      text: draft != null && formatMoney(draft.paid) != '0'
          ? formatMoney(draft.paid)
          : '',
    );
    _note = TextEditingController(text: draft?.note ?? '');
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  }

  @override
  void dispose() {
    _discount.dispose();
    _paid.dispose();
    _note.dispose();
    super.dispose();
  }

  // ── Document totals (display only) ───────────────────────────────────

  int get _subtotalMilli {
    var sum = 0;
    for (final line in _lines) {
      sum += line.lineTotalMilli;
    }
    return sum;
  }

  int? get _discountMilli {
    final text = _discount.text.trim();
    if (text.isEmpty) return 0;
    return moneyToMilli(text);
  }

  int get _totalMilli {
    final discount = _discountMilli ?? 0;
    final total = _subtotalMilli - discount;
    return total > 0 ? total : 0;
  }

  int? get _paidMilli {
    final text = _paid.text.trim();
    if (text.isEmpty) return 0;
    return moneyToMilli(text);
  }

  int get _remainingMilli {
    final paid = _paidMilli ?? 0;
    final remaining = _totalMilli - paid;
    return remaining > 0 ? remaining : 0;
  }

  // ── Validation ───────────────────────────────────────────────────────

  String? _validate(String loc) {
    if (_supplierId == null || _supplierId!.isEmpty) {
      return AppStrings.t('select_supplier', loc);
    }
    if (_lines.isEmpty) return AppStrings.t('purchase_requires_lines', loc);
    for (final line in _lines) {
      final qty = qtyToMilli(line.quantity);
      if (qty == null || qty <= 0) return AppStrings.t('invalid_qty', loc);
      if (moneyToMilli(line.unitCost) == null) {
        return AppStrings.t('invalid_amount', loc);
      }
      if (line.purchaseUnitId != null && !isWholeQty(line.quantity)) {
        return AppStrings.t('purchase_line_invalid', loc);
      }
    }
    if (_discountMilli == null) return AppStrings.t('invalid_amount', loc);
    if (_paidMilli == null) return AppStrings.t('invalid_amount', loc);
    if ((_discountMilli ?? 0) > _subtotalMilli) {
      return AppStrings.t('discount_exceeds_subtotal', loc);
    }
    if ((_paidMilli ?? 0) > _totalMilli) {
      return AppStrings.t('paid_exceeds_total', loc);
    }
    return null;
  }

  // ── Payload ──────────────────────────────────────────────────────────

  Map<String, dynamic> _payload({required bool receive}) {
    final note = _note.text.trim();
    return {
      'supplier_id': _supplierId,
      'lines': [for (final line in _lines) line.toPayload()],
      'discount': _discount.text.trim().isEmpty ? '0' : _discount.text.trim(),
      'paid': _paid.text.trim().isEmpty ? '0' : _paid.text.trim(),
      if (note.isNotEmpty) 'note': note,
      if (!_isEdit) ...{
        'receive': receive,
        'client_request_id': _clientRequestId,
      },
    };
  }

  // ── Actions ──────────────────────────────────────────────────────────

  Future<void> _submit({required bool receive}) async {
    if (_saving) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final validation = _validate(loc);
    if (validation != null) {
      setState(() {
        _error = validation;
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _errorDetail = null;
    });

    final notifier = ref.read(purchasesProvider.notifier);

    if (!_isEdit) {
      final (purchase, error) = await notifier.create(_payload(
        receive: receive,
      ));
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _saving = false;
          _error = error.message;
          _errorDetail = error.detail;
        });
        return;
      }
      Navigator.pop(context);
      showPosToast(
        context,
        message: AppStrings.t(
          receive ? 'purchase_received' : 'purchase_draft_saved',
          loc,
        ),
        detail: purchase?.invoiceNumber,
        kind: PosToastKind.success,
        key: const Key('purchase-form-success-toast'),
      );
      return;
    }

    // Edit mode: PUT (draft only), then optionally receive.
    final putError = await notifier.update(
      widget.draft!.id,
      _payload(receive: receive),
    );
    if (!mounted) return;
    if (putError != null) {
      setState(() {
        _saving = false;
        _error = putError.message;
        _errorDetail = putError.detail;
      });
      return;
    }
    if (!receive) {
      Navigator.pop(context);
      showPosToast(
        context,
        message: AppStrings.t('purchase_updated', loc),
        kind: PosToastKind.success,
        key: const Key('purchase-form-success-toast'),
      );
      return;
    }

    // Draft saved — now post it atomically. A receive failure leaves
    // the draft saved server-side; surface it as a toast and close.
    final receiveError = await notifier.receive(widget.draft!.id);
    if (!mounted) return;
    Navigator.pop(context);
    if (receiveError == null) {
      showPosToast(
        context,
        message: AppStrings.t('purchase_received', loc),
        kind: PosToastKind.success,
        key: const Key('purchase-form-success-toast'),
      );
    } else {
      showPosToast(
        context,
        message: receiveError.message,
        detail: receiveError.detail,
        kind: PosToastKind.error,
        key: const Key('purchase-form-receive-error-toast'),
      );
    }
  }

  Future<void> _pickSupplier() async {
    final supplier = await showPurchaseSupplierPicker(context);
    if (supplier == null || !mounted) return;
    setState(() {
      _supplierId = supplier.id;
      _supplierName = supplier.name;
      _error = null;
      _errorDetail = null;
    });
  }

  Future<void> _addLine() async {
    final line = await showPurchaseLineDialog(context);
    if (line == null || !mounted) return;
    setState(() {
      _lines.add(line);
      _error = null;
      _errorDetail = null;
    });
  }

  Future<void> _editLine(int index) async {
    final line = await showPurchaseLineDialog(
      context,
      initial: _lines[index],
    );
    if (line == null || !mounted) return;
    setState(() {
      _lines[index] = line;
      _error = null;
      _errorDetail = null;
    });
  }

  void _removeLine(int index) {
    setState(() {
      _lines.removeAt(index);
      _error = null;
      _errorDetail = null;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('purchase-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_purchase' : 'add_purchase', loc),
        key: const Key('purchase-form-title'),
      ),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Supplier row
            Row(
              children: [
                Expanded(
                  child: Text(
                    _supplierName ?? AppStrings.t('select_supplier', loc),
                    key: const Key('purchase-form-supplier'),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('purchase-form-pick-supplier'),
                  onPressed: _saving ? null : _pickSupplier,
                  icon: const Icon(Icons.search, size: 18),
                  label: Text(AppStrings.t('select', loc)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  AppStrings.t('purchase_lines', loc),
                  key: const Key('purchase-form-lines-title'),
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                TextButton.icon(
                  key: const Key('purchase-form-add-line'),
                  onPressed: _saving ? null : _addLine,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(AppStrings.t('add_line', loc)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _lines.isEmpty
                  ? Center(
                      key: const Key('purchase-form-lines-empty'),
                      child: Text(AppStrings.t('purchase_requires_lines', loc)),
                    )
                  : ListView.builder(
                      key: const Key('purchase-form-lines'),
                      itemCount: _lines.length,
                      itemBuilder: (context, index) {
                        final line = _lines[index];
                        final unitLabel = line.purchaseUnitName == null
                            ? ''
                            : ' ×${line.multiplier ?? ''}';
                        return ListTile(
                          key: Key('purchase-form-line-$index'),
                          dense: true,
                          title: Text(
                            line.labelForDisplay ?? '',
                            key: Key('purchase-form-line-name-$index'),
                          ),
                          subtitle: Text(
                            '${line.quantity}$unitLabel × '
                            '${formatMoney(line.unitCost)}',
                            key: Key('purchase-form-line-math-$index'),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                formatMoney(line.lineTotal),
                                key: Key('purchase-form-line-total-$index'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              IconButton(
                                key: Key('purchase-form-line-edit-$index'),
                                tooltip: AppStrings.t('edit', loc),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: _saving
                                    ? null
                                    : () => _editLine(index),
                              ),
                              IconButton(
                                key: Key('purchase-form-line-remove-$index'),
                                tooltip: AppStrings.t('delete', loc),
                                icon:
                                    const Icon(Icons.close, size: 18),
                                onPressed: _saving
                                    ? null
                                    : () => _removeLine(index),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(),
            // Totals + document fields
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SummaryRow(
                        labelKey: 'subtotal',
                        value: formatMoney(milliToMoney(_subtotalMilli)),
                        testKey: 'purchase-form-subtotal',
                      ),
                      TextField(
                        key: const Key('purchase-form-discount'),
                        controller: _discount,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          LengthLimitingTextInputFormatter(15),
                        ],
                        decoration: InputDecoration(
                          labelText: AppStrings.t('discount', loc),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {
                          _error = null;
                          _errorDetail = null;
                        }),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        key: const Key('purchase-form-paid'),
                        controller: _paid,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          LengthLimitingTextInputFormatter(15),
                        ],
                        decoration: InputDecoration(
                          labelText: AppStrings.t('paid', loc),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {
                          _error = null;
                          _errorDetail = null;
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SummaryRow(
                        labelKey: 'total',
                        value: formatMoney(milliToMoney(_totalMilli)),
                        emphasized: true,
                        testKey: 'purchase-form-total',
                      ),
                      _SummaryRow(
                        labelKey: 'remaining',
                        value: formatMoney(milliToMoney(_remainingMilli)),
                        testKey: 'purchase-form-remaining',
                      ),
                      TextField(
                        key: const Key('purchase-form-note'),
                        controller: _note,
                        enabled: !_saving,
                        maxLength: 2000,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('note', loc),
                          counterText: '',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {
                          _error = null;
                          _errorDetail = null;
                        }),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('purchase-form-error'),
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              if (_errorDetail != null && _errorDetail!.isNotEmpty)
                Text(
                  _errorDetail!,
                  key: const Key('purchase-form-error-detail'),
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('purchase-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        OutlinedButton(
          key: const Key('purchase-form-save-draft'),
          onPressed: _saving ? null : () => _submit(receive: false),
          child: Text(AppStrings.t('save_draft', loc)),
        ),
        ElevatedButton(
          key: const Key('purchase-form-save-receive'),
          onPressed: _saving ? null : () => _submit(receive: true),
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('save_and_receive', loc)),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String labelKey;
  final String value;
  final bool emphasized;
  final String testKey;

  const _SummaryRow({
    required this.labelKey,
    required this.value,
    required this.testKey,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    return Padding(
      key: Key(testKey),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            AppStrings.t(labelKey, loc),
            style: emphasized
                ? theme.textTheme.titleSmall
                : theme.textTheme.bodyMedium,
          ),
          Text(
            value,
            key: Key('$testKey-value'),
            style: emphasized
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
          ),
        ],
      ),
    );
  }
}
