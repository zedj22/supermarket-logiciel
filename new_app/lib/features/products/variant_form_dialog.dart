// Create/edit product variant dialog (Phase 6).
//
// Fields: name, barcode, sku, price (optional → inherit), cost, quantity.
// price/cost left blank stay NULL (inherit product values). Archive only —
// no hard delete. Server enforces barcode/name uniqueness.
//
// Staged mode (create-product flow): when [staged] is true the dialog has
// no productId yet — Save returns the payload map via Navigator.pop instead
// of calling the API. The product form submits children atomically with
// the product (backend create-with-children).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';
import 'products_providers.dart';

/// Returns:
/// - `staged=true`  → Map payload (not yet persisted)
/// - `staged=false` → bool success
Future<Object?> showVariantFormDialog(
  BuildContext context, {
  String? productId,
  VariantModel? variant,
  bool staged = false,
}) {
  assert(staged || productId != null, 'productId required unless staged');
  return showDialog<Object>(
    context: context,
    builder: (_) => VariantFormDialog(
      productId: productId,
      variant: variant,
      staged: staged,
    ),
  );
}

class VariantFormDialog extends ConsumerStatefulWidget {
  final String? productId;
  final VariantModel? variant;
  final bool staged;

  const VariantFormDialog({
    super.key,
    this.productId,
    this.variant,
    this.staged = false,
  });

  @override
  ConsumerState<VariantFormDialog> createState() => _VariantFormDialogState();
}

class _VariantFormDialogState extends ConsumerState<VariantFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _sku;
  late final TextEditingController _price;
  late final TextEditingController _cost;
  late final TextEditingController _quantity;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.variant != null;

  @override
  void initState() {
    super.initState();
    final v = widget.variant;
    _name = TextEditingController(text: v?.name ?? '');
    _barcode = TextEditingController(text: v?.barcode ?? '');
    _sku = TextEditingController(text: v?.sku ?? '');
    _price = TextEditingController(text: v?.price ?? '');
    _cost = TextEditingController(text: v?.cost ?? '');
    _quantity = TextEditingController(text: v?.quantity ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _sku.dispose();
    _price.dispose();
    _cost.dispose();
    _quantity.dispose();
    super.dispose();
  }

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (_name.text.trim().isEmpty) return AppStrings.t('name', loc);
    for (final pair in [
      ('price', _price.text),
      ('cost', _cost.text),
      ('quantity', _quantity.text),
    ]) {
      final text = pair.$2.trim();
      if (text.isEmpty) continue;
      final n = double.tryParse(text);
      if (n == null || n < 0) {
        return '${AppStrings.t(pair.$1, loc)} ≥ 0';
      }
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    String? nonEmpty(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    if (_isEdit) {
      return {
        'name': _name.text.trim(),
        if (nonEmpty(_barcode) != null) 'barcode': nonEmpty(_barcode),
        if (nonEmpty(_sku) != null) 'sku': nonEmpty(_sku),
        // Explicit null clears override → inherit product price.
        'price': _price.text.trim().isEmpty
            ? null
            : _price.text.trim(),
        'cost': _cost.text.trim().isEmpty ? null : _cost.text.trim(),
        if (_quantity.text.trim().isNotEmpty)
          'quantity': _quantity.text.trim(),
      };
    }
    return {
      'name': _name.text.trim(),
      if (nonEmpty(_barcode) != null) 'barcode': nonEmpty(_barcode),
      if (nonEmpty(_sku) != null) 'sku': nonEmpty(_sku),
      if (_price.text.trim().isNotEmpty) 'price': _price.text.trim(),
      if (_cost.text.trim().isNotEmpty) 'cost': _cost.text.trim(),
      if (_quantity.text.trim().isNotEmpty) 'quantity': _quantity.text.trim(),
    };
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

    final payload = _payload();

    // Staged (create-product): return payload — parent submits atomically.
    if (widget.staged) {
      if (!mounted) return;
      Navigator.pop(context, payload);
      return;
    }

    final notifier = ref.read(variantsProvider.notifier);
    final error = _isEdit
        ? await notifier.update(widget.productId!, widget.variant!.id, payload)
        : await notifier.create(widget.productId!, payload);

    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
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
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('variant-form-dialog'),
      title: Text(AppStrings.t(_isEdit ? 'edit_variant' : 'add_variant', loc)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('variant-name-field'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: AppStrings.t('variant_name', loc),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('variant-barcode-field'),
                      controller: _barcode,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('barcode', loc),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _sku,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('sku', loc),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('variant-price-field'),
                      controller: _price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: AppStrings.t('price_override', loc),
                        helperText: AppStrings.t('inherit_price', loc),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _cost,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: AppStrings.t('cost', loc),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: AppStrings.t('stock_quantity', loc),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('variant-form-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('variant-form-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
