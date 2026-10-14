// Audit Log screen (Slice B): who did what, when, on which PC, what
// changed, why — with the outcome.
//
// RBAC: `audit_view` to read (backend `require_permission` remains the
// security boundary; this gate only hides the chrome). Every filter the
// bar offers is a parameter the read API accepts — no client-side
// filtering — and the summary cards are the server's aggregates for the
// same filtered window, never inferred from the visible page. Legacy
// rows with a NULL outcome surface as an explicit "unknown".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import 'audit_detail_dialog.dart';
import 'audit_models.dart';
import 'audit_providers.dart';

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  final _searchController = TextEditingController();
  final _entityTypeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (the provider keeps its state alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(auditProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _entityTypeController.dispose();
    super.dispose();
  }

  AuditState get state => ref.read(auditProvider);

  Future<void> _pickDate({required bool from}) async {
    final notifier = ref.read(auditProvider.notifier);
    final current = from ? state.query.dateFrom : state.query.dateTo;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('audit_view'));

    if (!canView) {
      return Center(
        key: const Key('audit-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final audit = ref.watch(auditProvider);

    return Padding(
      key: const Key('audit-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('audit_log', loc),
                key: const Key('audit-title'),
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  AppStrings.t('audit_log_subtitle', loc),
                  key: const Key('audit-subtitle'),
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const Key('audit-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () => ref.read(auditProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SummaryCard(summary: audit.summary),
          const SizedBox(height: 16),
          _buildFilters(theme, loc, audit),
          const SizedBox(height: 8),
          Expanded(child: _buildList(theme, loc, audit)),
          if (audit.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('audit-prev'),
                  onPressed: audit.query.page > 1 && !audit.loading
                      ? () => ref
                          .read(auditProvider.notifier)
                          .setPage(audit.query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${audit.query.page} / ${audit.pages}',
                  key: const Key('audit-page'),
                ),
                IconButton(
                  key: const Key('audit-next'),
                  onPressed:
                      audit.query.page < audit.pages && !audit.loading
                          ? () => ref
                              .read(auditProvider.notifier)
                              .setPage(audit.query.page + 1)
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

  Widget _buildFilters(ThemeData theme, String loc, AuditState audit) {
    final notifier = ref.read(auditProvider.notifier);
    final query = audit.query;
    final hasFilters = query.search.isNotEmpty ||
        query.module.isNotEmpty ||
        query.action.isNotEmpty ||
        query.outcome.isNotEmpty ||
        query.entityType.isNotEmpty ||
        query.dateFrom != null ||
        query.dateTo != null;

    // Wrap (not Row) so the filter bar reflows instead of overflowing on
    // a narrow window or at a large text scale.
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 240,
          child: TextField(
            key: const Key('audit-search'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: AppStrings.t('audit_search_hint', loc),
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: const OutlineInputBorder(),
            ),
            inputFormatters: [LengthLimitingTextInputFormatter(200)],
            onSubmitted: (value) => notifier.setSearch(value),
          ),
        ),
        SizedBox(
          width: 180,
          child: DropdownButtonFormField<String>(
            key: const Key('audit-module-filter'),
            initialValue: query.module,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: AppStrings.t('audit_module', loc),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  AppStrings.t('all', loc),
                  key: const Key('audit-module-all'),
                ),
              ),
              for (final code in kAuditModules)
                DropdownMenuItem(
                  value: code,
                  child: Text(
                    AppStrings.t(auditModuleKey(code), loc),
                    key: Key('audit-module-$code'),
                  ),
                ),
            ],
            onChanged: (value) => notifier.setModule(value ?? ''),
          ),
        ),
        SizedBox(
          width: 180,
          child: DropdownButtonFormField<String>(
            key: const Key('audit-action-filter'),
            initialValue: query.action,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: AppStrings.t('audit_action', loc),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  AppStrings.t('all', loc),
                  key: const Key('audit-action-all'),
                ),
              ),
              for (final code in kAuditActions)
                DropdownMenuItem(
                  value: code,
                  child: Text(
                    AppStrings.t(auditActionKey(code), loc),
                    key: Key('audit-action-$code'),
                  ),
                ),
            ],
            onChanged: (value) => notifier.setAction(value ?? ''),
          ),
        ),
        SizedBox(
          width: 170,
          child: DropdownButtonFormField<String>(
            key: const Key('audit-outcome-filter'),
            initialValue: query.outcome,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: AppStrings.t('audit_outcome', loc),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  AppStrings.t('all', loc),
                  key: const Key('audit-outcome-all'),
                ),
              ),
              for (final code in kAuditOutcomes)
                DropdownMenuItem(
                  value: code,
                  child: Text(
                    AppStrings.t(auditOutcomeKey(code), loc),
                    key: Key('audit-outcome-$code'),
                  ),
                ),
            ],
            onChanged: (value) => notifier.setOutcome(value ?? ''),
          ),
        ),
        SizedBox(
          width: 170,
          child: TextField(
            key: const Key('audit-entity-type'),
            controller: _entityTypeController,
            decoration: InputDecoration(
              labelText: AppStrings.t('audit_entity_type', loc),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            inputFormatters: [LengthLimitingTextInputFormatter(50)],
            onSubmitted: (value) => notifier.setEntityType(value),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('audit_date_range', loc),
              key: const Key('audit-date-label'),
              style: theme.textTheme.bodySmall,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  key: const Key('audit-date-from'),
                  onPressed: () => _pickDate(from: true),
                  child: Text(
                    query.dateFrom == null
                        ? AppStrings.t('from', loc)
                        : auditDateParam(query.dateFrom!),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('audit-date-to'),
                  onPressed: () => _pickDate(from: false),
                  child: Text(
                    query.dateTo == null
                        ? AppStrings.t('to', loc)
                        : auditDateParam(query.dateTo!),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (hasFilters)
          IconButton(
            key: const Key('audit-clear'),
            tooltip: AppStrings.t('clear', loc),
            onPressed: () {
              _searchController.clear();
              _entityTypeController.clear();
              notifier.clearFilters();
            },
            icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
          ),
        Text(
          '${AppStrings.t('audit_count', loc)}: ${audit.total}',
          key: const Key('audit-total-count'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildList(ThemeData theme, String loc, AuditState audit) {
    if (audit.loading && audit.items.isEmpty) {
      return const Center(
        key: Key('audit-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (audit.error != null) {
      return Center(
        key: const Key('audit-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(audit.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('audit-retry'),
              onPressed: () => ref.read(auditProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (audit.items.isEmpty) {
      return Center(
        key: const Key('audit-empty'),
        child: Text(AppStrings.t('audit_empty', loc)),
      );
    }
    return ListView.builder(
      key: const Key('audit-list'),
      itemCount: audit.items.length,
      itemBuilder: (context, index) {
        final item = audit.items[index];
        final meta = <String>[
          item.occurredAt.toLocal().toString().substring(0, 16),
          item.actorLabel(loc),
          item.deviceLabel(loc),
          if (item.isUnverifiedClaim)
            AppStrings.t('audit_device_unverified', loc),
          if (item.entityRef != null && item.entityRef!.isNotEmpty)
            item.entityRef!,
          if ((item.reason ?? '').isNotEmpty) item.reason!,
        ];
        final outcomeColor = switch (item.outcome) {
          'success' => Colors.green,
          'failure' => Colors.red,
          'denied' => Colors.orange,
          _ => theme.disabledColor,
        };
        return ListTile(
          key: Key('audit-tile-$index'),
          leading: Tooltip(
            message: AppStrings.t(auditOutcomeKey(item.outcome), loc),
            child: CircleAvatar(
              radius: 8,
              backgroundColor: outcomeColor.withValues(alpha: 0.2),
              child: Icon(
                switch (item.outcome) {
                  'success' => Icons.check,
                  'failure' => Icons.close,
                  'denied' => Icons.block,
                  _ => Icons.help_outline,
                },
                size: 14,
                color: outcomeColor,
              ),
            ),
          ),
          title: Text(
            '${AppStrings.t(auditActionKey(item.action), loc)} · '
            '${AppStrings.t(auditModuleKey(item.module), loc)}',
            key: Key('audit-title-$index'),
          ),
          subtitle: Text(
            meta.join(' · '),
            key: Key('audit-meta-$index'),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => showAuditDetailDialog(context, eventId: item.id),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final AuditSummary? summary;

  const _SummaryCard({this.summary});

  @override
  Widget build(BuildContext context) {
    final data = summary;

    return Card(
      key: const Key('audit-summary'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 32,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _SummaryItem(
              labelKey: 'audit_summary_total',
              value: '${data?.total ?? 0}',
              testKey: 'audit-summary-total',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_success',
              value: '${data?.success ?? 0}',
              testKey: 'audit-summary-success',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_failure',
              value: '${data?.failure ?? 0}',
              testKey: 'audit-summary-failure',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_denied',
              value: '${data?.denied ?? 0}',
              testKey: 'audit-summary-denied',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_unknown',
              value: '${data?.unknown ?? 0}',
              testKey: 'audit-summary-unknown',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_users',
              value: '${data?.distinctUsers ?? 0}',
              testKey: 'audit-summary-users',
            ),
            _SummaryItem(
              labelKey: 'audit_summary_devices',
              value: '${data?.distinctDevices ?? 0}',
              testKey: 'audit-summary-devices',
            ),
          ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          AppStrings.t(labelKey, loc),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          value,
          key: Key(testKey),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
