// EXPERIMENTAL raw-scanner PoC card (lib/features/settings/
// raw_scanner_poc_panel.dart) — proves the flag-gated control surface:
//
//  * renders every control (toggle / learn / reset / layout selector /
//    learned devices / counters) against a mocked native channel, with
//    NO TextField anywhere (the scan-focus rule) and no autofocus;
//  * control taps reach the method channel with the right method names,
//    and the layout selector flips the controller's scanner table;
//  * status text follows the enabled flag.
//
// The widget itself carries no build-flag check — gating is the settings
// screen's `if (kRawScannerPocEnabled)` wrapper — so the card is testable
// in a plain build.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/raw_scanner/raw_scanner_decoder.dart';
import 'package:supermarket_pos/core/raw_scanner/raw_scanner_poc.dart';
import 'package:supermarket_pos/features/settings/raw_scanner_poc_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(kRawScannerMethodChannelName);
  late List<MethodCall> calls;
  late RawScannerPocController controller;

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
          'rawSeen': 0,
          'rawMatched': 0,
          'dropped': 0,
          'passed': 0,
          'orderViolations': 0,
          'orderDetail': '',
        };
      }
      return null;
    });
    controller = RawScannerPocController();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          rawScannerPocProvider.overrideWithValue(controller),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RawScannerPocSection(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('every control renders; no TextField can steal focus',
      (WidgetTester tester) async {
    await pumpPanel(tester);

    expect(find.byKey(const Key('settings-raw-scanner-toggle')), findsOneWidget);
    expect(find.byKey(const Key('settings-raw-scanner-learn')), findsOneWidget);
    expect(find.byKey(const Key('settings-raw-scanner-reset')), findsOneWidget);
    expect(find.byKey(const Key('settings-raw-scanner-status')), findsOneWidget);
    for (final layout in RawScannerDecoder.supportedLayouts) {
      expect(
        find.byKey(Key('settings-raw-scanner-layout-$layout')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const Key('settings-raw-scanner-devices-empty')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-raw-scanner-counters')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-raw-scanner-order')), findsOneWidget);
    expect(find.byKey(const Key('settings-raw-scanner-last')), findsOneWidget);
    expect(find.byKey(const Key('settings-raw-scanner-unavailable')), findsNothing,
        reason: 'native status was ready — no unavailable note');
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('toggle and learn reach the method channel',
      (WidgetTester tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byKey(const Key('settings-raw-scanner-toggle')));
    await tester.pump();
    expect(controller.enabled, isTrue);
    expect(
      calls.any((call) => call.method == 'setEnabled' && call.arguments == true),
      isTrue,
    );

    await tester.tap(find.byKey(const Key('settings-raw-scanner-learn')));
    await tester.pump();
    expect(controller.learnArmed, isTrue);
    expect(calls.any((call) => call.method == 'learn'), isTrue);
    expect(
      find.byKey(const Key('settings-raw-scanner-learn-status')),
      findsOneWidget,
      reason: 'the armed hint appears',
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the layout selector switches the scanner table',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    expect(controller.layout, kRawScannerLayoutUs);

    await tester.tap(find.byKey(const Key('settings-raw-scanner-layout-fr')));
    await tester.pump();
    expect(controller.layout, kRawScannerLayoutFr);
    expect(controller.decoder.layout, kRawScannerLayoutFr);

    await tester.tap(find.byKey(const Key('settings-raw-scanner-layout-ar')));
    await tester.pump();
    expect(controller.layout, kRawScannerLayoutAr);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('reset counters reaches the native module',
      (WidgetTester tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byKey(const Key('settings-raw-scanner-reset')));
    await tester.pump();
    expect(calls.any((call) => call.method == 'resetStats'), isTrue);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
