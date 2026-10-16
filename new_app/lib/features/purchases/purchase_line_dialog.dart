// Purchase line editor dialog (Phase 11).
//
// Owns one draft line: product selection (searchable picker), optional
// variant, optional purchase-unit dropdown (multiplier shown — whole
// packages only), quantity and unit cost with a computed display line
// total. Integer milli math only — NO PMP math ever happens here; the
// server is authoritative for all valuation.
//
// Per-line "Total cost" mode: when the checkbox is on, the amount typed
// in the cost field is the TOTAL cost of the whole entered quantity and
// the per-document-unit cost is derived (total ÷ qty, half-up). The
// staged line always stores the canonical per-unit cost — the checkbox
// is transient UI state only, never persisted or sent to the server.
//
// Keyboard-first: Enter in quantity/cost submits the line when valid.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../products/models.dart';
import 'purchase_models.dart';
import 'purchase_pickers.dart';

/// Returns the staged line, or null when the dialog was dismissed.
Future<DraftLine?> showPurchaseLineDialog(
  BuildContext context, {
  DraftLine? initial,
}) {
  return showDialog<DraftLine>(
    context: context,
    builder: (_) => PurchaseLineDialog(initial: initial),
  );
}

class PurchaseLineDialog extends ConsumerStatefulWidget {
  final DraftLine? initial;

  const PurchaseLineDialog({super.key, this.initial});

  @override
  ConsumerState<PurchaseLineDialog> createState() => _PurchaseLineDialogState();
}

class _PurchaseLineDialogState extends ConsumerState<PurchaseLineDialog> {
  ProductModel? _product;
  List<VariantModel> _variants = const [];
  List<PurchaseUnitModel> _units = const [];
  bool _loadingChoices = false;

  String? _variantId;
  String? _unitId;

  /// When true the amount typed in the cost field is the TOTAL cost of
  /// the whole entered quantity; the per-unit cost used everywhere
  /// downstream is derived from it (never persisted as a flag — the
  /// staged/saved line always stores the canonical per-unit cost).
  bool _totalCostMode = false;

  late final TextEditingController _qty;
  late final TextEditingController _cost;

  final bool _saving = false;
  String? _error;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _qty = TextEditingController(text: initial?.quantity ?? '');
    _cost = TextEditingController(text: initial?.unitCost ?? '');
    if (initial != null) {
      // Prefill from the stored draft line: only ids/names are needed.
      _product = ProductModel(
        id: initial.productId,
        name: initial.productName,
      );
      _variantId = initial.variantId;
      _unitId = initial.purchaseUnitId;
      _loadChoices(initial.productId, initialVariantId: initial.variantId,
          initialUnitId: initial.purchaseUnitId);
    }
  }

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _loadChoices(
    String productId, {
    String? initialVariantId,
    String? initialUnitId,
  }) async {
    setState(() {
      _loadingChoices = true;
      _variants = const [];
      _units = const [];
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final results = await Future.wait([
        dio.get(
          '/api/v1/products/$productId/variants',
          queryParameters: {'page_size': 50},
        ),
        dio.get(
          '/api/v1/products/$productId/purchase-units',
          queryParameters: {'include_archived': false},
        ),
      ]);
      if (!mounted) return;
      final variantData = results[0].data as Map<String, dynamic>? ?? const {};
      final unitData = results[1].data as Map<String, dynamic>? ?? const {};
      setState(() {
        _variants = (variantData['items'] as List<dynamic>? ?? const [])
            .map((e) => VariantModel.fromJson(e as Map<String, dynamic>))
            .where((v) => !v.isArchived)
            .toList();
        _units = (unitData['items'] as List<dynamic>? ?? const [])
            .map((e) => PurchaseUnitModel.fromJson(e as Map<String, dynamic>))
            .where((u) => !u.isArchived)
            .toList();
        _loadingChoices = false;
        if (initialVariantId != null &&
            !_variants.any((v) => v.id == initialVariantId)) {
          _variantId = null;
        }
        if (initialUnitId != null && !_units.any((u) => u.id == initialUnitId)) {
          _unitId = null;
        }
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingChoices = false;
        _variants = const [];
        _units = const [];
      });
    }
  }

  Future<void> _pickProduct() async {
    final product = await showPurchaseProductPicker(context);
    if (product == null || !mounted) return;
    setState(() {
      _product = product;
      _variantId = null;
      _unitId = null;
      _error = null;
    });
    await _loadChoices(product.id);
  }

  PurchaseUnitModel? get _selectedUnit {
    if (_unitId == null) return null;
    for (final u in _units) {
      if (u.id == _unitId) return u;
    }
    return null;
  }

  VariantModel? get _selectedVariant {
    if (_variantId == null) return null;
    for (final v in _variants) {
      if (v.id == _variantId) return v;
    }
    return null;
  }

  String? _validate(String loc) {
    if (_product == null) return AppStrings.t('field_required', loc);
    final qtyText = _qty.text.trim();
    if (qtyText.isEmpty) return AppStrings.t('invalid_qty', loc);
    final qtyMilli = qtyToMilli(qtyText);
    if (qtyMilli == null || qtyMilli <= 0) {
      return AppStrings.t('invalid_qty', loc);
    }
    if (_selectedUnit != null && !isWholeQty(qtyText)) {
      return AppStrings.t('purchase_line_invalid', loc);
    }
    final costText = _cost.text.trim();
    if (costText.isEmpty || moneyToMilli(costText) == null) {
      return AppStrings.t('invalid_amount', loc);
    }
    return null;
  }

  void _submit(String loc) {
    final validation = _validate(loc);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    final product = _product!;
    final variant = _selectedVariant;
    final unit = _selectedUnit;
    // Canonical stored cost is ALWAYS per document unit. In total-cost
    // mode the typed amount is divided by the quantity here — _validate
    // already guarantees qty > 0 and a parsable cost, so the derivation
    // cannot fail or divide by zero.
    var unitCost = _cost.text.trim();
    if (_totalCostMode) {
      final derived = effectiveUnitCostMilli(
        quantity: _qty.text.trim(),
        cost: unitCost,
        totalCostMode: true,
      );
      if (derived == null) {
        setState(() => _error = AppStrings.t('invalid_amount', loc));
        return;
      }
      unitCost = milliToMoney(derived);
    }
    Navigator.pop(
      context,
      DraftLine(
        productId: product.id,
        productName: product.name,
        variantId: variant?.id,
        variantName: variant?.name,
        purchaseUnitId: unit?.id,
        purchaseUnitName: unit?.name,
        multiplier: unit?.multiplier,
        quantity: _qty.text.trim(),
        unitCost: unitCost,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    // Live preview — pure milli arithmetic over the raw field text, so it
    // updates on every keystroke and never mutates anything: the derived
    // per-unit cost, the base-quantity equivalent, and the line total
    // that would be persisted if the line were saved right now.
    final qtyText = _qty.text.trim();
    final costText = _cost.text.trim();
    final multiplier = _selectedUnit?.multiplier;
    final qtyMilli = qtyToMilli(qtyText);
    final unitCostMilli = effectiveUnitCostMilli(
      quantity: qtyText,
      cost: costText,
      totalCostMode: _totalCostMode,
    );
    final baseQtyMilli = baseQtyEquivalentMilli(qtyText, multiplier);
    final baseCostMilli = baseUnitCostMilli(unitCostMilli, multiplier);
    final multiplierMilli = multiplier == null ? null : moneyToMilli(multiplier);
    final showsBaseUnits = multiplierMilli != null && multiplierMilli != 1000;

    return AlertDialog(
      key: const Key('purchase-line-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_line' : 'add_line', loc),
        key: const Key('purchase-line-title'),
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _product?.name ?? AppStrings.t('select_product', loc),
                    key: const Key('purchase-line-product'),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('purchase-line-pick-product'),
                  onPressed: _saving ? null : _pickProduct,
                  icon: const Icon(Icons.search, size: 18),
                  label: Text(
                    AppStrings.t(
                      _product == null ? 'select' : 'change_product',
                      loc,
                    ),
                  ),
                ),
              ],
            ),
            if (_loadingChoices)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: LinearProgressIndicator()),
              ),
            if (_product != null && !_loadingChoices) ...[
              if (_variants.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  key: const Key('purchase-line-variant'),
                  initialValue: _variantId,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('variant', loc),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(AppStrings.t('line_no_variant', loc)),
                    ),
                    ..._variants.map(
                      (v) => DropdownMenuItem<String?>(
                        value: v.id,
                        child: Text(v.name),
                      ),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                            _variantId = value;
                            _error = null;
                          }),
                ),
              ],
              if (_units.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  key: const Key('purchase-line-unit'),
                  initialValue: _unitId,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('purchase_unit', loc),
                    helperText: AppStrings.t('purchase_units_hint', loc),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(AppStrings.t('base_unit', loc)),
                    ),
                    ..._units.map(
                      (u) => DropdownMenuItem<String?>(
                        value: u.id,
                        child: Text('${u.name} ×${u.multiplier}'),
                      ),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                            _unitId = value;
                            _error = null;
                          }),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('purchase-line-qty'),
                      controller: _qty,
                      enabled: !_saving,
                      autofocus: !_isEdit,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t('quantity', loc),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(loc),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('purchase-line-cost'),
                      controller: _cost,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t(
                          _totalCostMode ? 'purchase_total_cost' : 'unit_cost',
                          loc,
                        ),
                        helperText: _totalCostMode
                            ? AppStrings.t('purchase_total_cost_hint', loc)
                            : null,
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(loc),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                key: const Key('purchase-line-total-cost-toggle'),
                value: _totalCostMode,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(AppStrings.t('purchase_total_cost', loc)),
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _totalCostMode = value ?? false;
                          _error = null;
                        }),
              ),
            ],
            if (unitCostMilli != null &&
                qtyMilli != null &&
                qtyMilli > 0 &&
                baseQtyMilli != null &&
                baseCostMilli != null) ...[
              const SizedBox(height: 12),
              // Bidi: Arabic segment labels stay natural RTL; each money
              // amount + currency suffix is ONE LTR isolate so grouped
              // digits (`1 000 DA`, `2 000 DA`) never reverse. Wrapping
              // the whole sentence in a forced-LTR paragraph would still
              // reorder the groups (bidi rule W7) — see numeric_text.dart.
              Text(
                [
                  if (showsBaseUnits)
                    '${AppStrings.t('purchase_preview_total_qty', loc)}: '
                    '${bidiIsolateLtr(formatMoney(milliToMoney(baseQtyMilli)))} '
                    '${AppStrings.unitLabel(_product?.unit, loc)}',
                  '${AppStrings.t('unit_cost', loc)}: '
                  '${bidiIsolateLtr(
                    '${formatMoney(milliToMoney(baseCostMilli))} '
                    '${AppStrings.t('currency', loc)}',
                  )}',
                  '${AppStrings.t('line_total', loc)}: '
                  '${bidiIsolateLtr(
                    '${formatMoney(milliToMoney(
                      (qtyMilli * unitCostMilli + 500) ~/ 1000,
                    ))} ${AppStrings.t('currency', loc)}',
                  )}',
                ].join(' · '),
                key: const Key('purchase-line-total'),
                style: theme.textTheme.titleMedium,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('purchase-line-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('purchase-line-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('purchase-line-submit'),
          onPressed: _saving ? null : () => _submit(loc),
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
