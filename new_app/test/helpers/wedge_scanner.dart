// Keyboard-wedge simulation helpers shared by the global barcode scan
// tests (gateway unit tests + POS/Products/Stock widget tests).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Logical key the wedge presses for each typed digit character.
const Map<String, LogicalKeyboardKey> _logicalDigits = <String,
    LogicalKeyboardKey>{
  '0': LogicalKeyboardKey.digit0,
  '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4,
  '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6,
  '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
};

/// Physical key the wedge presses for each typed digit character.
const Map<String, PhysicalKeyboardKey> _physicalDigits = <String,
    PhysicalKeyboardKey>{
  '0': PhysicalKeyboardKey.digit0,
  '1': PhysicalKeyboardKey.digit1,
  '2': PhysicalKeyboardKey.digit2,
  '3': PhysicalKeyboardKey.digit3,
  '4': PhysicalKeyboardKey.digit4,
  '5': PhysicalKeyboardKey.digit5,
  '6': PhysicalKeyboardKey.digit6,
  '7': PhysicalKeyboardKey.digit7,
  '8': PhysicalKeyboardKey.digit8,
  '9': PhysicalKeyboardKey.digit9,
};

/// The logical key for one digit character of a burst.
LogicalKeyboardKey digitKey(String character) => _logicalDigits[character]!;

/// One key-down of the wedge's [character] — for direct
/// `BarcodeScannerGateway.handleKeyForTest` assertions.
KeyEvent wedgeKeyDown(String character) => KeyDownEvent(
      physicalKey: _physicalDigits[character]!,
      logicalKey: _logicalDigits[character]!,
      timeStamp: Duration.zero,
      character: character,
    );

/// The Enter terminator as a key-down.
KeyEvent wedgeEnter() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
      character: '\n',
    );

/// One complete wedge burst through the REAL event pipeline: every
/// digit as its own key-down/up pair (a wedge releases each key before
/// pressing the next), then Enter as the terminator.
Future<void> sendWedgeScan(WidgetTester tester, String code) async {
  for (final character in code.split('')) {
    await tester.sendKeyEvent(digitKey(character));
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

/// One complete wedge burst typed INTO a focused text field the way the
/// engine delivers it on a real device: each digit appended at the caret
/// (end of the field's existing content — one text-input update per
/// character, firing `onChanged` per digit), then Enter as the field's
/// submit action.
///
/// [sendWedgeScan] alone never reaches a focused field's text in widget
/// tests (key events do not flow through the test binding's text input
/// connection), so a burst arriving in a focused quantity/search field
/// must be typed through this seam.
Future<void> typeWedgeScanIntoField(
  WidgetTester tester,
  Finder field,
  String code,
) async {
  // [field] may key the TextField or the EditableText itself.
  final editableFinder = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  final editable = editableFinder.evaluate().isNotEmpty
      ? tester.widget<EditableText>(editableFinder)
      : tester.widget<EditableText>(field);
  var text = editable.controller.text;
  for (final character in code.split('')) {
    text += character;
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ));
    await tester.pump();
  }
  await tester.testTextInput.receiveAction(TextInputAction.done);
}
