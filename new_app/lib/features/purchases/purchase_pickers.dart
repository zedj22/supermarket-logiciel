// Supplier + product pickers for the purchase editor (Phase 11).
//
// Both dialogs are self-contained (dio calls owned locally, debounced
// search, stale-response guarding) — the PackProductPicker pattern —
// so the purchase editor's draft state is never mutated by navigation.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/barcode_scanner.dart';
import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../products/models.dart';
import '../suppliers/supplier_models.dart';

const Duration kPurchasePickerDebounce = Duration(milliseconds: 300);

// ---------------------------------------------------------------------------
// Supplier picker
// ---------------------------------------------------------------------------

Future<SupplierModel?> showPurchaseSupplierPicker(BuildContext context) {
  return showDialog<SupplierModel>(
    context: context,
    builder: (_) => const PurchaseSupplierPicker(),
  );
}

class PurchaseSupplierPicker extends ConsumerStatefulWidget {
  const PurchaseSupplierPicker({super.key});

  @override
  ConsumerState<PurchaseSupplierPicker> createState() =>
      _PurchaseSupplierPickerState();
}

class _PurchaseSupplierPickerState
    extends ConsumerState<PurchaseSupplierPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<SupplierModel> _items = const [];
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
    _debounce = Timer(kPurchasePickerDebounce, () => _load(value));
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
        '/api/v1/suppliers',
        queryParameters: {
          if (query.trim().isNotEmpty) 'q': query.trim(),
          'page_size': 40,
        },
      );
      if (requestId != _requestId || !mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map((e) => SupplierModel.fromJson(e as Map<String, dynamic>))
            .where((s) => !s.isArchived)
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

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('purchase-supplier-picker'),
      title: Text(AppStrings.t('select_supplier', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('purchase-supplier-picker-search'),
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
                          key: const Key('purchase-supplier-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_data', loc),
                              key: const Key('purchase-supplier-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('purchase-supplier-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final s = _items[index];
                                return ListTile(
                                  key: Key('purchase-supplier-option-${s.id}'),
                                  dense: true,
                                  title: Text(s.name),
                                  subtitle: Text(
                                    [
                                      if (s.phone != null &&
                                          s.phone!.isNotEmpty)
                                        s.phone!,
                                      if (s.contactPerson != null &&
                                          s.contactPerson!.isNotEmpty)
                                        s.contactPerson!,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => Navigator.pop(context, s),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('purchase-supplier-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Product picker (barcode / name server search)
// ---------------------------------------------------------------------------

Future<ProductModel?> showPurchaseProductPicker(BuildContext context) {
  return showDialog<ProductModel>(
    context: context,
    builder: (_) => const PurchaseProductPicker(),
  );
}

class PurchaseProductPicker extends ConsumerStatefulWidget {
  const PurchaseProductPicker({super.key});

  @override
  ConsumerState<PurchaseProductPicker> createState() =>
      _PurchaseProductPickerState();
}

class _PurchaseProductPickerState extends ConsumerState<PurchaseProductPicker> {
  final TextEditingController _search = TextEditingController();
  late final BarcodeScanHandler _scanHandler;
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
      name: 'purchase-product-picker',
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

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(kPurchasePickerDebounce, () => _load(value));
  }

  void _handleBarcodeScan(String code) {
    _debounce?.cancel();
    _search.value = TextEditingValue(
      text: code,
      selection: TextSelection.collapsed(offset: code.length),
    );
    unawaited(_load(code));
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

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('purchase-product-picker'),
      title: Text(AppStrings.t('select_product', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('purchase-product-picker-search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: AppStrings.t('search_products', loc),
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
                          key: const Key('purchase-product-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_products_found', loc),
                              key: const Key('purchase-product-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('purchase-product-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final p = _items[index];
                                return ListTile(
                                  key: Key('purchase-product-option-${p.id}'),
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
                                    p.cost,
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
          key: const Key('purchase-product-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}
