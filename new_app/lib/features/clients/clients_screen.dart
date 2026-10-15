// Clients screen (Phase 9): master/detail customer management.
//
// Left pane — paginated customer list with debounced search and an
// "show archived" toggle. Right pane — selected customer detail,
// balance / credit-limit display, create/edit/archive actions (gated by
// customer_manage), and the paginated debt-history ledger.
//
// RBAC: viewing requires customer_view (whole screen); mutations are
// hidden without customer_manage. Balance/credit-limit are display-only
// here — the credit ceiling is NEVER enforced at this layer (Phase 9
// decision gate: unresolved).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../loyalty/loyalty_history_dialog.dart';
import '../loyalty/loyalty_models.dart';
import '../loyalty/loyalty_providers.dart';
import '../pos/pos_toast.dart';
import 'clients_error.dart';
import 'clients_providers.dart';
import 'customer_form_dialog.dart';
import 'customer_models.dart';
import 'debt_payment_dialog.dart';

String _timestampOf(DateTime? value) {
  if (value == null) return '';
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final h = value.hour.toString().padLeft(2, '0');
  final min = value.minute.toString().padLeft(2, '0');
  final s = value.second.toString().padLeft(2, '0');
  return '${value.year}-$m-$d $h:$min:$s';
}

class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (provider state itself is kept alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(customersProvider.notifier).load();
    });
  }

  void _select(String id) => setState(() => _selectedId = id);

  void _clearSelection() => setState(() => _selectedId = null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('customer_view'));
    final canManage = ref.watch(hasPermissionProvider('customer_manage'));

    if (!canView) {
      return Center(
        key: const Key('clients-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final state = ref.watch(customersProvider);
    final query = state.query;

    return Padding(
      key: const Key('clients-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wide windows keep the original single-row header (measured
          // one-line width ≈ 1007px in Arabic); tighter windows let the
          // title, search, chip and add button wrap instead of
          // overflowing ("RenderFlex overflowed by 335 pixels").
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Text(
                AppStrings.t('clients', loc),
                key: const Key('clients-title'),
                style: theme.textTheme.headlineSmall,
              );
              final searchField = SizedBox(
                width: 260,
                child: TextField(
                  key: const Key('clients-search'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  onChanged: (value) =>
                      ref.read(customersProvider.notifier).setSearch(value),
                ),
              );
              final archivedToggle = FilterChip(
                key: const Key('clients-archived-toggle'),
                label: Text(AppStrings.t('show_archived', loc)),
                selected: query.includeArchived,
                onSelected: (value) => ref
                    .read(customersProvider.notifier)
                    .setIncludeArchived(value),
              );
              final addButton = canManage
                  ? ElevatedButton.icon(
                      key: const Key('clients-add-button'),
                      onPressed: () => showCustomerFormDialog(context),
                      icon: const Icon(Icons.person_add_alt),
                      label: Text(AppStrings.t('add_client', loc)),
                    )
                  : null;

              if (constraints.maxWidth >= 1050) {
                return Row(
                  children: [
                    title,
                    const SizedBox(width: 24),
                    searchField,
                    const SizedBox(width: 16),
                    archivedToggle,
                    const Spacer(),
                    ?addButton,
                  ],
                );
              }
              return Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  title,
                  searchField,
                  archivedToggle,
                  ?addButton,
                ],
              );
            },
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Material(
              key: const Key('clients-error'),
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('clients-retry'),
                      onPressed: () =>
                          ref.read(customersProvider.notifier).refresh(),
                      child: Text(AppStrings.t('retry', loc)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${AppStrings.t('total', loc)}: ${state.total}',
                        key: const Key('clients-total'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Expanded(child: _buildList(theme, loc, state)),
                      if (state.pages > 1) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              key: const Key('clients-prev'),
                              onPressed: query.page > 1 && !state.loading
                                  ? () => ref
                                      .read(customersProvider.notifier)
                                      .setPage(query.page - 1)
                                  : null,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Text(
                              '${query.page} / ${state.pages}',
                              key: const Key('clients-page'),
                            ),
                            IconButton(
                              key: const Key('clients-next'),
                              onPressed:
                                  query.page < state.pages && !state.loading
                                      ? () => ref
                                          .read(customersProvider.notifier)
                                          .setPage(query.page + 1)
                                      : null,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 6,
                  child: _selectedId == null
                      ? Center(
                          key: const Key('clients-detail-empty'),
                          child: Text(AppStrings.t('select_client_hint', loc)),
                        )
                      : _CustomerDetailPane(
                          customerId: _selectedId!,
                          canManage: canManage,
                          onSelectionCleared: _clearSelection,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme, String loc, CustomersState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('clients-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('clients-empty'),
        child: Text(AppStrings.t('no_data', loc)),
      );
    }
    return ListView.builder(
      key: const Key('clients-list'),
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final customer = state.items[index];
        final balanceMilli = moneyToMilli(customer.balance) ?? 0;
        final ceilingMilli = moneyToMilli(customer.debtCeiling) ?? 0;
        final overLimit = balanceMilli > ceilingMilli && ceilingMilli > 0;
        return ListTile(
          key: Key('client-tile-$index'),
          selected: _selectedId == customer.id,
          onTap: () => _select(customer.id),
          title: Text(customer.name, key: Key('client-name-$index')),
          subtitle: customer.phone == null
              ? null
              : Text(customer.phone!, key: Key('client-phone-$index')),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMoney(customer.balance),
                key: Key('client-balance-$index'),
                style: theme.textTheme.titleMedium,
              ),
              if (overLimit)
                Text(
                  AppStrings.t('over_limit_hint', loc),
                  key: Key('client-over-limit-$index'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Detail pane
// ---------------------------------------------------------------------------

class _CustomerDetailPane extends ConsumerStatefulWidget {
  final String customerId;
  final bool canManage;
  final VoidCallback onSelectionCleared;

  const _CustomerDetailPane({
    required this.customerId,
    required this.canManage,
    required this.onSelectionCleared,
  });

  @override
  ConsumerState<_CustomerDetailPane> createState() =>
      _CustomerDetailPaneState();
}

class _CustomerDetailPaneState extends ConsumerState<_CustomerDetailPane> {
  @override
  void initState() {
    super.initState();
    // Fix Round 2 (debt balance bug): the detail + debt-history providers
    // are NON-autoDispose families that load exactly once per customer id,
    // so a (re)opened pane must re-read the server — otherwise a credit
    // sale or payment recorded since the first open keeps showing the
    // stale snapshot instead of the aggregate outstanding balance.
    Future.microtask(_refreshFromServer);
  }

  @override
  void didUpdateWidget(covariant _CustomerDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customerId != widget.customerId) {
      // Reused State for a different customer — re-read that id too.
      Future.microtask(_refreshFromServer);
    }
  }

  /// Silent refresh of detail + history. Skipped while a first-ever load
  /// is in flight to avoid a duplicate GET on the initial open. The
  /// master list keeps its own refresh in the screen's initState.
  Future<void> _refreshFromServer() async {
    if (!mounted) return;
    final detail = ref.read(customerDetailProvider(widget.customerId));
    if (!detail.isLoading) {
      ref
          .read(customerDetailProvider(widget.customerId).notifier)
          .load(silent: true);
    }
    final history = ref.read(debtHistoryProvider(widget.customerId));
    if (!history.loading) {
      ref.read(debtHistoryProvider(widget.customerId).notifier).refresh();
    }
    if (ref.exists(loyaltyBalanceProvider(widget.customerId))) {
      final loyalty = ref.read(loyaltyBalanceProvider(widget.customerId));
      if (!loyalty.loading) {
        ref
            .read(loyaltyBalanceProvider(widget.customerId).notifier)
            .refresh();
      }
    }
    if (ref.exists(loyaltyHistoryProvider(widget.customerId))) {
      final ledger = ref.read(loyaltyHistoryProvider(widget.customerId));
      if (!ledger.loading) {
        ref.read(loyaltyHistoryProvider(widget.customerId).notifier).refresh();
      }
    }
  }

  Future<void> _reloadAll() async {
    ref.read(customerDetailProvider(widget.customerId).notifier).load();
    ref.read(debtHistoryProvider(widget.customerId).notifier).refresh();
    ref.read(customersProvider.notifier).refresh();
    if (ref.exists(loyaltyBalanceProvider(widget.customerId))) {
      ref.read(loyaltyBalanceProvider(widget.customerId).notifier).refresh();
    }
    if (ref.exists(loyaltyHistoryProvider(widget.customerId))) {
      ref.read(loyaltyHistoryProvider(widget.customerId).notifier).refresh();
    }
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
      key: const Key('client-payment-success-toast'),
    );
    await _reloadAll();
  }

  Future<void> _edit(CustomerModel customer) async {
    await showCustomerFormDialog(context, customer: customer);
    if (!mounted) return;
    await _reloadAll();
  }

  Future<void> _archive(CustomerModel customer) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('client-archive-confirm'),
        title: Text(AppStrings.t('archive_client_confirm', loc)),
        actions: [
          TextButton(
            key: const Key('client-archive-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('client-archive-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('archive', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error = await ref
        .read(customersProvider.notifier)
        .archiveCustomer(widget.customerId);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('client_archived', loc),
        kind: PosToastKind.success,
        key: const Key('client-archive-success-toast'),
      );
      widget.onSelectionCleared();
      ref.read(customersProvider.notifier).refresh();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('client-archive-error-toast'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final detail = ref.watch(customerDetailProvider(widget.customerId));

    return detail.when(
      loading: () => const Center(
        key: Key('client-detail-loading'),
        child: CircularProgressIndicator(),
      ),
      error: (error, _) => Center(
        key: const Key('client-detail-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(clientsApiMessage(error, loc)),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const Key('client-detail-retry'),
              onPressed: () => ref
                  .read(customerDetailProvider(widget.customerId).notifier)
                  .load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      ),
      data: (customer) {
        if (customer == null) {
          return Center(
            key: const Key('client-detail-missing'),
            child: Text(AppStrings.t('customer_not_found', loc)),
          );
        }
        final balanceMilli = moneyToMilli(customer.balance) ?? 0;
        final ceilingMilli = moneyToMilli(customer.debtCeiling) ?? 0;
        final overLimit = balanceMilli > ceilingMilli && ceilingMilli > 0;
        final loyalty = ref.watch(loyaltyBalanceProvider(widget.customerId));

        return Padding(
          key: const Key('client-detail'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      customer.name,
                      key: const Key('client-detail-name'),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (customer.isArchived)
                    Chip(
                      key: const Key('client-detail-archived'),
                      label: Text(AppStrings.t('archived', loc)),
                    ),
                ],
              ),
              if (customer.phone != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    customer.phone!,
                    key: const Key('client-detail-phone'),
                  ),
                ),
              if (customer.address != null)
                Text(
                  customer.address!,
                  key: const Key('client-detail-address'),
                ),
              const SizedBox(height: 16),
              Card(
                key: const Key('client-balance-card'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${AppStrings.t('balance', loc)}: '
                        '${formatMoney(customer.balance)}',
                        key: const Key('client-detail-balance'),
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${AppStrings.t('debt_ceiling', loc)}: '
                        '${formatMoney(customer.debtCeiling)}',
                        key: const Key('client-detail-ceiling'),
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (overLimit)
                        Text(
                          AppStrings.t('over_limit_hint', loc),
                          key: const Key('client-detail-over-limit'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      // Phase E — loyalty balances (server-computed; hidden
                      // while the read is in flight or failed — the history
                      // dialog owns its own retry UI).
                      if (loyalty.balance != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          key: const Key('client-loyalty-row'),
                          children: [
                            Expanded(
                              child: Text(
                                '${AppStrings.t('loyalty_points', loc)}: '
                                '${formatLoyaltyPoints(loyalty.balance!.pointsBalance)}',
                                key: const Key('client-loyalty-points'),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${AppStrings.t('loyalty_cashback', loc)}: '
                                '${formatMoney(loyalty.balance!.cashbackBalance.toStringAsFixed(2))}',
                                key: const Key('client-loyalty-cashback'),
                                textAlign: TextAlign.end,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              key: const Key('client-loyalty-history-button'),
                              tooltip: AppStrings.t('loyalty_history', loc),
                              visualDensity: VisualDensity.compact,
                              iconSize: 20,
                              icon: const Icon(Icons.stars_outlined),
                              onPressed: () => showLoyaltyHistoryDialog(
                                context,
                                customerId: widget.customerId,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (widget.canManage) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      key: const Key('client-pay-button'),
                      onPressed: balanceMilli > 0 && !customer.isArchived
                          ? () => _pay(customer)
                          : null,
                      icon: const Icon(Icons.payments_outlined),
                      label: Text(AppStrings.t('record_payment', loc)),
                    ),
                    OutlinedButton.icon(
                      key: const Key('client-edit-button'),
                      onPressed: customer.isArchived
                          ? null
                          : () => _edit(customer),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(AppStrings.t('edit', loc)),
                    ),
                    OutlinedButton.icon(
                      key: const Key('client-archive-button'),
                      onPressed: customer.isArchived
                          ? null
                          : () => _archive(customer),
                      icon: const Icon(Icons.archive_outlined),
                      label: Text(AppStrings.t('archive', loc)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              _DebtHistorySection(customerId: widget.customerId),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Debt history section
// ---------------------------------------------------------------------------

class _DebtHistorySection extends ConsumerWidget {
  final String customerId;

  const _DebtHistorySection({required this.customerId});

  IconData _iconFor(String entryType) {
    switch (entryType) {
      case 'sale':
        return Icons.trending_up;
      case 'payment':
        return Icons.trending_down;
      default:
        return Icons.tune;
    }
  }

  Color _colorFor(BuildContext context, String entryType) {
    final scheme = Theme.of(context).colorScheme;
    switch (entryType) {
      case 'sale':
        return scheme.error;
      case 'payment':
        return scheme.primary;
      default:
        return scheme.tertiary;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(debtHistoryProvider(customerId));

    final Widget body;
    if (state.loading && state.items.isEmpty) {
      body = const Center(
        key: Key('client-hist-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (state.error != null) {
      body = Center(
        key: const Key('client-hist-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('client-hist-retry'),
              onPressed: () =>
                  ref.read(debtHistoryProvider(customerId).notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    } else if (state.items.isEmpty) {
      body = Center(
        key: const Key('client-hist-empty'),
        child: Text(AppStrings.t('no_debt_records', loc)),
      );
    } else {
      body = ListView.builder(
        key: const Key('client-hist-list'),
        itemCount: state.items.length,
        itemBuilder: (context, index) {
          final entry = state.items[index];
          // Pay All is a normal payment entry; the UI distinguishes it
          // by its zero running balance, never by a distinct type.
          final isFullPayment = entry.entryType == 'payment' &&
              entry.balanceAfter != null &&
              moneyToMilli(entry.balanceAfter!) == 0;
          final typeLabel = isFullPayment
              ? AppStrings.t('entry_type_full_payment', loc)
              : AppStrings.t('entry_type_${entry.entryType}', loc);
          final sign = entry.entryType == 'sale'
              ? '+'
              : entry.entryType == 'payment'
                  ? '-'
                  : '';
          final meta = <String>[
            if (entry.entryDate != null) _timestampOf(entry.entryDate),
            if (entry.balanceAfter != null)
              '${AppStrings.t('balance_after', loc)}: '
              '${formatMoney(entry.balanceAfter!)}',
            if (entry.invoiceNumber != null)
              '${AppStrings.t('invoice_number', loc)}: ${entry.invoiceNumber}',
            if (entry.userName != null) entry.userName!,
            if (entry.note != null && entry.note!.isNotEmpty) entry.note!,
          ].join(' · ');
          return ListTile(
            key: Key('client-hist-row-$index'),
            dense: true,
            leading: Icon(
              _iconFor(entry.entryType),
              color: _colorFor(context, entry.entryType),
            ),
            title: Text(
              '$typeLabel · $sign${formatMoney(entry.amount)}',
              key: Key('client-hist-amount-$index'),
            ),
            subtitle: meta.isEmpty
                ? null
                : Text(meta, key: Key('client-hist-meta-$index')),
          );
        },
      );
    }

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('debt_history', loc),
                key: const Key('client-hist-title'),
                style: theme.textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                key: const Key('client-hist-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () => ref
                    .read(debtHistoryProvider(customerId).notifier)
                    .refresh(),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: body),
          if (state.pages > 1) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('client-hist-prev'),
                  onPressed: state.page > 1 && !state.loading
                      ? () => ref
                          .read(debtHistoryProvider(customerId).notifier)
                          .setPage(state.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                Text(
                  '${state.page} / ${state.pages}',
                  key: const Key('client-hist-page'),
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  key: const Key('client-hist-next'),
                  onPressed: state.page < state.pages && !state.loading
                      ? () => ref
                          .read(debtHistoryProvider(customerId).notifier)
                          .setPage(state.page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
