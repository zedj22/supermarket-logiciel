// Phase A — the Scan diagnostics card in Settings.
//
// A session control surface for [ScanCaptureRecorder]: Start / Stop /
// Clear / Copy report, a live summary (status, counters, the category
// legend, the gateway's live buffer/armed state) and the privacy note.
//
// Rules the widget itself enforces:
//  * no TextField anywhere — nothing can take keyboard focus from a
//    scanner or an operator mid-diagnosis;
//  * no autofocus, no Focus nodes, no requestFocus calls;
//  * every user-visible string goes through AppStrings.t (en/ar/fr);
//  * Copy report writes ONLY [ScanCaptureRecorder.buildExport]'s redacted
//    text to the clipboard — never raw event objects.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/barcode_scanner.dart';
import '../../core/scan_capture_recorder.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';

/// The Scan diagnostics card. Rendered for every operator (like the scan
/// action toggles): it is an observation tool, not a store setting, and
/// it never talks to the backend.
class ScanDiagnosticsSection extends ConsumerWidget {
  const ScanDiagnosticsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final recorder = ref.watch(scanCaptureRecorderProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: recorder,
          builder: (context, _) {
            final gateway = BarcodeScannerGateway.instance;
            final active = recorder.isActive;
            final total = recorder.totalEvents;
            final dropped = recorder.droppedEvents;
            final counts = recorder.categoryCounts;
            final hasEvents = total > 0;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.t('settings_scan_diagnostics', loc),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  AppStrings.t('scan_diagnostics_desc', loc),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('settings-scan-diag-start'),
                      onPressed: active ? null : recorder.start,
                      child: Text(AppStrings.t('scan_diagnostics_start', loc)),
                    ),
                    FilledButton.tonal(
                      key: const Key('settings-scan-diag-stop'),
                      onPressed: active ? recorder.stop : null,
                      child: Text(AppStrings.t('scan_diagnostics_stop', loc)),
                    ),
                    OutlinedButton(
                      key: const Key('settings-scan-diag-clear'),
                      onPressed: hasEvents ? recorder.clear : null,
                      child: Text(AppStrings.t('scan_diagnostics_clear', loc)),
                    ),
                    OutlinedButton(
                      key: const Key('settings-scan-diag-copy'),
                      onPressed: hasEvents
                          ? () => _copyReport(context, loc, recorder)
                          : null,
                      child: Text(AppStrings.t('scan_diagnostics_copy', loc)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  active
                      ? AppStrings.t('scan_diagnostics_status_running', loc)
                      : AppStrings.t('scan_diagnostics_status_idle', loc),
                  key: const Key('settings-scan-diag-status'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${AppStrings.t('scan_diagnostics_total', loc)}: $total'
                  '   ${AppStrings.t('scan_diagnostics_dropped', loc)}: $dropped',
                  key: const Key('settings-scan-diag-counts'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${AppStrings.t('scan_diagnostics_gateway_buffer', loc)}:'
                  ' ${gateway.bufferedDigitCount}'
                  '  ·  ${AppStrings.t(
                    gateway.isCaptureArmed
                        ? 'scan_diagnostics_armed'
                        : 'scan_diagnostics_disarmed',
                    loc,
                  )}',
                  key: const Key('settings-scan-diag-gateway'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (!hasEvents)
                  Text(
                    AppStrings.t('scan_diagnostics_no_events', loc),
                    key: const Key('settings-scan-diag-empty'),
                    style: theme.textTheme.bodySmall,
                  )
                else
                  // The unordered legend: category id → count. Technical
                  // identifiers on purpose — identical to the export.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in counts.entries)
                        Text(
                          '${entry.key}: ${entry.value}',
                          key: Key('settings-scan-diag-cat-${entry.key}'),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _copyReport(
    BuildContext context,
    String loc,
    ScanCaptureRecorder recorder,
  ) async {
    await Clipboard.setData(ClipboardData(text: recorder.buildExport()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('scan_diagnostics_copied', loc))),
    );
  }
}
