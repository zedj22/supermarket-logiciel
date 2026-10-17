// POS quantity shortcuts (Phase 8): `+`, `-` and `*`.
//
// `+` increments / `-` decrements the last active cart line by exactly 1;
// `*` opens the quantity INPUT dialog for that line, where the entered
// number REPLACES the current quantity (24, `*`, 3 → 3 — never a product).
// All three:
//   - match the *character* the key produced (`+` / `-` / `*`) so any
//     layout works, plus the dedicated numpad keys (and the main-row keys
//     when no character is delivered);
//   - are claimed while the POS search field or ANY cart-line text field
//     (quantity or discount) has focus (the cashier can just keep typing —
//     the key must never be *inserted* there, it acts on the active line
//     instead), so a selected line stays shortcut-reachable even when its
//     quantity field is not the focused one;
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

/// True when [key] is ANY cart-line text field key — quantity
/// (`cart-line-qty-*`) or line discount (`cart-line-discount-*`).
///
/// The `+` / `-` / `*` shortcuts claim their key from every field of the
/// cart: a discount never needs those characters, and a selected line must
/// stay reachable even when the cashier last touched its discount (or a
/// sibling's field). Dialogs, pickers and invoice inputs carry other keys
/// and keep normal typing.
bool isCartLineTextFieldKey(String key) =>
    isCartLineQtyFieldKey(key) || key.startsWith('cart-line-discount-');

/// `ValueKey<String>` of the POS text field the primary focus sits in —
/// [posSearchFieldKey] or a cart-line field key (quantity / discount) —
/// else null (dialogs, pickers and every other input keep their own key or
/// none at all).
///
/// Walks from the primary focus to the enclosing [TextField] and reads its
/// `ValueKey<String>`; one shared walk for the focus rules below, so the
/// `+` / `-` / `*` shortcuts and the SPACE payment shortcut can never
/// disagree about which field is focused.
String? focusedPosTextFieldKey() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  TextField? field;
  if (context.widget is TextField) {
    field = context.widget as TextField;
  } else {
    field = context.findAncestorWidgetOfExactType<TextField>();
  }
  final key = field?.key;
  return key is ValueKey<String> ? key.value : null;
}

/// True while a cart line quantity field holds primary focus — the field
/// every add auto-focuses (Phase 8 FIX #1).
///
/// SPACE is the POS payment shortcut there: the key opens the payment dialog
/// and is consumed before the quantity text input can see it, so a stray
/// space can never change what is on screen. The search field and every
/// other text field are deliberately NOT included — they keep SPACE as an
/// ordinary character (the ONE exception is the EMPTY barcode field below,
/// see [posFocusRouting]).
bool cartQtyFieldHasFocus() {
  final key = focusedPosTextFieldKey();
  return key != null && isCartLineQtyFieldKey(key);
}

/// What the primary focus means for the POS page's keyboard shortcuts.
///
/// ONE shared routing answer, so `+` / `-` / `*`, Delete and SPACE can never
/// disagree about whether the cashier is typing into a field or simply has
/// focus parked somewhere idle (the barcode-ready home state).
enum PosFocusRouting {
  /// No editable field has primary focus: the workspace node, cart-row
  /// taps, buttons — every page shortcut may claim its key.
  noEditable,

  /// The POS search / barcode field is focused and EMPTY — the cashier has
  /// not started typing a query (autofocus home, Escape, post-payment
  /// flow). Barcode scanning is ready, but nothing is being edited, so the
  /// page's shortcuts (SPACE, Delete) may claim their keys here.
  searchIdle,

  /// The POS search field is focused and has text — a product query or a
  /// scanned code is being typed; the field keeps every key as text.
  searchTyping,

  /// A cart line QUANTITY field is focused.
  cartQty,

  /// Another cart-line text field (line discount) is focused.
  cartField,

  /// Any other editable — dialog, picker, invoice, customer, payment input.
  /// Plain typing, never hijacked.
  otherEditable,
}

EditableText? _focusedEditableText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  if (context.widget is EditableText) return context.widget as EditableText;
  return context.findAncestorWidgetOfExactType<EditableText>();
}

/// The single shared focus-routing helper for the POS page keys: resolves
/// [FocusManager.instance.primaryFocus] into a [PosFocusRouting] state
/// (walks the same chain as [focusedPosTextFieldKey], plus the focused
/// field's text so the barcode field can be told apart from a typed query).
PosFocusRouting posFocusRouting() {
  if (!editableTextHasFocus()) return PosFocusRouting.noEditable;
  final key = focusedPosTextFieldKey();
  if (key == posSearchFieldKey) {
    final text = _focusedEditableText()?.controller.text ?? '';
    return text.isEmpty
        ? PosFocusRouting.searchIdle
        : PosFocusRouting.searchTyping;
  }
  if (key == null) return PosFocusRouting.otherEditable;
  if (isCartLineQtyFieldKey(key)) return PosFocusRouting.cartQty;
  if (isCartLineTextFieldKey(key)) return PosFocusRouting.cartField;
  return PosFocusRouting.otherEditable;
}

/// SPACE may take the key while the focus sits in a POS-owned field that is
/// NOT being typed in: the cart quantity field (Phase 8 — the pay key can
/// never corrupt a quantity) or the EMPTY barcode field (barcode-ready
/// home: a row may be selected, SPACE must still pay). A typed query, a
/// discount, dialogs and pickers keep SPACE as ordinary text.
bool spaceMayClaimFocusedField() => switch (posFocusRouting()) {
      PosFocusRouting.searchIdle || PosFocusRouting.cartQty => true,
      _ => false,
    };

/// Delete may take the key while the focus sits in the EMPTY barcode field
/// (idle — not typing), so the selected line stays removable from the
/// cashier's home state. A typed query or ANY cart-line field being edited
/// keeps Delete as its text-editing meaning.
bool deleteMayClaimFocusedField() =>
    posFocusRouting() == PosFocusRouting.searchIdle;

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
        // (idle barcode home OR a query being typed) and into ANY focused
        // cart-line field (quantity or discount) — they must act on the
        // active line there instead of inserting the character. Dialogs,
        // pickers and every other input route as plain typing and never
        // fire (one shared [posFocusRouting] answer for all three keys).
        return switch (posFocusRouting()) {
          PosFocusRouting.otherEditable => false,
          _ => true,
        };
    }
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
        return _isStarEvent(event);
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

  /// The cashier's `*`, from every source a Windows layout can produce it:
  ///  1. the `*` character the key produced (any layout, main row or not);
  ///  2. the dedicated asterisk / numpad multiply keys;
  ///  3. the main row `8` key with Shift held, when the platform hands the
  ///     event no character at all — same fallback shape as [_isPlusEvent]
  ///     and [_isMinusEvent] (the file header always promised it for all
  ///     three keys; only `*` was still missing it, so a characterless
  ///     hardware Shift+8 fell through to plain typing).
  ///
  /// (3) needs both a characterless event and a held Shift, so a plain `8`
  /// (or a layout that really types another character there) is never
  /// hijacked. Key-down only (see [matchesEvent]) — one press, one dialog.
  static bool _isStarEvent(KeyEvent event) {
    if (event.character == '*') return true;
    if (event.logicalKey == LogicalKeyboardKey.asterisk) return true;
    if (event.logicalKey == LogicalKeyboardKey.numpadMultiply) return true;
    final character = event.character;
    if (character != null && character.isNotEmpty) return false;
    if (event.logicalKey != LogicalKeyboardKey.digit8) return false;
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);
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
