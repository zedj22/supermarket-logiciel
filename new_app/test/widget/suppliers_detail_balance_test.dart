// Phase 11 human QA fix round — Supplier Detail balance + history.
//
// Bug 1 root cause (fixed this round): `supplierDetailProvider` and
// `supplierLedgerProvider` are non-autoDispose families that load ONCE
// per supplier id. Reopening Supplier Detail reused the cached first
// snapshot, so a payable created after the first open kept displaying 0
// (and the ledger kept showing "No ledger entries"). The list refreshed
// on every screen entry (initState → load), so list and detail disagreed.
//
// The fix adds a fresh GET on every detail-pane mount / id change
// (silent, keeping the previous snapshot while the request is in flight).
// This suite pins the QA contract:
//   1. payload balance "1000.000" → detail displays 1000, never 0
//   2. reopening after the payable changed → fresh balance (list agrees)
//   3. reopening refreshes ledger history (signed amounts + balance_after)
//   4. history remains after the balance reaches 0 (incl. cancel entry),
//      and the payment action disables at 0 (no negative balance)
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

/// Stateful in-memory credential storage (same harness as the Phase 9
/// clients widget tests).
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

const _loginPath = '/api/v1/auth/login';
const _suppliersPath = '/api/v1/suppliers';
const _adminScopes = ['supplier_view', 'supplier_manage'];
const _lang = 'ar'; // default app locale

const _emptyListBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 40,
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
              for (final s in _adminScopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _supplierJson({String balance = '0.000'}) => {
      'id': 'c1',
      'name': 'North Wholesale',
      'phone': '0555111222',
      'address': null,
      'email': null,
      'contact_person': 'Sam',
      'notes': null,
      'balance': balance,
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _listBody({required String balance}) => {
      'items': [_supplierJson(balance: balance)],
      'total': 1,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _ledgerEntry({
  required String id,
  required String type,
  required String amount,
  required String balanceAfter,
  String? invoice,
  String? note,
}) =>
    {
      'id': id,
      'supplier_id': 'c1',
      'entry_type': type,
      'amount': amount,
      'note': note,
      'reference_purchase_id': 'p1',
      'invoice_number': invoice,
      'user_id': 'u1',
      'user_name': 'Admin',
      'entry_date': '2026-09-27T10:00:00Z',
      'created_at': '2026-09-27T10:00:00Z',
      'balance_after': balanceAfter,
    };

Map<String, dynamic> _ledgerBody(List<Map<String, dynamic>> items) => {
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  /// Stubs with saturating sequences: the FIRST call consumes element 0,
  /// later calls stick to the LAST element (deterministic ordering for
  /// the ctor load vs. the mount refresh).
  void stubRequests(
    MockDio dio, {
    required List<Map<String, dynamic>> detailSeq,
    required List<Map<String, dynamic>> ledgerSeq,
    String listBalance = '1000.000',
  }) {
    var detailCall = 0;
    var ledgerCall = 0;

    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody());
        }
        if (path == '/api/v1/auth/logout-token') {
          return okResponse(path, {'message': 'logged out'});
        }
        return okResponse(path, {'message': 'ok'});
      },
    );

    // Parameterized GET first — the bare stub below is checked last
    // (mocktail: the LAST registered stub wins; see clients_screen_test).
    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _suppliersPath) {
        return okResponse(path, _listBody(balance: listBalance));
      }
      if (path.endsWith('/ledger')) {
        final i = ledgerCall < ledgerSeq.length - 1
            ? ledgerCall
            : ledgerSeq.length - 1;
        ledgerCall += 1;
        return okResponse(path, ledgerSeq[i]);
      }
      return okResponse(path, _emptyListBody);
    });

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path.startsWith('$_suppliersPath/') && !path.endsWith('/ledger')) {
        final i = detailCall < detailSeq.length - 1
            ? detailCall
            : detailSeq.length - 1;
        detailCall += 1;
        return okResponse(path, detailSeq[i]);
      }
      if (path == _suppliersPath) {
        return okResponse(path, _listBody(balance: listBalance));
      }
      return okResponse(path, _emptyListBody);
    });

    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/setup/check', {
        'setup_needed': false,
      }),
    );
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/login-users', {
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
      }),
    );
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester, MockDio dio) async {
    tester.view.physicalSize = const Size(2200, 1200);
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

    await tester.tap(find.text(AppStrings.t('suppliers', _lang)));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> openSupplier(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('supplier-tile-0')));
    await tester.pumpAndSettle();
  }

  String detailBalanceText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('supplier-detail-balance'))).data!;

  group('Bug 1 — Supplier Detail balance', () {
    testWidgets('displays payload balance 1000.000, never 0', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [_supplierJson(balance: '1000.000')],
        ledgerSeq: [_ledgerBody([])],
      );
      await pumpApp(tester, dio);
      await openSupplier(tester);

      final detail = detailBalanceText(tester);
      expect(detail.contains(bidiIsolateLtr('1 000')), isTrue,
          reason: 'detail=$detail');
      expect(detail.trim().endsWith(': ${bidiIsolateLtr('0')}'), isFalse,
          reason: 'detail=$detail');

      // List and detail agree.
      final listBalance =
          tester.widget<Text>(find.byKey(const Key('supplier-balance-0'))).data!;
      expect(listBalance, '1 000');
    });

    testWidgets(
        'reopening Supplier Detail after the payable changed shows the '
        'fresh balance (stale-cache regression)', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [
          _supplierJson(balance: '0.000'), // first open, before the purchase
          _supplierJson(balance: '1000.000'), // after receive
        ],
        ledgerSeq: [_ledgerBody([]), _ledgerBody([])],
        listBalance: '1000.000',
      );
      final container = await pumpApp(tester, dio);
      await openSupplier(tester);
      expect(detailBalanceText(tester).endsWith(': ${bidiIsolateLtr('0')}'),
          isTrue,
          reason: 'first open happens before the payable exists');

      // Leave the screen (purchase happens elsewhere), then come back.
      container.read(routerProvider).go('/purchases');
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/suppliers');
      await tester.pumpAndSettle();
      await openSupplier(tester);

      final detail = detailBalanceText(tester);
      expect(detail.contains(bidiIsolateLtr('1 000')), isTrue,
          reason: 'stale 0 after reopen — detail=$detail');
      expect(detail.trim().endsWith(': ${bidiIsolateLtr('0')}'), isFalse,
          reason: 'detail=$detail');

      final listBalance =
          tester.widget<Text>(find.byKey(const Key('supplier-balance-0'))).data!;
      expect(listBalance, '1 000', reason: 'list and detail must agree');
    });
  });

  group('Bug 3 — Supplier history', () {
    testWidgets(
        'reopening refreshes the ledger: purchase/payment entries with '
        'signed amounts and balance_after, newest first', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [
          _supplierJson(balance: '0.000'),
          _supplierJson(balance: '600.000'),
        ],
        ledgerSeq: [
          _ledgerBody([]), // first open: no entries yet
          _ledgerBody([
            _ledgerEntry(
              id: 'e2',
              type: 'payment',
              amount: '400.000',
              balanceAfter: '600.000',
              note: 'cash',
            ),
            _ledgerEntry(
              id: 'e1',
              type: 'purchase',
              amount: '1000.000',
              balanceAfter: '1000.000',
              invoice: 'PUR-2026-0001',
            ),
          ]),
        ],
        listBalance: '600.000',
      );
      final container = await pumpApp(tester, dio);
      await openSupplier(tester);
      expect(find.byKey(const Key('supplier-ledger-empty')), findsOneWidget,
          reason: 'no history before the purchase');

      container.read(routerProvider).go('/purchases');
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/suppliers');
      await tester.pumpAndSettle();
      await openSupplier(tester);

      // Section header present (QA: clear History/Ledger section).
      expect(find.byKey(const Key('supplier-ledger-title')), findsOneWidget);

      // Newest first: payment -400 (bal 600), purchase +1000 (bal 1000).
      final row0 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-0')))
          .data!;
      expect(row0.contains('-400'), isTrue, reason: 'row0=$row0');
      final row1 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-1')))
          .data!;
      expect(row1.contains('+1 000'), isTrue, reason: 'row1=$row1');

      // balance_after comes from the backend read model.
      final meta1 =
          tester.widget<Text>(find.byKey(const Key('supplier-ledger-meta-1'))).data!;
      expect(meta1.contains('1 000'), isTrue, reason: 'meta1=$meta1');
      expect(meta1.contains('PUR-2026-0001'), isTrue, reason: 'meta1=$meta1');
      final meta0 =
          tester.widget<Text>(find.byKey(const Key('supplier-ledger-meta-0'))).data!;
      expect(meta0.contains('600'), isTrue, reason: 'meta0=$meta0');

      expect(find.byKey(const Key('supplier-ledger-empty')), findsNothing);
    });

    testWidgets(
        'history remains after the balance reaches 0 (cancel entry) and the '
        'payment action disables', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [_supplierJson(balance: '0.000')],
        ledgerSeq: [
          _ledgerBody([
            _ledgerEntry(
              id: 'e3',
              type: 'purchase_cancel',
              amount: '600.000',
              balanceAfter: '0.000',
              invoice: 'PUR-2026-0001',
            ),
            _ledgerEntry(
              id: 'e2',
              type: 'payment',
              amount: '400.000',
              balanceAfter: '600.000',
            ),
            _ledgerEntry(
              id: 'e1',
              type: 'purchase',
              amount: '1000.000',
              balanceAfter: '1000.000',
              invoice: 'PUR-2026-0001',
            ),
          ]),
        ],
        listBalance: '0.000',
      );
      await pumpApp(tester, dio);
      await openSupplier(tester);

      expect(
          detailBalanceText(tester).endsWith(': ${bidiIsolateLtr('0')}'), isTrue);
      expect(find.byKey(const Key('supplier-ledger-list')), findsOneWidget,
          reason: 'history must remain at balance 0');

      final row0 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-0')))
          .data!;
      expect(row0.contains('-600'), isTrue, reason: 'row0=$row0');
      final row2 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-2')))
          .data!;
      expect(row2.contains('+1 000'), isTrue, reason: 'row2=$row2');

      // No negative balance: payment action disabled at 0.
      final payButton =
          tester.widget<ElevatedButton>(find.byKey(const Key('supplier-pay-button')));
      expect(payButton.onPressed, isNull);
    });
  });

  group('RTL bidi currency order (Windows screenshots acceptance)', () {
    // Screenshot B: the supplier balance and the purchase/payment ledger
    // rows must render grouped amounts in logical left-to-right order
    // (`2 000`, `+2 000`, `-500`) while the Arabic labels and the
    // sentence stay natural RTL. The app runs in Arabic (RTL) here. Box
    // assertions use RenderParagraph — real ICU bidi glyph placement
    // under the Ahem test font — layout evidence, not a Windows golden.
    double? leftOf(RenderParagraph p, int base, int extent) => p
        .getBoxesForSelection(
          TextSelection(baseOffset: base, extentOffset: extent),
        )
        .first
        .left;

    /// True when the isolated [money] segment inside [text] is laid out
    /// in logical left-to-right order: first digit box left of the last
    /// digit box, and the last digit left of `DA` when present.
    bool moneyOrderOk(RenderParagraph p, String text, String money) {
      // +1 skips the leading LRI so digit offsets line up with the money.
      final start = text.indexOf(bidiIsolateLtr(money)) + 1;
      if (start <= 0) return false;
      final digits = RegExp('[0-9]').allMatches(money).toList();
      final first = leftOf(
        p,
        start + digits.first.start,
        start + digits.first.start + 1,
      )!;
      final last = leftOf(
        p,
        start + digits.last.start,
        start + digits.last.start + 1,
      )!;
      if (first > last) return false;
      final daAt = money.lastIndexOf(' DA');
      if (daAt >= 0) {
        final da = leftOf(p, start + daAt + 1, start + daAt + 3)!;
        if (last > da) return false;
      }
      return true;
    }

    RenderParagraph paragraphOf(WidgetTester tester, Key key) =>
        tester.renderObject<RenderParagraph>(find.byKey(key));

    testWidgets('supplier balance 2 000 renders in order under RTL',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [_supplierJson(balance: '2000.000')],
        ledgerSeq: [_ledgerBody([])],
        listBalance: '2000.000',
      );
      await pumpApp(tester, dio);
      await openSupplier(tester);

      final balance = tester
          .widget<Text>(find.byKey(const Key('supplier-detail-balance')));
      expect(
        balance.data,
        contains(bidiIsolateLtr('2 000')),
        reason: 'balance amount must be one isolated LTR unit — '
            'actual=${balance.data}',
      );
      // The Arabic "Balance:" label is a plain RTL sentence, not a
      // forced-LTR paragraph.
      expect(balance.textDirection, isNull);
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-detail-balance')),
          balance.data!,
          '2 000',
        ),
        isTrue,
        reason: 'digits of 2 000 must render left-to-right under RTL',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'purchase + payment ledger rows: signed amounts and balance-after '
        'stay in order (screenshot B rows)', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [_supplierJson(balance: '1500.000')],
        ledgerSeq: [
          _ledgerBody([
            _ledgerEntry(
              id: 'e2',
              type: 'payment',
              amount: '500.000',
              balanceAfter: '1500.000',
              note: 'cash',
            ),
            _ledgerEntry(
              id: 'e1',
              type: 'purchase',
              amount: '2000.000',
              balanceAfter: '2000.000',
              invoice: 'PUR-2026-0001',
            ),
          ]),
        ],
        listBalance: '1500.000',
      );
      await pumpApp(tester, dio);
      await openSupplier(tester);

      // Row 0 — outgoing payment: "-500" as one LTR unit.
      final row0 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-0')));
      expect(row0.data, contains(bidiIsolateLtr('-500')),
          reason: 'row0=${row0.data}');
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-ledger-amount-0')),
          row0.data!,
          '-500',
        ),
        isTrue,
      );

      // Row 1 — purchase: "+2 000" as one LTR unit.
      final row1 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-amount-1')));
      expect(row1.data, contains(bidiIsolateLtr('+2 000')),
          reason: 'row1=${row1.data}');
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-ledger-amount-1')),
          row1.data!,
          '+2 000',
        ),
        isTrue,
      );

      // Meta row 1 — Arabic description with invoice reference, date and
      // the balance-after amount.
      final meta1 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-meta-1')));
      expect(meta1.data, contains(bidiIsolateLtr('2 000')),
          reason: 'meta1=${meta1.data}'); // balance_after
      expect(meta1.data, contains('PUR-2026-0001'),
          reason: 'meta1=${meta1.data}');
      expect(
        meta1.data,
        contains(bidiIsolateLtr('2026-09-27 10:00:00')),
        reason: 'the timestamp must stay one LTR unit — meta1=${meta1.data}',
      );
      expect(meta1.textDirection, isNull);
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-ledger-meta-1')),
          meta1.data!,
          '2 000',
        ),
        isTrue,
      );
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-ledger-meta-1')),
          meta1.data!,
          '2026-09-27 10:00:00',
        ),
        isTrue,
      );

      // Meta row 0 — balance after the payment.
      final meta0 = tester
          .widget<Text>(find.byKey(const Key('supplier-ledger-meta-0')));
      expect(meta0.data, contains(bidiIsolateLtr('1 500')),
          reason: 'meta0=${meta0.data}');
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-ledger-meta-0')),
          meta0.data!,
          '1 500',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'payment dialog: balance line and remaining-after stay in order '
        'when an amount is typed', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        detailSeq: [_supplierJson(balance: '2000.000')],
        ledgerSeq: [_ledgerBody([])],
        listBalance: '2000.000',
      );
      await pumpApp(tester, dio);
      await openSupplier(tester);

      await tester.tap(find.byKey(const Key('supplier-pay-button')));
      await tester.pumpAndSettle();

      final balance = tester
          .widget<Text>(find.byKey(const Key('supplier-payment-balance')));
      expect(balance.data, contains(bidiIsolateLtr('2 000')),
          reason: 'balance=${balance.data}');
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-payment-balance')),
          balance.data!,
          '2 000',
        ),
        isTrue,
      );

      await tester.enterText(
        find.byKey(const Key('supplier-amount-field')),
        '500',
      );
      await tester.pump();

      final remaining = tester
          .widget<Text>(find.byKey(const Key('supplier-remaining')));
      expect(remaining.data, contains(bidiIsolateLtr('1 500')),
          reason: 'remaining=${remaining.data}');
      expect(
        moneyOrderOk(
          paragraphOf(tester, const Key('supplier-remaining')),
          remaining.data!,
          '1 500',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
