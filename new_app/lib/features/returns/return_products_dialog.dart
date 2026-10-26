// Return Products dialog (Phase 12 fix round 1) — INDEPENDENT,
// multi-product return.
//
// One dialog submission = ONE return document with N return_lines
// (sale_id NULL, customer_id NULL, no debt entry, movement type RETURN).
// Products are added by:
//   * barcode scan — Enter on the search field hits the canonical
//     GET /api/v1/products/barcode-lookup (selling unit → variant →
//     product). A variant barcode returns the VARIANT, and stock is
//     restored to the variant only (Phase 8/12 rule).
//   * text search — debounced GET /api/v1/products?search=… then tap [+].
// Rescanning / reselecting the SAME product or variant MERGES into its
// line and increments the quantity (never a duplicate line). An unknown
// barcode shows localized not-found feedback — scan failures are never
// silently ignored.
//
// Reason is OPTIONAL (product-owner decision): blank = no reason. The
// backend stays authoritative (unknown product 404, quantity > 0, caps,
// pack rules); current stock is NOT validated because a return only
// increases stock.
//
// One `client_request_id` per dialog open keeps double-submit idempotent
// (GATE 16).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/barcode_scanner.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'return_models.dart';
import 'return_providers.dart';

/// Opens the multi-product independent return dialog.
Future<ReturnCreateResult?> showReturnProductsDialog(
  BuildContext context,
) {
  return showDialog<ReturnCreateResult>(
    context: context,
    builder: (_) => const ReturnProductsDialog(),
  );
}

const Duration _searchDebounce = Duration(milliseconds: 300);

/// One selected product/variant line (merged on repeated scans).
class _SelectedLine {
  final String key;
  final String productId;
  final String? variantId;
  final String name;
  final String unit;

  const _SelectedLine({
    required this.key,
    required this.productId,
    required this.variantId,
    required this.name,
    required this.unit,
  });
}

class ReturnProductsDialog extends ConsumerStatefulWidget {
  const ReturnProductsDialog({super.key});

  @override
  ConsumerState<ReturnProductsDialog> createState() =>
      _ReturnProductsDialogState();
}

class _ReturnProductsDialogState extends ConsumerState<ReturnProductsDialog> {
  late final String _clientRequestId;
  final _search = TextEditingController();
  final _note = TextEditingController();
  final _focusNode = FocusNode();
  late final BarcodeScanHandler _scanHandler;
  final Map<String, TextEditingController> _qty = {};

  final List<_SelectedLine> _lines = [];
  List<ReturnProductCandidate> _products = const [];

  String _reason = '';
  bool _searching = false;
  bool _submitting = false;
  bool _mergedNotice = false;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _scanHandler = BarcodeScanHandler(
      context: context,
      name: 'return-products',
      allowWhileEditingFor: (editable) =>
          identical(editable.controller, _search),
      allowIncompletePassThrough: true,
      allowReplacementPassThrough: true,
      onScan: (code) => unawaited(_handleScan(code)),
    );
    BarcodeScannerGateway.instance.register(_scanHandler);
  }

  @override
  void dispose() {
    BarcodeScannerGateway.instance.unregister(_scanHandler);
    _search.dispose();
    _note.dispose();
    _focusNode.dispose();
    for (final controller in _qty.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _qtyFor(String key) {
    return _qty.putIfAbsent(key, () => TextEditingController());
  }

  String get _loc =>
      ref.read(localeProvider).flutterLocale.languageCode;

  // -------------------------------------------------------------------------
  // Adding products (scan + search share this path so merges behave the same)
  // -------------------------------------------------------------------------

  String _lineKey(String productId, String? variantId) =>
      variantId == null ? productId : '$productId|$variantId';

  void _addProduct({
    required String productId,
    String? variantId,
    required String name,
    required String unit,
  }) {
    final key = _lineKey(productId, variantId);
    setState(() {
      _error = null;
      _errorDetail = null;
      final index = _lines.indexWhere((line) => line.key == key);
      if (index >= 0) {
        // Same product/variant again → merge, never a duplicate line.
        final controller = _qtyFor(key);
        final current = double.tryParse(controller.text) ?? 0;
        controller.text = _fmtQty(current + 1);
        _mergedNotice = true;
      } else {
        _lines.add(
          _SelectedLine(
            key: key,
            productId: productId,
            variantId: variantId,
            name: name,
            unit: unit,
          ),
        );
        _qtyFor(key).text = '1';
        _mergedNotice = false;
      }
    });
  }

  void _removeLine(_SelectedLine line) {
    setState(() {
      _lines.removeWhere((entry) => entry.key == line.key);
      final controller = _qty.remove(line.key);
      controller?.dispose();
      _mergedNotice = false;
      _error = null;
    });
  }

  void _step(_SelectedLine line, int delta) {
    final controller = _qtyFor(line.key);
    final current = double.tryParse(controller.text) ?? 0;
    final next = current + delta;
    if (next <= 0) return; // never allow quantity <= 0
    setState(() {
      controller.text = _fmtQty(next);
      _error = null;
    });
  }

  // -------------------------------------------------------------------------
  // Search / scan
  // -------------------------------------------------------------------------

  Future<void> _searchProducts(String term) async {
    setState(() => _searching = true);
    final (items, error) =
        await ref.read(returnsApiProvider).searchProducts(term);
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (error != null) {
        _error = error.message;
        _errorDetail = error.detail;
      } else {
        _products = items;
      }
    });
  }

  /// Enter = committed scan (keyboard-wedge scanners send Enter).
  Future<void> _handleScan([String? scannedCode]) async {
    final term = (scannedCode ?? _search.text).trim();
    if (term.isEmpty || _submitting) return;
    final api = ref.read(returnsApiProvider);

    // 1) Canonical barcode path (product / variant / selling unit).
    final (hit, lookupError) = await api.barcodeLookup(term);
    if (!mounted) return;
    if (lookupError != null) {
      setState(() {
        _error = lookupError.message;
        _errorDetail = lookupError.detail;
      });
      return;
    }
    if (hit != null && hit.productId != null) {
      _addProduct(
        productId: hit.productId!,
        variantId: hit.returnVariantId,
        name: hit.displayName,
        unit: hit.unit,
      );
      _search.clear();
      _focusNode.requestFocus();
      return;
    }

    // 2) Fall back to the canonical search: exact name / barcode match.
    final (items, searchError) = await api.searchProducts(term);
    if (!mounted) return;
    if (searchError != null) {
      setState(() {
        _error = searchError.message;
        _errorDetail = searchError.detail;
      });
      return;
    }
    ReturnProductCandidate? exact;
    final needle = term.toLowerCase();
    for (final product in items) {
      if (product.name.toLowerCase() == needle ||
          (product.barcode.isNotEmpty && product.barcode == term)) {
        exact = product;
        break;
      }
    }
    if (exact != null) {
      _addProduct(
        productId: exact.id,
        name: exact.name,
        unit: exact.unit,
      );
      _search.clear();
      _focusNode.requestFocus();
      return;
    }

    // 3) Unknown barcode → localized not-found feedback (never silent).
    setState(() {
      _error = AppStrings.t('return_product_not_found', _loc);
      _errorDetail = null;
    });
  }

  // -------------------------------------------------------------------------
  // Validation + submit
  // -------------------------------------------------------------------------

  String? _localValidation(String loc) {
    if (_lines.isEmpty) return AppStrings.t('return_no_products', loc);
    for (final line in _lines) {
      final text = _qtyFor(line.key).text.trim();
      final qty = double.tryParse(text);
      if (qty == null || qty <= 0) return AppStrings.t('invalid_qty', loc);
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    final note = _note.text.trim();
    return {
      'client_request_id': _clientRequestId,
      if (_reason.trim().isNotEmpty) 'reason': _reason.trim(),
      if (note.isNotEmpty) 'note': note,
      'lines': [
        for (final line in _lines)
          {
            'product_id': line.productId,
            if (line.variantId != null) 'variant_id': line.variantId,
            'quantity': _qtyFor(line.key).text.trim(),
          },
      ],
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final loc = _loc;
    final problem = _localValidation(loc);
    if (problem != null) {
      setState(() {
        _error = problem;
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _errorDetail = null;
    });

    final (result, error) = await ref
        .read(returnsApiProvider)
        .create(payload: _payload());

    if (!mounted) return;
    if (result == null) {
      setState(() {
        _submitting = false;
        _error = error?.message;
        _errorDetail = error?.detail;
      });
      return;
    }
    Navigator.pop(context, result);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('return-products-dialog'),
      title: Text(
        AppStrings.t('return_products', loc),
        key: const Key('return-products-title'),
      ),
      content: SizedBox(
        width: 640,
        height: 560,
        child: SingleChildScrollView(
          key: const Key('return-products-body'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _searchField(loc),
              const SizedBox(height: 8),
              _productResults(theme, loc),
              const SizedBox(height: 12),
              Text(
                AppStrings.t('return_selected_products', loc),
                key: const Key('return-selected-title'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              if (_lines.isEmpty)
                Text(
                  AppStrings.t('return_no_products', loc),
                  key: const Key('return-selected-empty'),
                  style: theme.textTheme.bodySmall,
                )
              else
                for (var i = 0; i < _lines.length; i++)
                  _lineRow(theme, loc, _lines[i], i),
              if (_mergedNotice) ...[
                const SizedBox(height: 4),
                Text(
                  AppStrings.t('return_scan_merged', loc),
                  key: const Key('return-merge-info'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _reasonField(theme, loc),
              const SizedBox(height: 12),
              TextField(
                key: const Key('return-note-input'),
                controller: _note,
                maxLength: 2000,
                inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                decoration: InputDecoration(
                  labelText: AppStrings.t('return_note', loc),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const Key('return-create-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (_errorDetail != null) ...[
                const SizedBox(height: 4),
                Text(
                  _errorDetail!,
                  key: const Key('return-create-error-detail'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('return-cancel'),
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('return-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('return_submit', loc)),
        ),
      ],
    );
  }

  Widget _searchField(String loc) {
    return TextField(
      key: const Key('return-product-search'),
      controller: _search,
      focusNode: _focusNode,
      autofocus: true,
      decoration: InputDecoration(
        hintText:
            '${AppStrings.t('return_scan_product', loc)} / '
            '${AppStrings.t('return_search_product', loc)}',
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        border: const OutlineInputBorder(),
        suffixIcon: _searching
            ? const SizedBox(
                width: 18,
                height: 18,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
      onChanged: (value) {
        final term = value;
        Future.delayed(_searchDebounce, () {
          if (!mounted || _search.text != term) return;
          _searchProducts(term);
        });
      },
      onSubmitted: (_) => _handleScan(),
    );
  }

  Widget _productResults(ThemeData theme, String loc) {
    if (_products.isEmpty) {
      return Text(
        _search.text.trim().isEmpty
            ? AppStrings.t('return_search_hint', loc)
            : AppStrings.t('no_data', loc),
        key: const Key('return-product-results-empty'),
        style: theme.textTheme.bodySmall,
      );
    }
    return SizedBox(
      height: 160,
      child: ListView.builder(
        key: const Key('return-product-results'),
        itemCount: _products.length,
        itemBuilder: (context, index) {
          final product = _products[index];
          return ListTile(
            key: Key('return-product-$index'),
            dense: true,
            title: Text(product.name, key: Key('return-product-name-$index')),
            subtitle: numericText(
              '${product.price} ${AppStrings.t('currency', loc)} · '
              '${AppStrings.unitLabel(product.unit, loc)}',
              key: Key('return-product-price-$index'),
            ),
            trailing: IconButton(
              key: Key('return-product-add-$index'),
              tooltip: AppStrings.t('return_add_product', loc),
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _addProduct(
                productId: product.id,
                name: product.name,
                unit: product.unit,
              ),
            ),
            onTap: () => _addProduct(
              productId: product.id,
              name: product.name,
              unit: product.unit,
            ),
          );
        },
      ),
    );
  }

  Widget _lineRow(
    ThemeData theme,
    String loc,
    _SelectedLine line,
    int index,
  ) {
    final controller = _qtyFor(line.key);
    final qty = double.tryParse(controller.text) ?? 0;
    final unit = AppStrings.unitLabel(line.unit, loc);
    return Padding(
      key: Key('return-line-$index'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${line.name} ($unit)',
              key: Key('return-line-name-$index'),
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            key: Key('return-line-dec-$index'),
            tooltip: '-1',
            onPressed: qty > 1 ? () => _step(line, -1) : null,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
          SizedBox(
            width: 72,
            child: TextField(
              key: Key('return-line-qty-$index'),
              controller: controller,
              textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
          ),
          IconButton(
            key: Key('return-line-inc-$index'),
            tooltip: '+1',
            onPressed: () => _step(line, 1),
            icon: const Icon(Icons.add_circle_outline, size: 20),
          ),
          IconButton(
            key: Key('return-line-remove-$index'),
            tooltip: AppStrings.t('return_remove', loc),
            onPressed: () => _removeLine(line),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _reasonField(ThemeData theme, String loc) {
    return DropdownButtonFormField<String>(
      key: const Key('return-reason-select'),
      initialValue: _reason,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: AppStrings.t('return_reason_optional', loc),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(
            AppStrings.t('return_reason_none', loc),
            key: const Key('return-reason-none'),
          ),
        ),
        for (final reason in kReturnReasons)
          DropdownMenuItem(
            value: reason,
            child: Text(
              AppStrings.t(returnReasonKey(reason), loc),
              key: Key('return-reason-$reason'),
            ),
          ),
      ],
      onChanged: (value) => setState(() {
        _reason = value ?? '';
        _error = null;
      }),
    );
  }

  static String _fmtQty(double value) {
    if (value == value.roundToDouble()) {
      return formatGrouped(value.toInt().toString());
    }
    final fixed = value.toStringAsFixed(3);
    return formatGrouped(
      fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), ''),
    );
  }
}
