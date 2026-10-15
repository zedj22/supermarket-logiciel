// Payment dialog (F8) — cash / card / partial / credit with live totals.
//
// Server re-validates everything; this dialog enforces client-side rules
// for UX (customer required for partial/credit, paid >= total for cash).
// Escape closes without touching the cart. Checkout retry reuses the same
// client_request_id held by PosCartNotifier.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../loyalty/loyalty_providers.dart';
import 'pos_models.dart';
import 'pos_providers.dart';

/// Display label for a reward percent: `20` → `"20"`, `12.5` → `"12.5"`.
String _percentLabel(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class PaymentDialog extends ConsumerStatefulWidget {
  const PaymentDialog({super.key});

  @override
  ConsumerState<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<PaymentDialog> {
  PaymentMethod _method = PaymentMethod.cash;
  late final TextEditingController _paid;
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill the AMOUNT DUE (total minus the accepted loyalty reward
    // discount) — `_openPayment` settled the server preview first, so
    // this matches exactly what checkout will be validated against.
    final totals = ref.read(posCartProvider).totals;
    _paid = TextEditingController(
      text: PaymentMath.amountDueOf(
        total: totals.total,
        rewardDiscount: _rewardDiscount,
      ).toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _paid.dispose();
    super.dispose();
  }

  /// Accepted reward discount (server preview) for the CURRENT percent +
  /// total; anything else (no customer, stale/failed preview, percent
  /// above the cap) is worth 0 here — the server remains the authority
  /// and a mismatch surfaces as its structured checkout error.
  double get _rewardDiscount {
    final loyalty = ref.read(posLoyaltyProvider);
    return loyalty.previewMatches
        ? loyalty.preview!.rewardDiscount
        : 0.0;
  }

  double get _due => PaymentMath.amountDueOf(
        total: ref.read(posCartProvider).totals.total,
        rewardDiscount: _rewardDiscount,
      );

  double get _paidAmount => PaymentMath.parse(_paid.text);

  String? _validate(PaymentMethod method) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    final canCredit = ref.read(hasPermissionProvider('pos_credit_sale'));
    final canDiscount = ref.read(hasPermissionProvider('pos_discount'));
    final key = PaymentMath.validate(
      method: method,
      total: cart.totals.total,
      paid: method == PaymentMethod.cash || method == PaymentMethod.card
          ? _due
          : _paidAmount,
      hasCustomer: cart.customer != null,
      canDiscount: canDiscount || !cart.hasAnyDiscount,
      canCredit: canCredit,
      rewardDiscount: _rewardDiscount,
    );
    if (key == null) return null;
    return AppStrings.t(key, loc);
  }

  void _selectMethod(PaymentMethod method) {
    setState(() {
      _method = method;
      _error = null;
      if (method == PaymentMethod.cash || method == PaymentMethod.card) {
        _paid.text = _due.toStringAsFixed(2);
      } else if (method == PaymentMethod.credit) {
        _paid.text = '0.00';
      }
    });
  }

  Future<void> _submit() async {
    final err = _validate(_method);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final paid = switch (_method) {
      PaymentMethod.cash || PaymentMethod.card => _due,
      PaymentMethod.credit => 0.0,
      PaymentMethod.partial => _paidAmount,
    };
    final result =
        await ref.read(posCartProvider.notifier).checkout(
              method: _method,
              paid: paid,
              // Percent only — never a money value or a balance; the
              // server re-prices and re-validates the reward.
              loyaltyRewardPercent:
                  ref.read(posLoyaltyProvider).rewardPercent,
            );
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result);
    } else {
      final cart = ref.read(posCartProvider);
      setState(() {
        _submitting = false;
        _error = cart.lastError ??
            AppStrings.t(
              'sale_failed',
              ref.read(localeProvider).flutterLocale.languageCode,
            );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final cart = ref.watch(posCartProvider);
    final totals = cart.totals;
    final canCredit = ref.watch(hasPermissionProvider('pos_credit_sale'));
    final hasCustomer = cart.customer != null;
    // Every money figure below is evaluated against the AMOUNT DUE
    // (`total - accepted reward discount`); with no reward the dialog
    // behaves bit-for-bit like the pre-loyalty one.
    final loyalty = ref.watch(posLoyaltyProvider);
    final rewardDiscount =
        loyalty.previewMatches ? loyalty.preview!.rewardDiscount : 0.0;
    final amountDue = PaymentMath.amountDueOf(
      total: totals.total,
      rewardDiscount: rewardDiscount,
    );
    final change = PaymentMath.changeOf(
      paid: _paidAmount,
      total: totals.total,
      rewardDiscount: rewardDiscount,
    );
    final debt = PaymentMath.debtOf(
      paid: _paidAmount,
      total: totals.total,
      rewardDiscount: rewardDiscount,
    );
    final currency = AppStrings.t('currency', loc);
    // 440 clipped the amount-paid field and the change/debt pair on a
    // 1366px window; the checkout dialog grows with the window but never
    // becomes a portrait strip on a small one.
    final view = MediaQuery.sizeOf(context);
    var width = view.width - 96;
    if (width < 400) width = 400;
    if (width > 560) width = 560;

    return AlertDialog(
      key: const Key('payment-dialog'),
      title: Text(AppStrings.t('payment', loc)),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Totals summary
              _SummaryRow(
                label: AppStrings.t('subtotal_label', loc),
                value: totals.subtotalDisplay,
              ),
              _SummaryRow(
                label: AppStrings.t('invoice_discount', loc),
                value: '-${totals.invoiceDiscountDisplay}',
              ),
              const Divider(),
              _SummaryRow(
                label: AppStrings.t('total_label', loc),
                value: totals.totalDisplay,
                emphasize: true,
              ),
              if (rewardDiscount > 0) ...[
                _SummaryRow(
                  key: const Key('payment-loyalty-redeemed'),
                  label: AppStrings.t('loyalty_redeemed', loc),
                  value: '${_percentLabel(loyalty.rewardPercent)}% '
                      '(${PaymentMath.money(rewardDiscount)} $currency)',
                ),
                _SummaryRow(
                  key: const Key('payment-amount-due'),
                  label: AppStrings.t('amount_due', loc),
                  value: PaymentMath.money(amountDue),
                  emphasize: true,
                  color: theme.colorScheme.primary,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                AppStrings.t('payment_method', loc),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in PaymentMethod.values)
                    ChoiceChip(
                      key: Key('payment-method-${m.apiValue}'),
                      label: Text(switch (m) {
                        PaymentMethod.cash => AppStrings.t('cash', loc),
                        PaymentMethod.card => AppStrings.t('card', loc),
                        PaymentMethod.partial => AppStrings.t('partial', loc),
                        PaymentMethod.credit => AppStrings.t('credit', loc),
                      }),
                      selected: _method == m,
                      onSelected: (m == PaymentMethod.partial ||
                              m == PaymentMethod.credit)
                          ? (selected) {
                              if (!canCredit && selected) {
                                setState(() => _error =
                                    AppStrings.t('permission_credit', loc));
                                return;
                              }
                              if (selected) _selectMethod(m);
                            }
                          : (selected) {
                              if (selected) _selectMethod(m);
                            },
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                switch (_method) {
                  PaymentMethod.cash =>
                    AppStrings.t('payment_method_cash_hint', loc),
                  PaymentMethod.card =>
                    AppStrings.t('payment_method_card_hint', loc),
                  PaymentMethod.partial =>
                    AppStrings.t('payment_method_partial_hint', loc),
                  PaymentMethod.credit =>
                    AppStrings.t('payment_method_credit_hint', loc),
                },
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (_method == PaymentMethod.partial ||
                  _method == PaymentMethod.credit) ...[
                const SizedBox(height: 8),
                Text(
                  hasCustomer
                      ? '${AppStrings.t('customer', loc)}: ${cart.customer!.name}'
                      : AppStrings.t('customer_required', loc),
                  key: const Key('payment-customer-status'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hasCustomer ? AppColors.success : AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_method != PaymentMethod.credit)
                TextField(
                  key: const Key('payment-paid-input'),
                  controller: _paid,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: AppStrings.t('amount_paid', loc),
                    helperText: _method == PaymentMethod.card
                        ? (rewardDiscount > 0
                            ? AppStrings.t('amount_due', loc)
                            : AppStrings.t('total_label', loc))
                        : null,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _submit(),
                ),
              const SizedBox(height: 8),
              if (_method == PaymentMethod.cash)
                _SummaryRow(
                  label: AppStrings.t('change', loc),
                  value: PaymentMath.money(change),
                  emphasize: true,
                  color: AppColors.success,
                ),
              if (_method == PaymentMethod.partial)
                _SummaryRow(
                  label: AppStrings.t('debt', loc),
                  value: PaymentMath.money(debt),
                  emphasize: true,
                  color: AppColors.warning,
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key('payment-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              // Backend stock reasons are secondary detail — they never
              // replace the localized headline above (UX FIX #12 — FIX #5).
              if (cart.stockErrors.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...cart.stockErrors.map(
                  (e) => Text(
                    e,
                    key: const Key('payment-stock-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('payment-cancel'),
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('payment-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('confirm_payment', loc)),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;
  final Color? color;

  const _SummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.emphasize = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasize
        ? theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          )
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }
}

Future<CheckoutResult?> showPaymentDialog(BuildContext context) {
  return showDialog<CheckoutResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PaymentDialog(),
  );
}
