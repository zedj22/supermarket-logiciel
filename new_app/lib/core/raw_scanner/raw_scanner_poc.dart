// EXPERIMENTAL — the Dart half of the isolated raw-scanner PoC.
//
// Goal: prove on real hardware that a keyboard-wedge barcode scanner can
// be captured INDEPENDENTLY of the Windows keyboard layout (en-US /
// fr-FR / ar-DZ) with no customer reconfiguration of Windows or of the
// scanner, WITHOUT replacing the existing gateway
// (`lib/core/barcode_scanner.dart`, which keeps running untouched as the
// fallback path for everything this PoC does not claim).
//
// Architecture (Phase 1 evidence in `windows/runner/raw_scanner_input.h`):
//  * Raw Input is the only Windows API that attributes keyboard events to
//    a physical DEVICE; legacy messages carry no device id, and
//    RIDEV_NOLEGACY would silence every keyboard — hence the runner-level
//    module: it observes WM_INPUT (device + MakeCode), and while enabled
//    + learned it suppresses the matching legacy messages in the runner
//    message loop BEFORE TranslateMessage (no WM_CHAR can be produced).
//  * The barcode string is reconstructed HERE, in Dart, from the
//    scanner's own keyboard-country table (`RawScannerDecoder`) — the
//    Windows layout never participates. Suppressed keys reach no
//    shortcut, no field, no text editing; decoded runs are handed to the
//    existing gateway through [BarcodeScannerGateway.dispatchExternalScan]
//    so every screen, gate and diagnostics hop works exactly as before.
//
// Safety model (PoC-only, all opt-in, default OFF):
//  * the control surface exists only in builds with
//    `--dart-define=KLICK_RAW_SCANNER_POC=true` ([kRawScannerPocEnabled]);
//  * `enabled` is SESSION-ONLY (never persisted): every launch starts
//    with the ordinary gateway alone;
//  * the device is LEARNED first (native `learn` arms a one-shot; the
//    first keyboard device to speak is captured, and the operator learns
//    by triggering the scanner, never by typing);
//  * learned devices persist in SharedPreferences
//    (`raw_scanner_learned_devices`) so a test session can resume;
//  * with the PoC off — or on any device that was not learned — the
//    runner module passes every message through byte-for-byte.
//
// Caution documented on the panel: learning the WRONG device (a typing
// keyboard) would suppress and misdecode that keyboard while the PoC is
// enabled. Remove the device / toggle off to restore normal input.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../barcode_scanner.dart';
import '../scan_diagnostics.dart';
import 'raw_scanner_decoder.dart';

/// Whether the raw-scanner PoC surfaces (the settings card) exist in this
/// build — compile-time, mirror of `KLICK_SCAN_DIAG`'s pattern. With the
/// define absent the panel is never inserted, the controller is never
/// constructed (Riverpod laziness), and production builds are unchanged.
const bool kRawScannerPocEnabled =
    bool.fromEnvironment('KLICK_RAW_SCANNER_POC');

/// Runner-side channel names — must match `raw_scanner_input.cpp`.
const String kRawScannerMethodChannelName = 'klick/raw_scanner_poc';
const String kRawScannerEventChannelName = 'klick/raw_scanner_poc/events';

/// SharedPreferences key for the learned device paths.
const String kRawScannerLearnedPrefsKey = 'raw_scanner_learned_devices';

/// Native evidence counters (`status` reply of the runner module).
@immutable
class RawScannerNativeStatus {
  const RawScannerNativeStatus({
    required this.ready,
    required this.enabled,
    required this.learnArmed,
    required this.learned,
    required this.rawSeen,
    required this.rawMatched,
    required this.dropped,
    required this.passed,
    required this.orderViolations,
    required this.orderDetail,
  });

  factory RawScannerNativeStatus.initial() => const RawScannerNativeStatus(
        ready: false,
        enabled: false,
        learnArmed: false,
        learned: <String>[],
        rawSeen: 0,
        rawMatched: 0,
        dropped: 0,
        passed: 0,
        orderViolations: 0,
        orderDetail: '',
      );

  factory RawScannerNativeStatus.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? value) => value is num ? value.toInt() : 0;
    return RawScannerNativeStatus(
      ready: map['ready'] == true,
      enabled: map['enabled'] == true,
      learnArmed: map['learnArmed'] == true,
      learned: map['learned'] is List
          ? (map['learned'] as List<Object?>).whereType<String>().toList()
          : <String>[],
      rawSeen: asInt(map['rawSeen']),
      rawMatched: asInt(map['rawMatched']),
      dropped: asInt(map['dropped']),
      passed: asInt(map['passed']),
      orderViolations: asInt(map['orderViolations']),
      orderDetail: map['orderDetail'] is String
          ? map['orderDetail']! as String
          : '',
    );
  }

  final bool ready;
  final bool enabled;
  final bool learnArmed;
  final List<String> learned;
  final int rawSeen;
  final int rawMatched;
  final int dropped;
  final int passed;
  final int orderViolations;
  final String orderDetail;
}

/// The PoC control surface state: configuration pushed to the runner
/// module, learned devices, native evidence counters and the last decoded
/// run (length + suffix only — full codes are never stored or shown, the
/// repo's scan-privacy rule).
class RawScannerPocController extends ChangeNotifier {
  RawScannerPocController({int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const MethodChannel _method =
      MethodChannel(kRawScannerMethodChannelName);
  static const EventChannel _events =
      EventChannel(kRawScannerEventChannelName);

  final int Function() _clock;
  final RawScannerDecoder _decoder = RawScannerDecoder();

  StreamSubscription<Object?>? _subscription;
  Timer? _refreshTimer;
  SharedPreferences? _prefs;

  bool _enabled = false;
  bool _learnArmed = false;
  bool _available = true;
  String _layout = kRawScannerLayoutUs;
  final List<String> _learned = <String>[];
  RawScannerNativeStatus _status = RawScannerNativeStatus.initial();
  int? _lastScanLength;
  String? _lastScanSuffix3;

  bool get enabled => _enabled;
  bool get learnArmed => _learnArmed;

  /// `false` once a channel call fails or the native module reports not
  /// ready — the panel then shows the unavailable note and every control
  /// is inert.
  bool get available => _available;
  String get layout => _layout;
  List<String> get learned => List<String>.unmodifiable(_learned);
  RawScannerNativeStatus get status => _status;
  int? get lastScanLength => _lastScanLength;
  String? get lastScanSuffix3 => _lastScanSuffix3;

  /// Decoder instance (observation seam for tests).
  RawScannerDecoder get decoder => _decoder;

  /// Subscribes to the runner event stream, restores learned devices and
  /// fetches the native baseline. Safe to call once; failures degrade to
  /// [available] == false instead of throwing.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored =
        _prefs?.getStringList(kRawScannerLearnedPrefsKey) ?? <String>[];
    _learned.addAll(stored.where((device) => !_learned.contains(device)));
    await _pushLearned();
    _subscription = _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object _) {
            // No native side (test environment / other platform): stay
            // usable as a no-op and let `available` reflect the state.
            _available = false;
            _syncTimer();
          },
        );
    await refreshStatus();
    _syncTimer();
    notifyListeners();
  }

  /// True when the runner module answered `status` with ready == true
  /// (and no earlier call failed).
  Future<void> refreshStatus() async {
    final reply = await _invoke('status');
    if (reply is Map) {
      _status = RawScannerNativeStatus.fromMap(
        reply.map((key, value) => MapEntry<Object?, Object?>(key, value)),
      );
      _available = _status.ready;
    }
    _syncTimer();
    notifyListeners();
  }

  /// Session-only master switch (never persisted). Off also resets the
  /// decoder's half-finished run.
  Future<void> setEnabled(bool value) async {
    await _invoke('setEnabled', value);
    _enabled = value;
    if (!value) _decoder.reset();
    _syncTimer();
    notifyListeners();
    await refreshStatus();
  }

  /// Arms the native one-shot learn: the NEXT keyboard device to produce
  /// a raw event identifies the scanner (operator triggers a scan — never
  /// presses a typing key).
  Future<void> learn() async {
    await _invoke('learn');
    _learnArmed = true;
    _syncTimer();
    notifyListeners();
    await refreshStatus();
  }

  Future<void> cancelLearn() async {
    await _invoke('cancelLearn');
    _learnArmed = false;
    _syncTimer();
    notifyListeners();
    await refreshStatus();
  }

  /// Switches the SCANNER's declared keyboard-country table (decoder
  /// side only — nothing Windows-side is touched, ever).
  void setLayout(String value) {
    if (!RawScannerDecoder.supportedLayouts.contains(value)) return;
    if (value == _layout) return;
    _layout = value;
    _decoder.layout = value;
    _decoder.reset();
    notifyListeners();
  }

  /// Forgets one learned device (native suppression for it ends at the
  /// next `setLearned` push).
  Future<void> forgetDevice(String device) async {
    if (!_learned.remove(device)) return;
    await _persistAndPush();
    notifyListeners();
  }

  /// Zeroes the native evidence counters and the local last-scan display.
  Future<void> resetStats() async {
    await _invoke('resetStats');
    _lastScanLength = null;
    _lastScanSuffix3 = null;
    notifyListeners();
    await refreshStatus();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _refreshTimer?.cancel();
    if (_enabled) {
      // Session-only by contract: leaving must never strand suppression
      // on beyond this controller's life.
      unawaited(_invoke('setEnabled', false));
    }
    super.dispose();
  }

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _method.invokeMethod(method, arguments);
    } on PlatformException {
      _available = false;
      _syncTimer();
      return null;
    } on MissingPluginException {
      _available = false;
      _syncTimer();
      return null;
    }
  }

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final event = raw.map((key, value) => MapEntry<Object?, Object?>(key, value));
    final type = event['t'];
    if (type == 'learn') {
      final device = event['device'];
      if (device is! String || device.isEmpty) return;
      _learnArmed = false;
      if (!_learned.contains(device)) {
        _learned.add(device);
        unawaited(_persistAndPush());
      }
      _syncTimer();
      notifyListeners();
      unawaited(refreshStatus());
      return;
    }
    if (type == 'raw') {
      if (!_enabled) return;
      final key = RawScanKey(
        make: _asInt(event['make']),
        e0: event['e0'] == true,
        e1: event['e1'] == true,
        up: event['up'] == true,
        seq: _asInt(event['seq']),
        receivedAtMs: _clock(),
      );
      final code = _decoder.feed(key);
      if (code != null) _onDecoded(code);
      return;
    }
  }

  void _onDecoded(String code) {
    _lastScanLength = code.length;
    _lastScanSuffix3 = scanDiagSuffix3(code);
    if (!kBarcodeScanShape.hasMatch(code)) {
      // Tagged `raw-shape` (not the gateway's `shape`) so a hardware
      // session can tell a raw-path terminator drop from a legacy one.
      scanDiag('dispatch-drop', {'reason': 'raw-shape', 'len': code.length});
      notifyListeners();
      return;
    }
    BarcodeScannerGateway.instance.dispatchExternalScan(code);
    notifyListeners();
  }

  Future<void> _persistAndPush() async {
    await _prefs?.setStringList(
      kRawScannerLearnedPrefsKey,
      List<String>.of(_learned),
    );
    await _pushLearned();
  }

  Future<void> _pushLearned() =>
      _invoke('setLearned', List<String>.of(_learned));

  /// The 1s evidence poll runs only while there is something to observe
  /// (PoC enabled or learn armed) and the native side is reachable.
  void _syncTimer() {
    final want = (_enabled || _learnArmed) && _available;
    if (want && _refreshTimer == null) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refreshStatus(),
      );
    } else if (!want && _refreshTimer != null) {
      _refreshTimer!.cancel();
      _refreshTimer = null;
    }
  }

  static int _asInt(Object? value) => value is num ? value.toInt() : 0;
}

/// App-lifetime handle (plain `Provider`, mirroring
/// `scanCaptureRecorderProvider`): constructed on first read of the panel,
/// so builds without the PoC flag never touch a channel.
final rawScannerPocProvider = Provider<RawScannerPocController>((ref) {
  final controller = RawScannerPocController();
  ref.onDispose(controller.dispose);
  unawaited(controller.init());
  return controller;
});
