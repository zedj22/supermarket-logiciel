// Page-level shortcut hooks published to the nav shell (Phase 17 §18).
//
// The shell owns the keys that mean the same thing on every screen — F1/F2
// (routes), F3/Ctrl+N (add product), F4/Ctrl+F (focus *this* page's search
// box) and F5 (refresh *this* page). The last two cannot be written in the
// shell: only the mounted page knows which field to focus and which lists
// are safe to reload.
//
// A screen registers its hooks in `initState` and clears them in `dispose`.
// The callbacks are pure UI actions — none of them may ever mutate a cart,
// an unsaved form or any other in-progress user state, so a global key can
// never destroy work the cashier has not confirmed yet.
import 'package:flutter/foundation.dart';

class PageShortcuts {
  const PageShortcuts({this.focusSearch, this.refresh});

  /// Focus the page's search / barcode field (F4, Ctrl+F).
  final VoidCallback? focusSearch;

  /// Reload the page's read-only lists (F5). Must never touch the cart.
  final VoidCallback? refresh;
}

/// Process-wide pointer to the hooks of the page that is on screen.
///
/// Deliberately a plain static (not a provider): shortcut dispatch is a
/// synchronous widget-layer concern and must work in tests that pump a
/// screen without the surrounding router. Single entry — screens replace it
/// on push and clear it only if they still own it, so a stale screen can
/// never hijack the keys of the one that replaced it.
class PageShortcutsRegistry {
  static PageShortcuts? current;
}

/// Canonical key LABELS for the POS bindings registered in pos_screen's
/// `CallbackShortcuts` (Phase 17 §18).
///
/// This is a label table, NOT a second shortcut system: the keys stay
/// registered exactly where they always were (pos_screen.dart), and the
/// action they trigger lives there too. The shortcuts help dialog and the
/// on-button `ShortcutBadge`s render these same strings, so a badge can
/// never document a key the page does not answer — change a binding and
/// this table is the one place the displayed text is updated.
///
/// The symbols are literal and never localized: `F6` reads the same in
/// ar/fr/en (and must keep its LTR run inside an RTL layout).
abstract final class PosShortcutKeys {
  /// F6 — choose customer (the picker).
  static const chooseCustomer = 'F6';

  /// Shift+F6 — add customer (the shared client form, no picker first).
  static const addCustomer = 'Shift+F6';

  /// F7 — invoice discount.
  static const invoiceDiscount = 'F7';

  /// Shift+F7 — use loyalty points (the redemption dialog).
  static const useLoyaltyPoints = 'Shift+F7';

  /// Space / F8 — open payment. Both keys run the ONE payment action
  /// (the F8 binding is the legacy key restored beside Space). While
  /// Quick sale (Space) is ON they BOTH complete the sale directly
  /// instead; the help map swaps the row's meaning for that setting and
  /// the PAY badge follows it the same way. The label is literal like
  /// every other key in this table (never localized).
  static const payment = 'Space / F8';

  /// F9 — hold the current sale.
  static const hold = 'F9';

  /// F10 — held sales list.
  static const holds = 'F10';

  /// F11 — sales history.
  static const history = 'F11';

  /// F12 — clear cart (confirm dialog).
  static const clearCart = 'F12';

  /// Ctrl+N — quick product picker (searchable, keyboard-first window).
  /// Free at the POS layer: the shell owns F1–F5 and F3 / Ctrl+N (the
  /// add-product form), and while a modal route is open its focus scope
  /// keeps the keys, so the page binding never fires behind a dialog.
  static const productPicker = 'Ctrl+N';
}
