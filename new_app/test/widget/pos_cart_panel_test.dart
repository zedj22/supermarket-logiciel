// Cart-panel regression suite (customer-attached clipping fixes):
//  1. geometry  — the loyalty block must never clip the last cart line;
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
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/colors.dart';
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

/// Balance with ONE redeemable reward → the loyalty block shows its full
/// height (label row + reward dropdown row) under the customer row.
Map<String, Object> _balanceJson() => <String, Object>{
      'customer_id': _customerId,
      'has_account': true,
      'points_balance': '130.000',
      'cashback_balance': '25.000',
      'available_rewards': 1,
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

void _mockPosDio(MockDio dio) {
  Object? getBody(String path) {
    if (path.startsWith('/api/v1/customers/') && path.endsWith('/loyalty')) {
      return _balanceJson();
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
        'available_rewards': 1,
        'remaining_points': '30.000',
        'min_reward_points': 100,
        'max_reward_discount_percent': '20.000',
        'points_balance': '130.000',
        'cashback_balance': '25.000',
        'points_earned': '0.960',
        'cashback_earned': '0.500',
        'points_after_sale': '130.960',
        'reward_eligible': true,
      };
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

Future<ProviderContainer> _pumpPos(
  WidgetTester tester, {
  required MockDio dio,
  Size size = const Size(1366, 768),
  int lines = 12,
  // The permission-gated return action adds a THIRD actions row (~54px)
  // that shrinks the lines viewport — grant it only where its color is
  // asserted, so the geometry scenarios measure the default chrome.
  bool grantReturn = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final cart = _SeededCart(dio, () => 'en', () async => 'pos-test');
  for (var i = 0; i < lines; i++) {
    cart.addLine(CartLine(
      productId: 'p$i',
      name: 'Product $i',
      quantity: '1',
      unitPrice: '10',
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
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
        pdfPreviewProvider.overrideWithValue(_FakePdfPreview()),
        posCartProvider.overrideWith((ref) => cart),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: PosScreen()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
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

  group('loyalty merge and stacked total', () {
    testWidgets(
        'loyalty balance and reward selector ride the Total block — '
        'Subtotal and Discount rows stay clean', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      final disc = tester.getRect(find.byKey(const Key('pos-discount-value')));
      final totalLabel =
          tester.getRect(find.byKey(const Key('pos-total-label')));
      final totalValue =
          tester.getRect(find.byKey(const Key('pos-total-value')));
      final label =
          tester.getRect(find.byKey(const Key('pos-loyalty-label')));
      final balance =
          tester.getRect(find.byKey(const Key('pos-loyalty-balance')));
      final select =
          tester.getRect(find.byKey(const Key('pos-loyalty-reward-select')));

      // Subtotal/Discount rows are clean: every loyalty chunk sits BELOW
      // the discount row, inside the Total block's vertical band.
      expect(label.top, greaterThanOrEqualTo(disc.bottom),
          reason: 'the loyalty label must not ride the Subtotal row');
      expect(balance.top, greaterThanOrEqualTo(disc.bottom),
          reason: 'the balance must not ride the Subtotal row');
      expect(select.top, greaterThanOrEqualTo(disc.bottom),
          reason: 'the reward selector must not ride the Discount row');

      // The chunks are visually associated with the large amount: inside
      // the stacked Total band (label top → amount bottom, ± slack).
      expect(label.top, greaterThanOrEqualTo(totalLabel.top - 8),
          reason: 'the loyalty label sits in the Total band');
      expect(balance.bottom, lessThanOrEqualTo(totalValue.bottom + 8),
          reason: 'the balance sits in the Total band');
      expect(select.top, greaterThanOrEqualTo(totalLabel.top - 8));
      expect(select.bottom, lessThanOrEqualTo(totalValue.bottom + 8));

      // Left cluster beside the money edge: loyalty never overlaps the
      // dominant amount.
      expect(balance.right, lessThanOrEqualTo(totalValue.left + 4),
          reason: 'the balance stays clear of the Total amount');
      expect(label.right, lessThanOrEqualTo(balance.right));
      expect(select.right, lessThanOrEqualTo(totalValue.left + 4),
          reason: 'the selector stays clear of the Total amount');

      expect(find.byKey(const Key('pos-loyalty-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'reward selector stays usable beside the Total — picking a reward '
        'updates the preview without touching PAY', (tester) async {
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      final payFinder = find.byKey(const Key('pos-pay-button'));
      final payBefore = tester.getRect(payFinder);
      await tester.tap(find.byKey(const Key('pos-loyalty-reward-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();

      final rewardPercent =
          container.read(posLoyaltyProvider).rewardPercent;
      expect(rewardPercent, 5.0, reason: 'the dropdown drives the state');
      // The selector is inside the Total block, far from PAY — the tap
      // must never hit the payment button.
      final select =
          tester.getRect(find.byKey(const Key('pos-loyalty-reward-select')));
      final pay = tester.getRect(payFinder);
      expect(pay, payBefore, reason: 'PAY does not move or react');
      expect(select.bottom, lessThanOrEqualTo(pay.top),
          reason: 'the selector never overlaps PAY');
      expect(tester.takeException(), isNull);
    });

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
        // What the tree renders for the enabled button matches the style.
        expect(paintedFill(key), bg,
            reason: '$key must render the tint as its Material color');
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
