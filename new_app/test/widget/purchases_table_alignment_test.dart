// Purchases table column alignment (RTL + LTR).
//
// Contract: the pinned heading and every data row are laid out from the
// SAME column specs (`_Col` list + one `_cell` builder), so each value
// sits directly under its own heading — invoice, supplier, status, total,
// remaining balance and (wide mode) date — in both locales.
//
// What this file exists to prove:
//   * header cell and data cell of every column share one box (same left
//     edge, same width) — the shared-layout-constraints guarantee;
//   * money and the "no balance" dash hug the SAME edge as their heading.
//     The old bug: `numericText` forces an LTR paragraph, so a
//     `textAlign: TextAlign.end` value hugged the right edge while the
//     ambient-RTL heading hugged the left — Total/Remaining visibly
//     drifted apart under Arabic;
//   * numeric values keep their LTR paragraph (grouped digits never
//     mirror) and the medium layout (no date column) stays aligned too.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/permission_helpers.dart';
import 'package:supermarket_pos/features/purchases/purchase_models.dart';
import 'package:supermarket_pos/features/purchases/purchases_providers.dart';
import 'package:supermarket_pos/features/purchases/purchases_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

class MockDio extends Mock implements Dio {}

Map<String, dynamic> _purchaseJson({
  required String id,
  required String invoice,
  String? supplierName,
  String total = '0.000',
  String paid = '0.000',
  String status = PurchaseStatusValue.received,
  String? purchaseDate = '2026-10-18T10:00:00Z',
}) =>
    {
      'id': id,
      'invoice_number': invoice,
      'status': status,
      'supplier_id': supplierName == null ? null : 's-1',
      'supplier_name': supplierName,
      'user_id': 'u-1',
      'subtotal': total,
      'discount': '0.000',
      'total': total,
      'paid': paid,
      'note': null,
      'device_id': null,
      'client_request_id': null,
      'purchase_date': purchaseDate,
      'received_at': null,
      'cancelled_at': null,
      'created_at': '2026-10-18T10:00:00Z',
      'updated_at': '2026-10-18T10:00:00Z',
      'lines': <dynamic>[],
      'idempotent_replay': false,
    };

/// Row 0: fully paid (remaining renders the '—' dash), with supplier and
/// date. Row 1: unpaid balance, NO supplier, no date.
List<Map<String, dynamic>> _listItems() => [
      _purchaseJson(
        id: 'po-1',
        invoice: 'PO-2026-0001',
        supplierName: 'Atlas',
        total: '12500.000',
        paid: '12500.000',
      ),
      _purchaseJson(
        id: 'po-2',
        invoice: 'PO-2026-0002',
        supplierName: null,
        total: '9800.500',
        paid: '0.000',
        status: PurchaseStatusValue.draft,
        purchaseDate: null,
      ),
    ];

void _stubList(MockDio dio) {
  when(() => dio.options).thenReturn(BaseOptions());
  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/purchases'),
        statusCode: 200,
        data: {
          'items': _listItems(),
          'total': 2,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      ));
  when(() => dio.get(any())).thenAnswer((invocation) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/purchases'),
        statusCode: 200,
        data: {
          'items': _listItems(),
          'total': 2,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      ));
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required TextDirection direction,
  required AppLocale locale,
  Size viewport = const Size(1366, 768),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final lang = locale.name;
  final dio = MockDio();
  _stubList(dio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesProvider
            .overrideWith((ref) => PurchasesNotifier(dio, () => lang)),
        hasPermissionProvider('purchase_view').overrideWithValue(true),
        hasPermissionProvider('purchase_create').overrideWithValue(true),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Directionality(
          textDirection: direction,
          child: const Scaffold(body: PurchasesScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The heading label of one column, scoped to the pinned header row (the
/// page's "Total: N" summary line also uses the `total` string).
Finder _heading(String labelKey, String lang) => find.descendant(
      of: find.byKey(const Key('purchases-table-header')),
      matching: find.text(AppStrings.t(labelKey, lang)),
    );

/// Header cell and data cell of column [i] must share one box — the
/// guarantee that every value is laid out under its own heading.
/// (Sub-pixel tolerance: the flex division 1318×flex/15 can land on
/// 1066.4 vs 1066.3999999999999 depending on accumulation order.)
void _expectSharedColumnBoxes(WidgetTester tester, {required int columns}) {
  for (var i = 0; i < columns; i++) {
    final header = tester.getRect(find.byKey(Key('purchases-header-cell-$i')));
    final cell = tester.getRect(find.byKey(Key('purchase-row-0-cell-$i')));
    expect(header.left, closeTo(cell.left, 0.01),
        reason: 'column $i: the heading drifted off its cells');
    expect(header.width, closeTo(cell.width, 0.01),
        reason: 'column $i: the heading is not the same width as its cells');
  }
}

/// A numeric value must hug the same edge of its (identical) column box
/// as its heading does — `labelKey` heading vs the keyed value cell.
void _expectValueUnderHeading(
  WidgetTester tester, {
  required String labelKey,
  required Key valueKey,
  required String lang,
  required TextDirection direction,
}) {
  final label = tester.getRect(_heading(labelKey, lang));
  final value = tester.getRect(find.byKey(valueKey));
  if (direction == TextDirection.rtl) {
    expect(value.left, closeTo(label.left, 0.01),
        reason: '$labelKey: the value must hug the same edge as its '
            'heading under RTL (the LTR-paragraph textAlign.end bug '
            'pushed it to the opposite edge)');
  } else {
    expect(value.right, closeTo(label.right, 0.01),
        reason: '$labelKey: the value must hug the same edge as its '
            'heading under LTR');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('purchases table column alignment', () {
    testWidgets(
        'RTL (ar): every column shares its heading box; money and the '
        'balance dash sit under Total / Remaining', (tester) async {
      await _pumpScreen(
        tester,
        direction: TextDirection.rtl,
        locale: AppLocale.ar,
      );

      expect(find.byKey(const Key('purchases-table-header')), findsOneWidget);
      expect(find.byKey(const Key('purchase-row-0')), findsOneWidget);
      expect(find.byKey(const Key('purchase-row-1')), findsOneWidget);

      // Wide layout: 6 columns (date included).
      _expectSharedColumnBoxes(tester, columns: 6);

      // Numeric content hugs the heading edge under RTL (left).
      _expectValueUnderHeading(
        tester,
        labelKey: 'total',
        valueKey: const Key('purchase-total-0'),
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      // Row 0 is fully paid: the '—' dash must align exactly like money.
      _expectValueUnderHeading(
        tester,
        labelKey: 'remaining',
        valueKey: const Key('purchase-remaining-0'),
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      // Row 1 shows a real unpaid amount (red) — same edge, same column.
      _expectValueUnderHeading(
        tester,
        labelKey: 'remaining',
        valueKey: const Key('purchase-remaining-1'),
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      _expectValueUnderHeading(
        tester,
        labelKey: 'date',
        valueKey: const Key('purchase-date-0'),
        lang: 'ar',
        direction: TextDirection.rtl,
      );

      // Text columns hug the leading edge (right under RTL) together.
      final invoiceLabel =
          tester.getRect(_heading('invoice_number', 'ar'));
      final invoice = tester.getRect(find.byKey(const Key('purchase-invoice-0')));
      expect(invoice.right, closeTo(invoiceLabel.right, 0.01));

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'LTR (en): every column shares its heading box; money stays under '
        'its heading', (tester) async {
      await _pumpScreen(
        tester,
        direction: TextDirection.ltr,
        locale: AppLocale.en,
      );

      expect(find.byKey(const Key('purchases-table-header')), findsOneWidget);
      _expectSharedColumnBoxes(tester, columns: 6);

      _expectValueUnderHeading(
        tester,
        labelKey: 'total',
        valueKey: const Key('purchase-total-0'),
        lang: 'en',
        direction: TextDirection.ltr,
      );
      _expectValueUnderHeading(
        tester,
        labelKey: 'remaining',
        valueKey: const Key('purchase-remaining-0'),
        lang: 'en',
        direction: TextDirection.ltr,
      );
      _expectValueUnderHeading(
        tester,
        labelKey: 'remaining',
        valueKey: const Key('purchase-remaining-1'),
        lang: 'en',
        direction: TextDirection.ltr,
      );

      // Text columns start together under LTR.
      final invoiceLabel =
          tester.getRect(_heading('invoice_number', 'en'));
      final invoice = tester.getRect(find.byKey(const Key('purchase-invoice-0')));
      expect(invoice.left, closeTo(invoiceLabel.left, 0.01));

      // Optional supplier still renders its placeholder in the table.
      expect(find.text(AppStrings.t('no_supplier', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('medium viewport: the 5-column layout stays aligned '
        '(date column dropped)', (tester) async {
      await _pumpScreen(
        tester,
        direction: TextDirection.rtl,
        locale: AppLocale.ar,
        viewport: const Size(1024, 768),
      );

      expect(find.byKey(const Key('purchases-table-header')), findsOneWidget);
      expect(find.byKey(const Key('purchase-date-0')), findsNothing);
      expect(find.byKey(const Key('purchase-row-0-cell-5')), findsNothing);

      _expectSharedColumnBoxes(tester, columns: 5);
      _expectValueUnderHeading(
        tester,
        labelKey: 'total',
        valueKey: const Key('purchase-total-0'),
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('numeric values keep an LTR paragraph under RTL '
        '(grouped digits never mirror)', (tester) async {
      await _pumpScreen(
        tester,
        direction: TextDirection.rtl,
        locale: AppLocale.ar,
      );

      for (final key in const [
        Key('purchase-total-0'),
        Key('purchase-remaining-1'),
      ]) {
        final value = tester.widget<Text>(find.byKey(key));
        expect(value.textDirection, TextDirection.ltr,
            reason: '$key must keep the numericText LTR paragraph');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow viewport still renders the tile list', (tester) async {
      await _pumpScreen(
        tester,
        direction: TextDirection.rtl,
        locale: AppLocale.ar,
        viewport: const Size(600, 800),
      );

      expect(find.byKey(const Key('purchases-list')), findsOneWidget);
      expect(find.byKey(const Key('purchase-tile-0')), findsOneWidget);
      expect(find.byKey(const Key('purchases-table-header')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
