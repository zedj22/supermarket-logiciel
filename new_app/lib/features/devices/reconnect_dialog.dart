// Phase 16 — boot-time reconnect modal (§14 "steady-state UI").
//
// Legacy policy preserved: a modal appears ONLY during boot/wizard. Once
// the app is running the chip alone reports health, so a flapping network
// never interrupts a cashier mid-sale. "Cancel" drops the user to manual
// address entry rather than a dead end.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/strings.dart';
import '../../../l10n/locale_provider.dart';
import 'connection_provider.dart';

enum ReconnectAction { retry, manualEntry, dismiss }

class ReconnectDialog extends ConsumerWidget {
  const ReconnectDialog({super.key});

  /// Shows the modal. Resolves with the cashier's choice; the caller
  /// performs the actual retry / navigation so the dialog stays dumb.
  static Future<ReconnectAction> show(BuildContext context) {
    return showDialog<ReconnectAction>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ReconnectDialog(),
    ).then((value) => value ?? ReconnectAction.dismiss);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final conn = ref.watch(lanConnectionProvider);
    final serverUnreachable =
        conn.errorMessage == 'unreachable' || conn.baseUrl == null;

    return AlertDialog(
      title: Text(AppStrings.t('lan_reconnect_title', loc)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            serverUnreachable
                ? AppStrings.t('lan_server_unreachable', loc)
                : AppStrings.t('lan_reconnect_body', loc),
          ),
          if (conn.baseUrl != null) ...[
            const SizedBox(height: 12),
            Text(
              conn.baseUrl!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('reconnect-manual-entry'),
          onPressed: () => Navigator.of(context).pop(ReconnectAction.manualEntry),
          child: Text(AppStrings.t('lan_manual_entry', loc)),
        ),
        FilledButton(
          key: const Key('reconnect-now'),
          onPressed: () => Navigator.of(context).pop(ReconnectAction.retry),
          child: Text(AppStrings.t('lan_reconnect_now', loc)),
        ),
      ],
    );
  }
}
