// Promotions screen (Phase 18): filtered + paginated promotion list with
// the "Add promotion" entry point, the active ⇄ inactive toggle and the
// edit action.
//
// RBAC: `promotion_view` to read, `promotion_create` to add,
// `promotion_update` to toggle/edit (admin + manager — the cashier holds
// none of them and never sees the rail entry).
//
// The list shows the SERVER's promotion (type, value, membership count).
// It never derives an effective promotional price: that rides on the
// product responses for the POS.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';
import 'promotion_form_dialog.dart';
import 'promotion_models.dart';
import 'promotions_providers.dart';

class PromotionsScreen extends ConsumerStatefulWidget {
  const PromotionsScreen({super.key});

  @override
  ConsumerState<PromotionsScreen> createState() => _PromotionsScreenState();
}

class _PromotionsScreenState extends ConsumerState<PromotionsScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (the provider keeps its state alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(promotionsProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  PromotionsState get state => ref.read(promotionsProvider);

  Future<void> _addPromotion() async {
    final saved = await showPromotionFormDialog(context);
    if (saved == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('promotion_created', loc),
      detail: saved.name,
      kind: PosToastKind.success,
      key: const Key('promotions-toast'),
    );
    ref.read(promotionsProvider.notifier).refresh();
  }

  Future<void> _editPromotion(PromotionItem promotion) async {
    final saved = await showPromotionFormDialog(context, promotion: promotion);
    if (saved == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('promotion_updated', loc),
      detail: saved.name,
      kind: PosToastKind.success,
      key: const Key('promotions-update-toast'),
    );
    ref.read(promotionsProvider.notifier).refresh();
  }

  Future<void> _toggle(PromotionItem promotion) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final (saved, error) = await ref
        .read(promotionsApiProvider)
        .toggle(promotionId: promotion.id);
    if (!mounted) return;
    if (error != null) {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('promotions-toggle-error-toast'),
      );
      return;
    }
    showPosToast(
      context,
      message: AppStrings.t('promotion_status_changed', loc),
      detail: saved?.name,
      kind: PosToastKind.success,
      key: const Key('promotions-toggle-toast'),
    );
    ref.read(promotionsProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('promotion_view'));
    final canCreate = ref.watch(hasPermissionProvider('promotion_create'));
    final canUpdate = ref.watch(hasPermissionProvider('promotion_update'));

    if (!canView) {
      return Center(
        key: const Key('promotions-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final promotions = ref.watch(promotionsProvider);

    return Padding(
      key: const Key('promotions-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('promotions', loc),
                key: const Key('promotions-title'),
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(width: 12),
              Text(
                AppStrings.t('promotions_subtitle', loc),
                key: const Key('promotions-subtitle'),
                style: theme.textTheme.bodyMedium,
              ),
              const Spacer(),
              if (canCreate)
                OutlinedButton.icon(
                  key: const Key('promotions-add'),
                  onPressed: _addPromotion,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(AppStrings.t('promotion_add', loc)),
                ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('promotions-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () =>
                    ref.read(promotionsProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildFilters(theme, loc, promotions),
          const SizedBox(height: 8),
          Expanded(child: _buildList(theme, loc, promotions, canUpdate)),
          if (promotions.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('promotions-prev'),
                  onPressed: promotions.query.page > 1 && !promotions.loading
                      ? () => ref
                          .read(promotionsProvider.notifier)
                          .setPage(promotions.query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${promotions.query.page} / ${promotions.pages}',
                  key: const Key('promotions-page'),
                ),
                IconButton(
                  key: const Key('promotions-next'),
                  onPressed:
                      promotions.query.page < promotions.pages && !promotions.loading
                          ? () => ref
                              .read(promotionsProvider.notifier)
                              .setPage(promotions.query.page + 1)
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

  Widget _buildFilters(ThemeData theme, String loc, PromotionsState promotions) {
    final notifier = ref.read(promotionsProvider.notifier);
    final query = promotions.query;
    final hasFilters = query.search.isNotEmpty || query.isActive != null;

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: TextField(
            key: const Key('promotions-search'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: AppStrings.t('promotion_search_hint', loc),
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: const OutlineInputBorder(),
            ),
            inputFormatters: [LengthLimitingTextInputFormatter(200)],
            onSubmitted: (value) => notifier.setSearch(value),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 190,
          child: DropdownButtonFormField<String>(
            key: const Key('promotions-active-filter'),
            initialValue: query.isActive == null
                ? ''
                : (query.isActive! ? 'true' : 'false'),
            isExpanded: true,
            decoration: InputDecoration(
              labelText: AppStrings.t('status', loc),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  AppStrings.t('all', loc),
                  key: const Key('promotions-active-all'),
                ),
              ),
              DropdownMenuItem(
                value: 'true',
                child: Text(
                  AppStrings.t('active', loc),
                  key: const Key('promotions-active-active'),
                ),
              ),
              DropdownMenuItem(
                value: 'false',
                child: Text(
                  AppStrings.t('inactive', loc),
                  key: const Key('promotions-active-inactive'),
                ),
              ),
            ],
            onChanged: (value) => notifier.setIsActive(
              value == null || value.isEmpty ? null : (value == 'true'),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (hasFilters)
          IconButton(
            key: const Key('promotions-clear'),
            tooltip: AppStrings.t('clear', loc),
            onPressed: () {
              _searchController.clear();
              notifier.clearFilters();
            },
            icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
          ),
        const Spacer(),
        Text(
          '${AppStrings.t('promotion_count', loc)}: ${promotions.total}',
          key: const Key('promotions-total-count'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildList(
    ThemeData theme,
    String loc,
    PromotionsState promotions,
    bool canUpdate,
  ) {
    if (promotions.loading && promotions.items.isEmpty) {
      return const Center(
        key: Key('promotions-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (promotions.error != null) {
      return Center(
        key: const Key('promotions-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(promotions.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('promotions-retry'),
              onPressed: () => ref.read(promotionsProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (promotions.items.isEmpty) {
      return Center(
        key: const Key('promotions-empty'),
        child: Text(AppStrings.t('promotion_empty', loc)),
      );
    }
    return ListView.builder(
      key: const Key('promotions-list'),
      itemCount: promotions.items.length,
      itemBuilder: (context, index) {
        final item = promotions.items[index];
        final meta = <String>[
          AppStrings.t(promotionTypeKey(item.promotionType), loc),
          promotionValueLabel(item),
          '${item.productCount} ${AppStrings.t('products', loc)}',
          AppStrings.t(item.isActive ? 'active' : 'inactive', loc),
        ];
        return ListTile(
          key: Key('promotion-tile-$index'),
          title: Text(
            item.name,
            key: Key('promotion-name-$index'),
          ),
          subtitle: Text(
            meta.join(' · '),
            key: Key('promotion-meta-$index'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canUpdate) ...[
                IconButton(
                  key: Key('promotion-toggle-$index'),
                  tooltip: AppStrings.t(
                    item.isActive ? 'promotion_deactivate' : 'promotion_activate',
                    loc,
                  ),
                  icon: Icon(
                    item.isActive ? Icons.toggle_on : Icons.toggle_off,
                    color: item.isActive ? theme.colorScheme.primary : null,
                  ),
                  onPressed: () => _toggle(item),
                ),
                IconButton(
                  key: Key('promotion-edit-$index'),
                  tooltip: AppStrings.t('edit', loc),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () => _editPromotion(item),
                ),
              ],
            ],
          ),
          onTap: canUpdate ? () => _editPromotion(item) : null,
        );
      },
    );
  }
}
