// UI Redesign — packs table layout contract.
//
// The packs table historically split `[4,2,1,2,2,2]` across separately
// built header/body cells: `price` got one thirteenth of the table —
// too narrow for grouped decimals — and the header used `textAlign`
// while the body used `numericText(textAlign: end)`, so under RTL the
// heading and the value hugged opposite edges. The table now shares
// one spec list (`_PackCol` + `cell()`) with the products pattern:
// per-cell padding, ambient-direction placement, `_fitEnd` shrink for
// long figures. This file pins that geometry in both directions:
// - header and body cells are identical boxes per column
// - every value sits at the ambient edge of its heading
// - the long grouped price/sum values stay inside their cells and
//   apart from their neighbours
// - below 800px the cards render, not the table
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/packs/packs_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

class MockDio extends Mock implements Dio {}

/// Stateful in-memory credential storage (same shape as the packs
/// login-flow tests; the direct harness never logs in).
class FakeCredentialStorage extends SecureCredentialStorage {
  String? _token;
  List<String> _roles = [];
  List<String> _permissions = [];

  @override
  Future<bool> hasToken() async => _token != null && _token!.isNotEmpty;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveToken(String token) async => _token = token;

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async => _roles = roles;

  @override
  Future<void> saveUserPermissions(List<String> permissions) async =>
      _permissions = permissions;

  @override
  Future<List<String>> readUserRoles() async => _roles;

  @override
  Future<List<String>> readUserPermissions() async => _permissions;

  @override
  Future<void> clearAll() async {
    _token = null;
    _roles = [];
    _permissions = [];
  }
}

const _packId = '00000000-0000-0000-0000-0000000000k1';

/// Long grouped values on purpose: the old `flex: 1` price cell could
/// not hold `15 000 000.5` without colliding with its neighbours.
Map<String, dynamic> _packJson() => {
      'id': _packId,
      'name': 'Family Holiday Mega Pack',
      'barcode': '777888999',
      'price': '15000000.5',
      'is_active': true,
      'is_archived': false,
      'archived_at': null,
      'image_path': null,
      'components_count': 3,
      'sum_of_parts': '14000000.5',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _packsListBody() => {
      'items': [_packJson()],
      'total': 1,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: status,
    );

/// Generic GET stub: the direct harness never logs in, so the list
/// provider is the only real caller — every GET answers with the packs
/// body (mirrors the login-flow test's dispatcher).
void stubPacksList(MockDio dio) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  Object? bodyFor(String path) {
    if (path == '/api/v1/auth/setup/check') return {'setup_needed': false};
    return _packsListBody();
  }

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
}

/// Real app fonts: without them every glyph is a fixed-width box and
/// the value-vs-heading edge assertions measure nothing.
Future<void> _loadAppFonts() async {
  final loader = FontLoader('IBMPlexSansArabic')
    ..addFont(rootBundle.load('assets/fonts/IBMPlexSansArabic-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/IBMPlexSansArabic-Bold.ttf'));
  await loader.load();
}

/// Direct harness (stock `pumpStockScreenDirect` pattern): overrides
/// auth/locale providers and pumps the screen alone at a chosen size
/// and direction — no login flow, no router.
Future<void> pumpPacksScreenDirect(
  WidgetTester tester,
  MockDio dio, {
  required List<String> permissions,
  Size size = const Size(1366, 768),
  Locale locale = const Locale('ar'),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final user = AuthUser(
    id: '00000000-0000-0000-0000-0000000000a1',
    fullName: 'Admin',
    isActive: true,
    roles: const ['admin'],
    permissions: permissions,
  );

  final appLocale = switch (locale.languageCode) {
    'en' => AppLocale.en,
    'fr' => AppLocale.fr,
    _ => AppLocale.ar,
  };

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(user),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(appLocale)),
      ],
      child: MaterialApp(
        locale: locale,
        theme: theme,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: PacksScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Positive = clear horizontal space between the two text boxes,
/// negative = width of the overlap.
double horizontalGap(Rect a, Rect b) =>
    math.max(b.left - a.right, a.left - b.right);

/// The table geometry contract for one locale/direction at table
/// sizes (>= 800px).
void expectPackTableContract(
  WidgetTester tester, {
  required String lang,
  required TextDirection direction,
}) {
  final header = find.byKey(const Key('packs-table-header'));
  expect(header, findsOneWidget, reason: 'table mode must pin its header');
  final row = find.byKey(const Key('pack-row-$_packId'));
  expect(row, findsOneWidget);

  // One spec list drives both rows: header and body cells are the
  // same boxes, so headings sit exactly above their values.
  for (var i = 0; i < 6; i++) {
    final headerRect =
        tester.getRect(find.byKey(Key('packs-header-col-$i')));
    final bodyRect = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byKey(Key('packs-body-col-$i')),
      ),
    );
    expect(bodyRect.width, closeTo(headerRect.width, 0.01),
        reason: 'column $i: header and body cells must be identical '
            'boxes so headings sit exactly above their values');
  }

  // (label key, value finder, ambient edge): start columns hug the
  // leading edge in both directions, the figure/chip/button columns
  // the trailing one — and heading and value must share that edge.
  final columns = <(String, Finder, bool)>[
    ('pack_name', find.text('Family Holiday Mega Pack'), true),
    ('price', find.text('15 000 000.5'), false),
    (
      'components',
      find.descendant(of: row, matching: find.text('3')),
      false,
    ),
    (
      'sum_of_parts',
      find.descendant(
        of: row,
        matching: find.byKey(Key('pack-row-sum-$_packId')),
      ),
      false,
    ),
    (
      'status',
      find.descendant(
        of: row,
        matching: find.byKey(Key('pack-status-$_packId')),
      ),
      true,
    ),
    (
      'actions',
      find.descendant(
        of: row,
        matching: find.byKey(Key('pack-archive-$_packId')),
      ),
      false,
    ),
  ];

  for (var i = 0; i < columns.length; i++) {
    final (labelKey, value, atStart) = columns[i];
    expect(value, findsOneWidget,
        reason: '$labelKey value must render in the p1 row');

    final cell = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byKey(Key('packs-body-col-$i')),
      ),
    );
    final valueRect = tester.getRect(value);
    // Inside the cell (padding included): the long grouped figures
    // shrink to fit instead of overflowing into their neighbours.
    expect(
      valueRect.left,
      greaterThanOrEqualTo(cell.left - 0.01),
      reason: '$labelKey value must stay inside its cell',
    );
    expect(
      valueRect.right,
      lessThanOrEqualTo(cell.right + 0.01),
      reason: '$labelKey value must stay inside its cell',
    );

    final headingRect = tester.getRect(
      find.descendant(
        of: find.byKey(Key('packs-header-col-$i')),
        matching: find.text(AppStrings.t(labelKey, lang)),
      ),
    );
    if (direction == TextDirection.rtl) {
      expect(
        atStart ? valueRect.right : valueRect.left,
        closeTo(atStart ? headingRect.right : headingRect.left, 0.01),
        reason: '$labelKey: under RTL heading and value must share the '
            'ambient ${atStart ? 'start (right)' : 'end (left)'} edge',
      );
    } else {
      expect(
        atStart ? valueRect.left : valueRect.right,
        closeTo(atStart ? headingRect.left : headingRect.right, 0.01),
        reason: '$labelKey: under LTR heading and value must share the '
            'ambient ${atStart ? 'start (left)' : 'end (right)'} edge',
      );
    }
  }

  // The two long figures never touch their neighbours: cells are
  // adjacent boxes and every value keeps its own cell's padding.
  final priceRect = tester.getRect(find.text('15 000 000.5'));
  final componentsRect = tester.getRect(
    find.descendant(of: row, matching: find.text('3')),
  );
  final sumRect = tester.getRect(
    find.descendant(
      of: row,
      matching: find.byKey(Key('pack-row-sum-$_packId')),
    ),
  );
  expect(
    horizontalGap(priceRect, componentsRect),
    greaterThan(0),
    reason: 'the grouped price and the component count must not collide',
  );
  expect(
    horizontalGap(componentsRect, sumRect),
    greaterThan(0),
    reason: 'the component count and the grouped sum must not collide',
  );

  expect(tester.takeException(), isNull,
      reason: 'the table must lay out without overflow');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permissions = [
    'product_view',
    'product_create',
    'product_update',
    'product_archive',
  ];

  // Table sizes (>= 800px) in both directions: the spec-list layout
  // is direction-agnostic, so the geometry contract must hold for
  // Arabic RTL and English LTR at every width.
  final tableSizes = <String, Size>{
    '1920': const Size(1920, 1080),
    '1366': const Size(1366, 768),
    '1024': const Size(1024, 768),
  };

  group('Packs table layout contract', () {
    setUpAll(_loadAppFonts);

    for (final entry in tableSizes.entries) {
      testWidgets('RTL (ar) ${entry.key}: heading/value edges, matched '
          'cells and separated figures', (tester) async {
        final dio = MockDio();
        stubPacksList(dio);
        await pumpPacksScreenDirect(
          tester,
          dio,
          permissions: permissions,
          size: entry.value,
          locale: const Locale('ar'),
          theme: AppTheme.light(),
        );

        expectPackTableContract(
          tester,
          lang: 'ar',
          direction: TextDirection.rtl,
        );
      });

      testWidgets('LTR (en) ${entry.key}: heading/value edges, matched '
          'cells and separated figures', (tester) async {
        final dio = MockDio();
        stubPacksList(dio);
        await pumpPacksScreenDirect(
          tester,
          dio,
          permissions: permissions,
          size: entry.value,
          locale: const Locale('en'),
          theme: AppTheme.light(),
        );

        expectPackTableContract(
          tester,
          lang: 'en',
          direction: TextDirection.ltr,
        );
      });
    }

    testWidgets('narrow (600) renders cards, not the table',
        (tester) async {
      final dio = MockDio();
      stubPacksList(dio);
      await pumpPacksScreenDirect(
        tester,
        dio,
        permissions: permissions,
        size: const Size(600, 900),
        locale: const Locale('ar'),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('packs-table-header')), findsNothing);
      expect(find.byKey(const Key('pack-card-$_packId')), findsOneWidget);
      expect(
        find.byKey(const Key('pack-card-name-$_packId')),
        findsOneWidget,
      );
      expect(find.text('Family Holiday Mega Pack'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
