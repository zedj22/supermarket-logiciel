// Price override confirmation dialog (Phase 8 Step 3 review fix).
//
// Shown when POST /api/v1/sales returns a non-empty price_overrides[].
// The sale already committed with server-authoritative prices; this dialog
// makes the difference explicit so the cashier cannot miss it.
// Cart is NOT cleared because of the override — only because checkout
// succeeded (handled by PosCartNotifier.checkout).
import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import 'pos_models.dart';

class PriceOverrideDialog extends StatelessWidget {
  final List<PriceOverrideModel> overrides;

  const PriceOverrideDialog({super.key, required this.overrides});

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('price-override-dialog'),
      title: Text(AppStrings.t('price_override_dialog_title', loc)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                AppStrings.t('price_override_explanation', loc),
                key: const Key('price-override-explanation'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.t('price_override_server_price', loc),
                key: const Key('price-override-server-price-label'),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              for (final o in overrides) ...[
                Card(
                  key: Key('price-override-row-${o.identity}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          o.productName ?? o.identity,
                          key: Key('price-override-name-${o.identity}'),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        _PriceRow(
                          label: AppStrings.t('price_override_client_price', loc),
                          value: o.requestedUnitPrice,
                          keyPrefix: 'price-override-client-${o.identity}',
                          color: theme.colorScheme.outline,
                        ),
                        _PriceRow(
                          label: AppStrings.t('price_override_server_price', loc),
                          value: o.appliedUnitPrice,
                          keyPrefix: 'price-override-server-${o.identity}',
                          color: AppColors.success,
                          emphasize: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        ElevatedButton(
          key: const Key('price-override-acknowledge'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(AppStrings.t('price_override_acknowledge', loc)),
        ),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget {
  final String label;
  final String value;
  final String keyPrefix;
  final Color? color;
  final bool emphasize;

  const _PriceRow({
    required this.label,
    required this.value,
    required this.keyPrefix,
    this.color,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasize
        ? theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          )
        : theme.textTheme.bodyMedium?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(
            value,
            key: Key(keyPrefix),
            style: style,
          ),
        ],
      ),
    );
  }
}

/// Blocks until the cashier acknowledges. Non-dismissible (no barrier tap).
Future<void> showPriceOverrideDialog(
  BuildContext context,
  List<PriceOverrideModel> overrides,
) {
  if (overrides.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PriceOverrideDialog(overrides: overrides),
  );
}
