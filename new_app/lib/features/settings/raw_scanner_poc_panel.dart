// Phase 3 — the Raw input scanner PoC card in Settings (flag-gated).
//
// The control surface for [RawScannerPocController]: master toggle,
// scanner keyboard-country selector, Learn control, learned devices,
// native evidence counters (raw/suppression/order-violation) and the
// last decoded run (length + suffix only).
//
// Rendered ONLY when the app was built with
// `--dart-define=KLICK_RAW_SCANNER_POC=true` (the settings screen wraps
// this widget in `if (kRawScannerPocEnabled)`); with the flag absent this
// card and the whole controller never exist, so production behavior is
// unchanged.
//
// Rules the widget itself enforces (same as the scan-diagnostics card):
//  * no TextField anywhere — nothing can take keyboard focus from a
//    scanner or an operator mid-test;
//  * no autofocus, no Focus nodes, no requestFocus calls;
//  * every user-visible string goes through AppStrings.t (en/ar/fr);
//  * never renders a full barcode — only length and the 3-digit suffix.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/raw_scanner/raw_scanner_decoder.dart';
import '../../core/raw_scanner/raw_scanner_poc.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';

/// Layout label keys, indexed by [RawScannerDecoder.supportedLayouts].
const Map<String, String> _layoutLabelKeys = <String, String>{
  kRawScannerLayoutUs: 'raw_scanner_layout_us',
  kRawScannerLayoutFr: 'raw_scanner_layout_fr',
  kRawScannerLayoutAr: 'raw_scanner_layout_ar',
};

/// The Raw input scanner PoC card.
class RawScannerPocSection extends ConsumerWidget {
  const RawScannerPocSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final controller = ref.watch(rawScannerPocProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final status = controller.status;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.t('raw_scanner_title', loc),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  AppStrings.t('raw_scanner_desc', loc),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('settings-raw-scanner-toggle'),
                      onPressed: controller.available
                          ? () => controller.setEnabled(!controller.enabled)
                          : null,
                      child: Text(AppStrings.t('raw_scanner_enable', loc)),
                    ),
                    FilledButton.tonal(
                      key: const Key('settings-raw-scanner-learn'),
                      onPressed: controller.available &&
                              !controller.learnArmed
                          ? controller.learn
                          : null,
                      child: Text(AppStrings.t('raw_scanner_learn', loc)),
                    ),
                    OutlinedButton(
                      key: const Key('settings-raw-scanner-reset'),
                      onPressed: controller.available
                          ? controller.resetStats
                          : null,
                      child:
                          Text(AppStrings.t('raw_scanner_reset_stats', loc)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  controller.enabled
                      ? AppStrings.t('raw_scanner_status_on', loc)
                      : AppStrings.t('raw_scanner_status_off', loc),
                  key: const Key('settings-raw-scanner-status'),
                  style: theme.textTheme.bodyMedium,
                ),
                if (controller.learnArmed) ...[
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t('raw_scanner_learn_armed', loc),
                    key: const Key('settings-raw-scanner-learn-status'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ) ??
                        const TextStyle(),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('raw_scanner_layout', loc),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final value in RawScannerDecoder.supportedLayouts)
                      value == controller.layout
                          ? FilledButton(
                              key: Key('settings-raw-scanner-layout-$value'),
                              onPressed: () => controller.setLayout(value),
                              child: Text(
                                AppStrings.t(_layoutLabelKeys[value]!, loc),
                              ),
                            )
                          : OutlinedButton(
                              key: Key('settings-raw-scanner-layout-$value'),
                              onPressed: () => controller.setLayout(value),
                              child: Text(
                                AppStrings.t(_layoutLabelKeys[value]!, loc),
                              ),
                            ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('raw_scanner_learned', loc),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                if (controller.learned.isEmpty)
                  Text(
                    AppStrings.t('raw_scanner_learned_none', loc),
                    key: const Key('settings-raw-scanner-devices-empty'),
                    style: theme.textTheme.bodySmall,
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < controller.learned.length; i++)
                        Tooltip(
                          message: controller.learned[i],
                          child: Chip(
                            key: Key('settings-raw-scanner-device-$i'),
                            label: Text(_deviceLabel(controller.learned[i])),
                            onDeleted: () =>
                                controller.forgetDevice(controller.learned[i]),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(
                  '${AppStrings.t('raw_scanner_raw_seen', loc)}: '
                  '${status.rawSeen}   '
                  '${AppStrings.t('raw_scanner_raw_matched', loc)}: '
                  '${status.rawMatched}\n'
                  '${AppStrings.t('raw_scanner_dropped', loc)}: '
                  '${status.dropped}   '
                  '${AppStrings.t('raw_scanner_passed', loc)}: '
                  '${status.passed}',
                  key: const Key('settings-raw-scanner-counters'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${AppStrings.t('raw_scanner_order_violations', loc)}: '
                  '${status.orderViolations}'
                  '${status.orderDetail.isEmpty ? '' : ' (${status.orderDetail})'}',
                  key: const Key('settings-raw-scanner-order'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  controller.lastScanLength == null
                      ? '${AppStrings.t('raw_scanner_last_scan', loc)}: '
                          '${AppStrings.t('raw_scanner_no_scans', loc)}'
                      : '${AppStrings.t('raw_scanner_last_scan', loc)}: '
                          'len=${controller.lastScanLength}'
                          '  …${controller.lastScanSuffix3}',
                  key: const Key('settings-raw-scanner-last'),
                  style: theme.textTheme.bodySmall,
                ),
                if (!controller.available) ...[
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.t('raw_scanner_unavailable', loc),
                    key: const Key('settings-raw-scanner-unavailable'),
                    style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ) ??
                        const TextStyle(),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Short technical label for a device path: the `VID_…&PID_…` token
  /// (full path stays in the tooltip — long instance paths would drown
  /// the card).
  static String _deviceLabel(String name) {
    final match =
        RegExp(r'VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}').firstMatch(name);
    if (match != null) return match.group(0)!;
    return name.length > 32 ? name.substring(name.length - 32) : name;
  }
}
