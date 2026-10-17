// Shared keyboard focus / shortcut helpers (Phase 17 §18).
//
// One rule for every shortcut that must NOT steal a key the cashier is
// currently typing: ask [editableTextHasFocus]. The POS quantity shortcuts
// (`+` / `-` / `*`), the option-picker digit shortcuts and the SPACE-to-pay
// shortcut all go through it. Each shortcut then names the fields it may
// still claim its key from — the POS focus router (pos_qty_shortcuts.dart)
// answers WHICH focused field is idle vs being typed in (barcode-ready
// search, cart quantity, line discount, dialogs) via its
// allowWhileEditing hooks — so every other input (dialogs, pickers,
// invoices) keeps normal text entry.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// True while an [EditableText] (search field, quantity field, dialog input,
/// …) holds primary focus.
///
/// Kept out of the feature folders on purpose: this is a framework-level
/// question, not a POS or product question, and both layers must agree on
/// the answer for one key to behave consistently everywhere.
bool editableTextHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// [ShortcutActivator] for one logical key that must never be taken away
/// from a text-entry control.
///
/// Phase 17 §18: SPACE pays — but only while the POS workspace is active and
/// no text field is consuming the space. When an [EditableText] has primary
/// focus the activator declines, `CallbackShortcuts` lets the event keep
/// bubbling, and the space character is inserted as ordinary text.
///
/// [allowWhileEditing] is the single sanctioned exception: when an
/// [EditableText] DOES hold primary focus the activator asks it first, so
/// the caller can hand one specific key back to the shortcut (the POS cart
/// quantity field is auto-focused after every add — SPACE must pay there and
/// never reach the quantity text input). Every other text field keeps its
/// normal space character: the hook is opt-in, per binding, per caller.
///
/// Only [KeyDownEvent]s match: holding SPACE must not re-open a dialog
/// through key auto-repeat.
class TextFreeKeyActivator extends ShortcutActivator {
  const TextFreeKeyActivator(this.trigger, {this.allowWhileEditing});

  final LogicalKeyboardKey trigger;

  /// Consulted only while an [EditableText] has primary focus: returns true
  /// when the shortcut may claim the key anyway (and therefore consume it,
  /// so the text field never sees the character).
  final bool Function()? allowWhileEditing;

  @override
  Iterable<LogicalKeyboardKey>? get triggers =>
      <LogicalKeyboardKey>[trigger];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != trigger) return false;
    if (!editableTextHasFocus()) return true;
    return allowWhileEditing?.call() ?? false;
  }

  @override
  String debugDescribeKeys() => trigger.debugName ?? trigger.toString();
}
