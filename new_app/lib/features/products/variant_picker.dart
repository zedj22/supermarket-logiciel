// Variant picker (Phase 6).
//
// Lists a product's active variants for selection (POS Phase 8 / product
// form). Price NULL inherits the product price — shown as the passed
// productPrice fallback. Archive semantics only; no hard delete.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
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

    return AlertDialog(
      key: const Key('variant-picker'),
      title: Text(AppStrings.t('variants', loc)),
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
                    key: const Key('variant-picker-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  )
                : state.items.isEmpty
                    ? Text(
                        AppStrings.t('no_variants', loc),
                        key: const Key('variant-picker-empty'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: state.items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final v = state.items[index];
                          final price = v.price ?? widget.productPrice ?? '—';
                          return ListTile(
                            key: Key('variant-${v.id}'),
                            dense: true,
                            title: Text(v.name),
                            subtitle: Text(
                              '${AppStrings.t('price', loc)}: $price · '
                              '${AppStrings.t('stock_quantity', loc)}: ${v.quantity}',
                            ),
                            trailing: v.barcode != null
                                ? Text(
                                    v.barcode!,
                                    style: theme.textTheme.labelSmall,
                                  )
                                : null,
                            onTap: v.isArchived ? null : () => Navigator.pop(context, v),
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
