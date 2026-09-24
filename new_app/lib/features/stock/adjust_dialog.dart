// Stock adjustment dialog (Phase 7 — base unit only).
//
// operation: increase | decrease | set
// Quantity is always in the product's BASE unit (piece, kg, …).
// No unit selector: selling/purchase units live only in Products (Phase 6).
// Optional unit_cost (updates PMP on increases).
// Optional variant_id → adjusts variant quantity only.
// Returns the submitted payload, or null on cancel.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'inventory_models.dart';
import 'inventory_providers.dart';

enum AdjustOperation { increase, decrease, set }

Future<Map<String, dynamic>?> showAdjustDialog(
  BuildContext context, {
  required InventoryItemModel product,
  String? variantId,
  String? variantName,
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => AdjustDialog(
      product: product,
      variantId: variantId,
      variantName: variantName,
    ),
  );
}

class AdjustDialog extends ConsumerStatefulWidget {
  final InventoryItemModel product;
  final String? variantId;
  final String? variantName;

  const AdjustDialog({
    super.key,
    required this.product,
    this.variantId,
    this.variantName,
  });

  @override
  ConsumerState<AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends ConsumerState<AdjustDialog> {
  final _qtyController = TextEditingController();
  final _costController = TextEditingController();
  final _reasonController = TextEditingController();
  final _noteController = TextEditingController();

  AdjustOperation _operation = AdjustOperation.increase;
  String? _error;
  bool _submitting = false;

  bool get _isVariant => widget.variantId != null;

  @override
  void dispose() {
    _qtyController.dispose();
    _costController.dispose();
    _reasonController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  String get _currentStock =>
      _isVariant ? (widget.variantName ?? '') : widget.product.quantity;

  String get _baseUnitLabel => AppStrings.unitLabel(
        widget.product.unit,
        ref.read(localeProvider).flutterLocale.languageCode,
      );

  double get _enteredQty => double.tryParse(_qtyController.text.trim()) ?? 0;

  double _newStockPreview() {
    final current = double.tryParse(
          _isVariant ? '0' : widget.product.quantity,
        ) ??
        0;
    final qty = _enteredQty;
    switch (_operation) {
      case AdjustOperation.increase:
        return current + qty;
      case AdjustOperation.decrease:
        return current - qty;
      case AdjustOperation.set:
        return qty;
    }
  }

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final qtyText = _qtyController.text.trim();
    final qty = double.tryParse(qtyText);
    if (qtyText.isEmpty || qty == null || qty < 0) {
      return AppStrings.t('enter_quantity', loc);
    }
    if (_operation != AdjustOperation.set && qty <= 0) {
      return AppStrings.t('enter_quantity', loc);
    }
    if (_operation == AdjustOperation.set && qty < 0) {
      return AppStrings.t('enter_quantity', loc);
    }
    if (_operation != AdjustOperation.increase &&
        _reasonController.text.trim().isEmpty) {
      return AppStrings.t('enter_reason', loc);
    }
    final costText = _costController.text.trim();
    if (costText.isNotEmpty) {
      final cost = double.tryParse(costText);
      if (cost == null || cost < 0) {
        return AppStrings.t('invalid_unit_cost', loc);
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });

    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final operation = switch (_operation) {
      AdjustOperation.increase => 'increase',
      AdjustOperation.decrease => 'decrease',
      AdjustOperation.set => 'set',
    };
    final reasonText = _reasonController.text.trim();
    final payload = <String, dynamic>{
      'product_id': widget.product.productId,
      if (widget.variantId != null) 'variant_id': widget.variantId,
      'operation': operation,
      'quantity': _qtyController.text.trim(),
      if (reasonText.isNotEmpty) 'reason': reasonText,
      if (_noteController.text.trim().isNotEmpty)
        'note': _noteController.text.trim(),
      if (_costController.text.trim().isNotEmpty)
        'unit_cost': _costController.text.trim(),
    };

    final message = await ref.read(inventoryProvider.notifier).adjust(payload);
    if (!mounted) return;
    if (message != null) {
      setState(() {
        _error = message;
        _submitting = false;
      });
      return;
    }
    Navigator.pop(context, payload);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('adjustment_success', loc))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final title = _isVariant
        ? AppStrings.t('adjust_variant', loc)
        : AppStrings.t('adjust_stock', loc);
    final cs = theme.colorScheme;

    return AlertDialog(
      key: const Key('adjust-dialog'),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            _isVariant
                ? '${widget.product.name} — ${widget.variantName ?? ''}'
                : widget.product.name,
            key: const Key('adjust-product-name'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Current stock chip
              Container(
                key: const Key('adjust-current-stock'),
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
                ),
                child: Text(
                  '${AppStrings.t('current_stock', loc)}: '
                  '$_currentStock $_baseUnitLabel',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text(
                AppStrings.t('operation', loc),
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SegmentedButton<AdjustOperation>(
                key: const Key('adjust-operation'),
                segments: [
                  ButtonSegment(
                    value: AdjustOperation.increase,
                    label: Text(AppStrings.t('increase', loc)),
                    icon: const Icon(Icons.add, size: 18),
                  ),
                  ButtonSegment(
                    value: AdjustOperation.decrease,
                    label: Text(AppStrings.t('decrease', loc)),
                    icon: const Icon(Icons.remove, size: 18),
                  ),
                  ButtonSegment(
                    value: AdjustOperation.set,
                    label: Text(AppStrings.t('set_quantity', loc)),
                    icon: const Icon(Icons.pin, size: 18),
                  ),
                ],
                selected: {_operation},
                onSelectionChanged: (s) =>
                    setState(() => _operation = s.first),
              ),
              const SizedBox(height: 14),

              TextField(
                key: const Key('adjust-quantity'),
                controller: _qtyController,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: AppStrings.t('quantity', loc),
                  suffixText: _baseUnitLabel,
                  helperText:
                      '${AppStrings.t('base_unit', loc)}: $_baseUnitLabel',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),

              // New stock preview
              if (_qtyController.text.trim().isNotEmpty)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _qtyController,
                  builder: (context, value, _) {
                    final preview = _newStockPreview();
                    return Text(
                      '${AppStrings.t('new_stock', loc)}: '
                      '${preview.toStringAsFixed(3)} $_baseUnitLabel',
                      key: const Key('adjust-new-stock-preview'),
                      textDirection: TextDirection.ltr,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    );
                  },
                ),
              const SizedBox(height: 10),

              TextField(
                key: const Key('adjust-unit-cost'),
                controller: _costController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: AppStrings.t('unit_cost', loc),
                  helperText: AppStrings.t('unit_cost_optional', loc),
                ),
              ),
              const SizedBox(height: 10),

              TextField(
                key: const Key('adjust-reason'),
                controller: _reasonController,
                decoration: InputDecoration(
                  labelText: _operation == AdjustOperation.increase
                      ? AppStrings.t('reason', loc)
                      : '${AppStrings.t('reason', loc)} *',
                  helperText: _operation == AdjustOperation.increase
                      ? AppStrings.t('reason_optional', loc)
                      : AppStrings.t('reason_required', loc),
                  hintText: AppStrings.t('enter_reason', loc),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),

              TextField(
                key: const Key('adjust-note'),
                controller: _noteController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: AppStrings.t('note', loc),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('adjust-error'),
                  style: TextStyle(color: cs.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('adjust-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}
