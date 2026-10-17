// Desktop horizontal-scrolling / narrow-window regression suite.
//
// Objective 1 of the responsive pass: horizontal rows (POS favorites
// strip, report filter/tool rows, section headers, dropdown values)
// must stay reachable and must not overflow at the widths QA asked for:
// 600x500, 900x700, 1280x800, 1920x1080 — in Arabic (RTL, default) and
// English (LTR).
//
// What this suite proves:
//  * HScrollView bridges a VERTICAL wheel delta onto the horizontal axis
//    (a plain horizontal scrollable ignores it — content past the edge
//    was unreachable with a mouse) and still accepts horizontal deltas;
//  * a scrollbar thumb appears only while there is something to scroll;
//  * every route lays out without RenderFlex overflow at the four sizes;
//  * the POS favorites strip is present, wheel-scrollable, and its last
//    chip becomes reachable;
//  * all 11 report tabs lay out clean (Sales / SlowMoving / Loyalty
//    filter rows used to overflow by up to 141px).
//
// Vertical (height) overflows are deliberately OUT of scope here and
// keep the documented exclusions in responsive_overflow_test.dart:
// /stock, /expenses and /audit-log need >= ~700px height because their
// fixed chrome (summary + filters above the list) is taller than a
// 500px window. This suite therefore reuses the same supported-screen
// list at 600x500 and does not claim those three are clean.
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/widgets/h_scroll_view.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

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

/// Every scope that gates a shell destination (all buttons rendered).
const _allScopes = [
  'pos_sale',
  'pos_return',
  'pos_credit_sale',
  'pos_discount',
  'pos_void',
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_manage',
  'inventory_view',
  'inventory_adjust',
  'customer_view',
  'customer_manage',
  'supplier_view',
  'supplier_manage',
  'purchase_view',
  'purchase_create',
  'purchase_delete',
  'promotion_view',
  'promotion_create',
  'promotion_update',
  'user_manage',
  'report_financial',
  'export_data',
  'facturation_view',
  'expense_view',
  'expense_create',
  'expense_cancel',
  'audit_view',
];

/// The four window sizes QA asked for.
const _sizes = <String, Size>{
  '600x500': Size(600, 500),
  '900x700': Size(900, 700),
  '1280x800': Size(1280, 800),
  '1920x1080': Size(1920, 1080),
};

const _routes = [
  '/',
  '/pos',
  '/returns',
  '/expenses',
  '/clients',
  '/products',
  '/packs',
  '/promotions',
  '/stock',
  '/sales',
  '/debts',
  '/suppliers',
  '/purchases',
  '/facturation',
  '/invoice-clients',
  '/reports',
  '/users',
  '/devices',
  '/audit-log',
  '/settings',
  '/about',
  '/documentation',
  '/zakat',
];

/// Same exclusions as responsive_overflow_test.dart: at 600x500 these
/// screens keep a fixed chrome taller than a 500px window (documented,
/// vertical — not what this suite changes).
const _supportedAt600 = [
  '/pos',
  '/products',
  '/clients',
  '/suppliers',
  '/promotions',
  '/invoice-clients',
  '/returns',
  '/users',
  '/debts',
  '/about',
  '/reports',
  '/',
  '/zakat',
  '/facturation',
  '/purchases',
  '/packs',
  '/sales',
  '/devices',
  '/settings',
  '/documentation',
];

const _emptyBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 25,
  'pages': 1,
};

Map<String, dynamic> _loginBody() => {
      'access_token': 'tok-admin',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'roles': [
          {
            'name': 'admin',
            'permissions': [
              for (final s in _allScopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _summaryBody() => {
      'count': 0,
      'total_amount': '0',
      'drawer_amount': '0',
      'external_amount': '0',
    };

/// 14 chips — far wider than the POS catalog column at any size, so the
/// favorites strip always has something to scroll.
List<Map<String, dynamic>> _favoritesBody() => [
      for (var i = 1; i <= 14; i++)
        {
          'id': 'fav-$i',
          'product_id': 'p$i',
          'product_name': 'Favorite product $i with a long label',
          'barcode': 'b$i',
          'price': '${i * 10}',
          'quantity': '5',
        },
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Horizontal RenderFlex overflows seen by the current test (any
  /// orientation is dumped by the onError wrapper installed in
  /// [pumpApp]; only horizontal ones are collected here).
  final horizontalOverflows = <String>[];

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  void stubRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == '/api/v1/auth/login') {
          return okResponse('/api/v1/auth/login', _loginBody());
        }
        return okResponse(path, {'message': 'ok'});
      },
    );

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/expenses/summary') {
        return okResponse(path, _summaryBody());
      }
      return okResponse(path, _emptyBody);
    });

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/auth/setup/check') {
        return okResponse(path, {'setup_needed': false});
      }
      if (path == '/api/v1/auth/login-users') {
        return okResponse(path, {
          'items': [
            {
              'id': '00000000-0000-0000-0000-0000000000a1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
            },
          ],
          'total': 1,
        });
      }
      if (path == '/api/v1/pos/favorites') {
        return okResponse(path, {'items': _favoritesBody()});
      }
      return okResponse(path, _emptyBody);
    });
  }

  /// Logs in at a comfortable size (the PIN pad does not fit 600x500),
  /// then switches to the target size — same as responsive_overflow_test.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required Size size,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AppNavRail), findsOneWidget, reason: 'login worked');

    // Dump the full RenderFlex diagnostics (creator chain, orientation)
    // while still forwarding to the test binding, and collect the
    // horizontal ones so height-only failures can be told apart.
    horizontalOverflows.clear();
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final lines = text.split('\n');
      final headline = lines
          .firstWhere((l) => l.contains('overflowed'), orElse: () => lines.first)
          .trim();
      final where = lines
          .firstWhere((l) => l.contains('file:///'), orElse: () => '')
          .trim();
      final orientation = lines
          .firstWhere((l) => l.contains('orientation of'), orElse: () => '')
          .trim();
      // ignore: avoid_print
      print('=== LAYOUT ISSUE: $headline'
          '${where.isEmpty ? '' : ' | $where'}'
          '${orientation.isEmpty ? '' : ' | $orientation'}');
      if (text.contains('Axis.horizontal')) horizontalOverflows.add(text);
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpAndSettle();

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> visit(
    WidgetTester tester,
    ProviderContainer container,
    String route,
  ) async {
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();
  }

  void expectNoOverflow(WidgetTester tester) {
    expect(
      tester.takeException(),
      isNull,
      reason: 'no RenderFlex overflow allowed (got the exception above)',
    );
  }

  /// Clears whatever layout exception was recorded and fails only on a
  /// HORIZONTAL one.
  ///
  /// Used at 600x500, where a tall fixed chrome (reports filter card,
  /// stock/expenses/audit summary + filters) can still leave too little
  /// height for the pane below it. Those vertical overflows are the
  /// documented, out-of-scope limitation of this task; the horizontal
  /// behaviour this suite changes must be clean everywhere.
  void expectNoHorizontalOverflow(WidgetTester tester) {
    var guard = 0;
    while (tester.takeException() != null && guard++ < 20) {
      // Drain: the binding reports the next pending exception only after
      // the previous one was taken.
    }
    expect(
      horizontalOverflows,
      isEmpty,
      reason: 'no horizontal overflow allowed (details above)',
    );
  }

  /// A pure vertical wheel delta (no dx) — the case a stock horizontal
  /// scrollable silently drops.
  Future<void> verticalWheel(
    WidgetTester tester,
    Finder target, {
    double dy = 200,
  }) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(target),
        scrollDelta: Offset(0, dy),
      ),
    );
    await tester.pump();
  }

  // ---------------------------------------------------------------------
  // HScrollView: wheel bridging, thumb, RTL, reachability.
  // ---------------------------------------------------------------------

  Widget wrapStrip(Widget child, {TextDirection dir = TextDirection.ltr}) {
    return MaterialApp(
      home: Directionality(
        textDirection: dir,
        child: Scaffold(
          body: Center(
            child: SizedBox(width: 320, height: 140, child: child),
          ),
        ),
      ),
    );
  }

  Widget wideStrip({int count = 8}) {
    return HScrollView(
      key: const Key('hsv'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            SizedBox(
              width: 140,
              child: Text('hsv-item-$i', key: Key('hsv-item-$i')),
            ),
          ],
        ],
      ),
    );
  }

  ScrollPosition stripPosition(WidgetTester tester) {
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('hsv')),
        matching: find.byType(Scrollable),
      ),
    );
    return scrollable.position;
  }

  group('HScrollView wheel bridging', () {
    testWidgets('vertical wheel scrolls a horizontal strip (LTR)',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapStrip(wideStrip()));
      await tester.pumpAndSettle();

      expect(stripPosition(tester).maxScrollExtent, greaterThan(0),
          reason: 'strip is wider than its 320px viewport');

      await verticalWheel(tester, find.byKey(const Key('hsv')));
      expect(stripPosition(tester).pixels, greaterThan(0),
          reason: 'a vertical wheel delta must scroll a horizontal row');
      expect(tester.takeException(), isNull);
    });

    testWidgets('vertical wheel scrolls an Arabic (RTL) strip',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrapStrip(wideStrip(), dir: TextDirection.rtl),
      );
      await tester.pumpAndSettle();

      await verticalWheel(tester, find.byKey(const Key('hsv')));
      expect(stripPosition(tester).pixels, greaterThan(0),
          reason: 'RTL uses the same vertical-to-horizontal bridge');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a horizontal delta still scrolls natively', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapStrip(wideStrip()));
      await tester.pumpAndSettle();

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(const Key('hsv'))),
          scrollDelta: const Offset(120, 0),
        ),
      );
      await tester.pump();
      expect(stripPosition(tester).pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated wheel events reach the very last item',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapStrip(wideStrip()));
      await tester.pumpAndSettle();

      final lastKey = find.byKey(const Key('hsv-item-7'));
      final stripRect = tester.getRect(find.byKey(const Key('hsv')));
      expect(
        tester.getRect(lastKey).right > stripRect.right + 1,
        isTrue,
        reason: 'last item starts off the right edge',
      );

      for (var i = 0; i < 10; i++) {
        await verticalWheel(tester, find.byKey(const Key('hsv')), dy: 300);
      }
      await tester.pumpAndSettle();

      expect(stripPosition(tester).pixels,
          moreOrLessEquals(stripPosition(tester).maxScrollExtent, epsilon: 1));
      final lastRect = tester.getRect(lastKey);
      expect(lastRect.right <= stripRect.right + 1, isTrue,
          reason: 'last item must become reachable by wheel alone');
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a thumb only while the content overflows',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapStrip(wideStrip(count: 8)));
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsOneWidget,
          reason: 'overflowing content advertises a thumb');
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(
        wrapStrip(
          wideStrip(count: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsNothing,
          reason: 'content that fits looks exactly as it did before');
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // App: no horizontal RenderFlex overflow at the four requested sizes.
  // ---------------------------------------------------------------------

  for (final entry in _sizes.entries) {
    if (entry.key == '600x500') continue;

    testWidgets('every route lays out without overflow at ${entry.key}',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpApp(tester, dio, size: entry.value);

      for (final route in _routes) {
        await visit(tester, container, route);
        expectNoOverflow(tester);
      }
    });

    testWidgets('all report tabs lay out without overflow at ${entry.key}',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpApp(tester, dio, size: entry.value);
      await visit(tester, container, '/reports');

      final tabBar = tester.widget<TabBar>(
        find.byKey(const Key('reports-tabbar')),
      );
      final controller = tabBar.controller!;
      for (var i = 0; i < controller.length; i++) {
        controller.animateTo(i);
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
      }
    });
  }

  testWidgets('600x500: supported routes lay out without overflow',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: _sizes['600x500']!);

    for (final route in _supportedAt600) {
      await visit(tester, container, route);
      expectNoOverflow(tester);
    }
  });

  testWidgets('600x500: every report tab has no horizontal overflow',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: _sizes['600x500']!);
    await visit(tester, container, '/reports');

    final tabBar = tester.widget<TabBar>(
      find.byKey(const Key('reports-tabbar')),
    );
    final controller = tabBar.controller!;
    for (var i = 0; i < controller.length; i++) {
      controller.animateTo(i);
      await tester.pumpAndSettle();
      expectNoHorizontalOverflow(tester);
    }
  });

  testWidgets('English (LTR) lays out without overflow at 600x500',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: _sizes['600x500']!);
    container.read(localeProvider.notifier).setLocale(AppLocale.en);
    await tester.pumpAndSettle();

    for (final route in const [
      '/',
      '/facturation',
      '/zakat',
      '/reports',
      '/products',
      '/pos',
    ]) {
      await visit(tester, container, route);
      expectNoOverflow(tester);
    }

    await visit(tester, container, '/reports');
    final tabBar = tester.widget<TabBar>(
      find.byKey(const Key('reports-tabbar')),
    );
    final controller = tabBar.controller!;
    for (var i = 0; i < controller.length; i++) {
      controller.animateTo(i);
      await tester.pumpAndSettle();
      expectNoHorizontalOverflow(tester);
    }
  });

  // ---------------------------------------------------------------------
  // POS favorites strip: present, wheel-scrollable, last chip reachable.
  // ---------------------------------------------------------------------

  testWidgets('POS favorites strip scrolls with a vertical wheel',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    // wide layout (>= 1100) is what renders the favorites row.
    final container = await pumpApp(tester, dio, size: _sizes['1280x800']!);
    await visit(tester, container, '/pos');

    final strip = find.byKey(const Key('pos-favorites-row'));
    expect(strip, findsOneWidget, reason: 'favorites row rendered');
    expectNoOverflow(tester);

    final lastChip = find.byKey(const Key('pos-favorite-p14'));
    expect(lastChip, findsOneWidget, reason: 'all favorites rendered');

    final inner = find.descendant(
      of: strip,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(inner.first).position;
    expect(position.maxScrollExtent, greaterThan(100),
        reason: 'long strip really overflows the catalog column');

    final stripRect = tester.getRect(strip);
    final chipBefore = tester.getRect(lastChip);
    expect(
      chipBefore.left >= stripRect.left &&
          chipBefore.right <= stripRect.right,
      isFalse,
      reason:
          'last favorite starts outside the strip (strip=$stripRect chip=$chipBefore)',
    );

    // Pure vertical wheel deltas must be enough to reach the very end —
    // no trackpad swipe, no shift-wheel.
    var guard = 0;
    while (position.pixels < position.maxScrollExtent - 0.5 && guard++ < 40) {
      await verticalWheel(tester, strip, dy: 400);
    }
    await tester.pumpAndSettle();

    final after = tester.state<ScrollableState>(inner.first).position;
    expect(
      after.pixels,
      moreOrLessEquals(after.maxScrollExtent, epsilon: 1),
      reason: 'vertical wheel reached the end of the strip',
    );

    final chipAfter = tester.getRect(lastChip);
    expect(
      chipAfter.left >= stripRect.left - 1 &&
          chipAfter.right <= stripRect.right + 1,
      isTrue,
      reason:
          'last favorite must come into view (strip=$stripRect chip=$chipAfter)',
    );
    expectNoOverflow(tester);
  });

  testWidgets('POS favorites strip scrolls in English (LTR) too',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: _sizes['1280x800']!);
    container.read(localeProvider.notifier).setLocale(AppLocale.en);
    await tester.pumpAndSettle();
    await visit(tester, container, '/pos');

    final strip = find.byKey(const Key('pos-favorites-row'));
    expect(strip, findsOneWidget);
    await verticalWheel(tester, strip, dy: 300);
    expect(tester.takeException(), isNull);
  });
}
