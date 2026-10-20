// Opt-in structured diagnostics for the keyboard-wedge scan pipeline.
//
// Enable on a physical device with:
//   flutter run --dart-define=KLICK_SCAN_DIAG=true
// and read the `[SCAN-DIAG]` lines while reproducing the repeated-scan
// issue. Every line carries a monotonic sequence number and a
// millisecond timestamp, so one physical swipe can be traced end to end:
//
//   dispatch (gateway, seq=N) → scan-receive / scan-resolve / cart-add
//   (POS) → qty-submit (field path) — cross-hop correlation by timestamp
//   + barcode length + suffix3 (the last three digits; full codes are
//   deliberately never printed).
//
// The flag is a compile-time constant: with the define absent every call
// is dead code and costs nothing in production. No customer data, no full
// codes, no keystroke content — length and a 3-digit suffix only.
import 'package:flutter/foundation.dart';

/// Whether [scanDiag] emits. `true` only when the app was built with
/// `--dart-define=KLICK_SCAN_DIAG=true`.
const bool kScanDiagnosticsEnabled =
    bool.fromEnvironment('KLICK_SCAN_DIAG');

int _scanDiagSeq = 0;

/// The correlation id of the most recent pipeline ORIGIN (gateway
/// `dispatch`, qty-path `qty-submit`, search-path `search-submit`).
///
/// Set right before the originating path hands the code onward, read by
/// every downstream event (`scan-receive`, `scan-resolve`, `cart-add`) so
/// one physical scan can be traced across async hops. Concurrent pipelines
/// may overwrite each other here — always correlate by id PLUS millisecond
/// timestamp plus length plus suffix3, never by id alone.
int? lastScanCorr;

/// One structured pipeline event. No-op unless [kScanDiagnosticsEnabled].
///
/// [event] is a stable identifier (`dispatch`, `dispatch-drop`,
/// `run-abandon`, `scan-receive`, `scan-resolve`, `cart-add`,
/// `qty-submit`, `qty-clear`, `search-submit`, `stock-guard`,
/// `cart-reset`, …); [fields] holds small primitives only (lengths, ids,
/// quantities, stock). Returns the event's sequence number (its
/// correlation id), or null when diagnostics are off.
int? scanDiag(String event, [Map<String, Object?> fields = const {}]) {
  if (!kScanDiagnosticsEnabled) return null;
  final seq = ++_scanDiagSeq;
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final buffer = StringBuffer('[SCAN-DIAG] seq=$seq t=$timestamp $event');
  fields.forEach((key, value) => buffer.write(' $key=$value'));
  debugPrint(buffer.toString());
  return seq;
}

/// Last 3 characters of [code] — diagnostics correlation only (full
/// codes are deliberately never printed).
String scanDiagSuffix3(String code) =>
    code.length <= 3 ? code : code.substring(code.length - 3);
