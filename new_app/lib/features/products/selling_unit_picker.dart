// Selling-unit picker (Phase 6).
//
// Lists a product's active selling units (piece ×1, box ×24, …) with
// independent price and derived availability. Tapping a unit opens the
// quantity dialog and returns {unit, qty} for the caller (POS Phase 8
// or product form preview).
//
// Never labels a unit "Pack" — packs are a separate Phase 10 concept.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';
import 'products_providers.dart';
import 'quantity_dialog.dart';

class SellingUnitPickResult {
  final SellingUnitModel unit;
  final String quantity;

  const SellingUnitPickResult({required this.unit, required this.quantity});
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
      SellingUnitPickResult(unit: unit, quantity: qty),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(sellingUnitsProvider);
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('selling-unit-picker'),
      title: Text(AppStrings.t('selling_units', loc)),
      content: SizedBox(
        width: 440,
        child: state.loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            : state.error != null
                ? Text(
                    state.error!,
                    key: const Key('selling-unit-picker-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  )
                : state.items.isEmpty
                    ? Text(
                        AppStrings.t('no_selling_units', loc),
                        key: const Key('selling-unit-picker-empty'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: state.items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final unit = state.items[index];
                          final price = unit.effectivePrice ??
                              unit.sellingPrice ??
                              widget.productPrice ??
                              '0';
                          return ListTile(
                            key: Key('selling-unit-${unit.id}'),
                            dense: true,
                            leading: Icon(
                              unit.isBaseUnit
                                  ? Icons.radio_button_checked
                                  : Icons.straighten,
                              size: 20,
                              color: unit.isBaseUnit
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                            title: Text(unit.name),
                            subtitle: Text(
                              '${AppStrings.t('multiplier', loc)}: '
                              '${unit.multiplier} · '
                              '${AppStrings.unitLabel(unit.unitType, loc)} · '
                              '${AppStrings.t('unit_price', loc)}: $price · '
                              '${AppStrings.t('available_quantity', loc)}: '
                              '${unit.availableSellingQty ?? '—'}',
                            ),
                            trailing: unit.isBaseUnit
                                ? Text(
                                    AppStrings.t('base_unit', loc),
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  )
                                : null,
                            onTap: unit.isArchived ? null : () => _pick(unit),
                          );
                        },
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
}
