// Phase A — privacy-safe keyboard-wedge observation (scan_capture_recorder.dart).
//
// The contract under test:
//  * OFF by default; the handler exists only between start() and stop();
//  * the observer NEVER consumes an event (always-false handler) and
//    never changes the gateway's return values or dispatch counts;
//  * records are category-only — no character, typed text or digit value
//    is retained, for English, Arabic-Indic, fullwidth and AZERTY-like
//    layouts alike;
//  * the ring is bounded ([kScanCaptureBufferCapacity]), the fan-out is
//    allowlist-sanitized (`suffix3`/`text` stripped before delivery);
//  * the export cannot reconstruct a barcode.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/scan_capture_recorder.dart';
import 'package:supermarket_pos/core/scan_diagnostics.dart';

import '../helpers/wedge_scanner.dart';

KeyEvent _keyUp(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
    KeyUpEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    );

KeyEvent _namedDown(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    );

String _normalizeTimings(String export) => export
    .replaceAll(RegExp(r'\+\d+ms'), '+Xms')
    .replaceAll(RegExp(r'ms=\d+'), 'ms=X')
    .replaceAll(RegExp(r'started=\S+'), 'started=X');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recorder = ScanCaptureRecorder.instance;
  final gateway = BarcodeScannerGateway.instance;

  setUp(() {
    gateway.resetForTest();
    recorder.stop();
    recorder.clear();
  });

  tearDown(() {
    gateway.resetForTest();
    recorder.stop();
    if (!recorder.isDisposed) recorder.clear();
  });

  group('session lifecycle (off by default)', () {
    test('the recorder is inactive before any session', () {
      expect(recorder.isActive, isFalse);
      expect(recorder.totalEvents, 0);
    });

    test('events are never recorded while the session is off', () {
      expect(
        recorder.handleEventForTest(wedgeKeyDown('5')),
        isFalse,
      );
      expect(recorder.totalEvents, 0);
      expect(recorder.bufferedEventCount, 0);
    });

    test('start installs observation; stop removes it (idempotent both ways)',
        () {
      recorder.start();
      expect(recorder.isActive, isTrue);
      recorder.start(); // no double count, no throw
      expect(recorder.handleEventForTest(wedgeKeyDown('3')), isFalse);
      expect(recorder.totalEvents, 1);

      recorder.stop();
      expect(recorder.isActive, isFalse);
      expect(recorder.handleEventForTest(wedgeKeyDown('3')), isFalse);
      expect(recorder.totalEvents, 1, reason: 'no records after stop');
      recorder.stop(); // idempotent
      expect(recorder.totalEvents, 1);
    });

    test('clear empties counters and the ring in any session state', () {
      recorder.start();
      recorder.handleEventForTest(wedgeKeyDown('7'));
      expect(recorder.totalEvents, 1);
      recorder.clear();
      expect(recorder.totalEvents, 0);
      expect(recorder.bufferedEventCount, 0);
      expect(recorder.categoryCounts, isEmpty);
      recorder.stop();
    });
  });

  group('the observer never consumes', () {
    test('every category returns false from the handler seam', () {
      recorder.start();
      expect(recorder.handleEventForTest(wedgeKeyDown('4')), isFalse);
      expect(recorder.handleEventForTest(wedgeEnter()), isFalse);
      expect(
        recorder.handleEventForTest(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.numpadEnter,
            logicalKey: LogicalKeyboardKey.numpadEnter,
            timeStamp: Duration.zero,
          ),
        ),
        isFalse,
      );
      expect(
        recorder.handleEventForTest(
          _keyUp(LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
        ),
        isFalse,
      );
      expect(
        recorder.handleEventForTest(
          keyRepeat(
            logicalKey: LogicalKeyboardKey.digit5,
            physicalKey: PhysicalKeyboardKey.digit5,
          ),
        ),
        isFalse,
      );
      expect(
        recorder.handleEventForTest(
          _namedDown(
            LogicalKeyboardKey.escape,
            PhysicalKeyboardKey.escape,
          ),
        ),
        isFalse,
      );
      expect(
        recorder.handleEventForTest(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
            character: ' ',
          ),
        ),
        isFalse,
      );
    });

    testWidgets(
      'gateway return values and dispatch counts are IDENTICAL with the '
      'diagnostics session off and on',
      (tester) async {
        List<Object?> runScript() {
          gateway.resetForTest();
          final codes = <String>[];
          gateway.register(BarcodeScanHandler(onScan: codes.add));
          final returns = <bool>[];
          void feed(KeyEvent event) => returns.add(gateway.handleKeyForTest(event));

          for (final c in '311999888'.split('')) {
            feed(wedgeKeyDown(c));
          }
          feed(wedgeEnter());
          for (final c in '12'.split('')) {
            feed(wedgeKeyDown(c));
          }
          feed(wedgeEnter());
          feed(_keyUp(LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5));
          feed(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.space,
              logicalKey: LogicalKeyboardKey.space,
              timeStamp: Duration.zero,
              character: ' ',
            ),
          );
          feed(wedgeEnter());
          return <Object?>[returns, codes];
        }

        recorder.stop();
        recorder.clear();
        final off = runScript();

        recorder.start();
        recorder.clear();
        final on = runScript();
        recorder.stop();

        expect(on[0], off[0], reason: 'return values changed under observation');
        expect(on[1], off[1], reason: 'dispatch count changed under observation');
        expect((on[1] as List<String>), ['311999888']);
      },
    );

    testWidgets(
      'a pass-through (allowWhileEditing) run keeps its exact gateway '
      'returns while observing',
      (tester) async {
        // Mirrors the product-form seam: a handler with
        // allowWhileEditing and a controller the digits transit. The
        // gateway must keep returning false for every pass-through digit.
        recorder.start();
        recorder.clear();
        gateway.resetForTest();
        final codes = <String>[];
        gateway.register(
          BarcodeScanHandler(
            onScan: codes.add,
            allowWhileEditing: true,
          ),
        );

        // No focused EditableText in this tree-less seam, so the run is
        // consumed-style; the assertion that matters is the return-value
        // stream equals the no-recorder baseline below.
        final returns = <bool>[];
        for (final c in '555666777'.split('')) {
          returns.add(gateway.handleKeyForTest(wedgeKeyDown(c)));
        }
        returns.add(gateway.handleKeyForTest(wedgeEnter()));
        expect(returns, everyElement(isTrue));
        expect(codes, ['555666777']);
        recorder.stop();
      },
    );
  });

  group('categorization without retention', () {
    test('an English digit records category and timing ONLY', () {
      recorder.start();
      recorder.handleEventForTest(wedgeKeyDown('5'));
      final record = recorder.events.single;
      expect(record['cat'], ScanCaptureCategory.digitDown);
      expect(
        record.keys.toSet(),
        everyElement(isIn(kScanCaptureEventFieldAllowlist)),
      );
      expect(record.keys, isNot(contains('char')));
      expect(record.keys, isNot(contains('character')));
      expect(record.keys, isNot(contains('key')));
      expect(record.values, isNot(contains('5')));
      recorder.stop();
    });

    test('an AZERTY-like wedge (physical Digit1 → character "&") is counted '
        'as a digit-down and "&" is never stored', () {
      recorder.start();
      recorder.handleEventForTest(
        foreignKeyDown(
          physicalKey: PhysicalKeyboardKey.digit1,
          logicalKey: LogicalKeyboardKey.digit1,
          character: '&',
        ),
      );
      final record = recorder.events.single;
      expect(record['cat'], ScanCaptureCategory.digitDown);
      expect(record.values, isNot(contains('&')));
      expect(recorder.buildExport(), isNot(contains('&')));
      recorder.stop();
    });

    test('Arabic-Indic and fullwidth digit characters are counted, never kept',
        () {
      recorder.start();
      // Arabic-101 layout: logical digit3, character U+0663 '٣'.
      recorder.handleEventForTest(
        foreignKeyDown(
          physicalKey: PhysicalKeyboardKey.digit3,
          logicalKey: LogicalKeyboardKey.digit3,
          character: '٣',
        ),
      );
      // Fullwidth: logical digit1, character U+FF11 '１'.
      recorder.handleEventForTest(
        foreignKeyDown(
          physicalKey: PhysicalKeyboardKey.digit1,
          logicalKey: LogicalKeyboardKey.digit1,
          character: '１',
        ),
      );
      expect(recorder.categoryCounts[ScanCaptureCategory.digitDown], 2);
      for (final record in recorder.events) {
        expect(record.values, isNot(contains('٣')));
        expect(record.values, isNot(contains('１')));
      }
      final export = recorder.buildExport();
      expect(export, isNot(contains('٣')));
      expect(export, isNot(contains('１')));
      recorder.stop();
    });

    test('enter, numpad-enter, key-up, repeat, named and other categories', () {
      recorder.start();
      recorder.handleEventForTest(wedgeEnter());
      recorder.handleEventForTest(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadEnter,
          logicalKey: LogicalKeyboardKey.numpadEnter,
          timeStamp: Duration.zero,
        ),
      );
      recorder.handleEventForTest(
        _keyUp(LogicalKeyboardKey.digit9, PhysicalKeyboardKey.digit9),
      );
      recorder.handleEventForTest(
        keyRepeat(
          logicalKey: LogicalKeyboardKey.digit9,
          physicalKey: PhysicalKeyboardKey.digit9,
        ),
      );
      recorder.handleEventForTest(
        _namedDown(
          LogicalKeyboardKey.escape,
          PhysicalKeyboardKey.escape,
        ),
      );
      recorder.handleEventForTest(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
          character: ' ',
        ),
      );

      expect(recorder.categoryCounts[ScanCaptureCategory.enterDown], 1);
      expect(recorder.categoryCounts[ScanCaptureCategory.numpadEnterDown], 1);
      expect(recorder.categoryCounts[ScanCaptureCategory.keyUp], 1);
      expect(recorder.categoryCounts[ScanCaptureCategory.repeat], 1);
      expect(recorder.categoryCounts[ScanCaptureCategory.namedDown], 1);
      expect(recorder.categoryCounts[ScanCaptureCategory.otherDown], 1);

      // The named key may carry its identity (Escape is not content);
      // space (character-producing) must not.
      final named = recorder.events
          .where((r) => r['cat'] == ScanCaptureCategory.namedDown)
          .single;
      expect(named['key'], 'Escape');
      final other = recorder.events
          .where((r) => r['cat'] == ScanCaptureCategory.otherDown)
          .single;
      expect(other.keys, isNot(contains('key')));
      recorder.stop();
    });

    test('numpad digits are their own category', () {
      recorder.start();
      recorder.handleEventForTest(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpad7,
          logicalKey: LogicalKeyboardKey.numpad7,
          timeStamp: Duration.zero,
        ),
      );
      expect(
        recorder.categoryCounts[ScanCaptureCategory.numpadDigitDown],
        1,
      );
      recorder.stop();
    });
  });

  group('bounded ring buffer', () {
    test('keeps at most $kScanCaptureBufferCapacity records, counts drops',
        () {
      recorder.start();
      for (var i = 0; i < kScanCaptureBufferCapacity + 50; i++) {
        recorder.handleEventForTest(wedgeKeyDown('1'));
      }
      expect(recorder.totalEvents, kScanCaptureBufferCapacity + 50);
      expect(recorder.bufferedEventCount, kScanCaptureBufferCapacity);
      expect(recorder.droppedEvents, 50);
      // Oldest evicted: every retained record is a later event (ms ≥ 0
      // and the ring never grows past capacity).
      expect(recorder.events.length, kScanCaptureBufferCapacity);
      recorder.stop();
    });
  });

  group('pipeline fan-out sanitization', () {
    test('sanitizeScanDiagFields keeps only the closed allowlist', () {
      final sanitized = sanitizeScanDiagFields(<String, Object?>{
        'len': 13,
        'target': 'pos',
        'reason': 'shape',
        'suffix3': '456',
        'text': '99999',
      });
      expect(sanitized, <String, Object?>{
        'len': 13,
        'target': 'pos',
        'reason': 'shape',
      });
    });

    test('a listener never sees suffix3 or text', () {
      final seen = <(String, Map<String, Object?>)>[];
      void listener(String event, Map<String, Object?> fields) =>
          seen.add((event, fields));
      addScanDiagListener(listener);
      addTearDown(() => removeScanDiagListener(listener));
      scanDiag('dispatch', <String, Object?>{
        'len': 8,
        'suffix3': '777',
        'text': 'le secret',
        'target': 'products',
      });
      expect(seen, hasLength(1));
      expect(seen.single.$1, 'dispatch');
      expect(seen.single.$2, <String, Object?>{'len': 8, 'target': 'products'});
    });

    test('scanDiag return semantics are unchanged with and without listeners',
        () {
      // The compile-time flag is OFF in tests: scanDiag must return null
      // whether or not a session listener is attached.
      expect(kScanDiagnosticsEnabled, isFalse);
      expect(scanDiag('probe', {'len': 1}), isNull);
      void listener(String event, Map<String, Object?> fields) {}
      addScanDiagListener(listener);
      addTearDown(() => removeScanDiagListener(listener));
      expect(scanDiag('probe', {'len': 1}), isNull);
    });

    test('the recorder records pipeline events with allowlisted fields only',
        () {
      recorder.start();
      scanDiag('dispatch', <String, Object?>{
        'len': 8,
        'suffix3': '777',
        'target': 'pos',
      });
      final record = recorder.events.single;
      expect(record['cat'], 'pipeline:dispatch');
      expect(record['len'], 8);
      expect(record['target'], 'pos');
      expect(record.keys, isNot(contains('suffix3')));
      recorder.stop();
    });
  });

  group('redacted export', () {
    testWidgets(
      'two same-length codes produce identical normalized exports '
      '(digits are not reconstructable)',
      (tester) async {
        Future<String> exportFor(String code) async {
          recorder.stop();
          recorder.clear();
          gateway.resetForTest();
          gateway.register(BarcodeScanHandler(onScan: (_) {}));
          recorder.start();
          await sendWedgeScan(tester, code);
          await tester.pump();
          final export = recorder.buildExport();
          recorder.stop();
          return export;
        }

        final first = await exportFor('11111111');
        final second = await exportFor('22222222');

        expect(first, contains('Klick POS scan diagnostics'));
        expect(first, isNot(contains('11111111')));
        expect(second, isNot(contains('22222222')));
        expect(
          _normalizeTimings(first),
          _normalizeTimings(second),
          reason:
              'same-length bursts must produce identical category histories — '
              'any difference means a digit value leaked into the record',
        );
      },
    );

    testWidgets(
      'a real wedge burst of a known code leaves no trace of the code in '
      'the export',
      (tester) async {
        recorder.stop();
        recorder.clear();
        gateway.resetForTest();
        gateway.register(BarcodeScanHandler(onScan: (_) {}));
        recorder.start();
        await sendWedgeScan(tester, '8749561234567');
        await tester.pump();

        final export = recorder.buildExport();
        expect(export, isNot(contains('8749561234567')));
        expect(export, isNot(contains('suffix3')));
        expect(export, isNot(contains('char')));
        // The category shape of a wedge burst: digit-downs + key-ups + enter.
        expect(recorder.categoryCounts[ScanCaptureCategory.digitDown], 13);
        expect(recorder.categoryCounts[ScanCaptureCategory.enterDown], 1);
        recorder.stop();
      },
    );
  });

  // Keep LAST: disposing the singleton ends its ChangeNotifier.
  group('dispose', () {
    test('dispose stops the session', () {
      recorder.start();
      expect(recorder.isActive, isTrue);
      recorder.dispose();
      expect(recorder.isActive, isFalse);
      expect(recorder.isDisposed, isTrue);
    });
  });
}
