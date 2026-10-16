// Sale history dialog (reprint / recent sales).
// UX FIX #4: rows show invoice / date / total / payment / status and
// open Sale Detail (print / reprint / copy invoice / refresh / close).
// Full reporting is a later phase — list + detail only.
// UX FIX #12 (FIX #1): each row also shows a compact sold-units summary
// (`2 Box · 48 Piece`) so the invoice content is visible at a glance.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'pos_providers.dart';
import 'sale_detail_dialog.dart';

Future<void> showSaleHistoryDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const SaleHistoryDialog(),
  );
}

class SaleHistoryDialog extends ConsumerStatefulWidget {
  const SaleHistoryDialog({super.key});

  @override
  ConsumerState<SaleHistoryDialog> createState() => _SaleHistoryDialogState();
}

class _SaleHistoryDialogState extends ConsumerState<SaleHistoryDialog> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(saleHistoryProvider.notifier).load(),
    );
  }

  Future<void> _openDetail(String saleId, String invoiceNumber) async {
    await showSaleDetailDialog(
      context,
      saleId: saleId,
      invoiceNumber: invoiceNumber,
    );
    // Refresh list after detail closes (sale unchanged, but cheap).
    if (!mounted) return;
    await ref.read(saleHistoryProvider.notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final state = ref.watch(saleHistoryProvider);

    return AlertDialog(
      key: const Key('sale-history-dialog'),
      title: Text(AppStrings.t('sale_history', loc)),
      content: SizedBox(
        width: 520,
        height: 400,
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : state.error != null
                ? Center(
                    child: Text(
                      state.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : state.items.isEmpty
                    ? Center(child: Text(AppStrings.t('no_sales', loc)))
                    : ListView.builder(
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final sale = state.items[index];
                          final date = sale.saleDate
                              .toLocal()
                              .toString()
                              .substring(0, 16);
                          final units = sale.unitSummaryText(loc);
                          return ListTile(
                            key: Key('sale-row-${sale.id}'),
                            isThreeLine: true,
                            leading: const Icon(Icons.receipt_long_outlined),
                            title: Text(sale.invoiceNumber),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (units != null)
                                  Text(
                                    units,
                                    key: Key('sale-row-units-${sale.id}'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                Text(
                                  // Bidi: the date/time pair is one LTR
                                  // isolate so its two numeric groups never
                                  // swap next to the Arabic labels.
                                  '${bidiIsolateLtr(date)} · '
                                  '${AppStrings.t('payment_method', loc)}: '
                                  '${sale.paymentMethod}'
                                  '${sale.customerId != null ? ' · ${AppStrings.t('customer', loc)}' : ''}'
                                  '${sale.status.isNotEmpty ? ' · ${sale.status}' : ''}',
                                  key: Key('sale-row-meta-${sale.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                            trailing: numericText(
                              formatGrouped(sale.total),
                              key: Key('sale-row-total-${sale.id}'),
                              style: theme.textTheme.titleSmall,
                            ),
                            onTap: () => _openDetail(sale.id, sale.invoiceNumber),
                          );
                        },
                      ),
      ),
      actions: [
        if (state.page > 1)
          TextButton(
            onPressed: () => ref
                .read(saleHistoryProvider.notifier)
                .load(page: state.page - 1),
            child: Text(AppStrings.t('prev', loc)),
          ),
        TextButton(
          key: const Key('sale-history-refresh'),
          onPressed: () =>
              ref.read(saleHistoryProvider.notifier).load(page: state.page),
          child: Text(AppStrings.t('refresh', loc)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}
