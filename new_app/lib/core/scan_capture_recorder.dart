// Phase A — privacy-safe keyboard-wedge observation session.
//
// A field diagnosis needs to see WHAT KIND of keys reach the app during a
// wedge burst (digit, numpad digit, Enter, KeyUp, auto-repeat, other) and
// WHEN — never WHICH digits were typed. This recorder keeps a bounded,
// in-memory, category-only event history plus a live summary, for an
// explicitly started session only.
//
// Privacy invariants (enforced here and asserted by
// `test/unit/scan_capture_recorder_test.dart`):
//  * OFF by default; the observation handler is installed only between
//    start() and stop() and removed by stop()/dispose();
//  * the handler ALWAYS returns false — Flutter still delivers the event
//    to every other handler and to the focus tree, so observing can never
//    consume, delay or rewrite a keystroke;
//  * every recorded event is reduced to an allowlisted shape —
//    `{cat, ms}` for key events (a category name and milliseconds since
//    session start) and `{cat, ms, len?, target?, reason?}` for pipeline
//    events fanned out by scan_diagnostics.dart (its own allowlist strips
//    `suffix3` and `text` before delivery). NO character, string, digit
//    value or physical-key identity of a character-producing key is ever
//    kept, so the history cannot reconstruct a barcode even in order —
//    two same-length barcodes produce identical category histories;
//  * memory is bounded: the ring keeps at most
//    [kScanCaptureBufferCapacity] event records (oldest evicted, counted
//    in `dropped`); counters and the export stay O(1)/O(capacity);
//  * nothing is persisted to disk — the export goes to the clipboard only,
//    at the operator's explicit request.
//
// The compile-time [kScanDiagnosticsEnabled] pipeline logging is a
// separate, unchanged channel: this recorder never sets it, and its own
// session state is runtime-only.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'scan_diagnostics.dart';

/// Maximum number of event records kept in the ring buffer.
const int kScanCaptureBufferCapacity = 200;

/// Logical keys whose identity is safe to record by name: they produce no
/// character content of their own (navigation, editing, function, modifier
/// and locking keys). Character-producing keys — digits, letters,
/// punctuation, space — are NEVER named, only categorized, so an ordered
/// history can never be mapped back to typed content.
final Set<LogicalKeyboardKey> kScanCaptureNamedKeys =
    <LogicalKeyboardKey>{
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.insert,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.capsLock,
      LogicalKeyboardKey.numLock,
      LogicalKeyboardKey.scrollLock,
      LogicalKeyboardKey.printScreen,
      LogicalKeyboardKey.pause,
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
      LogicalKeyboardKey.f13,
      LogicalKeyboardKey.f14,
      LogicalKeyboardKey.f15,
      LogicalKeyboardKey.f16,
      LogicalKeyboardKey.f17,
      LogicalKeyboardKey.f18,
      LogicalKeyboardKey.f19,
      LogicalKeyboardKey.f20,
      LogicalKeyboardKey.f21,
      LogicalKeyboardKey.f22,
      LogicalKeyboardKey.f23,
      LogicalKeyboardKey.f24,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    };

/// The fixed category vocabulary. Category names are technical
/// identifiers (shown raw in the panel and the export), never localized —
/// they must match across both views.
abstract final class ScanCaptureCategory {
  static const String digitDown = 'digit-down';
  static const String numpadDigitDown = 'numpad-digit-down';
  static const String enterDown = 'enter-down';
  static const String numpadEnterDown = 'numpad-enter-down';
  static const String keyUp = 'key-up';
  static const String repeat = 'repeat';
  static const String otherDown = 'other-down';
  static const String namedDown = 'named-down';
  static const String pipelinePrefix = 'pipeline:';
}

/// The field names any recorded event may carry (closed allowlist).
const Set<String> kScanCaptureEventFieldAllowlist = <String>{
  'cat',
  'ms',
  'len',
  'target',
  'reason',
  'key',
};

/// Reduces one [event] to its category name, or null when the event is
/// outside the observed vocabulary (e.g. a [KeyRepeatEvent] is folded
/// into [ScanCaptureCategory.repeat]; anything that is not a key
/// down/up is ignored).
///
/// Character values are inspected ONLY to distinguish digit classes and
/// are never returned: the result carries no typed content.
String? categorizeKeyEvent(KeyEvent event) {
  if (event is KeyUpEvent) return ScanCaptureCategory.keyUp;
  if (event is KeyRepeatEvent) return ScanCaptureCategory.repeat;
  if (event is! KeyDownEvent) return null;

  final logical = event.logicalKey;
  if (logical == LogicalKeyboardKey.enter) {
    return ScanCaptureCategory.enterDown;
  }
  if (logical == LogicalKeyboardKey.numpadEnter) {
    return ScanCaptureCategory.numpadEnterDown;
  }
  if (_numpadDigitKeys.contains(logical)) {
    return ScanCaptureCategory.numpadDigitDown;
  }
  if (_digitKeys.contains(logical)) {
    return ScanCaptureCategory.digitDown;
  }
  if (kScanCaptureNamedKeys.contains(logical)) {
    return ScanCaptureCategory.namedDown;
  }
  return ScanCaptureCategory.otherDown;
}

final Set<LogicalKeyboardKey> _numpadDigitKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
};

final Set<LogicalKeyboardKey> _digitKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
};

/// Immutable snapshot of the recorder's counters.
@immutable
class ScanCaptureSummary {
  ScanCaptureSummary({
    required this.isActive,
    required this.totalEvents,
    required this.droppedEvents,
    required this.bufferedEvents,
    required this.startedAt,
    required Map<String, int> categoryCounts,
    required this.gatewayBufferedDigits,
    required this.gatewayCaptureArmed,
  }) : categoryCounts = Map<String, int>.unmodifiable(categoryCounts);

  final bool isActive;
  final int totalEvents;
  final int droppedEvents;
  final int bufferedEvents;
  final DateTime? startedAt;
  final Map<String, int> categoryCounts;
  final int gatewayBufferedDigits;
  final bool gatewayCaptureArmed;
}

/// The bounded, in-memory, category-only observation session.
///
/// Singleton: one hardware keyboard, one session at a time. Extends
/// [ChangeNotifier] so the settings panel can rebuild on every recorded
/// event while a session runs (nothing listens otherwise).
class ScanCaptureRecorder extends ChangeNotifier {
  ScanCaptureRecorder._();

  static final ScanCaptureRecorder instance = ScanCaptureRecorder._();

  final List<Map<String, Object?>> _events = <Map<String, Object?>>[];
  final Map<String, int> _categoryCounts = <String, int>{};

  bool _active = false;
  bool _disposed = false;
  int _total = 0;
  int _dropped = 0;
  DateTime? _startedAt;

  /// Bound on [events]; visible for the capacity test.
  static const int capacity = kScanCaptureBufferCapacity;

  bool get isActive => _active;
  bool get isDisposed => _disposed;
  int get totalEvents => _total;
  int get droppedEvents => _dropped;
  int get bufferedEventCount => _events.length;
  Map<String, int> get categoryCounts => Map<String, int>.unmodifiable(
    _categoryCounts,
  );
  List<Map<String, Object?>> get events => List<Map<String, Object?>>.unmodifiable(
    _events,
  );
  DateTime? get startedAt => _startedAt;

  /// Starts the session: installs the (always-non-consuming) observation
  /// handler and subscribes to the scan_diagnostics pipeline fan-out.
  /// Idempotent — an already-running session is left untouched (no double
  /// handler, no counter reset).
  void start() {
    if (_active) return;
    _active = true;
    _startedAt = DateTime.now();
    final keyboard = HardwareKeyboard.instance;
    keyboard.removeHandler(_handleKeyEvent);
    keyboard.addHandler(_handleKeyEvent);
    addScanDiagListener(_handlePipelineEvent);
    notifyListeners();
  }

  /// Stops the session: removes the handler and the pipeline subscription.
  /// Counters and the ring are kept (the operator may still read or export
  /// them until Clear); [stop] is idempotent.
  void stop() {
    if (!_active) return;
    _active = false;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    removeScanDiagListener(_handlePipelineEvent);
    notifyListeners();
  }

  /// Empties the ring and the counters. Safe in any session state.
  void clear() {
    _events.clear();
    _categoryCounts.clear();
    _total = 0;
    _dropped = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }

  /// The observation seam. ALWAYS returns false: the recorder never
  /// consumes an event, regardless of category or session state.
  @visibleForTesting
  bool handleEventForTest(KeyEvent event) => _handleKeyEvent(event);

  bool _handleKeyEvent(KeyEvent event) {
    // Double enforcement of "off by default": the handler is removed by
    // stop(), AND it refuses to record outside an explicit session — so
    // even a stray call can never observe outside a session.
    if (!_active) return false;
    final category = categorizeKeyEvent(event);
    if (category == null) return false;
    String? name;
    if (category == ScanCaptureCategory.namedDown) {
      name = event.logicalKey.debugName;
    }
    _record(category, _elapsedMs(), namedKey: name);
    return false;
  }

  void _handlePipelineEvent(String event, Map<String, Object?> fields) {
    final category = '${ScanCaptureCategory.pipelinePrefix}$event';
    _record(category, _elapsedMs(), extra: fields);
  }

  void _record(
    String category,
    int ms, {
    String? namedKey,
    Map<String, Object?>? extra,
  }) {
    _total++;
    _categoryCounts[category] = (_categoryCounts[category] ?? 0) + 1;
    final record = <String, Object?>{
      'cat': category,
      'ms': ms,
      'key': ?namedKey,
      ...?extra,
    };
    // Belt and braces: even if a future caller smuggled a non-allowlisted
    // field in, it never reaches the ring.
    record.removeWhere((key, _) => !kScanCaptureEventFieldAllowlist.contains(key));
    if (_events.length >= kScanCaptureBufferCapacity) {
      _events.removeAt(0);
      _dropped++;
    }
    _events.add(record);
    notifyListeners();
  }

  int _elapsedMs() {
    final start = _startedAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMilliseconds;
  }

  /// A redacted, clipboard-ready report: counters, the category legend and
  /// the bounded per-event history. By construction it contains no
  /// character values, no typed text and no barcode content — only
  /// category names, elapsed milliseconds and the allowlisted pipeline
  /// fields (`len`, `target`, `reason`).
  String buildExport() {
    final buffer = StringBuffer()
      ..writeln('Klick POS scan diagnostics (redacted)')
      ..writeln('status=${_active ? 'running' : 'idle'}')
      ..writeln(
        'started=${_startedAt?.toIso8601String() ?? '-'}',
      )
      ..writeln('total=$_total')
      ..writeln('dropped=$_dropped')
      ..writeln('capacity=$kScanCaptureBufferCapacity');
    _categoryCounts.forEach((category, count) {
      buffer.writeln('count $category = $count');
    });
    for (var i = 0; i < _events.length; i++) {
      final record = _events[i];
      final fields = <String>[];
      record.forEach((key, value) {
        if (key == 'cat' || key == 'ms') return;
        fields.add('$key=$value');
      });
      buffer.writeln(
        '#$i +${record['ms']}ms ${record['cat']}'
        '${fields.isEmpty ? '' : ' ${fields.join(' ')}'}',
      );
    }
    return buffer.toString();
  }

  /// Snapshot of the counters plus the gateway's live capture state.
  ScanCaptureSummary summary({
    int gatewayBufferedDigits = 0,
    bool gatewayCaptureArmed = false,
  }) {
    return ScanCaptureSummary(
      isActive: _active,
      totalEvents: _total,
      droppedEvents: _dropped,
      bufferedEvents: _events.length,
      startedAt: _startedAt,
      categoryCounts: _categoryCounts,
      gatewayBufferedDigits: gatewayBufferedDigits,
      gatewayCaptureArmed: gatewayCaptureArmed,
    );
  }
}

/// Riverpod handle to the session recorder. A plain Provider (not a
/// ChangeNotifierProvider): the recorder is an app-lifetime singleton and
/// must survive the panel's disposal — the panel listens via
/// ListenableBuilder and never disposes it.
final scanCaptureRecorderProvider = Provider<ScanCaptureRecorder>(
  (ref) => ScanCaptureRecorder.instance,
);
