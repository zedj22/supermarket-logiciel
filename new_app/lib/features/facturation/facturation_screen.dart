// Facturation screen (Phase 8): document history with doc-type /
// year / client / number-search filters. Tapping a row opens the
// detail dialog (historical lines, server totals, edit + PDF).
//
// RBAC: authenticated-only — facturation has no PermissionScope
// (backend precedent: /factures, invoice-clients, backups, print,
// settings all authenticate without a scope).
//
// Responsive: FacturationLayoutMode {wide ≥1200, medium ≥800, narrow}
// (purchases convention) — narrow renders compact tiles, medium and
// wide render table-like rows with progressively more columns.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../core/widgets/table_header.dart';
import '../../l10n/locale_provider.dart';
import 'facturation_format.dart';
import 'facturation_models.dart';
import 'facturation_pickers.dart';
import 'facturation_providers.dart';
import 'invoice_detail_dialog.dart';
import 'invoice_form_dialog.dart';

enum FacturationLayoutMode { wide, medium, narrow }

FacturationLayoutMode facturationLayoutModeFor(double width) {
  if (width >= 1200) return FacturationLayoutMode.wide;
  if (width >= 800) return FacturationLayoutMode.medium;
  return FacturationLayoutMode.narrow;
}

class FacturationScreen extends ConsumerStatefulWidget {
  const FacturationScreen({super.key});

  @override
  ConsumerState<FacturationScreen> createState() => _FacturationScreenState();
}

class _FacturationScreenState extends ConsumerState<FacturationScreen> {
  String? _filterClientName;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(facturationProvider.notifier).load();
    });
  }

  Future<void> _add() async {
    await showInvoiceFormDialog(context);
    if (!mounted) return;
    ref.read(facturationProvider.notifier).refresh();
  }

  Future<void> _pickClientFilter() async {
    final client = await showInvoiceClientPicker(context);
    if (client == null || !mounted) return;
    setState(() => _filterClientName = client.name);
    ref.read(facturationProvider.notifier).setClientFilter(client.id);
  }

  void _clearClientFilter() {
    setState(() => _filterClientName = null);
    ref.read(facturationProvider.notifier).setClientFilter(null);
  }

  Future<void> _openDetail(String documentId) async {
    await showInvoiceDetailDialog(context, documentId: documentId);
    if (!mounted) return;
    ref.read(facturationProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(facturationProvider);
    final query = state.query;
    final mode = facturationLayoutModeFor(MediaQuery.sizeOf(context).width);

    return Padding(
      key: const Key('facturation-screen'),
      padding: EdgeInsets.all(mode == FacturationLayoutMode.narrow ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                AppStrings.t('facturation', loc),
                key: const Key('facturation-title'),
                style: theme.textTheme.headlineSmall,
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  key: const Key('facturation-search'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(50)],
                  onChanged: (value) =>
                      ref.read(facturationProvider.notifier).setSearch(value),
                ),
              ),
              DropdownButtonFormField<String>(
                key: const Key('facturation-doctype-filter'),
                initialValue: query.docType,
                decoration: InputDecoration(
                  labelText: AppStrings.t('doc_type', loc),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text(AppStrings.t('all', loc)),
                  ),
                  for (final type in DocTypeValue.all)
                    DropdownMenuItem<String>(
                      value: type,
                      child: Text(
                        AppStrings.t('doc_type_${type.toLowerCase()}', loc),
                      ),
                    ),
                ],
                onChanged: (value) => ref
                    .read(facturationProvider.notifier)
                    .setDocType(value ?? ''),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  key: const Key('facturation-year-filter'),
                  decoration: InputDecoration(
                    labelText: AppStrings.t('year', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: query.year == null
                        ? null
                        : IconButton(
                            key: const Key('facturation-year-clear'),
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () => ref
                                .read(facturationProvider.notifier)
                                .setYear(null),
                          ),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  onSubmitted: (value) {
                    final year = int.tryParse(value.trim());
                    ref.read(facturationProvider.notifier).setYear(
                          year == null || value.trim().length != 4
                              ? null
                              : year,
                        );
                  },
                ),
              ),
              if (_filterClientName == null)
                OutlinedButton.icon(
                  key: const Key('facturation-client-filter'),
                  onPressed: _pickClientFilter,
                  icon: const Icon(Icons.person_outline, size: 18),
                  label: Text(AppStrings.t('select_invoice_client', loc)),
                )
              else
                Chip(
                  key: const Key('facturation-client-filter-chip'),
                  label: Text(_filterClientName!),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: _clearClientFilter,
                ),
              ElevatedButton.icon(
                key: const Key('facturation-add-button'),
                onPressed: _add,
                icon: const Icon(Icons.post_add_outlined),
                label: Text(AppStrings.t('new_document', loc)),
              ),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Material(
              key: const Key('facturation-error'),
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
                      key: const Key('facturation-retry'),
                      onPressed: () =>
                          ref.read(facturationProvider.notifier).refresh(),
                      child: Text(AppStrings.t('retry', loc)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '${AppStrings.t('total', loc)}: ${state.total}',
            key: const Key('facturation-total'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildList(theme, loc, state, mode)),
          if (state.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('facturation-prev'),
                  onPressed: query.page > 1 && !state.loading
                      ? () => ref
                          .read(facturationProvider.notifier)
                          .setPage(query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${query.page} / ${state.pages}',
                  key: const Key('facturation-page'),
                ),
                IconButton(
                  key: const Key('facturation-next'),
                  onPressed: query.page < state.pages && !state.loading
                      ? () => ref
                          .read(facturationProvider.notifier)
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

  Widget _buildList(
    ThemeData theme,
    String loc,
    FacturationState state,
    FacturationLayoutMode mode,
  ) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('facturation-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('facturation-empty'),
        child: Text(AppStrings.t('no_data', loc)),
      );
    }
    if (mode == FacturationLayoutMode.narrow) {
      return ListView.builder(
        key: const Key('facturation-list'),
        itemCount: state.items.length,
        itemBuilder: (context, index) {
          final doc = state.items[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              key: Key('facturation-tile-$index'),
              title: Text(doc.number, key: Key('facturation-number-$index')),
              subtitle: Text(
                [
                  AppStrings.t(
                    'doc_type_${doc.docType.toLowerCase()}',
                    loc,
                  ),
                  formatDisplayDate(doc.documentDate, loc),
                  if (doc.client != null) doc.client!.name,
                ].join(' · '),
                key: Key('facturation-subtitle-$index'),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _openDetail(doc.id),
            ),
          );
        },
      );
    }
    final wide = mode == FacturationLayoutMode.wide;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TableHeaderRow(
          testKey: const Key('facturation-table-header'),
          children: [
            tableHeaderCell(
              context,
              child: Text(AppStrings.t('invoice_number', loc)),
              numeric: false,
              flex: 14,
            ),
            tableHeaderCell(
              context,
              child: Text(AppStrings.t('doc_type', loc)),
              numeric: false,
              flex: 8,
            ),
            tableHeaderCell(
              context,
              child: Text(AppStrings.t('document_date', loc)),
              numeric: false,
              flex: 12,
            ),
            if (wide)
              tableHeaderCell(
                context,
                child: Text(AppStrings.t('invoice_client', loc)),
                numeric: false,
                flex: 16,
              ),
            tableHeaderCell(
              context,
              child: Text(AppStrings.t('payment_method', loc)),
              numeric: false,
              flex: 12,
            ),
            if (wide)
              tableHeaderCell(
                context,
                child: Text(AppStrings.t('note', loc)),
                numeric: false,
                flex: 18,
              ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            key: const Key('facturation-list'),
            itemCount: state.items.length,
            itemBuilder: (context, index) {
              final doc = state.items[index];
              return InkWell(
                key: Key('facturation-tile-$index'),
                onTap: () => _openDetail(doc.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 14,
                        child: Text(
                          doc.number,
                          key: Key('facturation-number-$index'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 8,
                        child: Text(
                          AppStrings.t(
                            'doc_type_${doc.docType.toLowerCase()}',
                            loc,
                          ),
                          key: Key('facturation-doctype-$index'),
                        ),
                      ),
                      Expanded(
                        flex: 12,
                        child: Text(
                          formatDisplayDate(doc.documentDate, loc),
                          key: Key('facturation-date-$index'),
                        ),
                      ),
                      if (wide)
                        Expanded(
                          flex: 16,
                          child: Text(
                            doc.client?.name ?? '',
                            key: Key('facturation-client-$index'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      Expanded(
                        flex: 12,
                        child: Text(
                          AppStrings.t(
                            'payment_${doc.paymentMethod}',
                            loc,
                          ),
                          key: Key('facturation-payment-$index'),
                        ),
                      ),
                      if (wide)
                        Expanded(
                          flex: 18,
                          child: Text(
                            doc.notes ?? '',
                            key: Key('facturation-notes-$index'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
