// Invoice line editor dialog (Phase 8 facturation).
//
// Owns one draft line: optional product selection (searchable picker —
// prefill from products.price HT + products.vat_rate, never promotion /
// wholesale / selling-unit price), or a free-text line (description +
// unit_price_ht + tva_rate all required), quantity, discount and a
// computed display line total. Integer milli math only — fiscal totals
// come from the server (preview endpoint), never from this dialog.
//
// Keyboard-first: Enter in quantity/price submits the line when valid.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
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

  late final TextEditingController _description;
  late final TextEditingController _qty;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  int? _tvaRate;
  final bool _saving = false;
  String? _error;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _description = TextEditingController(text: initial?.description ?? '');
    _qty = TextEditingController(text: initial?.quantity ?? '');
    _price = TextEditingController(text: initial?.unitPriceHt ?? '');
    _discount = TextEditingController(text: initial?.discountPct ?? '0');
    _tvaRate = initial?.tvaRate;
    if (initial != null && initial.productId != null) {
      _product = ProductModel(
        id: initial.productId!,
        name: initial.productName ?? '',
      );
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

  Future<void> _pickProduct() async {
    final product = await showFacturationProductPicker(context);
    if (product == null || !mounted) return;
    setState(() {
      _product = product;
      // Prefill = products.price (HT) + products.vat_rate — never
      // promotion / wholesale / selling-unit price (Phase 8 rule).
      _description.text = product.name;
      if (_price.text.trim().isEmpty) {
        _price.text = product.price;
      }
      _tvaRate ??= kTvaRates.contains(product.vatRate) ? product.vatRate : 0;
      _error = null;
    });
  }

  void _clearProduct() {
    setState(() {
      _product = null;
      _error = null;
    });
  }

  String? _validate(String loc) {
    final isFreeText = _product == null;
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
    // Free-text lines REQUIRE a price; product lines may leave it empty
    // so the server prefills from products.price.
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
    final isFreeText = _product == null;

    final previewLine = DraftInvoiceLine(
      productId: _product?.id,
      productName: _product?.name,
      description: _description.text,
      quantity: _qty.text,
      unitPriceHt: _price.text,
      tvaRate: _tvaRate,
      discountPct: _discount.text,
    );

    return AlertDialog(
      key: const Key('invoice-line-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_line' : 'add_line', loc),
        key: const Key('invoice-line-title'),
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
                    _product?.name ?? AppStrings.t('free_text_line', loc),
                    key: const Key('invoice-line-product'),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_product != null)
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
                      _product == null ? 'select_product' : 'change_product',
                      loc,
                    ),
                  ),
                ),
              ],
            ),
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
                      labelText: AppStrings.t('unit_price', loc),
                      hintText: isFreeText ? null : AppStrings.t('prefill_price', loc),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _submit(loc),
                    onChanged: (_) => setState(() => _error = null),
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
