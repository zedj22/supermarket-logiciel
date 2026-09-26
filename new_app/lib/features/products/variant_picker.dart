// Variant picker (Phase 6 / UX FIX #6).
//
// Lists a product's active variants as option cards via PosOptionPickerDialog.
// Price NULL inherits the product price — shown as the passed productPrice
// fallback. Archive semantics only; no hard delete.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_option_picker.dart';
import 'models.dart';
import 'products_providers.dart';

Future<VariantModel?> showVariantPicker(
  BuildContext context, {
  required String productId,
  String? productPrice,
}) {
  return showDialog<VariantModel>(
    context: context,
    builder: (_) => VariantPicker(
      productId: productId,
      productPrice: productPrice,
    ),
  );
}

class VariantPicker extends ConsumerStatefulWidget {
  final String productId;
  final String? productPrice;

  const VariantPicker({
    super.key,
    required this.productId,
    this.productPrice,
  });

  @override
  ConsumerState<VariantPicker> createState() => _VariantPickerState();
}

class _VariantPickerState extends ConsumerState<VariantPicker> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(variantsProvider.notifier).load(widget.productId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(variantsProvider);
    final theme = Theme.of(context);

    if (state.loading) {
      return AlertDialog(
        key: const Key('variant-picker'),
        title: Text(AppStrings.t('variants', loc)),
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
        key: const Key('variant-picker'),
        title: Text(AppStrings.t('variants', loc)),
        content: SizedBox(
          width: 440,
          child: Text(
            state.error!,
            key: const Key('variant-picker-error'),
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
    if (state.items.isEmpty) {
      return AlertDialog(
        key: const Key('variant-picker'),
        title: Text(AppStrings.t('variants', loc)),
        content: SizedBox(
          width: 440,
          child: Text(
            AppStrings.t('no_variants', loc),
            key: const Key('variant-picker-empty'),
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

    final cards = <PosOptionCard>[
      for (final v in state.items)
        PosOptionCard(
          optionKey: 'variant-${v.id}',
          title: v.name,
          price: v.price ?? widget.productPrice,
          secondary: (double.tryParse(v.quantity) ?? 0) <= 0
              ? AppStrings.t('out_of_stock', loc)
              : v.barcode,
          enabled: !v.isArchived && (double.tryParse(v.quantity) ?? 0) > 0,
        ),
    ];

    return PosOptionPickerDialog(
      title: AppStrings.t('variants', loc),
      subtitle: AppStrings.t('select_variant_hint', loc),
      options: cards,
      dialogKey: 'variant-picker',
      onConfirm: (index) async {
        final v = state.items[index];
        if (v.isArchived || (double.tryParse(v.quantity) ?? 0) <= 0) {
          return;
        }
        if (!mounted) return;
        Navigator.pop(context, v);
      },
    );
  }
}
