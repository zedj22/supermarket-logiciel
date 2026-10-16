// Debts screen (Phase 9): accounts-receivable overview.
//
// Summary KPIs (GET /api/v1/debts/summary) + debtors list (customer
// list with has_debt=true — a SEPARATE provider instance, so the
// clients screen query is never mutated). Recording a payment from
// here reuses the same dialog/backend command as the clients screen.
//
// RBAC: customer_view to read, customer_manage to record payments.
// The credit ceiling is display-only (no enforcement — Phase 9 gate).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/clients_providers.dart';
import '../clients/customer_models.dart';
import '../clients/debt_payment_dialog.dart';
import '../pos/pos_toast.dart';

class DebtsScreen extends ConsumerStatefulWidget {
  const DebtsScreen({super.key});

  @override
  ConsumerState<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends ConsumerState<DebtsScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh on every visit (providers keep their state alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(debtorsProvider.notifier).load();
      ref.read(debtSummaryProvider.notifier).refresh();
    });
  }

  Future<void> _pay(CustomerModel customer) async {
    final result = await showDebtPaymentDialog(context, customer: customer);
    if (result == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('payment_success', loc),
      detail: formatMoney(result.amount),
      kind: PosToastKind.success,
      key: const Key('debts-payment-success-toast'),
    );
    ref.read(debtorsProvider.notifier).refresh();
    ref.read(debtSummaryProvider.notifier).refresh();
    // Fix Round 2 (debt balance bug): a payment moves the AGGREGATE
    // customer balance, so every cached view of that customer must be
    // re-read too — otherwise the clients detail card and its ledger keep
    // the pre-payment snapshot. Only providers that are already alive are
    // touched, so nothing is fetched for a screen that never opened it.
    if (ref.exists(customersProvider)) {
      ref.read(customersProvider.notifier).refresh();
    }
    if (ref.exists(customerDetailProvider(result.customerId))) {
      ref
          .read(customerDetailProvider(result.customerId).notifier)
          .load(silent: true);
    }
    if (ref.exists(debtHistoryProvider(result.customerId))) {
      ref.read(debtHistoryProvider(result.customerId).notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('customer_view'));
    final canManage = ref.watch(hasPermissionProvider('customer_manage'));

    if (!canView) {
      return Center(
        key: const Key('debts-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final summary = ref.watch(debtSummaryProvider);
    final debtors = ref.watch(debtorsProvider);

    return Padding(
      key: const Key('debts-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('debts', loc),
                key: const Key('debts-title'),
                style: theme.textTheme.headlineSmall,
              ),
              const Spacer(),
              IconButton(
                key: const Key('debts-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () {
                  ref.read(debtSummaryProvider.notifier).refresh();
                  ref.read(debtorsProvider.notifier).refresh();
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSummary(theme, loc, summary),
          const SizedBox(height: 16),
          SizedBox(
            width: 320,
            child: TextField(
              key: const Key('debts-search'),
              decoration: InputDecoration(
                hintText: AppStrings.t('search', loc),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                border: const OutlineInputBorder(),
              ),
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              onChanged: (value) =>
                  ref.read(debtorsProvider.notifier).setSearch(value),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${AppStrings.t('total', loc)}: ${debtors.total}',
            key: const Key('debts-total-count'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildDebtors(theme, loc, debtors, canManage)),
          if (debtors.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('debts-prev'),
                  onPressed: debtors.query.page > 1 && !debtors.loading
                      ? () => ref
                          .read(debtorsProvider.notifier)
                          .setPage(debtors.query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${debtors.query.page} / ${debtors.pages}',
                  key: const Key('debts-page'),
                ),
                IconButton(
                  key: const Key('debts-next'),
                  onPressed:
                      debtors.query.page < debtors.pages && !debtors.loading
                          ? () => ref
                              .read(debtorsProvider.notifier)
                              .setPage(debtors.query.page + 1)
                          : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary(
    ThemeData theme,
    String loc,
    DebtSummaryState summary,
  ) {
    if (summary.loading && summary.summary == null) {
      return const LinearProgressIndicator(key: Key('debts-summary-loading'));
    }
    if (summary.error != null) {
      return Material(
        key: const Key('debts-summary-error'),
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  summary.error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              TextButton(
                key: const Key('debts-summary-retry'),
                onPressed: () =>
                    ref.read(debtSummaryProvider.notifier).refresh(),
                child: Text(AppStrings.t('retry', loc)),
              ),
            ],
          ),
        ),
      );
    }
    final data = summary.summary;
    if (data == null) return const SizedBox.shrink();
    // Wrap: the two fixed-width cards share one line on desktop and drop
    // to two lines on very narrow windows instead of overflowing the Row
    // ("RenderFlex overflowed by 177 pixels" at a 600px window).
    return Wrap(
      key: const Key('debts-summary'),
      spacing: 16,
      runSpacing: 8,
      children: [
        _summaryCard(
          theme,
          loc,
          key: const Key('debts-total'),
          label: AppStrings.t('total_debt', loc),
          value: formatMoney(data.totalDebt),
        ),
        _summaryCard(
          theme,
          loc,
          key: const Key('debts-count'),
          label: AppStrings.t('customers_with_debt', loc),
          value: '${data.customersWithDebt}',
        ),
      ],
    );
  }

  Widget _summaryCard(
    ThemeData theme,
    String loc, {
    required Key key,
    required String label,
    required String value,
  }) {
    return Card(
      key: key,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            numericText(value, style: theme.textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }

  Widget _buildDebtors(
    ThemeData theme,
    String loc,
    CustomersState debtors,
    bool canManage,
  ) {
    if (debtors.loading && debtors.items.isEmpty) {
      return const Center(
        key: Key('debts-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (debtors.error != null) {
      return Center(
        key: const Key('debts-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(debtors.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('debts-retry'),
              onPressed: () => ref.read(debtorsProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (debtors.items.isEmpty) {
      return Center(
        key: const Key('debts-empty'),
        child: Text(AppStrings.t('no_data', loc)),
      );
    }
    return ListView.builder(
      key: const Key('debts-list'),
      itemCount: debtors.items.length,
      itemBuilder: (context, index) {
        final customer = debtors.items[index];
        final balanceMilli = moneyToMilli(customer.balance) ?? 0;
        final ceilingMilli = moneyToMilli(customer.debtCeiling) ?? 0;
        final overLimit = balanceMilli > ceilingMilli && ceilingMilli > 0;
        return ListTile(
          key: Key('debtor-tile-$index'),
          title: Text(customer.name, key: Key('debtor-name-$index')),
          subtitle: customer.phone == null
              ? null
              : Text(customer.phone!, key: Key('debtor-phone-$index')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  numericText(
                    formatMoney(customer.balance),
                    key: Key('debtor-balance-$index'),
                    style: theme.textTheme.titleMedium,
                  ),
                  if (overLimit)
                    Text(
                      AppStrings.t('over_limit_hint', loc),
                      key: Key('debtor-over-limit-$index'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
              if (canManage) ...[
                const SizedBox(width: 12),
                OutlinedButton(
                  key: Key('debtor-pay-button-$index'),
                  onPressed: balanceMilli > 0 && !customer.isArchived
                      ? () => _pay(customer)
                      : null,
                  child: Text(AppStrings.t('record_payment', loc)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
