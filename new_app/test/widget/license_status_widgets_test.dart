// Phase L1-C - trial banner + license card presentation.
//
// Pins: hidden-until-known banner behavior, the three visual states
// (active / expired / unavailable), localized labels and formatted
// values in ar (RTL) and fr/en (LTR), the banner's tap-through to
// /licensing, and overflow-free rendering at 400px and 1200px widths.
//
// Every test that mounts a license snapshot unmounts before returning:
// the live view owns a one-minute refresh timer that must not outlive
// the test.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/features/licensing/license_widgets.dart';
import 'package:supermarket_pos/main.dart'
    show appLocalizationsDelegates, appSupportedLocales;

LicenseInfo _active({DateTime? expiresAt, int trialDays = 14}) {
  final now = DateTime.now();
  return LicenseInfo(
    mode: LicenseMode.trial,
    status: LicenseStatus.active,
    trialActive: true,
    trialExpired: false,
    remainingSeconds: 2 * 24 * 3600,
    firstLaunchAt: now.subtract(const Duration(days: 12)),
    expiresAt: expiresAt ?? now.add(const Duration(days: 2)),
    observedAt: now,
    trialDays: trialDays,
  );
}

LicenseInfo _expired() => LicenseInfo(
      mode: LicenseMode.trialExpired,
      status: LicenseStatus.expired,
      trialActive: false,
      trialExpired: true,
      remainingSeconds: 0,
      firstLaunchAt: DateTime.now().subtract(const Duration(days: 30)),
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      observedAt: DateTime.now(),
      trialDays: 14,
    );

const LicenseInfo _unavailable = LicenseInfo.unknown();

Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

/// Banner inside a minimal router so its `context.go('/licensing')` tap
/// has a destination to land on.
Future<void> _pumpBanner(
  WidgetTester tester, {
  required LicenseInfo? license,
  Locale locale = const Locale('ar'),
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: TrialStatusBanner(),
        ),
      ),
      GoRoute(
        path: '/licensing',
        builder: (context, state) => const Scaffold(
          body: Text('licensing-destination', key: Key('licensing-dest')),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        licenseStatusProvider.overrideWith((ref) => license),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Card inside a plain scaffold (no navigation involved).
Future<void> _pumpCard(
  WidgetTester tester, {
  required LicenseInfo license,
  Locale locale = const Locale('ar'),
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: SingleChildScrollView(
              child: TrialStatusCard(license: license),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ui.TextDirection _directionOf(WidgetTester tester, Finder scope) =>
    Directionality.of(tester.element(scope));

void main() {
  group('TrialStatusBanner', () {
    testWidgets('renders nothing while no snapshot exists (null state)',
        (tester) async {
      await _pumpBanner(tester, license: null);
      expect(find.byKey(const Key('license-banner')), findsNothing);
      expect(find.byKey(const Key('license-banner-chip')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('active trial shows chip, remaining time and expiry (ar)',
        (tester) async {
      final license = _active();
      await _pumpBanner(tester, license: license, locale: const Locale('ar'));

      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(
        find.byKey(const Key('license-banner-chip')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('license_trial_active', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-banner-remaining')), findsOneWidget);

      final remaining =
          tester.widget<Text>(find.byKey(const Key('license-banner-remaining')))
              .data!;
      expect(remaining, contains('2'));
      expect(remaining, isNot(contains('{d}')),
          reason: 'placeholders must be substituted');

      final expires =
          tester.widget<Text>(find.byKey(const Key('license-banner-expires')))
              .data!;
      final expectedDate =
          DateFormat('yyyy-MM-dd').format(license.expiresAt!.toLocal());
      expect(expires, contains(expectedDate));
      expect(expires, isNot(contains('{date}')));
      await _unmount(tester);
    });

    testWidgets('expired trial shows the expired label and no countdown',
        (tester) async {
      await _pumpBanner(
        tester,
        license: _expired(),
        locale: const Locale('fr'),
      );

      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_trial_expired', 'fr')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-banner-remaining')), findsNothing);
      expect(find.byKey(const Key('license-banner-expires')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('unavailable state shows the unavailable label (en)',
        (tester) async {
      await _pumpBanner(
        tester,
        license: _unavailable,
        locale: const Locale('en'),
      );

      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_status_unavailable', 'en')),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('tapping the banner navigates to /licensing', (tester) async {
      await _pumpBanner(tester, license: _active());

      await tester.tap(find.byKey(const Key('license-banner')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('licensing-dest')), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Arabic renders RTL and fr/en render LTR', (tester) async {
      final banner = find.byKey(const Key('license-banner'));
      await _pumpBanner(tester, license: _active(), locale: const Locale('ar'));
      expect(_directionOf(tester, banner), ui.TextDirection.rtl);
      await _unmount(tester);

      await _pumpBanner(tester, license: _active(), locale: const Locale('fr'));
      expect(_directionOf(tester, banner), ui.TextDirection.ltr);
      await _unmount(tester);

      await _pumpBanner(tester, license: _active(), locale: const Locale('en'));
      expect(_directionOf(tester, banner), ui.TextDirection.ltr);
      await _unmount(tester);
    });
  });

  group('TrialStatusCard', () {
    testWidgets('active card: remaining, expiry, trial length, notice',
        (tester) async {
      final license = _active(trialDays: 14);
      await _pumpCard(tester, license: license, locale: const Locale('ar'));

      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_trial_active', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('license-card-remaining')), findsOneWidget);
      expect(find.byKey(const Key('license-card-expires')), findsOneWidget);
      expect(find.byKey(const Key('license-card-days')), findsOneWidget);
      expect(find.byKey(const Key('license-card-notice')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('license-card-days'))).data,
        contains('14'),
      );
      expect(find.byKey(const Key('license-card-message')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('expired card shows the expired message (fr)', (tester) async {
      final license = _expired();
      await _pumpCard(tester, license: license, locale: const Locale('fr'));

      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_trial_expired', 'fr')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('license-card-message')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('license-card-message')))
            .data,
        AppStrings.t('license_expired_message', 'fr'),
      );
      expect(find.byKey(const Key('license-card-remaining')), findsNothing);
      expect(find.byKey(const Key('license-card-notice')), findsNothing);
      await _unmount(tester);
    });

    testWidgets('unavailable card shows the unavailable message (en)',
        (tester) async {
      await _pumpCard(
        tester,
        license: _unavailable,
        locale: const Locale('en'),
      );

      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(
        find.text(AppStrings.t('license_status_unavailable', 'en')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('license-card-message')))
            .data,
        AppStrings.t('license_unavailable_message', 'en'),
      );
      await _unmount(tester);
    });

    testWidgets('an active snapshot past its local expiry reads as expired',
        (tester) async {
      final license = _active(expiresAt: DateTime.now().subtract(const Duration(hours: 1)));
      await _pumpCard(tester, license: license, locale: const Locale('en'));

      expect(
        find.text(AppStrings.t('license_trial_expired', 'en')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('license-card-message')))
            .data,
        AppStrings.t('license_expired_message', 'en'),
      );
      await _unmount(tester);
    });

    testWidgets('card renders RTL in Arabic', (tester) async {
      await _pumpCard(tester, license: _active(), locale: const Locale('ar'));
      expect(
        _directionOf(tester, find.byKey(const Key('license-card'))),
        ui.TextDirection.rtl,
      );
      await _unmount(tester);
    });
  });

  group('responsive layout', () {
    testWidgets('banner and card fit a 400px-wide window without overflow',
        (tester) async {
      const narrow = Size(400, 800);
      await _pumpBanner(
        tester,
        license: _active(),
        locale: const Locale('ar'),
        size: narrow,
      );
      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);

      await _pumpCard(
        tester,
        license: _active(),
        locale: const Locale('ar'),
        size: narrow,
      );
      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('banner and card fit a 1200px-wide window', (tester) async {
      const wide = Size(1200, 900);
      await _pumpBanner(
        tester,
        license: _active(),
        locale: const Locale('fr'),
        size: wide,
      );
      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);

      await _pumpCard(
        tester,
        license: _expired(),
        locale: const Locale('fr'),
        size: wide,
      );
      expect(find.byKey(const Key('license-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  });
}
