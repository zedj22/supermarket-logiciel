// Invoice-level discount dialog (F7). Line discounts stay per-line.
// Requires pos_discount permission (checked by caller / server).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'pos_providers.dart';

Future<String?> showInvoiceDiscountDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const InvoiceDiscountDialog(),
  );
}

class InvoiceDiscountDialog extends ConsumerStatefulWidget {
  const InvoiceDiscountDialog({super.key});

  @override
  ConsumerState<InvoiceDiscountDialog> createState() =>
      _InvoiceDiscountDialogState();
}

class _InvoiceDiscountDialogState extends ConsumerState<InvoiceDiscountDialog> {
  late final TextEditingController _amount;
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

  void _submit() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final raw = _amount.text.trim();
    final value = double.tryParse(raw);
    final totals = ref.read(posCartProvider).totals;
    if (value == null || value < 0) {
      setState(() => _error = AppStrings.t('invalid_amount', loc));
      return;
    }
    if (value > totals.subtotal + 1e-9) {
      setState(() => _error = AppStrings.t('invalid_amount', loc));
      return;
    }
    ref.read(posCartProvider.notifier).setInvoiceDiscount('$value');
    Navigator.pop(context, raw);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final totals = ref.watch(posCartProvider).totals;

    return AlertDialog(
      key: const Key('invoice-discount-dialog'),
      title: Text(AppStrings.t('invoice_discount', loc)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${AppStrings.t('subtotal_label', loc)}: '
              '${totals.subtotalDisplay}',
              style: theme.textTheme.bodyMedium,
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
                labelText: AppStrings.t('discount', loc),
              ),
              onSubmitted: (_) => _submit(),
            ),
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
