// Shared keyboard focus / shortcut helpers (Phase 17 §18).
//
// One rule for every shortcut that must NOT steal a key the cashier is
// currently typing: ask [editableTextHasFocus]. The POS quantity shortcuts
// (`+` / `-` / `*`), the option-picker digit shortcuts and the SPACE-to-pay
// shortcut all go through it, so a search field, a cart quantity field or
// any dialog input always keeps normal text entry.
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
/// Only [KeyDownEvent]s match: holding SPACE must not re-open a dialog
/// through key auto-repeat.
class TextFreeKeyActivator extends ShortcutActivator {
  const TextFreeKeyActivator(this.trigger);

  final LogicalKeyboardKey trigger;

  @override
  Iterable<LogicalKeyboardKey>? get triggers =>
      <LogicalKeyboardKey>[trigger];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != trigger) return false;
    return !editableTextHasFocus();
  }

  @override
  String debugDescribeKeys() => trigger.debugName ?? trigger.toString();
}
