// Record-supplier-payment dialog (Phase 11).
//
// Client-side mirrors of the backend rules (legacy-verified): reject
// <= 0, reject > outstanding balance (no negative balance / advance),
// exact decimal math via moneyToMilli (no floats). A per-dialog
// client_request_id makes double-click / network-retry submissions
// idempotent end to end (Phase 9 pattern).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'suppliers_providers.dart';
import 'supplier_models.dart';

/// Returns the payment result, or null when the dialog was dismissed.
Future<SupplierPaymentResult?> showSupplierPaymentDialog(
  BuildContext context, {
  required SupplierModel supplier,
}) {
  return showDialog(
    context: context,
    builder: (_) => SupplierPaymentDialog(supplier: supplier),
  );
}

class SupplierPaymentDialog extends ConsumerStatefulWidget {
  final SupplierModel supplier;

  const SupplierPaymentDialog({super.key, required this.supplier});

  @override
  ConsumerState<SupplierPaymentDialog> createState() =>
      _SupplierPaymentDialogState();
}

class _SupplierPaymentDialogState extends ConsumerState<SupplierPaymentDialog> {
  late final TextEditingController _amount;
  late final TextEditingController _note;

  late final String _clientRequestId;
  bool _submitting = false;
  String? _error;
  String? _errorDetail;

  int get _balanceMilli => moneyToMilli(widget.supplier.balance) ?? 0;

  int? get _amountMilli => moneyToMilli(_amount.text);

  /// Valid when parsed, > 0, and not above the outstanding balance.
  bool get _amountValid {
    final milli = _amountMilli;
    if (milli == null || milli <= 0) return false;
    return milli <= _balanceMilli;
  }

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController();
    _note = TextEditingController();
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_amountValid || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
      _errorDetail = null;
    });

    final note = _note.text.trim();
    final result = await ref.read(supplierPaymentProvider).pay(
          widget.supplier.id,
          {
            'amount': _amount.text.trim(),
            if (note.isNotEmpty) 'note': note,
            'client_request_id': _clientRequestId,
          },
        );

    if (!mounted) return;
    final (payment, error) = result;
    if (payment != null) {
      Navigator.pop(context, payment);
    } else {
      setState(() {
        _submitting = false;
        _error = error?.message;
        _errorDetail = error?.detail;
      });
    }
  }

  String? _localValidation(String loc) {
    final text = _amount.text.trim();
    if (text.isEmpty) return null;
    final milli = _amountMilli;
    if (milli == null || milli <= 0) {
      return AppStrings.t('invalid_amount', loc);
    }
    if (milli > _balanceMilli) {
      return AppStrings.t('supplier_payment_exceeds', loc);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final localError = _localValidation(loc);
    final amountM = _amountMilli;
    final int? remaining =
        amountM != null && amountM > 0 && amountM <= _balanceMilli
            ? _balanceMilli - amountM
            : null;

    return AlertDialog(
      key: const Key('supplier-payment-dialog'),
      title: Text(
        AppStrings.t('record_supplier_payment', loc),
        key: const Key('supplier-payment-title'),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.supplier.name} · '
              '${AppStrings.t('balance', loc)}: '
              '${formatMoney(widget.supplier.balance)}',
              key: const Key('supplier-payment-balance'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('supplier-amount-field'),
              controller: _amount,
              enabled: !_submitting,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                LengthLimitingTextInputFormatter(15),
              ],
              decoration: InputDecoration(
                labelText: AppStrings.t('amount', loc),
                suffixIcon: IconButton(
                  key: const Key('supplier-pay-all'),
                  tooltip: AppStrings.t('pay_all', loc),
                  icon: const Icon(Icons.all_inclusive),
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                            _amount.text = formatMoney(
                              widget.supplier.balance,
                            );
                            _error = null;
                            _errorDetail = null;
                          }),
                ),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('supplier-note-field'),
              controller: _note,
              enabled: !_submitting,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: AppStrings.t('note', loc),
                hintText: AppStrings.t('note_hint', loc),
                counterText: '',
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            if (remaining != null) ...[
              const SizedBox(height: 8),
              Text(
                '${AppStrings.t('remaining_after', loc)}: '
                '${formatMoney(milliToMoney(remaining))}',
                key: const Key('supplier-remaining'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(
                localError,
                key: const Key('supplier-amount-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('supplier-payment-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              if (_errorDetail != null && _errorDetail!.isNotEmpty)
                Text(
                  _errorDetail!,
                  key: const Key('supplier-payment-error-detail'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('supplier-payment-cancel'),
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('supplier-pay-submit'),
          onPressed: (!_amountValid || _submitting) ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('record_payment', loc)),
        ),
      ],
    );
  }
}
