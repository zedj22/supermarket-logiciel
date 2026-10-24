// EXPERIMENTAL raw-scanner decoder (lib/core/raw_scanner/
// raw_scanner_decoder.dart) — proves the DECODING half of the PoC
// contract without any Windows dependency:
//
//  * us (default): raw MakeCodes decode to the US table's characters,
//    Enter/E0-Enter terminate, numpad digits work, breaks and autorepeat
//    never append, a non-decodable make kills the run, and a gap beyond
//    kBarcodeRunStaleGap restarts it;
//  * fr: the ASCII digits live on the SHIFT layer — tracked from raw
//    shift make/break packets alone (probe evidence: number row
//    &é"'(-è_çà with 1–0 shifted), the dead key 0x1A aborts;
//  * ar (Algeria, 00020401): the number row mirrors FR (digits shifted),
//    Arabic letter keys buffer their probe characters.
//
// Everything here is the scanner's own table — the Windows layout, symbol
// heuristics and Shift synthesis are structurally absent.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/raw_scanner/raw_scanner_decoder.dart';

void main() {
  /// Monotonic millisecond clock for the run-staleness rule (each feed
  /// advances it by 10ms — far below kBarcodeRunStaleGap).
  var now = 0;

  RawScanKey packet(
    int make, {
    bool e0 = false,
    bool isUp = false,
  }) {
    now += 10;
    return RawScanKey(
      make: make,
      e0: e0,
      e1: false,
      up: isUp,
      seq: now,
      receivedAtMs: now,
    );
  }

  /// One make/break press; returns the terminator result when [make] is
  /// an Enter.
  String? press(RawScannerDecoder decoder, int make, {bool e0 = false}) {
    final result = decoder.feed(packet(make, e0: e0));
    decoder.feed(packet(make, e0: e0, isUp: true));
    return result;
  }

  /// Shift + one number-row make/break (both shift keys held around the
  /// digit, exactly like a wedge that emulates the FR/AR layout).
  String? shiftPress(RawScannerDecoder decoder, int make) {
    decoder.feed(packet(0x2A));
    final result = decoder.feed(packet(make));
    decoder.feed(packet(make, isUp: true));
    decoder.feed(packet(0x2A, isUp: true));
    return result;
  }

  setUp(() {
    now = 0;
  });

  group('us table (default scanner layout)', () {
    test('digit burst + Enter decodes the run and resets', () {
      final decoder = RawScannerDecoder();
      for (final make in <int>[0x02, 0x03, 0x04, 0x05, 0x06, 0x07]) {
        expect(press(decoder, make), isNull);
      }
      expect(decoder.bufferedLength, 6);
      expect(press(decoder, 0x1C), '123456');
      expect(decoder.bufferedLength, 0, reason: 'terminator clears the run');
    });

    test('the E0 (extended) Enter terminates as well', () {
      final decoder = RawScannerDecoder();
      press(decoder, 0x02);
      press(decoder, 0x03);
      expect(press(decoder, 0x1C, e0: true), '12');
    });

    test('Enter with an empty run dispatches nothing', () {
      final decoder = RawScannerDecoder();
      expect(press(decoder, 0x1C), isNull);
    });

    test('numpad digits decode (layout-independent scan codes)', () {
      final decoder = RawScannerDecoder();
      press(decoder, 0x4F);
      press(decoder, 0x50);
      press(decoder, 0x51);
      expect(press(decoder, 0x1C), '123');
    });

    test('breaks and autorepeat makes never append', () {
      final decoder = RawScannerDecoder();
      decoder.feed(packet(0x02));
      decoder.feed(packet(0x02)); // autorepeat make, no break between
      expect(decoder.bufferedLength, 1, reason: 'repeat ignored');
      decoder.feed(packet(0x02, isUp: true));
      decoder.feed(packet(0x02)); // real second press after the break
      expect(decoder.bufferedLength, 2);
    });

    test('a non-decodable make aborts the run (gateway contract)', () {
      final decoder = RawScannerDecoder();
      press(decoder, 0x02);
      press(decoder, 0x03);
      decoder.feed(packet(0x57)); // F11 — in no table
      expect(decoder.bufferedLength, 0);
      expect(decoder.unknownKeys, 1);
      expect(press(decoder, 0x1C), isNull,
          reason: 'the killed run cannot terminate');
    });

    test('a gap beyond kBarcodeRunStaleGap restarts the run', () {
      final decoder = RawScannerDecoder();
      press(decoder, 0x02);
      press(decoder, 0x03);
      press(decoder, 0x04);
      now += 1000; // human pause > 400ms
      press(decoder, 0x07); // a fresh digit starts a fresh run
      expect(decoder.bufferedLength, 1);
      expect(press(decoder, 0x1C), '6',
          reason: 'the stale residue must not survive into the run');
    });

    test('shift is tracked from raw packets and never buffered itself', () {
      final decoder = RawScannerDecoder();
      decoder.feed(packet(0x2A));
      expect(decoder.shiftHeld, isTrue);
      expect(decoder.bufferedLength, 0);
      decoder.feed(packet(0x02)); // shifted US layer → '!'
      decoder.feed(packet(0x02, isUp: true));
      decoder.feed(packet(0x2A, isUp: true));
      expect(decoder.shiftHeld, isFalse);
      expect(decoder.bufferedLength, 1);
      expect(press(decoder, 0x1C), '!'); // shape rejection is the caller's
    });
  });

  group('fr table (probe: digits on the shift layer)', () {
    test('shift + number row decodes ASCII digits', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutFr;
      shiftPress(decoder, 0x02); // Shift+&-key → 1
      shiftPress(decoder, 0x09); // Shift+_ -key → 8
      expect(press(decoder, 0x1C), '18');
    });

    test('the unshifted number row buffers the FR symbols as probed', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutFr;
      press(decoder, 0x02); // '&'
      press(decoder, 0x03); // 'é'
      expect(press(decoder, 0x1C), '&é',
          reason: 'faithful capture — shape rejection happens downstream');
    });

    test('the dead key 0x1A aborts instead of corrupting the run', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutFr;
      press(decoder, 0x02);
      decoder.feed(packet(0x1A));
      expect(decoder.bufferedLength, 0);
      expect(decoder.unknownKeys, 1);
    });

    test('AZERTY letter positions decode (q at 0x1E)', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutFr;
      press(decoder, 0x1E);
      expect(press(decoder, 0x1C), 'q');
    });
  });

  group('ar table (Algeria 00020401: FR-style number row)', () {
    test('digits come from the shift layer, like FR', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutAr;
      shiftPress(decoder, 0x05); // → 4
      shiftPress(decoder, 0x06); // → 5
      expect(press(decoder, 0x1C), '45');
    });

    test('Arabic letter keys buffer their probe characters', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutAr;
      press(decoder, 0x23); // 'ا' (alef) as probed
      expect(press(decoder, 0x1C), 'ا');
    });

    test('the unshifted number row is FR-style (& é " …)', () {
      final decoder = RawScannerDecoder()..layout = kRawScannerLayoutAr;
      press(decoder, 0x02); // '&'
      press(decoder, 0x03); // 'é'
      expect(press(decoder, 0x1C), '&é');
    });
  });

  test('exactly three probe-evidenced layouts are offered', () {
    expect(
      RawScannerDecoder.supportedLayouts,
      <String>[kRawScannerLayoutUs, kRawScannerLayoutFr, kRawScannerLayoutAr],
    );
  });

  test('reset() drops buffer and held keys (hermeticity)', () {
    final decoder = RawScannerDecoder();
    press(decoder, 0x02);
    decoder.feed(packet(0x2A)); // shift held across the reset
    decoder.reset();
    expect(decoder.bufferedLength, 0);
    expect(decoder.shiftHeld, isFalse);
    expect(press(decoder, 0x1C), isNull);
  });
}
