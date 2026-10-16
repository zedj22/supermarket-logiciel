// Expense cancellation dialog (Phase 13, GATE 1 + GATE 11).
//
// Cancelling is TERMINAL and irreversible: the dialog says so in the
// user's language, requires a typed reason (the backend rejects a blank
// one with 422), and only then POSTs /expenses/{id}/cancel. Nothing is
// deleted — the row keeps its amount and gains the cancellation
// attribution (legacy defect L3: hard delete).
//
// The pop uses THIS dialog's own context (Phase 12 fix round): the shell
// route owns a nested navigator, so popping from the screen's context
// would pop the page itself.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../clients/customer_models.dart';
import 'expense_models.dart';
import 'expenses_providers.dart';

/// Returns the cancelled expense, or null when the cashier backs out.
Future<ExpenseItem?> showExpenseCancelDialog(
  BuildContext context, {
  required ExpenseItem expense,
}) {
  return showDialog<ExpenseItem>(
    context: context,
    builder: (_) => ExpenseCancelDialog(expense: expense),
  );
}

class ExpenseCancelDialog extends ConsumerStatefulWidget {
  final ExpenseItem expense;

  const ExpenseCancelDialog({super.key, required this.expense});

  @override
  ConsumerState<ExpenseCancelDialog> createState() =>
      _ExpenseCancelDialogState();
}

class _ExpenseCancelDialogState extends ConsumerState<ExpenseCancelDialog> {
  final _controller = TextEditingController();
  String? _error;
  String? _errorDetail;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      // Localized inline message (never a backend string).
      setState(() {
        _error = AppStrings.t('reason_required', loc);
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _errorDetail = null;
    });

    final (cancelled, error) = await ref.read(expensesApiProvider).cancel(
          expenseId: widget.expense.id,
          reason: reason,
        );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error.message;
        _errorDetail = error.detail;
      });
      return;
    }
    Navigator.pop(context, cancelled);
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final expense = widget.expense;

    return AlertDialog(
      key: const Key('expense-cancel-dialog'),
      title: Text(
        AppStrings.t('expense_cancel_title', loc),
        key: const Key('expense-cancel-title'),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              expenseTitleLabel(expense, loc),
              key: const Key('expense-cancel-item-title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            // Bidi: the Arabic category label stays natural; the grouped
            // amount is one LTR isolate (forced-LTR whole-string still
            // reverses it — W7).
            Text(
              '${AppStrings.t(expenseCategoryKey(expense.category), loc)} · '
              '${bidiIsolateLtr(formatMoney(expense.amount))}',
              key: const Key('expense-cancel-item-meta'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('expense_cancel_confirm', loc),
              key: const Key('expense-cancel-warning'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('expense-cancel-reason-input'),
              controller: _controller,
              autofocus: true,
              enabled: !_saving,
              maxLength: 200,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: InputDecoration(
                labelText: AppStrings.t('reason', loc),
                errorText: _error,
                border: const OutlineInputBorder(),
                isDense: true,
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_errorDetail != null && _errorDetail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _errorDetail!,
                  key: const Key('expense-cancel-error-detail'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('expense-cancel-dismiss'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('expense-cancel-confirm'),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('expense_cancel_action', loc)),
        ),
      ],
    );
  }
}
