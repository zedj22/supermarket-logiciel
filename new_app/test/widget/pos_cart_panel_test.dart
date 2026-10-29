// Cart-panel regression suite (customer-attached clipping fixes):
//  1. geometry  — the checkout tail must never clip the last cart line;
//     arrow reveal ALONE (no manual settle) keeps every row fully inside
//     the lines viewport, return-mode chrome included;
//  2. arrow nav — Up/Down walk the selection with NO prior row click and
//     NO cart click after a catalog/barcode add (the post-add quantity
//     focus must not swallow them), reveal the active row each step,
//     enter at the ends from the unselected state, survive
//     remove/clear/re-add, coexist with the +/Delete shortcuts, and only
//     freeze while a text query is actually being typed;
//  3. colors    — accent actions paint SUBTLE tint washes with onTint AA
//     labels and hue borders, Return stays the one solid red chip (white
//     AA), neutral holds, PAY rides the theme's primary.
//
// Harness distilled from the temporary pos_clip_diagnostic_test.dart
// geometry probe (deleted once this suite passed).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_providers.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_qty_shortcuts.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  String? _token;

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
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => ['cashier'];

  @override
  Future<List<String>> readUserPermissions() async => [];

  @override
  Future<void> clearAll() async => _token = null;
}

class _FakePdfPreview implements PdfPreviewBuilder {
  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  }) =>
      const Text('pdf');
}

/// [PosCartNotifier] with ONE test-only hook: clear only the active-line
/// selection. The production API never yields "lines but no selection"
/// (addLine preselects the newest line, removeLine hands the selection to
/// the newest remaining one) — but arrow navigation must handle it
/// defensively: Down enters at the first line, Up at the last.
class _SeededCart extends PosCartNotifier {
  _SeededCart(super.dio, super.localeCode, super.deviceId);

  void clearActiveForTest() =>
      state = state.copyWith(clearLastActiveKey: true);
}

const _customerId = 'cust-1';

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

/// Balance with ONE redeemable reward → the loyalty entry point unlocks
/// (the gate mirrors the server: available_rewards > 0 or a matching
/// eligible preview). [eligible] false serves the disabled-path contract:
/// zero rewards and a preview that denies redemption on this cart.
Map<String, Object> _balanceJson({bool eligible = true}) => <String, Object>{
      'customer_id': _customerId,
      'has_account': true,
      'points_balance': '130.000',
      'cashback_balance': '25.000',
      'available_rewards': eligible ? 1 : 0,
      'remaining_points': '30.000',
      'min_reward_points': 100,
    };

/// One sellable catalog item (shape of the real `/api/v1/products` item —
/// enough for `_addProduct` to go straight down its no-variant path).
Map<String, Object?> _catalogProduct(String id, String name) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'barcode': 'bc-$id',
      'unit': 'piece',
      'price': '10.0',
      'cost': '5',
      'avg_cost': '5',
      'quantity': '20',
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'category_id': null,
      'category_name': null,
      'image_path': null,
      'is_archived': false,
    };

void _mockPosDio(MockDio dio, {bool loyaltyEligible = true}) {
  Object? getBody(String path) {
    if (path.startsWith('/api/v1/customers/') && path.endsWith('/loyalty')) {
      return _balanceJson(eligible: loyaltyEligible);
    }
    if (path == '/api/v1/products') {
      // Catalog for the add-to-cart arrow tests: two fresh products plus
      // one that already sits in the seeded cart (its tap MERGES into the
      // existing line — the "increase an existing line" path).
      return <String, Object>{
        'items': <Object>[
          _catalogProduct('prod-a', 'Fresh Bread'),
          _catalogProduct('prod-b', 'Milk Pack'),
          _catalogProduct('p0', 'Product 0 (catalog)'),
        ],
        'total': 3,
      };
    }
    if (path == '/api/v1/auth/setup/check') {
      return <String, Object>{'setup_needed': false};
    }
    if (path == '/api/v1/auth/login-users') {
      return <String, Object>{
        'items': <Object>[
          <String, Object>{
            'id': 'u-1',
            'full_name': 'Cashier',
            'is_active': true,
          },
        ],
      };
    }
    if (path == '/api/v1/settings') {
      return <String, Object>{'items': <Object>[]};
    }
    return <String, Object>{'items': <Object>[], 'total': 0};
  }

  Object? postBody(String path, Object? data) {
    if (path.endsWith('/loyalty/preview')) {
      return _previewJson(data, loyaltyEligible: loyaltyEligible);
    }
    return <String, dynamic>{};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, getBody(path));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, getBody(path));
  });

  when(() => dio.post(any(), data: any(named: 'data')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, postBody(path, invocation.namedArguments[#data]));
  });

  when(() => dio.post(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
      )).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, postBody(path, invocation.namedArguments[#data]));
  });

  when(() => dio.post(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, postBody(path, null));
  });

  when(() => dio.delete(any())).thenAnswer((invocation) async =>
        Response<dynamic>(
          requestOptions: RequestOptions(
            path: invocation.positionalArguments.first as String? ?? '',
          ),
          statusCode: 204,
        ));
}

/// Server-shaped /api/v1/loyalty/preview answer: gross × percent, the
/// owner cap (20) and the eligibility flags — ONE builder shared by the
/// standard mock and the per-test preview scripts below (the dialog
/// dismissal regressions re-stub this endpoint, never re-derive its math).
Map<String, Object> _previewJson(
  Object? data, {
  required bool loyaltyEligible,
}) {
  final map = Map<String, dynamic>.from(data! as Map);
  final gross = double.parse('${map['gross_total']}');
  final percent = ((map['reward_percent'] as num?) ?? 0).toDouble();
  final discount = gross * percent / 100;
  return <String, Object>{
    'customer_id': map['customer_id'],
    'gross_total': map['gross_total'],
    'reward_percent': percent,
    'reward_discount': discount.toStringAsFixed(3),
    'amount_due': (gross - discount).toStringAsFixed(3),
    'available_rewards': loyaltyEligible ? 1 : 0,
    'remaining_points': '30.000',
    'min_reward_points': 100,
    'max_reward_discount_percent': '20.000',
    'points_balance': '130.000',
    'cashback_balance': '25.000',
    'points_earned': '0.960',
    'cashback_earned': '0.500',
    'points_after_sale': '130.960',
    'reward_eligible': loyaltyEligible,
  };
}

/// Re-registers the standard mock's `POST(any, data: …)` stub so
/// `/loyalty/preview` answers through [preview] — 1-based index of the
/// preview POSTs made AFTER this call; the callback may THROW a
/// DioException (failed validation) or await a Future (hold the write open)
/// — while every other POST keeps the mock's default empty answer.
/// mocktail resolves the NEWEST matching stub, so the standard
/// [_mockPosDio] answers stay in force for everything else.
void _restubPreviewPost(
  MockDio dio, {
  required FutureOr<Object?> Function(int call, Map<String, dynamic> data)
      preview,
}) {
  var calls = 0;
  when(() => dio.post(any(), data: any(named: 'data')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path.endsWith('/loyalty/preview')) {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data]! as Map,
      );
      return _ok(path, await preview(++calls, data));
    }
    return _ok(path, <String, dynamic>{});
  });
}

Future<ProviderContainer> _pumpPos(
  WidgetTester tester, {
  required MockDio dio,
  Size size = const Size(1366, 768),
  int lines = 12,
  // Unit price of the seeded lines — the loyalty money regressions price
  // exact DA figures (a 4,000 cart × 10% = 400 off).
  String unitPrice = '10',
  // The permission-gated return action adds a THIRD actions row (~54px)
  // that shrinks the lines viewport — grant it only where its color is
  // asserted, so the geometry scenarios measure the default chrome.
  bool grantReturn = false,
  // Short-viewport compaction scenarios (additive): reversed layout,
  // OS text scaling and the drawer form of the narrow window.
  bool reversed = false,
  double textScale = 1.0,
  bool openDrawer = false,
  // Arabic/RTL pump for the sidebar loyalty card (bidi contract W7).
  bool rtl = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (reversed) kPosLayoutSwitchKey: 'reversed',
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
  }

  final cart = _SeededCart(dio, () => 'en', () async => 'pos-test');
  for (var i = 0; i < lines; i++) {
    cart.addLine(CartLine(
      productId: 'p$i',
      name: 'Product $i',
      quantity: '1',
      unitPrice: unitPrice,
    ));
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(AuthUser(
          id: 'u-1',
          fullName: 'Cashier',
          isActive: true,
          roles: const ['cashier'],
          permissions: grantReturn ? const ['pos_return'] : const [],
        )),
        localeProvider.overrideWith((ref) => LocaleNotifier()
          ..setLocale(rtl ? AppLocale.ar : AppLocale.en)),
        pdfPreviewProvider.overrideWithValue(_FakePdfPreview()),
        posCartProvider.overrideWith((ref) => cart),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: Locale(rtl ? 'ar' : 'en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: const Scaffold(body: PosScreen()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
  if (openDrawer) {
    await tester.tap(find.byKey(const Key('toggle-cart')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
  }
  return ProviderScope.containerOf(
    tester.element(find.byKey(const Key('pos-screen'))),
    listen: false,
  );
}

/// Attaches the customer AFTER the screen is up — the real user flow
/// (ref.listen → setCustomerById → balance + preview → loyalty block).
Future<void> _attachCustomer(
  WidgetTester tester,
  ProviderContainer container,
) async {
  container.read(posCartProvider.notifier).setCustomer(const PosCustomer(
        id: _customerId,
        name: 'Loyal Customer With A Long Name',
        phone: '0555 12 34 56',
      ));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Taps a catalog product card and flushes the add flow: the merged/new
/// line lands in the provider and becomes the active line. NO cart-line
/// quantity field is auto-focused (Phase 8 FIX #1 retired) — focus stays
/// off the cart fields until the cashier clicks one — which is the exact
/// state the real cashier is in when the NEXT arrow press must already
/// navigate.
Future<void> _tapCatalogProduct(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('pos-product-$id')));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

final RegExp _tileRe = RegExp(r'^cart-line-p\d+\|\|$');

Finder _tiles() => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          _tileRe.hasMatch((w.key! as ValueKey<String>).value),
    );

Finder _lines() => find.byKey(const Key('pos-cart-lines'));

/// Force the lazy ListView onto its CURRENT maxScrollExtent: child layout
/// corrects the extent estimate every round (possibly DOWNWARD, leaving
/// pixels past max), so jump → pump → repeat until it sticks.
Future<void> _settleScrollToEnd(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: _lines().first,
    matching: find.byType(Scrollable),
  );
  expect(scrollable.evaluate(), isNotEmpty,
      reason: 'pos-cart-lines must host a Scrollable');
  final state = tester.state<ScrollableState>(scrollable.first);
  for (var i = 0; i < 12; i++) {
    final max = state.position.maxScrollExtent;
    if ((state.position.pixels - max).abs() <= 0.5) break;
    state.position.jumpTo(max);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// One key activation + the reveal it can trigger.
///
/// Frames: the key callback rebuilds the selection and (post-frame) the
/// reveal runs as an INSTANT jump (`ensureVisible` with `Duration.zero` —
/// an animated glide would make the scrollable drop every pointer until it
/// settles); the extra frames flush that post-frame callback and its paint.
Future<void> _sendArrow(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Value key of the focused text field, if the focus sits on one — the
/// focus assertions of the dialog dismissal regressions (an Escape that
/// leaked to the POS handler would move/clear the search field's state).
String? focusedFieldKey(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final field = context.widget is TextField
      ? context.widget as TextField
      : context.findAncestorWidgetOfExactType<TextField>();
  final key = field?.key;
  return key is ValueKey<String> ? key.value : null;
}

void main() {
  late MockDio dio;

  setUp(() {
    dio = MockDio();
    _mockPosDio(dio);
  });

  group('customer-attached cart geometry', () {
    testWidgets(
        '1366x768 + customer: the last line scrolls fully clear of the actions',
        (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 10);
      await _attachCustomer(tester, container);
      await _settleScrollToEnd(tester);

      final viewport = tester.getRect(_lines().first);
      final last = tester.getRect(_tiles().last);
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      expect(viewport.height, greaterThan(0));
      expect(last.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'last line must not hide above the viewport');
      expect(last.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'last line must not be clipped by the actions row');
      expect(last.bottom, lessThanOrEqualTo(actions.top + 0.5));
      // Not just the card frame: the row CONTENTS (name + quantity field)
      // must ride inside the viewport with the customer block attached.
      final lastKey = container.read(posCartProvider).lines.last.key;
      for (final part in [
        find.byKey(Key('cart-line-name-$lastKey')),
        find.byKey(Key('cart-line-qty-$lastKey')),
      ]) {
        final rect = tester.getRect(part);
        expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5),
            reason: 'row contents must not hide above the viewport');
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
            reason: 'row contents must not be clipped by the actions row');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '1024x600 + customer: a full line still fits and the last line reveals',
        (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        size: const Size(1024, 600),
        lines: 10,
      );
      await _attachCustomer(tester, container);
      await _settleScrollToEnd(tester);

      final viewport = tester.getRect(_lines().first);
      // A standard cart tile measures ~170px; the viewport must keep
      // room for at least one full row with the loyalty block attached.
      expect(viewport.height, greaterThanOrEqualTo(165));
      final last = tester.getRect(_tiles().last);
      expect(last.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(last.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '600x500 drawer + customer: no overflow; totals stay inside the panel',
        (tester) async {
      final container =
          await _pumpPos(tester, dio: dio, size: const Size(600, 500), lines: 6);
      await tester.tap(find.byKey(const Key('toggle-cart')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      await _attachCustomer(tester, container);
      expect(tester.takeException(), isNull,
          reason: 'the customer block must not overflow the narrow drawer');

      final panel = tester.getRect(find.byKey(const Key('pos-cart-panel')));
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      final totals = tester.getRect(find.byKey(const Key('pos-totals-panel')));
      expect(totals.bottom, lessThanOrEqualTo(panel.bottom + 0.5));
      expect(actions.bottom, lessThanOrEqualTo(totals.bottom + 0.5));
      expect(tester.getRect(_lines().first).height, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'arrow reveal ALONE pulls every row fully into view — no manual '
        'scroll settle anywhere', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 10);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      // Fresh page: the list sits at the TOP while addLine preselects the
      // LAST line — nothing has scrolled yet and nothing will settle it by
      // hand; only the arrow-driven reveal may move the scroll.
      expect(container.read(posCartProvider).lastActiveKey, keys.last);
      final scroller = find.descendant(
          of: _lines().first, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scroller.first).position;
      expect(position.pixels, 0);

      // First press steps OFF the un-built preselected row: the state lays
      // the target's region out (estimate), the tile claims the reveal
      // request on mount and brings itself fully into view.
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[8]);
      var viewport = tester.getRect(_lines().first);
      var tile = tester.getRect(find.byKey(Key('cart-line-${keys[8]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'step into the un-built region must still reveal the row');
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));

      // Walk back onto the LAST row — still reveal-only, still settled.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, keys.last);
      viewport = tester.getRect(_lines().first);
      tile = tester.getRect(find.byKey(Key('cart-line-${keys.last}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      expect(tile.bottom, lessThanOrEqualTo(actions.top + 0.5),
          reason: 'the last row must sit clear of the actions area');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'return mode + customer: the banner chrome keeps the last line and '
        'the totals panel clear of the actions', (tester) async {
      final container =
          await _pumpPos(tester, dio: dio, lines: 10, grantReturn: true);
      // Worst case stack: return banner (+80px budget) AND the customer /
      // loyalty block above the lines.
      container.read(posCartProvider.notifier).setReturnMode(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 300));
      await _attachCustomer(tester, container);
      await _settleScrollToEnd(tester);

      final viewport = tester.getRect(_lines().first);
      expect(viewport.height, greaterThan(0),
          reason: 'return + customer chrome must not swallow the lines');
      final last = tester.getRect(_tiles().last);
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      expect(last.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(last.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      expect(last.bottom, lessThanOrEqualTo(actions.top + 0.5));
      final panel = tester.getRect(find.byKey(const Key('pos-cart-panel')));
      final totals = tester.getRect(find.byKey(const Key('pos-totals-panel')));
      expect(totals.bottom, lessThanOrEqualTo(panel.bottom + 0.5),
          reason: 'the return totals must stay inside the panel');
      expect(tester.takeException(), isNull);
    });
  });

  group('short-viewport compaction — with customer + loyalty attached the '
      'last cart row always stays fully visible', () {
    /// Chrome-compaction probe distilled into permanent regressions: on
    /// short windows the fixed tail (actions + totals/PAY) must shed
    /// levels until the lines region keeps at least ONE full row — the
    /// tail never obscures or clips the last visible row, and the money
    /// keys stay inside the panel while the loyalty chrome lives only
    /// inside the redemption dialog (closed during normal use).
    Future<void> expectLastRowClear(
      WidgetTester tester, {
      required Size size,
      int lines = 10,
      bool reversed = false,
      double textScale = 1.0,
      bool openDrawer = false,
    }) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        size: size,
        lines: lines,
        reversed: reversed,
        textScale: textScale,
        openDrawer: openDrawer,
      );
      await _attachCustomer(tester, container);
      await _settleScrollToEnd(tester);

      final viewport = tester.getRect(_lines().first);
      final lastKey = container.read(posCartProvider).lines.last.key;
      final last = tester.getRect(find.byKey(Key('cart-line-$lastKey')));
      expect(viewport.height, greaterThanOrEqualTo(last.height - 0.75),
          reason: 'the lines region must fit at least one full cart row');
      expect(last.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'the last row must not hide above the viewport');
      expect(last.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'the last row must not be clipped by the loyalty/totals tail');

      final panel = tester.getRect(find.byKey(const Key('pos-cart-panel')));
      final totals = tester.getRect(find.byKey(const Key('pos-totals-panel')));
      expect(totals.bottom, lessThanOrEqualTo(panel.bottom + 0.5),
          reason: 'the totals panel stays inside the cart panel');
      bool inside(Rect outer, Rect inner) =>
          inner.left >= outer.left - 0.5 &&
          inner.right <= outer.right + 0.5 &&
          inner.top >= outer.top - 0.5 &&
          inner.bottom <= outer.bottom + 0.5;
      // The customer-facing keys survive every compaction level: the
      // money keys stay inside the totals/PAY panel. The loyalty chrome
      // (identity/balance/options/error) lives ONLY inside the loyalty
      // discount dialog — closed during normal use, so it renders
      // nowhere else: not in the cart panel, not in the totals card,
      // not in the drawer, at ANY compaction level.
      for (final key in [
        'pos-pay-button',
        'pos-subtotal-value',
        'pos-discount-value',
        'pos-total-label',
        'pos-total-value',
      ]) {
        final finder = find.byKey(Key(key));
        expect(finder, findsOneWidget, reason: '$key must stay rendered');
        expect(inside(totals, tester.getRect(finder)),
            isTrue,
            reason: '$key must sit inside the totals/PAY panel');
      }
      for (final key in [
        'pos-loyalty-label',
        'pos-loyalty-balance',
        'pos-loyalty-reward-input',
        'pos-loyalty-error',
      ]) {
        expect(find.byKey(Key(key)), findsNothing,
            reason: '$key renders only inside the (closed) dialog');
      }
      expect(tester.takeException(), isNull);
    }

    testWidgets('900x560: compaction yields a full row (was 153 < 166)',
        (tester) async {
      await expectLastRowClear(tester, size: const Size(900, 560));
    });

    testWidgets('800x540: compaction yields a full row (was 139 < 165)',
        (tester) async {
      await expectLastRowClear(tester, size: const Size(800, 540));
    });

    testWidgets('960x520: compaction yields a full row (was 119 < 165)',
        (tester) async {
      await expectLastRowClear(tester, size: const Size(960, 520));
    });

    testWidgets(
        '600x500 drawer (standard): compaction yields a full row '
        '(was 39 < 165)', (tester) async {
      await expectLastRowClear(
        tester,
        size: const Size(600, 500),
        openDrawer: true,
      );
    });

    testWidgets(
        '600x500 drawer (reversed): compaction yields a full dense row '
        '(was 58 < 62)', (tester) async {
      await expectLastRowClear(
        tester,
        size: const Size(600, 500),
        reversed: true,
        openDrawer: true,
      );
    });

    testWidgets('1024x600 at text scale 1.3: full row, no render overflow',
        (tester) async {
      await expectLastRowClear(
        tester,
        size: const Size(1024, 600),
        textScale: 1.3,
      );
    });

    testWidgets(
        '1280x720 reversed at text scale 1.3: full row, no render overflow',
        (tester) async {
      await expectLastRowClear(
        tester,
        size: const Size(1280, 720),
        reversed: true,
        textScale: 1.3,
      );
    });

    testWidgets(
        'compaction is presentation-only: money + loyalty values and PAY '
        'are byte-identical to the providers (900x560)', (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        size: const Size(900, 560),
        lines: 6,
      );
      await _attachCustomer(tester, container);
      await _settleScrollToEnd(tester);

      final model = container.read(posCartProvider);
      String textOf(String key) => tester
          .widget<Text>(find.byKey(Key(key)))
          .data ??
          '';
      expect(textOf('pos-subtotal-value'), model.totals.subtotalDisplay);
      expect(textOf('pos-discount-value'),
          '-${model.totals.invoiceDiscountDisplay}');
      expect(textOf('pos-total-value'), contains(model.totals.totalDisplay));
      // Loyalty money: the only write path the dialog's Confirm uses
      // (single-slot setRewardPercent + authoritative preview) drives the
      // footer's amount-due — the byte-for-byte provider mirror.
      final notifier = container.read(posLoyaltyProvider.notifier);
      notifier.setRewardPercent(5);
      await notifier.previewNow();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.previewMatches, isTrue,
          reason: 'the session preview answers 5% on this cart');
      final dueText = textOf('pos-loyalty-amount-due');
      expect(
        dueText,
        contains(PaymentMath.money(PaymentMath.amountDueOf(
          total: model.totals.total,
          rewardDiscount: loyalty.preview!.rewardDiscount,
        ))),
        reason: 'the footer amount-due shows the provider-mirrored due',
      );
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('pos-pay-button'))),
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('arrow-key line navigation', () {
    testWidgets(
        'Up/Down walk the selection across the whole cart, revealing the '
        'active row each step (customer attached)', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 8);
      await _attachCustomer(tester, container);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(keys, hasLength(8));
      // addLine preselects the newest line (pos_providers.dart) — the walk
      // starts there, at the bottom of a scrolled-to-END list.
      expect(container.read(posCartProvider).lastActiveKey, keys.last);
      await _settleScrollToEnd(tester);

      Finder row(int i) => find.byKey(Key('cart-line-${keys[i]}'));

      // Walk UP one press per line: each step re-selects and the reveal
      // keeps the active row fully inside the lines viewport.
      for (var i = keys.length - 2; i >= 0; i--) {
        await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
        expect(container.read(posCartProvider).lastActiveKey, keys[i],
            reason: 'Up press must land on line $i');
        final viewport = tester.getRect(_lines().first);
        final tile = tester.getRect(row(i));
        expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
            reason: 'line $i must be revealed below the fold top');
        expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
            reason: 'line $i must be revealed above the fold bottom');
      }

      // Clamps at the first line, still revealed.
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys.first);
      var viewport = tester.getRect(_lines().first);
      var tile = tester.getRect(row(0));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));

      // Walk back DOWN to the end, revealing every step.
      for (var i = 1; i < keys.length; i++) {
        await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
        expect(container.read(posCartProvider).lastActiveKey, keys[i],
            reason: 'Down press must land on line $i');
        viewport = tester.getRect(_lines().first);
        tile = tester.getRect(row(i));
        expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
            reason: 'line $i must be revealed below the fold top');
        expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
            reason: 'line $i must be revealed above the fold bottom');
      }

      // Clamps at the last line, which also sits clear of the actions row.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, keys.last);
      viewport = tester.getRect(_lines().first);
      tile = tester.getRect(row(keys.length - 1));
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      expect(tile.bottom, lessThanOrEqualTo(actions.top + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a typed query freezes the walk; a focused quantity field still '
        'navigates AND still edits (caret assert stays out)', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 4);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      // addLine preselects the newest line.
      expect(container.read(posCartProvider).lastActiveKey, keys.last);

      // Idle barcode field: arrows navigate (Up leaves the newest line).
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[2]);
      expect(tester.takeException(), isNull, reason: 'after idle Up');

      // Typed query freezes the selection MID-cart: a claimed Up or Down
      // would visibly walk it off keys[2].
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bread');
      await tester.pump();
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(tester.takeException(), isNull, reason: 'after bread Up');
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(tester.takeException(), isNull, reason: 'after bread Down');
      expect(container.read(posCartProvider).lastActiveKey, keys[2],
          reason: 'a typed query keeps its arrow keys');

      // Idle again: arrows navigate (proof the guard really was the only
      // thing holding them back).
      await tester.enterText(find.byKey(const Key('pos-search-field')), '');
      await tester.pump();
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(tester.takeException(), isNull, reason: 'after cleared Up');
      expect(container.read(posCartProvider).lastActiveKey, keys[1]);

      // Quantity field of a selected line — reached ONLY by an explicit
      // click (adds never auto-focus a qty field): Up/Down must walk the
      // selection from here without a cart click, focus must never be
      // stolen from the field, and the key must never reach Flutter's
      // single-line vertical-caret action (which asserts on this centered
      // field — the claim+swallow guard).
      await tester.ensureVisible(find.byKey(Key('cart-line-qty-${keys[1]}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('cart-line-qty-${keys[1]}')));
      await tester.pump();
      expect(focusedPosTextFieldKey(), 'cart-line-qty-${keys[1]}',
          reason: 'the qty field must really hold focus for this segment');

      // The field keeps editing normally: typed digits still land.
      await tester.enterText(find.byKey(Key('cart-line-qty-${keys[1]}')), '7');
      await tester.pump();
      final edited = container
          .read(posCartProvider)
          .lines
          .firstWhere((line) => line.key == keys[1]);
      expect(edited.quantity, '7', reason: 'typing still writes the qty');
      expect(focusedPosTextFieldKey(), 'cart-line-qty-${keys[1]}');

      // Arrows walk the SELECTION while the field keeps both its focus
      // and its text — and no vertical-caret assertion ever fires.
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[0],
          reason: 'a focused quantity field no longer blocks the walk');
      expect(focusedPosTextFieldKey(), 'cart-line-qty-${keys[1]}',
          reason: 'arrows must not steal focus from the qty field');
      expect(tester.takeException(), isNull, reason: 'after qty Up');
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, keys[1]);
      expect(focusedPosTextFieldKey(), 'cart-line-qty-${keys[1]}');
      expect(tester.takeException(), isNull, reason: 'after qty Down');
      final still = container
          .read(posCartProvider)
          .lines
          .firstWhere((line) => line.key == keys[1]);
      expect(still.quantity, '7', reason: 'the typed qty survives the walk');
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty cart: Up/Down are a no-op', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 0);
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'catalog tap arms the arrows INSTANTLY — no cart click between the '
        'add and the first Up/Down', (tester) async {
      // One short line: the appended row lands INSIDE the list's cache
      // window (a two-line seed already pushes it past visible+cache), so
      // its tile is built right away — the exact built-tile state a short
      // cart hits in the real cashier flow.
      final container = await _pumpPos(tester, dio: dio, lines: 1);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(container.read(posCartProvider).lastActiveKey, keys.last);

      // THE regression path: tap a catalog card, touch NOTHING in the
      // cart afterwards. The add preselects the new line — and (Phase 8
      // FIX #1 retired) must NOT auto-focus any quantity field. The next
      // arrow press must already navigate from that exact state.
      await _tapCatalogProduct(tester, 'prod-a');
      final after = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(after, hasLength(2), reason: 'the tap must add a line');
      expect(container.read(posCartProvider).lastActiveKey, after.last,
          reason: 'the freshly added line becomes the active one');
      expect(find.byKey(Key('cart-line-${after.last}')), findsOneWidget,
          reason: 'the new tile must be built');
      expect(focusedPosTextFieldKey(), isNot('cart-line-qty-${after.last}'),
          reason: 'the add must never auto-focus the new qty field');

      // First press (Up) walks OFF the new line without any cart click…
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, after[0],
          reason: 'Up right after a catalog tap must move the selection');
      final viewport = tester.getRect(_lines().first);
      final tile = tester.getRect(find.byKey(Key('cart-line-${after[0]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'the moved-to line must be revealed');
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      // …focus never jumped into any cart qty field, and no caret
      // assertion fired.
      expect(focusedPosTextFieldKey(), isNot('cart-line-qty-${after.last}'));

      // …and Down walks straight back — still without a cart click.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, after.last);
      expect(focusedPosTextFieldKey(), isNot('cart-line-qty-${after.last}'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a SECOND distinct catalog tap keeps the arrows ready — two adds, '
        'zero cart clicks', (tester) async {
      // One short line: both appended tiles mount inside the cache window
      // (the built-tile state).
      final container = await _pumpPos(tester, dio: dio, lines: 1);

      await _tapCatalogProduct(tester, 'prod-a');
      await _tapCatalogProduct(tester, 'prod-b');
      final after = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(after, hasLength(3), reason: 'two distinct adds, two lines');
      expect(container.read(posCartProvider).lastActiveKey, after[2],
          reason: 'the second add preselects ITS line');
      expect(focusedPosTextFieldKey(), isNot('cart-line-qty-${after[2]}'),
          reason: 'neither add may auto-focus a quantity field');

      // Up lands on the FIRST added line…
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, after[1],
          reason: 'Up from the second add must reach the first add');
      // …and Down returns to the second — one press each, no clicks.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, after[2]);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'tapping an existing product INCREASES it and the arrows answer on '
        'the very next press', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 4);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];

      // Catalog product 'p0' already sits in the cart as keys[0]: the tap
      // merges (quantity 1 → 2) and moves the active line to that key.
      await _tapCatalogProduct(tester, 'p0');
      final cart = container.read(posCartProvider);
      expect(cart.lines, hasLength(4), reason: 'a merge adds no new line');
      final merged =
          cart.lines.firstWhere((line) => line.key == keys[0]);
      expect(merged.quantity, '2', reason: 'the tap must increase the line');
      expect(cart.lastActiveKey, keys[0],
          reason: 'the merged line becomes the active one');
      expect(focusedPosTextFieldKey(), isNot('cart-line-qty-${keys[0]}'),
          reason: 'an increase-merge must never auto-focus a qty field');

      // Down (Up would clamp at the first line) walks immediately.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, keys[1],
          reason: 'arrows must answer right after an increase-merge');
      final viewport = tester.getRect(_lines().first);
      final tile = tester.getRect(find.byKey(Key('cart-line-${keys[1]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[0]);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'no prior row click: arrows walk the cart from a fresh page and '
        'reveal each moved-to row', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 10);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      // NOTHING is tapped anywhere: focus stays wherever the screen parked
      // it (barcode field idle / page workspace) and the walk must work
      // regardless — this is the "arrows only after clicking a row" bug.
      expect(container.read(posCartProvider).lastActiveKey, keys.last);

      for (var i = keys.length - 2; i >= keys.length - 4; i--) {
        await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
        expect(container.read(posCartProvider).lastActiveKey, keys[i],
            reason: 'Up press without any prior tap must land on line $i');
        final viewport = tester.getRect(_lines().first);
        final tile = tester.getRect(find.byKey(Key('cart-line-${keys[i]}')));
        expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
            reason: 'line $i must be revealed without a row click first');
        expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      }

      // And back down a step — still without a single click.
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey,
          keys[keys.length - 3]);
      final viewport = tester.getRect(_lines().first);
      final tile =
          tester.getRect(find.byKey(Key('cart-line-${keys[keys.length - 3]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'no selection yet: Down enters at the first line, Up at the last '
        '(never a crash, never a silent no-op)', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 6);
      final cart = container.read(posCartProvider.notifier) as _SeededCart;
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];

      // Down enters at the FIRST line (list is already at the top).
      cart.clearActiveForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(posCartProvider).lastActiveKey, isNull);
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lastActiveKey, keys.first);
      var viewport = tester.getRect(_lines().first);
      var tile = tester.getRect(find.byKey(Key('cart-line-${keys.first}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'Down must enter at a revealed first line');
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));

      // From unselected again, Up enters at the LAST line — the entering
      // jump lays out the list end so the tile can reveal itself.
      cart.clearActiveForTest();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(posCartProvider).lastActiveKey, isNull);
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys.last);
      viewport = tester.getRect(_lines().first);
      tile = tester.getRect(find.byKey(Key('cart-line-${keys.last}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'Up must enter at a revealed last line');
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      final actions = tester.getRect(find.byKey(const Key('pos-cart-actions')));
      expect(tile.bottom, lessThanOrEqualTo(actions.top + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'selection stays valid through remove / clear / re-add — arrows '
        'keep walking afterwards', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 5);
      final notifier = container.read(posCartProvider.notifier);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];

      // Remove the ACTIVE (last) line → the newest remaining line takes
      // over; arrows start walking from THERE, never a stale key.
      notifier.removeLine(keys.last);
      await tester.pump();
      expect(container.read(posCartProvider).lastActiveKey, keys[3]);
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[2]);
      var viewport = tester.getRect(_lines().first);
      var tile = tester.getRect(find.byKey(Key('cart-line-${keys[2]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));

      // Cleared cart: arrows are quiet no-ops (no crash, no selection).
      notifier.clearCart();
      await tester.pump();
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      await _sendArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(container.read(posCartProvider).lines, isEmpty);
      expect(container.read(posCartProvider).lastActiveKey, isNull);

      // Re-add two lines → the newest preselects; arrows walk from there
      // and the revealed row ends up inside the viewport.
      notifier.addLine(CartLine(
        productId: 'pX',
        name: 'Product X',
        quantity: '1',
        unitPrice: '10',
      ));
      notifier.addLine(CartLine(
        productId: 'pY',
        name: 'Product Y',
        quantity: '1',
        unitPrice: '10',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final after = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(after, hasLength(2));
      expect(container.read(posCartProvider).lastActiveKey, after.last);
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, after.first);
      viewport = tester.getRect(_lines().first);
      tile = tester.getRect(find.byKey(Key('cart-line-${after.first}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'arrows coexist with the existing shortcuts: +/Delete keep operating '
        'on the line the arrow walk just selected', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 5);
      final keys = [
        for (final line in container.read(posCartProvider).lines) line.key
      ];
      expect(container.read(posCartProvider).lastActiveKey, keys.last);

      // Arrow walk picks the line…
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[3]);

      // …+ adds to ITS quantity…
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final bumped = container
          .read(posCartProvider)
          .lines
          .firstWhere((line) => line.key == keys[3]);
      expect(bumped.quantity, '2',
          reason: '+ must target the line arrows just selected');

      // …and Delete removes exactly that line, with the selection falling
      // back to the newest remaining one — arrows continue from THERE.
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(posCartProvider).lines, hasLength(4));
      expect(container.read(posCartProvider).lastActiveKey, keys[4],
          reason: 'the newest remaining line inherits the selection');
      await _sendArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(container.read(posCartProvider).lastActiveKey, keys[2]);
      expect(tester.takeException(), isNull);
    });
  });

  group('totals panel layout', () {
    testWidgets(
        'Total label sits immediately above the amount, both right-aligned '
        'to the money edge, amount 44–48 and dominant', (tester) async {
      await _pumpPos(tester, dio: dio, lines: 2);

      final labelRect =
          tester.getRect(find.byKey(const Key('pos-total-label')));
      final valueRect =
          tester.getRect(find.byKey(const Key('pos-total-value')));
      final labelText = tester
          .widget<Text>(find.byKey(const Key('pos-total-label')));
      final valueText = tester
          .widget<Text>(find.byKey(const Key('pos-total-value')));

      // §4/§6: stacked — label IMMEDIATELY above the amount…
      expect(valueRect.top, greaterThanOrEqualTo(labelRect.bottom - 0.5));
      expect(valueRect.top - labelRect.bottom, lessThanOrEqualTo(8),
          reason: 'no spread between the label and its amount');
      // …both flush to the same money edge…
      expect((labelRect.right - valueRect.right).abs(), lessThanOrEqualTo(3),
          reason: 'label and amount share the right money edge');
      // …the figure dominates at 44–48px bold, above the label size.
      expect(valueText.style!.fontSize!, inInclusiveRange(44, 48));
      expect(valueText.style!.fontWeight, FontWeight.w800);
      expect(labelText.style!.fontSize!, inInclusiveRange(18, 20));
      expect(valueText.style!.fontSize!, greaterThan(labelText.style!.fontSize!));
      expect(tester.takeException(), isNull);
    });
  });

  // The loyalty discount is CART-level (percent off the totals) — never a
  // per-line price. The presentation contract: a GENUINE (preview-matched)
  // discount strikes the original total through and demotes it, while the
  // effective price below goes green, bold and LARGER. Suppressed/stale
  // previews render the plain primary total with no strike anywhere, and
  // every value/key stays byte-identical to the providers throughout.
  group('loyalty discount price presentation', () {
    testWidgets(
        'before redemption: the total stays plain primary with no strike '
        'and no effective-price row', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      final total =
          tester.widget<Text>(find.byKey(const Key('pos-total-value')));
      expect(total.style!.decoration, TextDecoration.none,
          reason: 'no discount yet → no strikethrough');
      expect(total.style!.fontWeight, FontWeight.w800);
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing,
          reason: 'the effective-price row exists only with a discount');
      expect(container.read(posLoyaltyProvider).rewardDiscount, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'genuine 5% preview: the original total strikes through, the '
        'effective price is green and larger, totals stay byte-identical',
        (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      String textOf(String key) =>
          tester.widget<Text>(find.byKey(Key(key))).data ?? '';
      final model = container.read(posCartProvider);
      final notifier = container.read(posLoyaltyProvider.notifier);
      notifier.setRewardPercent(5);
      await notifier.previewNow();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.previewMatches, isTrue,
          reason: 'the session preview answers 5% on this cart');

      // The original: struck through the middle, demoted, still the FULL
      // figure — display only, no recomputed money.
      final original =
          tester.widget<Text>(find.byKey(const Key('pos-total-value')));
      expect(original.style!.decoration, TextDecoration.lineThrough);
      expect(original.data, contains(model.totals.totalDisplay),
          reason: 'the original price stays on screen with the strike');

      // The effective price: the provider-mirrored due in money-green,
      // w800, and larger than the struck original above it.
      final due = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')));
      expect(
        due.data,
        PaymentMath.money(PaymentMath.amountDueOf(
          total: model.totals.total,
          rewardDiscount: loyalty.preview!.rewardDiscount,
        )),
        reason: 'the footer renders the provider-mirrored due',
      );
      expect(due.style!.color, AppColors.success);
      expect(due.style!.fontWeight, FontWeight.w800);
      expect(
        due.style!.fontSize!,
        greaterThan(original.style!.fontSize!),
        reason: 'the discounted price dominates the struck original',
      );

      // Totals unchanged: every money row is the provider value.
      expect(textOf('pos-subtotal-value'), model.totals.subtotalDisplay);
      expect(textOf('pos-discount-value'),
          '-${model.totals.invoiceDiscountDisplay}');
      expect(textOf('pos-total-value'), contains(model.totals.totalDisplay));
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a suppressed preview (out-of-cap percent) drops the strike and '
        'the effective row together — no green, no lineThrough', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      final notifier = container.read(posLoyaltyProvider.notifier);

      notifier.setRewardPercent(5);
      await notifier.previewNow();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(posLoyaltyProvider).previewMatches, isTrue);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .style!
            .decoration,
        TextDecoration.lineThrough,
        reason: 'the genuine discount is live → strike shows',
      );

      // 25% is beyond the server cap — only reachable through a direct
      // session write; the suppressed preview may drive no money, so the
      // original un-strikes the moment the preview stops matching.
      notifier.setRewardPercent(25);
      await tester.pump(const Duration(milliseconds: 50));
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.previewMatches, isFalse);
      final total =
          tester.widget<Text>(find.byKey(const Key('pos-total-value')));
      expect(total.style!.decoration, TextDecoration.none,
          reason: 'a suppressed preview never strikes the total');
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing);

      // Drain the session's own scheduled revalidation so no timer
      // outlives the test.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Arabic/RTL: the struck original and the larger green effective '
        'price keep their bidi-isolated money (no reordering, no overflow)',
        (tester) async {
      final container =
          await _pumpPos(tester, dio: dio, lines: 3, rtl: true);
      await _attachCustomer(tester, container);
      final model = container.read(posCartProvider);
      final notifier = container.read(posLoyaltyProvider.notifier);
      notifier.setRewardPercent(5);
      await notifier.previewNow();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(posLoyaltyProvider).previewMatches, isTrue);

      // Both money figures stay LTR paragraphs inside the RTL layout
      // (numericText's bidi contract W7) — digits never reorder.
      final original =
          tester.widget<Text>(find.byKey(const Key('pos-total-value')));
      expect(original.textDirection, TextDirection.ltr);
      expect(original.style!.decoration, TextDecoration.lineThrough);
      expect(original.data, contains(model.totals.totalDisplay));

      final due = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')));
      expect(due.textDirection, TextDirection.ltr);
      expect(due.style!.color, AppColors.success);
      expect(
        due.style!.fontSize!,
        greaterThan(original.style!.fontSize!),
        reason: 'RTL keeps the discounted price dominant too',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // The loyalty entry point: ONE compact button in the cart action row
  // (server-owned eligibility) plus the redemption dialog that owns the
  // percent selector. The workspace catalog stays clean, the totals panel
  // keeps only Subtotal/Discount/TOTAL/(amount-due)/PAY, and NOTHING is
  // written to the loyalty session until the dialog's Confirm.
  group('loyalty discount button + redemption dialog', () {
    Finder loyaltyButton() =>
        find.byKey(const Key('pos-loyalty-discount-button'));

    testWidgets(
        'no customer: the button sits in the cart action row but stays '
        'disabled — no loyalty chrome renders anywhere', (tester) async {
      await _pumpPos(tester, dio: dio, lines: 2);

      expect(loyaltyButton(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-cart-panel')),
          matching: loyaltyButton(),
        ),
        findsOneWidget,
        reason: 'redemption lives in the CART action row, not the workspace',
      );
      expect(
        tester.widget<OutlinedButton>(loyaltyButton()).onPressed,
        isNull,
        reason: 'nothing to redeem without a customer',
      );
      for (final key in [
        'pos-loyalty-label',
        'pos-loyalty-balance',
        'pos-loyalty-reward-input',
        'pos-loyalty-amount-due',
        'pos-loyalty-dialog',
      ]) {
        expect(find.byKey(Key(key)), findsNothing,
            reason: 'no loyalty chrome without a customer: $key');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ineligible customer (0 rewards, preview denies): the button '
        'mirrors the server answer and stays disabled', (tester) async {
      dio = MockDio();
      _mockPosDio(dio, loyaltyEligible: false);
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.hasCustomer, isTrue);
      expect(loyalty.canSelectReward, isFalse,
          reason: 'the gate mirrors the SERVER answer');
      expect(tester.widget<OutlinedButton>(loyaltyButton()).onPressed, isNull);
      await tester.tap(loyaltyButton());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing,
          reason: 'a disabled entry never opens the dialog');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'eligible customer: the button opens the dialog with the customer '
        'identity, balance and the server-capped free-entry field', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      expect(
        tester.widget<OutlinedButton>(loyaltyButton()).onPressed,
        isNotNull,
      );
      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-customer')))
            .data,
        'Loyal Customer With A Long Name',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-loyalty-balance'))).data ??
            '',
        isNotEmpty,
      );
      final input = find.byKey(const Key('pos-loyalty-reward-input'));
      expect(input, findsOneWidget,
          reason: 'the dropdown is replaced by a free-entry percent field');
      expect(
        tester.widget<TextField>(input).controller!.text,
        '',
        reason: 'a fresh dialog starts on None (empty field)',
      );
      // The owner cap (20) is shown as the field helper — any valid value
      // up to it may be typed (12, 17, 18.5 …), never above it.
      expect(find.text('Max: 20%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'cancel or barrier-dismiss changes NOTHING — browsing a percent '
        'never mutates the session, the sale or PAY', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      String snap() {
        final l = container.read(posLoyaltyProvider);
        final c = container.read(posCartProvider);
        return 'l:${l.customerId}|${l.rewardPercent}|'
            '${l.preview?.rewardPercent}|${l.preview?.grossTotal}|'
            '${l.exceeds}|${l.loading}|${l.error}|'
            'c:${c.lines.length}|${c.totals.total}|${c.customer?.id}';
      }

      final before = snap();
      final payBefore =
          tester.getRect(find.byKey(const Key('pos-pay-button')));

      // Browse 5%: the dialog fetches its preview LOCALLY — the session
      // must not move a single field before any Confirm.
      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(snap(), before,
          reason: 'browsing a percent must not mutate any provider');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        isNotEmpty,
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(snap(), before);
      expect(tester.getRect(find.byKey(const Key('pos-pay-button'))),
          payBefore,
          reason: 'PAY never moves or reacts');
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing,
          reason: 'no discount was applied to the sale');

      // The SAME contract for a barrier dismissal (the default dialog
      // escape hatch — still zero writes without a Confirm).
      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      expect(snap(), before);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(snap(), before);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'selecting 5% shows the SERVER numbers; confirm commits once and '
        'the footer mirrors the same figure', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      final payBefore =
          tester.getRect(find.byKey(const Key('pos-pay-button')));
      // 3 lines × 1 × 10 → gross 30 → 5% = 1.50 discount, due 28.50.

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();

      final discountText = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-discount')))
          .data!;
      final dueText = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
          .data!;
      expect(discountText, contains(PaymentMath.money(1.5)),
          reason: 'the server-issued discount for 5% of 30');
      expect(dueText, contains(PaymentMath.money(28.5)),
          reason: 'the server-issued due for 5% of 30');
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
        reason: 'server numbers known → confirmable',
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);

      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 5.0);
      expect(loyalty.previewMatches, isTrue);
      expect(loyalty.preview!.rewardDiscount, closeTo(1.5, 0.001));
      final footerDue = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')))
          .data!;
      expect(footerDue, PaymentMath.money(28.5),
          reason: 'the footer renders the provider-mirrored due');
      expect(dueText, contains(footerDue),
          reason: 'dialog and footer show ONE server truth');
      expect(tester.getRect(find.byKey(const Key('pos-pay-button'))),
          payBefore,
          reason: 'PAY never reacts to redemption');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'arbitrary percents are accepted: 12%, 17% and 18.5% each price '
        'through the server preview and commit exactly', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      // 3 lines × 1 × 10 → gross 30 → the mock prices percent% of 30.

      for (final entry in [
        ('12', 3.6),
        ('17', 5.1),
        ('18.5', 5.55),
      ]) {
        await tester.tap(loyaltyButton());
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('pos-loyalty-reward-input')),
          entry.$1,
        );
        await tester.pumpAndSettle();

        final discountText = tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-discount')))
            .data!;
        expect(discountText, contains(PaymentMath.money(entry.$2)),
            reason: 'the server-issued discount for ${entry.$1}% of 30');
        expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const Key('pos-loyalty-dialog-confirm')))
              .onPressed,
          isNotNull,
          reason: 'a non-step percent within the cap is confirmable',
        );

        await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
        await tester.pumpAndSettle();

        final loyalty = container.read(posLoyaltyProvider);
        expect(loyalty.rewardPercent, double.parse(entry.$1));
        expect(loyalty.preview!.rewardDiscount, closeTo(entry.$2, 0.001));
        expect(loyalty.exceeds, isFalse);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the cap is enforced on free entry: 25% (cap 20) shows the exceeds '
        'error, disables Confirm and never mutates the session', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '25',
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('pos-loyalty-reward-error'))).data,
        AppStrings.t('loyalty_redeem_exceeds', 'en'),
        reason: 'an over-cap percent is REJECTED, never clamped to 20',
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNull,
        reason: 'a rejected percent can never be confirmed',
      );
      // 25% of the 30 cart would be 7.50 — it must never be priced
      // anywhere: the preview row still answers the last VALID choice.
      final shownDiscount = tester
              .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-discount')))
              .data ??
          '';
      expect(shownDiscount, isNot(contains('7.50')),
          reason: 'the rejected percent never reaches the server preview');

      // Fixing the field re-enables the flow — the rejection is live,
      // not sticky.
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '20',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-reward-error')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();

      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0,
          reason: 'nothing was ever committed from the rejected session');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'unparseable input shows the invalid-amount error and never '
        'reaches the session', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '12.5.5',
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('pos-loyalty-reward-error'))).data,
        AppStrings.t('invalid_amount', 'en'),
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the clear button empties the field back to None (no reward)',
        (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('pos-loyalty-reward-input')))
            .controller!
            .text,
        '10',
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-reward-clear')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('pos-loyalty-reward-input')))
            .controller!
            .text,
        '',
      );
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the cap is server-owned: an out-of-cap session write flags the '
        'state and the footer hides every previewed penny', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      final notifier = container.read(posLoyaltyProvider.notifier);

      // 25% is beyond the server's 20% cap — only reachable through a
      // direct session write (the dialog's options never offer it).
      notifier.setRewardPercent(25);
      await tester.pump(const Duration(milliseconds: 50));
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.exceeds, isTrue,
          reason: 'an out-of-cap percent flags exceeds immediately');
      expect(loyalty.previewMatches, isFalse,
          reason: 'the suppressed preview may drive no money');
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing);

      // Drain the session's own scheduled revalidation (it re-asks the
      // server; the server stays the final judge) so no timer outlives
      // the test.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'cart changes under the dialog: the due row refetches for the NEW '
        'total (no stale money)', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 2);
      await _attachCustomer(tester, container);
      // 2 lines × 10 → gross 20 → 5% → due 19.00.

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(19.0)),
      );

      // The cart moves under the modal (programmatic edit): 3 lines × 10
      // → gross 30 → due 28.50 — the dialog must refetch, never go stale.
      container.read(posCartProvider.notifier).addLine(CartLine(
            productId: 'p-under-dialog',
            name: 'Added Under Dialog',
            quantity: '1',
            unitPrice: '10',
          ));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(28.5)),
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
        reason: 'the refetched preview re-enables confirm',
      );
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'detaching the customer resets the session and disables the '
        'redemption button', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);
      expect(
        tester.widget<OutlinedButton>(loyaltyButton()).onPressed,
        isNotNull,
      );

      container.read(posCartProvider.notifier).setCustomer(null);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.hasCustomer, isFalse);
      expect(loyalty.rewardPercent, 0.0);
      expect(tester.widget<OutlinedButton>(loyaltyButton()).onPressed, isNull);
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('redemption never stacks: a second confirm keeps ONE 5% '
        'discount', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      // First redemption: type 5% into the free-entry field and Confirm.
      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      final first = container.read(posLoyaltyProvider);
      expect(first.rewardPercent, 5.0);
      final firstDiscount = first.preview!.rewardDiscount;

      // Second Confirm on the SAME selection (the dialog reopens with the
      // session's 5% already prefilled — no typing): the slot REPLACES,
      // never accumulates.
      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('pos-loyalty-reward-input')))
            .controller!
            .text,
        '5',
        reason: 'the dialog reopens with the committed percent prefilled',
      );
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      final second = container.read(posLoyaltyProvider);
      expect(second.rewardPercent, 5.0,
          reason: 'a second confirm never doubles the discount');
      expect(second.preview!.rewardPercent, 5.0);
      expect(second.preview!.rewardDiscount, firstDiscount);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'return mode withholds the whole action row: the banner owns the '
        'cart, redemption included', (tester) async {
      final container =
          await _pumpPos(tester, dio: dio, lines: 3, grantReturn: true);
      await _attachCustomer(tester, container);
      expect(loyaltyButton(), findsOneWidget);
      expect(find.byKey(const Key('pos-return-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-return-button')), findsNothing);
      expect(loyaltyButton(), findsNothing,
          reason: 'a return earns nothing — no redemption entry');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Arabic/RTL: the dialog renders identity, balance and options in '
        'RTL without layout exceptions', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3, rtl: true);
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(
          find.byKey(const Key('pos-loyalty-dialog-customer')), findsOneWidget);
      expect(find.byKey(const Key('pos-loyalty-balance')), findsOneWidget);
      expect(find.byKey(const Key('pos-loyalty-reward-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'short viewport at text scale 1.3: the open dialog never overflows',
        (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        size: const Size(1024, 600),
        lines: 3,
        textScale: 1.3,
      );
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the dialog must ellipsize, never overflow, at 1.3x');
    });

    testWidgets(
        'Escape closes the dialog with ZERO writes and never leaks into the '
        'POS Escape handler (search text survives)', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      String snap() {
        final l = container.read(posLoyaltyProvider);
        final c = container.read(posCartProvider);
        return 'l:${l.customerId}|${l.rewardPercent}|'
            '${l.preview?.rewardPercent}|${l.preview?.grossTotal}|'
            '${l.exceeds}|${l.loading}|${l.error}|'
            'c:${c.lines.length}|${c.totals.total}|${c.customer?.id}';
      }

      // Text in the search box BEFORE the dialog opens: the POS Escape
      // handler would clear it — so the surviving text proves the dialog
      // route (not the page binding) owned the key.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bread',
      );
      await tester.pump();
      final before = snap();

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(snap(), before, reason: 'browsing a percent mutates nothing');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing,
          reason: 'Escape is the normal dismiss while no confirm is running');
      expect(snap(), before,
          reason: 'Escape applies nothing — no percent, no preview, no cart');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pos-search-field')))
            .controller!
            .text,
        'bread',
        reason: 'the POS Escape handler never ran — its CallbackShortcuts '
            'scope is not in the dialog route key chain',
      );
      expect(focusedFieldKey(tester), 'pos-search-field',
          reason: 'focus returns to the field the dialog was opened from');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a FAILED confirm never closes as success: the slot rolls back, the '
        'error shows, and a retry still works', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      // Local dialog previews succeed; the SESSION revalidation for the
      // typed 5% (its 2nd percent-5 call) fails; the rollback restore
      // (percent 0) and the later retry both succeed.
      var fiveCalls = 0;
      _restubPreviewPost(
        dio,
        preview: (call, data) {
          final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
          if (percent == 5 && ++fiveCalls == 2) {
            throw DioException(
              requestOptions: RequestOptions(
                path: '/api/v1/loyalty/preview',
              ),
              message: 'validation unavailable',
            );
          }
          return _previewJson(data, loyaltyEligible: true);
        },
      );

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(fiveCalls, 1, reason: 'one LOCAL preview prices the typing');
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget,
          reason: 'a failed validation must never present a close as success');
      expect(
        find.byKey(const Key('pos-loyalty-dialog-confirm-error')),
        findsOneWidget,
        reason: 'the failure is surfaced inside the still-open dialog',
      );
      final failed = container.read(posLoyaltyProvider);
      expect(failed.rewardPercent, 0.0,
          reason: 'the failed attempt was rolled back — nothing applied');
      expect(failed.error, isNull,
          reason: 'the rollback revalidated the session for the old value');
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
        reason: 'the restore succeeded → the cashier can retry immediately',
      );

      // Retry: the server answers again → the ONE write lands and closes.
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(container.read(posLoyaltyProvider).rewardPercent, 5.0);
      expect(fiveCalls, 3, reason: 'local + failed session + retried session');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'double-tapping Confirm in one frame applies the write EXACTLY once',
        (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      // Hold the session write open so BOTH taps land while the first
      // submit is still in flight — the realistic same-frame duplicate
      // (without the gate the success path pops the dialog between the
      // two taps and the second press would find no button at all).
      final gate = Completer<void>();
      var fiveCalls = 0;
      _restubPreviewPost(
        dio,
        preview: (call, data) async {
          final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
          if (percent == 5 && ++fiveCalls == 2) {
            await gate.future;
          }
          return _previewJson(data, loyaltyEligible: true);
        },
      );

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(fiveCalls, 1, reason: 'the local pricing preview');

      // Two taps with NO frame between them: the first enters _confirm
      // (sets _busy synchronously, before its first await) and parks on
      // the gated write; the second reaches the same still-built button
      // and must find _busy set — a plain no-op, never a second write.
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      expect(fiveCalls, 2,
          reason: 'the duplicate press was rejected by the synchronous '
              '_busy guard — still one local + one session write');

      gate.complete();
      await tester.pumpAndSettle();

      expect(fiveCalls, 2,
          reason: 'after the write lands there is still no second submit');
      expect(container.read(posLoyaltyProvider).rewardPercent, 5.0,
          reason: 'the discount applied once, never doubled');
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Escape and the barrier cannot dismiss the dialog while the confirm '
        'write is in flight — it closes only when the write lands', (
      tester,
    ) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      final gate = Completer<void>();
      var fiveCalls = 0;
      _restubPreviewPost(
        dio,
        preview: (call, data) async {
          final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
          if (percent == 5 && ++fiveCalls == 2) {
            await gate.future; // hold the SESSION write open
          }
          return _previewJson(data, loyaltyEligible: true);
        },
      );

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pump(); // rebuilds PopScope with canPop: false
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget,
          reason: 'Escape is vetoed mid-write (a close must never precede '
              'the success)');

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget,
          reason: 'the barrier is vetoed mid-write too');

      // The write lands → the SUCCESS path is the one that closes it.
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(container.read(posLoyaltyProvider).rewardPercent, 5.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'exact money regression: a 4,000.00 DA cart + 10% — Confirm applies '
        'the 400 DA discount ONCE, closes, and the panel shows 3,600.00 DA '
        'due', (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );
      await _attachCustomer(tester, container);
      expect(container.read(posCartProvider).totals.total, 4000.0);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-discount')))
            .data,
        contains(PaymentMath.money(400)),
        reason: 'the server prices 10% of 4,000 → 400 DA off',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(3600)),
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('pos-loyalty-dialog-confirm')))
            .onPressed,
        isNotNull,
        reason: 'a server-accepted percent on a healthy session is '
            'confirmable — the click can never land on a dead button',
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing,
          reason: 'a successful confirm closes exactly once');
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 10.0);
      expect(loyalty.previewMatches, isTrue);
      expect(loyalty.preview!.rewardDiscount, closeTo(400, 0.001));
      expect(
        PaymentMath.amountDueOf(
          total: 4000,
          rewardDiscount: loyalty.preview!.rewardDiscount,
        ),
        closeTo(3600, 0.001),
        reason: 'what PAY charges = total − the ONE server discount',
      );
      final footer = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')))
          .data!;
      expect(footer, PaymentMath.money(3600),
          reason: 'the totals panel mirrors the same 3,600.00 due');
      final cart = container.read(posCartProvider);
      expect(cart.totals.total, 4000.0,
          reason: 'the cart total is untouched — the discount rides the '
              'loyalty preview, never a second discount field');
      expect(cart.invoiceDiscount, '0',
          reason: 'loyalty and invoice discounts never stack');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'session mirror desynced from the live cart: the dialog prices its '
        'rows from the LIVE cart, Confirm reconciles the session, applies '
        'the 400 DA discount ONCE and closes — a correct preview can never '
        'fail to apply', (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );
      await _attachCustomer(tester, container);

      // The reported production failure: the loyalty session's cart
      // mirror (state.cartTotal — the ONLY base the confirm-time write
      // reads) is empty while the live cart holds the 4,000 DA invoice.
      // The dialog's OWN preview never depended on the mirror (it prices
      // against cart.totals.total), so the rows show the right numbers —
      // but pre-reconcile the session write silently no-ops on the empty
      // mirror, the success gate rolls the slot back, and the dialog
      // stays open with the total unchanged.
      container.read(posLoyaltyProvider.notifier).setCartTotal(0);
      await tester.pumpAndSettle();
      final desynced = container.read(posLoyaltyProvider);
      expect(desynced.cartTotal, 0,
          reason: 'the session mirror no longer answers the live cart');
      expect(desynced.previewMatches, isFalse);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-discount')))
            .data,
        contains(PaymentMath.money(400)),
        reason: 'the dialog priced 10% of the LIVE 4,000 from its OWN '
            'server answer — the mirror never fed these rows',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(3600)),
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing,
          reason: 'the reconciled write landed → success closes');
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 10.0);
      expect(loyalty.previewMatches, isTrue);
      expect(loyalty.cartTotal, 4000.0,
          reason: 'Confirm healed the mirror from the live cart');
      expect(loyalty.preview!.grossTotal, closeTo(4000, 0.001),
          reason: 'the applied discount was priced on the SAME base the '
              'preview rows displayed');
      expect(loyalty.preview!.rewardDiscount, closeTo(400, 0.001),
          reason: 'exactly ONE 400 DA discount — never doubled, never lost');
      final footer = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')))
          .data!;
      expect(footer, PaymentMath.money(3600));
      final cart = container.read(posCartProvider);
      expect(cart.totals.total, 4000.0,
          reason: 'the cart lines and invoice total stay untouched');
      expect(cart.invoiceDiscount, '0');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'session mirror stale at a DIFFERENT total: Confirm reconciles to '
        'the live 4,000 cart so the applied discount and the footer answer '
        '3,600 — never the stale base', (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );
      await _attachCustomer(tester, container);

      // The dual desync: a NON-EMPTY but stale mirror. Pre-reconcile the
      // session posted gross 3,500 at Confirm, the self-consistent
      // preview "matched" the stale mirror, the dialog closed — and the
      // footer/PAY charged 4,000 − 350 = 3,650 for a preview that showed
      // 400/3,600. Preview and application must share ONE base.
      container.read(posLoyaltyProvider.notifier).setCartTotal(3500);
      await tester.pumpAndSettle();
      expect(container.read(posLoyaltyProvider).cartTotal, 3500);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(3600)),
        reason: 'the rows price off the LIVE cart, as the cashier sees it',
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 10.0);
      expect(loyalty.previewMatches, isTrue);
      expect(loyalty.cartTotal, 4000.0);
      expect(loyalty.preview!.grossTotal, closeTo(4000, 0.001));
      expect(loyalty.preview!.rewardDiscount, closeTo(400, 0.001),
          reason: '10% of the LIVE 4,000 — the stale 3,500 base is gone');
      final footer = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')))
          .data!;
      expect(footer, PaymentMath.money(3600),
          reason: 'the totals panel mirrors the reconciled 3,600.00 due');
      expect(container.read(posCartProvider).totals.total, 4000.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a late session-preview FAILURE after the dialog opened must not '
        'silently kill Confirm — the retry revalidates and the 10% lands',
        (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );

      // The attach-time session preview (call 1) lands LAST and FAILS —
      // the realistic transient blip: the balance answered, the dialog is
      // openable, and only the background preview poisons the session
      // (error set, preview cleared) while the dialog's OWN local fetches
      // (calls 2–3) still succeed and price the rows.
      final sessionGate = Completer<void>();
      _restubPreviewPost(
        dio,
        preview: (call, data) async {
          if (call == 1) {
            await sessionGate.future;
            throw DioException(
              requestOptions: RequestOptions(path: '/api/v1/loyalty/preview'),
              message: 'transient backend blip',
            );
          }
          return _previewJson(data, loyaltyEligible: true);
        },
      );
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(3600)),
        reason: 'the dialog priced 400/3,600 from its OWN server answer',
      );

      // Now the held session preview fails: the session carries an error
      // and no preview — while the open dialog still shows good rows.
      sessionGate.complete();
      await tester.pumpAndSettle();
      final poisoned = container.read(posLoyaltyProvider);
      expect(poisoned.error, isNotNull,
          reason: 'the late failure poisoned the SESSION state');
      expect(poisoned.previewMatches, isFalse);

      // ROOT CONTRACT: that background state must never turn the click
      // into a silent no-op. Confirm stays actionable; the awaited
      // revalidation either lands (heals the session, closes, applies)
      // or fails VISIBLE in the still-open dialog.
      final confirm = find.byKey(const Key('pos-loyalty-dialog-confirm'));
      expect(
        tester.widget<FilledButton>(confirm).onPressed,
        isNotNull,
        reason: 'the dialog\'s server-validated preview — not an invisible '
            'session flag — gates Confirm; a dead button with healthy rows '
            'is the reported bug (click does NOTHING, dialog stays open)',
      );

      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing,
          reason: 'the retried revalidation landed → success closes');
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.error, isNull, reason: 'a landed preview heals the session');
      expect(loyalty.rewardPercent, 10.0);
      expect(loyalty.previewMatches, isTrue);
      expect(loyalty.preview!.rewardDiscount, closeTo(400, 0.001));
      final footer = tester
          .widget<Text>(find.byKey(const Key('pos-loyalty-amount-due')))
          .data!;
      expect(footer, PaymentMath.money(3600));
      expect(container.read(posCartProvider).totals.total, 4000.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'poisoned session + a STILL-failing confirm: the dialog stays open '
        'with the error, the slot rolls back to nothing, Cancel is clean',
        (tester) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );

      final sessionGate = Completer<void>();
      var percent10Fails = false;
      _restubPreviewPost(
        dio,
        preview: (call, data) async {
          final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
          if (call == 1) {
            await sessionGate.future;
            throw DioException(
              requestOptions: RequestOptions(path: '/api/v1/loyalty/preview'),
              message: 'transient backend blip',
            );
          }
          if (percent == 10 && percent10Fails) {
            throw DioException(
              requestOptions: RequestOptions(path: '/api/v1/loyalty/preview'),
              message: 'still down',
            );
          }
          return _previewJson(data, loyaltyEligible: true);
        },
      );
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      sessionGate.complete();
      await tester.pumpAndSettle();
      expect(container.read(posLoyaltyProvider).error, isNotNull);
      // The server refuses the confirm-time write too — from now on.
      percent10Fails = true;

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget,
          reason: 'a failing confirm never presents a close as success');
      expect(
        find.byKey(const Key('pos-loyalty-dialog-confirm-error')),
        findsOneWidget,
        reason: 'the FAILURE is visible — never a silent dead click',
      );
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 0.0,
          reason: 'the failed attempt rolled back to nothing');
      expect(loyalty.error, isNull,
          reason: 'the rollback revalidated the restored (percent-0) slot');
      expect(find.byKey(const Key('pos-loyalty-amount-due')), findsNothing,
          reason: 'the panel never shows a discount that did not land');
      expect(container.read(posCartProvider).totals.total, 4000.0);

      // A clean Cancel still applies nothing and actually closes.
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a malformed confirm-time answer degrades to the visible error — '
        'never a frozen dialog (buttons and dismissal stay alive)', (
      tester,
    ) async {
      final container = await _pumpPos(
        tester,
        dio: dio,
        lines: 1,
        unitPrice: '4000',
      );
      await _attachCustomer(tester, container);

      await tester.tap(loyaltyButton());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '10',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-loyalty-dialog-due')))
            .data,
        contains(PaymentMath.money(3600)),
      );

      // From now on the SESSION's percent-10 write answers a non-map 200
      // (proxy garbage) — a NON-Dio failure the old catch clauses let
      // escape, stranding _busy/_confirming with PopScope holding the
      // route shut.
      _restubPreviewPost(
        dio,
        preview: (call, data) {
          final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
          if (percent == 10) return 'not-a-json-object';
          return _previewJson(data, loyaltyEligible: true);
        },
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'a malformed answer is a FAILURE, not a crash');
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('pos-loyalty-dialog-confirm-error')),
        findsOneWidget,
        reason: 'the failure surfaces in the still-open dialog',
      );
      final loyalty = container.read(posLoyaltyProvider);
      expect(loyalty.rewardPercent, 0.0,
          reason: 'the malformed write applied nothing (rolled back)');

      // The dialog must NOT be frozen: Cancel is alive and Escape-capable.
      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(container.read(posCartProvider).totals.total, 4000.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('tint action colors', () {
    testWidgets(
        'accent actions paint subtle tint washes with onTint labels, Return '
        'stays a solid red chip, holds stay neutral, PAY rides theme blue',
        (tester) async {
      final container =
          await _pumpPos(tester, dio: dio, lines: 1, grantReturn: true);
      expect(container, isNotNull);
      const enabled = <WidgetState>{};
      const disabled = <WidgetState>{WidgetState.disabled};

      final theme = Theme.of(
          tester.element(find.byKey(const Key('pos-holds-button'))));

      /// The Material color the button actually paints with (outermost
      /// non-null one — ButtonStyleButton's own background Material).
      Color? paintedFill(Key key) {
        final mats = tester.widgetList<Material>(find.descendant(
            of: find.byKey(key), matching: find.byType(Material)));
        for (final m in mats) {
          if (m.color != null) return m.color;
        }
        return null;
      }

      /// The subtle outline look: a translucent wash of the hue (never an
      /// opaque slab), the hue itself as the border, [AppColors.onTint] as
      /// the label. Disabled releases the wash instead of painting a dim
      /// slab.
      void expectTint(Key key, Color accent) {
        final button = tester.widget<OutlinedButton>(find.byKey(key));
        final style = button.style!;
        final bg = style.backgroundColor!.resolve(enabled)!;
        expect(bg, AppColors.tint(accent, theme.brightness),
            reason: '$key must wash in its action hue');
        expect(bg.a, closeTo(AppColors.tintAlpha(theme.brightness), 0.001),
            reason: '$key fill must stay a translucent tint');
        expect(bg.a, lessThan(1.0),
            reason: '$key must never paint an opaque slab');
        final fg = style.foregroundColor!.resolve(enabled)!;
        expect(fg, AppColors.onTint(accent, theme.brightness),
            reason: '$key must label itself with the tint-safe fg');
        // AA: label vs the wash composited onto the panel's card.
        expect(
            AppColors.contrastRatio(
                fg, Color.alphaBlend(bg, AppColors.greyCard)),
            greaterThanOrEqualTo(4.5),
            reason: '$key label over its tinted card');
        // The border carries the identity hue.
        expect(style.side!.resolve(enabled)!.color, accent,
            reason: '$key border must be its action hue');
        // What the tree renders matches the style of the ACTUAL state —
        // an enabled chip paints the tint, a disabled one paints its
        // released (transparent) background.
        final isEnabled = button.onPressed != null;
        expect(paintedFill(key),
            style.backgroundColor!.resolve(isEnabled ? enabled : disabled),
            reason: '$key must render its resolved background');
        // Disabled: wash released, outline softened, label dimmed.
        final off = style.backgroundColor!.resolve(disabled)!;
        expect(off.a, 0.0, reason: '$key disabled must release the wash');
        expect(style.side!.resolve(disabled)!.color,
            theme.colorScheme.outline.withValues(alpha: 0.6));
        expect(style.foregroundColor!.resolve(disabled),
            theme.colorScheme.onSurface.withValues(alpha: 0.38));
      }

      expectTint(const Key('pos-discount-button'), AppColors.warning);
      expectTint(const Key('pos-hold-button'), AppColors.actionHold);
      expectTint(const Key('pos-history-button'), AppColors.actionHistory);
      expectTint(const Key('pos-loyalty-discount-button'), AppColors.success);

      // Return is the ONE solid chip: opaque red, white label, muted off.
      void expectSolid(Key key, Color accent) {
        final button = tester.widget<OutlinedButton>(find.byKey(key));
        final style = button.style!;
        final bg = style.backgroundColor!.resolve(enabled)!;
        expect(bg, accent, reason: '$key must resolve to its action hue');
        expect(bg.a, 1.0, reason: '$key fill must be opaque');
        expect(style.foregroundColor!.resolve(enabled), Colors.white,
            reason: '$key must label itself in white');
        expect(AppColors.contrastRatio(Colors.white, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'white label on the solid red chip');
        final off = style.backgroundColor!.resolve(disabled)!;
        expect(off, AppColors.mutedAction(accent, theme.colorScheme.surface),
            reason: '$key disabled fill must be the muted mix');
        expect(off.a, 1.0, reason: '$key disabled fill must be opaque');
        expect(paintedFill(key), accent,
            reason: '$key must render the solid hue as its Material color');
        expect(style.side!.resolve(enabled)!.color, accent);
      }

      expectSolid(const Key('pos-return-button'), AppColors.actionReturn);

      // The holds list is neutral by design: no accent fill, plain outline.
      final holds = tester
          .widget<OutlinedButton>(find.byKey(const Key('pos-holds-button')));
      expect(holds.style!.backgroundColor, isNull);
      expect(holds.style!.side!.resolve(enabled)!.color,
          theme.colorScheme.outline);

      // PAY rides the THEME accent — the screen-wide primary (solid blue in
      // the dark theme, deep blue in light, slate in grey).
      final pay = tester
          .widget<FilledButton>(find.byKey(const Key('pos-pay-button')));
      final payBg = pay.style!.backgroundColor!.resolve(enabled)!;
      expect(payBg, theme.colorScheme.primary,
          reason: 'PAY must ride the theme accent');
      expect(payBg.a, 1.0);
      final payForeground =
          pay.style!.foregroundColor?.resolve(enabled) ?? Colors.white;
      expect(payForeground, Colors.white);
      // The PAY label is bold/large: AA-large = 3:1 (darkAccent 3.7:1,
      // lightAccent 6.7:1, greyAccent 4.8:1 — every theme clears).
      expect(
          AppColors.contrastRatio(payForeground, payBg),
          greaterThanOrEqualTo(3.0));
      expect(paintedFill(const Key('pos-pay-button')),
          theme.colorScheme.primary);
      expect(tester.takeException(), isNull);
    });

    test('every action label clears WCAG AA in every theme', () {
      // Solid chips carry white directly.
      const solidAccents = <Color>[AppColors.actionReturn];
      for (final accent in solidAccents) {
        expect(accent.a, 1.0,
            reason: '${accent.toString()} must be a solid (opaque) fill');
        expect(
          AppColors.contrastRatio(Colors.white, accent),
          greaterThanOrEqualTo(4.5),
          reason: 'white label on ${accent.toString()}',
        );
      }
      // Tint washes carry [AppColors.onTint], measured against the wash
      // composited onto that brightness's panel card (light: white card,
      // dark: grey card) — light and dark both.
      const tintAccents = <Color>[
        AppColors.warning,
        AppColors.actionHold,
        AppColors.actionHistory,
        AppColors.success,
      ];
      for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
        final surface =
            brightness == Brightness.light ? AppColors.lightSurface : AppColors.greyCard;
        for (final accent in tintAccents) {
          final bg = AppColors.tint(accent, brightness);
          final fg = AppColors.onTint(accent, brightness);
          expect(
            AppColors.contrastRatio(fg, Color.alphaBlend(bg, surface)),
            greaterThanOrEqualTo(4.5),
            reason:
                '${accent.toString()} tint label in ${brightness.name} theme',
          );
        }
      }
    });

    test('the solid Return hue clears WCAG 3:1 as its border on both panel '
        'surfaces', () {
      const accents = <Color>[AppColors.actionReturn];
      for (final accent in accents) {
        expect(
          AppColors.contrastRatio(accent, AppColors.lightSurface),
          greaterThanOrEqualTo(3.0),
          reason: '${accent.toString()} border on white',
        );
        expect(
          AppColors.contrastRatio(accent, AppColors.darkSurface),
          greaterThanOrEqualTo(3.0),
          reason: '${accent.toString()} border on #1E1E1E',
        );
      }
    });
  });
}
