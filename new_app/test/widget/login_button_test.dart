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
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class LoginCredentialStorage extends SecureCredentialStorage {
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
const _keyHandlerKey = Key('login-key-handler');

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

  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<Override> overridesFor(MockDio dio, {AppLocale locale = AppLocale.ar}) {
    return [
      apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
      credentialStorageProvider.overrideWithValue(LoginCredentialStorage()),
      localeProvider.overrideWith((ref) {
        final notifier = LocaleNotifier();
        notifier.setLocale(locale);
        return notifier;
      }),
    ];
  }

  Future<void> pumpLoginScreen(
    WidgetTester tester,
    MockDio dio, {
    AppLocale locale = AppLocale.ar,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overridesFor(dio, locale: locale),
        child: MaterialApp(
          locale: Locale(locale.name),
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

  Future<void> enterPinDigits(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
  }

  Finder submitButton() => find.byKey(_submitKey);

  ElevatedButton submitButtonWidget(WidgetTester tester) =>
      tester.widget<ElevatedButton>(submitButton());

  group('Login button gating', () {
    testWidgets(
        'button appears after user selection and stays disabled until '
        'PIN has at least 4 digits', (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      expect(submitButton(), findsNothing);

      await selectAdmin(tester);
      expect(submitButton(), findsOneWidget);
      expect(submitButtonWidget(tester).onPressed, isNull,
          reason: 'empty PIN must keep the button disabled');

      await enterPinDigits(tester, '123');
      expect(submitButtonWidget(tester).onPressed, isNull,
          reason: '3-digit PIN is below minPinLength (4)');

      await tester.tap(find.text('4'));
      await tester.pump();
      expect(submitButtonWidget(tester).onPressed, isNotNull,
          reason: '4-digit PIN enables the button');

      expect(tester.takeException(), isNull);
    });

    testWidgets('backspace below 4 digits disables the button again',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');
      expect(submitButtonWidget(tester).onPressed, isNotNull);

      final backspace = find.byIcon(Icons.backspace_outlined);
      await tester.tap(backspace);
      await tester.pump();
      expect(submitButtonWidget(tester).onPressed, isNull);
    });
  });

  group('Login button action', () {
    testWidgets(
        'tapping the button sends POST /api/v1/auth/login with user_id and 4-digit PIN',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) async => successLoginResponse());

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');

      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      final captured = verify(
        () => dio.post(_loginPath, data: captureAny(named: 'data')),
      ).captured;
      expect(captured, hasLength(1));
      final data = captured.single as Map;
      expect(data['user_id'], 'u1');
      expect(data['pin'], '1234');
      expect(data['device_name'], 'Desktop POS');
    });

    testWidgets('double-tapping while authenticating sends only one POST',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      final completer = Completer<Response<dynamic>>();
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) => completer.future);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');

      await tester.tap(submitButton());
      await tester.tap(submitButton());
      completer.complete(successLoginResponse());
      await tester.pumpAndSettle();

      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
    });

    testWidgets('Enter key with a valid PIN triggers the login request',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) async => successLoginResponse());

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');

      final focusHandler =
          tester.widget<Focus>(find.byKey(_keyHandlerKey));
      focusHandler.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
    });

    testWidgets('successful login navigates to the Dashboard in the full app',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((_) async => successLoginResponse());

      await pumpFullApp(tester, dio);
      expect(find.text('Admin'), findsOneWidget);

      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');
      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      expect(find.text('Dashboard - Phase 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Login button error handling', () {
    testWidgets(
        'invalid PIN (HTTP 401) shows the authentication error, never a connection error',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.post(_loginPath, data: any(named: 'data'))).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: _loginPath),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: _loginPath),
            statusCode: 401,
            data: <String, dynamic>{},
          ),
          type: DioExceptionType.badResponse,
        ),
      );

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');
      await tester.tap(submitButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text(AppStrings.t('authentication_failed', 'ar')),
          findsOneWidget);
      expect(find.text(AppStrings.t('network_error_retry', 'ar')), findsNothing);

      expect(tester.takeException(), isNull);
    });
  });

  group('Login button localization', () {
    Future<void> expectLabel(WidgetTester tester, AppLocale locale,
        String expected) async {
      final dio = MockDio();
      stubBootRequests(dio);
      await pumpLoginScreen(tester, dio, locale: locale);
      await selectAdmin(tester);

      expect(
        find.text(expected),
        findsOneWidget,
        reason: 'login_submit must render as "$expected" for ${locale.name}',
      );
      expect(submitButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    testWidgets('Arabic button label', (tester) async {
      useDesktopViewport(tester);
      await expectLabel(tester, AppLocale.ar, 'تسجيل الدخول');
    });

    testWidgets('French button label', (tester) async {
      useDesktopViewport(tester);
      await expectLabel(tester, AppLocale.fr, 'Se connecter');
    });

    testWidgets('English button label', (tester) async {
      useDesktopViewport(tester);
      await expectLabel(tester, AppLocale.en, 'Login');
    });
  });

  group('Login button layout', () {
    testWidgets('PIN pad plus login button renders without overflow',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpLoginScreen(tester, dio);
      await selectAdmin(tester);
      await enterPinDigits(tester, '1234');

      expect(submitButton(), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Also verify at a short window height where scrolling is required.
      tester.view.physicalSize = const Size(800, 500);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
