// Create / edit promotion dialog (Phase 18).
//
// Same architecture as ExpenseFormDialog / PackFormDialog: the dialog
// owns its fields and submit flow, delegates persistence to
// [PromotionsApi], then pops with the saved promotion.
//
// The manager picks MANY products in one shot (bulk apply — the server
// writes the promotion AND its membership rows in ONE transaction) and
// may switch the promotion on/off. Guard rails mirrored from the backend:
//   * `name` required (trimmed, non-blank)
//   * percentage: 0 < value <= 100
//   * fixed price: value >= 0 (money, max 3 decimals)
//   * >= 1 product
//   * multi-product × fixed price is rejected client-side too
//     (`MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED`)
//
// `client_request_id` is generated per dialog open (GATE: a retry submit
// replays idempotently instead of creating a second promotion). Money and
// value travel as decimal strings; no binary float is ever written.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/barcode_scanner.dart';
import '../../core/strings.dart';
import '../../core/widgets/status_chip.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../clients/customer_models.dart' show moneyToMilli, milliToMoney;
import '../products/models.dart';
import '../products/products_providers.dart' show kSearchDebounce;
import 'promotion_models.dart';
import 'promotions_providers.dart';

/// Returns the saved promotion, or null when the manager backs out.
Future<PromotionItem?> showPromotionFormDialog(
  BuildContext context, {
  PromotionItem? promotion,
}) {
  return showDialog<PromotionItem>(
    context: context,
    builder: (_) => PromotionFormDialog(promotion: promotion),
  );
}

/// One selected product for the membership set (id + display name).
class _SelectedProduct {
  final String id;
  final String name;

  const _SelectedProduct({required this.id, required this.name});
}

class PromotionFormDialog extends ConsumerStatefulWidget {
  final PromotionItem? promotion;

  const PromotionFormDialog({super.key, this.promotion});

  @override
  ConsumerState<PromotionFormDialog> createState() =>
      _PromotionFormDialogState();
}

class _PromotionFormDialogState extends ConsumerState<PromotionFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _value;
  late final String _clientRequestId;

  String _type = 'percentage';
  bool _isActive = true;
  final List<_SelectedProduct> _selected = [];
  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.promotion != null;

  @override
  void initState() {
    super.initState();
    final p = widget.promotion;
    _name = TextEditingController(text: p?.name ?? '');
    _value = TextEditingController(text: p?.value ?? '');
    _type = p?.promotionType ?? 'percentage';
    _isActive = p?.isActive ?? true;
    for (final ref in p?.products ?? const <PromotionProductRef>[]) {
      _selected.add(_SelectedProduct(id: ref.id, name: ref.name));
    }
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  // ── Validation (client-side convenience, server stays authoritative) ──

  String? _validate(String loc) {
    if (_name.text.trim().isEmpty) return AppStrings.t('field_required', loc);

    final milli = moneyToMilli(_value.text);
    if (milli == null) return AppStrings.t('promotion_invalid_value', loc);
    if (_type == 'percentage') {
      // 0 < value <= 100 (thousandths: 1 .. 100000).
      if (milli <= 0 || milli > 100000) {
        return AppStrings.t('promotion_invalid_value', loc);
      }
    } else if (milli < 0) {
      return AppStrings.t('promotion_invalid_value', loc);
    }

    if (_selected.isEmpty) return AppStrings.t('promotion_requires_products', loc);
    if (_type == 'fixed_price' && _selected.length > 1) {
      return AppStrings.t('promotion_multi_fixed', loc);
    }
    return null;
  }

  // ── Payload ──────────────────────────────────────────────────────────

  Map<String, dynamic> _payload() {
    return {
      if (!_isEdit) 'client_request_id': _clientRequestId,
      'name': _name.text.trim(),
      'promotion_type': _type,
      'value': milliToMoney(moneyToMilli(_value.text)!),
      'product_ids': [for (final item in _selected) item.id],
      'is_active': _isActive,
    };
  }

  Future<void> _submit() async {
    if (_saving) return;
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

    final api = ref.read(promotionsApiProvider);
    final payload = _payload();
    final (saved, error) = _isEdit
        ? await api.update(promotionId: widget.promotion!.id, payload: payload)
        : await api.create(payload: payload);

    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error.message;
        _errorDetail = error.detail;
      });
      return;
    }
    Navigator.pop(context, saved);
  }

  // ── Product multi-select ─────────────────────────────────────────────

  Future<void> _pickProducts() async {
    final picked = await showPromotionProductPicker(
      context,
      selectedIds: {for (final item in _selected) item.id},
    );
    if (picked == null || !mounted) return;
    setState(() {
      _error = null;
      _errorDetail = null;
      for (final product in picked) {
        if (_selected.any((item) => item.id == product.id)) continue;
        _selected.add(_SelectedProduct(id: product.id, name: product.name));
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final isPercentage = _type == 'percentage';

    return AlertDialog(
      key: const Key('promotion-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_promotion' : 'add_promotion', loc),
        key: const Key('promotion-form-title'),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('promotion-form-name'),
                controller: _name,
                enabled: !_saving,
                autofocus: true,
                maxLength: 200,
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: AppStrings.t('promotion_name_label', loc),
                  counterText: '',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) =>
                    setState(() => _error = null),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('promotion-form-type'),
                      initialValue: _type,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('promotion_type_label', loc),
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final code in const ['percentage', 'fixed_price'])
                          DropdownMenuItem(
                            value: code,
                            child: Text(
                              AppStrings.t(promotionTypeKey(code), loc),
                              key: Key('promotion-form-type-$code'),
                            ),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                                _type = value ?? _type;
                                _error = null;
                                _errorDetail = null;
                              }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('promotion-form-value'),
                      controller: _value,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: InputDecoration(
                        labelText: AppStrings.t('promotion_value_label', loc),
                        hintText: isPercentage
                            ? AppStrings.t('promotion_value_percent_hint', loc)
                            : AppStrings.t('promotion_value_price_hint', loc),
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) =>
                          setState(() => _error = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('promotion-form-active'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  AppStrings.t(
                    _isActive ? 'active' : 'inactive',
                    loc,
                  ),
                  key: const Key('promotion-form-active-label'),
                ),
                value: _isActive,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _isActive = value;
                          _error = null;
                        }),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('promotion_products_label', loc),
                      key: const Key('promotion-form-products-label'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${_selected.length}',
                    key: const Key('promotion-form-products-count'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_selected.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    AppStrings.t('promotion_products_empty', loc),
                    key: const Key('promotion-form-products-empty'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              for (var i = 0; i < _selected.length; i++)
                _productRow(loc, theme, i),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('promotion-form-add-products'),
                onPressed: _saving ? null : _pickProducts,
                icon: const Icon(Icons.add, size: 18),
                label: Text(AppStrings.t('promotion_select_products', loc)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('promotion-form-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                if (_errorDetail != null && _errorDetail!.isNotEmpty)
                  Text(
                    _errorDetail!,
                    key: const Key('promotion-form-error-detail'),
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
          key: const Key('promotion-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('promotion-form-submit'),
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

  Widget _productRow(String loc, ThemeData theme, int index) {
    final item = _selected[index];
    return Padding(
      key: Key('promotion-form-product-$index'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.name,
              key: Key('promotion-form-product-name-$index'),
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            key: Key('promotion-form-product-remove-$index'),
            tooltip: AppStrings.t('remove_line', loc),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _error = null;
                      _selected.removeAt(index);
                    }),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-select product picker (searchable; returns the ADDED products)
// ---------------------------------------------------------------------------

/// Opens the searchable product list. [selectedIds] marks rows that are
/// already in the membership set (they are skipped on return); the dialog
/// returns only the newly chosen products so the caller can append them.
Future<List<ProductModel>?> showPromotionProductPicker(
  BuildContext context, {
  Set<String> selectedIds = const {},
}) {
  return showDialog<List<ProductModel>>(
    context: context,
    builder: (_) => PromotionProductPicker(
      selectedIds: selectedIds,
    ),
  );
}

class PromotionProductPicker extends ConsumerStatefulWidget {
  final Set<String> selectedIds;

  const PromotionProductPicker({super.key, this.selectedIds = const {}});

  @override
  ConsumerState<PromotionProductPicker> createState() =>
      _PromotionProductPickerState();
}

class _PromotionProductPickerState extends ConsumerState<PromotionProductPicker> {
  final TextEditingController _search = TextEditingController();
  late final BarcodeScanHandler _scanHandler;
  final Set<String> _checked = {};
  Timer? _debounce;
  int _requestId = 0;

  List<ProductModel> _items = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanHandler = BarcodeScanHandler.forTextController(
      context: context,
      name: 'promotion-product-picker',
      controller: _search,
      onScan: _handleBarcodeScan,
    );
    BarcodeScannerGateway.instance.register(_scanHandler);
    _load('');
  }

  @override
  void dispose() {
    BarcodeScannerGateway.instance.unregister(_scanHandler);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
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
        final licenseKey = licenseErrorKeyFrom(e);
        _error = licenseKey != null
            ? AppStrings.t(licenseKey, _loc)
            : isConnectionError(e)
                ? AppStrings.t('network_error_retry', _loc)
                : (backendErrorMessage(e) ?? AppStrings.t('api_error_retry', _loc));
      });
    }
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(kSearchDebounce, () => _load(value));
  }

  void _handleBarcodeScan(String code) {
    _debounce?.cancel();
    _search.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    unawaited(_load(code));
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('promotion-product-picker'),
      title: Text(AppStrings.t('promotion_select_products', loc)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('promotion-product-picker-search'),
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
                          key: const Key('promotion-product-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_products_found', loc),
                              key: const Key('promotion-product-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('promotion-product-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final p = _items[index];
                                final alreadyInSet =
                                    widget.selectedIds.contains(p.id);
                                // PART 11: price and stock on the face of
                                // every row — a sold-out item is visible
                                // before it can be ticked (the server
                                // already returns quantity/threshold/unit
                                // on this search response).
                                final qty = double.tryParse(p.quantity) ?? 0;
                                final threshold =
                                    double.tryParse(p.lowStockThreshold) ?? 0;
                                final out = qty <= 0;
                                final low =
                                    !out && threshold > 0 && qty <= threshold;
                                final unit =
                                    AppStrings.unitLabel(p.unit, loc);
                                final stockLabel = out
                                    ? AppStrings.t('out_of_stock', loc)
                                    : low
                                        ? '${p.quantity} · '
                                            '${AppStrings.t('low_stock', loc)}'
                                        : unit.isEmpty
                                            ? p.quantity
                                            : '${p.quantity} $unit';
                                final stockTone = out
                                    ? StatusTone.error
                                    : low
                                        ? StatusTone.warning
                                        : StatusTone.success;
                                return CheckboxListTile(
                                  key: Key('promotion-product-option-${p.id}'),
                                  dense: true,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text(p.name),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${AppStrings.t('price', loc)} '
                                        '${p.price}',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      StatusChip(
                                        label: stockLabel,
                                        tone: stockTone,
                                        dense: true,
                                        testKey: Key(
                                          'promotion-product-stock-${p.id}',
                                        ),
                                      ),
                                    ],
                                  ),
                                  secondary: alreadyInSet
                                      ? Icon(
                                          Icons.check,
                                          size: 18,
                                          key: Key(
                                            'promotion-product-in-set-${p.id}',
                                          ),
                                          color: theme.colorScheme.primary,
                                        )
                                      : null,
                                  value: _checked.contains(p.id) ||
                                      alreadyInSet,
                                  onChanged: alreadyInSet
                                      ? null
                                      : (value) => setState(() {
                                            if (value == true) {
                                              _checked.add(p.id);
                                            } else {
                                              _checked.remove(p.id);
                                            }
                                          }),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('promotion-product-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('promotion-product-picker-confirm'),
          onPressed: () {
            final added = [
              for (final p in _items)
                if (_checked.contains(p.id) &&
                    !widget.selectedIds.contains(p.id))
                  p,
            ];
            Navigator.pop(context, added);
          },
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
