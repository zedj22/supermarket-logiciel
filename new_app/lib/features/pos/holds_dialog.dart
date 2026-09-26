// Held-sales dialog (F10) — list, restore into cart, delete.
// Restore revalidates stock/prices server-side (no reservation).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'pos_error_message.dart';
import 'pos_models.dart';
import 'pos_providers.dart';
import 'pos_toast.dart';

/// Returns true when a hold was restored into the cart.
Future<bool?> showHoldsDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const HoldsDialog(),
  );
}

class HoldsDialog extends ConsumerStatefulWidget {
  const HoldsDialog({super.key});

  @override
  ConsumerState<HoldsDialog> createState() => _HoldsDialogState();
}

class _HoldsDialogState extends ConsumerState<HoldsDialog> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(holdsProvider.notifier).load(),
    );
  }

  Future<void> _restore(String holdId) async {
    if (_busy) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    setState(() => _busy = true);
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.post('/api/v1/pos/holds/$holdId/restore');
      final data = response.data as Map<String, dynamic>? ?? const {};
      final holdJson = data['hold'] as Map<String, dynamic>?;
      // FIX #3/#10B: a failed restore (server kept the hold) must NOT
      // load the cart or close the dialog — keep the hold listed and
      // allow retry. Show the backend's own validation reasons when
      // present instead of a blanket system error.
      if (data['ok'] == false || holdJson == null) {
        final errors = data['errors'];
        final backendDetail = errors is List && errors.isNotEmpty
            ? errors.map((e) => '$e').join(' — ')
            : null;
        if (mounted) await ref.read(holdsProvider.notifier).load();
        if (mounted) {
          // Localized headline, backend reasons on the secondary line
          // (UX FIX #12 — FIX #5).
          showPosToast(
            context,
            message: AppStrings.t('api_error_retry', loc),
            detail: backendDetail,
            kind: PosToastKind.error,
            key: const Key('hold-restore-error'),
          );
        }
        return;
      }
      final hold = HoldModel.fromJson(holdJson);
      if (!mounted) return;
      // 1) load into active cart  2) hold already deleted server-side
      ref.read(posCartProvider.notifier).loadHold(hold);
      // 3) refresh held-sales count immediately
      await ref.read(holdsProvider.notifier).load();
      if (!mounted) return;
      // Success snackbar is shown by the caller after this dialog closes
      // (dialog context would be disposed before the snackbar paints).
      // 4) close dialog — active cart has restored lines
      Navigator.pop(context, true);
    } catch (e) {
      // FIX #10B STEP 8: HTTP 200 + a valid payload never reaches here.
      // Unexpected (parse) exceptions are logged for development instead
      // of being swallowed; known HTTP errors keep their real message.
      debugPrint('POS hold restore exception: $e');
      // Localized headline + optional backend detail (UX FIX #12 — FIX #5).
      final error = posApiError(e, loc);
      // Failed restore: do NOT delete hold; keep list; allow retry.
      if (mounted) {
        await ref.read(holdsProvider.notifier).load();
      }
      if (mounted) {
        showPosToast(
          context,
          message: error.message,
          detail: error.detail,
          kind: PosToastKind.error,
          key: const Key('hold-restore-error'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final state = ref.watch(holdsProvider);

    return AlertDialog(
      key: const Key('holds-dialog'),
      title: Text(AppStrings.t('held_sales', loc)),
      content: SizedBox(
        width: 480,
        height: 360,
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : state.error != null
                ? Center(
                    child: Text(
                      state.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : state.items.isEmpty
                    ? Center(child: Text(AppStrings.t('no_holds', loc)))
                    : ListView.builder(
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final hold = state.items[index];
                          return ListTile(
                            key: Key('hold-row-${hold.id}'),
                            leading: const Icon(Icons.pause_circle_outline),
                            title: Text(
                              '${hold.items.length} '
                              '${AppStrings.t('items_count', loc)}'
                              '${hold.note == null ? '' : ' — ${hold.note}'}',
                            ),
                            subtitle: Text(
                              hold.createdAt
                                  .toLocal()
                                  .toString()
                                  .substring(0, 16),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: Key('hold-restore-${hold.id}'),
                                  tooltip: AppStrings.t('restore_hold', loc),
                                  icon: const Icon(Icons.restore),
                                  onPressed: () => _restore(hold.id),
                                ),
                                IconButton(
                                  key: Key('hold-delete-${hold.id}'),
                                  tooltip: AppStrings.t('delete_hold', loc),
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final err = await ref
                                        .read(holdsProvider.notifier)
                                        .delete(hold.id);
                                    if (err != null && context.mounted) {
                                      showPosToast(
                                        context,
                                        message: err,
                                        kind: PosToastKind.error,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                            onTap: () => _restore(hold.id),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        TextButton(
          key: const Key('holds-refresh'),
          onPressed: () => ref.read(holdsProvider.notifier).load(),
          child: Text(AppStrings.t('refresh', loc)),
        ),
      ],
    );
  }
}
