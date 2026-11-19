// POS pack picker (Phase 10).
//
// Cashier-facing dialog: search active packs, choose how many packs to
// add, then run the READ-ONLY availability pre-flight before the pack
// enters the cart. The dialog never mutates stock — the backend remains
// authoritative at checkout (`PACK_INACTIVE` / `PACK_STOCK_INSUFFICIENT`).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../packs/pack_models.dart';
import '../packs/packs_providers.dart';

/// "Components: Sugar (2 Box) · Milk (3 L) +2" — built from the LIVE
/// availability payload so the pinned selling unit (and its conversion) is
/// the one the backend will actually use at checkout.
///
/// Top-level (not dialog-private) so the POS catalog's pack tile, which adds
/// a pack without opening the picker, shows the SAME component snapshot.
String packComponentsSummary(
  PackAvailabilityModel availability,
  String loc,
) {
  final entries = <String>[];
  for (final component in availability.components) {
    final label = packComponentLabel(
      productName: component.productName,
      unitName: component.sellingUnitName,
      unitQuantity: component.unitQuantity,
      sellingUnitId: component.sellingUnitId,
      multiplierText: component.sellingUnitMultiplier,
    );
    if (!entries.contains(label)) entries.add(label);
  }
  if (entries.isEmpty) return '';
  return '${AppStrings.t('components', loc)}: '
      '${entries.take(3).join(' · ')}'
      '${entries.length > 3 ? ' +${entries.length - 3}' : ''}';
}

/// `Bread` / `Sugar (2 Box)` for one pack component row.
String packComponentLabel({
  required String productName,
  required String? unitName,
  required String unitQuantity,
  required String? sellingUnitId,
  required String? multiplierText,
}) {
  if (sellingUnitId == null) return productName;
  final multiplier = double.tryParse(multiplierText ?? '1') ?? 1;
  if ((multiplier - 1).abs() <= 0.0000001) return productName;
  return '$productName ($unitQuantity $unitName)';
}

Future<PackPickResult?> showPackPickerDialog(BuildContext context) {
  return showDialog<PackPickResult>(
    context: context,
    builder: (_) => const PackPickerDialog(),
  );
}

class PackPickerDialog extends ConsumerStatefulWidget {
  const PackPickerDialog({super.key});

  @override
  ConsumerState<PackPickerDialog> createState() => _PackPickerDialogState();
}

class _PackPickerDialogState extends ConsumerState<PackPickerDialog> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _quantity = TextEditingController(text: '1');

  String? _selectedId;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Fresh list on every open — the cashier must not see a stale search.
    Future.microtask(() {
      ref.read(packPickerProvider.notifier).setQuery('');
      ref.read(packPickerProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _quantity.dispose();
    super.dispose();
  }

  PackModel? _selected(List<PackModel> items) {
    for (final pack in items) {
      if (pack.id == _selectedId) return pack;
    }
    return items.isNotEmpty ? items.first : null;
  }

  /// Pre-flight then pop with the cart payload. A pack that cannot be sold
  /// for the requested quantity stays in the dialog with a localized reason.
  Future<void> _add(PackModel pack) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final quantity = _quantity.text.trim().isEmpty
        ? '1'
        : _quantity.text.trim();
    final qtyValue = double.tryParse(quantity) ?? 0;
    if (qtyValue <= 0) {
      setState(() => _error = AppStrings.t('enter_pack_quantity', loc));
      return;
    }
    if (!pack.isSaleable) {
      setState(() => _error = AppStrings.t('pack_not_saleable', loc));
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });
    final availability = await ref
        .read(packsProvider.notifier)
        .fetchAvailability(pack.id, quantity: quantity);
    if (!mounted) return;
    setState(() => _checking = false);

    if (availability == null) {
      setState(() => _error = AppStrings.t('network_error_retry', loc));
      return;
    }
    if (!availability.saleable) {
      setState(() => _error = AppStrings.t('pack_not_saleable', loc));
      return;
    }
    final max = double.tryParse(availability.maxPackQuantity) ?? 0;
    if (max < qtyValue) {
      setState(() => _error = AppStrings.t('pack_stock_insufficient', loc));
      return;
    }

    Navigator.pop(
      context,
      PackPickResult(
        packId: pack.id,
        name: pack.name,
        barcode: pack.barcode,
        price: pack.price,
        quantity: quantity,
        maxPackQuantity: availability.maxPackQuantity,
        componentsSummary: packComponentsSummary(availability, loc),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final state = ref.watch(packPickerProvider);
    final selected = _selected(state.items);

    return AlertDialog(
      key: const Key('pack-picker'),
      title: Text(
        AppStrings.t('pack_picker_title', loc),
        key: const Key('pack-picker-title'),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('pack-picker-search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: AppStrings.t('pack_picker_hint', loc),
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
              ),
              onChanged: (value) =>
                  ref.read(packPickerProvider.notifier).setQuery(value),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 260,
              child: state.loading && state.items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : state.error != null
                      ? Text(
                          state.error!,
                          key: const Key('pack-picker-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : state.items.isEmpty
                          ? Text(
                              AppStrings.t('no_packs_found', loc),
                              key: const Key('pack-picker-empty'),
                              style: TextStyle(color: theme.colorScheme.outline),
                            )
                          : ListView.builder(
                              key: const Key('pack-picker-list'),
                              itemCount: state.items.length,
                              itemBuilder: (context, index) {
                                final pack = state.items[index];
                                final isSelected = pack.id == selected?.id;
                                return ListTile(
                                  key: Key('pack-option-${pack.id}'),
                                  dense: true,
                                  selected: isSelected,
                                  title: Text(
                                    pack.name,
                                    key: Key('pack-option-name-${pack.id}'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                    subtitle: pack.components.isNotEmpty
                                        ? Text(
                                            pack.components
                                                .map(
                                                  (c) => packComponentLabel(
                                                    productName: c.productName,
                                                    unitName:
                                                        c.sellingUnitName,
                                                    unitQuantity: c.unitQuantity,
                                                    sellingUnitId:
                                                        c.sellingUnitId,
                                                    multiplierText:
                                                        c.sellingUnitMultiplier,
                                                  ),
                                                )
                                                .take(3)
                                                .join(' · '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          )
                                        : null,
                                  trailing: numericText(
                                    formatGrouped(pack.price),
                                    key: Key('pack-option-price-${pack.id}'),
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  onTap: () => setState(() {
                                    _selectedId = pack.id;
                                    _error = null;
                                  }),
                                );
                              },
                            ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('pack-picker-qty'),
                    controller: _quantity,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      LengthLimitingTextInputFormatter(12),
                    ],
                    decoration: InputDecoration(
                      labelText: AppStrings.t('enter_pack_quantity', loc),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${AppStrings.t('sum_of_parts', loc)}: '
                  '${selected?.sumOfParts ?? '—'}',
                  key: const Key('pack-picker-sum'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const Key('pack-picker-error-line'),
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pack-picker-cancel'),
          onPressed: _checking ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('pack-picker-add'),
          onPressed:
              _checking || selected == null ? null : () => _add(selected),
          child: _checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('add', loc)),
        ),
      ],
    );
  }
}
