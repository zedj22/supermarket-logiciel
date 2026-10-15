// Phase E — customer loyalty history dialog.
//
// Reads the append-only ledger (`GET /api/v1/customers/{id}/loyalty/history`)
// with the balance header on top. Refreshes on open exactly like the debt
// history does — a sale/redeem recorded since the last open must never show
// a stale snapshot. All amounts are server numbers; this dialog only
// formats them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_models.dart';
import 'loyalty_models.dart';
import 'loyalty_providers.dart';

Future<void> showLoyaltyHistoryDialog(
  BuildContext context, {
  required String customerId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => LoyaltyHistoryDialog(customerId: customerId),
  );
}

class LoyaltyHistoryDialog extends ConsumerStatefulWidget {
  const LoyaltyHistoryDialog({super.key, required this.customerId});

  final String customerId;

  @override
  ConsumerState<LoyaltyHistoryDialog> createState() =>
      _LoyaltyHistoryDialogState();
}

class _LoyaltyHistoryDialogState extends ConsumerState<LoyaltyHistoryDialog> {
  @override
  void initState() {
    super.initState();
    // Silent refresh on open — skipped while a first load is in flight
    // (same contract as the pane's debt history refresh).
    Future.microtask(() {
      final balance =
          ref.read(loyaltyBalanceProvider(widget.customerId));
      if (!balance.loading) {
        ref.read(loyaltyBalanceProvider(widget.customerId).notifier).refresh();
      }
      final history = ref.read(loyaltyHistoryProvider(widget.customerId));
      if (!history.loading) {
        ref.read(loyaltyHistoryProvider(widget.customerId).notifier).refresh();
      }
    });
  }

  IconData _iconFor(String eventType) {
    switch (eventType) {
      case 'sale_earn':
      case 'debt_settlement_earn':
        return Icons.stars;
      case 'redeem':
        return Icons.redeem;
      case 'return_clawback':
      case 'void_clawback':
        return Icons.undo;
      case 'expiry':
        return Icons.hourglass_bottom;
      default:
        return Icons.tune;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final balance = ref.watch(loyaltyBalanceProvider(widget.customerId));
    final state = ref.watch(loyaltyHistoryProvider(widget.customerId));
    final currency = AppStrings.t('currency', loc);

    final Widget body;
    if (state.loading && state.items.isEmpty) {
      body = const Center(
        key: Key('loyalty-history-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (state.error != null) {
      body = Center(
        key: const Key('loyalty-history-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('loyalty-history-retry'),
              onPressed: () => ref
                  .read(loyaltyHistoryProvider(widget.customerId).notifier)
                  .refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    } else if (state.items.isEmpty) {
      body = Center(
        key: const Key('loyalty-history-empty'),
        child: Text(AppStrings.t('loyalty_history_empty', loc)),
      );
    } else {
      body = ListView.builder(
        key: const Key('loyalty-history-list'),
        itemCount: state.items.length,
        itemBuilder: (context, index) {
          final entry = state.items[index];
          final points =
              '${entry.pointsDelta > 0 ? '+' : ''}'
              '${formatLoyaltyPoints(entry.pointsDelta)} '
              '${AppStrings.t('loyalty_points', loc)}';
          final cashbackPart = entry.cashbackDelta == 0
              ? ''
              : ' · ${entry.cashbackDelta > 0 ? '+' : ''}'
                  '${PaymentMath.money(entry.cashbackDelta)} $currency';
          final meta = <String>[
            if (entry.createdAt != null)
              entry.createdAt!.toLocal().toString().substring(0, 16),
            if (entry.invoiceNumber != null)
              '${AppStrings.t('invoice_number', loc)}: ${entry.invoiceNumber}',
            '${AppStrings.t('loyalty_balance', loc)}: '
            '${formatLoyaltyPoints(entry.balanceAfterPoints)}',
            if (entry.note != null && entry.note!.isNotEmpty) entry.note!,
          ].join(' · ');
          return ListTile(
            key: Key('loyalty-history-row-$index'),
            dense: true,
            leading: Icon(
              _iconFor(entry.eventType),
              size: 20,
              color: entry.pointsDelta >= 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.tertiary,
            ),
            title: Text(
              '${AppStrings.t(loyaltyEventTypeKey(entry.eventType), loc)}'
              ' · $points$cashbackPart',
              key: Key('loyalty-history-title-$index'),
            ),
            subtitle: meta.isEmpty
                ? null
                : Text(meta, key: Key('loyalty-history-meta-$index')),
          );
        },
      );
    }

    return AlertDialog(
      key: const Key('loyalty-history-dialog'),
      title: Text(AppStrings.t('loyalty_history', loc)),
      content: SizedBox(
        width: 460,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('loyalty-history-balance'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: balance.balance == null
                  ? Text(
                      balance.error ??
                          '${AppStrings.t('loyalty_balance', loc)}: …',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${AppStrings.t('loyalty_points', loc)}: '
                            '${formatLoyaltyPoints(balance.balance!.pointsBalance)}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Text(
                          '${AppStrings.t('loyalty_cashback', loc)}: '
                          '${PaymentMath.money(balance.balance!.cashbackBalance)} '
                          '$currency',
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            if (state.loading && state.items.isNotEmpty)
              const LinearProgressIndicator(key: Key('loyalty-history-busy')),
            Expanded(child: body),
            if (state.pages > 1) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const Key('loyalty-history-prev'),
                    onPressed: state.page > 1 && !state.loading
                        ? () => ref
                            .read(loyaltyHistoryProvider(widget.customerId)
                                .notifier)
                            .setPage(state.page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left, size: 20),
                  ),
                  Text(
                    '${state.page} / ${state.pages}',
                    key: const Key('loyalty-history-page'),
                    style: theme.textTheme.bodySmall,
                  ),
                  IconButton(
                    key: const Key('loyalty-history-next'),
                    onPressed: state.page < state.pages && !state.loading
                        ? () => ref
                            .read(loyaltyHistoryProvider(widget.customerId)
                                .notifier)
                            .setPage(state.page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right, size: 20),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('loyalty-history-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('close', loc)),
        ),
      ],
    );
  }
}
