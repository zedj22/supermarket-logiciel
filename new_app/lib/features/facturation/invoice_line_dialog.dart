// Invoice line editor dialog (Phase 8 facturation).
//
// Owns one draft line: optional product selection (searchable picker —
// prefill from products.price HT + products.vat_rate, never promotion /
// wholesale / selling-unit price), a labeled unit-price field plus the
// product's REFERENCE prices (regular, wholesale when configured) as
// chips that populate the editable field — the field is always what the
// line subtotal and document totals are computed from — or a free-text
// line (description + unit_price_ht + tva_rate all required), quantity,
// discount and a computed display line total. Integer milli math only —
// fiscal totals come from the server (preview endpoint), never from
// this dialog.
//
// Keyboard-first: Enter in quantity/price submits the line when valid.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../products/models.dart';
import 'facturation_format.dart';
import 'facturation_models.dart';
import 'facturation_pickers.dart';

/// Returns the staged line, or null when the dialog was dismissed.
Future<DraftInvoiceLine?> showInvoiceLineDialog(
  BuildContext context, {
  DraftInvoiceLine? initial,
}) {
  return showDialog<DraftInvoiceLine>(
    context: context,
    builder: (_) => InvoiceLineDialog(initial: initial),
  );
}

class InvoiceLineDialog extends ConsumerStatefulWidget {
  final DraftInvoiceLine? initial;

  const InvoiceLineDialog({super.key, this.initial});

  @override
  ConsumerState<InvoiceLineDialog> createState() => _InvoiceLineDialogState();
}

class _InvoiceLineDialogState extends ConsumerState<InvoiceLineDialog> {
  ProductModel? _product;

  /// Stage 3A option selection — at most one of (variant, selling unit)
  /// under the product, or a pack alone. Names are display-only; the
  /// ids are what the payload transmits.
  String? _variantId;
  String? _variantName;
  String? _sellingUnitId;
  String? _sellingUnitName;
  String? _packId;
  String? _packName;

  /// Reference-price bookkeeping. [_productDataReal] is true only when
  /// [_product] holds authoritative catalog data — a fresh picker
  /// selection or a successful GET /products/{id} hydration on an edit
  /// round-trip — so reference prices are never guessed from the
  /// id/name-only placeholder built in initState.
  bool _productDataReal = false;
  bool _regularSelected = false;
  bool _wholesaleSelected = false;

  /// Option-context reference price resolved AT PICK TIME (mirrors the
  /// server prefill rules). Null when the option came from a persisted
  /// line, where only ids are stored — nothing is guessed for it.
  String? _variantReference;
  String? _sellingUnitReference;

  late final TextEditingController _description;
  late final TextEditingController _qty;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  int? _tvaRate;
  final bool _saving = false;
  String? _error;

  bool get _isEdit => widget.initial != null;

  /// A line with no product and no pack is free-text (all fields
  /// required); pack lines are server-prefilled summary lines.
  bool get _isFreeText => _product == null && _packId == null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _description = TextEditingController(text: initial?.description ?? '');
    _qty = TextEditingController(text: initial?.quantity ?? '');
    _price = TextEditingController(text: initial?.unitPriceHt ?? '');
    _discount = TextEditingController(text: initial?.discountPct ?? '0');
    _tvaRate = initial?.tvaRate;
    // Rehydrate the full option identity so an edit round-trip keeps
    // variant / selling unit / pack links intact.
    _variantId = initial?.variantId;
    _variantName = initial?.variantName;
    _sellingUnitId = initial?.sellingUnitId;
    _sellingUnitName = initial?.sellingUnitName;
    _packId = initial?.packId;
    _packName = initial?.packName;
    // The persisted line carries only option ids; recover the display
    // name from the "Product · Option" description convention so the
    // buttons don't look unselected on a real edit.
    if (_variantId != null && _variantName == null) {
      _variantName = _optionNameFromDescription(initial?.description);
    }
    if (_sellingUnitId != null && _sellingUnitName == null) {
      _sellingUnitName = _optionNameFromDescription(initial?.description);
    }
    if (_packId != null && _packName == null) {
      _packName = initial?.description.trim();
    }
    if (initial != null && initial.productId != null) {
      _product = ProductModel(
        id: initial.productId!,
        name: initial.productName ?? '',
      );
      // Display-only enrichment: hydrate the real catalog row so the
      // reference-price section can appear on edit round-trips.
      _loadProductDetail();
    }
  }

  /// Rehydrates the full product row for an edit round-trip (the
  /// persisted line carries only ids/names). Best effort — on any
  /// failure the reference section simply stays hidden and the line
  /// remains fully editable.
  Future<void> _loadProductDetail() async {
    final id = widget.initial?.productId;
    if (id == null) return;
    try {
      final dio = ref.read(apiClientProvider).dio;
      final response = await dio.get('/api/v1/products/$id');
      if (!mounted) return;
      final data = response.data;
      if (data is! Map<String, dynamic>) return;
      setState(() {
        _product = ProductModel.fromJson(data);
        _productDataReal = true;
      });
    } catch (_) {
      // Display-only: never block editing on it.
    }
  }

  @override
  void dispose() {
    _description.dispose();
    _qty.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// Recovers the option display name from the "Product · Option"
  /// description convention used by the backend prefill. Returns null
  /// when the description doesn't follow the convention.
  static String? _optionNameFromDescription(String? description) {
    final d = description?.trim() ?? '';
    final i = d.lastIndexOf(' · ');
    if (i < 0 || i + 3 >= d.length) return null;
    return d.substring(i + 3);
  }

  Future<void> _pickProduct() async {
    final product = await showFacturationProductPicker(context);
    if (product == null || !mounted) return;
    setState(() {
      _product = product;
      _productDataReal = true;
      // A new product invalidates any option of the previous identity.
      _variantId = null;
      _variantName = null;
      _sellingUnitId = null;
      _sellingUnitName = null;
      _packId = null;
      _packName = null;
      _variantReference = null;
      _sellingUnitReference = null;
      _regularSelected = false;
      _wholesaleSelected = false;
      // Prefill = products.price (HT) + products.vat_rate — never
      // promotion / wholesale price (Phase 8 rule). The prefilled
      // regular price marks its reference chip; a hand-typed price is
      // left untouched and marks no chip.
      _description.text = product.name;
      if (_price.text.trim().isEmpty) {
        _price.text = product.price;
        _regularSelected = true;
      }
      _tvaRate ??= kTvaRates.contains(product.vatRate) ? product.vatRate : 0;
      _error = null;
    });
  }

  Future<void> _pickVariant() async {
    final product = _product;
    if (product == null) return;
    final variant = await showFacturationVariantPicker(
      context,
      productId: product.id,
    );
    if (variant == null || !mounted) return;
    setState(() {
      _variantId = variant.id;
      _variantName = variant.name;
      // Variant XOR selling unit (SaleService parity).
      _sellingUnitId = null;
      _sellingUnitName = null;
      _sellingUnitReference = null;
      // Selection belongs to the previous option context.
      _regularSelected = false;
      _wholesaleSelected = false;
      _description.text = '${product.name} · ${variant.name}';
      // variant.price when configured, else products.price AS-IS
      // (server-side rule mirrored for prefill UX only), resolved at
      // pick time so the reference chip always shows the true context
      // price.
      final reference = variant.price ?? product.price;
      _variantReference = reference;
      if (_price.text.trim().isEmpty) {
        _price.text = reference;
        _regularSelected = true;
      }
      _tvaRate ??= kTvaRates.contains(product.vatRate) ? product.vatRate : 0;
      _error = null;
    });
  }

  Future<void> _pickSellingUnit() async {
    final product = _product;
    if (product == null) return;
    final unit = await showFacturationSellingUnitPicker(
      context,
      productId: product.id,
    );
    if (unit == null || !mounted) return;
    setState(() {
      _sellingUnitId = unit.id;
      _sellingUnitName = unit.name;
      // Selling unit XOR variant (SaleService parity).
      _variantId = null;
      _variantName = null;
      _variantReference = null;
      _regularSelected = false;
      _wholesaleSelected = false;
      _description.text = '${product.name} · ${unit.name}';
      // effective_price (selling_price when configured, else the
      // product price AS-IS — the multiplier never multiplies price),
      // resolved at pick time for the reference chip.
      final reference =
          unit.effectivePrice ?? unit.sellingPrice ?? product.price;
      _sellingUnitReference = reference;
      if (_price.text.trim().isEmpty) {
        _price.text = reference;
        _regularSelected = true;
      }
      _tvaRate ??= kTvaRates.contains(product.vatRate) ? product.vatRate : 0;
      _error = null;
    });
  }

  Future<void> _pickPack() async {
    final pack = await showFacturationPackPicker(context);
    if (pack == null || !mounted) return;
    setState(() {
      // Pack XOR product (backend contract).
      _packId = pack.id;
      _packName = pack.name;
      _product = null;
      _productDataReal = false;
      _variantId = null;
      _variantName = null;
      _sellingUnitId = null;
      _sellingUnitName = null;
      _variantReference = null;
      _sellingUnitReference = null;
      _regularSelected = false;
      _wholesaleSelected = false;
      _description.text = pack.name;
      _price.text = pack.price;
      _tvaRate ??= 0;
      _error = null;
    });
  }

  void _clearProduct() {
    setState(() {
      _product = null;
      _productDataReal = false;
      _variantId = null;
      _variantName = null;
      _sellingUnitId = null;
      _sellingUnitName = null;
      _packId = null;
      _packName = null;
      _variantReference = null;
      _sellingUnitReference = null;
      _regularSelected = false;
      _wholesaleSelected = false;
      _error = null;
    });
  }

  /// Wholesale is only meaningful for a plain base-unit product line —
  /// SaleService never quotes it under a variant or selling unit.
  bool get _isPlainProductLine =>
      _product != null && _variantId == null && _sellingUnitId == null;

  /// Wholesale configured per the server rule: BOTH fields present and
  /// wholesale_min_qty > 0 (anything else is treated as unconfigured).
  bool get _wholesaleConfigured {
    final product = _product;
    if (product == null) return false;
    final minQty = double.tryParse(product.wholesaleMinQty ?? '');
    return product.wholesalePrice != null && minQty != null && minQty > 0;
  }

  /// Regular reference price for the CURRENT option context, or null
  /// when the dialog holds no trustworthy data for it (id-only edit
  /// before the product detail lands, or a restored option whose price
  /// was never observed).
  String? get _regularReference {
    if (_product == null || !_productDataReal) return null;
    if (_variantId != null) return _variantReference;
    if (_sellingUnitId != null) return _sellingUnitReference;
    return _product!.price;
  }

  /// Applies a reference price to the editable unit-price field — the
  /// chips are shortcuts into the field; the field (not the chip) is
  /// what every total is computed from.
  void _applyReference({required bool wholesale}) {
    final value = wholesale ? _product?.wholesalePrice : _regularReference;
    if (value == null || value.trim().isEmpty) return;
    setState(() {
      _price.text = value;
      _regularSelected = !wholesale;
      _wholesaleSelected = wholesale;
      _error = null;
    });
  }

  String? _validate(String loc) {
    final isFreeText = _isFreeText;
    if (isFreeText && _description.text.trim().isEmpty) {
      return AppStrings.t('field_required', loc);
    }
    final qtyText = _qty.text.trim();
    if (qtyText.isEmpty) return AppStrings.t('invalid_qty', loc);
    final qtyMilli = qtyToMilli(qtyText);
    if (qtyMilli == null || qtyMilli <= 0) {
      return AppStrings.t('invalid_qty', loc);
    }
    final priceText = _price.text.trim();
    // Free-text lines REQUIRE a price; product / pack lines may leave it
    // empty so the server prefills from its authoritative source.
    if (isFreeText && priceText.isEmpty) {
      return AppStrings.t('invalid_amount', loc);
    }
    if (priceText.isNotEmpty && moneyToMilli(priceText) == null) {
      return AppStrings.t('invalid_amount', loc);
    }
    if (isFreeText && _tvaRate == null) {
      return AppStrings.t('tva_rate', loc);
    }
    final discountText = _discount.text.trim();
    if (discountText.isNotEmpty) {
      final discount = pctToMilli(discountText);
      if (discount == null) return AppStrings.t('invalid_amount', loc);
      if (discount > 100000) return AppStrings.t('invalid_amount', loc);
    }
    return null;
  }

  void _submit(String loc) {
    final validation = _validate(loc);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    final product = _product;
    Navigator.pop(
      context,
      DraftInvoiceLine(
        productId: product?.id,
        productName: product?.name,
        variantId: _variantId,
        variantName: _variantName,
        sellingUnitId: _sellingUnitId,
        sellingUnitName: _sellingUnitName,
        packId: _packId,
        packName: _packName,
        description: _description.text.trim(),
        quantity: _qty.text.trim(),
        unitPriceHt: _price.text.trim(),
        tvaRate: _tvaRate,
        discountPct: _discount.text.trim().isEmpty
            ? '0'
            : _discount.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final isFreeText = _isFreeText;
    final hasPack = _packId != null;
    final hasProduct = _product != null;

    final previewLine = DraftInvoiceLine(
      productId: _product?.id,
      productName: _product?.name,
      variantId: _variantId,
      sellingUnitId: _sellingUnitId,
      packId: _packId,
      description: _description.text,
      quantity: _qty.text,
      unitPriceHt: _price.text,
      tvaRate: _tvaRate,
      discountPct: _discount.text,
    );

    final identityLabel = hasPack
        ? (_packName ?? AppStrings.t('pack', loc))
        : _product?.name ?? AppStrings.t('free_text_line', loc);

    return AlertDialog(
      key: const Key('invoice-line-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_line' : 'add_line', loc),
        key: const Key('invoice-line-title'),
      ),
      content: SizedBox(
        width: 560,
        // The reference-price section grows the dialog — scroll instead
        // of overflowing on short windows / small devices.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      identityLabel,
                      key: const Key('invoice-line-product'),
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasProduct || hasPack)
                    OutlinedButton.icon(
                      key: const Key('invoice-line-clear-product'),
                      onPressed: _saving ? null : _clearProduct,
                      icon: const Icon(Icons.clear, size: 18),
                      label: Text(AppStrings.t('free_text_line', loc)),
                    ),
                  OutlinedButton.icon(
                    key: const Key('invoice-line-pick-product'),
                    onPressed: _saving ? null : _pickProduct,
                    icon: const Icon(Icons.search, size: 18),
                    label: Text(
                      AppStrings.t(
                        hasProduct ? 'change_product' : 'select_product',
                        loc,
                      ),
                    ),
                  ),
                ],
              ),
              if (hasProduct) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('invoice-line-pick-variant'),
                        onPressed: _saving ? null : _pickVariant,
                        icon: const Icon(Icons.category_outlined, size: 18),
                        label: Text(
                          _variantName == null
                              ? AppStrings.t('select_variant', loc)
                              : '${AppStrings.t('variants', loc)}: ${_variantName!}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('invoice-line-pick-selling-unit'),
                        onPressed: _saving ? null : _pickSellingUnit,
                        icon: const Icon(Icons.straighten, size: 18),
                        label: Text(
                          _sellingUnitName == null
                              ? AppStrings.t('select_selling_unit', loc)
                              : '${AppStrings.t('selling_units', loc)}: ${_sellingUnitName!}',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (!hasProduct && !hasPack) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('invoice-line-pick-pack'),
                  onPressed: _saving ? null : _pickPack,
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: Text(AppStrings.t('select_pack', loc)),
                ),
              ],
              if (isFreeText) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('invoice-line-description'),
                  controller: _description,
                  enabled: !_saving,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('description', loc),
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
              ],
              if (hasProduct && _regularReference != null) ...[
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('reference_prices', loc),
                  key: const Key('invoice-line-reference-prices'),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      key: const Key('invoice-line-ref-regular'),
                      label: Text(
                        '${AppStrings.t('regular_price', loc)}: '
                        '${formatDisplayMoney(_regularReference!, loc)}',
                      ),
                      selected: _regularSelected,
                      onSelected: _saving
                          ? null
                          : (_) => _applyReference(wholesale: false),
                    ),
                    if (_isPlainProductLine)
                      ChoiceChip(
                        key: const Key('invoice-line-ref-wholesale'),
                        label: Text(
                          _wholesaleConfigured
                              ? '${AppStrings.t('wholesale_price', loc)}: '
                                    '${formatDisplayMoney(_product!.wholesalePrice!, loc)}'
                              : AppStrings.t('wholesale_price', loc),
                        ),
                        selected: _wholesaleSelected,
                        onSelected: _saving || !_wholesaleConfigured
                            ? null
                            : (_) => _applyReference(wholesale: true),
                      ),
                  ],
                ),
                if (_isPlainProductLine && !_wholesaleConfigured) ...[
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t('wholesale_price_unavailable', loc),
                    key: const Key('invoice-line-wholesale-unavailable'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
                if (_isPlainProductLine && _wholesaleConfigured) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${AppStrings.t('wholesale_min_qty', loc)}: '
                    '${_product!.wholesaleMinQty}',
                    key: const Key('invoice-line-wholesale-min-qty'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('invoice-line-qty'),
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
                      key: const Key('invoice-line-price'),
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
                        labelText: AppStrings.t('unit_price_da', loc),
                        hintText: isFreeText
                            ? null
                            : AppStrings.t('prefill_price', loc),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(loc),
                      onChanged: (_) => setState(() {
                        _error = null;
                        // A hand-typed price is neither reference — the
                        // selection must never mask what the field holds.
                        _regularSelected = false;
                        _wholesaleSelected = false;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      key: const Key('invoice-line-tva'),
                      initialValue: _tvaRate,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('tva_rate', loc),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem<int?>(
                          value: null,
                          child: Text(AppStrings.t('select', loc)),
                        ),
                        ...kTvaRates.map(
                          (rate) => DropdownMenuItem<int?>(
                            value: rate,
                            child: Text('$rate%'),
                          ),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              _tvaRate = value;
                              _error = null;
                            }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('invoice-line-discount'),
                      controller: _discount,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t('discount_pct', loc),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _submit(loc),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                ],
              ),
              if (previewLine.lineHtMilli > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '${AppStrings.t('line_total', loc)}: '
                  '${formatDisplayMoney(previewLine.lineHt, loc)}'
                  '${previewLine.lineTvaMilli > 0 ? ' + ${AppStrings.t('tva', loc)} ${formatDisplayMoney(previewLine.lineTva, loc)}' : ''}',
                  key: const Key('invoice-line-total'),
                  style: theme.textTheme.titleMedium,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('invoice-line-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('invoice-line-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('invoice-line-submit'),
          onPressed: _saving ? null : () => _submit(loc),
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
