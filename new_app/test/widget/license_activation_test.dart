// Phase L2-C — the Lifetime activation UI on the licensing screen.
//
// Pins: request-code generation on open (with copy-to-clipboard), the
// signed-code submission against the exact existing endpoints, the
// immediate in-place status refresh after success (lifetime card replaces
// the trial card, no restart), every failure state rendered from the
// actual backend error code, the client-side empty-input rejection, the
// "already activated" state, the preserved trial/expired presentation,
// Arabic RTL rendering, and the lifetime banner branch.
//
// Every test that mounts a license card unmounts before returning: the
// trial card owns a one-minute refresh timer that must not outlive the
// test (same rule as the L1-C widget tests).
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/features/licensing/license_snapshot.dart';
import 'package:supermarket_pos/features/licensing/license_widgets.dart';
import 'package:supermarket_pos/features/licensing/licensing_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart'
    show appLocalizationsDelegates, appSupportedLocales;
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

/// Deterministic locale without touching SharedPreferences.
class _FixedLocaleNotifier extends LocaleNotifier {
  _FixedLocaleNotifier(AppLocale locale) {
    state = LocaleState(locale: locale);
  }
}

const _statusPath = '/api/v1/license/status';
const _requestPath = '/api/v1/license/activation-request';
const _activatePath = '/api/v1/license/activate';
const _setupCheckPath = '/api/v1/auth/setup/check';

const _requestCode = 'SMPr1.TESTREQ';
const _fingerprintCode = 'ABCD-1234';

Response<dynamic> _resp(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

DioException _envelope(int status, String code) => DioException(
      requestOptions: RequestOptions(path: _activatePath),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: _activatePath),
        statusCode: status,
        data: {
          'error': {
            'code': code,
            'message': 'backend text for $code',
            'details': <String, dynamic>{},
          },
        },
      ),
    );

DioException _network() => DioException.connectionError(
      requestOptions: RequestOptions(path: _activatePath),
      reason: 'connection refused',
    );

Map<String, dynamic> _trialStatusPayload({String status = 'active'}) =>
    <String, dynamic>{
      'mode': status == 'active' ? 'trial' : 'trial_expired',
      'status': status,
      'license_type': null,
      'license_id': null,
      'activated_at': null,
      'trial': <String, dynamic>{
        'mode': status == 'active' ? 'trial' : 'trial_expired',
        'status': status,
        'trial_active': status == 'active',
        'trial_expired': status != 'active',
        'expires_at': status == 'active'
            ? '2099-01-01T00:00:00Z'
            : '2020-01-01T00:00:00Z',
        'remaining_seconds': status == 'active' ? 777600 : 0,
        'trial_days': 10,
      },
    };

Map<String, dynamic> _lifetimeStatusPayload() => <String, dynamic>{
      'mode': 'lifetime',
      'status': 'active',
      'license_type': 'lifetime',
      'license_id': 'LIC-42',
      'activated_at': '2026-11-03T09:30:00Z',
      'trial': _trialStatusPayload(status: 'expired')['trial'],
    };

LicenseInfo _trialInfo({required bool expired}) => LicenseInfo(
      mode: expired ? LicenseMode.trialExpired : LicenseMode.trial,
      status: expired ? LicenseStatus.expired : LicenseStatus.active,
      trialActive: !expired,
      trialExpired: expired,
      remainingSeconds: expired ? 0 : 777600,
      firstLaunchAt: DateTime.now().subtract(const Duration(days: 1)),
      expiresAt: expired
          ? DateTime.now().subtract(const Duration(days: 1))
          : DateTime.now().add(const Duration(days: 8)),
      trialDays: 10,
    );

LicenseSnapshot _lifetimeSnapshot() =>
    LicenseSnapshot.tryParse(_lifetimeStatusPayload())!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDio dio;

  // The body the status endpoint answers with — tests swap this between
  // the pre-activation trial state and the post-activation lifetime one.
  late Map<String, dynamic> statusBody;

  setUp(() {
    dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    statusBody = _trialStatusPayload();
    when(() => dio.get(_setupCheckPath))
        .thenAnswer((_) async => _resp(_setupCheckPath, {
              'setup_needed': false,
            }));
    when(() => dio.get(_statusPath))
        .thenAnswer((_) async => _resp(_statusPath, statusBody));
    when(() => dio.post(_requestPath)).thenAnswer(
      (_) async => _resp(_requestPath, {
        'request_code': _requestCode,
        'fingerprint_display_code': _fingerprintCode,
      }),
    );
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    LicenseInfo? license,
    LicenseSnapshot? snapshot,
    AppLocale locale = AppLocale.en,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
          localeProvider.overrideWith((ref) => _FixedLocaleNotifier(locale)),
          if (license != null)
            licenseStatusProvider.overrideWith((ref) => license),
          if (snapshot != null)
            licenseSnapshotProvider.overrideWith((ref) => snapshot),
        ],
        child: MaterialApp(
          locale: ui.Locale(locale.name),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const LicensingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  LicenseSnapshot? snapshotOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(LicensingScreen)))
          .read(licenseSnapshotProvider);

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  void stubActivateSuccess() {
    when(() => dio.post(_activatePath, data: any(named: 'data'))).thenAnswer(
        (_) async => _resp(_activatePath, _lifetimeStatusPayload()));
  }

  group('request code', () {
    testWidgets('is generated on open and copied with the copy action',
        (tester) async {
      final clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          clipboard.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpScreen(tester, license: _trialInfo(expired: false));

      verify(() => dio.post(_requestPath)).called(1);
      expect(find.byKey(const Key('license-activation-panel')), findsOneWidget);
      expect(find.text(_requestCode), findsOneWidget);
      expect(find.text(_fingerprintCode), findsOneWidget);

      await tester.tap(find.byKey(const Key('license-activation-copy-request')));
      await tester.pump();

      final setData = clipboard
          .where((call) => call.method == 'Clipboard.setData')
          .toList();
      expect(setData, hasLength(1));
      expect((setData.single.arguments as Map)['text'], _requestCode);
      expect(find.byKey(const Key('license-activation-copied-snack')),
          findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a failed request surfaces the network sentence and keeps a '
        'retry button', (tester) async {
      when(() => dio.post(_requestPath)).thenThrow(_network());

      await pumpScreen(tester);

      expect(find.byKey(const Key('license-activation-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_activation_error_network', 'en')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('license-activation-request-button')),
        findsOneWidget,
      );

      await unmount(tester);
    });
  });

  group('activation success', () {
    testWidgets(
        'a signed code activates in place: success state, lifetime card, '
        'no restart', (tester) async {
      await pumpScreen(tester, license: _trialInfo(expired: true));
      expect(find.byKey(const Key('license-card')), findsOneWidget,
          reason: 'the rescue scenario starts on an expired trial');

      stubActivateSuccess();
      statusBody = _lifetimeStatusPayload(); // the refresh answers lifetime

      await tester.enterText(
        find.byKey(const Key('license-activation-input')),
        '  SMP1.VALID  ',
      );
      await tester.tap(find.byKey(const Key('license-activation-submit')));
      await tester.pumpAndSettle();

      verify(() => dio.post(_activatePath, data: any(named: 'data'))).called(1);
      // Twice: once at mount (best-effort) and once as the refresh right
      // after the activation.
      verify(() => dio.get(_statusPath)).called(2);

      final container =
          ProviderScope.containerOf(tester.element(find.byType(LicensingScreen)));
      final activation = container.read(activationControllerProvider);
      expect(activation.phase, ActivationPhase.success,
          reason: 'phase=${activation.phase} key=${activation.errorMessageKey} '
              'code=${activation.errorCode} req=${activation.requestCode}');

      expect(
          find.byKey(const Key('license-activation-success')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_activation_success', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('lifetime-card')), findsOneWidget);
      expect(find.byKey(const Key('lifetime-card-chip')), findsOneWidget);
      expect(find.byKey(const Key('license-card')), findsNothing,
          reason: 'a licensed install is not presented as trial-limited');
      expect(find.byKey(const Key('license-activation-already')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('license-activation-input')),
            )
            .controller!
            .text,
        isEmpty,
        reason: 'the consumed code must not linger in the field',
      );
      expect(snapshotOf(tester)?.isLifetime, isTrue,
          reason: 'the status was refreshed without an app restart');

      await unmount(tester);
    });
  });

  group('failure states from real backend codes', () {
    const cases = <String, String>{
      'license_invalid': 'license_error_invalid',
      'license_bound_elsewhere': 'license_error_bound_elsewhere',
      'license_invalid_key': 'license_error_invalid_key',
      'RATE_LIMITED': 'license_activation_error_rate_limited',
      'INTERNAL_ERROR': 'license_activation_error_server',
    };

    cases.forEach((code, messageKey) {
      testWidgets('$code renders its own localized sentence', (tester) async {
        final status = code == 'RATE_LIMITED'
            ? 429
            : (code == 'INTERNAL_ERROR' ? 500 : 403);
        when(() => dio.post(_activatePath, data: any(named: 'data')))
            .thenThrow(_envelope(status, code));

        await pumpScreen(tester);

        await tester.enterText(
          find.byKey(const Key('license-activation-input')),
          'SMP1.CODE',
        );
        await tester.tap(find.byKey(const Key('license-activation-submit')));
        await tester.pumpAndSettle();

        final expected = AppStrings.t(messageKey, 'en');
        expect(find.byKey(const Key('license-activation-error')), findsOneWidget);
        expect(
          find.text(expected),
          findsOneWidget,
          reason: '$code must render $expected',
        );
        expect(find.byKey(const Key('lifetime-card')), findsNothing);
        expect(snapshotOf(tester)?.isLifetime, isFalse,
            reason: 'a failed attempt never writes a lifetime snapshot');
        expect(snapshotOf(tester)?.mode, LicenseSnapshotMode.trial,
            reason: 'the pre-existing trial snapshot must stay untouched');

        await unmount(tester);
      });
    });

    testWidgets('an unreachable server renders the network sentence',
        (tester) async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_network());

      await pumpScreen(tester);
      await tester.enterText(
        find.byKey(const Key('license-activation-input')),
        'SMP1.CODE',
      );
      await tester.tap(find.byKey(const Key('license-activation-submit')));
      await tester.pumpAndSettle();

      expect(
        find.text(AppStrings.t('license_activation_error_network', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('lifetime-card')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an empty submission is rejected before any request',
        (tester) async {
      await pumpScreen(tester);
      verifyNever(() => dio.post(_activatePath, data: any(named: 'data')));

      await tester.tap(find.byKey(const Key('license-activation-submit')));
      await tester.pumpAndSettle();

      expect(
        find.text(AppStrings.t('license_activation_error_empty', 'en')),
        findsOneWidget,
      );
      verifyNever(() => dio.post(_activatePath, data: any(named: 'data')));

      await unmount(tester);
    });
  });

  group('preserved trial experience and states', () {
    testWidgets('an active trial keeps its card and the panel stays',
        (tester) async {
      await pumpScreen(tester, license: _trialInfo(expired: false));

      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(find.byKey(const Key('lifetime-card')), findsNothing);
      expect(find.byKey(const Key('license-activation-panel')), findsOneWidget);
      expect(find.byKey(const Key('license-back-button')), findsOneWidget);
      expect(find.byKey(const Key('license-activation-already')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an expired trial keeps its restrictions around the panel',
        (tester) async {
      await pumpScreen(tester, license: _trialInfo(expired: true));

      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(
        find.byKey(const Key('license-card-message')),
        findsOneWidget,
        reason: 'the expired sentence must stay',
      );
      expect(find.byKey(const Key('license-activation-panel')), findsOneWidget,
          reason: 'activation is the rescue path on an expired trial');
      expect(find.byKey(const Key('license-back-button')), findsNothing,
          reason: 'an unlicensed expired install stays parked');
      expect(find.byKey(const Key('lifetime-card')), findsNothing);

      await unmount(tester);
    });

    testWidgets('an already activated install shows the lifetime state and '
        'regains navigation', (tester) async {
      await pumpScreen(
        tester,
        license: _trialInfo(expired: true),
        snapshot: _lifetimeSnapshot(),
      );

      expect(find.byKey(const Key('lifetime-card')), findsOneWidget);
      expect(
          find.byKey(const Key('license-activation-already')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_activation_already', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-back-button')), findsOneWidget,
          reason: 'a licensed install is never held by an expired trial');
      expect(find.byKey(const Key('license-logout-button')), findsNothing);

      await unmount(tester);
    });
  });

  group('localization and layout', () {
    testWidgets('Arabic renders RTL with translated activation labels',
        (tester) async {
      await pumpScreen(
        tester,
        license: _trialInfo(expired: false),
        locale: AppLocale.ar,
      );

      expect(
        tester.widget<Directionality>(find.byType(Directionality)).textDirection,
        TextDirection.rtl,
      );
      expect(find.text('تفعيل الترخيص الدائم'), findsOneWidget,
          reason: 'the panel title must be translated');
      expect(find.text('طلب رمز التفعيل'), findsOneWidget);
      expect(find.text('تفعيل'), findsOneWidget);
      expect(find.text(_requestCode), findsOneWidget,
          reason: 'the request code survives RTL mirroring');

      await unmount(tester);
    });
  });

  group('lifetime banner branch', () {
    testWidgets('a lifetime snapshot replaces the trial countdown banner',
        (tester) async {
      tester.view.physicalSize = const Size(900, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            licenseSnapshotProvider.overrideWith((ref) => _lifetimeSnapshot()),
            licenseStatusProvider.overrideWith((ref) => _trialInfo(expired: true)),
          ],
          child: MaterialApp(
            locale: ui.Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const Scaffold(body: TrialStatusBanner()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(find.byKey(const Key('license-banner-chip')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_lifetime_active', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-banner-lifetime')), findsOneWidget);
      expect(find.byKey(const Key('license-banner-remaining')), findsNothing,
          reason: 'a lifetime banner never counts down a trial');

      await unmount(tester);
    });

    testWidgets('without a lifetime snapshot the trial banner is unchanged',
        (tester) async {
      tester.view.physicalSize = const Size(900, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            licenseStatusProvider.overrideWith((ref) => _trialInfo(expired: false)),
          ],
          child: MaterialApp(
            locale: ui.Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const Scaffold(body: TrialStatusBanner()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_trial_active', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-banner-lifetime')), findsNothing);

      await unmount(tester);
    });
  });
}
