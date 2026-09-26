// Selling-unit picker (Phase 6 / UX FIX #4 / UX FIX #6).
//
// Lists a product's active selling units as option cards via
// PosOptionPickerDialog. Tapping / confirming a unit opens the quantity
// dialog and returns {sellingUnitId, unitName, unitPrice, quantity,
// unitMultiplier, isBaseUnit} for the caller.
//
// UX FIX #4 — base unit option (Part A):
// - The product/variant BASE unit is ALWAYS shown as a selectable option
//   when the picker is opened from POS (productUnit/productPrice known or
//   any configured units exist). Synthetic option key: `selling-unit-base`.
// - Synthetic base is never a fake DB record: sellingUnitId = null.
// - Configured units with isBaseUnit == true are filtered to avoid
//   duplicates (their name seeds the synthetic label when productUnit
//   is not provided).
// - Empty dialog is forbidden when a base can be shown (base-only list).
//   Bare product-form preview (no unit/price/items) keeps empty state.
//
// Never labels a unit "Pack" — packs are a separate Phase 10 concept.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_option_picker.dart';
import 'models.dart';
import 'products_providers.dart';
import 'quantity_dialog.dart';

/// Key for the synthetic base-unit option row.
const String kSellingUnitBaseKey = 'selling-unit-base';

class SellingUnitPickResult {
  /// Null when the base unit was chosen (never a fake DB id).
  final String? sellingUnitId;
  final String unitName;
  final String unitPrice;
  final String quantity;
  final String? unitMultiplier;
  final bool isBaseUnit;

  const SellingUnitPickResult({
    required this.sellingUnitId,
    required this.unitName,
    required this.unitPrice,
    required this.quantity,
    this.unitMultiplier,
    this.isBaseUnit = false,
  });
}

Future<SellingUnitPickResult?> showSellingUnitPicker(
  BuildContext context, {
  required String productId,
  String productQuantity = '0',
  String? productUnit,
  String? productPrice,
}) {
  return showDialog<SellingUnitPickResult>(
    context: context,
    builder: (_) => SellingUnitPicker(
      productId: productId,
      productQuantity: productQuantity,
      productUnit: productUnit,
      productPrice: productPrice,
    ),
  );
}

class SellingUnitPicker extends ConsumerStatefulWidget {
  final String productId;
  final String productQuantity;
  final String? productUnit;
  final String? productPrice;

  const SellingUnitPicker({
    super.key,
    required this.productId,
    this.productQuantity = '0',
    this.productUnit,
    this.productPrice,
  });

  @override
  ConsumerState<SellingUnitPicker> createState() => _SellingUnitPickerState();
}

class _SellingUnitPickerState extends ConsumerState<SellingUnitPicker> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(sellingUnitsProvider.notifier).load(widget.productId),
    );
  }

  /// Synthetic base-unit model for the quantity dialog only — never
  /// persisted, never sent as selling_unit_id.
  SellingUnitModel _baseUnitModel(String name) {
    return SellingUnitModel(
      id: kSellingUnitBaseKey,
      productId: widget.productId,
      name: name,
      unitType: widget.productUnit ?? 'piece',
      multiplier: '1',
      isBaseUnit: true,
      sellingPrice: widget.productPrice,
      effectivePrice: widget.productPrice,
      availableBaseQty: widget.productQuantity,
      availableSellingQty: widget.productQuantity,
    );
  }

  Future<void> _pickBase(String name) async {
    final qty = await showQuantityDialog(
      context,
      unit: _baseUnitModel(name),
      productQuantity: widget.productQuantity,
      productUnit: widget.productUnit ?? name,
    );
    if (qty == null || !mounted) return;
    Navigator.pop(
      context,
      SellingUnitPickResult(
        sellingUnitId: null,
        unitName: widget.productUnit ?? name,
        unitPrice: widget.productPrice ?? '0',
        quantity: qty,
        unitMultiplier: '1',
        isBaseUnit: true,
      ),
    );
  }

  Future<void> _pick(SellingUnitModel unit) async {
    final qty = await showQuantityDialog(
      context,
      unit: unit,
      productQuantity: widget.productQuantity,
      productUnit: widget.productUnit ?? unit.unitType,
    );
    if (qty == null || !mounted) return;
    Navigator.pop(
      context,
      SellingUnitPickResult(
        sellingUnitId: unit.id,
        unitName: unit.name,
        unitPrice: unit.effectivePrice ??
            unit.sellingPrice ??
            widget.productPrice ??
            '0',
        quantity: qty,
        unitMultiplier: unit.multiplier,
        isBaseUnit: unit.isBaseUnit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(sellingUnitsProvider);
    final theme = Theme.of(context);

    if (state.loading) {
      return AlertDialog(
        key: const Key('selling-unit-picker'),
        title: Text(AppStrings.t('selling_units', loc)),
        content: const SizedBox(
          width: 440,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      );
    }
    if (state.error != null) {
      return AlertDialog(
        key: const Key('selling-unit-picker'),
        title: Text(AppStrings.t('selling_units', loc)),
        content: SizedBox(
          width: 440,
          child: Text(
            state.error!,
            key: const Key('selling-unit-picker-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel', loc)),
          ),
        ],
      );
    }

    // Filter configured base records — synthetic base replaces them
    // (never two "Piece" rows).
    final configuredBase = state.items.where((u) => u.isBaseUnit).toList();
    final others = state.items.where((u) => !u.isBaseUnit).toList();
    final canShowBase = widget.productPrice != null ||
        widget.productUnit != null ||
        state.items.isNotEmpty;
    final baseName = widget.productUnit ??
        configuredBase.firstOrNull?.name ??
        AppStrings.unitLabel('piece', loc);

    if (!canShowBase && others.isEmpty) {
      return AlertDialog(
        key: const Key('selling-unit-picker'),
        title: Text(AppStrings.t('selling_units', loc)),
        content: SizedBox(
          width: 440,
          child: Text(
            AppStrings.t('no_selling_units', loc),
            key: const Key('selling-unit-picker-empty'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel', loc)),
          ),
        ],
      );
    }

    final basePrice = widget.productPrice ?? '0';
    final cards = <PosOptionCard>[
      if (canShowBase)
        PosOptionCard(
          optionKey: kSellingUnitBaseKey,
          title: baseName,
          price: basePrice,
          secondary: AppStrings.t('base_unit', loc),
        ),
      for (final unit in others)
        PosOptionCard(
          optionKey: 'selling-unit-${unit.id}',
          title: unit.name,
          price: unit.effectivePrice ??
              unit.sellingPrice ??
              widget.productPrice ??
              '0',
          secondary:
              '${unit.multiplier} ${AppStrings.unitLabel(unit.unitType, loc)}',
          enabled: !unit.isArchived,
        ),
    ];

    return PosOptionPickerDialog(
      title: AppStrings.t('selling_units', loc),
      subtitle: AppStrings.t('select_unit_hint', loc),
      options: cards,
      dialogKey: 'selling-unit-picker',
      onConfirm: (index) async {
        if (!mounted) return;
        if (canShowBase && index == 0) {
          await _pickBase(baseName);
          return;
        }
        final unitIndex = canShowBase ? index - 1 : index;
        final unit = others[unitIndex];
        if (unit.isArchived) return;
        await _pick(unit);
      },
    );
  }
}
