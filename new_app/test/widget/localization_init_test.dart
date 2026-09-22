import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/pin_pad.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class NoSessionCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => false;

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clearAll() async {}
}

Matcher hasArabicScript() => matches(RegExp(r'[\u0600-\u06FF]'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('App localization delegate configuration', () {
    test('registers Material, Widgets and Cupertino global delegates', () {
      expect(
        appLocalizationsDelegates,
        contains(GlobalMaterialLocalizations.delegate),
      );
      expect(
        appLocalizationsDelegates,
        contains(GlobalWidgetsLocalizations.delegate),
      );
      expect(
        appLocalizationsDelegates,
        contains(GlobalCupertinoLocalizations.delegate),
      );
    });

    test('supported locales are ar, fr and en', () {
      expect(appSupportedLocales, const <Locale>[
        Locale('ar'),
        Locale('fr'),
        Locale('en'),
      ]);
    });

    test('global delegates support ar, fr and en', () {
      for (final locale in appSupportedLocales) {
        expect(
          GlobalMaterialLocalizations.delegate.isSupported(locale),
          isTrue,
          reason: 'GlobalMaterialLocalizations must support $locale',
        );
        expect(
          GlobalWidgetsLocalizations.delegate.isSupported(locale),
          isTrue,
          reason: 'GlobalWidgetsLocalizations must support $locale',
        );
        expect(
          GlobalCupertinoLocalizations.delegate.isSupported(locale),
          isTrue,
          reason: 'GlobalCupertinoLocalizations must support $locale',
        );
      }
    });

    test(
      'Arabic loads real Material localization and RTL widgets direction',
      () async {
        final materialLocalizations = await GlobalMaterialLocalizations.delegate
            .load(const Locale('ar'));
        expect(materialLocalizations.openAppDrawerTooltip, hasArabicScript());

        final widgetsLocalizations = await GlobalWidgetsLocalizations.delegate
            .load(const Locale('ar'));
        expect(widgetsLocalizations.textDirection, TextDirection.rtl);

        final cupertinoLocalizations = await GlobalCupertinoLocalizations
            .delegate
            .load(const Locale('ar'));
        expect(cupertinoLocalizations, isNotNull);
      },
    );

    test('French and English Material localization load', () async {
      for (final locale in [const Locale('fr'), const Locale('en')]) {
        final materialLocalizations = await GlobalMaterialLocalizations.delegate
            .load(locale);
        expect(materialLocalizations.openAppDrawerTooltip, isNotEmpty);
      }
    });

    test('custom AppStrings translations remain available', () {
      expect(AppStrings.t('login_button', 'ar'), 'تسجيل الدخول');
      expect(AppStrings.t('login_button', 'fr'), 'Connexion');
      expect(AppStrings.t('login_button', 'en'), 'Login');
      expect(AppStrings.t('select_user', 'ar'), 'اختر المستخدم');
      expect(AppStrings.t('welcome', 'ar'), 'مرحباً بك');
      expect(AppStrings.t('welcome', 'fr'), 'Bienvenue');
      expect(AppStrings.t('welcome', 'en'), 'Welcome');
    });
  });

  group('SupermarketPosApp startup localization', () {
    Future<void> stubBootRequests(MockDio dio) async {
      when(() => dio.interceptors).thenReturn(Interceptors());
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

    Future<void> pumpSupermarketApp(
      WidgetTester tester, {
      required AppLocale locale,
    }) async {
      final dio = MockDio();
      await stubBootRequests(dio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            credentialStorageProvider.overrideWithValue(
              NoSessionCredentialStorage(),
            ),
            localeProvider.overrideWith((ref) {
              final notifier = LocaleNotifier();
              notifier.setLocale(locale);
              return notifier;
            }),
          ],
          child: const SupermarketPosApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Arabic startup does not throw MaterialLocalizations missing errors',
      (tester) async {
        await pumpSupermarketApp(tester, locale: AppLocale.ar);

        expect(tester.takeException(), isNull);
        expect(find.byType(MaterialApp), findsOneWidget);
        expect(find.byType(Scaffold), findsOneWidget);

        final context = tester.element(find.byType(Scaffold));
        final materialLocalizations = MaterialLocalizations.of(context);
        expect(materialLocalizations.openAppDrawerTooltip, hasArabicScript());
        expect(CupertinoLocalizations.of(context), isNotNull);
        expect(Directionality.of(context), TextDirection.rtl);

        expect(find.text('Admin'), findsOneWidget);
        expect(find.text(AppStrings.t('select_user', 'ar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Arabic login screen builds PIN pad and TextField', (
      tester,
    ) async {
      await pumpSupermarketApp(tester, locale: AppLocale.ar);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Admin'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(PinPad), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(AppStrings.t('pin', 'ar')), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'ar')), findsOneWidget);
    });

    testWidgets('French startup works with French Material localization', (
      tester,
    ) async {
      await pumpSupermarketApp(tester, locale: AppLocale.fr);

      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);

      final context = tester.element(find.byType(Scaffold));
      final materialLocalizations = MaterialLocalizations.of(context);
      expect(materialLocalizations.openAppDrawerTooltip, isNotEmpty);
      expect(
        materialLocalizations.openAppDrawerTooltip,
        isNot(hasArabicScript()),
      );
      expect(Directionality.of(context), TextDirection.ltr);

      expect(find.text('Admin'), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'fr')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('English startup works with English Material localization', (
      tester,
    ) async {
      await pumpSupermarketApp(tester, locale: AppLocale.en);

      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);

      final context = tester.element(find.byType(Scaffold));
      final materialLocalizations = MaterialLocalizations.of(context);
      expect(materialLocalizations.openAppDrawerTooltip, isNotEmpty);
      expect(Directionality.of(context), TextDirection.ltr);

      expect(find.text('Admin'), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Material localization-dependent widgets build under ar', () {
    testWidgets(
      'MaterialApp, buttons, dialogs, text fields, drawer and navigation work',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const _LocalizationProbeScreen(),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(MaterialApp), findsOneWidget);
        expect(find.byType(Scaffold), findsOneWidget);
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.byType(TextField), findsNWidgets(2));
        expect(find.byType(Card), findsOneWidget);
      expect(find.byType(PinPad), findsOneWidget);
      expect(find.byType(ElevatedButton), findsWidgets);
      expect(find.text('open'), findsOneWidget);

      await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsOneWidget);

        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.byType(DrawerButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(Drawer), findsOneWidget);
      },
    );
  });
}

class _LocalizationProbeScreen extends StatelessWidget {
  const _LocalizationProbeScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('probe')),
      drawer: const Drawer(child: SizedBox(height: 100)),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Card(child: SizedBox(height: 40, width: 200)),
          const TextField(),
          PinPad(locale: 'ar', onSubmit: (_) {}),
          ElevatedButton(
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('dialog'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('ok'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('open'),
          ),
        ],
      ),
    );
  }
}
