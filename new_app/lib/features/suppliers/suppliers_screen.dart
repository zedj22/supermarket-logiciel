// Suppliers screen (Phase 11): master/detail supplier management.
//
// Left pane — paginated supplier list with debounced search and a
// "show archived" toggle. Right pane — selected supplier detail,
// balance display, create/edit/archive actions (gated by
// supplier_manage), and the paginated supplier payables ledger with a
// payment action (supplier_manage, mirrors customer payments).
//
// RBAC: viewing requires supplier_view (whole screen); mutations are
// hidden without supplier_manage. Balance is display-only — it only
// moves with ledger entries (purchase receipt, cancellation, payment).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';
import 'supplier_form_dialog.dart';
import 'supplier_models.dart';
import 'suppliers_error.dart';
import 'suppliers_providers.dart';
import 'supplier_payment_dialog.dart';

String _timestampOf(DateTime? value) {
  if (value == null) return '';
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final h = value.hour.toString().padLeft(2, '0');
  final min = value.minute.toString().padLeft(2, '0');
  final s = value.second.toString().padLeft(2, '0');
  return '${value.year}-$m-$d $h:$min:$s';
}

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (provider state itself is kept alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(suppliersProvider.notifier).load();
    });
  }

  void _select(String id) => setState(() => _selectedId = id);

  void _clearSelection() => setState(() => _selectedId = null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('supplier_view'));
    final canManage = ref.watch(hasPermissionProvider('supplier_manage'));

    if (!canView) {
      return Center(
        key: const Key('suppliers-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final state = ref.watch(suppliersProvider);
    final query = state.query;

    return Padding(
      key: const Key('suppliers-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wide windows keep the original single-row header (measured
          // one-line width ≈ 1031px in Arabic); tighter windows let the
          // title, search, chip and add button wrap instead of
          // overflowing ("RenderFlex overflowed by 359 pixels").
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Text(
                AppStrings.t('suppliers', loc),
                key: const Key('suppliers-title'),
                style: theme.textTheme.headlineSmall,
              );
              final searchField = SizedBox(
                width: 260,
                child: TextField(
                  key: const Key('suppliers-search'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  onChanged: (value) =>
                      ref.read(suppliersProvider.notifier).setSearch(value),
                ),
              );
              final archivedToggle = FilterChip(
                key: const Key('suppliers-archived-toggle'),
                label: Text(AppStrings.t('show_archived', loc)),
                selected: query.includeArchived,
                onSelected: (value) => ref
                    .read(suppliersProvider.notifier)
                    .setIncludeArchived(value),
              );
              final addButton = canManage
                  ? ElevatedButton.icon(
                      key: const Key('suppliers-add-button'),
                      onPressed: () => showSupplierFormDialog(context),
                      icon: const Icon(Icons.person_add_alt),
                      label: Text(AppStrings.t('add_supplier', loc)),
                    )
                  : null;

              if (constraints.maxWidth >= 1070) {
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
              key: const Key('suppliers-error'),
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
                      key: const Key('suppliers-retry'),
                      onPressed: () =>
                          ref.read(suppliersProvider.notifier).refresh(),
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
                        key: const Key('suppliers-total'),
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
                              key: const Key('suppliers-prev'),
                              onPressed: query.page > 1 && !state.loading
                                  ? () => ref
                                      .read(suppliersProvider.notifier)
                                      .setPage(query.page - 1)
                                  : null,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Text(
                              '${query.page} / ${state.pages}',
                              key: const Key('suppliers-page'),
                            ),
                            IconButton(
                              key: const Key('suppliers-next'),
                              onPressed:
                                  query.page < state.pages && !state.loading
                                      ? () => ref
                                          .read(suppliersProvider.notifier)
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
                          key: const Key('suppliers-detail-empty'),
                          child: Text(AppStrings.t('select_supplier_hint', loc)),
                        )
                      : _SupplierDetailPane(
                          supplierId: _selectedId!,
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

  Widget _buildList(ThemeData theme, String loc, SuppliersState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('suppliers-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('suppliers-empty'),
        child: Text(AppStrings.t('no_data', loc)),
      );
    }
    return ListView.builder(
      key: const Key('suppliers-list'),
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final supplier = state.items[index];
        return ListTile(
          key: Key('supplier-tile-$index'),
          selected: _selectedId == supplier.id,
          onTap: () => _select(supplier.id),
          title: Text(supplier.name, key: Key('supplier-name-$index')),
          subtitle: Text(
            [
              if (supplier.phone != null && supplier.phone!.isNotEmpty)
                supplier.phone!,
              if (supplier.contactPerson != null &&
                  supplier.contactPerson!.isNotEmpty)
                supplier.contactPerson!,
            ].join(' · '),
            key: Key('supplier-subtitle-$index'),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMoney(supplier.balance),
                key: Key('supplier-balance-$index'),
                style: theme.textTheme.titleMedium,
              ),
              if (supplier.isArchived)
                Text(
                  AppStrings.t('archived', loc),
                  key: Key('supplier-archived-$index'),
                  style: theme.textTheme.bodySmall,
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

class _SupplierDetailPane extends ConsumerStatefulWidget {
  final String supplierId;
  final bool canManage;
  final VoidCallback onSelectionCleared;

  const _SupplierDetailPane({
    required this.supplierId,
    required this.canManage,
    required this.onSelectionCleared,
  });

  @override
  ConsumerState<_SupplierDetailPane> createState() =>
      _SupplierDetailPaneState();
}

class _SupplierDetailPaneState extends ConsumerState<_SupplierDetailPane> {
  @override
  void initState() {
    super.initState();
    // QA fix round (Bug 1/3): the detail + ledger providers are cached per
    // supplier id, so a (re)opened pane must re-read the server — otherwise
    // a payable or ledger entry created since the first open keeps showing
    // the stale snapshot (balance 0 / "No ledger entries").
    Future.microtask(_refreshFromServer);
  }

  @override
  void didUpdateWidget(covariant _SupplierDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.supplierId != widget.supplierId) {
      // Reused State for a different supplier — re-read that id too.
      Future.microtask(_refreshFromServer);
    }
  }

  /// Silent refresh of detail + ledger. Skipped while a first-ever load
  /// is in flight to avoid a duplicate GET on the initial open. The master
  /// list keeps its own refresh in the screen's initState.
  Future<void> _refreshFromServer() async {
    if (!mounted) return;
    final detail = ref.read(supplierDetailProvider(widget.supplierId));
    if (!detail.isLoading) {
      ref
          .read(supplierDetailProvider(widget.supplierId).notifier)
          .load(silent: true);
    }
    final ledger = ref.read(supplierLedgerProvider(widget.supplierId));
    if (!ledger.loading) {
      ref.read(supplierLedgerProvider(widget.supplierId).notifier).refresh();
    }
  }

  Future<void> _reloadAll() async {
    ref.read(supplierDetailProvider(widget.supplierId).notifier).load();
    ref.read(supplierLedgerProvider(widget.supplierId).notifier).refresh();
    ref.read(suppliersProvider.notifier).refresh();
  }

  Future<void> _pay(SupplierModel supplier) async {
    final result = await showSupplierPaymentDialog(
      context,
      supplier: supplier,
    );
    if (result == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('supplier_payment_success', loc),
      detail: formatMoney(result.amount),
      kind: PosToastKind.success,
      key: const Key('supplier-payment-success-toast'),
    );
    await _reloadAll();
  }

  Future<void> _edit(SupplierModel supplier) async {
    await showSupplierFormDialog(context, supplier: supplier);
    if (!mounted) return;
    await _reloadAll();
  }

  Future<void> _archive(SupplierModel supplier) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('supplier-archive-confirm'),
        title: Text(AppStrings.t('archive_supplier_confirm', loc)),
        actions: [
          TextButton(
            key: const Key('supplier-archive-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('supplier-archive-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('archive', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error = await ref
        .read(suppliersProvider.notifier)
        .archiveSupplier(widget.supplierId);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('supplier_archived', loc),
        kind: PosToastKind.success,
        key: const Key('supplier-archive-success-toast'),
      );
      widget.onSelectionCleared();
      ref.read(suppliersProvider.notifier).refresh();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('supplier-archive-error-toast'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final detail = ref.watch(supplierDetailProvider(widget.supplierId));

    return detail.when(
      loading: () => const Center(
        key: Key('supplier-detail-loading'),
        child: CircularProgressIndicator(),
      ),
      error: (error, _) => Center(
        key: const Key('supplier-detail-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(suppliersApiMessage(error, loc)),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const Key('supplier-detail-retry'),
              onPressed: () => ref
                  .read(supplierDetailProvider(widget.supplierId).notifier)
                  .load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      ),
      data: (supplier) {
        if (supplier == null) {
          return Center(
            key: const Key('supplier-detail-missing'),
            child: Text(AppStrings.t('supplier_not_found', loc)),
          );
        }
        final balanceMilli = moneyToMilli(supplier.balance) ?? 0;

        return Padding(
          key: const Key('supplier-detail'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      supplier.name,
                      key: const Key('supplier-detail-name'),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (supplier.isArchived)
                    Chip(
                      key: const Key('supplier-detail-archived'),
                      label: Text(AppStrings.t('archived', loc)),
                    ),
                ],
              ),
              if (supplier.phone != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    supplier.phone!,
                    key: const Key('supplier-detail-phone'),
                  ),
                ),
              if (supplier.address != null)
                Text(
                  supplier.address!,
                  key: const Key('supplier-detail-address'),
                ),
              if (supplier.email != null && supplier.email!.isNotEmpty)
                Text(
                  supplier.email!,
                  key: const Key('supplier-detail-email'),
                ),
              if (supplier.contactPerson != null &&
                  supplier.contactPerson!.isNotEmpty)
                Text(
                  '${AppStrings.t('contact_person', loc)}: '
                  '${supplier.contactPerson}',
                  key: const Key('supplier-detail-contact'),
                ),
              if (supplier.notes != null && supplier.notes!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    supplier.notes!,
                    key: const Key('supplier-detail-notes'),
                  ),
                ),
              const SizedBox(height: 16),
              Card(
                key: const Key('supplier-balance-card'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${AppStrings.t('balance', loc)}: '
                        '${formatMoney(supplier.balance)}',
                        key: const Key('supplier-detail-balance'),
                        style: theme.textTheme.headlineSmall,
                      ),
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
                      key: const Key('supplier-pay-button'),
                      onPressed: balanceMilli > 0 && !supplier.isArchived
                          ? () => _pay(supplier)
                          : null,
                      icon: const Icon(Icons.payments_outlined),
                      label: Text(
                        AppStrings.t('record_supplier_payment', loc),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('supplier-edit-button'),
                      onPressed: supplier.isArchived
                          ? null
                          : () => _edit(supplier),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(AppStrings.t('edit', loc)),
                    ),
                    OutlinedButton.icon(
                      key: const Key('supplier-archive-button'),
                      onPressed: supplier.isArchived
                          ? null
                          : () => _archive(supplier),
                      icon: const Icon(Icons.archive_outlined),
                      label: Text(AppStrings.t('archive', loc)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              _SupplierLedgerSection(supplierId: widget.supplierId),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Payables ledger section
// ---------------------------------------------------------------------------

class _SupplierLedgerSection extends ConsumerWidget {
  final String supplierId;

  const _SupplierLedgerSection({required this.supplierId});

  IconData _iconFor(String entryType) {
    switch (entryType) {
      case 'purchase':
        return Icons.trending_up;
      case 'payment':
        return Icons.trending_down;
      default:
        return Icons.undo;
    }
  }

  Color _colorFor(BuildContext context, String entryType) {
    final scheme = Theme.of(context).colorScheme;
    switch (entryType) {
      case 'purchase':
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
    final state = ref.watch(supplierLedgerProvider(supplierId));

    final Widget body;
    if (state.loading && state.items.isEmpty) {
      body = const Center(
        key: Key('supplier-ledger-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (state.error != null) {
      body = Center(
        key: const Key('supplier-ledger-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('supplier-ledger-retry'),
              onPressed: () => ref
                  .read(supplierLedgerProvider(supplierId).notifier)
                  .refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    } else if (state.items.isEmpty) {
      body = Center(
        key: const Key('supplier-ledger-empty'),
        child: Text(AppStrings.t('no_ledger_entries', loc)),
      );
    } else {
      body = ListView.builder(
        key: const Key('supplier-ledger-list'),
        itemCount: state.items.length,
        itemBuilder: (context, index) {
          final entry = state.items[index];
          final typeLabel =
              AppStrings.t('supplier_entry_type_${entry.entryType}', loc);
          final sign = entry.entryType == 'purchase' ? '+' : '-';
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
            key: Key('supplier-ledger-row-$index'),
            dense: true,
            leading: Icon(
              _iconFor(entry.entryType),
              color: _colorFor(context, entry.entryType),
            ),
            title: Text(
              '$typeLabel · $sign${formatMoney(entry.amount)}',
              key: Key('supplier-ledger-amount-$index'),
            ),
            subtitle: meta.isEmpty
                ? null
                : Text(meta, key: Key('supplier-ledger-meta-$index')),
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
                AppStrings.t('supplier_ledger', loc),
                key: const Key('supplier-ledger-title'),
                style: theme.textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                key: const Key('supplier-ledger-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () => ref
                    .read(supplierLedgerProvider(supplierId).notifier)
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
                  key: const Key('supplier-ledger-prev'),
                  onPressed: state.page > 1 && !state.loading
                      ? () => ref
                          .read(supplierLedgerProvider(supplierId).notifier)
                          .setPage(state.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                Text(
                  '${state.page} / ${state.pages}',
                  key: const Key('supplier-ledger-page'),
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  key: const Key('supplier-ledger-next'),
                  onPressed: state.page < state.pages && !state.loading
                      ? () => ref
                          .read(supplierLedgerProvider(supplierId).notifier)
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
