// First-run administrator setup — ONE page, validation, auto-login.
//
// Contracts pinned here:
//  * a fresh install sees the setup page (driven by `setup_needed`), with
//    username + PIN + confirm all on one page and both PINs obscured;
//  * the visibility toggle reveals both PIN fields;
//  * missing fields / invalid PIN / mismatched confirmation never POST;
//  * a successful creation POSTs once and leaves the app AUTHENTICATED with
//    the token the backend returned (no second PIN prompt);
//  * a refused creation (409: an admin already exists) shows the backend
//    message and keeps the app unauthenticated.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/setup_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class RecordingCredentialStorage extends SecureCredentialStorage {
  String? token;
  String? userName;
  List<String> permissions = [];

  @override
  Future<bool> hasToken() async => token != null;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async => userName = name;

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> value) async =>
      permissions = value;

  @override
  Future<List<String>> readUserRoles() async => const [];

  @override
  Future<List<String>> readUserPermissions() async => permissions;

  @override
  Future<void> clearAll() async {
    token = null;
    userName = null;
    permissions = [];
  }
}

const _setupPath = '/api/v1/auth/setup';
const _setupCheckPath = '/api/v1/auth/setup/check';
const _mePath = '/api/v1/auth/me';

const _adminPermissions = [
  'settings_manage',
  'product_create',
  'pos_sale',
];

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void _stubBoot(MockDio dio, {bool setupNeeded = true}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(_setupCheckPath)).thenAnswer(
    (_) async => _ok(_setupCheckPath, {'setup_needed': setupNeeded}),
  );
  when(() => dio.get(_mePath)).thenAnswer(
    (_) async => _ok(_mePath, {
      'id': 'admin-1',
      'full_name': 'Patron',
      'is_active': true,
      'permissions': _adminPermissions,
      'roles': ['admin'],
    }),
  );
}

void _stubSuccessfulSetup(MockDio dio, {List<Map<String, dynamic>>? captured}) {
  when(() => dio.post(_setupPath, data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      captured?.add(
        Map<String, dynamic>.from(invocation.namedArguments[#data] as Map),
      );
      return _ok(_setupPath, {
        'user_id': 'admin-1',
        'name': 'Patron',
        'message': 'Admin account created successfully',
        'access_token': 'fresh-admin-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': 'admin-1',
          'full_name': 'Patron',
          'is_active': true,
          'created_at': '2026-11-21T10:00:00Z',
          'roles': [
            {
              'id': 'role-1',
              'name': 'admin',
              'permissions': [
                for (final scope in _adminPermissions) {'scope': scope},
              ],
            },
          ],
        },
      });
    },
  );
}

Future<ProviderContainer> _pumpSetup(
  WidgetTester tester,
  MockDio dio, {
  RecordingCredentialStorage? storage,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(
          storage ?? RecordingCredentialStorage(),
        ),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const SetupScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Finder get _usernameField => find.byKey(const Key('setup-username-field'));
Finder get _pinField => find.byKey(const Key('setup-pin-field'));
Finder get _confirmField => find.byKey(const Key('setup-confirm-pin-field'));
Finder get _submit => find.byKey(const Key('setup-submit-button'));

Future<void> _fill(
  WidgetTester tester, {
  String username = 'Patron',
  String pin = '1234',
  String confirm = '1234',
}) async {
  await tester.enterText(_usernameField, username);
  await tester.enterText(_pinField, pin);
  await tester.enterText(_confirmField, confirm);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fresh install gets ONE setup page with username + both PINs',
      (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    _stubSuccessfulSetup(dio);
    await _pumpSetup(tester, dio);

    expect(find.byKey(const Key('setup-title')), findsOneWidget);
    expect(find.text(AppStrings.t('setup_subtitle', 'en')), findsOneWidget);
    expect(_usernameField, findsOneWidget);
    expect(_pinField, findsOneWidget);
    expect(_confirmField, findsOneWidget);
    expect(
      find.descendant(of: _submit, matching: find.text('Create Administrator Account')),
      findsOneWidget,
    );

    // PINs are obscured by default.
    expect(tester.widget<TextField>(_pinField).obscureText, isTrue);
    expect(tester.widget<TextField>(_confirmField).obscureText, isTrue);

    // Nothing is sent before the operator submits.
    verifyNever(() => dio.post(_setupPath, data: any(named: 'data')));
  });

  testWidgets('the visibility toggle reveals both PIN fields', (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    await _pumpSetup(tester, dio);

    await tester.tap(find.byKey(const Key('setup-pin-visibility')));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_pinField).obscureText, isFalse);
    expect(tester.widget<TextField>(_confirmField).obscureText, isFalse);

    await tester.tap(find.byKey(const Key('setup-confirm-pin-visibility')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_pinField).obscureText, isTrue);
    expect(tester.widget<TextField>(_confirmField).obscureText, isTrue);
  });

  testWidgets('an empty form shows field errors and never POSTs',
      (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    _stubSuccessfulSetup(dio);
    await _pumpSetup(tester, dio);

    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.t('setup_username_required', 'en')),
        findsOneWidget);
    // Both PIN fields report the same required message.
    expect(find.text(AppStrings.t('pin_required', 'en')), findsNWidgets(2));
    verifyNever(() => dio.post(_setupPath, data: any(named: 'data')));
  });

  testWidgets('an invalid PIN is rejected before any request', (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    await _pumpSetup(tester, dio);

    await _fill(tester, pin: '12', confirm: '12');
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    // The confirmation matches, so only the PIN field itself is in error.
    expect(find.text(AppStrings.t('pin_required', 'en')), findsOneWidget);
    verifyNever(() => dio.post(_setupPath, data: any(named: 'data')));
  });

  testWidgets('a mismatched confirmation never POSTs', (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    await _pumpSetup(tester, dio);

    await _fill(tester, pin: '1234', confirm: '4321');
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.t('pin_mismatch', 'en')), findsOneWidget);
    verifyNever(() => dio.post(_setupPath, data: any(named: 'data')));
  });

  testWidgets('a successful creation signs the administrator in immediately',
      (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    final payloads = <Map<String, dynamic>>[];
    _stubSuccessfulSetup(dio, captured: payloads);
    final storage = RecordingCredentialStorage();
    final container = await _pumpSetup(tester, dio, storage: storage);

    await _fill(tester);
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(payloads, hasLength(1));
    expect(payloads.single, {
      'name': 'Patron',
      'pin': '1234',
      'pin_confirm': '1234',
    });

    final auth = container.read(authProvider);
    expect(auth.status, AuthStatus.authenticated);
    expect(auth.user?.fullName, 'Patron');
    expect(auth.user?.roles, contains('admin'));
    expect(auth.user?.permissions, contains('settings_manage'));
    expect(storage.token, 'fresh-admin-token');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused creation shows the backend message and stays signed out',
      (tester) async {
    final dio = MockDio();
    _stubBoot(dio);
    when(() => dio.post(_setupPath, data: any(named: 'data'))).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: _setupPath),
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: _setupPath),
          statusCode: 409,
          data: {
            'error': {
              'code': 'CONFLICT',
              'message': 'Admin account already exists',
            },
          },
        ),
      ),
    );
    final container = await _pumpSetup(tester, dio);

    await _fill(tester);
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('setup-form-error')), findsOneWidget);
    expect(find.text('Admin account already exists'), findsOneWidget);
    expect(container.read(authProvider).status, isNot(AuthStatus.authenticated));
    // The form stays on screen for a retry.
    expect(_submit, findsOneWidget);
  });
}
