// Returns screen (Phase 12): paginated return history + the clearly
// visible "Return Products" entry point for an INDEPENDENT multi-product
// return (scan/search → N lines → one document). Linked returns start
// from the invoice detail (sale_detail_dialog.dart → "Return items").
//
// RBAC: `pos_return` to read and to post a return (GATE 15 — no new
// scopes; voiding keeps its own `pos_void`). Money is displayed exactly
// as the server computed it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../core/widgets/adaptive_title_row.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import 'return_detail_dialog.dart';
import 'return_models.dart';
import 'return_products_dialog.dart';
import 'return_providers.dart';

class ReturnsScreen extends ConsumerStatefulWidget {
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh on every visit (the provider keeps its state alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(returnsProvider.notifier).load();
    });
  }

  Future<void> _returnProducts() async {
    final result = await showReturnProductsDialog(context);
    if (result == null || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final message = result.idempotentReplay
        ? AppStrings.t('return_replay', loc)
        : AppStrings.t('return_success', loc);
    _showResultDialog(result, message);
    ref.read(returnsProvider.notifier).refresh();
  }

  /// Authoritative refund split from the server (never client-computed).
  void _showResultDialog(ReturnCreateResult result, String message) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('return-result-dialog'),
        title: Text(message, key: const Key('return-result-title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.doc.returnNumber,
              key: const Key('return-result-number'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _resultRow(
              theme,
              loc,
              'return_refund_total',
              result.refundTotal,
              const Key('return-result-refund'),
            ),
            _resultRow(
              theme,
              loc,
              'return_credit_reversed',
              result.creditReversed,
              const Key('return-result-credit'),
            ),
            _resultRow(
              theme,
              loc,
              'return_cash_pending',
              result.cashPending,
              const Key('return-result-cash'),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            key: const Key('return-result-close'),
            onPressed: () => _closeResultDialog(dialogContext),
            child: Text(AppStrings.t('ok', loc)),
          ),
        ],
      ),
    );
  }

  /// Closes ONLY the result dialog route — never the /returns page.
  ///
  /// `showDialog` pushes on the root navigator (`useRootNavigator: true`),
  /// and with a `ShellRoute` go_router builds a NESTED navigator for the
  /// shell's child pages, so the Returns screen and the dialog live on two
  /// different navigators. Popping with the screen's context therefore
  /// popped the `/returns` page (a page-based route → GoRouter's
  /// `onPopPage`), emptied the route stack and produced
  /// "You have popped the last page off of the stack" + "!_debugLocked".
  ///
  /// The dialog's own builder context resolves to the navigator that owns
  /// the dialog; the `isCurrent` guard makes a repeated/second tap a no-op
  /// while the dialog is already closing, so the pop can never fall through
  /// to the page underneath. Exactly one pop per dialog.
  void _closeResultDialog(BuildContext dialogContext) {
    final route = ModalRoute.of(dialogContext);
    if (route == null || route.isFirst || !route.isCurrent) return;
    Navigator.of(dialogContext).pop();
  }

  Widget _resultRow(
    ThemeData theme,
    String loc,
    String labelKey,
    String value,
    Key key,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(AppStrings.t(labelKey, loc), style: theme.textTheme.bodySmall),
          const SizedBox(width: 16),
          numericText(value, key: key, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('pos_return'));

    if (!canView) {
      return Center(
        key: const Key('returns-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final state = ref.watch(returnsProvider);

    return Padding(
      key: const Key('returns-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveTitleRow(
            title: Text(
              AppStrings.t('returns_history', loc),
              key: const Key('returns-title'),
              style: theme.textTheme.headlineSmall,
            ),
            actions: [
              OutlinedButton.icon(
                key: const Key('returns-return-products'),
                onPressed: _returnProducts,
                icon: const Icon(Icons.undo, size: 18),
                label: Text(AppStrings.t('return_products', loc)),
              ),
              IconButton(
                key: const Key('returns-refresh'),
                tooltip: AppStrings.t('refresh', loc),
                onPressed: () =>
                    ref.read(returnsProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Wide windows keep the original single-row filter bar; tighter
          // windows wrap search / reason / count instead of overflowing
          // ("RenderFlex overflowed by 139 pixels" at an 800px window).
          LayoutBuilder(
            builder: (context, constraints) {
              final searchField = SizedBox(
                width: 280,
                child: TextField(
                  key: const Key('returns-filter-invoice'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('return_search_invoice', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(100),
                  ],
                  onSubmitted: (value) => ref
                      .read(returnsProvider.notifier)
                      .setInvoiceNumber(value),
                ),
              );
              final reasonFilter = SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  key: const Key('returns-filter-reason'),
                  initialValue: state.query.reason,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('return_reason', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        AppStrings.t('return_all_reasons', loc),
                        key: const Key('returns-reason-all'),
                      ),
                    ),
                    for (final reason in kReturnReasons)
                      DropdownMenuItem(
                        value: reason,
                        child: Text(
                          AppStrings.t(returnReasonKey(reason), loc),
                          key: Key('returns-reason-$reason'),
                        ),
                      ),
                  ],
                  onChanged: (value) => ref
                      .read(returnsProvider.notifier)
                      .setReason(value ?? ''),
                ),
              );
              final countText = Text(
                '${AppStrings.t('total', loc)}: ${state.total}',
                key: const Key('returns-total-count'),
                style: theme.textTheme.bodySmall,
              );

              if (constraints.maxWidth >= 840) {
                return Row(
                  children: [
                    searchField,
                    const SizedBox(width: 12),
                    reasonFilter,
                    const SizedBox(width: 12),
                    countText,
                  ],
                );
              }
              return Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [searchField, reasonFilter, countText],
              );
            },
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildList(theme, loc, state)),
          if (state.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('returns-prev'),
                  onPressed: state.query.page > 1 && !state.loading
                      ? () => ref
                          .read(returnsProvider.notifier)
                          .setPage(state.query.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${state.query.page} / ${state.pages}',
                  key: const Key('returns-page'),
                ),
                IconButton(
                  key: const Key('returns-next'),
                  onPressed: state.query.page < state.pages && !state.loading
                      ? () => ref
                          .read(returnsProvider.notifier)
                          .setPage(state.query.page + 1)
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

  Widget _buildList(ThemeData theme, String loc, ReturnsState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('returns-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.error != null) {
      return Center(
        key: const Key('returns-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('returns-retry'),
              onPressed: () => ref.read(returnsProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('returns-empty'),
        child: Text(AppStrings.t('no_returns', loc)),
      );
    }
    return ListView.builder(
      key: const Key('returns-list'),
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final doc = state.items[index];
        return ListTile(
          key: Key('return-tile-$index'),
          title: Text(
            doc.returnNumber,
            key: Key('return-number-$index'),
          ),
          subtitle: Text(
            [
              // Bidi: Arabic labels natural; the invoice number and the
              // date/time pair are LTR isolates (their numeric groups
              // would otherwise swap in the RTL subtitle).
              if (doc.invoiceNumber != null && doc.invoiceNumber!.isNotEmpty)
                '${AppStrings.t('invoice_number', loc)}: '
                '${bidiIsolateLtr(doc.invoiceNumber!)}',
              // Reason is optional (fix round 1): only shown when given.
              if (doc.reason.isNotEmpty)
                AppStrings.t(returnReasonKey(doc.reason), loc),
              bidiIsolateLtr(doc.returnDate.toLocal().toString().substring(0, 16)),
            ].join(' · '),
            key: Key('return-meta-$index'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              numericText(
                formatGrouped(doc.total),
                key: Key('return-total-$index'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => showReturnDetailDialog(
            context,
            returnId: doc.id,
            initial: doc,
          ),
        );
      },
    );
  }
}
