// Pack detail dialog (Phase 10): components + live availability.
//
// Availability is READ-ONLY (`GET /packs/{id}/availability`) — it never
// reserves or mutates stock. The requested quantity is re-checked on
// demand so a manager can see exactly how many packs the current component
// stock supports.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'pack_models.dart';
import 'packs_providers.dart';

Future<void> showPackDetailDialog(
  BuildContext context, {
  required PackModel pack,
}) {
  return showDialog(
    context: context,
    builder: (_) => PackDetailDialog(pack: pack),
  );
}

class PackDetailDialog extends ConsumerStatefulWidget {
  final PackModel pack;

  const PackDetailDialog({super.key, required this.pack});

  @override
  ConsumerState<PackDetailDialog> createState() => _PackDetailDialogState();
}

class _PackDetailDialogState extends ConsumerState<PackDetailDialog> {
  late final TextEditingController _quantity;
  PackAvailabilityModel? _availability;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _quantity = TextEditingController(text: '1');
    _check();
  }

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await ref
        .read(packsProvider.notifier)
        .fetchAvailability(
          widget.pack.id,
          quantity: _quantity.text.trim().isEmpty
              ? '1'
              : _quantity.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result == null) {
        _error = AppStrings.t('api_error_retry',
            ref.read(localeProvider).flutterLocale.languageCode);
      } else {
        _availability = result;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final pack = widget.pack;
    final availability = _availability;

    return AlertDialog(
      key: const Key('pack-detail-dialog'),
      title: Text(
        AppStrings.t('pack_detail_title', loc),
        key: const Key('pack-detail-title'),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                pack.name,
                key: const Key('pack-detail-name'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              // Bidi: Arabic labels stay natural; each numeric segment is
              // an LTR isolate (forced-LTR whole strings still reverse
              // grouped digits after an Arabic label — W7).
              Text(
                [
                  '${AppStrings.t('price', loc)}: '
                  '${bidiIsolateLtr(formatGrouped(pack.price))}',
                  if (pack.barcode != null && pack.barcode!.isNotEmpty)
                    '${AppStrings.t('barcode', loc)}: '
                    '${bidiIsolateLtr(pack.barcode!)}',
                  '${AppStrings.t('components', loc)}: '
                  '${bidiIsolateLtr('${pack.componentsCount}')}',
                  if (pack.sumOfParts != null)
                    '${AppStrings.t('sum_of_parts', loc)}: '
                    '${bidiIsolateLtr(formatGrouped(pack.sumOfParts!))}',
                ].join('  ·  '),
                key: const Key('pack-detail-summary'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              if (pack.estimatedCost != null ||
                  pack.estimatedProfit != null ||
                  pack.estimatedMarkupPercent != null) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    if (pack.estimatedCost != null)
                      '${AppStrings.t('estimated_cost', loc)}: '
                      '${bidiIsolateLtr(formatGrouped(pack.estimatedCost!))}',
                    if (pack.estimatedProfit != null)
                      '${AppStrings.t('estimated_profit', loc)}: '
                      '${bidiIsolateLtr(formatGrouped(pack.estimatedProfit!))}',
                    // Markup ON COST, recomputed client-side from the two
                    // figures above (the backend's `estimated_margin_percent`
                    // is profit / price — never displayed).
                    if (pack.estimatedMarkupPercent != null)
                      '${AppStrings.t('estimated_margin', loc)}: '
                      '${bidiIsolateLtr(pack.estimatedMarkupPercent!)}',
                  ].join('  ·  '),
                  key: const Key('pack-detail-estimate'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                Text(
                  AppStrings.t('estimate_pmp_note', loc),
                  key: const Key('pack-detail-estimate-note'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      width: 140,
                      child: TextField(
                        key: const Key('pack-detail-quantity'),
                        controller: _quantity,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: AppStrings.t('quantity', loc),
                        ),
                        onSubmitted: (_) => _check(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('pack-detail-check'),
                    onPressed: _loading ? null : _check,
                    child: Text(AppStrings.t('refresh', loc)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Text(
                  _error!,
                  key: const Key('pack-detail-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else if (availability != null) ...[
                _availabilityBanner(context, loc, theme, availability),
                const SizedBox(height: 12),
                _componentsTable(loc, theme, availability),
                if (availability.errors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final e in availability.errors)
                    Text(
                      e,
                      key: const Key('pack-detail-availability-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pack-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }

  Widget _availabilityBanner(
    BuildContext context,
    String loc,
    ThemeData theme,
    PackAvailabilityModel availability,
  ) {
    final ok = availability.saleable;
    return Container(
      key: const Key('pack-availability-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (ok ? AppColors.success : AppColors.error)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (ok ? AppColors.success : AppColors.error)
              .withValues(alpha: 0.5),
        ),
      ),
      child: Text(
        ok
            ? '${AppStrings.t('max_packs', loc)}: ${availability.maxPackQuantity}'
            : AppStrings.t('pack_not_saleable', loc),
        key: Key(ok ? 'pack-availability-ok' : 'pack-availability-blocked'),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: ok ? AppColors.success : AppColors.error,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _componentsTable(String loc, ThemeData theme, PackAvailabilityModel a) {
    final head = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.outline,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(flex: 4, child: Text(AppStrings.t('components', loc), style: head)),
            Expanded(
              flex: 2,
              child: Text(
                AppStrings.t('quantity', loc),
                style: head,
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                AppStrings.t('available_quantity', loc),
                style: head,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const Divider(height: 12),
        for (var i = 0; i < a.components.length; i++)
          _componentRow(theme, a.components[i], i),
      ],
    );
  }

  /// Product name + (when the pack pins a selling unit) the exact conversion
  /// the backend stored, e.g. "2 Box = 48 piece". The quantity columns stay
  /// in BASE units — they are what the sale actually deducts.
  Widget _componentRow(
    ThemeData theme,
    PackComponentAvailabilityModel component,
    int index,
  ) {
    final body = theme.textTheme.bodyMedium;
    final multiplier =
        double.tryParse(component.sellingUnitMultiplier ?? '1') ?? 1;
    final showConversion =
        component.hasSellingUnit && (multiplier - 1).abs() > 0.0000001;

    return Padding(
      key: Key('pack-availability-component-$index'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  component.productName,
                  style: body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (showConversion)
                  Text(
                    '${component.unitQuantity} ${component.sellingUnitName} '
                    '= ${component.requiredPerPack} ${component.productUnit}',
                    key: Key('pack-availability-component-unit-$index'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              component.requiredQuantity,
              style: body?.copyWith(
                color: component.ok ? null : AppColors.error,
                fontWeight:
                    component.ok ? FontWeight.w400 : FontWeight.w700,
              ),
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              component.availableQuantity,
              style: body,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
