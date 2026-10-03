// Phase 16 — AppBar connection chip (§23.1, §14 "steady-state UI").
//
// The chip is the ONLY steady-state indicator of LAN health: no modal ever
// appears after the wizard (legacy policy, §14). Colour is green / amber /
// red, the tooltip carries the detail, and it sits at the AppBar's trailing
// edge so RTL reads it last (Arabic is the default locale).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/strings.dart';
import '../../../l10n/locale_provider.dart';
import '../connection_provider.dart';

class ConnectionStatusChip extends ConsumerWidget {
  const ConnectionStatusChip({super.key});

  /// (colour, localization key) for the current phase.
  static (Color, String) presentation(LanPhase phase, bool degraded) {
    switch (phase) {
      case LanPhase.connected:
        return degraded
            ? (Colors.amber, 'lan_degraded_db')
            : (Colors.green, 'lan_connected');
      case LanPhase.reconnecting:
      case LanPhase.disconnected:
        return (Colors.red, 'lan_disconnected');
      case LanPhase.rejected:
        return (Colors.red, 'lan_disconnected');
      case LanPhase.unconfigured:
      case LanPhase.discovering:
        return (Colors.grey, 'lan_disconnected');
      case LanPhase.serverFound:
      case LanPhase.pairingRequested:
      case LanPhase.awaitingApproval:
      case LanPhase.connecting:
        return (Colors.amber, 'lan_reconnecting');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(lanConnectionProvider);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    final (color, key) = presentation(conn.phase, conn.degraded);
    final label = AppStrings.t(key, loc);
    final tooltip = conn.phase == LanPhase.connected && !conn.degraded
        ? AppStrings.t('lan_connected_tooltip', loc)
        : label;

    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const Key('connection-status-dot'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              key: const Key('connection-status-label'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
