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

/// Whether the capture path has any consumer for detailed burst summaries.
/// This keeps their counters out of the normal keyboard hot path.
bool get scanDiagObservationEnabled =>
    kScanDiagnosticsEnabled || _scanDiagListeners.isNotEmpty;

int _scanDiagSeq = 0;

/// Listener signature for the runtime diagnostic fan-out ([scanDiag]).
///
/// Receives the pipeline event name plus a sanitized field map (see
/// [sanitizeScanDiagFields]) — never the raw caller map, so a listener can
/// never observe `suffix3`, `text` or any other non-allowlisted value.
typedef ScanDiagListener = void Function(
  String event,
  Map<String, Object?> fields,
);

/// Runtime subscribers of the [scanDiag] fan-out. Empty in normal
/// operation (the panel subscribes only while a diagnostics SESSION is
/// explicitly running), so the hot path costs one length check.
final List<ScanDiagListener> _scanDiagListeners = <ScanDiagListener>[];

/// The CLOSED allowlist of field names the fan-out passes to listeners.
///
/// `len` (a count), `target` (a screen name) and `reason` (a fixed code
/// chosen in this repo's own call sites) carry no barcode content.
/// Everything else — notably `suffix3` (three digits of a code) and
/// `text` (field content) — is stripped BEFORE any listener sees it.
const Set<String> kScanDiagFieldAllowlist = <String>{
  'len',
  'target',
  'reason',
  'characterDigits',
  'physicalDigits',
  'otherKeys',
  'bufferedDigits',
  'editableFocus',
  'phase',
  'origin',
  'accepted',
  'bufferBefore',
  'bufferAfter',
  'rawLength',
  'normalizedLength',
  'normalized',
  'validShape',
  'runThrough',
  'result',
  'attemptId',
  'corr',
  'productId',
  'variantId',
  'sellingUnitId',
  'lineKey',
  'previous',
  'next',
  'handlerName',
  'physicalKey',
  'logicalKey',
  'eventType',
  'focusState',
};

/// Returns a copy of [fields] keeping only [kScanDiagFieldAllowlist] keys.
/// Never mutates the caller's map.
Map<String, Object?> sanitizeScanDiagFields(Map<String, Object?> fields) {
  if (fields.isEmpty) return const <String, Object?>{};
  final sanitized = <String, Object?>{};
  fields.forEach((key, value) {
    if (kScanDiagFieldAllowlist.contains(key)) sanitized[key] = value;
  });
  return sanitized;
}

/// Subscribes [listener] to the runtime fan-out (idempotent).
void addScanDiagListener(ScanDiagListener listener) {
  if (_scanDiagListeners.contains(listener)) return;
  _scanDiagListeners.add(listener);
}

/// Unsubscribes [listener]; safe to call when not subscribed.
void removeScanDiagListener(ScanDiagListener listener) {
  _scanDiagListeners.remove(listener);
}

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
///
/// Runtime fan-out: when a diagnostics session is running (a listener is
/// subscribed via [addScanDiagListener]), the event name and the
/// ALLOWLISTED fields are delivered to each listener — this runs whether
/// or not the compile-time flag is set, and never changes the return
/// value or anything the caller observes. With no listeners the fan-out
/// is a single empty-check; call sites need no changes.
int? scanDiag(String event, [Map<String, Object?> fields = const {}]) {
  if (_scanDiagListeners.isNotEmpty) {
    final sanitized = sanitizeScanDiagFields(fields);
    // Copy-on-iterate so a listener may unsubscribe during notification.
    for (final listener in List<ScanDiagListener>.of(_scanDiagListeners)) {
      listener(event, sanitized);
    }
  }
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
