// Reusable quantity / weight entry dialog (Phase 6 — weight/length
// amount entry pass).
//
// Used by the selling-unit picker (and the POS base-only add flow) to
// enter a quantity or weight in a selling unit. Shows conversion to base
// units using the unit's multiplier — never a hardcoded cross-unit
// conversion (kg↔g) unless the unit_type matches.
//
// WEIGHT / LENGTH AMOUNT ENTRY — for selling units whose `unit_type` is
// weight or length (`kg`, `gram`, `meter` — the ProductUnit vocabulary,
// never translated labels) the dialog offers TWO modes:
//   * Mode A "By quantity" — the existing quantity field, plus a live
//     line-total preview (quantity × the unit's effective price);
//   * Mode B "By amount"  — the cashier enters how much DA the customer
//     wants to pay; the quantity is computed as amount ÷ effective
//     price in EXACT scaled math (core/amount_entry.dart, HALF-UP to
//     the 3-decimal domain), then the ACTUAL total is recomputed from
//     the rounded quantity and shown before confirmation — a requested
//     100 DA at 300 DA/unit confirms as 0.333 for 99.9 DA, never a
//     silent 100 DA. Zero/invalid price disables amount mode with an
//     explanation; the quantity mode always stays available.
//
// Count-based units (piece, box, pack, liter, …) never see the toggle —
// their dialog is exactly the Phase 6 one.
//
// Returns a positive Decimal-compatible quantity string (plain number or
// computed expression product), or null when cancelled.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/amount_entry.dart';
import '../../core/barcode_scanner.dart';
import '../../core/quantity_expression.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';

/// Shows a modal quantity/weight dialog for [unit].
///
/// [productQuantity] is the base stock (for availability display).
/// [unitPrice] is the effective unit price the line will charge — the
/// picker passes the same value it puts on the pick result. Returns the
/// entered quantity as a string, or null on cancel.
Future<String?> showQuantityDialog(
  BuildContext context, {
  required SellingUnitModel unit,
  String productQuantity = '0',
  String? productUnit,
  String? unitPrice,
}) {
  // Same scanner suspension as the selling-unit picker: a burst arriving
  // while this dialog is open is captured (never dispatched), and a burst
  // that transits the focused quantity/amount field is restored to its
  // pre-run text at the terminator — the field keeps exactly what the
  // human typed, and the Enter never submits the dialog on a scanner's
  // behalf. Manual typing, Enter-on-typing, arrows and Escape are
  // untouched.
  return BarcodeScannerGateway.instance.withScannerSuspended(
    (token) => showDialog<String>(
      context: context,
      builder: (_) => ScannerSuspensionGuard(
        token: token,
        child: QuantityDialog(
          unit: unit,
          productQuantity: productQuantity,
          productUnit: productUnit,
          unitPrice: unitPrice,
        ),
      ),
    ),
  );
}

class QuantityDialog extends ConsumerStatefulWidget {
  final SellingUnitModel unit;
  final String productQuantity;
  final String? productUnit;
  final String? unitPrice;

  const QuantityDialog({
    super.key,
    required this.unit,
    this.productQuantity = '0',
    this.productUnit,
    this.unitPrice,
  });

  @override
  ConsumerState<QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends ConsumerState<QuantityDialog> {
  late final TextEditingController _qty;
  late final TextEditingController _amount;
  late final FocusNode _amountFocus;
  String? _error;
  bool _byAmount = false;

  SellingUnitModel get _unit => widget.unit;

  /// The mode toggle is offered for weight/length units only.
  bool get _isWeightOrLength => isAmountEntryUnit(_unit.unitType);

  /// Effective unit price (×1000); null when unusable → amount mode is
  /// disabled with an explanation (never an error, never a silent 0).
  int? get _priceScaled {
    final scaled = posScaled(widget.unitPrice);
    if (scaled == null || scaled <= 0) return null;
    return scaled;
  }

  bool get _amountModeAvailable => _isWeightOrLength && _priceScaled != null;

  @override
  void initState() {
    super.initState();
    // Phase 17 §18: blank + autofocused. The selling-unit picker just told
    // the cashier which unit they picked, so the next keystroke is the
    // quantity — not a selection of a pre-filled `1`. Empty is rejected by
    // `_validate` (`enter_quantity`), and the conversion preview below
    // still shows the multiplier the moment a number is typed.
    _qty = TextEditingController(text: '');
    _amount = TextEditingController(text: '');
    _amountFocus = FocusNode();
  }

  @override
  void dispose() {
    _qty.dispose();
    _amount.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  double _baseStock() => double.tryParse(widget.productQuantity) ?? 0;

  double _multiplier() => double.tryParse(_unit.multiplier) ?? 1;

  /// Shared parser (UX FIX #12 — FIX #3): plain numbers **and** quantity
  /// expressions (`10*24` → 240) — same rules as the POS cart.
  PosQuantityExpression get _parsed => parseQuantityExpression(_qty.text);

  double _enteredQty() => _parsed.value;

  double _baseNeeded() => _enteredQty() * _multiplier();

  /// Exact base stock needed for [quantityScaled] of this unit
  /// (×1000 math, HALF-UP — the same conversion as the POS guard).
  int? _baseNeededScaled(int quantityScaled) {
    final multiplier = posScaled(_unit.multiplier) ?? kPosQtyScale;
    if (multiplier <= 0) return kPosQtyScale;
    final product = quantityScaled * multiplier;
    return (2 * product + kPosQtyScale) ~/ (2 * kPosQtyScale);
  }

  /// Stock error for an amount-mode quantity, or null when it fits.
  String? _amountStockError(int quantityScaled) {
    final stock = posScaled(widget.productQuantity);
    if (stock == null) return null; // unknown stock → never blocks
    final needed = _baseNeededScaled(quantityScaled);
    if (needed == null) return null;
    if (needed <= stock) return null;
    return AppStrings.t('out_of_stock', loc);
  }

  String get loc => ref.read(localeProvider).flutterLocale.languageCode;

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (_byAmount && _amountModeAvailable) {
      return _validateAmount(loc);
    }
    if (_qty.text.trim().isEmpty) {
      return AppStrings.t('enter_quantity', loc);
    }
    final parseError = validateRequestedQuantity(_qty.text, loc);
    if (parseError != null) return parseError;
    final needed = _baseNeeded();
    final stock = _baseStock();
    if (needed > stock) {
      return AppStrings.t('out_of_stock', loc);
    }
    return null;
  }

  /// Amount-mode validation: parse the amount, convert through the exact
  /// HALF-UP division, then apply the quantity caps and the stock rule to
  /// the CONVERTED quantity — never to the raw amount.
  String? _validateAmount(String loc) {
    final text = _amount.text.trim();
    if (text.isEmpty) return AppStrings.t('enter_amount', loc);
    final amountScaled = posScaled(text);
    if (amountScaled == null || amountScaled <= 0) {
      return AppStrings.t('invalid_amount', loc);
    }
    final quantityScaled = amountToQuantityScaled(
      amountScaled: amountScaled,
      priceScaled: _priceScaled!,
    );
    if (quantityScaled == null || quantityScaled <= 0) {
      return AppStrings.t('invalid_amount', loc);
    }
    if (quantityScaled > kPosQuantityMax * kPosQtyScale) {
      return AppStrings.t('quantity_too_large', loc);
    }
    final stockError = _amountStockError(quantityScaled);
    if (stockError != null) return stockError;
    return null;
  }

  void _submit() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (_byAmount && _amountModeAvailable) {
      // The ROUNDED quantity is what the cart stores — the actual total
      // was previewed from it, so confirm returns exactly that number.
      final amountScaled = posScaled(_amount.text.trim())!;
      final quantityScaled = amountToQuantityScaled(
        amountScaled: amountScaled,
        priceScaled: _priceScaled!,
      )!;
      Navigator.pop(context, posScaledText(quantityScaled));
      return;
    }
    // Plain numbers keep the typed text; an expression stores its product.
    Navigator.pop(context, _parsed.text);
  }

  void _selectMode({required bool byAmount}) {
    if (_byAmount == byAmount) return;
    setState(() {
      _byAmount = byAmount;
      _error = null;
    });
    if (byAmount) {
      _amountFocus.requestFocus();
    }
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
              if (_isWeightOrLength) ...[
                const SizedBox(height: 10),
                // Mode toggle — quantity (always) or amount (only when
                // the effective price is usable).
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const Key('quantity-mode-quantity'),
                      label: Text(AppStrings.t('by_quantity', loc)),
                      selected: !_byAmount,
                      onSelected: (_) => _selectMode(byAmount: false),
                    ),
                    ChoiceChip(
                      key: const Key('quantity-mode-amount'),
                      label: Text(AppStrings.t('by_amount', loc)),
                      selected: _byAmount,
                      onSelected: _amountModeAvailable
                          ? (_) => _selectMode(byAmount: true)
                          : null,
                    ),
                  ],
                ),
                if (!_amountModeAvailable) ...[
                  const SizedBox(height: 6),
                  Text(
                    AppStrings.t('amount_entry_price_unavailable', loc),
                    key: const Key('amount-mode-unavailable'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              if (_byAmount && _amountModeAvailable) ...[
                TextField(
                  key: const Key('amount-input'),
                  controller: _amount,
                  focusNode: _amountFocus,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: AppStrings.t('enter_amount', loc),
                    helperText:
                        '${AppStrings.t('unit_price', loc)}: ${widget.unitPrice}',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _amount,
                  builder: (context, value, _) {
                    final text = value.text.trim();
                    final amountScaled = posScaled(text);
                    final price = _priceScaled;
                    if (amountScaled == null ||
                        amountScaled <= 0 ||
                        price == null) {
                      return Text(
                        '${AppStrings.t('computed_quantity', loc)}: —',
                        key: const Key('amount-computed-quantity'),
                        style: theme.textTheme.bodySmall,
                      );
                    }
                    final quantityScaled = amountToQuantityScaled(
                      amountScaled: amountScaled,
                      priceScaled: price,
                    );
                    final actualScaled = quantityScaled == null
                        ? null
                        : quantityToAmountScaled(
                            quantityScaled: quantityScaled,
                            priceScaled: price,
                          );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Bidi: Arabic labels stay natural; each grouped
                        // value is its own LTR isolate (a forced-LTR
                        // whole-string still reverses digits after an
                        // Arabic label — W7).
                        Text(
                          '${AppStrings.t('computed_quantity', loc)}: '
                          '${bidiIsolateLtr(
                            formatGrouped(posScaledText(quantityScaled ?? 0)),
                          )} ${_unit.name}',
                          key: const Key('amount-computed-quantity'),
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        // The ACTUAL charge recomputed from the rounded
                        // quantity — shown even when it differs from the
                        // requested amount (never silently charge more or
                        // less than what is displayed here).
                        Text(
                          '${AppStrings.t('line_total', loc)}: '
                          '${bidiIsolateLtr(
                            formatGrouped(posScaledText(actualScaled ?? 0)),
                          )}',
                          key: const Key('amount-line-total'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        if (actualScaled != null &&
                            actualScaled != amountScaled) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${AppStrings.t('requested_amount', loc)}: '
                            '${bidiIsolateLtr(
                              formatGrouped(posScaledText(amountScaled)),
                            )}',
                            key: const Key('amount-requested'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ] else ...[
                TextField(
                  key: const Key('quantity-input'),
                  controller: _qty,
                  autofocus: !_byAmount,
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
                    final parsed = parseQuantityExpression(value.text);
                    final price = _priceScaled;
                    final totalScaled = price == null || !parsed.isValid
                        ? null
                        : quantityToAmountScaled(
                            quantityScaled: parsed.scaled,
                            priceScaled: price,
                          );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Bidi: Arabic label natural; each grouped value is
                        // its own LTR isolate (W7).
                        Text(
                          '${AppStrings.t('available_quantity', loc)}: '
                          '${bidiIsolateLtr(formatGrouped(widget.productQuantity))}'
                          ' → ${bidiIsolateLtr(formatGrouped(base.toStringAsFixed(3)))}',
                          key: const Key('quantity-base-preview'),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (price != null && totalScaled != null) ...[
                          const SizedBox(height: 4),
                          // Mode A line total: quantity × effective price.
                          Text(
                            '${AppStrings.t('line_total', loc)}: '
                            '${bidiIsolateLtr(
                              formatGrouped(posScaledText(totalScaled)),
                            )}',
                            key: const Key('quantity-line-total'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
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
          key: const Key('quantity-cancel'),
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
