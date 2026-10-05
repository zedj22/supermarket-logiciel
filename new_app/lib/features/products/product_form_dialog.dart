// Create/edit product dialog (Phase 5, UI refinement).
//
// Responsive sectioned form:
//   Product Information | Pricing | Additional Information | Product Image | Actions
// Two-column fields on wide screens; single-column scrollable form on narrow
// (usable at 600×500). Image path is set via ProductImagePickerService
// (native file picker) with preview / choose / replace / remove — never a
// raw path text field. Cancel closes without error; missing/invalid path
// renders a placeholder (no crash).
//
// Stock (Phase 17):
//   `PUT /products/{id}` has NO `quantity` field — sending one was silently
//   dropped by Pydantic, so the quantity appeared to save while the backend
//   never changed it. Quantity is now:
//     * create → still sent in the body (the create endpoint seeds stock);
//     * edit + `inventory_adjust` → PUT first, then an audited
//       `POST /inventory/adjust` with `operation: set`; the dialog only
//       reports success when BOTH calls succeed;
//     * edit without `inventory_adjust` → read-only, with a route to /stock.
//   PUT runs before the adjustment so a rejected adjustment leaves the
//   dialog open (and the product data saved) instead of a false success.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import 'models.dart';
import 'product_image_picker_service.dart';
import 'products_providers.dart';
import 'purchase_unit_form_dialog.dart';
import 'selling_unit_form_dialog.dart';
import 'variant_form_dialog.dart';

const List<String> kProductUnits = [
  'piece',
  'kg',
  'gram',
  'liter',
  'milliliter',
  'meter',
  'pack',
];

Future<void> showProductFormDialog(
  BuildContext context, {
  ProductModel? product,
}) {
  return showDialog(
    context: context,
    builder: (_) => ProductFormDialog(product: product),
  );
}

class ProductFormDialog extends ConsumerStatefulWidget {
  final ProductModel? product;

  const ProductFormDialog({super.key, this.product});

  @override
  ConsumerState<ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends ConsumerState<ProductFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _sku;
  late final TextEditingController _price;
  late final TextEditingController _cost;
  late final TextEditingController _quantity;
  late final TextEditingController _threshold;
  late final TextEditingController _description;
  late final TextEditingController _expiryDate;

  String? _categoryId;
  String _unit = 'piece';
  String? _imagePath;
  bool _saving = false;
  String? _error;

  // Staged children (create mode) — submitted atomically with the product.
  final List<VariantModel> _stagedVariants = <VariantModel>[];
  final List<SellingUnitModel> _stagedSellingUnits = <SellingUnitModel>[];
  final List<PurchaseUnitModel> _stagedPurchaseUnits = <PurchaseUnitModel>[];
  int _stagedSeq = 0;

  bool get _isEdit => widget.product != null;

  /// The quantity the user wants, as a backend decimal string.
  String get _quantityValue =>
      _quantity.text.trim().isEmpty ? '0' : _quantity.text.trim();

  /// True when the stock value actually moved — compared numerically so
  /// `240` and `240.000` are the same stock, never a phantom adjustment.
  bool get _quantityChanged {
    if (!_isEdit) return false;
    final next = num.tryParse(_quantityValue);
    final current = num.tryParse(widget.product!.quantity);
    if (next == null || current == null) return false;
    return next != current;
  }

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _name = TextEditingController(text: p?.name ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _sku = TextEditingController(text: p?.sku ?? '');
    _price = TextEditingController(text: p != null ? _trimDecimal(p.price) : '');
    _cost = TextEditingController(text: p != null ? _trimDecimal(p.cost) : '');
    _quantity = TextEditingController(
      text: p != null ? _trimDecimal(p.quantity) : '',
    );
    _threshold = TextEditingController(
      text: p != null ? _trimDecimal(p.lowStockThreshold) : '',
    );
    _description = TextEditingController(text: p?.description ?? '');
    _expiryDate = TextEditingController(text: p?.expiryDate ?? '');
    _categoryId = p?.categoryId;
    _unit = p?.unit ?? 'piece';
    _imagePath = p?.imagePath;

    // Ensure category options are available for the dropdown.
    Future.microtask(
      () => ref.read(categoriesProvider.notifier).load(status: 'active'),
    );
    // Load variants + selling units for edit mode (on demand — no N+1 on list).
    // Defensive: missing stubs / offline must not crash the dialog.
    if (_isEdit) {
      final pid = widget.product!.id;
      Future.microtask(() async {
        try {
          await ref
              .read(variantsProvider.notifier)
              .load(pid, includeArchived: true);
        } catch (_) {
          // leave variants empty — section shows empty state
        }
        try {
          await ref
              .read(sellingUnitsProvider.notifier)
              .load(pid, includeArchived: true);
        } catch (_) {
          // leave selling units empty
        }
        try {
          await ref
              .read(purchaseUnitsProvider.notifier)
              .load(pid, includeArchived: true);
        } catch (_) {
          // leave purchase units empty
        }
      });
    }
  }

  /// Strip the fractional zeros of a backend decimal for display.
  ///
  /// Only touches what sits AFTER the decimal point: `240.000` → `240`,
  /// `10.10` → `10.1`, and a plain integer is returned untouched. The
  /// earlier `\.?0+$` pattern also matched the trailing zeros of `100`
  /// and showed `1` — which would then have been saved as a real stock
  /// set once quantity became persistable.
  static String _trimDecimal(String value) {
    if (!value.contains('.')) return value;
    final trimmed = value.replaceFirst(RegExp(r'0+$'), '');
    if (!trimmed.endsWith('.')) return trimmed;
    return trimmed.substring(0, trimmed.length - 1);
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _sku.dispose();
    _price.dispose();
    _cost.dispose();
    _quantity.dispose();
    _threshold.dispose();
    _description.dispose();
    _expiryDate.dispose();
    super.dispose();
  }

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (_name.text.trim().isEmpty) return AppStrings.t('name', loc);
    final price = num.tryParse(_price.text.trim());
    if (price == null || price < 0) return '${AppStrings.t('price', loc)} ≥ 0';
    for (final pair in [
      ('cost', _cost.text),
      ('quantity', _quantity.text),
      ('threshold', _threshold.text),
    ]) {
      final text = pair.$2.trim();
      if (text.isEmpty) continue;
      final n = num.tryParse(text);
      if (n == null || n < 0) {
        return '${AppStrings.t(pair.$1 == 'threshold' ? 'low_stock_threshold' : pair.$1, loc)} ≥ 0';
      }
    }
    final expiry = _expiryDate.text.trim();
    if (expiry.isNotEmpty && DateTime.tryParse(expiry) == null) {
      return AppStrings.t('expiry_date', loc);
    }
    final path = _imagePath?.trim();
    if (path != null &&
        path.isNotEmpty &&
        !ref.read(productImagePickerProvider).isSupportedPath(path)) {
      return AppStrings.t('unsupported_image', loc);
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    String? nonEmpty(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    final image = _imagePath?.trim();
    return {
      'name': _name.text.trim(),
      if (nonEmpty(_barcode) != null) 'barcode': nonEmpty(_barcode),
      if (nonEmpty(_sku) != null) 'sku': nonEmpty(_sku),
      'unit': _unit,
      'price': _price.text.trim(),
      'cost': _cost.text.trim().isEmpty ? '0' : _cost.text.trim(),
      // Stock is not a product field on edit (see the header comment):
      // including it would be dropped by the backend and report a false
      // success. Create still seeds the initial quantity atomically.
      if (!_isEdit)
        'quantity': _quantity.text.trim().isEmpty ? '0' : _quantity.text.trim(),
      'low_stock_threshold': _threshold.text.trim().isEmpty
          ? '5'
          : _threshold.text.trim(),
      if (nonEmpty(_description) != null)
        'description': nonEmpty(_description),
      if (image != null && image.isNotEmpty) 'image_path': image,
      if (nonEmpty(_expiryDate) != null) 'expiry_date': nonEmpty(_expiryDate),
      if (_categoryId != null) 'category_id': _categoryId,
      // Create mode only: staged children ride along for atomic create.
      if (!_isEdit) ...{
        'variants': [
          for (final v in _stagedVariants) _variantPayload(v),
        ],
        'selling_units': [
          for (final u in _stagedSellingUnits) _sellingUnitPayload(u),
        ],
        'purchase_units': [
          for (final u in _stagedPurchaseUnits) _purchaseUnitPayload(u),
        ],
      },
    };
  }

  static Map<String, dynamic> _variantPayload(VariantModel v) => {
        'name': v.name,
        if (v.barcode != null && v.barcode!.trim().isNotEmpty)
          'barcode': v.barcode,
        if (v.sku != null && v.sku!.trim().isNotEmpty) 'sku': v.sku,
        if (v.price != null) 'price': v.price,
        if (v.cost != null) 'cost': v.cost,
        'quantity': v.quantity,
      };

  static Map<String, dynamic> _sellingUnitPayload(SellingUnitModel u) => {
        'name': u.name,
        'unit_type': u.unitType,
        'multiplier': u.multiplier,
        if (u.barcode != null && u.barcode!.trim().isNotEmpty)
          'barcode': u.barcode,
        'selling_price': u.sellingPrice,
        'is_base_unit': u.isBaseUnit,
      };

  static Map<String, dynamic> _purchaseUnitPayload(PurchaseUnitModel u) => {
        'name': u.name,
        'unit_type': u.unitType,
        'multiplier': u.multiplier,
        if (u.barcode != null && u.barcode!.trim().isNotEmpty)
          'barcode': u.barcode,
        'is_default': u.isDefault,
      };

  String _stagedId(String prefix) => 'staged-$prefix-${++_stagedSeq}';

  Future<void> _pickImage() async {
    final picker = ref.read(productImagePickerProvider);
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final path = await picker.pickImage();
    // Cancel or unsupported → leave current selection unchanged, no error.
    if (path == null) return;
    if (!picker.isSupportedPath(path)) {
      if (mounted) {
        setState(() => _error = AppStrings.t('unsupported_image', loc));
      }
      return;
    }
    if (mounted) {
      setState(() {
        _imagePath = path;
        _error = null;
      });
    }
  }

  void _removeImage() {
    setState(() => _imagePath = null);
  }

  /// Without `inventory_adjust` the quantity is read-only here — send the
  /// user to the audited stock screen instead of pretending the field works.
  void _goToStock() {
    final router = GoRouter.of(context);
    Navigator.pop(context);
    router.go('/stock');
  }

  Future<void> _submit() async {
    final validation = _validate();
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final canAdjust = ref.read(hasPermissionProvider('inventory_adjust'));
    final notifier = ref.read(productsProvider.notifier);
    final payload = _payload();
    final error = _isEdit
        ? await notifier.updateProduct(widget.product!.id, payload)
        : await notifier.createProduct(payload);

    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }

    // Edit + moved stock → the audited inventory SET operation. Only now,
    // so a rejected adjustment keeps this dialog open with a visible error
    // instead of closing on a success toast that never landed in stock.
    var stockChanged = false;
    if (_isEdit && canAdjust && _quantityChanged) {
      final stockError = await notifier.setStock(
        widget.product!.id,
        _quantityValue,
        AppStrings.t('product_stock_reason', loc),
      );
      if (!mounted) return;
      if (stockError != null) {
        setState(() {
          _saving = false;
          _error = stockError;
        });
        return;
      }
      stockChanged = true;
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.t(
            _isEdit
                ? (stockChanged
                    ? 'product_and_stock_updated'
                    : 'product_updated')
                : 'product_created',
            loc,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canSeeCost = ref.watch(hasPermissionProvider('product_update'));
    final canCreate = ref.watch(hasPermissionProvider('product_create'));
    final canUpdate = ref.watch(hasPermissionProvider('product_update'));
    final canArchive = ref.watch(hasPermissionProvider('product_archive'));
    // Stock can only be saved through the inventory journal, so the
    // quantity field is a real input only for holders of that scope.
    final canAdjustStock = ref.watch(hasPermissionProvider('inventory_adjust'));
    final quantityReadOnly = _isEdit && !canAdjustStock;
    final categories = ref.watch(categoriesProvider).activeItems;
    final variantsState = ref.watch(variantsProvider);
    final sellingUnitsState = ref.watch(sellingUnitsProvider);
    final purchaseUnitsState = ref.watch(purchaseUnitsProvider);
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('product-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_product' : 'add_product', loc),
      ),
      content: SizedBox(
        width: 560,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 480;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    theme,
                    AppStrings.t('product_information', loc),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('product-name-field'),
                    controller: _name,
                    decoration:
                        InputDecoration(labelText: AppStrings.t('name', loc)),
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    narrow: narrow,
                    children: [
                      TextField(
                        key: const Key('product-barcode-field'),
                        controller: _barcode,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('barcode', loc),
                        ),
                      ),
                      TextField(
                        controller: _sku,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('sku', loc),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    narrow: narrow,
                    children: [
                      DropdownButtonFormField<String>(
                        key: const Key('product-unit-field'),
                        initialValue: _unit,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('unit', loc),
                        ),
                        items: [
                          for (final u in kProductUnits)
                            DropdownMenuItem(
                              value: u,
                              child: Text(AppStrings.unitLabel(u, loc)),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _unit = v);
                        },
                      ),
                      DropdownButtonFormField<String?>(
                        key: const Key('product-category-field'),
                        initialValue: _categoryId,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('category', loc),
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(AppStrings.t('no_category', loc)),
                          ),
                          for (final c in categories)
                            DropdownMenuItem<String?>(
                              value: c.id,
                              child: Text(c.name),
                            ),
                        ],
                        onChanged: (v) => setState(() => _categoryId = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _sectionHeader(theme, AppStrings.t('pricing', loc)),
                  const SizedBox(height: 8),
                  _fieldRow(
                    narrow: narrow,
                    children: [
                      TextField(
                        key: const Key('product-price-field'),
                        controller: _price,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: AppStrings.t('price', loc),
                        ),
                      ),
                      if (canSeeCost)
                        TextField(
                          controller: _cost,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: AppStrings.t('cost', loc),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _fieldRow(
                    narrow: narrow,
                    children: [
                      TextField(
                        key: const Key('product-quantity-field'),
                        controller: _quantity,
                        readOnly: quantityReadOnly,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: AppStrings.t('quantity', loc),
                          helperText: quantityReadOnly
                              ? AppStrings.t('quantity_readonly', loc)
                              : null,
                        ),
                      ),
                      TextField(
                        controller: _threshold,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: AppStrings.t('low_stock_threshold', loc),
                        ),
                      ),
                    ],
                  ),
                  if (quantityReadOnly) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const Key('product-quantity-open-stock'),
                        onPressed: _goToStock,
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: Text(AppStrings.t('adjust_stock', loc)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _sectionHeader(
                    theme,
                    AppStrings.t('additional_information', loc),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _description,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: AppStrings.t('description', loc),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _expiryDate,
                    decoration: InputDecoration(
                      labelText:
                          '${AppStrings.t('expiry_date', loc)} (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionHeader(theme, AppStrings.t('product_image', loc)),
                  const SizedBox(height: 8),
                    _imageSection(loc),
                    // Phase 6 — variants (create stages locally; edit loads via API)
                    const SizedBox(height: 16),
                    _sectionHeader(
                      theme,
                      AppStrings.t('manage_variants', loc),
                    ),
                    const SizedBox(height: 8),
                    _variantsSection(
                      loc,
                      state: variantsState,
                      canCreate: canCreate,
                      canUpdate: canUpdate,
                      canArchive: canArchive,
                    ),
                    // Phase 6 — selling units
                    const SizedBox(height: 16),
                    _sectionHeader(
                      theme,
                      AppStrings.t('manage_selling_units', loc),
                    ),
                    const SizedBox(height: 8),
                    _sellingUnitsSection(
                      loc,
                      state: sellingUnitsState,
                      canCreate: canCreate,
                      canUpdate: canUpdate,
                      canArchive: canArchive,
                    ),
                    // Phase 6 correction — purchase units
                    const SizedBox(height: 16),
                    _sectionHeader(
                      theme,
                      AppStrings.t('manage_purchase_units', loc),
                    ),
                    const SizedBox(height: 8),
                    _purchaseUnitsSection(
                      loc,
                      state: purchaseUnitsState,
                      canCreate: canCreate,
                      canUpdate: canUpdate,
                      canArchive: canArchive,
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      key: const Key('product-form-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('product-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('product-form-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        Divider(
          height: 1,
          thickness: 1,
          color: theme.colorScheme.outline.withValues(alpha: 0.18),
        ),
      ],
    );
  }

  /// Phase 6 — variants list with add/edit/archive.
  /// Create mode: staged local rows (submitted with the product).
  /// Edit mode: loaded via variantsProvider (includeArchived).
  Widget _variantsSection(
    String loc, {
    required VariantsState state,
    required bool canCreate,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final theme = Theme.of(context);
    final items = _isEdit ? state.items : _stagedVariants;
    final pid = _isEdit ? widget.product!.id : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canCreate)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('add-variant-button'),
              onPressed: () async {
                final result = await showVariantFormDialog(
                  context,
                  productId: pid,
                  staged: !_isEdit,
                );
                if (result is Map<String, dynamic>) {
                  if (!mounted) return;
                  setState(() {
                    _stagedVariants.add(
                      VariantModel(
                        id: _stagedId('var'),
                        productId: '',
                        name: '${result['name']}',
                        barcode: result['barcode'] as String?,
                        sku: result['sku'] as String?,
                        price: result['price']?.toString(),
                        cost: result['cost']?.toString(),
                        quantity: '${result['quantity'] ?? '0'}',
                      ),
                    );
                  });
                } else if (result == true && pid != null) {
                  ref.read(variantsProvider.notifier).load(
                        pid,
                        includeArchived: true,
                      );
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(AppStrings.t('add_variant', loc)),
            ),
          ),
        if (_isEdit && state.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (items.isEmpty)
          Text(
            AppStrings.t('no_variants', loc),
            key: const Key('variants-empty'),
            style: theme.textTheme.bodySmall,
          )
        else
          for (final v in items)
            Padding(
              key: Key('variant-row-${v.id}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${v.name}'
                      '${v.price != null ? ' · ${v.price}' : ''}'
                      '${v.barcode != null ? ' · ${v.barcode}' : ''}'
                      '${v.isArchived ? ' · ${AppStrings.t('archived_variant', loc)}' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (v.isArchived)
                    Padding(
                      key: Key('variant-archived-badge-${v.id}'),
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Icon(
                        Icons.archive_outlined,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  if (canUpdate && !v.isArchived && _isEdit)
                    IconButton(
                      key: Key('edit-variant-${v.id}'),
                      tooltip: AppStrings.t('edit_variant', loc),
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () async {
                        final ok = await showVariantFormDialog(
                          context,
                          productId: pid,
                          variant: v,
                        );
                        if (ok == true && pid != null && mounted) {
                          ref.read(variantsProvider.notifier).load(
                                pid,
                                includeArchived: true,
                              );
                        }
                      },
                    ),
                  if (canArchive && !v.isArchived && _isEdit)
                    IconButton(
                      key: Key('archive-variant-${v.id}'),
                      tooltip: AppStrings.t('archive_variant', loc),
                      icon: const Icon(Icons.archive_outlined, size: 18),
                      onPressed: () async {
                        final err = await ref
                            .read(variantsProvider.notifier)
                            .archive(pid!, v.id);
                        if (!mounted) return;
                        if (err != null) {
                          setState(() => _error = err);
                        } else {
                          _showArchiveSnack(loc, 'variant_archived');
                        }
                      },
                    ),
                  if (!_isEdit && canUpdate)
                    IconButton(
                      key: Key('remove-staged-variant-${v.id}'),
                      tooltip: AppStrings.t('delete', loc),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(
                        () => _stagedVariants.removeWhere(
                          (x) => x.id == v.id,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// Phase 6 — selling units list with add/edit/archive.
  Widget _sellingUnitsSection(
    String loc, {
    required SellingUnitsState state,
    required bool canCreate,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final theme = Theme.of(context);
    final items = _isEdit ? state.items : _stagedSellingUnits;
    final pid = _isEdit ? widget.product!.id : null;
    final hasBase = items.any((u) => u.isBaseUnit && !u.isArchived);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canCreate)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('add-selling-unit-button'),
              onPressed: () async {
                final result = await showSellingUnitFormDialog(
                  context,
                  productId: pid,
                  canCreateBaseUnit: !hasBase,
                  staged: !_isEdit,
                );
                if (result is Map<String, dynamic>) {
                  if (!mounted) return;
                  setState(() {
                    _stagedSellingUnits.add(
                      SellingUnitModel(
                        id: _stagedId('su'),
                        productId: '',
                        name: '${result['name']}',
                        unitType: '${result['unit_type'] ?? 'piece'}',
                        multiplier: '${result['multiplier'] ?? '1'}',
                        barcode: result['barcode'] as String?,
                        sellingPrice: result['selling_price']?.toString(),
                        isBaseUnit: result['is_base_unit'] as bool? ?? false,
                      ),
                    );
                  });
                } else if (result == true && pid != null) {
                  ref.read(sellingUnitsProvider.notifier).load(
                        pid,
                        includeArchived: true,
                      );
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(AppStrings.t('add_selling_unit', loc)),
            ),
          ),
        if (_isEdit && state.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (items.isEmpty)
          Text(
            AppStrings.t('no_selling_units', loc),
            key: const Key('selling-units-empty'),
            style: theme.textTheme.bodySmall,
          )
        else
          for (final u in items)
            Padding(
              key: Key('selling-unit-row-${u.id}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${u.name}'
                      ' · ${AppStrings.unitLabel(u.unitType, loc)}'
                      ' · ×${u.multiplier}'
                      '${u.sellingPrice != null ? ' · ${u.sellingPrice}' : ''}'
                      '${u.isBaseUnit ? ' · ${AppStrings.t('base_unit', loc)}' : ''}'
                      '${u.isArchived ? ' · ${AppStrings.t('archived_unit', loc)}' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (u.isArchived)
                    Padding(
                      key: Key('selling-unit-archived-badge-${u.id}'),
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Icon(
                        Icons.archive_outlined,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  if (canUpdate && !u.isArchived && _isEdit)
                    IconButton(
                      key: Key('edit-selling-unit-${u.id}'),
                      tooltip: AppStrings.t('edit_selling_unit', loc),
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () async {
                        final ok = await showSellingUnitFormDialog(
                          context,
                          productId: pid,
                          unit: u,
                          canCreateBaseUnit: !hasBase,
                        );
                        if (ok == true && pid != null && mounted) {
                          ref.read(sellingUnitsProvider.notifier).load(
                                pid,
                                includeArchived: true,
                              );
                        }
                      },
                    ),
                  if (canArchive && !u.isArchived && _isEdit)
                    IconButton(
                      key: Key('archive-selling-unit-${u.id}'),
                      tooltip: AppStrings.t('archive_selling_unit', loc),
                      icon: const Icon(Icons.archive_outlined, size: 18),
                      onPressed: () async {
                        final err = await ref
                            .read(sellingUnitsProvider.notifier)
                            .archive(pid!, u.id);
                        if (!mounted) return;
                        if (err != null) {
                          setState(() => _error = err);
                        } else {
                          _showArchiveSnack(loc, 'selling_unit_archived');
                        }
                      },
                    ),
                  if (!_isEdit && canUpdate)
                    IconButton(
                      key: Key('remove-staged-selling-unit-${u.id}'),
                      tooltip: AppStrings.t('delete', loc),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(
                        () => _stagedSellingUnits.removeWhere(
                          (x) => x.id == u.id,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// Phase 6 correction — purchase units list with add/edit/archive.
  Widget _purchaseUnitsSection(
    String loc, {
    required PurchaseUnitsState state,
    required bool canCreate,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final theme = Theme.of(context);
    final items = _isEdit ? state.items : _stagedPurchaseUnits;
    final pid = _isEdit ? widget.product!.id : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canCreate)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('add-purchase-unit-button'),
              onPressed: () async {
                final result = await showPurchaseUnitFormDialog(
                  context,
                  productId: pid,
                  staged: !_isEdit,
                );
                if (result is Map<String, dynamic>) {
                  if (!mounted) return;
                  setState(() {
                    _stagedPurchaseUnits.add(
                      PurchaseUnitModel(
                        id: _stagedId('pu'),
                        productId: '',
                        name: '${result['name']}',
                        unitType: '${result['unit_type'] ?? 'piece'}',
                        multiplier: '${result['multiplier'] ?? '1'}',
                        barcode: result['barcode'] as String?,
                        isDefault: result['is_default'] as bool? ?? false,
                      ),
                    );
                  });
                } else if (result == true && pid != null) {
                  ref.read(purchaseUnitsProvider.notifier).load(
                        pid,
                        includeArchived: true,
                      );
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(AppStrings.t('add_purchase_unit', loc)),
            ),
          ),
        if (_isEdit && state.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (items.isEmpty)
          Text(
            AppStrings.t('no_purchase_units', loc),
            key: const Key('purchase-units-empty'),
            style: theme.textTheme.bodySmall,
          )
        else
          for (final u in items)
            Padding(
              key: Key('purchase-unit-row-${u.id}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${u.name}'
                      ' · ${AppStrings.unitLabel(u.unitType, loc)}'
                      ' · ×${u.multiplier}'
                      '${u.fullPackages != null && u.fullPackages != '0' ? ' · ${AppStrings.t('full_packages', loc)}: ${u.fullPackages}' : ''}'
                      '${u.isDefault ? ' · ${AppStrings.t('is_default_purchase_unit', loc)}' : ''}'
                      '${u.isArchived ? ' · ${AppStrings.t('archived_purchase_unit', loc)}' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (u.isArchived)
                    Padding(
                      key: Key('purchase-unit-archived-badge-${u.id}'),
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Icon(
                        Icons.archive_outlined,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  if (canUpdate && !u.isArchived && _isEdit)
                    IconButton(
                      key: Key('edit-purchase-unit-${u.id}'),
                      tooltip: AppStrings.t('edit_purchase_unit', loc),
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () async {
                        final ok = await showPurchaseUnitFormDialog(
                          context,
                          productId: pid,
                          unit: u,
                        );
                        if (ok == true && pid != null && mounted) {
                          ref.read(purchaseUnitsProvider.notifier).load(
                                pid,
                                includeArchived: true,
                              );
                        }
                      },
                    ),
                  if (canArchive && !u.isArchived && _isEdit)
                    IconButton(
                      key: Key('archive-purchase-unit-${u.id}'),
                      tooltip: AppStrings.t('archive_purchase_unit', loc),
                      icon: const Icon(Icons.archive_outlined, size: 18),
                      onPressed: () async {
                        final err = await ref
                            .read(purchaseUnitsProvider.notifier)
                            .archive(pid!, u.id);
                        if (!mounted) return;
                        if (err != null) {
                          setState(() => _error = err);
                        } else {
                          _showArchiveSnack(loc, 'purchase_unit_archived');
                        }
                      },
                    ),
                  if (!_isEdit && canUpdate)
                    IconButton(
                      key: Key('remove-staged-purchase-unit-${u.id}'),
                      tooltip: AppStrings.t('delete', loc),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(
                        () => _stagedPurchaseUnits.removeWhere(
                          (x) => x.id == u.id,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  void _showArchiveSnack(String loc, String messageKey) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t(messageKey, loc))),
    );
  }

  /// Two-column field row on wide dialogs; stacks vertically when narrow.
  Widget _fieldRow({
    required bool narrow,
    required List<Widget> children,
  }) {
    if (narrow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _imageSection(String loc) {
    final hasImage = _imagePath != null && _imagePath!.trim().isNotEmpty;
    final path = _imagePath?.trim() ?? '';
    final validFile = hasImage && File(path).existsSync();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Preview
        Container(
          key: const Key('product-image-preview'),
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: validFile
              ? Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      _imagePlaceholder(loc, invalid: true),
                )
              : _imagePlaceholder(loc, invalid: hasImage && !validFile),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasImage
                    ? path.split(RegExp(r'[\\/]')).last
                    : AppStrings.t('no_image', loc),
                key: const Key('product-image-name'),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    key: const Key('product-image-choose'),
                    onPressed: _pickImage,
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: Text(
                      hasImage
                          ? AppStrings.t('change_image', loc)
                          : AppStrings.t('choose_image', loc),
                    ),
                  ),
                  if (hasImage)
                    OutlinedButton.icon(
                      key: const Key('product-image-remove'),
                      onPressed: _removeImage,
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(AppStrings.t('remove_image', loc)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _imagePlaceholder(String loc, {bool invalid = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            invalid ? Icons.broken_image_outlined : Icons.image_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 4),
          Text(
            invalid
                ? AppStrings.t('unsupported_image', loc)
                : AppStrings.t('no_image', loc),
            key: const Key('product-image-placeholder'),
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
