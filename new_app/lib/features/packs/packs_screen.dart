// Packs / bundles screen (Phase 10).
//
// Management surface for the pack module: paginated list, search, status
// filter, create/edit/detail/archive actions and a footer. Reads reuse the
// Phase 4 product scopes (GATE 11) — no pack-specific permission exists.
//
// Responsive: full table at >= 800px, stacked cards below. Logical
// directional properties only, so Arabic RTL works without overrides.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/search_field_state.dart';
import '../../core/strings.dart';
import '../../core/widgets/table_header.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';
import 'pack_detail_dialog.dart';
import 'pack_form_dialog.dart';
import 'pack_models.dart';
import 'packs_providers.dart';

/// One column spec shared by the packs table header and every body row
/// (the products `_Col` pattern): `flex` columns share the leftover
/// width, `fixedWidth` columns keep a deliberate size, `numeric`
/// columns place their content at the ambient end. [id] keeps the
/// historical `<id>-header` keys on the heading cells.
class _PackCol {
  const _PackCol(
    this.id,
    this.label, {
    this.flex = 0,
    this.fixedWidth = 0,
    this.numeric = false,
  });

  final String id;
  final String label;
  final int flex;
  final double fixedWidth;
  final bool numeric;
}

/// Shrink-to-fit wrapper for figures: a grouped value wider than its
/// column scales down instead of wrapping or colliding with the next
/// cell (products `_fitEnd` pattern).
Widget _fitEnd(Widget child) => FittedBox(fit: BoxFit.scaleDown, child: child);

class PacksScreen extends ConsumerStatefulWidget {
  const PacksScreen({super.key});

  @override
  ConsumerState<PacksScreen> createState() => _PacksScreenState();
}

class _PacksScreenState extends ConsumerState<PacksScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The query outlives this page State: without re-seeding, returning
    // shows an empty box while the list is still filtered.
    seedSearchField(
      _searchController,
      ref.read(packsProvider).query.search,
    );
    Future.microtask(() => ref.read(packsProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    final canView = ref.watch(hasPermissionProvider('product_view'));
    if (!canView) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          key: const Key('packs-permission-denied'),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final canCreate = ref.watch(hasPermissionProvider('product_create'));
    final canUpdate = ref.watch(hasPermissionProvider('product_update'));
    final canArchive = ref.watch(hasPermissionProvider('product_archive'));

    final state = ref.watch(packsProvider);
    final narrow = MediaQuery.sizeOf(context).width < 800;
    final gap = narrow ? 8.0 : 12.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, narrow ? 12 : 16, 16, narrow ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(theme, loc, narrow, canCreate),
          SizedBox(height: gap),
          _buildToolbar(theme, loc, narrow, state),
          SizedBox(height: gap),
          Expanded(child: _buildBody(theme, loc, narrow, state,
              canUpdate: canUpdate, canArchive: canArchive)),
          SizedBox(height: gap),
          _buildFooter(theme, loc, narrow, state),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────
  Widget _buildHeader(
    ThemeData theme,
    String loc,
    bool narrow,
    bool canCreate,
  ) {
    final titleBlock = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!narrow) ...[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.28),
              ),
            ),
            child: Icon(
              Icons.local_offer_outlined,
              size: 22,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppStrings.t('packs', loc),
                key: const Key('packs-header-title'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: narrow ? 22 : 26,
                ),
              ),
              if (!narrow) ...[
                const SizedBox(height: 2),
                Text(
                  AppStrings.t('packs_subtitle', loc),
                  key: const Key('packs-header-subtitle'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final addButton = canCreate
        ? FilledButton.icon(
            key: const Key('packs-add-button'),
            onPressed: () => showPackFormDialog(context),
            icon: const Icon(Icons.add, size: 18),
            label: Text(AppStrings.t('add_pack', loc)),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.symmetric(
                horizontal: narrow ? 12 : 18,
                vertical: narrow ? 8 : 12,
              ),
            ),
          )
        : null;

    if (narrow) {
      return Row(
        children: [
          Expanded(child: titleBlock),
          if (addButton != null) ...[
            const SizedBox(width: 8),
            Flexible(child: addButton),
          ],
        ],
      );
    }

    return SizedBox(
      height: 72,
      child: Row(
        children: [
          Expanded(child: titleBlock),
          if (addButton != null) ...[
            const SizedBox(width: 12),
            addButton,
          ],
        ],
      ),
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────
  Widget _buildToolbar(
    ThemeData theme,
    String loc,
    bool narrow,
    PacksState state,
  ) {
    final cs = theme.colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: cs.outline.withValues(alpha: 0.35)),
    );

    final searchField = TextField(
      key: const Key('packs-search-field'),
      controller: _searchController,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: AppStrings.t('search', loc),
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
        prefixIcon: Icon(
          Icons.search,
          size: 20,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              key: const Key('packs-search-clear'),
              tooltip: AppStrings.t('clear', loc),
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                _searchController.clear();
                ref.read(packsProvider.notifier).setSearch('');
              },
            );
          },
        ),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
        filled: true,
        fillColor: cs.surface,
      ),
      onChanged: (value) => ref.read(packsProvider.notifier).setSearch(value),
    );

    final status = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 170),
      child: DropdownButtonFormField<String>(
        key: const Key('packs-status-filter'),
        initialValue: state.query.status,
        isDense: true,
        isExpanded: true,
        items: [
          for (final entry in [
            ('active', AppStrings.t('active', loc)),
            ('archived', AppStrings.t('archived', loc)),
            ('all', AppStrings.t('all', loc)),
          ])
            DropdownMenuItem(
              value: entry.$1,
              child: Text(entry.$2, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) ref.read(packsProvider.notifier).setStatus(v);
        },
        icon: const Icon(Icons.arrow_drop_down, size: 22),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(
            Icons.tune,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          filled: true,
          fillColor: cs.surface,
        ),
      ),
    );

    final refresh = IconButton(
      key: const Key('packs-refresh-button'),
      tooltip: AppStrings.t('refresh', loc),
      onPressed: () => ref.read(packsProvider.notifier).refresh(),
      icon: const Icon(Icons.refresh),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: cs.primary,
        backgroundColor: cs.primary.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );

    return Material(
      key: const Key('packs-toolbar'),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: narrow ? 8 : 10,
        ),
        child: narrow
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(width: 220, child: searchField),
                  status,
                  refresh,
                ],
              )
            : Row(
                children: [
                  Expanded(flex: 3, child: searchField),
                  const SizedBox(width: 10),
                  status,
                  const SizedBox(width: 10),
                  refresh,
                ],
              ),
      ),
    );
  }

  // ── Body (table / cards) ──────────────────────────────────────────────
  Widget _buildBody(
    ThemeData theme,
    String loc,
    bool narrow,
    PacksState state, {
    required bool canUpdate,
    required bool canArchive,
  }) {
    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              state.error!,
              key: const Key('packs-error'),
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('packs-retry'),
              onPressed: () => ref.read(packsProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        child: Text(
          AppStrings.t('no_packs', loc),
          key: const Key('packs-empty'),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }

    return narrow
        ? _cardList(theme, loc, state,
            canUpdate: canUpdate, canArchive: canArchive)
        : _table(theme, loc, state,
            canUpdate: canUpdate, canArchive: canArchive);
  }

  Widget _table(
    ThemeData theme,
    String loc,
    PacksState state, {
    required bool canUpdate,
    required bool canArchive,
  }) {
    final head = AppTheme.tableHeader(theme);

    // One spec list drives the header and every row (products `_Col` +
    // `cell()` pattern): the pack name leads the flex share, the money
    // and count columns get deliberate weights so grouped decimals
    // never collide, and status/actions keep fixed chip/button widths.
    // Each cell carries its own horizontal padding, so header and body
    // boxes share one width definition by construction. The previous
    // layout split the width `[4,2,1,2,2,2]` across separately-built
    // header/body cells: `price` got one thirteenth of the table (too
    // narrow for decimals) and its `numericText(textAlign: end)`
    // hugged the opposite edge from the heading under RTL.
    final cols = <_PackCol>[
      _PackCol('pack_name', AppStrings.t('pack_name', loc), flex: 24),
      _PackCol('price', AppStrings.t('price', loc), flex: 13, numeric: true),
      _PackCol('components', AppStrings.t('components', loc),
          flex: 12, numeric: true),
      _PackCol('sum_of_parts', AppStrings.t('sum_of_parts', loc),
          flex: 13, numeric: true),
      _PackCol('status', AppStrings.t('status', loc),
          flex: 0, fixedWidth: 112),
      _PackCol('actions', AppStrings.t('actions', loc),
          flex: 0, fixedWidth: 144, numeric: true),
    ];

    Widget cell(int index, Widget child, {bool header = false}) {
      final col = cols[index];
      Widget content = Align(
        alignment: col.numeric
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: child,
      );
      if (col.fixedWidth > 0) {
        content = SizedBox(width: col.fixedWidth, child: content);
      }
      if (header) {
        content = DefaultTextStyle(style: head, child: content);
      }
      final padded = Padding(
        key: Key(header ? 'packs-header-col-$index' : 'packs-body-col-$index'),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: content,
      );
      if (col.fixedWidth > 0) return padded;
      return Expanded(flex: col.flex, child: padded);
    }

    List<Widget> headerCells() => [
          for (var i = 0; i < cols.length; i++)
            cell(
              i,
              Text(
                cols[i].label,
                key: Key('${cols[i].id}-header'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              header: true,
            ),
        ];

    List<Widget> dataCells(PackModel pack) {
      final body = theme.textTheme.bodyMedium;
      var i = 0;
      return [
        cell(
          i++,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pack.name,
                key: Key('pack-row-name-${pack.id}'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (pack.barcode != null && pack.barcode!.isNotEmpty)
                Text(
                  pack.barcode!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        // Numeric contract: the LTR paragraph orders the digits, the
        // cell's ambient-direction Align does the placing —
        // `textAlign.end` inside the LTR paragraph flips the edge
        // under RTL and left the price heading above empty space.
        cell(
          i++,
          _fitEnd(numericText(formatGrouped(pack.price), style: body)),
        ),
        cell(
          i++,
          Text('${pack.componentsCount}', style: body),
        ),
        cell(
          i++,
          _fitEnd(
            numericText(
              pack.sumOfParts ?? '—',
              key: Key('pack-row-sum-${pack.id}'),
              style: body,
            ),
          ),
        ),
        cell(i++, _statusBadge(theme, loc, pack)),
        cell(
          i,
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: Key('pack-detail-${pack.id}'),
                tooltip: AppStrings.t('pack_detail_title', loc),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                onPressed: () => showPackDetailDialog(context, pack: pack),
              ),
              if (canUpdate)
                IconButton(
                  key: Key('pack-edit-${pack.id}'),
                  tooltip: AppStrings.t('edit', loc),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: pack.isArchived
                      ? null
                      : () => _edit(pack),
                ),
              if (canArchive && !pack.isArchived)
                IconButton(
                  key: Key('pack-archive-${pack.id}'),
                  tooltip: AppStrings.t('delete', loc),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  onPressed: () => _confirmArchive(pack),
                ),
            ],
          ),
        ),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pinned heading: stays put while the pack list scrolls (§17.2).
        TableHeaderRow(
          testKey: const Key('packs-table-header'),
          children: headerCells(),
        ),
        Expanded(
          child: ListView.separated(
            key: const Key('packs-list'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: state.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final pack = state.items[index];
              return Padding(
                key: Key('pack-row-${pack.id}'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: dataCells(pack),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _cardList(
    ThemeData theme,
    String loc,
    PacksState state, {
    required bool canUpdate,
    required bool canArchive,
  }) {
    return ListView.separated(
      key: const Key('packs-list'),
      itemCount: state.items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final pack = state.items[index];
        return Card(
          key: Key('pack-card-${pack.id}'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        pack.name,
                        key: Key('pack-card-name-${pack.id}'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    numericText(
                      formatGrouped(pack.price),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Bidi: Arabic labels stay natural; each numeric segment is
                // an LTR isolate (whole-string forced LTR still reverses
                // grouped digits after an Arabic label — W7).
                Text(
                  '${AppStrings.t('components', loc)}: '
                  '${bidiIsolateLtr('${pack.componentsCount}')}'
                  '${pack.sumOfParts != null ? '  ·  ${AppStrings.t('sum_of_parts', loc)}: ${bidiIsolateLtr(pack.sumOfParts!)}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _statusBadge(theme, loc, pack),
                    const Spacer(),
                    IconButton(
                      key: Key('pack-detail-${pack.id}'),
                      tooltip: AppStrings.t('pack_detail_title', loc),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      onPressed: () =>
                          showPackDetailDialog(context, pack: pack),
                    ),
                    if (canUpdate)
                      IconButton(
                        key: Key('pack-edit-${pack.id}'),
                        tooltip: AppStrings.t('edit', loc),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: pack.isArchived
                            ? null
                            : () => _edit(pack),
                      ),
                    if (canArchive && !pack.isArchived)
                      IconButton(
                        key: Key('pack-archive-${pack.id}'),
                        tooltip: AppStrings.t('delete', loc),
                        icon: const Icon(Icons.archive_outlined, size: 18),
                        onPressed: () => _confirmArchive(pack),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusBadge(ThemeData theme, String loc, PackModel pack) {
    final archived = pack.isArchived;
    final inactive = !pack.isActive;
    final color = archived
        ? theme.colorScheme.onSurface.withValues(alpha: 0.6)
        : inactive
            ? AppColors.warning
            : AppColors.success;
    return Container(
      key: Key('pack-status-${pack.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        archived
            ? AppStrings.t('archived', loc)
            : AppStrings.t('active', loc),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// Issue 3 (Phase 10 fix round): the LIST payload carries no
  /// `components[]`, so the edit form must be opened with the hydrated
  /// DETAIL (`GET /packs/{id}`) — otherwise every existing component row
  /// would silently disappear when a pack is opened for editing.
  Future<void> _edit(PackModel pack) async {
    final detail =
        await ref.read(packsProvider.notifier).fetchDetail(pack.id);
    if (!mounted) return;
    if (detail == null) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      showPosToast(
        context,
        message: AppStrings.t('api_error_retry', loc),
        kind: PosToastKind.error,
        key: const Key('pack-edit-error-toast'),
      );
      return;
    }
    await showPackFormDialog(context, pack: detail);
  }

  void _confirmArchive(PackModel pack) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('pack-archive-confirm'),
        title: Text(AppStrings.t('delete', loc)),
        content: Text(
          '${AppStrings.t('archive_pack_confirm', loc)}\n\n${pack.name}',
          key: const Key('pack-archive-confirm-text'),
        ),
        actions: [
          TextButton(
            key: const Key('pack-archive-cancel'),
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('pack-archive-confirm-button'),
            onPressed: () async {
              Navigator.pop(dialogContext);
              final error = await ref
                  .read(packsProvider.notifier)
                  .archive(pack.id);
              if (!mounted) return;
              if (error != null) {
                showPosToast(
                  context,
                  message: error,
                  kind: PosToastKind.error,
                  key: const Key('pack-archive-error-toast'),
                );
              } else {
                showPosToast(
                  context,
                  message: AppStrings.t('pack_archived', loc),
                  kind: PosToastKind.success,
                  key: const Key('pack-archived-toast'),
                );
              }
            },
            child: Text(AppStrings.t('confirm', loc)),
          ),
        ],
      ),
    );
  }

  // ── Footer (pagination) ───────────────────────────────────────────────
  Widget _buildFooter(
    ThemeData theme,
    String loc,
    bool narrow,
    PacksState state,
  ) {
    final cs = theme.colorScheme;
    const pageSizeOptions = [20, 40, 60, 100];
    final currentSize = pageSizeOptions.contains(state.query.pageSize)
        ? state.query.pageSize
        : 40;

    return Container(
      key: const Key('packs-footer'),
      height: narrow ? 44 : 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(
          top: BorderSide(color: cs.outline.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '${AppStrings.t('total', loc)}: ${state.total}',
              key: const Key('packs-total'),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (!narrow) ...[
            DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const Key('packs-page-size'),
                value: currentSize,
                isDense: true,
                items: [
                  for (final size in pageSizeOptions)
                    DropdownMenuItem(
                      value: size,
                      child: Text('$size', style: theme.textTheme.bodySmall),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    ref.read(packsProvider.notifier).setPageSize(v);
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
          ],
          IconButton(
            key: const Key('packs-prev-page'),
            tooltip: AppStrings.t('prev', loc),
            onPressed: state.query.page > 1
                ? () => ref
                    .read(packsProvider.notifier)
                    .setPage(state.query.page - 1)
                : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          Text(
            '${state.query.page} / ${state.pages}',
            key: const Key('packs-page-indicator'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('packs-next-page'),
            tooltip: AppStrings.t('next', loc),
            onPressed: state.query.page < state.pages
                ? () => ref
                    .read(packsProvider.notifier)
                    .setPage(state.query.page + 1)
                : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
