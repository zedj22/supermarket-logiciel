// EXPERIMENTAL raw-scanner PoC service (lib/core/raw_scanner/
// raw_scanner_poc.dart) — the Dart half of the isolated PoC, exercised
// against MOCKED platform channels (no Windows runner, no hardware):
//
//  * init restores persisted learned devices and pushes them native;
//  * learn arms native, a pushed `learn` event records + persists the
//    device and disarms the one-shot;
//  * raw events are ignored while disabled; enabled they decode and —
//    through BarcodeScannerGateway.dispatchExternalScan — reach the
//    registered scan handler exactly like an Enter-terminated burst;
//  * a non-shaped raw run is dropped with the `raw-shape` diagnostic
//    reason and never dispatches;
//  * control calls (setEnabled / learn / resetStats / setLearned) reach
//    the method channel with the right payloads.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/raw_scanner/raw_scanner_decoder.dart';
import 'package:supermarket_pos/core/raw_scanner/raw_scanner_poc.dart';
import 'package:supermarket_pos/core/scan_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(kRawScannerMethodChannelName);
  const eventChannelName = kRawScannerEventChannelName;
  const codec = StandardMethodCodec();

  final gateway = BarcodeScannerGateway.instance;
  late List<MethodCall> calls;
  late RawScannerPocController controller;

  /// Pushes one runner event onto the (mocked) event channel, exactly as
  /// the native EventSink would deliver it.
  Future<void> pushEvent(Map<String, Object?> event) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      eventChannelName,
      codec.encodeSuccessEnvelope(event),
      (ByteData? _) {},
    );
    await pumpEventQueue();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'status') {
        return <Object?, Object?>{
          'ready': true,
          'enabled': false,
          'learnArmed': false,
          'learned': <Object?>[],
          'rawSeen': 7,
          'rawMatched': 5,
          'dropped': 4,
          'passed': 3,
          'orderViolations': 0,
          'orderDetail': '',
        };
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(eventChannelName, (ByteData? message) async {
      // The stream listen/cancel handshake: acknowledge, no payload.
      codec.decodeMethodCall(message!);
      return null;
    });
    controller = RawScannerPocController();
    gateway.resetForTest();
  });

  tearDown(() async {
    gateway.resetForTest();
    controller.dispose();
    await pumpEventQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(eventChannelName, null);
  });

  group('learn flow', () {
    test('init restores persisted devices and pushes them native', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kRawScannerLearnedPrefsKey: <String>[r'\\?\HID#VID_060E&PID_0960#7&x&0&0000'],
      });
      await controller.init();

      expect(controller.learned, hasLength(1));
      final push = calls.lastWhere((call) => call.method == 'setLearned');
      expect(push.arguments, controller.learned);
    });

    test('learn arms, the first device event records + persists it',
        () async {
      await controller.init();
      await controller.learn();
      expect(controller.learnArmed, isTrue);

      const device = r'\\?\HID#VID_060E&PID_0960#7&ad69&0&0000';
      await pushEvent(<String, Object?>{'t': 'learn', 'device': device});

      expect(controller.learnArmed, isFalse,
          reason: 'the one-shot disarms on the first device');
      expect(controller.learned, <String>[device]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(kRawScannerLearnedPrefsKey), <String>[device]);
      final push = calls.lastWhere((call) => call.method == 'setLearned');
      expect(push.arguments, <Object?>[device]);
    });

    test('a malformed learn event is ignored', () async {
      await controller.init();
      await controller.learn();
      await pushEvent(<String, Object?>{'t': 'learn', 'device': ''});
      expect(controller.learnArmed, isTrue,
          reason: 'empty device names keep the one-shot armed');
      expect(controller.learned, isEmpty);
    });
  });

  group('raw decode → gateway dispatch', () {
    Future<void> scanRun(
      RawScannerPocController target,
      List<int> digitMakes,
    ) async {
      var seq = 0;
      Future<void> send(int make, bool isUp) => pushEvent(<String, Object?>{
            't': 'raw',
            'device': r'\\?\HID#VID_TEST',
            'make': make,
            'e0': false,
            'e1': false,
            'up': isUp,
            'vk': 0x31,
            'seq': seq++,
          });

      for (final make in digitMakes) {
        // A wedge sends a make AND a break per character — without the
        // break the decoder's anti-repeat guard would (correctly) treat a
        // second press of the same digit as autorepeat.
        await send(make, false);
        await send(make, true);
      }
      await send(0x1C, false);
      await send(0x1C, true);
      expect(target.decoder.bufferedLength, 0,
          reason: 'the terminator always clears the run');
    }

    test('disabled: raw events never touch the decoder', () async {
      await controller.init();
      await scanRun(controller, <int>[0x02, 0x03, 0x04]);
      expect(controller.lastScanLength, isNull);
      expect(controller.decoder.bufferedLength, 0);
    });

    test('enabled US run dispatches through the existing gateway',
        () async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add, name: 'poc'));
      await controller.init();
      await controller.setEnabled(true);
      expect(
        calls.any((call) => call.method == 'setEnabled' && call.arguments == true),
        isTrue,
      );

      // 3 5 6 1 3 4 5 → scan codes 0x04 0x06 0x07 0x02 0x04 0x05 0x06.
      await scanRun(
        controller,
        <int>[0x04, 0x06, 0x07, 0x02, 0x04, 0x05, 0x06],
      );

      expect(codes, <String>['3561345']);
      expect(controller.lastScanLength, 7);
      expect(controller.lastScanSuffix3, '345');
    });

    test('enabled FR shift-layer run dispatches ASCII digits', () async {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add, name: 'poc'));
      await controller.init();
      controller.setLayout(kRawScannerLayoutFr);
      await controller.setEnabled(true);

      Future<void> send(int make, bool isUp) => pushEvent(<String, Object?>{
            't': 'raw',
            'device': r'\\?\HID#VID_TEST',
            'make': make,
            'e0': false,
            'e1': false,
            'up': isUp,
            'vk': 0x31,
            'seq': 0,
          });

      // One FR digit: shift down, digit make/break, shift up — the raw
      // shift layer is the ONLY source of the ASCII digits here.
      Future<void> frDigit(int make) async {
        await send(0x2A, false);
        await send(make, false);
        await send(make, true);
        await send(0x2A, true);
      }

      await frDigit(0x02); // Shift+& → 1
      await frDigit(0x09); // Shift+_ → 8
      await frDigit(0x0A); // Shift+ç → 9
      await frDigit(0x0B); // Shift+à → 0
      await frDigit(0x02); // Shift+& → 1
      await frDigit(0x04); // Shift+" → 3
      await scanRun(controller, <int>[]); // Enter only

      expect(codes, <String>['189013']);
    });

    test('a non-shaped raw run is dropped with reason raw-shape', () async {
      final codes = <String>[];
      final diagnostics = <String, Map<String, Object?>>{};
      void listener(String event, Map<String, Object?> fields) =>
          diagnostics[event] = fields;
      addScanDiagListener(listener);
      addTearDown(() => removeScanDiagListener(listener));

      gateway.register(BarcodeScanHandler(onScan: codes.add, name: 'poc'));
      await controller.init();
      await controller.setEnabled(true);

      await scanRun(controller, <int>[0x02, 0x03, 0x04]); // only '123'

      expect(codes, isEmpty, reason: 'shape must gate any dispatch');
      expect(diagnostics.containsKey('dispatch-drop'), isTrue);
      expect(diagnostics['dispatch-drop']!['reason'], 'raw-shape');
      expect(diagnostics['dispatch-drop']!['len'], 3);
      expect(controller.lastScanLength, 3,
          reason: 'the panel still shows what was decoded');
    });

    test('decoded run with no registered screen drops with no-owner',
        () async {
      final diagnostics = <String, Map<String, Object?>>{};
      void listener(String event, Map<String, Object?> fields) =>
          diagnostics[event] = fields;
      addScanDiagListener(listener);
      addTearDown(() => removeScanDiagListener(listener));

      await controller.init();
      await controller.setEnabled(true);
      await scanRun(controller, <int>[0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);

      expect(diagnostics['dispatch-drop']?['reason'], 'no-owner');
    });
  });

  group('control surface', () {
    test('disabling resets the decoder run and stops suppression natively',
        () async {
      await controller.init();
      await controller.setEnabled(true);
      expect(controller.enabled, isTrue);

      await pushEvent(<String, Object?>{
        't': 'raw',
        'device': 'x',
        'make': 0x02,
        'e0': false,
        'e1': false,
        'up': false,
        'vk': 0x31,
        'seq': 0,
      });
      expect(controller.decoder.bufferedLength, 1);

      await controller.setEnabled(false);
      expect(controller.enabled, isFalse);
      expect(controller.decoder.bufferedLength, 0);
      expect(
        calls.any((call) => call.method == 'setEnabled' && call.arguments == false),
        isTrue,
      );
    });

    test('resetStats reaches the native counters', () async {
      await controller.init();
      await controller.resetStats();
      expect(calls.any((call) => call.method == 'resetStats'), isTrue);
    });

    test('forgetDevice removes + persists + pushes', () async {
      const device = r'\\?\HID#VID_060E&PID_0960#7&ad69&0&0000';
      SharedPreferences.setMockInitialValues(<String, Object>{
        kRawScannerLearnedPrefsKey: <String>[device],
      });
      await controller.init();
      expect(controller.learned, <String>[device]);

      await controller.forgetDevice(device);
      expect(controller.learned, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(kRawScannerLearnedPrefsKey), isEmpty);
      expect(
        calls.lastWhere((call) => call.method == 'setLearned').arguments,
        isEmpty,
      );
    });

    test('status refresh adopts the native counters', () async {
      await controller.init();
      await controller.refreshStatus();
      expect(controller.status.rawSeen, 7);
      expect(controller.status.dropped, 4);
      expect(controller.status.ready, isTrue);
      expect(controller.available, isTrue);
    });

    test('setLayout rejects unknown ids and switches known ones', () async {
      await controller.init();
      controller.setLayout('de');
      expect(controller.layout, kRawScannerLayoutUs);
      controller.setLayout(kRawScannerLayoutAr);
      expect(controller.layout, kRawScannerLayoutAr);
      expect(controller.decoder.layout, kRawScannerLayoutAr);
    });
  });

  group('gateway dispatchExternalScan (raw entry point)', () {
    test('shape gate: short codes never dispatch', () {
      expect(gateway.dispatchExternalScan('123'), isFalse);
      expect(gateway.dispatchExternalScan('abc123'), isFalse);
    });

    test('owner gate: no registered screen means no dispatch', () {
      expect(gateway.dispatchExternalScan('3561345'), isFalse);
    });

    test('a live handler receives the code through the raw origin', () {
      final codes = <String>[];
      gateway.register(BarcodeScanHandler(onScan: codes.add, name: 'poc'));
      expect(gateway.dispatchExternalScan('3561345'), isTrue);
      expect(codes, <String>['3561345']);
    });
  });
}
