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
//
// Layout: three columns of one table — the key, the action it triggers
// (with its one-line meaning underneath, so no column is skipped), and the
// scope the binding is live in.  The column widths are declared once and
// shared by the header row and every body row, and the body scrolls inside
// a height that tracks the window, so the map never overflows at 800×600
// nor stacks Arabic characters in a 78px cell.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/shortcuts.dart';
import '../../core/strings.dart';
import '../settings/pos_settings_provider.dart';

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
  // The key symbols come from PosShortcutKeys — the SAME table the
  // on-button badges render — so the map, the badges and the registered
  // CallbackShortcuts bindings can never drift apart.
  _ShortcutRow('Enter', 'sc_a_add_search', _pos, 'sc_d_add_search'),
  _ShortcutRow(PosShortcutKeys.chooseCustomer, 'sc_a_customer', _pos, 'sc_d_customer'),
  _ShortcutRow(PosShortcutKeys.addCustomer, 'add_client', _pos, 'sc_d_add_customer'),
  _ShortcutRow(PosShortcutKeys.invoiceDiscount, 'sc_a_invoice_discount', _pos, 'sc_d_invoice_discount'),
  _ShortcutRow(PosShortcutKeys.useLoyaltyPoints, 'loyalty_redeem', _pos, 'sc_d_use_points'),
  _ShortcutRow(PosShortcutKeys.payment, 'sc_a_payment', _pos, 'sc_d_payment'),
  _ShortcutRow(PosShortcutKeys.hold, 'sc_a_hold', _pos, 'sc_d_hold'),
  _ShortcutRow(PosShortcutKeys.holds, 'sc_a_held_sales', _pos, 'sc_d_held_sales'),
  _ShortcutRow(PosShortcutKeys.history, 'sc_a_sales_history', _pos, 'sc_d_sales_history'),
  _ShortcutRow(PosShortcutKeys.clearCart, 'sc_a_clear_cart', _pos, 'sc_d_clear_cart'),
  _ShortcutRow('+', 'sc_a_qty_inc', _pos, 'sc_d_qty_inc'),
  _ShortcutRow('-', 'sc_a_qty_dec', _pos, 'sc_d_qty_dec'),
  _ShortcutRow('*', 'sc_a_qty_entry', _pos, 'sc_d_qty_entry'),
];

/// Column geometry, shared by the header and every body row so labels can
/// never drift away from their cells.
const double _keyColumn = 96;
const double _scopeColumn = 132;
const double _columnGap = 12;

double _clamp(double value, double low, double high) =>
    value < low ? low : (value > high ? high : value);

/// Opens the localized keyboard-shortcuts map.
void showShortcutsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const ShortcutsHelpDialog(),
  );
}

class ShortcutsHelpDialog extends ConsumerWidget {
  const ShortcutsHelpDialog({super.key});

  /// The Space row describes what the key actually DOES: the ordinary
  /// payment dialog, or — when the operator preference is on — the
  /// direct quick sale (full cash payment of the amount due, no dialog).
  /// The map is documentation only, so it simply mirrors the setting.
  static _ShortcutRow _effectiveRow(_ShortcutRow row, bool quickSale) {
    if (!quickSale || row.keys != PosShortcutKeys.payment) return row;
    return _ShortcutRow(row.keys, 'sc_a_quick_sale', row.scopeKey, 'sc_d_quick_sale');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final view = MediaQuery.sizeOf(context);
    final quickSale = ref.watch(posSettingsProvider).quickSaleWithSpace;

    // Responsive sizing: the map grows with the window but always stays
    // inside the dialog's 40px inset, and the body height is what is left
    // after the title and the close button — so nothing is ever pushed
    // off-screen, including at the smallest supported 800×600.
    final width = _clamp(view.width - 112, 340, 760);
    final bodyHeight = _clamp(view.height - 230, 220, 540);

    Widget column({double? width, required Widget child}) => width == null
        ? Expanded(child: child)
        : SizedBox(width: width, child: child);

    Widget head(String key, {double? width}) => column(
          width: width,
          child: Text(
            AppStrings.t(key, loc),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: theme.colorScheme.primary,
            ),
          ),
        );

    Widget keyBadge(String keys) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
          ),
          child: Text(
            keys,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: cs.primary,
            ),
          ),
        );

    Widget scopeChip(String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: cs.outline.withValues(alpha: 0.28)),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        );

    // Identical geometry for the header and every body row.
    Widget cells({required List<Widget> children}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );

    Widget headerRow() => cells(
          children: [
            head('shortcuts_col_key', width: _keyColumn),
            const SizedBox(width: _columnGap),
            head('shortcuts_col_action'),
            const SizedBox(width: _columnGap),
            head('shortcuts_col_scope', width: _scopeColumn),
          ],
        );

    Widget bodyRow(_ShortcutRow row) => cells(
          children: [
            column(width: _keyColumn, child: keyBadge(row.keys)),
            const SizedBox(width: _columnGap),
            column(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.t(row.actionKey, loc),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    AppStrings.t(row.descKey, loc),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.3,
                      color: cs.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: _columnGap),
            column(
              width: _scopeColumn,
              child: scopeChip(AppStrings.t(row.scopeKey, loc)),
            ),
          ],
        );

    return AlertDialog(
      key: const Key('shortcuts-dialog'),
      title: Text(AppStrings.t('shortcuts_title', loc)),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      content: SizedBox(
        key: const Key('shortcuts-dialog-content'),
        width: width,
        height: bodyHeight,
        child: Column(
          children: [
            headerRow(),
            Divider(height: 1, thickness: 1, color: cs.outline.withValues(alpha: 0.4)),
            Expanded(
              // Eager, not a `ListView`: every row of the map is a real
              // widget even when it sits below the fold (the help tests —
              // and Ctrl+F — look for a key that is not on screen).
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _shortcutRows.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          color: cs.outline.withValues(alpha: 0.14),
                        ),
                      bodyRow(_effectiveRow(_shortcutRows[i], quickSale)),
                    ],
                  ],
                ),
              ),
            ),
          ],
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
