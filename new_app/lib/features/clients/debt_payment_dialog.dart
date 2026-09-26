// Record-debt-payment dialog (Phase 9).
//
// Client-side mirrors of the backend rules (same legacy-verified
// semantics): reject <= 0, reject > outstanding balance (no negative
// balance / advance), exact decimal math via moneyToMilli (no floats).
// A per-dialog client_request_id makes double-click / network-retry
// submissions idempotent end to end.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'clients_providers.dart';
import 'customer_models.dart';

/// Returns the payment result, or null when the dialog was dismissed.
Future<DebtPaymentResult?> showDebtPaymentDialog(
  BuildContext context, {
  required CustomerModel customer,
}) {
  return showDialog(
    context: context,
    builder: (_) => DebtPaymentDialog(customer: customer),
  );
}

class DebtPaymentDialog extends ConsumerStatefulWidget {
  final CustomerModel customer;

  const DebtPaymentDialog({super.key, required this.customer});

  @override
  ConsumerState<DebtPaymentDialog> createState() => _DebtPaymentDialogState();
}

class _DebtPaymentDialogState extends ConsumerState<DebtPaymentDialog> {
  late final TextEditingController _amount;
  late final TextEditingController _note;

  late final String _clientRequestId;
  bool _submitting = false;
  String? _error;
  String? _errorDetail;

  int get _balanceMilli => moneyToMilli(widget.customer.balance) ?? 0;

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
    final result = await ref.read(debtPaymentProvider).pay(
          widget.customer.id,
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
    if (milli == null || milli <= 0) return AppStrings.t('invalid_amount', loc);
    if (milli > _balanceMilli) {
      return AppStrings.t('debt_payment_exceeds', loc);
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
      key: const Key('debt-payment-dialog'),
      title: Text(
        AppStrings.t('record_debt_payment', loc),
        key: const Key('debt-payment-title'),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.customer.name} · '
              '${AppStrings.t('balance', loc)}: '
              '${formatMoney(widget.customer.balance)}',
              key: const Key('debt-payment-balance'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('debt-amount-field'),
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
                  key: const Key('debt-pay-all'),
                  tooltip: AppStrings.t('pay_all', loc),
                  icon: const Icon(Icons.all_inclusive),
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                            _amount.text = formatMoney(
                              widget.customer.balance,
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
              key: const Key('debt-note-field'),
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
                key: const Key('debt-remaining'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (localError != null) ...[
              const SizedBox(height: 8),
              Text(
                localError,
                key: const Key('debt-amount-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('debt-payment-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              if (_errorDetail != null && _errorDetail!.isNotEmpty)
                Text(
                  _errorDetail!,
                  key: const Key('debt-payment-error-detail'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('debt-payment-cancel'),
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('debt-pay-submit'),
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
