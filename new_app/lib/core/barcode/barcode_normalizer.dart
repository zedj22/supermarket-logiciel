/// Normalizes scanner tokens without coercing product codes to numbers.
///
/// The symbol mapping is specific to a scanner emitting a US number-row
/// burst through a French AZERTY layout. It is applied only when the whole
/// token becomes numeric, so ordinary search text and internal codes remain
/// untouched.
String normalizeBarcode(String raw) {
  return _normalizeBarcode(raw, allowMixedScannerDigits: false);
}

/// Normalizes a run already confirmed by the keyboard-wedge scanner path.
/// The gateway has verified that each key came from a number-row digit key,
/// so a scanner burst may mix layout symbols and ASCII digits.
String normalizeScannerBarcode(String raw) {
  return _normalizeBarcode(raw, allowMixedScannerDigits: true);
}

String _normalizeBarcode(String raw, {required bool allowMixedScannerDigits}) {
  final unicodeNormalized = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      unicodeNormalized.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      unicodeNormalized.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      unicodeNormalized.writeCharCode(rune);
    }
  }

  // Only surrounding scanner framing is trimmed. Internal whitespace can
  // belong to ordinary search text and is never discarded here.
  final token = raw.trim();
  final numericToken = token.runes.every(
    (rune) =>
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x0660 && rune <= 0x0669) ||
        (rune >= 0x06F0 && rune <= 0x06F9),
  );
  final azertySymbolToken = token.runes.every(
    (rune) => _azertyDigits.containsKey(String.fromCharCode(rune)),
  );
  final scannerToken = token.runes.every(
    (rune) =>
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x0660 && rune <= 0x0669) ||
        (rune >= 0x06F0 && rune <= 0x06F9) ||
        _azertyDigits.containsKey(String.fromCharCode(rune)),
  );
  if (token.length < 6 ||
      !(allowMixedScannerDigits
          ? scannerToken
          : numericToken || azertySymbolToken)) {
    return unicodeNormalized.toString();
  }

  final normalized = StringBuffer();
  for (final rune in token.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      normalized.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      normalized.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      normalized.writeCharCode(
        _azertyDigits[String.fromCharCode(rune)] ?? rune,
      );
    }
  }

  final result = normalized.toString();
  return result;
}

const Map<String, int> _azertyDigits = <String, int>{
  '&': 0x31,
  'é': 0x32,
  '"': 0x33,
  "'": 0x34,
  '(': 0x35,
  '-': 0x36,
  'è': 0x37,
  '_': 0x38,
  'ç': 0x39,
  'à': 0x30,
};
