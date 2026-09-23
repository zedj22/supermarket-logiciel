// Create/edit product dialog (Phase 5, UI refinement).
//
// Responsive sectioned form:
//   Product Information | Pricing | Additional Information | Product Image | Actions
// Two-column fields on wide screens; single-column scrollable form on narrow
// (usable at 600×500). Image path is set via ProductImagePickerService
// (native file picker) with preview / choose / replace / remove — never a
// raw path text field. Cancel closes without error; missing/invalid path
// renders a placeholder (no crash).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import 'models.dart';
import 'product_image_picker_service.dart';
import 'products_providers.dart';

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

  bool get _isEdit => widget.product != null;

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
  }

  static String _trimDecimal(String value) {
    if (!value.contains('.')) return value;
    return value.replaceFirst(RegExp(r'\.?0+$'), '');
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
      'quantity': _quantity.text.trim().isEmpty ? '0' : _quantity.text.trim(),
      'low_stock_threshold': _threshold.text.trim().isEmpty
          ? '5'
          : _threshold.text.trim(),
      if (nonEmpty(_description) != null)
        'description': nonEmpty(_description),
      if (image != null && image.isNotEmpty) 'image_path': image,
      if (nonEmpty(_expiryDate) != null) 'expiry_date': nonEmpty(_expiryDate),
      if (_categoryId != null) 'category_id': _categoryId,
    };
  }

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

    final notifier = ref.read(productsProvider.notifier);
    final payload = _payload();
    final error = _isEdit
        ? await notifier.updateProduct(widget.product!.id, payload)
        : await notifier.createProduct(payload);

    if (!mounted) return;
    if (error == null) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.t(
              _isEdit ? 'product_updated' : 'product_created',
              loc,
            ),
          ),
        ),
      );
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canSeeCost = ref.watch(hasPermissionProvider('product_update'));
    final categories = ref.watch(categoriesProvider).activeItems;
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
                            DropdownMenuItem(value: u, child: Text(u)),
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
                        controller: _quantity,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: AppStrings.t('quantity', loc),
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
