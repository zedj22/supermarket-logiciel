import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/auth/pin_pad.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class KeyboardCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => false;

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clearAll() async {}

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
  Future<List<String>> readUserRoles() async => [];

  @override
  Future<List<String>> readUserPermissions() async => [];
}

const _loginPath = '/api/v1/auth/login';
const _submitKey = Key('login-submit-button');
const _pinInputKey = Key('pin-input');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  void stubBootRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/setup/check'),
        data: {'setup_needed': false},
        statusCode: 200,
      ),
    );
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
        data: {
          'items': [
            {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
            },
          ],
          'total': 1,
        },
        statusCode: 200,
      ),
    );
    when(() => dio.get('/api/v1/auth/me')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/me'),
        data: {
          'id': 'u1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': [
            {'name': 'admin'},
          ],
          'permissions': ['user_manage'],
        },
        statusCode: 200,
      ),
    );
  }

  Response<dynamic> successLoginResponse() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-123',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
            'permissions': ['user_manage'],
          },
        },
        statusCode: 200,
      );

  DioException unauthorizedLogin() => DioException(
        requestOptions: RequestOptions(path: _loginPath),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: _loginPath),
          statusCode: 401,
          // Empty body → client falls back to localized authentication_failed.
          data: <String, dynamic>{},
        ),
        type: DioExceptionType.badResponse,
      );

  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<Override> overridesFor(MockDio dio, {AppLocale locale = AppLocale.ar}) {
    return [
      apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
      credentialStorageProvider
          .overrideWithValue(KeyboardCredentialStorage()),
      localeProvider.overrideWith((ref) {
        final notifier = LocaleNotifier();
        notifier.setLocale(locale);
        return notifier;
      }),
    ];
  }

  Future<void> pumpLoginScreen(WidgetTester tester, MockDio dio) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overridesFor(dio),
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const Scaffold(body: LoginScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpFullApp(WidgetTester tester, MockDio dio) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overridesFor(dio),
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectAdmin(WidgetTester tester) async {
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
  }

  Future<void> enterPinOnScreen(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      // Match only the on-screen keypad button (the PIN field's EditableText
      // also exposes the same digit string once entered).
      await tester.tap(find.widgetWithText(ElevatedButton, digit).last);
      await tester.pump();
    }
  }

  String pinFieldValue(WidgetTester tester) {
    final field = tester.widget<TextField>(find.byKey(_pinInputKey));
    return field.controller?.text ?? '';
  }

  Future<void> focusPinField(WidgetTester tester) async {
    final field = tester.widget<TextField>(find.byKey(_pinInputKey));
    field.focusNode?.requestFocus();
    await tester.pump();
  }

  Future<void> sendDigits(
    WidgetTester tester,
    List<(LogicalKeyboardKey key, String char)> keys,
  ) async {
    for (final (key, char) in keys) {
      await tester.sendKeyEvent(key, character: char);
      await tester.pump();
    }
  }

  const mainDigits = [
    (LogicalKeyboardKey.digit1, '1'),
    (LogicalKeyboardKey.digit2, '2'),
    (LogicalKeyboardKey.digit3, '3'),
    (LogicalKeyboardKey.digit4, '4'),
  ];

  const numpadDigits = [
    (LogicalKeyboardKey.numpad1, '1'),
    (LogicalKeyboardKey.numpad2, '2'),
    (LogicalKeyboardKey.numpad3, '3'),
    (LogicalKeyboardKey.numpad4, '4'),
  ];

  group('BUG 1 — physical keyboard PIN input', () {
    testWidgets('main-row digits 1234 type into the PIN field and enable Login',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await focusPinField(tester);

      await sendDigits(tester, mainDigits);

      expect(pinFieldValue(tester), '1234');
      final button =
          tester.widget<ElevatedButton>(find.byKey(_submitKey));
      expect(button.onPressed, isNotNull,
          reason: 'keyboard-entered 4-digit PIN must enable Login');
      expect(tester.takeException(), isNull);
    });

    testWidgets('numpad digits 1234 type into the PIN field and enable Login',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await focusPinField(tester);

      await sendDigits(tester, numpadDigits);

      expect(pinFieldValue(tester), '1234');
      final button =
          tester.widget<ElevatedButton>(find.byKey(_submitKey));
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keyboard Backspace removes exactly one digit', (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await focusPinField(tester);
      await sendDigits(tester, mainDigits);
      expect(pinFieldValue(tester), '1234');

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(pinFieldValue(tester), '123');
      final button =
          tester.widget<ElevatedButton>(find.byKey(_submitKey));
      expect(button.onPressed, isNull,
          reason: '3 digits is below minPinLength — button disabled again');
      expect(tester.takeException(), isNull);
    });

    testWidgets('keyboard Enter with valid PIN sends exactly one POST',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) async => successLoginResponse());

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await focusPinField(tester);
      await sendDigits(tester, mainDigits);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Enter and Login button together still send only one POST (guarded)',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      final completer = Completer<Response<dynamic>>();
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) => completer.future);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await focusPinField(tester);
      await sendDigits(tester, mainDigits);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tap(find.byKey(_submitKey));
      completer.complete(successLoginResponse());
      await tester.pumpAndSettle();

      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on-screen PIN pad still works alongside keyboard input',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);

      await enterPinOnScreen(tester, '12');
      await focusPinField(tester);
      await sendDigits(tester, [
        (LogicalKeyboardKey.digit3, '3'),
        (LogicalKeyboardKey.digit4, '4'),
      ]);

      expect(pinFieldValue(tester), '1234');
      expect(tester.takeException(), isNull);
    });
  });

  group('BUG 2 — wrong PIN preserves selected user', () {
    testWidgets(
        'failed login stays on Admin PIN screen: user kept, PIN cleared, error shown',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenThrow(unauthorizedLogin());

      await pumpFullApp(tester, dio);
      await selectAdmin(tester);
      await enterPinOnScreen(tester, '9999');
      expect(pinFieldValue(tester), '9999');

      await tester.tap(find.byKey(_submitKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // Still on the PIN screen (Login button + PIN field present).
      expect(find.byKey(_submitKey), findsOneWidget);
      expect(find.byKey(_pinInputKey), findsOneWidget);
      // Selected user identity still displayed.
      expect(find.text('Admin'), findsWidgets);
      // PIN cleared.
      expect(pinFieldValue(tester), '');
      // Localized authentication error visible on the PIN screen.
      expect(find.text(AppStrings.t('authentication_failed', 'ar')),
          findsOneWidget);
      // Not back on the user-selection list (no user-tile selection flow):
      // the PIN screen keeps the submit button — user list has none.
      expect(find.byType(PinPad), findsOneWidget);
      // Session was not expired / credentials not cleared: no logout.
      verifyNever(() => dio.post('/api/v1/auth/logout-token',
          data: any(named: 'data')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('retry after wrong PIN with correct PIN opens Dashboard',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenThrow(unauthorizedLogin());

      await pumpFullApp(tester, dio);
      await selectAdmin(tester);
      await enterPinOnScreen(tester, '9999');
      await tester.tap(find.byKey(_submitKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // Still on PIN screen for the same user.
      expect(find.text('Admin'), findsWidgets);
      expect(pinFieldValue(tester), '');

      // Correct PIN — same user, no re-selection.
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) async => successLoginResponse());
      await enterPinOnScreen(tester, '1234');
      expect(pinFieldValue(tester), '1234');
      await tester.tap(find.byKey(_submitKey));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard - Phase 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('login failure does not navigate away from /login route',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenThrow(unauthorizedLogin());

      await pumpFullApp(tester, dio);
      await selectAdmin(tester);
      await enterPinOnScreen(tester, '9999');
      await tester.tap(find.byKey(_submitKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // LoginScreen still mounted (same selection UI with PIN pad).
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(PinPad), findsOneWidget);
      expect(find.byKey(_submitKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
