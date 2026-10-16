// Expenses screen (Phase 13): filtered + paginated money-out ledger with
// its live summary, the "Add expense" entry point and the terminal
// cancellation action.
//
// RBAC: `expense_view` to read, `expense_create` to add, `expense_cancel`
// to cancel (GATE 7/8/9 — admin, manager and cashier all hold them).
// Money is displayed exactly as the server computed it; cancelled rows are
// hidden by default and keep their amount forever (never deleted).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../core/widgets/adaptive_title_row.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/customer_models.dart';
import '../pos/pos_toast.dart';
import 'expense_cancel_dialog.dart';
import 'expense_form_dialog.dart';
import 'expense_models.dart';
import 'expenses_providers.dart';

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (the provider keeps its state alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(expensesProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addExpense() async {
    final expense = await showExpenseFormDialog(context);
    if (expense == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t(
        expense.idempotentReplay ? 'expense_replay' : 'expense_saved',
        loc,
      ),
      detail: expense.title,
      kind: PosToastKind.success,
      key: const Key('expenses-toast'),
    );
    ref.read(expensesProvider.notifier).refresh();
  }

  Future<void> _cancelExpense(ExpenseItem expense) async {
    final cancelled = await showExpenseCancelDialog(context, expense: expense);
    if (cancelled == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('expense_cancelled_success', loc),
      detail: cancelled.title,
      kind: PosToastKind.success,
      key: const Key('expenses-cancel-toast'),
    );
    ref.read(expensesProvider.notifier).refresh();
  }

  Future<void> _pickDate({required bool from}) async {
    final notifier = ref.read(expensesProvider.notifier);
    final current = from
        ? state.query.dateFrom
        : state.query.dateTo;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    if (from) {
      notifier.setDateFrom(picked);
    } else {
      notifier.setDateTo(picked);
    }
  }

  ExpensesState get state => ref.read(expensesProvider);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('expense_view'));
    final canCreate = ref.watch(hasPermissionProvider('expense_create'));
    final canCancel = ref.watch(hasPermissionProvider('expense_cancel'));

    if (!canView) {
      return Center(
        key: const Key('expenses-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final expenses = ref.watch(expensesProvider);

    return Padding(
      key: const Key('expenses-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveTitleRow(
            title: Text(
              AppStrings.t('expenses', loc),
              key: const Key('expenses-title'),
              style: theme.textTheme.headlineSmall,
            ),
            subtitle: Text(
              AppStrings.t('expenses_subtitle', loc),
              key: const Key('expenses-subtitle'),
              style: theme.textTheme.bodyMedium,
            ),
            actions: [
              if (canCreate)
                OutlinedButton.icon(
                  key: const Key('expenses-add'),
                  onPressed: _addExpense,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(AppStrings.t('expense_add', loc)),
                ),
              IconButton(
                key: const Key('expenses-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () =>
                    ref.read(expensesProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SummaryCard(summary: expenses.summary),
          const SizedBox(height: 16),
          _buildFilters(theme, loc, expenses),
          const SizedBox(height: 8),
          Expanded(child: _buildList(theme, loc, expenses, canCancel)),
          if (expenses.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('expenses-prev'),
                  onPressed: expenses.query.page > 1 && !expenses.loading
                      ? () => ref
                          .read(expensesProvider.notifier)
                          .setPage(expenses.query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${expenses.query.page} / ${expenses.pages}',
                  key: const Key('expenses-page'),
                ),
                IconButton(
                  key: const Key('expenses-next'),
                  onPressed:
                      expenses.query.page < expenses.pages && !expenses.loading
                          ? () => ref
                              .read(expensesProvider.notifier)
                              .setPage(expenses.query.page + 1)
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

  Widget _buildFilters(ThemeData theme, String loc, ExpensesState expenses) {
    final notifier = ref.read(expensesProvider.notifier);
    final query = expenses.query;
    final hasFilters = query.search.isNotEmpty ||
        query.category.isNotEmpty ||
        query.paidFromDrawer != null ||
        query.dateFrom != null ||
        query.dateTo != null;

    final searchField = SizedBox(
      width: 260,
      child: TextField(
        key: const Key('expenses-search'),
        controller: _searchController,
        decoration: InputDecoration(
          hintText: AppStrings.t('expense_search_hint', loc),
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          border: const OutlineInputBorder(),
        ),
        inputFormatters: [LengthLimitingTextInputFormatter(200)],
        onSubmitted: (value) => notifier.setSearch(value),
      ),
    );
    final categoryFilter = SizedBox(
      width: 200,
      child: DropdownButtonFormField<String>(
        key: const Key('expenses-category-filter'),
        initialValue: query.category,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('category', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(
              AppStrings.t('expense_filter_all_categories', loc),
              key: const Key('expenses-category-all'),
            ),
          ),
          for (final code in kExpenseCategories)
            DropdownMenuItem(
              value: code,
              child: Text(
                AppStrings.t(expenseCategoryKey(code), loc),
                key: Key('expenses-category-$code'),
              ),
            ),
        ],
        onChanged: (value) => notifier.setCategory(value ?? ''),
      ),
    );
    final paymentFilter = SizedBox(
      width: 200,
      child: DropdownButtonFormField<String>(
        key: const Key('expenses-payment-filter'),
        initialValue: query.paidFromDrawer == null
            ? ''
            : (query.paidFromDrawer! ? 'true' : 'false'),
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('expense_filter_payment', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(
              AppStrings.t('all', loc),
              key: const Key('expenses-payment-all'),
            ),
          ),
          DropdownMenuItem(
            value: 'true',
            child: Text(
              AppStrings.t('expense_paid_from_drawer', loc),
              key: const Key('expenses-payment-drawer'),
            ),
          ),
          DropdownMenuItem(
            value: 'false',
            child: Text(
              AppStrings.t('expense_paid_external', loc),
              key: const Key('expenses-payment-external'),
            ),
          ),
        ],
        onChanged: (value) => notifier.setPaidFromDrawer(
          value == null || value.isEmpty ? null : (value == 'true'),
        ),
      ),
    );
    final statusFilter = SizedBox(
      width: 170,
      child: DropdownButtonFormField<String>(
        key: const Key('expenses-status-filter'),
        initialValue: query.status,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('status', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: 'posted',
            child: Text(
              AppStrings.t('expense_status_posted', loc),
              key: const Key('expenses-status-posted'),
            ),
          ),
          DropdownMenuItem(
            value: 'cancelled',
            child: Text(
              AppStrings.t('expense_status_cancelled', loc),
              key: const Key('expenses-status-cancelled'),
            ),
          ),
          DropdownMenuItem(
            value: 'all',
            child: Text(
              AppStrings.t('all', loc),
              key: const Key('expenses-status-all'),
            ),
          ),
        ],
        onChanged: (value) => notifier.setStatus(value ?? 'posted'),
      ),
    );
    final dateRange = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.t('expense_date_range', loc),
          key: const Key('expenses-date-label'),
          style: theme.textTheme.bodySmall,
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              key: const Key('expenses-date-from'),
              onPressed: () => _pickDate(from: true),
              child: Text(
                query.dateFrom == null
                    ? AppStrings.t('from', loc)
                    : expenseDateParam(query.dateFrom!),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('expenses-date-to'),
              onPressed: () => _pickDate(from: false),
              child: Text(
                query.dateTo == null
                    ? AppStrings.t('to', loc)
                    : expenseDateParam(query.dateTo!),
              ),
            ),
          ],
        ),
      ],
    );
    final clearButton = IconButton(
      key: const Key('expenses-clear'),
      tooltip: AppStrings.t('clear', loc),
      onPressed: () {
        _searchController.clear();
        notifier.clearFilters();
      },
      icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
    );
    final countText = Text(
      '${AppStrings.t('expense_count', loc)}: ${expenses.total}',
      key: const Key('expenses-total-count'),
      style: theme.textTheme.bodySmall,
    );

    // Wide windows keep the original single-row bar (filters left, count
    // pinned right); tighter windows let the same controls wrap onto
    // extra rows instead of overflowing (human QA: "RenderFlex overflowed
    // by 365 pixels" on the expenses filter row).
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1340) {
          return Row(
            children: [
              searchField,
              const SizedBox(width: 12),
              categoryFilter,
              const SizedBox(width: 12),
              paymentFilter,
              const SizedBox(width: 12),
              statusFilter,
              const SizedBox(width: 12),
              dateRange,
              const SizedBox(width: 8),
              if (hasFilters) clearButton,
              const Spacer(),
              countText,
            ],
          );
        }
        return Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            searchField,
            categoryFilter,
            paymentFilter,
            statusFilter,
            dateRange,
            if (hasFilters) clearButton,
            countText,
          ],
        );
      },
    );
  }

  Widget _buildList(
    ThemeData theme,
    String loc,
    ExpensesState expenses,
    bool canCancel,
  ) {
    if (expenses.loading && expenses.items.isEmpty) {
      return const Center(
        key: Key('expenses-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (expenses.error != null) {
      return Center(
        key: const Key('expenses-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(expenses.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('expenses-retry'),
              onPressed: () => ref.read(expensesProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (expenses.items.isEmpty) {
      return Center(
        key: const Key('expenses-empty'),
        child: Text(AppStrings.t('expense_empty', loc)),
      );
    }
    return ListView.builder(
      key: const Key('expenses-list'),
      itemCount: expenses.items.length,
      itemBuilder: (context, index) {
        final item = expenses.items[index];
        final meta = <String>[
          AppStrings.t(expenseCategoryKey(item.category), loc),
          // Isolated: the date/time pair stays one LTR unit in the RTL
          // subtitle (its two numeric groups would otherwise swap next
          // to the Arabic category label).
          bidiIsolateLtr(item.expenseDate.toLocal().toString().substring(0, 16)),
          AppStrings.t(expenseStatusKey(item.status), loc),
          if (item.isCancelled && (item.cancelReason ?? '').isNotEmpty)
            item.cancelReason!,
        ];
        return ListTile(
          key: Key('expense-tile-$index'),
          title: Text(expenseTitleLabel(item, loc), key: Key('expense-title-$index')),
          subtitle: Text(
            meta.join(' · '),
            key: Key('expense-meta-$index'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              numericText(
                formatMoney(item.amount),
                key: Key('expense-amount-$index'),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: item.isCancelled ? theme.disabledColor : null,
                  decoration: item.isCancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              if (!item.isCancelled && canCancel) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: Key('expense-cancel-$index'),
                  tooltip: AppStrings.t('expense_cancel_action', loc),
                  icon: const Icon(Icons.block, size: 18),
                  onPressed: () => _cancelExpense(item),
                ),
              ],
            ],
          ),
          onTap: (!item.isCancelled && canCancel)
              ? () => _cancelExpense(item)
              : null,
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final ExpenseSummary? summary;

  const _SummaryCard({this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final data = summary;

    return Card(
      key: const Key('expenses-summary'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // Wide windows keep the single-row summary; tighter windows let
        // the items wrap instead of overflowing ("RenderFlex overflowed
        // by 115 pixels" at an 800px window).
        child: LayoutBuilder(
          builder: (context, constraints) {
            final items = [
              _SummaryItem(
                labelKey: 'expense_count',
                value: '${data?.count ?? 0}',
                testKey: 'expenses-summary-count',
              ),
              _SummaryItem(
                labelKey: 'expense_total',
                value: formatMoney(data?.totalAmount ?? '0'),
                testKey: 'expenses-summary-total',
              ),
              _SummaryItem(
                labelKey: 'expense_total_drawer',
                value: formatMoney(data?.drawerAmount ?? '0'),
                testKey: 'expenses-summary-drawer',
              ),
              _SummaryItem(
                labelKey: 'expense_total_external',
                value: formatMoney(data?.externalAmount ?? '0'),
                testKey: 'expenses-summary-external',
              ),
            ];
            final currency = Text(
              AppStrings.t('currency', loc),
              key: const Key('expenses-summary-currency'),
              style: theme.textTheme.bodySmall,
            );
            if (constraints.maxWidth >= 840) {
              return Row(
                children: [
                  ...items,
                  const Spacer(),
                  currency,
                ],
              );
            }
            return Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...items, currency],
            );
          },
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String labelKey;
  final String value;
  final String testKey;

  const _SummaryItem({
    required this.labelKey,
    required this.value,
    required this.testKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppStrings.t(labelKey, loc),
            style: theme.textTheme.bodySmall,
          ),
          numericText(
            value,
            key: Key(testKey),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
