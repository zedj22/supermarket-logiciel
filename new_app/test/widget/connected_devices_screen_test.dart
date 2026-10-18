// Objective 3 — the Connected Devices screen (server PC hardware).
//
// The honesty contract under test:
//  * every list comes from `GET /api/v1/hardware/overview` and the
//    discovery warnings are shown verbatim;
//  * a non-Windows/failed discovery shows empty categories plus its
//    note — never invented devices;
//  * the three test actions post the device name and a 200 with
//    `ok: false` is a FAILURE toast, never a success;
//  * the page (and any discovery walk) exists only for `device_manage`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/devices/devices_screen.dart'
    show deviceManageScope;
import 'package:supermarket_pos/features/hardware/connected_devices_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/settings_fake_adapter.dart';

const Map<String, Object> _printerJson = <String, Object>{
  'name': 'HP LaserJet Pro',
  'driver_name': 'HP Universal Printing PCL 6',
  'port_name': 'USB001',
  'status': 'idle',
  'is_default': true,
  'is_offline': false,
  'raw_status': 3,
};

const Map<String, Object> _scannerJson = <String, Object>{
  'name': 'Datalogic Heron D330',
  'status': 'OK',
  'class_name': 'Image',
  'instance_id': 'USB\\VID_05E3&PID_0100',
  'manufacturer': 'Datalogic',
};

const Map<String, Object> _usbJson = <String, Object>{
  'name': 'HID Keyboard Device',
  'status': 'OK',
  'class_name': 'HIDClass',
  'instance_id': 'HID\\VID_046D&PID_C31C',
  'manufacturer': 'Microsoft',
};

const Map<String, Object> _serialJson = <String, Object>{
  'name': 'COM3',
  'description': 'Prolific USB-to-Serial Comm Port',
  'status': 'OK',
  'instance_id': 'FTDIBUS\\COMPORT3',
  'pnp_device_id': 'FTDIBUS\\0000\\5&2E6F7C0F&0&COM3',
};

const Map<String, Object> _overviewJson = <String, Object>{
  'scanned_at': '2026-10-18T09:15:00+00:00',
  'platform': 'Windows',
  'cached': false,
  'printers': <Object>[_printerJson],
  'scanners': <Object>[_scannerJson],
  'usb_devices': <Object>[_usbJson],
  'serial_ports': <Object>[_serialJson],
  'warnings': <Object>['PowerShell discovery failed for USB devices'],
};

const Map<String, Object> _emptyOverviewJson = <String, Object>{
  'scanned_at': '2026-10-18T09:15:00+00:00',
  'platform': 'Linux',
  'cached': false,
  'printers': <Object>[],
  'scanners': <Object>[],
  'usb_devices': <Object>[],
  'serial_ports': <Object>[],
  'warnings': <Object>[],
};

const Map<String, Object> _refreshedOverviewJson = <String, Object>{
  'scanned_at': '2026-10-18T10:22:00+00:00',
  'platform': 'Windows',
  'cached': false,
  'printers': <Object>[
    <String, Object>{
      'name': 'New Printer',
      'driver_name': 'Microsoft IPP Class Driver',
      'port_name': '192.168.1.50',
      'status': 'printing',
      'is_default': false,
      'is_offline': false,
      'raw_status': 4,
    },
  ],
  'scanners': <Object>[],
  'usb_devices': <Object>[],
  'serial_ports': <Object>[],
  'warnings': <Object>[],
};

Map<String, Object> _errorEnvelope(String code, String message) =>
    <String, Object>{
      'error': <String, Object>{'code': code, 'message': message},
    };

/// Backend stand-in: overview + refresh + the three test actions, each
/// independently failable.
FakeJsonAdapter _adapter({
  Map<String, Object> overview = _overviewJson,
  bool failOverview = false,
  Map<String, Object>? refreshOverview,
  ({bool ok, String message})? testPage,
  ({bool ok, String message})? scannerTest,
  ({bool ok, String message})? serialTest,
}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (options.method == 'POST' && path.endsWith('/overview/refresh')) {
      return (statusCode: 200, body: refreshOverview ?? overview);
    }
    if (options.method == 'GET' && path.endsWith('/hardware/overview')) {
      if (failOverview) {
        return (
          statusCode: 500,
          body: _errorEnvelope(
            'internal_error',
            'hardware discovery failed: powershell missing',
          ),
        );
      }
      return (statusCode: 200, body: overview);
    }
    if (path.endsWith('/printers/test-page')) {
      final t = testPage ?? (ok: true, message: 'Queued to HP LaserJet Pro');
      return (
        statusCode: 200,
        body: <String, Object>{
          'ok': t.ok,
          'printer': 'HP LaserJet Pro',
          'message': t.message,
        },
      );
    }
    if (path.endsWith('/scanners/test')) {
      final t = scannerTest ?? (ok: true, message: 'Scanner answered');
      return (
        statusCode: 200,
        body: <String, Object>{
          'ok': t.ok,
          'scanner': 'Datalogic Heron D330',
          'message': t.message,
        },
      );
    }
    if (path.endsWith('/serial-ports/test')) {
      final t = serialTest ?? (ok: true, message: 'COM3 is present');
      return (
        statusCode: 200,
        body: <String, Object>{
          'ok': t.ok,
          'port': 'COM3',
          'message': t.message,
        },
      );
    }
    return (
      statusCode: 404,
      body: _errorEnvelope('not_found', 'unexpected path: $path'),
    );
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: <String>['admin'],
  permissions: <String>[deviceManageScope],
);

const AuthUser _cashier = AuthUser(
  id: 'u-2',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: <String>['cashier'],
  permissions: <String>[],
);

Future<void> _pump(
  WidgetTester tester, {
  required AuthUser user,
  required FakeJsonAdapter adapter,
  AppLocale locale = AppLocale.en,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localeProvider.overrideWith(
          (ref) => LocaleNotifier()..setLocale(locale),
        ),
        currentUserProvider.overrideWithValue(user),
        apiClientProvider.overrideWithValue(ApiClient(dio: fakeDio(adapter))),
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: ConnectedDevicesScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Lets every toast dismiss timer fire so no timer leaks past the test.
Future<void> _drainToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Asserts the exact text carried by the widget with [key] (the hardware
/// screen puts finder keys directly on its [Text] widgets).
void _expectText(WidgetTester tester, Key key, String expected) {
  final text = tester.widget<Text>(find.byKey(key));
  expect(text.data, expected, reason: 'content of $key');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Connected devices gate', () {
    testWidgets('a cashier sees permission denied and never triggers a '
        'discovery walk', (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _cashier, adapter: adapter);

      expect(
        find.byKey(const Key('connected-devices-denied')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('connected-devices-title')), findsNothing);
      expect(adapter.requests, isEmpty,
          reason: 'a non-admin must not trigger a discovery walk');
      expect(tester.takeException(), isNull);
    });
  });

  group('Overview', () {
    testWidgets('renders every category with statuses, warnings and the '
        'server note', (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.path, '/api/v1/hardware/overview');

      expect(
        find.byKey(const Key('connected-devices-title')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('connected-devices-note')),
        findsOneWidget,
      );
      // Snapshot meta: platform chip + scanned-at.
      expect(
        find.descendant(
          of: find.byKey(const Key('hw-platform')),
          matching: find.text('Windows'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('hw-scanned-at')),
        findsOneWidget,
      );
      expect(
        find.textContaining('2026-10-18 09:15'),
        findsOneWidget,
        reason: 'scanned_at renders with the T replaced by a space',
      );

      // Discovery warnings are shown verbatim, not swallowed.
      expect(find.byKey(const Key('hw-warnings')), findsOneWidget);
      _expectText(tester, const Key('hw-warnings-title'),
          AppStrings.t('hw_warnings_title', 'en'));
      expect(
        find.byKey(
          const Key('hw-warning-PowerShell discovery failed for USB devices'),
        ),
        findsOneWidget,
      );

      // Section headers with counts.
      for (final section in <String>[
        'hw_printers',
        'hw_scanners',
        'hw_usb',
        'hw_serial',
      ]) {
        expect(
          find.byKey(Key('report-section-$section')),
          findsOneWidget,
          reason: 'category $section must be titled',
        );
        expect(
          find.descendant(
            of: find.byKey(Key('$section-count')),
            matching: find.text('1'),
          ),
          findsOneWidget,
        );
      }

      // Printer tile: name, default chip, details, idle status, action.
      _expectText(tester, const Key('printer-name-0'), 'HP LaserJet Pro');
      expect(
        find.descendant(
          of: find.byKey(const Key('printer-default-0')),
          matching: find.text(AppStrings.t('hw_default', 'en')),
        ),
        findsOneWidget,
      );
      _expectText(tester, const Key('printer-details-0'),
          'HP Universal Printing PCL 6 · USB001');
      expect(
        find.descendant(
          of: find.byKey(const Key('printer-status-0')),
          matching: find.text(AppStrings.t('hw_status_idle', 'en')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('printer-test-0')), findsOneWidget);

      // Scanner tile: PnP OK status + test action.
      _expectText(tester, const Key('scanner-name-0'), 'Datalogic Heron D330');
      _expectText(tester, const Key('scanner-details-0'), 'Image · Datalogic');
      expect(
        find.descendant(
          of: find.byKey(const Key('scanner-status-0')),
          matching: find.text(AppStrings.t('hw_pnp_ok', 'en')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('scanner-test-0')), findsOneWidget);

      // USB devices have no test action - presence comes from PnP only.
      _expectText(tester, const Key('usb-name-0'), 'HID Keyboard Device');
      expect(find.byKey(const Key('usb-test-0')), findsNothing);

      // Serial port: description, test action, presence-only note.
      _expectText(tester, const Key('serial-name-0'), 'COM3');
      _expectText(tester, const Key('serial-details-0'),
          'Prolific USB-to-Serial Comm Port');
      expect(find.byKey(const Key('serial-test-0')), findsOneWidget);
      _expectText(
          tester, const Key('hw-serial-note'), AppStrings.t('hw_port_probe_note', 'en'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty (non-Windows) overview says nothing was found '
        'in every category', (tester) async {
      final adapter = _adapter(overview: _emptyOverviewJson);
      await _pump(tester, user: _admin, adapter: adapter);

      for (final emptyKey in <String>[
        'hw-printers-empty',
        'hw-scanners-empty',
        'hw-usb-empty',
        'hw-serial-empty',
      ]) {
        expect(find.byKey(Key(emptyKey)), findsOneWidget);
      }
      expect(find.text(AppStrings.t('hw_none', 'en')), findsNWidgets(4));
      for (final section in <String>[
        'hw_printers',
        'hw_scanners',
        'hw_usb',
        'hw_serial',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('$section-count')),
            matching: find.text('0'),
          ),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('hw-warnings')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('hw-platform')),
          matching: find.text('Linux'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed overview reports the reason instead of claiming '
        'an empty server', (tester) async {
      final adapter = _adapter(failOverview: true);
      await _pump(tester, user: _admin, adapter: adapter);

      expect(find.byKey(const Key('hw-error')), findsOneWidget);
      expect(
        find.textContaining('hardware discovery failed'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('hw-printers-empty')), findsNothing,
          reason: 'a failed load must not claim there are no devices');
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh posts the force endpoint and shows the new '
        'snapshot', (tester) async {
      final adapter = _adapter(refreshOverview: _refreshedOverviewJson);
      await _pump(tester, user: _admin, adapter: adapter);
      expect(find.text('HP LaserJet Pro'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('hw-refresh')));

      final refreshes = adapter.requests
          .where((r) => r.path.endsWith('/overview/refresh'))
          .toList();
      expect(refreshes, hasLength(1));
      expect(refreshes.single.method, 'POST');

      expect(find.text('New Printer'), findsOneWidget);
      expect(find.text('HP LaserJet Pro'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('printer-status-0')),
          matching: find.text(AppStrings.t('hw_status_printing', 'en')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Test actions', () {
    testWidgets('an accepted test page is announced as success', (tester) async {
      final adapter = _adapter(
        testPage: (ok: true, message: 'Queued to HP LaserJet Pro'),
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('printer-test-0')));

      final posts = adapter.requests
          .where((r) => r.path.endsWith('/printers/test-page'))
          .toList();
      expect(posts, hasLength(1));
      expect(posts.single.method, 'POST');
      final body = posts.single.data;
      expect(body, isA<Map<String, dynamic>>());
      expect((body as Map)['name'], 'HP LaserJet Pro');

      expect(
        find.byKey(const Key('hardware-test-toast')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('hw_test_page_ok', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('hw_test_page_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a 200 with ok:false is a failure toast with the Windows '
        'message, never a success', (tester) async {
      final adapter = _adapter(
        testPage: (ok: false, message: 'Windows says the queue is paused'),
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('printer-test-0')));

      expect(
        find.byKey(const Key('hardware-test-toast')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('hw_test_page_failed', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('hw_test_page_ok', 'en')),
        findsNothing,
        reason: 'ok:false must never be presented as success',
      );
      expect(find.textContaining('queue is paused'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('the scanner check posts its own endpoint and reports the '
        'refusal', (tester) async {
      final adapter = _adapter(
        scannerTest: (ok: false, message: 'No answer from the scanner'),
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('scanner-test-0')));

      final posts = adapter.requests
          .where((r) => r.path.endsWith('/scanners/test'))
          .toList();
      expect(posts, hasLength(1));
      expect((posts.single.data as Map)['name'], 'Datalogic Heron D330');
      expect(
        find.text(AppStrings.t('hw_scanner_failed', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('hw_scanner_ok', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('the serial port check announces a found port', (tester) async {
      final adapter = _adapter(
        serialTest: (ok: true, message: 'COM3 is present'),
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('serial-test-0')));

      final posts = adapter.requests
          .where((r) => r.path.endsWith('/serial-ports/test'))
          .toList();
      expect(posts, hasLength(1));
      expect((posts.single.data as Map)['name'], 'COM3');
      expect(find.text(AppStrings.t('hw_port_ok', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('hw_port_failed', 'en')), findsNothing);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });
}
