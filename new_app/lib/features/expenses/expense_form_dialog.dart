// Expense editor dialog (Phase 13): record one money-out.
//
// The client sends ONLY what the backend accepts — title (optional,
// Fix Round 2), category, amount, paid_from_drawer, note and the
// per-open `client_request_id`
// (GATE 10: one key per dialog open makes a retry submit idempotent).
// `id` / `expense_date` / `user_id` / `status` are server-assigned and are
// never sent (B6/B7), so backdating from this UI is impossible (GATE 6).
//
// Amount validation is client-side convenience only: the schema is the
// authority (`0 < amount <= MONEY_MAX`, max 3 decimals — exact integer
// milli math, never a float).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../clients/customer_models.dart';
import 'expense_models.dart';
import 'expenses_providers.dart';

/// Returns the created expense (with `idempotentReplay`), or null when the
/// cashier backs out.
Future<ExpenseItem?> showExpenseFormDialog(BuildContext context) {
  return showDialog<ExpenseItem>(
    context: context,
    builder: (_) => const ExpenseFormDialog(),
  );
}

class ExpenseFormDialog extends ConsumerStatefulWidget {
  const ExpenseFormDialog({super.key});

  @override
  ConsumerState<ExpenseFormDialog> createState() => _ExpenseFormDialogState();
}

class _ExpenseFormDialogState extends ConsumerState<ExpenseFormDialog> {
  late final TextEditingController _title;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late final String _clientRequestId;

  String _category = kExpenseCategories.first;
  bool _paidFromDrawer = true; // legacy default (`paid_from_drawer = 1`)
  bool _saving = false;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _amount = TextEditingController();
    _note = TextEditingController();
    _clientRequestId =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  // ── Validation (client-side convenience, server stays authoritative) ──

  String? _validate(String loc) {
    // Title is OPTIONAL (Fix Round 2 / B1): an empty field is valid and
    // simply sends no title. Only the money value can block the POST.
    final milli = moneyToMilli(_amount.text);
    if (milli == null || milli <= 0) {
      return AppStrings.t('expense_amount_invalid', loc);
    }
    return null;
  }

  // ── Payload ──────────────────────────────────────────────────────────

  Map<String, dynamic> _payload() {
    final note = _note.text.trim();
    final title = _title.text.trim();
    return {
      'client_request_id': _clientRequestId,
      // Optional (B1): omitted when blank — never an invented default.
      if (title.isNotEmpty) 'title': title,
      'category': _category,
      'amount': milliToMoney(moneyToMilli(_amount.text)!),
      'paid_from_drawer': _paidFromDrawer,
      if (note.isNotEmpty) 'note': note,
    };
  }

  Future<void> _submit() async {
    if (_saving) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final validation = _validate(loc);
    if (validation != null) {
      setState(() {
        _error = validation;
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _errorDetail = null;
    });

    final (expense, error) =
        await ref.read(expensesApiProvider).create(payload: _payload());
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error.message;
        _errorDetail = error.detail;
      });
      return;
    }
    Navigator.pop(context, expense);
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('expense-form-dialog'),
      title: Text(
        AppStrings.t('expense_add', loc),
        key: const Key('expense-form-title'),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('expense-form-title-input'),
              controller: _title,
              enabled: !_saving,
              autofocus: true,
              maxLength: 200,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: AppStrings.t('expense_title_label', loc),
                hintText: AppStrings.t('expense_title_hint', loc),
                counterText: '',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('expense-form-category'),
              initialValue: _category,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: AppStrings.t('expense_category_label', loc),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final code in kExpenseCategories)
                  DropdownMenuItem(
                    value: code,
                    child: Text(
                      AppStrings.t(expenseCategoryKey(code), loc),
                      key: Key('expense-form-category-$code'),
                    ),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                        _category = value ?? _category;
                        _error = null;
                        _errorDetail = null;
                      }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('expense-form-amount'),
              controller: _amount,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                LengthLimitingTextInputFormatter(15),
              ],
              decoration: InputDecoration(
                labelText: AppStrings.t('expense_amount_label', loc),
                hintText: AppStrings.t('expense_amount_hint', loc),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('expense-form-drawer'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                AppStrings.t(
                  _paidFromDrawer
                      ? 'expense_paid_from_drawer'
                      : 'expense_paid_external',
                  loc,
                ),
                key: const Key('expense-form-drawer-label'),
              ),
              value: _paidFromDrawer,
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                        _paidFromDrawer = value;
                        _error = null;
                        _errorDetail = null;
                      }),
            ),
            TextField(
              key: const Key('expense-form-note'),
              controller: _note,
              enabled: !_saving,
              maxLength: 2000,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: AppStrings.t('expense_note_label', loc),
                counterText: '',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('expense-form-error'),
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              if (_errorDetail != null && _errorDetail!.isNotEmpty)
                Text(
                  _errorDetail!,
                  key: const Key('expense-form-error-detail'),
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('expense-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('expense-form-save'),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('expense_submit', loc)),
        ),
      ],
    );
  }
}
