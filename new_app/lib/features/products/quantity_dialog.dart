// Reusable quantity / weight entry dialog (Phase 6).
//
// Used by the selling-unit picker (and later POS in Phase 8) to enter a
// quantity or weight in a selling unit. Shows conversion to base units
// using the unit's multiplier — never a hardcoded cross-unit conversion
// (kg↔g) unless the unit_type matches.
//
// Returns a positive Decimal-compatible string, or null when cancelled.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';

/// Shows a modal quantity/weight dialog for [unit].
///
/// [productQuantity] is the base stock (for availability display).
/// Returns the entered quantity as a string, or null on cancel.
Future<String?> showQuantityDialog(
  BuildContext context, {
  required SellingUnitModel unit,
  String productQuantity = '0',
  String? productUnit,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => QuantityDialog(
      unit: unit,
      productQuantity: productQuantity,
      productUnit: productUnit,
    ),
  );
}

class QuantityDialog extends ConsumerStatefulWidget {
  final SellingUnitModel unit;
  final String productQuantity;
  final String? productUnit;

  const QuantityDialog({
    super.key,
    required this.unit,
    this.productQuantity = '0',
    this.productUnit,
  });

  @override
  ConsumerState<QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends ConsumerState<QuantityDialog> {
  late final TextEditingController _qty;
  String? _error;

  SellingUnitModel get _unit => widget.unit;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  double _baseStock() => double.tryParse(widget.productQuantity) ?? 0;

  double _multiplier() => double.tryParse(_unit.multiplier) ?? 1;

  double _enteredQty() => double.tryParse(_qty.text.trim()) ?? 0;

  double _baseNeeded() => _enteredQty() * _multiplier();

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final q = _enteredQty();
    if (_qty.text.trim().isEmpty || q <= 0) {
      return AppStrings.t('enter_quantity', loc);
    }
    final needed = _baseNeeded();
    final stock = _baseStock();
    if (needed > stock) {
      return AppStrings.t('out_of_stock', loc);
    }
    return null;
  }

  void _submit() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, _qty.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final unitLabel = AppStrings.unitLabel(_unit.unitType, loc);

    return AlertDialog(
      key: const Key('quantity-dialog'),
      title: Text(AppStrings.t('enter_quantity', loc)),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppStrings.t('selling_unit', loc)}: ${_unit.name}',
                key: const Key('quantity-unit-name'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('quantity-input'),
                controller: _qty,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: AppStrings.t('enter_quantity', loc),
                  helperText: unitLabel,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              // Conversion preview (explicit multiplier — never implicit)
              Text(
                '${AppStrings.t('conversion', loc)}: '
                '1 ${_unit.name} = ${_unit.multiplier} ${widget.productUnit ?? AppStrings.t('base_unit', loc)}',
                key: const Key('quantity-conversion'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _qty,
                builder: (context, value, _) {
                  final base = _baseNeeded();
                  return Text(
                    '${AppStrings.t('available_quantity', loc)}: '
                    '${widget.productQuantity} → ${base.toStringAsFixed(3)}',
                    key: const Key('quantity-base-preview'),
                    style: theme.textTheme.bodySmall,
                  );
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key('quantity-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('quantity-submit'),
          onPressed: _submit,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}
