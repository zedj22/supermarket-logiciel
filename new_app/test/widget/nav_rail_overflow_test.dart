// Phase 11 human QA fix round — NavigationRail vertical overflow (Bug 2).
//
// Root cause: Flutter's NavigationRail only wraps its destination Column
// in a scroll view when `scrollable: true`. Without it, all destinations
// (now 11 with Suppliers + Purchases) must fit the window height, and the
// internal RenderFlex overflows on short windows ("RenderFlex overflowed
// by 87 pixels"). Fix: `scrollable: true` in app_router.dart — the
// framework's own adaptive behavior; destinations are never hidden or
// removed, permission gating is untouched, and tall windows are
// visually unchanged (content still sizes intrinsically).
//
// This suite checks: no RenderFlex overflow at normal / medium / very
// short heights, minimize-restore (resize back), every destination still
// reachable (scroll + tap), and AR/EN labels both working.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// In-memory credential storage (same harness as clients_screen_test).
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

/// Every scope that gates a rail destination → all 11 destinations show
/// (worst case for rail height).
const _allScopes = [
  'pos_sale',
  'product_view',
  'inventory_view',
  'customer_view',
  'supplier_view',
  'purchase_view',
  'user_manage',
];

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
              for (final s in _allScopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _supplierJson() => {
      'id': 'c1',
      'name': 'North Wholesale',
      'phone': null,
      'address': null,
      'email': null,
      'contact_person': null,
      'notes': null,
      'balance': '1000.000',
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
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

  void stubRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody());
        }
        return okResponse(path, {'message': 'ok'});
      },
    );

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/suppliers') {
        return okResponse(path, {
          'items': [_supplierJson()],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        });
      }
      return okResponse(path, _emptyListBody);
    });

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/suppliers') {
        return okResponse(path, {
          'items': [_supplierJson()],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        });
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

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
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

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Finder railLabel(String label) => find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(label),
      );

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex overflow allowed (got exception above)');
  }

  Future<void> tapRail(WidgetTester tester, String label) async {
    final finder = railLabel(label);
    expect(finder, findsOneWidget, reason: 'destination "$label" must exist');
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  group('NavigationRail overflow (Bug 2)', () {
    testWidgets(
        'no overflow at normal/medium/very short heights; destinations '
        'reachable by scrolling; minimize-restore; AR + EN', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpApp(tester, dio);

      // Normal desktop height — every destination fits (no scrolling).
      expect(
        railLabel(AppStrings.t('suppliers', 'ar')),
        findsOneWidget,
      );
      expect(
        railLabel(AppStrings.t('purchases', 'ar')),
        findsOneWidget,
      );
      await tester.tap(railLabel(AppStrings.t('suppliers', 'ar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('suppliers-title')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Medium height (shorter window) — no overflow.
      await resize(tester, const Size(1600, 520));
      expect(
        railLabel(AppStrings.t('suppliers', 'ar')),
        findsOneWidget,
      );
      expect(
        railLabel(AppStrings.t('purchases', 'ar')),
        findsOneWidget,
      );

      // Very short height — still no overflow, destinations still there.
      await resize(tester, const Size(1600, 400));
      expect(
        railLabel(AppStrings.t('purchases', 'ar')),
        findsOneWidget,
      );

      // All destinations remain accessible: scroll the rail and navigate
      // to Purchases from the very short window.
      await tapRail(tester, AppStrings.t('purchases', 'ar'));
      expect(find.byKey(const Key('purchases-title')), findsOneWidget);

      // Minimize / restore (resize back to a tall window).
      await resize(tester, const Size(1600, 1000));
      await tapRail(tester, AppStrings.t('suppliers', 'ar'));
      expect(find.byKey(const Key('suppliers-title')), findsOneWidget);

      // English labels work the same way.
      container.read(localeProvider.notifier).setLocale(AppLocale.en);
      await tester.pumpAndSettle();
      expect(
        railLabel(AppStrings.t('suppliers', 'en')),
        findsOneWidget,
      );
      await resize(tester, const Size(1600, 460));
      await tapRail(tester, AppStrings.t('purchases', 'en'));
      expect(find.byKey(const Key('purchases-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
