// App-level keyboard-wedge gateway (lib/core/barcode_scanner.dart):
// capture rules, arming gates, dispatch routing, and the proof that a
// consumed key never reaches the focus system while a passed one does.
//
// Every pipeline test drives the REAL event simulation
// (`tester.sendKeyEvent` → handleKeyData queue + raw key message →
// HardwareKeyboard handlers → FocusManager), so both gateway listeners
// are exercised exactly as on a physical wedge.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/keyboard.dart';

import '../helpers/wedge_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gateway = BarcodeScannerGateway.instance;

  setUp(gateway.resetForTest);
  tearDown(gateway.resetForTest);

  group('capture state machine', () {
    testWidgets('a digit burst + Enter dispatches exactly one code',
        (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendWedgeScan(tester, '444555666');

      expect(codes, ['444555666']);
    });

    testWidgets('a consumed digit is reported handled to the platform',
        (tester) async {
      gateway.register(BarcodeScanHandler(onScan: (_) {}));
      expect(await tester.sendKeyEvent(digitKey('4')), isTrue);
      // …while a key outside the capture rules passes untouched.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f1), isFalse);
    });

    test('consumed return values: buffered digits and a matching Enter '
        'are taken, everything else passes', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final character in '8718114202402'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(character)), isTrue);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      expect(codes, ['8718114202402']);

      // A too-short run: the digits are buffered (nothing else could
      // consume them) but the terminator passes untouched.
      for (final character in '123'.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(character)), isTrue);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, ['8718114202402']);

      // Key-ups never touch the run and never report handled.
      expect(
        gateway.handleKeyForTest(
          KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.digit5,
            logicalKey: LogicalKeyboardKey.digit5,
            timeStamp: Duration.zero,
          ),
        ),
        isFalse,
      );
      // A non-digit key-down discards the partial run and passes.
      expect(
        gateway.handleKeyForTest(
          KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
            character: ' ',
          ),
        ),
        isFalse,
      );
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(codes, ['8718114202402']);
    });

    testWidgets('a second Enter with no digits in between passes',
        (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendWedgeScan(tester, '8718114202402');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(codes, ['8718114202402']); // exactly one dispatch per burst
    });

    testWidgets('a non-digit key mid-run discards the partial burst',
        (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final character in '444555'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      for (final character in '666'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(codes, isEmpty); // "666" alone is not a barcode-shaped run
    });

    testWidgets('key-ups interleaved per character never reset the run',
        (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final character in '111222333'.split('')) {
        await tester.sendKeyDownEvent(digitKey(character));
        await tester.sendKeyUpEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(codes, ['111222333']);
    });

    testWidgets('key auto-repeat cannot extend a run into a burst',
        (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await tester.sendKeyDownEvent(digitKey('5'));
      for (var i = 0; i < 8; i++) {
        expect(
          gateway.handleKeyForTest(
            KeyRepeatEvent(
              physicalKey: PhysicalKeyboardKey.digit5,
              logicalKey: LogicalKeyboardKey.digit5,
              timeStamp: Duration(milliseconds: 50 * i),
              character: '5',
            ),
          ),
          isFalse,
        );
      }
      await tester.sendKeyUpEvent(digitKey('5'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      // One real digit only — repeats never appended.
      expect(codes, isEmpty);
    });

    testWidgets('numpad Enter terminates as well', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      for (final character in '111222333'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);

      expect(codes, ['111222333']);
    });
  });

  group('arming gates', () {
    testWidgets('a focused text field stands the gateway down', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TextField())),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(gateway.hasActiveHandler, isFalse);

      await sendWedgeScan(tester, '8718114202402');
      expect(codes, isEmpty);

      // The field's own behavior is untouched: text entry goes through
      // the normal focused path, never the gateway.
      await tester.enterText(find.byType(TextField), '8718114202402');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '8718114202402',
      );
      expect(codes, isEmpty);
    });

    testWidgets('a held Ctrl chord stands the gateway down', (tester) async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      expect(gateway.hasActiveHandler, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(gateway.hasActiveHandler, isFalse);

      await sendWedgeScan(tester, '8718114202402');
      expect(codes, isEmpty);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(gateway.hasActiveHandler, isTrue);
      await sendWedgeScan(tester, '8718114202402');
      expect(codes, ['8718114202402']);
    });

    testWidgets('a modal dialog pushed over the screen route blocks scans',
        (tester) async {
      final codes = <String>[];
      late BuildContext screenContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              screenContext = context;
              return const Scaffold(body: Text('screen'));
            },
          ),
        ),
      );
      gateway.register(
        BarcodeScanHandler(context: screenContext, onScan: codes.add),
      );

      await sendWedgeScan(tester, '444555666');
      expect(codes, ['444555666']);

      showDialog<void>(
        context: screenContext,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();
      expect(gateway.hasActiveHandler, isFalse);

      await sendWedgeScan(tester, '444555666');
      expect(codes, ['444555666']); // never scan behind a dialog

      Navigator.of(screenContext).pop();
      await tester.pumpAndSettle();
      expect(gateway.hasActiveHandler, isTrue);

      await sendWedgeScan(tester, '444555666');
      expect(codes, ['444555666', '444555666']);
    });

    testWidgets('a same-route focus move never truncates a run in flight',
        (tester) async {
      // The post-add refocus lands DURING the next physical burst when the
      // cashier scans fast (Enter → unfocus → chain → refocus ~100-300ms
      // later while the next burst is already being typed). The digits
      // were consumed by the gateway, so the run must stay its property
      // through the focus move — truncating it here discards the barcode
      // prefix and types the remainder as a quantity (the repeated-scan
      // corruption).
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));
      final nodeA = FocusNode();
      final nodeB = FocusNode();
      addTearDown(nodeA.dispose);
      addTearDown(nodeB.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: nodeA,
                  autofocus: true,
                  child: const SizedBox(width: 40, height: 40),
                ),
                Focus(focusNode: nodeB, child: const SizedBox(width: 40)),
              ],
            ),
          ),
        ),
      );
      expect(FocusManager.instance.primaryFocus, nodeA);

      for (final character in '123456'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      nodeB.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, nodeB);

      // Same route: the run continues under nodeB's scope and the
      // terminator dispatches the FULL code — never a truncated remainder,
      // never nothing.
      for (final character in '7890123'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(codes, ['1234567890123']);
    });

    testWidgets('a run in flight survives focus moving into a text field '
        'and the field never sees it', (tester) async {
      // The exact POS window: burst starts with the workspace unfocused,
      // the post-add refocus lands mid-run, the rest of the burst and the
      // Enter belong to the gateway — the qty field keeps showing the
      // committed quantity the whole time.
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(autofocus: true, child: SizedBox(width: 40, height: 40)),
                TextField(),
              ],
            ),
          ),
        ),
      );
      final field = find.byType(TextField);

      for (final character in '8718114'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.tap(field);
      await tester.pump();
      expect(
        editableTextHasFocus(),
        isTrue,
        reason: 'the qty field now holds primary focus mid-run',
      );

      for (final character in '202402'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      // The consumed digits never reached the field's text.
      expect(
        tester.widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        ).controller.text,
        isEmpty,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(codes, ['8718114202402'],
          reason: 'one physical burst, one dispatch, full code');
      // Enter was consumed with the run: the field never submitted.
      expect(
        tester.widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        ).controller.text,
        isEmpty,
      );
    });

    testWidgets('a dialog pushed mid-run abandons the run (never scans '
        'behind it)', (tester) async {
      final codes = <String>[];
      late BuildContext screenContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              screenContext = context;
              return const Scaffold(body: Text('screen'));
            },
          ),
        ),
      );
      gateway.register(
        BarcodeScanHandler(context: screenContext, onScan: codes.add),
      );

      for (final character in '444555'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      showDialog<void>(
        context: screenContext,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();

      // The route changed: the partial run is junk — remaining digits and
      // the terminator all pass through untouched.
      for (final character in '666777'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(codes, isEmpty);
      expect(gateway.hasActiveHandler, isFalse);
    });
  });

  group('dispatch routing', () {
    testWidgets('only the most recent registration receives the code',
        (tester) async {
      final older = <String>[];
      final newer = <String>[];
      final olderHandler = BarcodeScanHandler(onScan: older.add);
      gateway.register(olderHandler);
      gateway.register(BarcodeScanHandler(onScan: newer.add));
      expect(gateway.handlerCount, 2);

      await sendWedgeScan(tester, '444555666');
      expect(newer, ['444555666']);
      expect(older, isEmpty);

      // Unregistering the older screen leaves exactly the active one.
      gateway.unregister(olderHandler);
      expect(gateway.handlerCount, 1);
      await sendWedgeScan(tester, '111222333');
      expect(newer, ['444555666', '111222333']);
      expect(older, isEmpty);
    });

    testWidgets('re-registering the same handler never duplicates it',
        (tester) async {
      final codes = <String>[];
      final handler = BarcodeScanHandler(onScan: codes.add);
      gateway.register(handler);
      gateway.register(handler);
      expect(gateway.handlerCount, 1);

      await sendWedgeScan(tester, '8718114202402');
      expect(codes, ['8718114202402']);
    });

    testWidgets('unregister empties the list and stops all dispatch',
        (tester) async {
      final codes = <String>[];
      final handler = BarcodeScanHandler(onScan: codes.add);
      gateway.register(handler);
      expect(gateway.handlerCount, 1);
      expect(gateway.hasActiveHandler, isTrue);

      gateway.unregister(handler);
      expect(gateway.handlerCount, 0);
      expect(gateway.hasActiveHandler, isFalse);

      await sendWedgeScan(tester, '8718114202402');
      expect(codes, isEmpty);
    });
  });

  group('focus-system consumption', () {
    testWidgets('a captured burst never reaches an ancestor shortcut binding',
        (tester) async {
      final codes = <String>[];
      var digitBound = false;
      var enterBound = false;
      await tester.pumpWidget(
        CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.digit5): () {
              digitBound = true;
            },
            const SingleActivator(LogicalKeyboardKey.enter): () {
              enterBound = true;
            },
          },
          child: const Focus(
            autofocus: true,
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      );
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendWedgeScan(tester, '555555');

      expect(codes, ['555555']);
      // Hardware handlers cannot stop the focus walk on their own —
      // only the early-key-event half proves the digits and the
      // terminator were truly consumed.
      expect(digitBound, isFalse);
      expect(enterBound, isFalse);
    });

    testWidgets('an Enter outside a barcode-shaped run still reaches the '
        'focus system', (tester) async {
      final codes = <String>[];
      var digitBound = false;
      var enterBound = false;
      await tester.pumpWidget(
        CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.digit5): () {
              digitBound = true;
            },
            const SingleActivator(LogicalKeyboardKey.enter): () {
              enterBound = true;
            },
          },
          child: const Focus(
            autofocus: true,
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      );
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      await sendWedgeScan(tester, '555'); // 3 digits: buffer only

      expect(codes, isEmpty);
      expect(digitBound, isFalse); // the buffered digits were consumed
      expect(enterBound, isTrue); // …but the unmatched Enter passed on
    });

    testWidgets('with a text field focused the shortcut binding still fires',
        (tester) async {
      var digitBound = false;
      await tester.pumpWidget(
        CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.digit5): () {
              digitBound = true;
            },
          },
          child: const MaterialApp(home: Scaffold(body: TextField())),
        ),
      );
      gateway.register(BarcodeScanHandler(onScan: (_) {}));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(gateway.hasActiveHandler, isFalse);

      await tester.sendKeyEvent(digitKey('5'));
      expect(digitBound, isTrue); // gateway stood down: keys flow normally
    });
  });
}
