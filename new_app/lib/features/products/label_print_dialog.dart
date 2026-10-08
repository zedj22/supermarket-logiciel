// Product barcode / price-label printing dialog (§ labels).
//
// Selection happens on the products screen (rows/cards → "Print labels").
// This dialog owns PER-PRODUCT label quantity, the paper type (A4 grid
// vs adhesive roll) and the physical layout (mm geometry / columns /
// rows for A4, media width + margins for a roll), then hands the batch
// to the shared preview-first flow: showPrintPreviewDialog with a
// [fetcher] that POSTs /api/v1/print/labels. Prices are NEVER sent — the
// server resolves the effective price (active promotion vs retail, § price rule)
// and re-validates the layout against the chosen paper.
//
// Confirm → system print dialog → pop(true) (screen exits selection
// mode, no success toast §16.2). Cancel / preview-dismiss stay neutral.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../pos/pos_providers.dart';
import '../pos/print_document.dart';
import '../pos/print_preview_dialog.dart';
import '../pos/print_service.dart';
import 'models.dart';

/// Opens the label batch dialog. Returns true only after a print was
/// handed to the system dialog — the caller then clears its selection.
Future<bool?> showLabelPrintDialog(
  BuildContext context, {
  required List<ProductModel> products,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => LabelPrintDialog(products: products),
  );
}

class LabelPrintDialog extends ConsumerStatefulWidget {
  const LabelPrintDialog({super.key, required this.products});

  final List<ProductModel> products;

  @override
  ConsumerState<LabelPrintDialog> createState() => _LabelPrintDialogState();
}

class _LabelPrintDialogState extends ConsumerState<LabelPrintDialog> {
  late List<ProductModel> _products;
  final Map<String, int> _qty = <String, int>{};

  // Physical layout (mm) — defaults are the standard A4 grid: 3×9 labels.
  late final TextEditingController _width;
  late final TextEditingController _height;
  late final TextEditingController _gapX;
  late final TextEditingController _gapY;
  late final TextEditingController _marginX;
  late final TextEditingController _marginY;
  late final TextEditingController _columns;
  late final TextEditingController _rows;

  // Roll-label mode (`label_paper_roll`): the media + its margins. The
  // label size and vertical gap are the SAME fields as A4 (defaults
  // 50×30 mm / 2 mm already match the stock roll geometry), so switching
  // modes never loses an edited dimension. Defaults: 58 mm media, the
  // label flush to the top-left corner.
  String _paperType = 'A4';
  late final TextEditingController _rollWidth;
  late final TextEditingController _marginLeft;
  late final TextEditingController _marginRight;
  late final TextEditingController _marginTop;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _products = List<ProductModel>.of(widget.products);
    for (final product in _products) {
      _qty[product.id] = 1;
    }
    _width = TextEditingController(text: '50');
    _height = TextEditingController(text: '30');
    _gapX = TextEditingController(text: '2');
    _gapY = TextEditingController(text: '2');
    _marginX = TextEditingController(text: '5');
    _marginY = TextEditingController(text: '5');
    _columns = TextEditingController();
    _rows = TextEditingController();
    _rollWidth = TextEditingController(text: '58');
    _marginLeft = TextEditingController(text: '0');
    _marginRight = TextEditingController(text: '0');
    _marginTop = TextEditingController(text: '0');
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _gapX.dispose();
    _gapY.dispose();
    _marginX.dispose();
    _marginY.dispose();
    _columns.dispose();
    _rows.dispose();
    _rollWidth.dispose();
    _marginLeft.dispose();
    _marginRight.dispose();
    _marginTop.dispose();
    super.dispose();
  }

  String get _loc => ref.read(localeProvider).flutterLocale.languageCode;

  int get _totalLabels {
    var total = 0;
    for (final product in _products) {
      total += _qty[product.id] ?? 1;
    }
    return total;
  }

  void _setQty(ProductModel product, int value) {
    setState(() {
      _qty[product.id] = value.clamp(1, 999);
    });
  }

  void _removeRow(ProductModel product) {
    setState(() {
      _products.removeWhere((p) => p.id == product.id);
      _qty.remove(product.id);
    });
  }

  /// Parses the layout. Empty cells → null (backend auto-fits columns /
  /// rows); a filled but non-numeric cell → second tuple element is false.
  (Map<String, dynamic>, bool) _layout() {
    double parse(TextEditingController c, double fallback) {
      final raw = c.text.trim();
      if (raw.isEmpty) return fallback;
      return double.tryParse(raw) ?? double.nan;
    }

    int? parseInt(TextEditingController c) {
      final raw = c.text.trim();
      if (raw.isEmpty) return null;
      return int.tryParse(raw);
    }

    final width = parse(_width, 50);
    final height = parse(_height, 30);
    final gapX = parse(_gapX, 2);
    final gapY = parse(_gapY, 2);
    final marginX = parse(_marginX, 5);
    final marginY = parse(_marginY, 5);
    final columns = parseInt(_columns);
    final rows = parseInt(_rows);
    final filledIntsBad =
        (_columns.text.trim().isNotEmpty && columns == null) ||
        (_rows.text.trim().isNotEmpty && rows == null);
    final ok = <double>[width, height, gapX, gapY, marginX, marginY]
        .every((v) => !v.isNaN) && !filledIntsBad;
    if (!ok) return (<String, dynamic>{}, false);
    final layout = <String, dynamic>{
      'label_width_mm': width,
      'label_height_mm': height,
      'gap_x_mm': gapX,
      'gap_y_mm': gapY,
      'margin_x_mm': marginX,
      'margin_y_mm': marginY,
    };
    // Empty columns/rows stay ABSENT — the backend auto-fits the grid.
    if (columns != null) layout['columns'] = columns;
    if (rows != null) layout['rows'] = rows;
    return (layout, true);
  }

  /// Parses + validates the roll geometry, mirroring the backend's
  /// schema bounds and media cross-check so an impossible roll never
  /// reaches the server as a 422. Returns `(null, errorKey)` on
  /// rejection: `validation_error` for a non-numeric cell,
  /// `label_roll_fit` for out-of-range or impossible dimensions.
  (Map<String, dynamic>?, String?) _rollLayout() {
    double parse(TextEditingController c, double fallback) {
      final raw = c.text.trim();
      if (raw.isEmpty) return fallback;
      return double.tryParse(raw) ?? double.nan;
    }

    final rollW = parse(_rollWidth, 58);
    final width = parse(_width, 50);
    final height = parse(_height, 30);
    final gap = parse(_gapY, 2);
    final left = parse(_marginLeft, 0);
    final right = parse(_marginRight, 0);
    final top = parse(_marginTop, 0);
    if (<double>[rollW, width, height, gap, left, right, top]
        .any((v) => v.isNaN)) {
      return (null, 'validation_error');
    }
    bool inRange(double v, double min, double max) => v >= min && v <= max;
    final boundsOk = inRange(rollW, 20, 150) &&
        inRange(width, 30, 100) &&
        inRange(height, 20, 100) &&
        inRange(gap, 0, 20) &&
        inRange(left, 0, 50) &&
        inRange(right, 0, 50) &&
        inRange(top, 0, 50);
    // Width > 0 is implied by the range mins (>= 20 / >= 30); the media
    // cross-check: left margin + label + right margin <= roll width.
    if (!boundsOk || left + width + right > rollW + 1e-9) {
      return (null, 'label_roll_fit');
    }
    return (<String, dynamic>{
      'roll_width_mm': rollW,
      'label_width_mm': width,
      'label_height_mm': height,
      'gap_y_mm': gap,
      'margin_left_mm': left,
      'margin_right_mm': right,
      'margin_top_mm': top,
    }, null);
  }

  void _applyPreset(double presetWidth, double presetHeight) {
    setState(() {
      _width.text = _trim(presetWidth);
      _height.text = _trim(presetHeight);
      // Keep the geometry valid: widen the media if the preset label no
      // longer fits between the configured margins.
      final rollW = double.tryParse(_rollWidth.text.trim()) ?? 58;
      final left = double.tryParse(_marginLeft.text.trim()) ?? 0;
      final right = double.tryParse(_marginRight.text.trim()) ?? 0;
      final needed = presetWidth + left + right;
      if (rollW < needed) _rollWidth.text = _trim(needed);
    });
  }

  static String _trim(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  Future<void> _print() async {
    if (_busy || _products.isEmpty) return;
    final isRoll = _paperType == 'roll';
    Map<String, dynamic> layout;
    if (isRoll) {
      final (rollLayout, errorKey) = _rollLayout();
      if (rollLayout == null) {
        setState(() => _error = AppStrings.t(errorKey!, _loc));
        return;
      }
      layout = rollLayout;
    } else {
      final (a4Layout, valid) = _layout();
      if (!valid) {
        setState(() => _error = AppStrings.t('validation_error', _loc));
        return;
      }
      layout = a4Layout;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? deviceId;
    try {
      deviceId = await ref.read(posDeviceIdProvider.future);
    } catch (_) {
      deviceId = null;
    }
    if (!mounted) return;
    final loc = _loc;
    final dio = ref.read(apiClientProvider).dio;
    final items = <LabelPrintItem>[
      for (final product in _products)
        LabelPrintItem(productId: product.id, quantity: _qty[product.id] ?? 1),
    ];
    try {
      final result = await showPrintPreviewDialog(
        context,
        // A4 keeps the receipt-paper toggle exactly as before; a roll
        // job previews as `roll` only (its geometry is the document).
        initialPaper: isRoll ? 'roll' : 'A4',
        papers: isRoll ? const <String>['roll'] : null,
        deviceId: deviceId,
        fetcher: (paper, locale) => fetchLabelPdf(
          dio,
          items: items,
          paper: paper,
          locale: locale,
          layout: layout,
          deviceId: deviceId,
        ),
      );
      if (result == null || !mounted) {
        // Preview dismissed — neutral: no print, no toast (§16.2).
        setState(() => _busy = false);
        return;
      }
      await ref.read(printServiceProvider).printPdf(
            result.bytes,
            paper: result.paper,
            filename: result.filename,
          );
      if (!mounted) return;
      // Printed — tell the screen to exit selection mode.
      Navigator.of(context).pop(true);
    } on PrintServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Never "success" on failure — localized error only.
        final headline = e.code != null
            ? AppStrings.t(e.code!, loc)
            : AppStrings.t('print_failed', loc);
        _error = e.message.isEmpty || e.code != null
            ? headline
            : '$headline: ${e.message}';
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = printFetchMessage(e, loc);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.t('print_failed', loc);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    return AlertDialog(
      key: const Key('label-print-dialog'),
      title: Text(AppStrings.t('print_labels', loc)),
      content: SizedBox(
        width: 620,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStrings.t('labels_hint', loc),
              key: const Key('label-dialog-hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              AppStrings.t('labels_per_product', loc),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              flex: 3,
              child: _products.isEmpty
                  ? Center(
                      child: Text(
                        AppStrings.t('labels_hint', loc),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('label-qty-list'),
                      itemCount: _products.length,
                      itemBuilder: (context, index) {
                        final product = _products[index];
                        final qty = _qty[product.id] ?? 1;
                        return Padding(
                          key: Key('label-row-${product.id}'),
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  product.name,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              IconButton(
                                key: Key('label-qty-dec-${product.id}'),
                                tooltip: AppStrings.t('decrease', loc),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.remove, size: 16),
                                onPressed: qty <= 1
                                    ? null
                                    : () => _setQty(product, qty - 1),
                              ),
                              SizedBox(
                                width: 36,
                                child: Text(
                                  key: Key('label-qty-value-${product.id}'),
                                  '$qty',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: Key('label-qty-inc-${product.id}'),
                                tooltip: AppStrings.t('increase', loc),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.add, size: 16),
                                onPressed: qty >= 999
                                    ? null
                                    : () => _setQty(product, qty + 1),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                key: Key('label-row-remove-${product.id}'),
                                tooltip: AppStrings.t('delete', loc),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () => _removeRow(product),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('labels_layout', loc),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              key: const Key('label-paper-type-row'),
              children: [
                Text(
                  AppStrings.t('label_paper_type', loc),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const Key('label-paper-type'),
                    initialValue: _paperType,
                    isDense: true,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                        value: 'A4',
                        child: Text(
                          AppStrings.t('label_paper_a4', loc),
                          key: const Key('label-paper-a4'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'roll',
                        child: Text(
                          AppStrings.t('label_paper_roll', loc),
                          key: const Key('label-paper-roll'),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      _paperType = value ?? 'A4';
                      _error = null; // stale geometry error never carries over
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _paperType == 'roll'
                  ? [
                      _layoutField(
                          'label-field-roll-width', 'label_roll_width', _rollWidth, loc),
                      _layoutField(
                          'label-field-width', 'label_width', _width, loc),
                      _layoutField(
                          'label-field-height', 'label_height', _height, loc),
                      _layoutField(
                          'label-field-gap-y', 'label_gap_y', _gapY, loc),
                      _layoutField('label-field-margin-left',
                          'label_margin_left', _marginLeft, loc),
                      _layoutField('label-field-margin-right',
                          'label_margin_right', _marginRight, loc),
                      _layoutField('label-field-margin-top',
                          'label_margin_top', _marginTop, loc),
                    ]
                  : [
                      _layoutField(
                          'label-field-width', 'label_width', _width, loc),
                      _layoutField(
                          'label-field-height', 'label_height', _height, loc),
                      _layoutField(
                          'label-field-gap-x', 'label_gap_x', _gapX, loc),
                      _layoutField(
                          'label-field-gap-y', 'label_gap_y', _gapY, loc),
                      _layoutField('label-field-margin-x',
                          'label_margin_x', _marginX, loc),
                      _layoutField('label-field-margin-y',
                          'label_margin_y', _marginY, loc),
                      _layoutField('label-field-columns',
                          'label_columns', _columns, loc),
                      _layoutField(
                          'label-field-rows', 'label_rows', _rows, loc),
                    ],
            ),
            if (_paperType == 'roll')
              Wrap(
                key: const Key('label-roll-presets'),
                spacing: 4,
                runSpacing: 0,
                children: [
                  _presetButton(
                      'label-preset-small', 'label_preset_small', 50, 30, loc),
                  _presetButton(
                      'label-preset-medium', 'label_preset_medium', 58, 40, loc),
                  _presetButton(
                      'label-preset-large', 'label_preset_large', 60, 40, loc),
                ],
              ),
            const SizedBox(height: 8),
            Text(
              key: const Key('label-total-count'),
              '${AppStrings.t('labels_total', loc)}: $_totalLabels',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('label-print-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('label-dialog-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton.icon(
          key: const Key('label-dialog-print'),
          onPressed: _busy || _products.isEmpty ? null : _print,
          // Static icon (not a spinner): _busy spans the WHOLE
          // preview + system-print flow — an indeterminate animation
          // here would run behind the modal the entire time.
          icon: const Icon(Icons.local_print_shop_outlined, size: 16),
          label: Text(AppStrings.t('print', loc)),
        ),
      ],
    );
  }

  Widget _layoutField(
    String key,
    String labelKey,
    TextEditingController controller,
    String loc,
  ) {
    return SizedBox(
      width: 140,
      child: TextField(
        key: Key(key),
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          labelText: AppStrings.t(labelKey, loc),
        ),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  /// Optional roll dimension shortcut (label size only — no printer
  /// brands, no media assumptions beyond keeping the media valid).
  Widget _presetButton(
    String key,
    String labelKey,
    double width,
    double height,
    String loc,
  ) {
    return TextButton(
      key: Key(key),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: () => _applyPreset(width, height),
      child: Text(
        '${AppStrings.t(labelKey, loc)} ${_trim(width)}×${_trim(height)}',
      ),
    );
  }
}
