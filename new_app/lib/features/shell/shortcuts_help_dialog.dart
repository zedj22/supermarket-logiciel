// Keyboard shortcuts help surface (Phase 17 §18).
//
// The legacy POS exposed a dozen F-keys and no in-app way to discover them;
// this dialog is the localized map, split into the two scopes it has always
// had: keys the nav shell answers on every screen, and keys the POS
// workspace answers while a sale is open.
//
// Reachable from the shell AppBar and from the POS header (both use the
// same `showShortcutsDialog`). It is documentation only — it never mutates
// cart or page state, and Escape closes it through the normal dialog route
// before any POS binding is ever consulted.
import 'package:flutter/material.dart';

import '../../core/strings.dart';

/// One line of the keyboard map: key combination → action, scope, meaning.
///
/// The key labels are deliberately literal-free at the widget call site so
/// they are not mistaken for user-visible text (they are symbols like
/// `F1`, `Ctrl+N`, `Space` and read the same in every locale).
class _ShortcutRow {
  const _ShortcutRow(this.keys, this.actionKey, this.scopeKey, this.descKey);

  final String keys;
  final String actionKey;
  final String scopeKey;
  final String descKey;
}

const _global = 'shortcuts_scope_global';
const _pos = 'shortcuts_scope_pos';

/// Full map: shell scope first, then the POS scope.
const _shortcutRows = <_ShortcutRow>[
  // --- shell: identical on every screen ---
  _ShortcutRow('F1', 'sc_a_pos', _global, 'sc_d_pos'),
  _ShortcutRow('F2', 'sc_a_products', _global, 'sc_d_products'),
  _ShortcutRow('F3', 'sc_a_add_product', _global, 'sc_d_add_product'),
  _ShortcutRow('Ctrl+N', 'sc_a_add_product', _global, 'sc_d_add_product'),
  _ShortcutRow('F4', 'sc_a_search', _global, 'sc_d_search'),
  _ShortcutRow('Ctrl+F', 'sc_a_search', _global, 'sc_d_search'),
  _ShortcutRow('F5', 'sc_a_refresh', _global, 'sc_d_refresh'),
  _ShortcutRow('Esc', 'sc_a_close', _global, 'sc_d_close'),
  // --- POS workspace: only while a sale is open ---
  _ShortcutRow('Enter', 'sc_a_add_search', _pos, 'sc_d_add_search'),
  _ShortcutRow('F6', 'sc_a_customer', _pos, 'sc_d_customer'),
  _ShortcutRow('F7', 'sc_a_invoice_discount', _pos, 'sc_d_invoice_discount'),
  _ShortcutRow('Space', 'sc_a_payment', _pos, 'sc_d_payment'),
  _ShortcutRow('F9', 'sc_a_hold', _pos, 'sc_d_hold'),
  _ShortcutRow('F10', 'sc_a_held_sales', _pos, 'sc_d_held_sales'),
  _ShortcutRow('F11', 'sc_a_sales_history', _pos, 'sc_d_sales_history'),
  _ShortcutRow('F12', 'sc_a_clear_cart', _pos, 'sc_d_clear_cart'),
  _ShortcutRow('+', 'sc_a_qty_inc', _pos, 'sc_d_qty_inc'),
  _ShortcutRow('-', 'sc_a_qty_dec', _pos, 'sc_d_qty_dec'),
  _ShortcutRow('*', 'sc_a_qty_entry', _pos, 'sc_d_qty_entry'),
];

/// Opens the localized keyboard-shortcuts map.
void showShortcutsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const ShortcutsHelpDialog(),
  );
}

class ShortcutsHelpDialog extends StatelessWidget {
  const ShortcutsHelpDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    Widget head(String key) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            AppStrings.t(key, loc),
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        );

    Widget cell(String text, {bool bold = false}) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
          child: Text(
            text,
            style: bold
                ? theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700)
                : theme.textTheme.bodyMedium,
          ),
        );

    return AlertDialog(
      key: const Key('shortcuts-dialog'),
      title: Text(AppStrings.t('shortcuts_title', loc)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Table(
            columnWidths: const {
              0: FixedColumnWidth(78),
              1: FixedColumnWidth(140),
              2: FixedColumnWidth(78),
              3: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                children: [
                  head('shortcuts_col_key'),
                  head('shortcuts_col_action'),
                  head('shortcuts_col_scope'),
                  head('shortcuts_col_desc'),
                ],
              ),
              for (final row in _shortcutRows)
                TableRow(
                  children: [
                    cell(row.keys, bold: true),
                    cell(AppStrings.t(row.actionKey, loc)),
                    cell(AppStrings.t(row.scopeKey, loc)),
                    cell(AppStrings.t(row.descKey, loc)),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('shortcuts-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('close', loc)),
        ),
      ],
    );
  }
}
