// Phase 16 (§23.1) — the store server's device-management screen.
//
// Pinned here: the `device_manage` gate, the pairing-code card never
// rendering a token, approve/deny/revoke wiring, and the fact that the
// screen renders server JSON as-is (no client-side invention).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/devices/devices_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class _NoSessionCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => false;
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> saveToken(String token) async {}
  @override
  Future<void> saveUserId(String userId) async {}
  @override
  Future<void> saveUserName(String name) async {}
  @override
  Future<void> saveUserRoles(List<String> roles) async {}
  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}
  @override
  Future<List<String>> readUserRoles() async => const [];
  @override
  Future<List<String>> readUserPermissions() async => const [];
  @override
  Future<void> clearAll() async {}
}

const _devicesPath = '/api/v1/devices';
const _codePath = '$_devicesPath/pairing-code';

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: 200,
    );

Map<String, dynamic> _device(
  String id, {
  String status = 'pending',
  String name = 'POS-01',
  String? lastIp,
  String? clientVersion,
}) =>
    {
      'id': '00000000-0000-0000-0000-0000000000$id',
      'device_id': id,
      'display_name': name,
      'status': status,
      'last_ip': lastIp,
      'requested_ip': lastIp,
      'client_version': clientVersion,
      'last_seen_at': null,
      'created_at': '2026-10-03T10:00:00Z',
      'updated_at': '2026-10-03T10:00:00Z',
    };

Map<String, dynamic> _listBody(List<Map<String, dynamic>> items) =>
    {'items': items, 'total': items.length};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  late MockDio dio;
  late List<String> postedPaths;

  Future<ProviderContainer> pumpDevices(
    WidgetTester tester, {
    List<String> scopes = const ['device_manage'],
    List<Map<String, dynamic>> devices = const [],
    String code = '481 902',
  }) async {
    dio = MockDio();
    postedPaths = <String>[];

    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(_devicesPath)).thenAnswer(
      (_) async => _ok(_devicesPath, _listBody(devices)),
    );
    when(() => dio.get(_codePath)).thenAnswer(
      (_) async => _ok(_codePath, {
        'code': code,
        'generated_at': '2026-10-03T10:00:00Z',
        'expires_at': '2026-10-03T10:15:00Z',
        'expires_in_seconds': 900,
        'protocol': 'http',
        'server_id': 'server-1',
        'http_port': 8000,
      }),
    );
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer((i) async {
      postedPaths.add(i.positionalArguments.first as String);
      return _ok(i.positionalArguments.first as String, <String, dynamic>{});
    });

    final user = AuthUser(
      id: '00000000-0000-0000-0000-0000000000a1',
      fullName: 'Admin',
      isActive: true,
      roles: const ['admin'],
      permissions: scopes,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
          currentUserProvider.overrideWithValue(user),
          localeProvider
              .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(body: DevicesScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return ProviderScope.containerOf(tester.element(find.byType(DevicesScreen)));
  }

  group('DevicesScreen', () {
    testWidgets('is denied without the device_manage scope', (tester) async {
      await pumpDevices(tester, scopes: const ['pos_sale']);

      expect(
        find.text(AppStrings.t('permission_denied', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('devices-title')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows title, pairing card and the empty sections',
        (tester) async {
      await pumpDevices(tester);

      expect(find.byKey(const Key('devices-title')), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_devices_title', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('generate-code')), findsOneWidget);
      expect(find.byKey(const Key('pairing-code-value')), findsNothing);
      expect(
        find.text(AppStrings.t('lan_enter_pairing_code', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('no-pending')), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_no_registered', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders pending and registered devices with their actions',
        (tester) async {
      await pumpDevices(tester, devices: [
        _device('pos-a1', name: 'Cashier PC'),
        _device('pos-b2', status: 'approved', name: 'Back office',
            lastIp: '192.168.1.20', clientVersion: '1.0.0'),
        _device('pos-c3', status: 'revoked', name: 'Old till'),
      ]);
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const Key('pending-pos-a1')), findsOneWidget);
      expect(find.byKey(const Key('approve-pos-a1')), findsOneWidget);
      expect(find.byKey(const Key('reject-pos-a1')), findsOneWidget);

      expect(find.byKey(const Key('device-pos-b2')), findsOneWidget);
      expect(find.byKey(const Key('revoke-pos-b2')), findsOneWidget);

      expect(find.byKey(const Key('device-pos-c3')), findsOneWidget);
      expect(find.byKey(const Key('revoke-pos-c3')), findsNothing);
      expect(
        find.text(AppStrings.t('lan_status_revoked', 'en')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('generate-code displays the 6-digit code, never a token',
        (tester) async {
      await pumpDevices(tester);

      await tester.tap(find.byKey(const Key('generate-code')));
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const Key('pairing-code-value')), findsOneWidget);
      expect(find.text('481 902'), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_pairing_code_hint', 'en')),
        findsOneWidget,
      );
      // No token wording anywhere on the server screen (§23.1).
      expect(find.textContaining('token'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deny posts straight to /deny; approve asks for confirmation',
        (tester) async {
      await pumpDevices(tester, devices: [_device('pos-a1')]);
      await tester.pump(const Duration(milliseconds: 80));

      await tester.tap(find.byKey(const Key('reject-pos-a1')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(postedPaths, ['$_devicesPath/pos-a1/deny']);

      final approveLabel = AppStrings.t('lan_approve', 'en');
      final cancelLabel = AppStrings.t('cancel', 'en');

      await tester.tap(find.byKey(const Key('approve-pos-a1')));
      await tester.pump();
      expect(find.byKey(Key('confirm-$approveLabel')), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, cancelLabel));
      await tester.pump();
      expect(postedPaths, ['$_devicesPath/pos-a1/deny'],
          reason: 'cancelling must not approve');

      await tester.tap(find.byKey(const Key('approve-pos-a1')));
      await tester.pump();
      await tester.tap(find.byKey(Key('confirm-$approveLabel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(postedPaths, [
        '$_devicesPath/pos-a1/deny',
        '$_devicesPath/pos-a1/approve',
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('revoke shows the destructive confirmation first',
        (tester) async {
      await pumpDevices(tester, devices: [
        _device('pos-b2', status: 'approved', name: 'Back office'),
      ]);
      await tester.pump(const Duration(milliseconds: 80));

      await tester.tap(find.byKey(const Key('revoke-pos-b2')));
      await tester.pump();
      expect(
        find.text(AppStrings.t('lan_revoke_confirm', 'en')),
        findsOneWidget,
      );
      expect(postedPaths, isEmpty);

      await tester.tap(find.text(AppStrings.t('cancel', 'en')));
      await tester.pump();
      expect(postedPaths, isEmpty);

      await tester.tap(find.byKey(const Key('revoke-pos-b2')));
      await tester.pump();
      await tester
          .tap(find.widgetWithText(FilledButton, AppStrings.t('lan_revoke', 'en')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(postedPaths, ['$_devicesPath/pos-b2/revoke']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load surfaces a retryable error, not a crash',
        (tester) async {
      dio = MockDio();
      when(() => dio.interceptors).thenReturn(Interceptors());
      when(() => dio.options).thenReturn(BaseOptions());
      when(() => dio.get(_devicesPath)).thenThrow(
        DioException.connectionError(
          requestOptions: RequestOptions(path: _devicesPath),
          reason: 'down',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            credentialStorageProvider
                .overrideWithValue(_NoSessionCredentialStorage()),
            currentUserProvider.overrideWithValue(AuthUser(
              id: 'u',
              fullName: 'Admin',
              isActive: true,
              roles: const ['admin'],
              permissions: const ['device_manage'],
            )),
            localeProvider.overrideWith(
              (ref) => LocaleNotifier()..setLocale(AppLocale.en),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: Scaffold(body: DevicesScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const Key('devices-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('network_error_retry', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
