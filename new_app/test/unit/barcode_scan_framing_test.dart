// Scan framing — the gateway's burst-boundary rules.
//
// A keyboard-wedge scanner is an ordinary keyboard: a run of digits and an
// Enter. Everything that makes a POS scanner "sometimes right, sometimes
// wrong" lives in WHERE one burst ends and the next begins:
//
//  * a run that loses its terminator (lost Enter, a dialog that swallowed
//    it, a scanner with its suffix disabled) must NOT be glued onto the
//    next physical scan — that produced one impossible code, i.e. "it
//    read the wrong barcode" and "the product does not exist although it
//    does";
//  * a burst that DID terminate must leave no residue, so fast
//    consecutive scans and fast double-scans of one product dispatch
//    twice, in order, and never once;
//  * layout translation (AZERTY symbols for a US-configured scanner,
//    Arabic-Indic digits) must end at the SAME string as the US burst —
//    the lookup compares strings, not key identities.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/barcode/barcode_normalizer.dart';

import '../helpers/wedge_scanner.dart';

/// One wedge key-down carrying an explicit engine timestamp (a run's
/// framing is decided by the gaps between these).
KeyDownEvent _digitAt(String character, Duration at) {
  final base = wedgeKeyDown(character) as KeyDownEvent;
  return KeyDownEvent(
    physicalKey: base.physicalKey,
    logicalKey: base.logicalKey,
    timeStamp: at,
    character: character,
  );
}

/// The Enter terminator at [at].
KeyDownEvent _enterAt(Duration at) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: at,
      character: '\n',
    );

/// Position of each French-AZERTY number-row symbol on the US main row —
/// what a US-configured scanner emits when Windows runs AZERTY.
const Map<String, String> _azertyRowDigit = <String, String>{
  '&': '1',
  'é': '2',
  '"': '3',
  "'": '4',
  '(': '5',
  '-': '6',
  'è': '7',
  '_': '8',
  'ç': '9',
  'à': '0',
};

/// One foreign-layout key-down: the physical US digit key with the
/// layout-translated [character] the engine delivered.
KeyDownEvent _foreignDigitAt(String character, Duration at) {
  final base = wedgeKeyDown(_azertyRowDigit[character]!) as KeyDownEvent;
  return KeyDownEvent(
    physicalKey: base.physicalKey,
    logicalKey: base.logicalKey,
    timeStamp: at,
    character: character,
  );
}

/// Types [code] as one clean burst starting at [start] (one millisecond
/// between characters, the way a wedge types it) and returns the time of
/// the last character.
Duration _burst(
  BarcodeScannerGateway gateway,
  String code, {
  required Duration start,
  bool enter = true,
}) {
  var at = start;
  for (final character in code.split('')) {
    gateway.handleKeyForTest(_digitAt(character, at));
    at += const Duration(milliseconds: 1);
  }
  if (enter) gateway.handleKeyForTest(_enterAt(at));
  return at;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gateway = BarcodeScannerGateway.instance;

  setUp(gateway.resetForTest);
  tearDown(gateway.resetForTest);

  group('burst framing across scans', () {
    test('ten consecutive scans of one code dispatch ten codes, in order', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));
      const code = '8718114202402';

      for (var i = 0; i < 10; i++) {
        _burst(gateway, code, start: Duration(milliseconds: i * 400));
        expect(
          gateway.bufferedDigitCount,
          0,
          reason: 'a terminated burst leaves no residue behind',
        );
      }

      expect(codes, List<String>.filled(10, code));
    });

    test('an incomplete scan followed by a valid scan dispatches only the '
        'valid code', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      // A burst that never terminated (5 digits — no Enter reached the
      // app). It must not become the prefix of the next scan.
      _burst(
        gateway,
        '12345',
        start: Duration.zero,
        enter: false,
      );
      expect(gateway.bufferedDigitCount, 5);

      // The cashier scans again, well over [kBarcodeRunStaleGap] later.
      _burst(gateway, '8718114202402', start: const Duration(seconds: 2));

      expect(
        codes,
        ['8718114202402'],
        reason: 'the orphaned residue is dropped, never glued on',
      );
      expect(gateway.bufferedDigitCount, 0);
    });

    test('a scan followed immediately by another scan dispatches both', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      _burst(gateway, '4006381333931', start: Duration.zero);
      // Back-to-back: the very next millisecond after the first terminator.
      _burst(
        gateway,
        '4006381333931',
        start: const Duration(milliseconds: 20),
      );

      expect(codes, ['4006381333931', '4006381333931']);
    });

    test('a pause mid-run restarts the run instead of merging the two '
        'halves', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      // First half, then a pause far longer than one burst's inter-key gap.
      var at = _burst(
        gateway,
        '8718',
        start: Duration.zero,
        enter: false,
      );
      at += const Duration(seconds: 1);
      for (final character in '114202402'.split('')) {
        at += const Duration(milliseconds: 1);
        gateway.handleKeyForTest(_digitAt(character, at));
      }
      gateway.handleKeyForTest(_enterAt(at));

      expect(
        codes,
        ['114202402'],
        reason: 'digits separated by more than one burst are two runs',
      );
    });

    test('a genuine re-scan of one code is never dropped as a duplicate of '
        'the raw observation that preceded it', () async {
      var calls = 0;
      gateway.register(BarcodeScanHandler(onScan: (_) => calls++));
      gateway.resetDispatchDedupForTest();

      // Scan 1 observed by the raw-input path (its legacy Enter was
      // suppressed by the native layer, or arrived out of order)…
      expect(gateway.dispatchExternalScan('8718114202402'), isTrue);
      // …then the cashier scans the SAME product again a moment later.
      // A window wide enough to cover that pause swallowed the second
      // physical scan: the re-scan never reached the cart.
      await Future<void>.delayed(
        const Duration(
          milliseconds: BarcodeScannerGateway.kCrossOriginDispatchDupMs + 40,
        ),
      );
      _burst(gateway, '8718114202402', start: const Duration(seconds: 5));

      expect(calls, 2, reason: 'two trigger pulls, two actions');
    });

    test('a human quantity (short digit run + Enter) never dispatches', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      _burst(gateway, '12', start: Duration.zero);

      expect(codes, isEmpty);
    });
  });

  group('layout independence', () {
    test('a US burst and its AZERTY-symbol equivalent normalize to the same '
        'code', () {
      const usCode = '1234567890';
      // The same number row on French AZERTY, unshifted.
      const azertyCode = '&é"\u0027(-è_çà';

      expect(normalizeScannerBarcode(azertyCode), usCode);

      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add));

      _burst(gateway, usCode, start: Duration.zero);
      var at = const Duration(seconds: 1);
      for (final character in azertyCode.split('')) {
        gateway.handleKeyForTest(_foreignDigitAt(character, at));
        at += const Duration(milliseconds: 1);
      }
      gateway.handleKeyForTest(_enterAt(at));

      expect(codes, [usCode, usCode]);
    });

    test('Arabic-Indic digits normalize to ASCII digits', () {
      expect(normalizeScannerBarcode('٤٠٠٦٣٨١٣٣٣٩٣١'), '4006381333931');
    });
  });

  group('barcode normalization', () {
    test('leading zeros are preserved, never stripped or coerced to a number',
        () {
      expect(normalizeScannerBarcode('0045600012345'), '0045600012345');
      expect(normalizeBarcode(' 0045600012345\n'), '0045600012345');
    });

    test('EAN-8 and UPC-A lengths survive untouched', () {
      expect(normalizeScannerBarcode('96385074'), '96385074');
      expect(normalizeScannerBarcode('036000291452'), '036000291452');
    });

    test('internal whitespace in ordinary search text is never discarded', () {
      expect(normalizeBarcode('milk 1l'), 'milk 1l');
    });
  });
}
