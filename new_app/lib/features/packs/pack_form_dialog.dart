// Create / edit pack dialog (Phase 10 + Phase 10 fix round).
//
// Same architecture as ProductFormDialog / CustomerFormDialog: the dialog
// owns its fields and submit flow, delegates persistence to the
// packsProvider notifier (localized message or null on success), then pops.
//
// Components target BASE products only (GATE 1) — the picker never offers
// variants. A component MAY name one of that product's EXISTING SELLING
// UNITS (Phase 6 model): the quantity is then expressed in the selected
// unit and the backend converts it once with
// `base = quantity x multiplier` (e.g. 2 Box x24 = 48 Piece). When the
// product has no selling units only its base unit is offered.
//
// The dialog also renders the informational profitability preview
// (estimated cost / profit / margin) from each component's live
// `avg_cost` (Phase 7 PMP) — display only, nothing is persisted.
//
// Prices and quantities travel as decimal strings; no binary float is ever
// written to the payload.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../pos/pos_toast.dart';
import '../products/models.dart';
import '../products/products_providers.dart';
import 'pack_models.dart';
import 'packs_providers.dart';

Future<void> showPackFormDialog(
  BuildContext context, {
  PackModel? pack,
}) {
  return showDialog(
    context: context,
    builder: (_) => PackFormDialog(pack: pack),
  );
}

/// One selectable unit for a component row: `id == null` means the
/// product's own base unit (the product's `unit`, multiplier 1).
class _UnitOption {
  final String? id;
  final String name;
  final String multiplier;

  const _UnitOption({this.id, required this.name, required this.multiplier});

  String get label => '$name \u00d7$multiplier';
}

/// One component row while the form is being edited.
class _ComponentRow {
  final String productId;
  final String productName;
  final String productUnit;
  final String productPrice;

  /// Live PMP of the component product (Phase 7) — estimate only.
  final String avgCost;

  /// Selected selling unit (null = base unit / legacy component).
  String? sellingUnitId;

  /// Quantity expressed in the SELECTED unit (base units when null).
  final TextEditingController quantity;

  _ComponentRow({
    required this.productId,
    required this.productName,
    required this.productUnit,
    required this.productPrice,
    required this.avgCost,
    this.sellingUnitId,
    required this.quantity,
  });

  void dispose() => quantity.dispose();
}

/// Formats a display number without introducing float noise: integers stay
/// integers, fractional values keep at most 3 decimals (NUMERIC(18,3)).
String _fmt(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  final text = value.toStringAsFixed(3);
  if (!text.contains('.')) return text;
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class PackFormDialog extends ConsumerStatefulWidget {
  final PackModel? pack;

  const PackFormDialog({super.key, this.pack});

  @override
  ConsumerState<PackFormDialog> createState() => _PackFormDialogState();
}

class _PackFormDialogState extends ConsumerState<PackFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _price;
  final List<_ComponentRow> _components = [];

  /// productId -> active selling units (Phase 6), loaded on demand.
  final Map<String, List<SellingUnitModel>> _units = {};

  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.pack != null;

  @override
  void initState() {
    super.initState();
    final p = widget.pack;
    _name = TextEditingController(text: p?.name ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _price = TextEditingController(text: p != null ? p.price : '');
    for (final c in p?.components ?? const <PackComponentModel>[]) {
      _components.add(_ComponentRow(
        productId: c.productId,
        productName: c.productName,
        productUnit: c.productUnit,
        productPrice: c.productPrice,
        avgCost: c.avgCost,
        // Hydration: the stored unit identity wins; legacy rows have none
        // and fall back to the product's base unit (multiplier 1) in the
        // selector, keeping their stored base quantity untouched.
        sellingUnitId: c.sellingUnitId,
        // The field edits the quantity in the SELECTED unit.
        quantity: TextEditingController(
          text: c.unitQuantity.isNotEmpty ? c.unitQuantity : c.quantity,
        ),
      ));
      _loadUnits(c.productId);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _price.dispose();
    for (final row in _components) {
      row.dispose();
    }
    super.dispose();
  }

  // --------------------------------------------------------------------
  // Selling units (Phase 6 — reused as-is, no pack-specific unit logic)
  // --------------------------------------------------------------------

  Future<void> _loadUnits(String productId) async {
    if (_units.containsKey(productId)) return;
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio
          .get('/api/v1/products/$productId/selling-units');
      if (!mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => SellingUnitModel.fromJson(e as Map<String, dynamic>))
          .where((u) => !u.isArchived) // active / non-archived only
          .toList();
      setState(() => _units[productId] = items);
    } on DioException {
      // A failed lookup must never block the form: the product's base
      // unit is still selectable.
      if (!mounted) return;
      setState(() => _units[productId] = const <SellingUnitModel>[]);
    }
  }

  /// Unit options for one row: the base unit first, then the remaining
  /// active selling units.
  List<_UnitOption> _optionsFor(_ComponentRow row) {
    final units = _units[row.productId] ?? const <SellingUnitModel>[];
    final options = <_UnitOption>[];

    SellingUnitModel? base;
    for (final unit in units) {
      if (unit.isBaseUnit) {
        base = unit;
        break;
      }
    }
    base ??= units.cast<SellingUnitModel?>().firstWhere(
          (unit) => unit!.multiplier == '1',
          orElse: () => null,
        );

    if (base != null) {
      options.add(_UnitOption(
        id: base.id,
        name: base.name,
        multiplier: base.multiplier,
      ));
    } else {
      options.add(_UnitOption(
        id: null,
        name: row.productUnit,
        multiplier: '1',
      ));
    }
    for (final unit in units) {
      if (unit.id == options.first.id) continue;
      options.add(_UnitOption(
        id: unit.id,
        name: unit.name,
        multiplier: unit.multiplier,
      ));
    }
    return options;
  }

  bool _hasUnits(String productId) =>
      (_units[productId] ?? const []).isNotEmpty;

  _UnitOption _selectedOption(_ComponentRow row) {
    final options = _optionsFor(row);
    for (final option in options) {
      if (option.id == row.sellingUnitId) return option;
    }
    // Unknown / archived / legacy identity -> base unit (their stored
    // quantity already means base units, so nothing is rescaled).
    return options.first;
  }

  double _multiplierOf(_ComponentRow row) {
    final parsed = double.tryParse(_selectedOption(row).multiplier);
    return (parsed == null || parsed <= 0) ? 1 : parsed;
  }

  // --------------------------------------------------------------------
  // Informational profitability preview (Issue 2)
  // --------------------------------------------------------------------

  /// Σ(resolved base quantity × product avg_cost) — current PMP only.
  double get _estimatedCost {
    var sum = 0.0;
    for (final row in _components) {
      final entered = double.tryParse(row.quantity.text.trim()) ?? 0;
      final base = entered * _multiplierOf(row);
      final avgCost = double.tryParse(row.avgCost) ?? 0;
      sum += base * avgCost;
    }
    return sum;
  }

  double? get _estimatedMargin {
    final price = double.tryParse(_price.text.trim()) ?? 0;
    if (price == 0) return null; // never divide by zero
    return (_estimatedProfit / price) * 100;
  }

  double get _estimatedProfit {
    final price = double.tryParse(_price.text.trim()) ?? 0;
    return price - _estimatedCost;
  }

  /// Informational only (GATE 3) — never used for pricing or stock.
  /// Component quantities are resolved to BASE units first.
  String get _sumOfParts {
    var sum = 0.0;
    for (final row in _components) {
      final price = double.tryParse(row.productPrice) ?? 0;
      final entered = double.tryParse(row.quantity.text.trim()) ?? 0;
      sum += price * entered * _multiplierOf(row);
    }
    return _fmt(sum);
  }

  String? _validate(String loc) {
    if (_name.text.trim().isEmpty) return AppStrings.t('field_required', loc);
    final price = _price.text.trim();
    if (price.isEmpty) return AppStrings.t('field_required', loc);
    final priceValue = double.tryParse(price);
    if (priceValue == null || priceValue < 0) {
      return AppStrings.t('invalid_amount', loc);
    }
    if (_components.isEmpty) return AppStrings.t('pack_requires_components', loc);
    final seen = <String>{};
    for (final row in _components) {
      if (seen.contains(row.productId)) {
        return AppStrings.t('pack_component_duplicate', loc);
      }
      seen.add(row.productId);
      final qty = double.tryParse(row.quantity.text.trim());
      if (qty == null || qty <= 0) {
        return AppStrings.t('invalid_amount', loc);
      }
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    return {
      'name': _name.text.trim(),
      'barcode': _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      'price': _price.text.trim(),
      'is_active': widget.pack?.isActive ?? true,
      'components': [
        for (final row in _components)
          {
            'product_id': row.productId,
            // Base unit when null — the backend treats "no unit" as
            // base units (unchanged Phase 10 contract).
            'selling_unit_id': row.sellingUnitId,
            'quantity': row.quantity.text.trim(),
          },
      ],
    };
  }

  Future<void> _submit() async {
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

    final notifier = ref.read(packsProvider.notifier);
    final payload = _payload();
    final result = _isEdit
        ? await notifier.update(widget.pack!.id, payload)
        : await notifier.create(payload);

    if (!mounted) return;
    if (result == null) {
      Navigator.pop(context);
      showPosToast(
        context,
        message: AppStrings.t(_isEdit ? 'pack_updated' : 'pack_created', loc),
        kind: PosToastKind.success,
        key: const Key('pack-form-success-toast'),
      );
    } else {
      setState(() {
        _saving = false;
        _error = result;
        _errorDetail = null;
      });
    }
  }

  Future<void> _pickProduct() async {
    final product = await showPackProductPicker(context);
    if (product == null || !mounted) return;
    if (_components.any((row) => row.productId == product.id)) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      setState(() => _error = AppStrings.t('pack_component_duplicate', loc));
      return;
    }
    setState(() {
      _error = null;
      _errorDetail = null;
      _components.add(_ComponentRow(
        productId: product.id,
        productName: product.name,
        productUnit: product.unit,
        productPrice: product.price,
        avgCost: product.avgCost,
        quantity: TextEditingController(text: '1'),
      ));
    });
    await _loadUnits(product.id);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('pack-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_pack' : 'add_pack', loc),
        key: const Key('pack-form-title'),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('pack-name-field'),
                controller: _name,
                enabled: !_saving,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: AppStrings.t('pack_name', loc),
                  counterText: '',
                ),
                onChanged: (_) =>
                    setState(() => _error = null),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('pack-price-field'),
                      controller: _price,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t('price', loc),
                      ),
                      // Live estimate: price changes recompute the preview.
                      onChanged: (_) =>
                          setState(() => _error = null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('pack-barcode-field'),
                      controller: _barcode,
                      enabled: !_saving,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('barcode', loc),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('components', loc),
                      key: const Key('pack-components-label'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${AppStrings.t('sum_of_parts', loc)}: $_sumOfParts',
                    key: const Key('pack-sum-of-parts'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_components.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    AppStrings.t('pack_requires_components', loc),
                    key: const Key('pack-components-empty'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              for (var i = 0; i < _components.length; i++)
                _componentRow(context, loc, theme, i),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('pack-add-component'),
                onPressed: _saving ? null : _pickProduct,
                icon: const Icon(Icons.add, size: 18),
                label: Text(AppStrings.t('add_component', loc)),
              ),
              const SizedBox(height: 12),
              _estimateBox(loc, theme),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('pack-form-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                if (_errorDetail != null && _errorDetail!.isNotEmpty)
                  Text(
                    _errorDetail!,
                    key: const Key('pack-form-error-detail'),
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pack-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('pack-form-submit'),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------
  // Component row (unit selector + quantity + conversion preview)
  // --------------------------------------------------------------------

  Widget _componentRow(
    BuildContext context,
    String loc,
    ThemeData theme,
    int index,
  ) {
    final row = _components[index];
    final unitsLoaded = _units.containsKey(row.productId);
    final options = _optionsFor(row);
    final selected = _selectedOption(row);
    final multiplier = double.tryParse(selected.multiplier) ?? 1;
    final entered = double.tryParse(row.quantity.text.trim()) ?? 0;
    final base = entered * multiplier;
    final hasDropdown = unitsLoaded && _hasUnits(row.productId);

    return Padding(
      key: Key('pack-component-row-$index'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.productName,
                  key: Key('pack-component-name-$index'),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: hasDropdown
                    ? DropdownButton<String?>(
                        key: Key('pack-component-unit-$index'),
                        value: options.any((o) => o.id == row.sellingUnitId)
                            ? row.sellingUnitId
                            : options.first.id,
                        isDense: true,
                        isExpanded: true,
                        items: [
                          for (final option in options)
                            DropdownMenuItem<String?>(
                              value: option.id,
                              child: Text(
                                option.label,
                                key: Key(
                                  'pack-component-unit-option-'
                                  '${option.id ?? 'base'}-$index',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                  row.sellingUnitId = value;
                                  _error = null;
                                }),
                      )
                    : Text(
                        // No selling units: the product's own base unit.
                        unitsLoaded ? row.productUnit : '',
                        key: Key('pack-component-unit-$index'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: TextField(
                  key: Key('pack-component-qty-$index'),
                  controller: row.quantity,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(12),
                  ],
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: AppStrings.t('quantity', loc),
                  ),
                  // Live estimate: quantity changes recompute the preview.
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
              IconButton(
                key: Key('pack-component-remove-$index'),
                tooltip: AppStrings.t('remove_line', loc),
                onPressed: _saving
                    ? null
                    : () => setState(() {
                          _error = null;
                          row.dispose();
                          _components.removeAt(index);
                        }),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          if (unitsLoaded && multiplier != 1)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                '${_fmt(entered)} ${selected.name} = '
                '${_fmt(base)} ${row.productUnit}',
                key: Key('pack-component-preview-$index'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------
  // Estimated profitability preview (Issue 2 — informational only)
  // --------------------------------------------------------------------

  Widget _estimateBox(String loc, ThemeData theme) {
    final cost = _estimatedCost;
    final profit = _estimatedProfit;
    final margin = _estimatedMargin;

    return Container(
      key: const Key('pack-estimate'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppStrings.t('estimated_cost', loc),
                key: const Key('pack-estimated-cost-label'),
                style: theme.textTheme.bodySmall,
              ),
              Text(
                _fmt(cost),
                key: const Key('pack-estimated-cost'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppStrings.t('estimated_profit', loc),
                key: const Key('pack-estimated-profit-label'),
                style: theme.textTheme.bodySmall,
              ),
              Text(
                _fmt(profit),
                key: const Key('pack-estimated-profit'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: profit >= 0 ? theme.colorScheme.primary : null,
                ),
              ),
            ],
          ),
          if (margin != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  AppStrings.t('estimated_margin', loc),
                  key: const Key('pack-estimated-margin-label'),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '${_fmt(margin)}%',
                  key: const Key('pack-estimated-margin'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            AppStrings.t('estimate_pmp_note', loc),
            key: const Key('pack-estimate-note'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Base-product picker (GATE 1 — no variants, ever)
// ---------------------------------------------------------------------------

Future<ProductModel?> showPackProductPicker(BuildContext context) {
  return showDialog<ProductModel>(
    context: context,
    builder: (_) => const PackProductPicker(),
  );
}

class PackProductPicker extends ConsumerStatefulWidget {
  const PackProductPicker({super.key});

  @override
  ConsumerState<PackProductPicker> createState() => _PackProductPickerState();
}

class _PackProductPickerState extends ConsumerState<PackProductPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<ProductModel> _items = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(kSearchDebounce, () => _load(value));
  }

  Future<void> _load(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/products/search',
        queryParameters: {
          if (query.trim().isNotEmpty) 'q': query.trim(),
          'limit': 40,
        },
      );
      if (requestId != _requestId || !mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map((e) => ProductModel.fromJson(e as Map<String, dynamic>))
            .where((p) => !p.isArchived)
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (requestId != _requestId || !mounted) return;
      setState(() {
        _loading = false;
        _error = isConnectionError(e)
            ? AppStrings.t('network_error_retry', _loc)
            : (backendErrorMessage(e) ?? AppStrings.t('api_error_retry', _loc));
      });
    }
  }

  String get _loc =>
      Localizations.localeOf(context).languageCode;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('pack-product-picker'),
      title: Text(AppStrings.t('select_pack_product', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('pack-product-picker-search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: AppStrings.t('search', loc),
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
              ),
              onChanged: _onChanged,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Text(
                          _error!,
                          key: const Key('pack-product-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_products_found', loc),
                              key: const Key('pack-product-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('pack-product-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final p = _items[index];
                                return ListTile(
                                  key: Key('pack-product-option-${p.id}'),
                                  dense: true,
                                  title: Text(p.name),
                                  subtitle: Text(
                                    [
                                      if (p.barcode != null &&
                                          p.barcode!.isNotEmpty)
                                        p.barcode!,
                                      '${AppStrings.t('stock_quantity', loc)}: '
                                          '${p.quantity}',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Text(
                                    p.price,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  onTap: () => Navigator.pop(context, p),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pack-product-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}
