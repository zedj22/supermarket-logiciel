// Invoice-client + product pickers for the facturation editor (Phase 8).
//
// Both dialogs are self-contained (dio calls owned locally, debounced
// search, stale-response guarding) — the PackProductPicker pattern —
// so the invoice editor's draft state is never mutated by navigation.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../auth/auth_provider.dart';
import '../facturation/facturation_error.dart';
import '../facturation/facturation_models.dart';
import '../facturation/facturation_providers.dart' show kInvoiceClientsPath;
import '../invoice_clients/invoice_clients_error.dart';
import '../packs/pack_models.dart';
import '../products/models.dart';

const Duration kFacturationPickerDebounce = Duration(milliseconds: 300);

// ---------------------------------------------------------------------------
// Invoice-client picker
// ---------------------------------------------------------------------------

Future<InvoiceClientModel?> showInvoiceClientPicker(BuildContext context) {
  return showDialog<InvoiceClientModel>(
    context: context,
    builder: (_) => const InvoiceClientPicker(),
  );
}

class InvoiceClientPicker extends ConsumerStatefulWidget {
  const InvoiceClientPicker({super.key});

  @override
  ConsumerState<InvoiceClientPicker> createState() => _InvoiceClientPickerState();
}

class _InvoiceClientPickerState extends ConsumerState<InvoiceClientPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<InvoiceClientModel> _items = const [];
  bool _loading = false;
  String? _error;
  String? _errorDetail;

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
    _debounce = Timer(kFacturationPickerDebounce, () => _load(value));
  }

  Future<void> _load(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        kInvoiceClientsPath,
        queryParameters: {
          if (query.trim().isNotEmpty) 'q': query.trim(),
          'page_size': 40,
        },
      );
      if (requestId != _requestId || !mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map(
              (e) => InvoiceClientModel.fromJson(e as Map<String, dynamic>),
            )
            .where((c) => !c.isArchived)
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (requestId != _requestId || !mounted) return;
      final mapped = invoiceClientsApiError(e, _loc);
      setState(() {
        _loading = false;
        _error = mapped.message;
        _errorDetail = mapped.detail;
      });
    }
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('invoice-client-picker'),
      title: Text(AppStrings.t('select_invoice_client', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('invoice-client-picker-search'),
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
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _error!,
                              key: const Key('invoice-client-picker-error'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                            if (_errorDetail != null &&
                                _errorDetail!.isNotEmpty)
                              Text(
                                _errorDetail!,
                                key: const Key(
                                  'invoice-client-picker-error-detail',
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_data', loc),
                              key: const Key('invoice-client-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('invoice-client-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final c = _items[index];
                                return ListTile(
                                  key: Key('invoice-client-option-${c.id}'),
                                  dense: true,
                                  title: Text(c.name),
                                  subtitle: Text(
                                    [
                                      if (c.wilaya != null &&
                                          c.wilaya!.isNotEmpty)
                                        c.wilaya!,
                                      if (c.phone != null &&
                                          c.phone!.isNotEmpty)
                                        c.phone!,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => Navigator.pop(context, c),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('invoice-client-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Product picker (barcode / name server search) — price + vat_rate prefill
// ---------------------------------------------------------------------------

Future<ProductModel?> showFacturationProductPicker(BuildContext context) {
  return showDialog<ProductModel>(
    context: context,
    builder: (_) => const FacturationProductPicker(),
  );
}

class FacturationProductPicker extends ConsumerStatefulWidget {
  const FacturationProductPicker({super.key});

  @override
  ConsumerState<FacturationProductPicker> createState() =>
      _FacturationProductPickerState();
}

class _FacturationProductPickerState
    extends ConsumerState<FacturationProductPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<ProductModel> _items = const [];
  bool _loading = false;
  String? _error;
  String? _errorDetail;

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
    _debounce = Timer(kFacturationPickerDebounce, () => _load(value));
  }

  Future<void> _load(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
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
      final mapped = facturationApiError(e, _loc);
      setState(() {
        _loading = false;
        _error = mapped.message;
        _errorDetail = mapped.detail;
      });
    }
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('facturation-product-picker'),
      title: Text(AppStrings.t('select_product', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('facturation-product-picker-search'),
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
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _error!,
                              key: const Key('facturation-product-picker-error'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                            if (_errorDetail != null &&
                                _errorDetail!.isNotEmpty)
                              Text(
                                _errorDetail!,
                                key: const Key(
                                  'facturation-product-picker-error-detail',
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_products_found', loc),
                              key: const Key('facturation-product-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('facturation-product-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final p = _items[index];
                                return ListTile(
                                  key: Key('facturation-product-option-${p.id}'),
                                  dense: true,
                                  title: Text(p.name),
                                  subtitle: Text(
                                    [
                                      if (p.barcode != null &&
                                          p.barcode!.isNotEmpty)
                                        p.barcode!,
                                      '${AppStrings.t('tva_rate', loc)}: '
                                          '${p.vatRate}%',
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
          key: const Key('facturation-product-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stage 3A option pickers — variant / selling unit / pack.
//
// Self-contained (local dio, no shared POS providers) exactly like the
// product picker above, so facturation can never mutate POS picker
// state. READ-ONLY: no stock checks, no availability pre-flight —
// invoices never gate or move inventory.
// ---------------------------------------------------------------------------

Future<VariantModel?> showFacturationVariantPicker(
  BuildContext context, {
  required String productId,
}) {
  return showDialog<VariantModel>(
    context: context,
    builder: (_) => FacturationVariantPicker(productId: productId),
  );
}

class FacturationVariantPicker extends ConsumerStatefulWidget {
  final String productId;

  const FacturationVariantPicker({super.key, required this.productId});

  @override
  ConsumerState<FacturationVariantPicker> createState() =>
      _FacturationVariantPickerState();
}

class _FacturationVariantPickerState
    extends ConsumerState<FacturationVariantPicker> {
  List<VariantModel> _items = const [];
  bool _loading = true;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  Future<void> _load() async {
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/products/${widget.productId}/variants',
        queryParameters: {'include_archived': false},
      );
      if (!mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map((e) => VariantModel.fromJson(e as Map<String, dynamic>))
            .where((v) => !v.isArchived)
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final mapped = facturationApiError(e, _loc);
      setState(() {
        _loading = false;
        _error = mapped.message;
        _errorDetail = mapped.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('facturation-variant-picker'),
      title: Text(AppStrings.t('select_variant', loc)),
      content: SizedBox(
        width: 460,
        child: SizedBox(
          height: 300,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _error!,
                          key: const Key('facturation-variant-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        if (_errorDetail != null && _errorDetail!.isNotEmpty)
                          Text(
                            _errorDetail!,
                            key: const Key(
                              'facturation-variant-picker-error-detail',
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    )
                  : _items.isEmpty
                      ? Text(
                          AppStrings.t('no_variants', loc),
                          key: const Key('facturation-variant-picker-empty'),
                        )
                      : ListView.builder(
                          key: const Key('facturation-variant-picker-list'),
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final v = _items[index];
                            return ListTile(
                              key: Key('facturation-variant-option-${v.id}'),
                              dense: true,
                              title: Text(v.name),
                              trailing: Text(
                                v.price ?? '',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onTap: () => Navigator.pop(context, v),
                            );
                          },
                        ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('facturation-variant-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}

Future<SellingUnitModel?> showFacturationSellingUnitPicker(
  BuildContext context, {
  required String productId,
}) {
  return showDialog<SellingUnitModel>(
    context: context,
    builder: (_) => FacturationSellingUnitPicker(productId: productId),
  );
}

class FacturationSellingUnitPicker extends ConsumerStatefulWidget {
  final String productId;

  const FacturationSellingUnitPicker({super.key, required this.productId});

  @override
  ConsumerState<FacturationSellingUnitPicker> createState() =>
      _FacturationSellingUnitPickerState();
}

class _FacturationSellingUnitPickerState
    extends ConsumerState<FacturationSellingUnitPicker> {
  List<SellingUnitModel> _items = const [];
  bool _loading = true;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  Future<void> _load() async {
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/products/${widget.productId}/selling-units',
        queryParameters: {'include_archived': false},
      );
      if (!mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map((e) => SellingUnitModel.fromJson(e as Map<String, dynamic>))
            .where((u) => !u.isArchived)
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final mapped = facturationApiError(e, _loc);
      setState(() {
        _loading = false;
        _error = mapped.message;
        _errorDetail = mapped.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('facturation-selling-unit-picker'),
      title: Text(AppStrings.t('select_selling_unit', loc)),
      content: SizedBox(
        width: 460,
        child: SizedBox(
          height: 300,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _error!,
                          key: const Key('facturation-selling-unit-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        if (_errorDetail != null && _errorDetail!.isNotEmpty)
                          Text(
                            _errorDetail!,
                            key: const Key(
                              'facturation-selling-unit-picker-error-detail',
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    )
                  : _items.isEmpty
                      ? Text(
                          AppStrings.t('no_selling_units', loc),
                          key: const Key('facturation-selling-unit-picker-empty'),
                        )
                      : ListView.builder(
                          key: const Key('facturation-selling-unit-picker-list'),
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final u = _items[index];
                            return ListTile(
                              key: Key('facturation-selling-unit-option-${u.id}'),
                              dense: true,
                              title: Text(
                                u.isBaseUnit
                                    ? '${u.name} · ${AppStrings.t('base_unit', loc)}'
                                    : u.name,
                              ),
                              subtitle: u.multiplier == '1'
                                  ? null
                                  : Text('×${u.multiplier}'),
                              trailing: Text(
                                u.effectivePrice ?? u.sellingPrice ?? '',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onTap: () => Navigator.pop(context, u),
                            );
                          },
                        ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('facturation-selling-unit-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}

Future<PackModel?> showFacturationPackPicker(BuildContext context) {
  return showDialog<PackModel>(
    context: context,
    builder: (_) => const FacturationPackPicker(),
  );
}

class FacturationPackPicker extends ConsumerStatefulWidget {
  const FacturationPackPicker({super.key});

  @override
  ConsumerState<FacturationPackPicker> createState() =>
      _FacturationPackPickerState();
}

class _FacturationPackPickerState extends ConsumerState<FacturationPackPicker> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;

  List<PackModel> _items = const [];
  bool _loading = false;
  String? _error;
  String? _errorDetail;

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
    _debounce = Timer(kFacturationPickerDebounce, () => _load(value));
  }

  String get _loc => Localizations.localeOf(context).languageCode;

  Future<void> _load(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/packs',
        queryParameters: {
          'status': 'active',
          if (query.trim().isNotEmpty) 'q': query.trim(),
          'page_size': 40,
        },
      );
      if (requestId != _requestId || !mounted) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .map((e) => PackModel.fromJson(e as Map<String, dynamic>))
            .where((p) => p.isActive && !p.isArchived)
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (requestId != _requestId || !mounted) return;
      final mapped = facturationApiError(e, _loc);
      setState(() {
        _loading = false;
        _error = mapped.message;
        _errorDetail = mapped.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('facturation-pack-picker'),
      title: Text(AppStrings.t('select_pack', loc)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('facturation-pack-picker-search'),
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
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _error!,
                              key: const Key('facturation-pack-picker-error'),
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                            if (_errorDetail != null &&
                                _errorDetail!.isNotEmpty)
                              Text(
                                _errorDetail!,
                                key: const Key(
                                  'facturation-pack-picker-error-detail',
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        )
                      : _items.isEmpty
                          ? Text(
                              AppStrings.t('no_packs', loc),
                              key: const Key('facturation-pack-picker-empty'),
                            )
                          : ListView.builder(
                              key: const Key('facturation-pack-picker-list'),
                              itemCount: _items.length,
                              itemBuilder: (context, index) {
                                final p = _items[index];
                                return ListTile(
                                  key: Key('facturation-pack-option-${p.id}'),
                                  dense: true,
                                  title: Text(p.name),
                                  subtitle: p.barcode == null ||
                                          p.barcode!.isEmpty
                                      ? null
                                      : Text(p.barcode!),
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
          key: const Key('facturation-pack-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}
