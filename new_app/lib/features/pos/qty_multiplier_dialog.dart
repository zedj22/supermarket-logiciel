// Quantity input dialog for the POS `*` shortcut (Phase 8 FIX #3).
//
// `*` does NOT multiply. It opens this dialog so the cashier can type the
// NEW quantity of the active cart line — the entered value REPLACES the
// current one (current 24, `*`, type 3, confirm → 3), never
// `current × entered`.
//
// Validation reuses the shared POS quantity rules: `posScaled` (exact
// ×1000 parsing), `> 0`, `kPosQuantityMax` and the single-line stock rule
// `posQtyStockError`; the cart-wide guard runs once more inside
// `applyLineQuantity` when the value is written to the cart. No second
// parser, no second stock rule.
//
// The field autofocuses, so while this dialog route is open it — not the
// background POS shortcut layer — owns the keyboard. Enter confirms,
// Escape / Cancel closes with no cart mutation.
import 'package:flutter/material.dart';

import '../../core/strings.dart';
import 'pos_quantity.dart';

/// Opens the quantity input dialog for one cart line.
///
/// Returns the NEW quantity as canonical decimal text (exact scaled math —
/// `2.5` stays `2.5`, never float garbage) or null when cancelled.
Future<String?> showQuantityInputDialog(
  BuildContext context, {
  required String productName,
  required String currentQuantity,
  String? availableStock,
  String? unitMultiplier,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => QuantityInputDialog(
      productName: productName,
      currentQuantity: currentQuantity,
      availableStock: availableStock,
      unitMultiplier: unitMultiplier,
    ),
  );
}

class QuantityInputDialog extends StatefulWidget {
  const QuantityInputDialog({
    super.key,
    required this.productName,
    required this.currentQuantity,
    this.availableStock,
    this.unitMultiplier,
  });

  final String productName;
  final String currentQuantity;
  final String? availableStock;
  final String? unitMultiplier;

  @override
  State<QuantityInputDialog> createState() => _QuantityInputDialogState();
}

class _QuantityInputDialogState extends State<QuantityInputDialog> {
  late final TextEditingController _qty;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Phase 17 §18: the field opens BLANK and autofocused, so the cashier
    // types the new quantity straight away instead of having to select and
    // replace the pre-filled current one. The current quantity still shows
    // above the field (and in the `current → entered` preview), so nothing
    // is lost. Empty is rejected by the shared validation in `_submit`.
    _qty = TextEditingController(text: '');
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  /// Current quantity as an exact scaled (×1000) integer.
  int get _currentScaled => posScaled(widget.currentQuantity) ?? 0;

  /// Current quantity as exact decimal text (canonical, no float noise).
  String get _currentText => posScaledText(_currentScaled);

  /// Validates the ENTERED quantity and returns it — no multiplication
  /// anywhere: the typed number *is* the new line quantity.
  void _submit() {
    final loc = Localizations.localeOf(context).languageCode;
    final text = _qty.text.trim();
    final entered = posScaled(text);
    if (text.isEmpty || entered == null || entered <= 0) {
      setState(() => _error = AppStrings.t('enter_quantity', loc));
      return;
    }
    if (entered > kPosQuantityMax * kPosQtyScale) {
      setState(
        () => _error = AppStrings.t('quantity_too_large', loc),
      );
      return;
    }
    // Exact scaled text of the entered number (never binary floats).
    final next = posScaledText(entered);
    final err = posQtyStockError(
      quantity: next,
      availableStock: widget.availableStock,
      unitMultiplier: widget.unitMultiplier,
      loc: loc,
    );
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, next);
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('qty-multiplier-dialog'),
      title: Text(
        AppStrings.t('enter_quantity', loc),
        key: const Key('qty-multiplier-title'),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.productName,
              key: const Key('qty-multiplier-product'),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              '${AppStrings.t('quantity', loc)}: '
              '$_currentText',
              key: const Key('qty-multiplier-current'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('qty-multiplier-input'),
              controller: _qty,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: AppStrings.t('quantity', loc),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _qty,
              builder: (context, value, _) {
                final typed = value.text.trim();
                final entered = posScaled(typed);
                final next = (typed.isEmpty ||
                        entered == null ||
                        entered <= 0)
                    ? '—'
                    : posScaledText(entered);
                return Text(
                  '$_currentText → $next',
                  key: const Key('qty-multiplier-preview'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                );
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('qty-multiplier-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('qty-multiplier-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('qty-multiplier-apply'),
          onPressed: _submit,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}
