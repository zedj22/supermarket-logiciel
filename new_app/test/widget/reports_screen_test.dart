// Phase 14 Reports screen (§10 / §17.2): permission gating, tab
// navigation, shared range selector, loading/empty/error states with
// retry, and the `export_data`-gated export button.
//
// Harness: same full-app login flow as expenses_screen_test / nav_rail
// overflow test (mocktail Dio + FakeCredentialStorage). Default locale
// in tests is Arabic (matches the app default).
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/reports/reports_providers.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

/// In-memory credential storage (same harness as expenses_screen_test).
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
const _financialPath = '/api/v1/reports/financial';
const _productsPath = '/api/v1/reports/products';
const _exportsPath = '/api/v1/exports';

const _viewerScopes = ['report_financial', 'export_data'];

Map<String, dynamic> _loginBody(List<String> scopes, String roleName) => {
      'access_token': 'tok-$roleName',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'roles': [
          {
            'name': roleName,
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _financialJson() => <String, dynamic>{
      'date_from': '2026-09-01',
      'date_to': '2026-09-30',
      'gross_sales': '1200.000',
      'line_discounts': '10.000',
      'invoice_discounts': '5.000',
      'discounts_total': '15.000',
      'sales_after_discounts': '1185.000',
      'returns_count': 1,
      'returns_total': '15.000',
      'net_sales': '1170.000',
      'invoice_count': 9,
      'items_sold': '30',
      'cogs': '600.000',
      'returns_cost': '8.000',
      'cogs_net': '592.000',
      'expenses_total': '100.000',
      'expenses_drawer': '60.000',
      'expenses_external': '40.000',
      'gross_profit': '578.000',
      'net_profit': '478.000',
      'profit_margin_pct': '40.85',
      'paid_cash': '700.000',
      'paid_card': '300.000',
      'paid_partial': '170.000',
      'collected_total': '1170.000',
      'debt_created': '0.000',
      'change_total': '0.000',
      'outstanding_debt': '0.000',
      'debt_collected': '0.000',
      'ar_outstanding': '0.000',
      'customers_with_debt': 0,
      'device_breakdown': [
        {
          'device_id': 'POS-1',
          'invoice_count': 9,
          'net_sales': '1170.000',
          'share_pct': '100.00',
        },
      ],
    };

const _emptyPage = <String, dynamic>{
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 100,
  'pages': 1,
  'totals': <String, dynamic>{},
};

const _dashboardJson = <String, dynamic>{
  'date_from': '2026-09-30',
  'date_to': '2026-09-30',
  'today_sales': '100.000',
  'today_invoices': 2,
  'today_net_profit': '20.000',
  'today_expenses': '0.000',
  'total_products': 10,
  'total_customers': 3,
  'stock_value': '500.000',
  'low_stock_count': 1,
  'customers_with_debt': 0,
  'total_debt': '0.000',
  'recent_sales': <Map<String, dynamic>>[],
  'top_products': <Map<String, dynamic>>[],
};

DioException _envelope(int status, String code) => DioException(
      requestOptions: RequestOptions(path: _financialPath),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: _financialPath),
        statusCode: status,
        data: <String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': 'raw'},
        },
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    // The export flow awaits posDeviceIdProvider (SharedPreferences) —
    // without an in-memory store the future never resolves and the
    // export spinner blocks pumpAndSettle.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  // Phase 15 §12.1: bodies posted to `POST /exports` (cleared per stub),
  // plus a per-test error override for the export endpoint.
  final exportRequestBodies = <Map<String, dynamic>>[];
  Object? exportPostError;

  void stubRequests(
    MockDio dio, {
    List<String> scopes = _viewerScopes,
    String roleName = 'admin',
    bool failFinancialOnce = false,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    exportRequestBodies.clear();
    exportPostError = null;

    var financialCalls = 0;

    Response<dynamic> postAnswer(Invocation invocation) {
      final path = invocation.positionalArguments.first as String;
      if (path == _exportsPath) {
        final data = invocation.namedArguments[#data];
        if (data is Map) {
          exportRequestBodies.add(Map<String, dynamic>.from(data));
        }
        final error = exportPostError;
        if (error != null) throw error;
        // Server-rendered XLSX bytes + sanitized filename (§10.1).
        return Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: Uint8List.fromList(<int>[88, 76, 83, 88]),
          headers: Headers.fromMap(<String, List<String>>{
            'content-disposition': <String>[
              'attachment; filename="financial_export.xlsx"',
            ],
          }),
        );
      }
      if (path == _loginPath) {
        return okResponse(_loginPath, _loginBody(scopes, roleName));
      }
      return okResponse(path, <String, dynamic>{'message': 'ok'});
    }

    when(() => dio.post(any(), data: any(named: 'data')))
        .thenAnswer((invocation) async => postAnswer(invocation));

    // Phase 15 byte endpoints call `post<Uint8List>` — mocktail matches
    // the generic type argument strictly, so they need their own
    // registrations (same pattern as pos_screen_test).
    Future<Response<Uint8List>> postBytes(Invocation invocation) async {
      final response = postAnswer(invocation);
      return Response<Uint8List>(
        requestOptions: response.requestOptions,
        statusCode: response.statusCode,
        data: response.data is Uint8List ? response.data as Uint8List : null,
        headers: response.headers,
        statusMessage: response.statusMessage,
      );
    }

    when(() => dio.post<Uint8List>(any(), data: any(named: 'data')))
        .thenAnswer(postBytes);
    when(
      () => dio.post<Uint8List>(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(postBytes);

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _financialPath) {
        financialCalls++;
        if (failFinancialOnce && financialCalls == 1) {
          throw _envelope(422, 'REPORT_RANGE_TOO_WIDE');
        }
        return okResponse(path, _financialJson());
      }
      if (path == _productsPath) return okResponse(path, _emptyPage);
      if (path == '/api/v1/dashboard') {
        return okResponse(path, _dashboardJson);
      }
      return okResponse(path, _emptyPage);
    });
    when(() => dio.get(any())).thenAnswer((invocation) async =>
        okResponse(invocation.positionalArguments.first as String,
            _emptyPage));

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
              {'name': roleName},
            ],
          },
        ],
        'total': 1,
      }),
    );
  }

  Future<ProviderContainer> pumpLogin(
    WidgetTester tester,
    MockDio dio,
  ) async {
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

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Finder railLabel(String label) => find.descendant(
        of: find.byType(AppNavRail),
        matching: find.text(label),
      );

  group('Reports screen — RBAC (§10)', () {
    testWidgets('report viewer: rail entry exists and opens the screen',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);

      // Rail destination gated by report_financial (§10).
      final reportsRail = railLabel(AppStrings.t('reports', 'ar'));
      expect(reportsRail, findsOneWidget);

      await tester.tap(reportsRail);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-screen')), findsOneWidget);
      expect(find.byKey(const Key('reports-title')), findsOneWidget);
      expect(find.byKey(const Key('reports-tabbar')), findsOneWidget);
      // Redesigned shared filter: one responsive card holds the period
      // preset, the range buttons, and the device field.
      expect(find.byKey(const Key('reports-filter-card')), findsOneWidget);
      expect(find.byKey(const Key('reports-date-from')), findsOneWidget);
      expect(find.byKey(const Key('reports-date-to')), findsOneWidget);

      // All ten surfaces (§8 R1–R9 + R13).
      for (final tab in [
        'financial',
        'products',
        'categories',
        'daily',
        'hourly',
        'peak',
        'slow',
        'voided',
        'sales',
        'suppliers',
      ]) {
        expect(find.byKey(Key('reports-tab-$tab')), findsOneWidget);
      }

      // Financial tab auto-loaded: KPI tiles + R15 device table.
      expect(find.byKey(const Key('financial-content')), findsOneWidget);
      expect(find.byKey(const Key('kpi-kpi_gross_sales')), findsOneWidget);
      expect(find.byKey(const Key('kpi-kpi_gross_sales-value')), findsOneWidget);
      expect(find.byKey(const Key('financial-devices')), findsOneWidget);

      // export_data renders the export button (§10).
      expect(find.byKey(const Key('reports-export')), findsOneWidget);
    });

    testWidgets('viewer without export_data: no export button', 
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: ['report_financial']);
      await pumpLogin(tester, dio);

      containerGoReports(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-screen')), findsOneWidget);
      expect(find.byKey(const Key('reports-export')), findsNothing);
    });

    testWidgets('no report scope: no rail entry, deep link shows denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: ['expense_view'], roleName: 'cashier');
      final container = await pumpLogin(tester, dio);

      expect(railLabel(AppStrings.t('reports', 'ar')), findsNothing);

      container.read(routerProvider).go('/reports');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-denied')), findsOneWidget);
      expect(find.byKey(const Key('reports-screen')), findsNothing);
    });
  });

  group('Reports screen — tabs & filters (§8/§9)', () {
    testWidgets('switching to products shows sort + empty state',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reports-tab-products')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-sort-net_revenue')), findsOneWidget);
      expect(find.byKey(const Key('report-empty')), findsOneWidget);
      expect(find.text(AppStrings.t('state_no_data', 'ar')), findsOneWidget);

      verify(() => dio.get(_productsPath,
              queryParameters: any(named: 'queryParameters')))
          .called(1);
    });

    testWidgets('preset change swaps the shared range and reloads',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-preset-today')), findsOneWidget);
      verify(() => dio.get(_financialPath,
              queryParameters: any(named: 'queryParameters')))
          .called(1);

      await tester.tap(find.byKey(const Key('reports-preset-today')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reports-preset-item-yesterday')));
      await tester.pumpAndSettle();

      // Field rebuilt with the new preset; shared filter reloaded R1.
      expect(find.byKey(const Key('reports-preset-yesterday')), findsOneWidget);
      verify(() => dio.get(_financialPath,
              queryParameters: any(named: 'queryParameters')))
          .called(1);
    });

    testWidgets(
        'last_month preset swaps both bounds to the previous complete month',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      // Initial load of the open financial tab (default = today).
      verify(() => dio.get(_financialPath,
              queryParameters: any(named: 'queryParameters')))
          .called(1);

      await tester.tap(find.byKey(const Key('reports-preset-today')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('reports-preset-item-last_month')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('reports-preset-last_month')), findsOneWidget);

      final container =
          ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      final filter = container.read(reportFilterProvider);
      final now = DateTime.now();

      // Both bounds move together to the previous COMPLETE calendar month
      // (never a rolling 30-day window, never the current partial month).
      expect(filter.dateFrom, DateTime(now.year, now.month - 1, 1));
      expect(filter.dateTo, DateTime(now.year, now.month, 0));
      expect(filter.dateFrom.isAfter(filter.dateTo), isFalse);

      // The visible date buttons display the swapped pair.
      expect(find.text(reportDateParam(filter.dateFrom)), findsOneWidget);
      expect(find.text(reportDateParam(filter.dateTo)), findsOneWidget);

      // The already-open financial tab reloaded with the new range.
      verify(() => dio.get(_financialPath,
              queryParameters: any(named: 'queryParameters')))
          .called(1);
    });

    testWidgets('device filter field submits into the shared filter',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('reports-device-')), 'POS-7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-device-POS-7')), findsOneWidget);
      expect(find.byKey(const Key('reports-clear')), findsOneWidget);

      // Every financial reload (initial + device submit) carried the
      // shared range; the latest one includes §8 device_id.
      final captured = verify(() => dio.get(
            _financialPath,
            queryParameters: captureAny(named: 'queryParameters'),
          )).captured;
      expect(captured, hasLength(2));
      final lastParams = (captured.last as Map).cast<String, dynamic>();
      expect(lastParams['device_id'], 'POS-7');
      expect(lastParams['date_from'], isNotEmpty);
    });
  });

  group('Reports screen — error + retry (§17.2)', () {
    testWidgets('422 REPORT_RANGE_TOO_WIDE shows localized error, retry recovers',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, failFinancialOnce: true);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      // First load failed → localized headline + retry action.
      expect(find.byKey(const Key('report-error')), findsOneWidget);
      expect(
        find.byKey(const Key('report-error-message')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('report-error-message')))
            .data,
        AppStrings.t('report_range_too_wide', 'ar'),
      );

      await tester.tap(find.byKey(const Key('report-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('report-error')), findsNothing);
      expect(find.byKey(const Key('financial-content')), findsOneWidget);
    });
  });

  group('Reports screen — unified export (Phase 15 §12.1/§19.2)', () {
    testWidgets('export button opens the format dialog; cancel is neutral',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reports-export')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('export-format-dialog')), findsOneWidget);
      expect(find.byKey(const Key('export-format-csv')), findsOneWidget);
      expect(find.byKey(const Key('export-format-xlsx')), findsOneWidget);
      expect(find.byKey(const Key('export-format-pdf')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('export-format-dialog')),
          matching: find.text(AppStrings.t('export_title', 'ar')),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('export-format-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('export-format-dialog')), findsNothing);
      // Neutral cancel: no request, no toast, button re-enabled (§16.2).
      expect(exportRequestBodies, isEmpty);
      expect(find.byKey(const Key('reports-export-toast')), findsNothing);
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('reports-export')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('XLSX posts ExportRequest + prefills server filename + toast',
        (tester) async {
      final picker = _FakeFilePicker()..savedPath = 'C:/tmp/out.xlsx';
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reports-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-format-xlsx')));
      await tester.pumpAndSettle();

      expect(exportRequestBodies, hasLength(1));
      final sent = exportRequestBodies.single;
      expect(sent['report'], 'financial');
      expect(sent['format'], 'xlsx');
      expect(sent['locale'], 'ar');
      expect(sent['date_from'], isNotEmpty);
      expect(sent['date_to'], isNotEmpty);

      // Server filename prefills the save dialog (§10.1).
      expect(picker.lastFileName, 'financial_export.xlsx');
      expect(picker.lastTitle, AppStrings.t('export_xlsx', 'ar'));

      expect(find.byKey(const Key('reports-export-toast')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('export_done', 'ar')),
        findsOneWidget,
      );
      // The success toast travels with the sanitized filename as detail.
      expect(find.textContaining('financial_export.xlsx'), findsOneWidget);
    });

    testWidgets('422 EXPORT_FORMAT_UNSUPPORTED → localized toast, no save',
        (tester) async {
      final picker = _FakeFilePicker()..savedPath = 'C:/tmp/out.xlsx';
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      final dio = MockDio();
      stubRequests(dio);
      exportPostError = _envelope(422, 'EXPORT_FORMAT_UNSUPPORTED');
      await pumpLogin(tester, dio);
      containerGoReports(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reports-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-format-xlsx')));
      await tester.pumpAndSettle();

      expect(exportRequestBodies, hasLength(1)); // request WAS sent
      expect(picker.lastFileName, isNull); // save dialog never opened
      expect(find.byKey(const Key('export-format-dialog')), findsNothing);
      expect(find.byKey(const Key('reports-export-toast')), findsOneWidget);
      expect(
        find.text(AppStrings.t('export_format_unsupported', 'ar')),
        findsOneWidget,
      );
      expect(
        find.textContaining(AppStrings.t('export_done', 'ar')),
        findsNothing,
      );
    });
  });
}

/// Deep-links into `/reports` through the live router (rail-independent).
void containerGoReports(WidgetTester tester) {
  final container =
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  container.read(routerProvider).go('/reports');
}

/// In-memory `saveFile` fake for the Phase 15 export/save dialogs.
class _FakeFilePicker extends FilePicker {
  String? savedPath;
  String? lastTitle;
  String? lastFileName;
  Uint8List? lastBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    lastTitle = dialogTitle;
    lastFileName = fileName;
    lastBytes = bytes;
    return savedPath;
  }
}
