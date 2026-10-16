// Purchase line dialog — per-line "Total cost" mode + live preview.
//
// Contract:
// - checkbox OFF: typed cost is the per-document-unit cost (existing
//   behavior preserved);
// - checkbox ON: typed cost is the line TOTAL; the dialog derives the
//   per-unit cost, previews it live, and stages the canonical per-unit
//   cost on save (the checkbox itself is never persisted);
// - box lines convert through the purchase-unit multiplier, previewing
//   the base-quantity equivalent and the base-unit cost;
// - the preview is informational only — no API write happens on typing.
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
import 'package:supermarket_pos/features/purchases/purchase_line_dialog.dart';
import 'package:supermarket_pos/features/purchases/purchase_models.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => true;

  @override
  Future<String?> readToken() async => 'tok';

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => ['admin'];

  @override
  Future<List<String>> readUserPermissions() async => [];

  @override
  Future<void> clearAll() async {}
}

Map<String, dynamic> _boxUnitJson({String multiplier = '5'}) => {
      'id': 'unit-box',
      'product_id': 'prod-1',
      'name': 'Box',
      'unit_type': 'piece',
      'multiplier': multiplier,
      'barcode': null,
      'is_default': false,
      'is_archived': false,
      'full_packages': null,
      'base_equivalent_available': null,
    };

void _stubChoices(MockDio dio) {
  Response<dynamic> ok(String path, Object? data) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path.endsWith('/variants')) {
      return ok(path, {'items': <dynamic>[], 'total': 0});
    }
    if (path.endsWith('/purchase-units')) {
      return ok(path, {'items': [_boxUnitJson()], 'total': 1});
    }
    return ok(path, {'items': <dynamic>[], 'total': 0});
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return ok(path, {'items': <dynamic>[], 'total': 0});
  });
}

DraftLine? _staged;

/// Money segment in the summary text: the dialog wraps each amount +
/// currency suffix in a zero-width LRI/PDI isolate so it renders as one
/// LTR unit inside the mixed-direction sentence (see numeric_text.dart).
String _m(String money) => bidiIsolateLtr(money);

DraftLine _initialLine() => const DraftLine(
      productId: 'prod-1',
      productName: 'Lait',
      quantity: '',
      unitCost: '',
    );

Future<void> _pumpDialog(
  WidgetTester tester, {
  TextDirection direction = TextDirection.ltr,
}) async {
  final dio = MockDio();
  _stubChoices(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        // Explicit host Directionality so the RTL case exercises the real
        // Arabic layout path regardless of the (en) content locale.
        home: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () {
                  showPurchaseLineDialog(context, initial: _initialLine()).then(
                    (value) => _staged = value,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _staged = null;
  await tester.tap(find.byKey(const Key('open-dialog')));
  await tester.pumpAndSettle();
}

/// Box-level bidi proof: the isolated [money] segment inside [text] must
/// be laid out in logical left-to-right order — first digit box left of
/// the last digit box, and the last digit left of `DA` when present. The
/// Ahem test font still runs the real ICU bidi algorithm — this is
/// genuine glyph placement, not a golden screenshot.
bool _moneySegmentOrderOk(RenderParagraph paragraph, String text, String money) {
  double? leftOf(int base, int extent) => paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: base, extentOffset: extent),
      )
      .first
      .left;
  final start = text.indexOf(money);
  if (start < 0) return false;
  final digits = RegExp('[0-9]').allMatches(money).toList();
  final first = leftOf(start + digits.first.start, start + digits.first.start + 1)!;
  final last = leftOf(start + digits.last.start, start + digits.last.start + 1)!;
  if (first > last) return false;
  final daAt = money.lastIndexOf(' DA');
  if (daAt >= 0) {
    final da = leftOf(start + daAt + 1, start + daAt + 3)!;
    if (last > da) return false;
  }
  return true;
}

/// Selects the "Box ×5" purchase unit in the dropdown.
Future<void> _selectBox(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('purchase-line-unit')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Box ×5').last);
  await tester.pumpAndSettle();
}

Future<DraftLine?> _submit(WidgetTester tester) async {
  _staged = null;
  await tester.tap(find.byKey(const Key('purchase-line-submit')));
  await tester.pumpAndSettle();
  return _staged;
}

void main() {
  testWidgets(
      'mode OFF: 10 pieces at 100 keeps 100 per piece and stages it',
      (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.pump();

    expect(
      find.text('Unit cost: ${_m('100 DA')} · '
          'Line total: ${_m('1 000 DA')}'),
      findsOneWidget,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.quantity, '10');
    expect(line.unitCost, '100');
    expect(line.multiplier, isNull);
  });

  testWidgets('mode ON: 10 pieces at total 100 derives 10 per piece',
      (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();

    expect(
      find.text('Unit cost: ${_m('10 DA')} · Line total: ${_m('100 DA')}'),
      findsOneWidget,
    );
    // The cost field relabels to the total interpretation.
    expect(
      find.text(AppStrings.t('purchase_total_cost', 'en')),
      findsWidgets,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.quantity, '10');
    expect(line.unitCost, '10.000');
  });

  testWidgets(
      'mode ON with boxes: 10 boxes × 5 at total 100 → 2 per base piece',
      (tester) async {
    await _pumpDialog(tester);
    await _selectBox(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();

    expect(
      find.text('Total quantity: ${_m('50')} Piece · '
          'Unit cost: ${_m('2 DA')} · Line total: ${_m('100 DA')}'),
      findsOneWidget,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.quantity, '10');
    // Canonical stored cost is PER BOX (100 ÷ 10 boxes), never the
    // base-piece cost — the server divides by the multiplier on receive.
    expect(line.unitCost, '10.000');
    expect(line.multiplier, '5');
    expect(line.purchaseUnitId, 'unit-box');
  });

  testWidgets(
      'mode OFF with boxes: 100 per box stays 100 per box, 20 per piece',
      (tester) async {
    await _pumpDialog(tester);
    await _selectBox(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.pump();

    expect(
      find.text('Total quantity: ${_m('50')} Piece · '
          'Unit cost: ${_m('20 DA')} · Line total: ${_m('1 000 DA')}'),
      findsOneWidget,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.unitCost, '100');
  });

  testWidgets('preview updates live when quantity changes (total mode)',
      (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();
    expect(
      find.text('Unit cost: ${_m('10 DA')} · Line total: ${_m('100 DA')}'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '20');
    await tester.pump();
    expect(
      find.text('Unit cost: ${_m('5 DA')} · Line total: ${_m('100 DA')}'),
      findsOneWidget,
    );
  });

  testWidgets('preview updates live when the toggle flips', (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '10');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.pump();
    expect(
      find.text('Unit cost: ${_m('100 DA')} · Line total: ${_m('1 000 DA')}'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();
    expect(
      find.text('Unit cost: ${_m('10 DA')} · Line total: ${_m('100 DA')}'),
      findsOneWidget,
    );
  });

  testWidgets('zero quantity in total mode is rejected through validation',
      (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '0');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();

    // No preview is shown for a zero quantity (no division happens).
    expect(find.byKey(const Key('purchase-line-total')), findsNothing);

    await tester.tap(find.byKey(const Key('purchase-line-submit')));
    await tester.pump();
    expect(
      find.text(AppStrings.t('invalid_qty', 'en')),
      findsOneWidget,
    );
    // Dialog stays open — nothing was staged.
    expect(find.byKey(const Key('purchase-line-dialog')), findsOneWidget);
  });

  testWidgets('rounding follows thousandths half-up (100 over 3)',
      (tester) async {
    await _pumpDialog(tester);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '3');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '100');
    await tester.tap(find.byKey(const Key('purchase-line-total-cost-toggle')));
    await tester.pump();

    expect(
      find.text('Unit cost: ${_m('33.333 DA')} · '
          'Line total: ${_m('99.999 DA')}'),
      findsOneWidget,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.unitCost, '33.333');
  });

  testWidgets(
      'RTL: qty 2 at 1 000 DA keeps "1 000 DA" and "2 000 DA" in visual '
      'order (Windows screenshot A acceptance)', (tester) async {
    await _pumpDialog(tester, direction: TextDirection.rtl);
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '2');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '1000');
    await tester.pump();

    final expected =
        'Unit cost: ${_m('1 000 DA')} · Line total: ${_m('2 000 DA')}';
    final summary = tester.widget<Text>(
      find.byKey(const Key('purchase-line-total')),
    );
    expect(summary.data, expected);
    // The sentence is a NATURAL RTL paragraph (labels keep RTL order);
    // only the isolated money segments are LTR units.
    expect(summary.textDirection, isNull);

    final paragraph = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('purchase-line-total')),
    );
    expect(
      _moneySegmentOrderOk(paragraph, expected, '1 000 DA'),
      isTrue,
      reason: 'unit cost must render 1 000 DA in order under RTL',
    );
    expect(
      _moneySegmentOrderOk(paragraph, expected, '2 000 DA'),
      isTrue,
      reason: 'line total must render 2 000 DA in order under RTL '
          '(the screenshot bug)',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'RTL counter-proof detector: without isolates an Arabic summary '
      'reverses its groups (proves the box detector is not vacuous)',
      (tester) async {
    // The screenshots run under the Arabic locale: an Arabic label
    // precedes the amount, so bidi rule W7 flips the EN digits into RTL
    // runs and the groups reverse. (Latin labels do NOT trigger W7 — the
    // flip needs a strong RTL character before the number.)
    const broken = 'إجمالي السطر: 2 000 DA · تكلفة الوحدة: 1 000 DA';
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: const Text(broken),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.byType(Text));
    expect(
      _moneySegmentOrderOk(paragraph, broken, '2 000 DA'),
      isFalse,
      reason: 'unisolated mixed Arabic text under RTL must reproduce the '
          'reordered-groups bug',
    );
    expect(
      _moneySegmentOrderOk(paragraph, broken, '1 000 DA'),
      isFalse,
      reason: 'the unit-cost segment reverses too',
    );
  });
}
