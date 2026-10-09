// Invoice (fiscal) clients screen (Phase 8): master-data CRUD list.
//
// Invoice clients are the fiscal document identity — a SEPARATE
// domain from the POS Customer (this screen never touches the
// customers table). Left pane — paginated list with debounced search
// and a "show archived" toggle. Actions: create / edit / archive
// (authenticated-only; facturation has no PermissionScope).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../facturation/facturation_models.dart';
import '../pos/pos_toast.dart';
import 'invoice_client_form_dialog.dart';
import 'invoice_clients_providers.dart';

class InvoiceClientsScreen extends ConsumerStatefulWidget {
  const InvoiceClientsScreen({super.key});

  @override
  ConsumerState<InvoiceClientsScreen> createState() =>
      _InvoiceClientsScreenState();
}

class _InvoiceClientsScreenState extends ConsumerState<InvoiceClientsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(invoiceClientsProvider.notifier).load();
    });
  }

  Future<void> _add() async {
    await showInvoiceClientFormDialog(context);
    if (!mounted) return;
    ref.read(invoiceClientsProvider.notifier).refresh();
  }

  Future<void> _edit(InvoiceClientModel client) async {
    await showInvoiceClientFormDialog(context, client: client);
    if (!mounted) return;
    ref.read(invoiceClientsProvider.notifier).refresh();
  }

  Future<void> _archive(InvoiceClientModel client) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('invoice-client-archive-confirm'),
        title: Text(AppStrings.t('archive_invoice_client_confirm', loc)),
        content: Text(client.name),
        actions: [
          TextButton(
            key: const Key('invoice-client-archive-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('invoice-client-archive-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('archive', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error = await ref
        .read(invoiceClientsProvider.notifier)
        .archiveClient(client.id);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('invoice_client_archived', loc),
        kind: PosToastKind.success,
        key: const Key('invoice-client-archive-success-toast'),
      );
      ref.read(invoiceClientsProvider.notifier).refresh();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('invoice-client-archive-error-toast'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(invoiceClientsProvider);
    final query = state.query;

    return Padding(
      key: const Key('invoice-clients-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('invoice_clients', loc),
                key: const Key('invoice-clients-title'),
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: 260,
                child: TextField(
                  key: const Key('invoice-clients-search'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  onChanged: (value) =>
                      ref.read(invoiceClientsProvider.notifier).setSearch(value),
                ),
              ),
              const SizedBox(width: 16),
              FilterChip(
                key: const Key('invoice-clients-archived-toggle'),
                label: Text(AppStrings.t('show_archived', loc)),
                selected: query.includeArchived,
                onSelected: (value) => ref
                    .read(invoiceClientsProvider.notifier)
                    .setIncludeArchived(value),
              ),
              const Spacer(),
              ElevatedButton.icon(
                key: const Key('invoice-clients-add-button'),
                onPressed: _add,
                icon: const Icon(Icons.person_add_alt),
                label: Text(AppStrings.t('add_invoice_client', loc)),
              ),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Material(
              key: const Key('invoice-clients-error'),
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
                      key: const Key('invoice-clients-retry'),
                      onPressed: () =>
                          ref.read(invoiceClientsProvider.notifier).refresh(),
                      child: Text(AppStrings.t('retry', loc)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '${AppStrings.t('total', loc)}: ${state.total}',
            key: const Key('invoice-clients-total'),
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
                  key: const Key('invoice-clients-prev'),
                  onPressed: query.page > 1 && !state.loading
                      ? () => ref
                          .read(invoiceClientsProvider.notifier)
                          .setPage(query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${query.page} / ${state.pages}',
                  key: const Key('invoice-clients-page'),
                ),
                IconButton(
                  key: const Key('invoice-clients-next'),
                  onPressed: query.page < state.pages && !state.loading
                      ? () => ref
                          .read(invoiceClientsProvider.notifier)
                          .setPage(query.page + 1)
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

  Widget _buildList(ThemeData theme, String loc, InvoiceClientsState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('invoice-clients-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('invoice-clients-empty'),
        child: Text(AppStrings.t('no_data', loc)),
      );
    }
    return ListView.builder(
      key: const Key('invoice-clients-list'),
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final client = state.items[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 4),
          child: ListTile(
            key: Key('invoice-client-tile-$index'),
            title: Text(client.name, key: Key('invoice-client-name-$index')),
            subtitle: Text(
              [
                if (client.phone != null && client.phone!.isNotEmpty)
                  client.phone!,
                if (client.wilaya != null && client.wilaya!.isNotEmpty)
                  client.wilaya!,
                if (client.nif != null && client.nif!.isNotEmpty)
                  'NIF: ${client.nif}',
                if (client.isArchived) AppStrings.t('archived', loc),
              ].join(' · '),
              key: Key('invoice-client-subtitle-$index'),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('invoice-client-edit-$index'),
                  tooltip: AppStrings.t('edit', loc),
                  onPressed: () => _edit(client),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                if (!client.isArchived)
                  IconButton(
                    key: Key('invoice-client-archive-$index'),
                    tooltip: AppStrings.t('archive', loc),
                    onPressed: () => _archive(client),
                    icon: const Icon(Icons.archive_outlined, size: 20),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
