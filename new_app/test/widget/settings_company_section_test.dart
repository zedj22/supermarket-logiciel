// Stage 1 (facturation legacy parity) — the Company Information section.
//
// Contract under test:
//  * the section is `settings_manage`-gated exactly like the store section
//    and never issues a request for anyone else;
//  * the seven Phase 6 fiscal fields (wilaya, email, rc, nif, ai, nis,
//    rib) round-trip through `GET/PUT /api/v1/settings` — the three legacy
//    company fields name/address/phone already live in the store section;
//  * saving company information sends the WHOLE form, so unrelated saved
//    settings ride along unchanged (never clobbered);
//  * incomplete fiscal data does not block a save — `store_name` is the
//    only required company field (the backend's COMPANY_MISSING rule);
//  * a failed save keeps the typing and never claims success;
//  * every label is localized (ar/fr/en through AppStrings).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

/// `kDefaultSettingsJson` with realistic company/fiscal values, to prove
/// the section seeds from the server snapshot.
const Map<String, Object> _companyFixture = <String, Object>{
  'store_name': 'Supermarket Pro',
  'store_phone': '023 45 67 89',
  'store_address': '12 Rue de la Liberté',
  'invoice_footer': 'Merci de votre visite',
  'store_wilaya': 'Alger',
  'store_email': 'contact@supermarket.dz',
  'store_nif': '1600011111111111',
  'store_nis': '1600022222222222',
  'store_rc': '16/00-9999999 B 99',
  'store_ai': '1600033333333333',
  'store_rib': '0079 1111 2222 3333 44',
  'default_paper': '80mm',
  'ask_before_print': false,
  'auto_print_invoice': false,
  'allow_debt': true,
  'low_stock_threshold': 5,
};

const _companyFieldKeys = <Key>[
  Key('settings-company-wilaya'),
  Key('settings-company-email'),
  Key('settings-company-rc'),
  Key('settings-company-nif'),
  Key('settings-company-ai'),
  Key('settings-company-nis'),
  Key('settings-company-rib'),
];

const _companyFieldLabels = <String>[
  'wilaya',
  'email',
  'rc',
  'nif',
  'ai',
  'nis',
  'rib',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> pumpSettingsApp(
    WidgetTester tester, {
    AppLocale locale = AppLocale.en,
    AppThemeMode mode = AppThemeMode.dark,
    SharedPreferences? prefs,
    AuthUser? user,
    FakeJsonAdapter? adapter,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          themeProvider.overrideWith(
            (ref) => ThemeNotifier(prefs)..setTheme(mode),
          ),
          if (user != null)
            currentUserProvider.overrideWithValue(user),
          if (adapter != null)
            apiClientProvider.overrideWithValue(
              ApiClient(dio: fakeDio(adapter)),
            ),
        ],
        child: const _SettingsHarness(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  group('Company information section (Stage 1)', () {
    testWidgets('hidden for a user without settings_manage, and never '
        'issues a request', (tester) async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 200, body: kDefaultSettingsJson),
      );

      await pumpSettingsApp(
        tester,
        user: _userWith(const []),
        adapter: adapter,
      );

      expect(find.byKey(const Key('settings-company-wilaya')), findsNothing);
      expect(
        find.byKey(const Key('settings-company-save-button')),
        findsNothing,
      );
      expect(adapter.requests, isEmpty,
          reason: 'a non-manager must not trigger a settings GET');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an admin sees the section with all seven fiscal fields '
        'seeded from the server snapshot', (tester) async {
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: _fixtureAdapter(_companyFixture),
      );

      expect(
        find.text(AppStrings.t('settings_company', 'en')),
        findsOneWidget,
      );
      for (final key in _companyFieldKeys) {
        expect(find.byKey(key), findsOneWidget, reason: 'missing $key');
      }
      expect(find.text('Alger'), findsOneWidget);
      expect(find.text('contact@supermarket.dz'), findsOneWidget);
      expect(find.text('1600011111111111'), findsOneWidget);
      expect(find.text('1600022222222222'), findsOneWidget);
      expect(find.text('16/00-9999999 B 99'), findsOneWidget);
      expect(find.text('1600033333333333'), findsOneWidget);
      expect(find.text('0079 1111 2222 3333 44'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the three legacy company fields that predate this stage — '
        'name, address, phone — remain editable in the store section',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: _fixtureAdapter(_companyFixture),
      );

      expect(find.byKey(const Key('settings-store-name')), findsOneWidget);
      expect(find.byKey(const Key('settings-store-phone')), findsOneWidget);
      expect(find.byKey(const Key('settings-store-address')), findsOneWidget);
      expect(find.text('12 Rue de la Liberté'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('save stays disabled until a company field actually changes',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: _fixtureAdapter(_companyFixture),
      );

      final save = find.byKey(const Key('settings-company-save-button'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await _enterText(
        tester,
        find.byKey(const Key('settings-company-wilaya')),
        'Oran',
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    });

    testWidgets('a successful save PUTs the seven company fields and sends '
        'the unrelated settings unchanged', (tester) async {
      final adapter = _fixtureAdapter(_companyFixture);
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
      );

      await _enterText(
        tester,
        find.byKey(const Key('settings-company-wilaya')),
        'Oran',
      );
      await _tap(
        tester,
        find.byKey(const Key('settings-company-save-button')),
      );

      final put = adapter.requests.lastWhere((r) => r.method == 'PUT');
      expect(put.path, '/api/v1/settings');
      final body = Map<String, dynamic>.from(put.data as Map);

      // The edited field...
      expect(body['store_wilaya'], 'Oran');
      // ...the untouched company fields...
      expect(body['store_email'], 'contact@supermarket.dz');
      expect(body['store_nif'], '1600011111111111');
      expect(body['store_nis'], '1600022222222222');
      expect(body['store_rc'], '16/00-9999999 B 99');
      expect(body['store_ai'], '1600033333333333');
      expect(body['store_rib'], '0079 1111 2222 3333 44');
      // ...and every unrelated setting, carried from the snapshot so a
      // company save can never revert them.
      expect(body['store_name'], 'Supermarket Pro');
      expect(body['store_phone'], '023 45 67 89');
      expect(body['store_address'], '12 Rue de la Liberté');
      expect(body['invoice_footer'], 'Merci de votre visite');
      expect(body['default_paper'], '80mm');
      expect(body['allow_debt'], isTrue);
      expect(body['low_stock_threshold'], 5);

      expect(find.text(AppStrings.t('settings_saved', 'en')), findsOneWidget);
      expect(find.byKey(const Key('settings-error-banner')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('incomplete company information is still saveable — only '
        'store_name is required, exactly like the COMPANY_MISSING guard',
        (tester) async {
      // Fresh-install snapshot: every company/fiscal field empty.
      final adapter = _fixtureAdapter(kDefaultSettingsJson);
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
      );

      final save = find.byKey(const Key('settings-company-save-button'));
      await _enterText(
        tester,
        find.byKey(const Key('settings-company-wilaya')),
        'Annaba',
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
          reason: 'empty fiscal identifiers must not block the save');

      await _tap(tester, save);

      final body = Map<String, dynamic>.from(
        adapter.requests.lastWhere((r) => r.method == 'PUT').data as Map,
      );
      expect(body['store_wilaya'], 'Annaba');
      expect(body['store_nif'], '', reason: 'left empty on purpose');
      expect(body['store_rib'], '', reason: 'left empty on purpose');
      expect(body['store_name'], 'Supermarket Pro');
      expect(find.text(AppStrings.t('settings_saved', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed save shows the failure banner, keeps the typed '
        'value and never claims success', (tester) async {
      final adapter = FakeJsonAdapter((options) async {
        if (options.method == 'PUT') {
          return (
            statusCode: 403,
            body: <String, Object>{
              'error': <String, Object>{
                'code': 'FORBIDDEN',
                'message': 'Insufficient permissions',
              },
            },
          );
        }
        return (statusCode: 200, body: _companyFixture);
      });
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
      );

      await _enterText(
        tester,
        find.byKey(const Key('settings-company-rib')),
        '0079 0000 0000 0000 00',
      );
      await _tap(
        tester,
        find.byKey(const Key('settings-company-save-button')),
      );

      expect(find.byKey(const Key('settings-error-banner')), findsOneWidget);
      expect(
        find.text(
          '${AppStrings.t('settings_save_failed', 'en')} — '
          'Insufficient permissions',
        ),
        findsOneWidget,
      );
      expect(find.text('0079 0000 0000 0000 00'), findsOneWidget,
          reason: 'the operator\'s typing must survive a failed save');
      expect(find.text(AppStrings.t('settings_saved', 'en')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every field label follows the active locale (ar)', //
        (tester) async {
      await pumpSettingsApp(
        tester,
        locale: AppLocale.ar,
        user: _admin,
        adapter: _fixtureAdapter(_companyFixture),
      );

      expect(
        find.text(AppStrings.t('settings_company', 'ar')),
        findsOneWidget,
      );
      for (final label in _companyFieldLabels) {
        expect(
          find.text(AppStrings.t(label, 'ar')),
          findsOneWidget,
          reason: 'missing ar label for $label',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('every field label follows the active locale (fr)', //
        (tester) async {
      await pumpSettingsApp(
        tester,
        locale: AppLocale.fr,
        user: _admin,
        adapter: _fixtureAdapter(_companyFixture),
      );

      expect(
        find.text(AppStrings.t('settings_company', 'fr')),
        findsOneWidget,
      );
      for (final label in _companyFieldLabels) {
        expect(
          find.text(AppStrings.t(label, 'fr')),
          findsOneWidget,
          reason: 'missing fr label for $label',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}

AuthUser _userWith(List<String> permissions) => AuthUser(
      id: 'u-1',
      fullName: 'Test User',
      isActive: true,
      roles: const ['cashier'],
      permissions: permissions,
    );

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: [settingsManageScope],
);

/// GET returns [json]; PUT echoes its body back (that is what the backend
/// does — it answers with the stored settings).
FakeJsonAdapter _fixtureAdapter(Map<String, Object> json) =>
    FakeJsonAdapter((options) async {
      if (options.method == 'PUT') {
        return (
          statusCode: 200,
          body: Map<String, dynamic>.from(options.data as Map),
        );
      }
      return (statusCode: 200, body: json);
    });

Future<void> _enterText(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _SettingsHarness extends ConsumerWidget {
  const _SettingsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final mode = ref.watch(themeProvider).mode;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forMode(mode),
      locale: locale.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: const Scaffold(body: SettingsScreen()),
    );
  }
}
