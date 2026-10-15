// Storage & Data Usage page — reachable from Settings (admin only).
//
// Layout: one summary (total measured, marked *partial* whenever any
// category or scope is unavailable), then two clearly separated cards:
// "This computer" (measured locally, off the UI thread) and "Server"
// (measured by the backend on the machine that runs PostgreSQL and
// stores backups).  Every size is pinned LTR so digits read the same in
// Arabic, French and English, and every unavailable category shows its
// reason instead of a made-up number.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../settings/settings_provider.dart';
import 'storage_models.dart';
import 'storage_provider.dart';

/// Admin-only storage page (`settings_manage` gates both this screen and
/// `GET /api/v1/storage`).
class StorageUsageScreen extends ConsumerStatefulWidget {
  const StorageUsageScreen({super.key});

  @override
  ConsumerState<StorageUsageScreen> createState() =>
      _StorageUsageScreenState();
}

class _StorageUsageScreenState extends ConsumerState<StorageUsageScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred: the provider must not be read during build.
    Future.microtask(_loadIfNeeded);
  }

  void _loadIfNeeded() {
    if (!mounted) return;
    // Never issue a measurement (local walk or API request) for a user
    // without `settings_manage` — the backend would reject it anyway.
    if (!ref.read(hasPermissionProvider(settingsManageScope))) return;
    if (ref.read(storageProvider).status == StorageStatus.idle) {
      ref.read(storageProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canManage = ref.watch(hasPermissionProvider(settingsManageScope));

    if (!canManage) return _DeniedView(loc: loc);

    final state = ref.watch(storageProvider);
    final runMode = ref.watch(storageRunModeProvider).valueOrNull;

    return SingleChildScrollView(
      key: const Key('storage-screen'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 32, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(theme, loc, state),
                const SizedBox(height: 16),
                if (state.hasError)
                  _errorCard(theme, loc)
                else if (!state.hasData) ...[
                  _loadingCard(theme, loc),
                ] else ...[
                  if (state.local != null)
                    _summaryCard(theme, loc, state),
                  if (state.local != null) ...[
                    const SizedBox(height: 16),
                    _sectionCard(
                      theme: theme,
                      loc: loc,
                      scope: storageScopeLocal,
                      titleKey: 'storage_this_pc',
                      section: state.local,
                      errorKey: state.localErrorKey,
                      isBusy: state.isBusy,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _sectionCard(
                    theme: theme,
                    loc: loc,
                    scope: storageScopeServer,
                    titleKey: 'storage_server',
                    section: state.server,
                    errorKey: state.serverErrorKey,
                    isBusy: state.isBusy,
                    noteKey: runMode == 'server'
                        ? 'storage_server_on_this_pc'
                        : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -- header -------------------------------------------------------------

  Widget _header(ThemeData theme, String loc, StorageState state) {
    return Row(
      children: [
        Expanded(
          child: Text(
            AppStrings.t('storage_usage', loc),
            style: theme.textTheme.headlineSmall,
          ),
        ),
        FilledButton.icon(
          key: const Key('storage-refresh'),
          onPressed: state.isBusy
              ? null
              : () => ref.read(storageProvider.notifier).refresh(),
          icon: state.isBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    key: Key('storage-refresh-spinner'),
                  ),
                )
              : const Icon(Icons.refresh),
          label: Text(AppStrings.t('refresh', loc)),
        ),
      ],
    );
  }

  // -- full-page states ---------------------------------------------------

  Widget _loadingCard(ThemeData theme, String loc) {
    return Card(
      key: const Key('storage-loading-card'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  key: Key('storage-loading'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.t('storage_measuring', loc),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorCard(ThemeData theme, String loc) {
    return Card(
      key: const Key('storage-error-card'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 8),
              Text(
                AppStrings.t('storage_load_failed', loc),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('storage-retry'),
                onPressed: () =>
                    ref.read(storageProvider.notifier).refresh(),
                child: Text(AppStrings.t('retry', loc)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -- summary ------------------------------------------------------------

  Widget _summaryCard(ThemeData theme, String loc, StorageState state) {
    return Card(
      key: const Key('storage-summary-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('storage_total_measured', loc),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                formatBytes(state.totalBytes),
                key: const Key('storage-total-value'),
                style: theme.textTheme.headlineMedium,
              ),
            ),
            if (!state.overallComplete) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('storage-partial-chip'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        AppStrings.t('storage_partial', loc),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // -- one scope card -----------------------------------------------------

  Widget _sectionCard({
    required ThemeData theme,
    required String loc,
    required String scope,
    required String titleKey,
    required StorageSection? section,
    required String? errorKey,
    required bool isBusy,
    String? noteKey,
  }) {
    return Card(
      key: Key('storage-$scope-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.t(titleKey, loc), style: theme.textTheme.titleMedium),
            if (noteKey != null) ...[
              const SizedBox(height: 4),
              Text(
                AppStrings.t(noteKey, loc),
                key: Key('storage-$scope-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (section == null && isBusy)
              _scopeLoadingRow(theme, loc, scope)
            else if (section == null)
              _scopeErrorRow(theme, loc, scope, errorKey ?? 'storage_load_failed')
            else ...[
              if (errorKey != null) ...[
                _scopeErrorRow(theme, loc, scope, errorKey),
                const SizedBox(height: 8),
              ],
              for (final category in section.categories)
                _categoryRow(theme, loc, scope, category),
              if (section.disk != null) ...[
                const Divider(height: 16),
                ..._diskRows(theme, loc, scope, section.disk!),
              ],
              const SizedBox(height: 8),
              _measuredAtRow(theme, loc, scope, section.measuredAt),
            ],
          ],
        ),
      ),
    );
  }

  Widget _scopeLoadingRow(ThemeData theme, String loc, String scope) {
    return Padding(
      key: Key('storage-$scope-loading'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            AppStrings.t('storage_measuring', loc),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopeErrorRow(
    ThemeData theme,
    String loc,
    String scope,
    String errorKey,
  ) {
    return Padding(
      key: Key('storage-$scope-error'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppStrings.t(errorKey, loc),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton(
            key: Key('storage-$scope-retry'),
            onPressed: () =>
                ref.read(storageProvider.notifier).refresh(),
            child: Text(AppStrings.t('retry', loc)),
          ),
        ],
      ),
    );
  }

  // -- rows ---------------------------------------------------------------

  Widget _categoryRow(
    ThemeData theme,
    String loc,
    String scope,
    StorageCategory category,
  ) {
    final value = category.available
        ? formatBytes(category.bytes ?? 0)
        : null;
    return Padding(
      key: Key('storage-$scope-row-${category.key}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.t(storageCategoryLabelKey(category.key), loc),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (value != null)
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                value,
                key: Key('storage-$scope-value-${category.key}'),
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Text(
              AppStrings.t(storageReasonLabelKey(category.reason), loc),
              key: Key('storage-$scope-reason-${category.key}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _diskRows(
    ThemeData theme,
    String loc,
    String scope,
    StorageDisk disk,
  ) {
    if (!disk.available) {
      return <Widget>[
        Padding(
          key: Key('storage-$scope-disk-unavailable'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  AppStrings.t('storage_disk_total', loc),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                AppStrings.t(storageReasonLabelKey(disk.reason), loc),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ];
    }
    return <Widget>[
      _diskRow(theme, loc, scope, 'total', 'storage_disk_total',
          disk.totalBytes ?? 0),
      _diskRow(theme, loc, scope, 'free', 'storage_disk_free',
          disk.freeBytes ?? 0),
    ];
  }

  Widget _diskRow(
    ThemeData theme,
    String loc,
    String scope,
    String slot,
    String labelKey,
    int bytes,
  ) {
    return Padding(
      key: Key('storage-$scope-disk-$slot'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.t(labelKey, loc),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              formatBytes(bytes),
              key: Key('storage-$scope-disk-$slot-value'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _measuredAtRow(
    ThemeData theme,
    String loc,
    String scope,
    DateTime? measuredAt,
  ) {
    return Row(
      key: Key('storage-$scope-measured-at'),
      children: [
        Expanded(
          child: Text(
            AppStrings.t('storage_last_measured', loc),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            formatBackupDate(measuredAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown when the signed-in user lacks `settings_manage` — the same
/// permission the backend enforces on `GET /api/v1/storage`.
class _DeniedView extends StatelessWidget {
  const _DeniedView({required this.loc});

  final String loc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            key: const Key('storage-denied'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.t('storage_no_permission', loc),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('storage-denied-settings'),
                    onPressed: () => context.go('/settings'),
                    child: Text(AppStrings.t('settings', loc)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
