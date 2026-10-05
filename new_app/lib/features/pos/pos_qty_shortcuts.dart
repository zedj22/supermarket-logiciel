// POS quantity shortcuts (Phase 8): `+`, `-` and `*`.
//
// `+` increments / `-` decrements the last active cart line by exactly 1;
// `*` opens the quantity INPUT dialog for that line, where the entered
// number REPLACES the current quantity (24, `*`, 3 → 3 — never a product).
// All three:
//   - match the *character* the key produced (`+` / `-` / `*`) so any
//     layout works, plus the dedicated numpad keys (and the main-row keys
//     when no character is delivered);
//   - are claimed while the POS search field or a cart quantity field has
//     focus (the cashier can just keep typing — the key must never be
//     *inserted* there, it acts on the active line instead);
//   - never fire while any OTHER text input has focus (dialogs, pickers,
//     invoices keep normal typing);
//   - apply quantity and stock validation through
//     `pos_quantity.dart` (one shared rule for every mutation path).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/keyboard.dart';

/// Which quantity shortcut a [PosQtyShortcutActivator] matches.
enum PosQtyShortcutKind { increment, decrement, quantityEntry }

/// Text-field keys that are allowed to hand `+` back to the POS shortcut.
/// Anything else (option pickers, dialogs, …) keeps the key as typed.
const String posSearchFieldKey = 'pos-search-field';

/// True when [key] is a cart line quantity field key (`cart-line-qty-*`).
bool isCartLineQtyFieldKey(String key) => key.startsWith('cart-line-qty-');

/// [ShortcutActivator] for the POS quantity shortcuts.
///
/// A single activator instance per action guarantees the shortcut callback
/// runs at most once per key event (`CallbackShortcuts` invokes *every*
/// activator that accepts an event).
class PosQtyShortcutActivator extends ShortcutActivator {
  const PosQtyShortcutActivator(this.kind);

  final PosQtyShortcutKind kind;

  /// `+` / `-` / `*` are produced by different physical keys per layout
  /// (`=`, `-`, `8`, numpad, …), so every key event is inspected.
  @override
  Iterable<LogicalKeyboardKey>? get triggers => null;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (!matchesEvent(kind, event)) return false;
    switch (kind) {
      case PosQtyShortcutKind.increment:
      case PosQtyShortcutKind.decrement:
      case PosQtyShortcutKind.quantityEntry:
        // `+` / `-` / `*` may be typed straight into the POS search field
        // and into the focused cart quantity field — they must act on the
        // active line there instead of inserting the character (human QA:
        // "focused on search — + does not increment"; `*` must open the
        // quantity dialog from both fields). One identical focus rule for
        // the three keys, so they always resolve the same active line.
        return !editableTextHasFocus() || _focusIsPosQuantityInput();
    }
  }

  /// True when the focused text input is one of the POS quantity inputs
  /// identified by [posSearchFieldKey] / [isCartLineQtyFieldKey].
  ///
  /// Walks from the primary focus to the enclosing [TextField] and reads
  /// its `ValueKey<String>` — any other text field (dialogs, pickers,
  /// invoices) keeps normal typing behavior.
  static bool _focusIsPosQuantityInput() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    TextField? field;
    if (context.widget is TextField) {
      field = context.widget as TextField;
    } else {
      field = context.findAncestorWidgetOfExactType<TextField>();
    }
    if (field == null) return false;
    final key = field.key;
    if (key is! ValueKey<String>) return false;
    return key.value == posSearchFieldKey || isCartLineQtyFieldKey(key.value);
  }

  /// Pure key-event matcher (no focus rules) — shared by tests.
  static bool matchesEvent(PosQtyShortcutKind kind, KeyEvent event) {
    switch (kind) {
      case PosQtyShortcutKind.increment:
        // Key down and key repeat: holding `+` keeps adding units.
        if (event is KeyUpEvent) return false;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return false;
        }
        return _isPlusEvent(event);
      case PosQtyShortcutKind.decrement:
        // Key down and key repeat: holding `-` keeps removing units.
        if (event is KeyUpEvent) return false;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return false;
        }
        return _isMinusEvent(event);
      case PosQtyShortcutKind.quantityEntry:
        // Key down only — the dialog must open exactly once.
        if (event is! KeyDownEvent) return false;
        return event.character == '*' ||
            event.logicalKey == LogicalKeyboardKey.asterisk ||
            event.logicalKey == LogicalKeyboardKey.numpadMultiply;
    }
  }

  /// The cashier's `+`, from every source a Windows layout can produce it:
  ///  1. the `+` character the key produced (any layout, main row or not);
  ///  2. the dedicated numpad add key;
  ///  3. the main row `=` key with Shift held, when the platform hands the
  ///     event no character at all — the old matcher accepted only (1) and
  ///     (2), so that press fell through to the text input and *inserted*
  ///     a `+` instead of incrementing.
  ///
  /// (3) needs both a characterless event and a held Shift, so a plain `=`
  /// (or a layout that really types another character there) is never
  /// hijacked. One matcher → one activation path, no second shortcut system.
  static bool _isPlusEvent(KeyEvent event) {
    if (event.character == '+') return true;
    if (event.logicalKey == LogicalKeyboardKey.numpadAdd) return true;
    final character = event.character;
    if (character != null && character.isNotEmpty) return false;
    if (event.logicalKey != LogicalKeyboardKey.equal) return false;
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);
  }

  /// The cashier's `-`, from every source a Windows layout can produce it:
  ///  1. the `-` character the key produced (US main row `minus`, AZERTY
  ///     Shift-less `-`, …);
  ///  2. the dedicated numpad subtract key;
  ///  3. the main row `minus` key when the platform hands the event no
  ///     character at all — without this the press falls through to the
  ///     text input and *inserts* a `-` instead of decrementing.
  ///
  /// (3) needs a characterless event, so a layout that really types
  /// another character there keeps its key. Same shape as [_isPlusEvent]:
  /// one matcher → one activation path, no second shortcut system.
  static bool _isMinusEvent(KeyEvent event) {
    if (event.character == '-') return true;
    if (event.logicalKey == LogicalKeyboardKey.numpadSubtract) return true;
    final character = event.character;
    if (character != null && character.isNotEmpty) return false;
    return event.logicalKey == LogicalKeyboardKey.minus;
  }

  @override
  String debugDescribeKeys() => switch (kind) {
        PosQtyShortcutKind.increment => "'+'",
        PosQtyShortcutKind.decrement => "'-'",
        PosQtyShortcutKind.quantityEntry => "'*'",
      };
}

/// Quantity text used everywhere a cart quantity is written back
/// (`1` not `1.0`; trailing decimals preserved as typed).
String posQtyText(double value) {
  final rounded = value.roundToDouble();
  return value == rounded ? value.toInt().toString() : value.toString();
}
