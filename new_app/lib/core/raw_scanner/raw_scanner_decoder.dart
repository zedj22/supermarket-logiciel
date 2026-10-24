// EXPERIMENTAL — raw-input barcode decoding for the isolated scanner PoC
// (`raw_scanner_poc.dart`, runner module `windows/runner/raw_scanner_input.*`).
//
// What this class is: the second half of a device-scoped scan path. The
// runner's Raw Input hook observes one LEARNED scanner device by its HID
// identity, forwards its raw MakeCodes (scan codes + E0/E1 + break state,
// never a translated character) to Dart, and suppresses the matching
// legacy WM_KEYDOWN/WM_KEYUP/WM_CHAR messages so the Flutter engine never
// performs a layout translation of them. This decoder reconstructs the
// characters locally — from the SCANNER's own declared keyboard-country
// table — so the WINDOWS keyboard layout (en-US, fr-FR, ar-DZ …) plays no
// role anywhere: no symbol→digit heuristics, no synthesized Shift, no
// input-layout changes, nothing global.
//
// Tables are probe evidence, not folklore: `layout_probe.ps1`
// (ToUnicodeEx per installed layout on this machine) produced, verbatim:
//  * us — 00000409: number row 0x02..0x0B → 1..9,0 unshifted, symbols
//    shifted (the US-configured scanner's own table);
//  * fr — 0000040C: number row &é"'(-è_çà) with the ASCII digits on the
//    SHIFT layer (an FR-configured scanner reaches a digit as Shift+key),
//    AZERTY letter positions, 0x1A is a DEAD key — omitted here, so a
//    dead make aborts the run instead of silently corrupting it;
//  * ar — 00020401 (Arabic/Algeria): the number row is identical to FR
//    (digits on the shift layer) with Arabic letters on the letter keys;
//    multi-UTF-16-unit values (e.g. lam+hamza) are kept whole.
// Control keys (backspace/tab/ctrl/alt), the dead key, keys the probe
// reported as `<none>` and every scan code absent from a table are
// NON-decodable: they reset the run — the same "a non-digit key kills the
// burst" contract the ordinary gateway applies to typing.
//
// Run rules (mirroring `barcode_scanner.dart`):
//  * only key-downs append (breaks and autorepeats never do — a held key
//    can never fabricate a barcode);
//  * a pause longer than [kBarcodeRunStaleGap] between two characters
//    restarts the run, so slow human typing can never accumulate into a
//    scan-shaped buffer;
//  * Enter (main row or E0/numpad) terminates: whatever accumulated is
//    returned to the caller, which applies [kBarcodeScanShape] before any
//    dispatch (the gateway double-checks the shape too).
//
// The shift layer is tracked from the RAW stream itself (scan codes
// 0x2A / E0-0x36 make and break) — never from any modifier the Windows
// layout state might claim, and never synthesized.
import '../barcode_scanner.dart' show kBarcodeRunStaleGap;

/// One raw keyboard event as forwarded by the runner module (see
/// `raw_scanner_input.cpp`): identity of the key on the DEVICE, the break
/// state, the native sequence counter and the Dart-side arrival clock in
/// milliseconds (the platform event carries no timestamp of its own).
class RawScanKey {
  const RawScanKey({
    required this.make,
    required this.e0,
    required this.e1,
    required this.up,
    required this.seq,
    required this.receivedAtMs,
  });

  /// HID scan code (0..0xFF), untranslated.
  final int make;

  /// Extended-key flag (E0) as reported by the raw packet.
  final bool e0;

  /// E1 flag as reported by the raw packet (right Ctrl / Pause family).
  final bool e1;

  /// `true` for a break (key-up) packet.
  final bool up;

  /// Native monotonic raw-event counter — ordering evidence only.
  final int seq;

  /// Dart-side arrival time (`DateTime.now().millisecondsSinceEpoch`).
  final int receivedAtMs;

  /// Packed key identity used by every table: make | E0 (0x100) |
  /// E1 (0x200) — the same packing `raw_scanner_input.cpp` uses.
  int get packed => (make & 0xFF) | (e0 ? 0x100 : 0) | (e1 ? 0x200 : 0);
}

/// Device-table decoder: raw key events in, completed code runs out.
class RawScannerDecoder {
  RawScannerDecoder({this.layout = kRawScannerLayoutUs});

  /// The scanner's DECLARED keyboard country — what the device itself
  /// emulates, not what Windows is set to. One of
  /// [supportedLayouts].
  String layout;

  /// Layouts with probe-evidenced tables (see file header).
  static const List<String> supportedLayouts = <String>[
    kRawScannerLayoutUs,
    kRawScannerLayoutFr,
    kRawScannerLayoutAr,
  ];

  static const int _shiftLeft = 0x2A;
  static const int _shiftRight = 0x136; // E0-0x36
  static const int _enter = 0x1C;
  static const int _numpadEnter = 0x11C; // E0-0x1C

  /// Number-pad digits (NumLock on): HID usage positions, layout
  /// independent, identical on every table. The probe's scan list did not
  /// cover the pad; these are the standard Windows digit scan codes. No
  /// pad decimal/numlock/nav key is decodable — they abort the run.
  static const Map<int, String> _numpadDigits = <int, String>{
    0x47: '7',
    0x48: '8',
    0x49: '9',
    0x4B: '4',
    0x4C: '5',
    0x4D: '6',
    0x4F: '1',
    0x50: '2',
    0x51: '3',
    0x52: '0',
  };

  // ---------------------------------------------------------------------
  // us — layout 00000409 (probe verbatim).
  // ---------------------------------------------------------------------
  static const Map<int, String> _usPlain = <int, String>{
    0x02: '1', 0x03: '2', 0x04: '3', 0x05: '4', 0x06: '5', 0x07: '6',
    0x08: '7', 0x09: '8', 0x0A: '9', 0x0B: '0', 0x0C: '-', 0x0D: '=',
    0x10: 'q', 0x11: 'w', 0x12: 'e', 0x13: 'r', 0x14: 't', 0x15: 'y',
    0x16: 'u', 0x17: 'i', 0x18: 'o', 0x19: 'p', 0x1A: '[', 0x1B: ']',
    0x1E: 'a', 0x1F: 's', 0x20: 'd', 0x21: 'f', 0x22: 'g', 0x23: 'h',
    0x24: 'j', 0x25: 'k', 0x26: 'l', 0x27: ';',
    0x2C: 'z', 0x2D: 'x', 0x2E: 'c', 0x2F: 'v', 0x30: 'b', 0x31: 'n',
    0x32: 'm', 0x28: "'", 0x29: '`', 0x2B: '\\',
    0x33: ',', 0x34: '.', 0x35: '/', 0x39: ' ',
  };

  static const Map<int, String> _usShifted = <int, String>{
    0x02: '!', 0x03: '@', 0x04: '#', 0x05: '\$', 0x06: '%', 0x07: '^',
    0x08: '&', 0x09: '*', 0x0A: '(', 0x0B: ')', 0x0C: '_', 0x0D: '+',
    0x10: 'Q', 0x11: 'W', 0x12: 'E', 0x13: 'R', 0x14: 'T', 0x15: 'Y',
    0x16: 'U', 0x17: 'I', 0x18: 'O', 0x19: 'P', 0x1A: '{', 0x1B: '}',
    0x1E: 'A', 0x1F: 'S', 0x20: 'D', 0x21: 'F', 0x22: 'G', 0x23: 'H',
    0x24: 'J', 0x25: 'K', 0x26: 'L', 0x27: ':',
    0x2C: 'Z', 0x2D: 'X', 0x2E: 'C', 0x2F: 'V', 0x30: 'B', 0x31: 'N',
    0x32: 'M', 0x28: '"', 0x29: '~', 0x2B: '|',
    0x33: '<', 0x34: '>', 0x35: '?', 0x39: ' ',
  };

  // ---------------------------------------------------------------------
  // fr — layout 0000040C (probe verbatim). 0x1A is DEAD on both layers
  // and 0x29 has no shifted value — both omitted (non-decodable).
  // ---------------------------------------------------------------------
  static const Map<int, String> _frPlain = <int, String>{
    0x02: '&', 0x03: '\u00E9', 0x04: '"', 0x05: "'", 0x06: '(',
    0x07: '-', 0x08: '\u00E8', 0x09: '_', 0x0A: '\u00E7', 0x0B: '\u00E0',
    0x0C: ')', 0x0D: '=',
    0x10: 'a', 0x11: 'z', 0x12: 'e', 0x13: 'r', 0x14: 't', 0x15: 'y',
    0x16: 'u', 0x17: 'i', 0x18: 'o', 0x19: 'p', 0x1B: '\$',
    0x1E: 'q', 0x1F: 's', 0x20: 'd', 0x21: 'f', 0x22: 'g', 0x23: 'h',
    0x24: 'j', 0x25: 'k', 0x26: 'l', 0x27: 'm',
    0x2C: 'w', 0x2D: 'x', 0x2E: 'c', 0x2F: 'v', 0x30: 'b', 0x31: 'n',
    0x32: ',', 0x28: '\u00F9', 0x29: '\u00B2', 0x2B: '*',
    0x33: ';', 0x34: ':', 0x35: '!', 0x39: ' ',
  };

  static const Map<int, String> _frShifted = <int, String>{
    0x02: '1', 0x03: '2', 0x04: '3', 0x05: '4', 0x06: '5', 0x07: '6',
    0x08: '7', 0x09: '8', 0x0A: '9', 0x0B: '0', 0x0C: '\u00B0',
    0x0D: '+',
    0x10: 'A', 0x11: 'Z', 0x12: 'E', 0x13: 'R', 0x14: 'T', 0x15: 'Y',
    0x16: 'U', 0x17: 'I', 0x18: 'O', 0x19: 'P', 0x1B: '\u00A3',
    0x1E: 'Q', 0x1F: 'S', 0x20: 'D', 0x21: 'F', 0x22: 'G', 0x23: 'H',
    0x24: 'J', 0x25: 'K', 0x26: 'L', 0x27: 'M',
    0x2C: 'W', 0x2D: 'X', 0x2E: 'C', 0x2F: 'V', 0x30: 'B', 0x31: 'N',
    0x32: '?', 0x28: '%', 0x2B: '\u00B5',
    0x33: '.', 0x34: '/', 0x35: '\u00A7', 0x39: ' ',
  };

  // ---------------------------------------------------------------------
  // ar — layout 00020401, Arabic (Algeria): the number row is FR-style
  // (digits on the SHIFT layer), the letter keys are Arabic (probe
  // verbatim; multi-unit values kept whole). 0x1F has no shifted value —
  // omitted (non-decodable).
  // ---------------------------------------------------------------------
  static const Map<int, String> _arPlain = <int, String>{
    0x02: '&', 0x03: '\u00E9', 0x04: '"', 0x05: "'", 0x06: '(',
    0x07: '-', 0x08: '\u00E8', 0x09: '_', 0x0A: '\u00E7', 0x0B: '\u00E0',
    0x0C: ')', 0x0D: '=',
    0x10: '\u0636', 0x11: '\u0635', 0x12: '\u062B', 0x13: '\u0642',
    0x14: '\u0641', 0x15: '\u063A', 0x16: '\u0639', 0x17: '\u0647',
    0x18: '\u062E', 0x19: '\u062D', 0x1A: '\u062C', 0x1B: '\u062F',
    0x1E: '\u0634', 0x1F: '\u0633', 0x20: '\u064A', 0x21: '\u0628',
    0x22: '\u0644', 0x23: '\u0627', 0x24: '\u062A', 0x25: '\u0646',
    0x26: '\u0645', 0x27: '\u0643',
    0x2C: '\u0626', 0x2D: '\u0621', 0x2E: '\u0624', 0x2F: '\u0631',
    0x30: '\u0644\u0627', 0x31: '\u0649', 0x32: '\u0629',
    0x29: '>', 0x2B: '\u0630', 0x28: '\u0637',
    0x33: '\u0648', 0x34: '\u0632', 0x35: '\u0638', 0x39: ' ',
  };

  static const Map<int, String> _arShifted = <int, String>{
    0x02: '1', 0x03: '2', 0x04: '3', 0x05: '4', 0x06: '5', 0x07: '6',
    0x08: '7', 0x09: '8', 0x0A: '9', 0x0B: '0', 0x0C: '\u00B0',
    0x0D: '+',
    0x10: '\u064E', 0x11: '\u064B', 0x12: '\u064F', 0x13: '\u064C',
    0x14: '\u0644\u0625', 0x15: '\u0625', 0x16: '\u2018', 0x17: '\u00F7',
    0x18: '\u00D7', 0x19: '\u061B', 0x1A: '}', 0x1B: '{',
    0x1E: '\\', 0x20: ']', 0x21: '[',
    0x22: '\u0644\u0623', 0x23: '\u0623', 0x24: '\u0640', 0x25: '\u060C',
    0x26: '/', 0x27: ':',
    0x2C: '~', 0x2D: '\u0652', 0x2E: '\u0650', 0x2F: '\u064D',
    0x30: '\u0644\u0622', 0x31: '\u0622', 0x32: '\u2019',
    0x29: '<', 0x2B: '\u0651', 0x28: '"',
    0x33: ',', 0x34: '.', 0x35: '\u061F', 0x39: ' ',
  };

  /// Characters of the run in progress (bookkeeping only — the panel
  /// shows its LENGTH, never content).
  final StringBuffer _buffer = StringBuffer();

  /// Keys currently down on the device (break not yet seen): the guard
  /// against raw autorepeat makes — the second make without an
  /// intervening break is ignored, so holding a key never appends twice.
  final Set<int> _held = <int>{};

  /// Shift keys currently down, tracked from raw break state alone.
  final Set<int> _shiftKeys = <int>{};

  int? _lastCharAtMs;

  /// Evidence counters for the hardware report.
  int unknownKeys = 0;

  /// Feed one raw key event. Returns the completed run when a TERMINATOR
  /// (Enter) ends a non-empty run — the caller applies the scan shape —
  /// and `null` for every other event.
  String? feed(RawScanKey key) {
    final packed = key.packed;

    if (packed == _shiftLeft || packed == _shiftRight) {
      // Modifier state for the shift layer; never part of the buffer.
      if (key.up) {
        _shiftKeys.remove(packed);
      } else {
        _shiftKeys.add(packed);
      }
      return null;
    }

    if (key.up) {
      _held.remove(packed);
      return null;
    }
    if (_held.contains(packed)) {
      // Autorepeat (a repeat make with no break between): ignore.
      return null;
    }
    _held.add(packed);

    if (packed == _enter || packed == _numpadEnter) {
      if (_stale(key.receivedAtMs)) _resetRun();
      final code = _buffer.toString();
      _resetRun();
      return code.isEmpty ? null : code;
    }

    if (_stale(key.receivedAtMs)) _resetRun();

    final tables = _tables();
    final layer = _shiftKeys.isEmpty ? tables.plain : tables.shifted;
    final character = layer[packed] ?? _numpadDigits[packed];
    if (character == null) {
      // Non-decodable on this scanner table (control key, dead key, a
      // layer the probe reports as `<none>`, F-key, nav key, …): a key
      // that is not part of a run kills the run — exactly like the
      // ordinary gateway treats any non-digit.
      unknownKeys++;
      _resetRun();
      return null;
    }
    _buffer.write(character);
    _lastCharAtMs = key.receivedAtMs;
    return null;
  }

  /// Drops the current run and all held-key state (layout switch, PoC
  /// disable, test hermeticity).
  void reset() {
    _buffer.clear();
    _held.clear();
    _shiftKeys.clear();
    _lastCharAtMs = null;
  }

  /// Characters currently buffered (length only — content is never
  /// rendered anywhere).
  int get bufferedLength => _buffer.length;

  /// Whether a Shift key is currently down per the raw stream.
  bool get shiftHeld => _shiftKeys.isNotEmpty;

  /// The [kBarcodeRunStaleGap] rule from `barcode_scanner.dart`: a pause
  /// longer than the gap means the buffered residue describes typing, not
  /// one burst. The zero-advancing clock seam never qualifies (mirroring
  /// the gateway's timestamp rule).
  bool _stale(int nowMs) {
    final last = _lastCharAtMs;
    if (last == null) return false;
    return nowMs > last && nowMs - last > kBarcodeRunStaleGap.inMilliseconds;
  }

  void _resetRun() {
    _buffer.clear();
    _lastCharAtMs = null;
  }

  ({Map<int, String> plain, Map<int, String> shifted}) _tables() {
    switch (layout) {
      case kRawScannerLayoutFr:
        return (plain: _frPlain, shifted: _frShifted);
      case kRawScannerLayoutAr:
        return (plain: _arPlain, shifted: _arShifted);
      default:
        return (plain: _usPlain, shifted: _usShifted);
    }
  }
}

/// Scanner keyboard-country ids (panel options, decoder tables).
const String kRawScannerLayoutUs = 'us';
const String kRawScannerLayoutFr = 'fr';
const String kRawScannerLayoutAr = 'ar';
