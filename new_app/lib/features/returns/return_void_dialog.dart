// Void confirmation dialog (Phase 12, GATE 1 + GATE 9).
//
// A void is TERMINAL and irreversible: the dialog says so in the user's
// language, requires a typed reason (the backend rejects a blank one),
// and the caller only then POSTs /sales/{id}/void. Nothing is written
// locally — success is whatever the server returns.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/strings.dart';

/// Returns the typed reason, or null when the cashier cancels.
Future<String?> showVoidReasonDialog(
  BuildContext context, {
  String? invoiceNumber,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => VoidReasonDialog(invoiceNumber: invoiceNumber),
  );
}

class VoidReasonDialog extends StatefulWidget {
  final String? invoiceNumber;

  const VoidReasonDialog({super.key, this.invoiceNumber});

  @override
  State<VoidReasonDialog> createState() => _VoidReasonDialogState();
}

class _VoidReasonDialogState extends State<VoidReasonDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      // Localized inline message (never a backend string).
      setState(
        () => _error = AppStrings.t(
          'void_reason_required',
          Localizations.localeOf(context).languageCode,
        ),
      );
      return;
    }
    Navigator.pop(context, reason);
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('void-dialog'),
      title: Text(
        AppStrings.t('void_invoice', loc),
        key: const Key('void-dialog-title'),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.invoiceNumber != null &&
                widget.invoiceNumber!.isNotEmpty) ...[
              Text(
                widget.invoiceNumber!,
                key: const Key('void-dialog-invoice'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
            ],
            Text(
              AppStrings.t('void_confirm_question', loc),
              key: const Key('void-dialog-warning'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('void-reason-input'),
              controller: _controller,
              autofocus: true,
              maxLength: 500,
              inputFormatters: [LengthLimitingTextInputFormatter(500)],
              decoration: InputDecoration(
                labelText: AppStrings.t('void_reason_label', loc),
                errorText: _error,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('void-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('void-confirm'),
          onPressed: _submit,
          child: Text(AppStrings.t('void_confirm', loc)),
        ),
      ],
    );
  }
}
