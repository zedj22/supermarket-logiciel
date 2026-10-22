// EXPERIMENTAL physical-key scanner capture (lib/core/barcode_scanner.dart).
//
// The logical-key variant of foreign-layout capture failed on field
// hardware, so the experiment now keys on the PHYSICAL scan-code digit
// keys (1:1 with the US number row for a US-configured scanner, layout-
// independent by construction) — gated by
// `BarcodeScannerGateway.experimentalPhysicalDigitCapture` (default
// OFF). This file proves BOTH sides of the contract:
//
//  * flag OFF (default): the gateway is exactly the pre-experiment
//    character-only capture — foreign bursts are dropped, US scans and
//    ordinary typing/shortcuts unchanged;
//  * flag ON: French AZERTY (`&é"'(-è_çà`) and Arabic-Indic bursts
//    dispatch ASCII digits, while English US, ordinary typing, POS
//    shortcuts (`+`/`-`/`*`), numpad, duplicate-dispatch protection
//    and privacy all keep their behavior; the flag can be flipped off
//    again and the old behavior returns.
//
// No symbol-to-digit table, no Shift synthesis and no OS input
// injection anywhere: the digit comes from the physical key's scan-code
// ordinal; the layout-translated character is ignored, never converted.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';

import '../helpers/wedge_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gateway = BarcodeScannerGateway.instance;

  setUp(gateway.resetForTest);
  tearDown(gateway.resetForTest);

  /// The unshifted number-row characters the AZERTY layout delivers for
  /// US scan codes (probed live: scancodes 0x02–0x0B → ToUnicode
  /// `&é"'(-è_çà`). Note `6` → `-`: the scan/minus-shortcut collision
  /// resolved in favor of the scan.
  const azerty = <String, String>{
    '1': '&',
    '2': 'é',
    '3': '"',
    '4': "'",
    '5': '(',
    '6': '-',
    '7': 'è',
    '8': '_',
    '9': 'ç',
    '0': 'à',
  };

  /// Arabic-Indic digit characters some Arabic keyboard modes deliver
  /// for the same physical positions.
  const arabicIndic = <String, String>{
    '1': '١',
    '2': '٢',
    '3': '٣',
    '4': '٤',
    '5': '٥',
    '6': '٦',
    '7': '٧',
    '8': '٨',
    '9': '٩',
    '0': '٠',
  };

  group('flag OFF (default): exact pre-experiment behavior', () {
    test('a foreign AZERTY burst is NOT captured (the old drop)', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      expect(BarcodeScannerGateway.experimentalPhysicalDigitCapture, isFalse);
      for (final d in '444555666'.split('')) {
        expect(
          gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d])),
          isFalse,
          reason: 'symbol characters pass untouched while the experiment '
              'is off',
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, isEmpty);
      expect(gateway.bufferedDigitCount, 0);
    });

    test('US scans keep working (character path)', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '8718114202402'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isTrue);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['8718114202402']);
    });

    testWidgets('resetForTest restores the default (OFF) after a session '
        'enabled the experiment', (tester) async {
      BarcodeScannerGateway.experimentalPhysicalDigitCapture = true;
      gateway.resetForTest();
      expect(BarcodeScannerGateway.experimentalPhysicalDigitCapture, isFalse);
    });
  });

  group('flag ON — French AZERTY capture', () {
    setUp(() => BarcodeScannerGateway.experimentalPhysicalDigitCapture = true);

    test('an AZERTY burst on physical digit keys dispatches ASCII digits',
        () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '444555666'.split('')) {
        expect(
          gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d])),
          isTrue,
          reason: 'physical position "$d" must capture despite character '
              '"${azerty[d]}"',
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);

      expect(codes, ['444555666']);
      expect(codes.single, matches(RegExp(r'^\d+$')),
          reason: 'only ASCII digits ever leave the gateway (privacy)');
    });

    testWidgets('through the REAL pipeline: one dispatch, first digit '
        'consumed', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      expect(
        await tester.sendKeyEvent(digitKey('4'), character: azerty['4']),
        isTrue,
      );
      for (final d in '44555666'.split('')) {
        await tester.sendKeyEvent(digitKey(d), character: azerty[d]);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(codes, ['444555666']);
    });

    testWidgets('two consecutive bursts dispatch twice; a second Enter '
        'never re-dispatches', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendForeignWedgeScan(tester, '444555666', characters: azerty);
      await sendForeignWedgeScan(tester, '8718114202402', characters: azerty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(codes, ['444555666', '8718114202402']);
    });

    test('a mixed US + AZERTY run concatenates; a non-digit key abandons',
        () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '4445'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isTrue);
      }
      for (final d in '55666'.split('')) {
        expect(
          gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d])),
          isTrue,
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['444555666']);

      // F5 mid-run: junk — the partial run dies and Enter passes.
      for (final d in '444'.split('')) {
        gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d]));
      }
      gateway.handleKeyForTest(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.f5,
          logicalKey: LogicalKeyboardKey.f5,
          timeStamp: Duration.zero,
        ),
      );
      expect(gateway.bufferedDigitCount, 0);
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, ['444555666']);
    });

    test('ordinary typing is untouched: letters never capture; a short '
        'symbol run is not a scan', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      final letters = <PhysicalKeyboardKey, LogicalKeyboardKey>{
        PhysicalKeyboardKey.keyA: LogicalKeyboardKey.keyA,
        PhysicalKeyboardKey.keyZ: LogicalKeyboardKey.keyZ,
        PhysicalKeyboardKey.keyE: LogicalKeyboardKey.keyE,
        PhysicalKeyboardKey.keyR: LogicalKeyboardKey.keyR,
        PhysicalKeyboardKey.keyT: LogicalKeyboardKey.keyT,
        PhysicalKeyboardKey.keyY: LogicalKeyboardKey.keyY,
      };
      final chars = <PhysicalKeyboardKey, String>{
        PhysicalKeyboardKey.keyA: 'a',
        PhysicalKeyboardKey.keyZ: 'z',
        PhysicalKeyboardKey.keyE: 'e',
        PhysicalKeyboardKey.keyR: 'r',
        PhysicalKeyboardKey.keyT: 't',
        PhysicalKeyboardKey.keyY: 'y',
      };
      for (final entry in letters.entries) {
        expect(
          gateway.handleKeyForTest(
            foreignKeyDown(
              physicalKey: entry.key,
              logicalKey: entry.value,
              character: chars[entry.key],
            ),
          ),
          isFalse,
        );
      }
      expect(gateway.bufferedDigitCount, 0);

      for (final d in '12345'.split('')) {
        gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d]));
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, isEmpty);
    });

    testWidgets('POS shortcut ownership: "*" and "+" never capture on '
        'digit keys; Shift blocks everything', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      // digit8+"*" and digit2+"+" (the qty-shortcut characters) pass.
      expect(
        await tester.sendKeyEvent(digitKey('8'), character: '*'),
        isFalse,
      );
      expect(
        await tester.sendKeyEvent(digitKey('2'), character: '+'),
        isFalse,
      );
      expect(gateway.bufferedDigitCount, 0);

      // A held Shift keeps produced-character semantics: the whole
      // foreign burst passes (a scanner never sends Shift).
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await sendForeignWedgeScan(tester, '444555666', characters: azerty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(codes, isEmpty);
      expect(gateway.bufferedDigitCount, 0);
    });

    testWidgets('the minus character (AZERTY digit-6) captures — the '
        'documented collision resolves to the scan', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      // 444555666 contains three digit-6 positions → three "-" keys.
      await sendForeignWedgeScan(tester, '444555666', characters: azerty);
      expect(codes, ['444555666']);
    });

    test('English US is unchanged with the experiment on', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '111222333'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isTrue);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['111222333']);
    });

    test('numpad: NumLock-on digits capture (character path); NumLock-off '
        'navigation never captures', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '777888999'.split('')) {
        final numpadKey = switch (int.parse(d)) {
          7 => LogicalKeyboardKey.numpad7,
          8 => LogicalKeyboardKey.numpad8,
          9 => LogicalKeyboardKey.numpad9,
          _ => throw StateError('unexpected digit $d'),
        };
        expect(
          gateway.handleKeyForTest(
            foreignKeyDown(
              physicalKey: PhysicalKeyboardKey(numpadKey.keyId),
              logicalKey: numpadKey,
              character: d,
            ),
          ),
          isTrue,
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['777888999']);

      codes.clear();
      const numLockOff7 = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.numpad7,
        logicalKey: LogicalKeyboardKey.numpad7,
        timeStamp: Duration.zero,
        character: null,
      );
      expect(gateway.handleKeyForTest(numLockOff7), isFalse);
      expect(gateway.bufferedDigitCount, 0);
    });

    test('the experiment can be disabled again at runtime', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      BarcodeScannerGateway.experimentalPhysicalDigitCapture = false;

      for (final d in '444555666'.split('')) {
        expect(
          gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d])),
          isFalse,
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, isEmpty);
    });
  });

  group('flag ON — Arabic capture', () {
    setUp(() => BarcodeScannerGateway.experimentalPhysicalDigitCapture = true);

    test('Arabic-Indic characters on physical digit keys dispatch ASCII '
        'digits', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final d in '8718114202402'.split('')) {
        expect(
          gateway.handleKeyForTest(
            physicalDigitKeyDown(d, character: arabicIndic[d]),
          ),
          isTrue,
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['8718114202402']);
    });

    testWidgets('through the REAL pipeline', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendForeignWedgeScan(tester, '444555666', characters: arabicIndic);
      expect(codes, ['444555666']);
    });

    test('logical-digit keys alone never capture (the failed Phase E '
        'signal is not used)', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      // Logical digit3 with a NON-digit physical key: the experiment
      // must key on the PHYSICAL identity only.
      expect(
        gateway.handleKeyForTest(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.f6,
            logicalKey: LogicalKeyboardKey.digit3,
            timeStamp: Duration.zero,
            character: '٣',
          ),
        ),
        isFalse,
      );
      expect(gateway.bufferedDigitCount, 0);
      expect(codes, isEmpty);
    });
  });

  group('flag ON — pass-through runs (allowWhileEditing / Add Product form)',
      () {
    setUp(() => BarcodeScannerGateway.experimentalPhysicalDigitCapture = true);

    Future<EditableText> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField())),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      return tester.widget<EditableText>(find.byType(EditableText));
    }

    testWidgets('the foreign burst transits the field as symbols and is '
        'rolled back at Enter before the ASCII code dispatches',
        (tester) async {
      final codes = <String>[];
      gateway.register(
        BarcodeScanHandler(onScan: codes.add, allowWhileEditing: true),
      );
      final editable = await pumpForm(tester);

      for (final d in '444555666'.split('')) {
        expect(
          gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d])),
          isFalse,
          reason: 'a form digit must reach the focused field',
        );
      }
      final symbols = '444555666'.split('').map((d) => azerty[d]!).join();
      expect(symbols, "'''(((---");
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: symbols,
        selection: TextSelection.collapsed(offset: symbols.length),
      ));
      await tester.pump();

      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      await tester.pump();

      expect(editable.controller.text, isEmpty);
      expect(codes, ['444555666']);
    });

    testWidgets('a short foreign run stays in the field as typing',
        (tester) async {
      final codes = <String>[];
      gateway.register(
        BarcodeScanHandler(onScan: codes.add, allowWhileEditing: true),
      );
      final editable = await pumpForm(tester);

      for (final d in '12345'.split('')) {
        gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d]));
      }
      final symbols = '12345'.split('').map((d) => azerty[d]!).join();
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: symbols,
        selection: TextSelection.collapsed(offset: symbols.length),
      ));
      await tester.pump();

      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      await tester.pump();
      expect(codes, isEmpty);
      expect(editable.controller.text, symbols);
    });

    testWidgets('a field diverged mid-run is typing: never dispatched, '
        'never restored', (tester) async {
      final codes = <String>[];
      gateway.register(
        BarcodeScanHandler(onScan: codes.add, allowWhileEditing: true),
      );
      await pumpForm(tester);

      for (final d in '444555666'.split('')) {
        gateway.handleKeyForTest(physicalDigitKeyDown(d, character: azerty[d]));
      }
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'xy',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();

      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      await tester.pump();
      expect(codes, isEmpty);
    });

    testWidgets('the US pass-through path is unchanged (exact text match)',
        (tester) async {
      final codes = <String>[];
      gateway.register(
        BarcodeScanHandler(onScan: codes.add, allowWhileEditing: true),
      );
      final editable = await pumpForm(tester);

      for (final d in '444555666'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isFalse);
      }
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '444555666',
        selection: TextSelection.collapsed(offset: 9),
      ));
      await tester.pump();

      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      await tester.pump();
      expect(editable.controller.text, isEmpty);
      expect(codes, ['444555666']);
    });
  });
}
