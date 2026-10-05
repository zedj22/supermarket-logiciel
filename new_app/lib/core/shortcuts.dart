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
