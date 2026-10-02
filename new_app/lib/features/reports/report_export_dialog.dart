// Export format selection dialog (Phase 15 roadmap: "Export format
// selection", §19.2).
//
// One export button → three formats:
//   CSV  → the frozen Phase 14 client-side builder (§11.3 / G10),
//   XLSX → `POST /api/v1/exports` (server-rendered, §12.1),
//   PDF  → `POST /api/v1/exports` (server-rendered, §12.1).
//
// Returning `null` means the user cancelled — neutral, no toast (§16.2).
import 'package:flutter/material.dart';

import '../../core/strings.dart';

/// Returns `'csv'` | `'xlsx'` | `'pdf'`, or `null` when cancelled.
Future<String?> showReportExportDialog(BuildContext context, String loc) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('export-format-dialog'),
      title: Text(AppStrings.t('export_title', loc)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OptionButton(
              format: 'csv',
              labelKey: 'export_csv',
              icon: Icons.table_view_outlined,
              loc: loc,
            ),
            _OptionButton(
              format: 'xlsx',
              labelKey: 'export_xlsx',
              icon: Icons.grid_on_outlined,
              loc: loc,
            ),
            _OptionButton(
              format: 'pdf',
              labelKey: 'export_pdf',
              icon: Icons.picture_as_pdf_outlined,
              loc: loc,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('export-format-cancel'),
          // Pop via the DIALOG's context: the caller's context resolves
          // the router's page navigator, which would pop a PAGE instead
          // of this dialog (go_router asserts on the empty match list).
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    ),
  );
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.format,
    required this.labelKey,
    required this.icon,
    required this.loc,
  });

  final String format;
  final String labelKey;
  final IconData icon;
  final String loc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OutlinedButton.icon(
        key: Key('export-format-$format'),
        onPressed: () => Navigator.of(context).pop(format),
        icon: Icon(icon, size: 18),
        label: Text(AppStrings.t(labelKey, loc)),
      ),
    );
  }
}
