// Invoice-level discount dialog (F7). Line discounts stay per-line.
// Requires pos_discount permission (checked by caller / server).
//
// Two input modes over the SAME stored value: a fixed DZD amount (the
// original behaviour, unchanged) or a percentage of the current subtotal
// (after line discounts). Only the AMOUNT is ever persisted — the percent
// is converted at save time, so the cart state, the checkout payload
// (`invoice_discount`), the server totals, the sale row and the receipt
// keep carrying exactly what they always carried. Reopening the dialog
// lands in amount mode with the stored amount prefilled.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'pos_providers.dart';

Future<String?> showInvoiceDiscountDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const InvoiceDiscountDialog(),
  );
}

/// How the operator expresses the discount: money (DZD) or a percent of
/// the current subtotal. Purely an input mode — the stored value is
/// always an amount.
enum _DiscountMode { amount, percent }

class InvoiceDiscountDialog extends ConsumerStatefulWidget {
  const InvoiceDiscountDialog({super.key});

  @override
  ConsumerState<InvoiceDiscountDialog> createState() =>
      _InvoiceDiscountDialogState();
}

class _InvoiceDiscountDialogState extends ConsumerState<InvoiceDiscountDialog> {
  late final TextEditingController _amount;
  _DiscountMode _mode = _DiscountMode.amount;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
      text: ref.read(posCartProvider).invoiceDiscount,
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// Parsed input for the CURRENT mode, or null when empty/unparseable.
  double? get _parsed => double.tryParse(_amount.text.trim());

  /// Discount money for the current valid input (0 while invalid/empty).
  /// A percent never yields more than the eligible subtotal.
  double _discountOf(double subtotal) {
    final raw = _parsed;
    if (raw == null) return 0;
    if (_mode == _DiscountMode.amount) return raw;
    final computed = subtotal * raw / 100;
    return computed > subtotal ? subtotal : computed;
  }

  void _onChanged(_) => setState(() => _error = null);

  void _submit() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final raw = _amount.text.trim();
    final value = double.tryParse(raw);
    final totals = ref.read(posCartProvider).totals;
    if (value == null || value < 0) {
      setState(() => _error = AppStrings.t('invalid_amount', loc));
      return;
    }
    if (_mode == _DiscountMode.percent && value > 100) {
      setState(() => _error = AppStrings.t('discount_percent_too_high', loc));
      return;
    }
    final amount = _mode == _DiscountMode.percent
        ? double.parse(_discountOf(totals.subtotal).toStringAsFixed(2))
        : value;
    if (amount > totals.subtotal + 1e-9) {
      setState(() => _error = AppStrings.t('invalid_amount', loc));
      return;
    }
    ref.read(posCartProvider.notifier).setInvoiceDiscount('$amount');
    Navigator.pop(context, '$amount');
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final totals = ref.watch(posCartProvider).totals;

    final parsed = _parsed;
    final valid = parsed != null &&
        parsed >= 0 &&
        !(_mode == _DiscountMode.percent && parsed > 100);
    final discount = valid ? _discountOf(totals.subtotal) : 0.0;
    final resultingTotal = (totals.subtotal - discount) < 0
        ? 0.0
        : totals.subtotal - discount;
    final currency = AppStrings.t('currency', loc);

    return AlertDialog(
      key: const Key('invoice-discount-dialog'),
      title: Text(AppStrings.t('invoice_discount', loc)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bidi: Arabic label natural; the grouped subtotal is one LTR
            // isolate (forced-LTR whole-string still reverses it — W7).
            Text(
              '${AppStrings.t('subtotal_label', loc)}: '
              '${bidiIsolateLtr(totals.subtotalDisplay)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SegmentedButton<_DiscountMode>(
              key: const Key('invoice-discount-mode'),
              segments: [
                ButtonSegment<_DiscountMode>(
                  value: _DiscountMode.amount,
                  label: Text(AppStrings.t('discount_type_amount', loc)),
                ),
                ButtonSegment<_DiscountMode>(
                  value: _DiscountMode.percent,
                  label: Text(AppStrings.t('discount_type_percent', loc)),
                ),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => setState(() {
                _mode = selection.first;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('invoice-discount-input'),
              controller: _amount,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: _mode == _DiscountMode.percent
                    ? AppStrings.t('discount_type_percent', loc)
                    : AppStrings.t('discount_type_amount', loc),
                suffixText: _mode == _DiscountMode.percent ? '%' : null,
              ),
              onChanged: _onChanged,
              onSubmitted: (_) => _submit(),
            ),
            // Live effect: the money the discount takes off and the total
            // the sale will carry, for ANY valid input in either mode.
            if (valid && parsed > 0) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      AppStrings.t('discount', loc),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  numericText(
                    '-${_money(discount)} $currency',
                    key: const Key('invoice-discount-preview-amount'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      AppStrings.t('total_label', loc),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  numericText(
                    _money(resultingTotal),
                    key: const Key('invoice-discount-preview-total'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const Key('invoice-discount-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('invoice-discount-submit'),
          onPressed: _submit,
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}

/// Display form of a discount figure: 2 decimals + grouping, matching the
/// totals panel (PaymentMath.money without importing the payment model).
String _money(double value) => formatGroupedFixed(value, 2);
