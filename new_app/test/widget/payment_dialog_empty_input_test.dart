// Payment dialog — "Paid by Customer" ALWAYS starts empty.
//
// Contract under test (client side only; the server owns all numbers):
//  - opening the dialog (Pay button) leaves the paid field EMPTY; the
//    invoice total stays visible in the totals summary;
//  - no code path (open, method switch, cart rebuild, reopen) ever
//    pre-fills the invoice total (or the amount due) into the field;
//  - an empty field parses as 0 and is REJECTED by the existing per-
//    method validation (cash: paid_too_low, card/partial: invalid_amount)
//    — it is never an implicit full payment and never submits a sale;
//  - once the cashier types an amount, full / over / partial payment
//    math works exactly as before: cash settles the amount due (the
//    overpayment is the change shown), partial sends the entered amount
//    and shows the remaining debt, card demands the exact due, credit
//    sends 0 with the field hidden;
//  - switching payment methods and rebuilding the dialog never
//    populate the field.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_providers.dart';
import 'package:supermarket_pos/features/pos/payment_dialog.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const _customerId = '11111111-1111-1111-1111-111111111111';

const _saleJson = <String, Object>{
  'id': 'sale-1',
  'invoice_number': 'INV-001',
  'status': 'completed',
  'subtotal': '100.00',
  'discount': '0',
  'total': '100.00',
  'paid': '100.00',
  'change': '0',
  'debt': '0',
  'payment_method': 'cash',
  'idempotent_replay': false,
  'price_overrides': <Object>[],
  'amount_due': '100.000',
  'loyalty_points_earned': '0',
  'loyalty_cashback_earned': '0.000',
  'loyalty_points_redeemed': '0',
  'loyalty_redeemed_value': '0.000',
};

/// A backend stand-in: checkout answers in-process and every /sales body
/// is recorded for payload assertions.
FakeJsonAdapter _adapter({List<Map<String, Object>>? salePayloads}) {
  return FakeJsonAdapter((options) async {
    if (options.path.endsWith('/sales')) {
      salePayloads?.add(Map<String, Object>.from(options.data as Map));
      return (statusCode: 201, body: _saleJson);
    }
    return (statusCode: 200, body: <String, Object>{});
  });
}

const AuthUser _cashier = AuthUser(
  id: 'u-1',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: ['cashier'],
  permissions: <String>['pos_credit_sale', 'pos_discount'],
);

class _PaymentHarness extends StatelessWidget {
  const _PaymentHarness();

  @override
  Widget build(BuildContext context) {
    // The Builder sits BELOW MaterialApp so the tap handler's context has
    // MaterialLocalizations for showDialog.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-payment'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const PaymentDialog(),
              ),
              child: const Text('Pay'),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cart + loyalty notifiers against [adapter], seeded synchronously, plus
/// the provider overrides that hand the SEEDED instances to the tree.
///
/// The cart holds one Bread line of 100.00 (with an attached customer so
/// partial/credit stay reachable); [invoiceDiscount] is applied before the
/// dialog opens when given.
List<Override> _overrides(
  FakeJsonAdapter adapter, {
  double? invoiceDiscount,
}) {
  final dio = fakeDio(adapter);
  final cart = PosCartNotifier(dio, () => 'en', () async => 'device-test');
  cart.addLine(const CartLine(
    productId: 'p1',
    name: 'Bread',
    quantity: '1',
    unitPrice: '100',
  ));
  if (invoiceDiscount != null) {
    cart.setInvoiceDiscount('$invoiceDiscount');
  }
  cart.setCustomer(const PosCustomer(
    id: _customerId,
    name: 'Alice',
  ));

  return [
    posCartProvider.overrideWith((ref) => cart),
    posLoyaltyProvider.overrideWith(
      (ref) => PosLoyaltyNotifier(dio, () => 'en'),
    ),
    currentUserProvider.overrideWithValue(_cashier),
    localeProvider.overrideWith(
      (ref) => LocaleNotifier()..setLocale(AppLocale.en),
    ),
  ];
}

void main() {
  Future<void> pumpHarness(
    WidgetTester tester,
    List<Override> overrides, {
    bool openDialog = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const _PaymentHarness(),
      ),
    );
    await tester.pumpAndSettle();
    if (openDialog) {
      await tester.tap(find.byKey(const Key('open-payment')));
      await tester.pumpAndSettle();
    }
  }

  String paidText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('payment-paid-input')))
      .controller!
      .text;

  Future<void> enterPaid(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('payment-paid-input')), text);
    await tester.pump();
  }

  Future<void> selectMethod(WidgetTester tester, PaymentMethod m) async {
    await tester.tap(find.byKey(Key('payment-method-${m.apiValue}')));
    await tester.pumpAndSettle();
  }

  void expectNoSale(List<Map<String, Object>> payloads) =>
      expect(payloads, isEmpty, reason: 'no sale may be posted');

  group('PaymentDialog — paid field starts empty', () {
    testWidgets('opens empty; the invoice total stays visible', (
      tester,
    ) async {
      final adapter = _adapter();
      await pumpHarness(tester, _overrides(adapter));

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(paidText(tester), isEmpty,
          reason: 'the amount received is typed in, never pre-filled');

      // The invoice total is still right there in the summary.
      expect(find.text('100.00'), findsWidgets);
      expect(
        find.text(AppStrings.t('total_label', 'en')),
        findsOneWidget,
      );

      // Autofocus lands on the empty paid field (keyboard/scanner ready).
      final context = FocusManager.instance.primaryFocus?.context;
      final field = context?.widget is TextField
          ? context!.widget as TextField
          : context?.findAncestorWidgetOfExactType<TextField>();
      expect(field?.key, const Key('payment-paid-input'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty input never triggers a full payment', (tester) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('paid_too_low', 'en')),
        findsOneWidget,
      );
      expectNoSale(payloads);
      expect(paidText(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clearing the input restores the empty state', (
      tester,
    ) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));

      await enterPaid(tester, '150');
      expect(find.text('50.00'), findsOneWidget,
          reason: 'overpayment shows as change');

      await enterPaid(tester, '');
      expect(paidText(tester), isEmpty);
      expect(find.text('0.00'), findsOneWidget,
          reason: 'change returns to 0 — no assumed payment');

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('paid_too_low', 'en')), findsOneWidget);
      expectNoSale(payloads);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reopening the dialog does not restore the previous '
        'amount', (tester) async {
      final adapter = _adapter();
      await pumpHarness(tester, _overrides(adapter));

      await enterPaid(tester, '100.00');
      await tester.tap(find.byKey(const Key('payment-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);

      await tester.tap(find.byKey(const Key('open-payment')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(paidText(tester), isEmpty,
          reason: 'a fresh dialog always starts empty');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cart rebuild while the dialog is open never '
        'repopulates the field', (tester) async {
      final adapter = _adapter();
      final overrides = _overrides(adapter);
      await pumpHarness(tester, overrides, openDialog: false);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('open-payment'))),
        listen: false,
      );

      await tester.tap(find.byKey(const Key('open-payment')));
      await tester.pumpAndSettle();
      expect(paidText(tester), isEmpty);

      // A live cart mutation rebuilds the dialog (it watches the cart):
      // totals update, the field stays empty.
      container.read(posCartProvider.notifier).addLine(const CartLine(
            productId: 'p2',
            name: 'Milk',
            quantity: '1',
            unitPrice: '50',
          ));
      await tester.pumpAndSettle();
      expect(paidText(tester), isEmpty);
      expect(find.text('150.00'), findsWidgets,
          reason: 'the rebuilt totals summary shows the new total');
      expect(tester.takeException(), isNull);
    });
  });

  group('PaymentDialog — full / over / partial payment math', () {
    testWidgets('exact total: full payment works, change 0.00', (
      tester,
    ) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));

      await enterPaid(tester, '100');
      expect(find.text('0.00'), findsOneWidget,
          reason: 'exact payment → no change');

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      final body = payloads.single;
      expect(body['payment_method'], 'cash');
      expect(body['paid'], '100.00',
          reason: 'cash settles the amount due');
      expect(tester.takeException(), isNull);
    });

    testWidgets('overpayment: change is calculated, sale still settles '
        'the amount due', (tester) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));

      await enterPaid(tester, '150');
      expect(find.text('50.00'), findsOneWidget,
          reason: '150 tendered − 100 due = 50 change');

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      expect(payloads.single['paid'], '100.00',
          reason: 'the overpayment is change, never a larger paid');
      expect(tester.takeException(), isNull);
    });

    testWidgets('underpayment in cash is rejected — no change, no sale', (
      tester,
    ) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));

      await enterPaid(tester, '40');
      expect(find.text('0.00'), findsOneWidget,
          reason: 'a short amount is never change');

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('paid_too_low', 'en')), findsOneWidget);
      expectNoSale(payloads);
      expect(tester.takeException(), isNull);
    });
  });

  group('PaymentDialog — payment methods never populate the field', () {
    testWidgets('switching cash → card → partial → credit keeps it empty', (
      tester,
    ) async {
      final adapter = _adapter();
      await pumpHarness(tester, _overrides(adapter));
      expect(paidText(tester), isEmpty);

      await selectMethod(tester, PaymentMethod.card);
      expect(paidText(tester), isEmpty,
          reason: 'card never inherits or invents an amount');

      await selectMethod(tester, PaymentMethod.partial);
      expect(paidText(tester), isEmpty);

      await selectMethod(tester, PaymentMethod.credit);
      expect(find.byKey(const Key('payment-paid-input')), findsNothing,
          reason: 'credit hides the field entirely');

      await selectMethod(tester, PaymentMethod.cash);
      expect(paidText(tester), isEmpty,
          reason: 'returning to cash is still empty');
      expect(tester.takeException(), isNull);
    });

    testWidgets('card: empty and mismatched amounts are rejected, the '
        'exact due settles', (tester) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));
      await selectMethod(tester, PaymentMethod.card);

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.t('invalid_amount', 'en')), findsOneWidget);
      expectNoSale(payloads);

      await enterPaid(tester, '99');
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.t('invalid_amount', 'en')), findsOneWidget);
      expectNoSale(payloads);

      await enterPaid(tester, '100.00');
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      expect(payloads.single['payment_method'], 'card');
      expect(payloads.single['paid'], '100.00');
      expect(tester.takeException(), isNull);
    });

    testWidgets('partial: empty rejected; entered amount drives paid + '
        'remaining debt', (tester) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));
      await selectMethod(tester, PaymentMethod.partial);

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('invalid_amount', 'en')), findsOneWidget);
      expectNoSale(payloads);

      await enterPaid(tester, '40');
      expect(find.text('60.00'), findsOneWidget,
          reason: 'remaining debt = 100 due − 40 paid');

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      expect(payloads.single['payment_method'], 'partial');
      expect(payloads.single['paid'], '40.00');
      expect(tester.takeException(), isNull);
    });

    testWidgets('credit: field hidden, nothing typed, paid 0.00 settles', (
      tester,
    ) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(tester, _overrides(adapter));
      await selectMethod(tester, PaymentMethod.credit);

      expect(find.byKey(const Key('payment-paid-input')), findsNothing);

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      expect(payloads.single['payment_method'], 'credit');
      expect(payloads.single['paid'], '0.00');
      expect(tester.takeException(), isNull);
    });
  });

  group('PaymentDialog — invoice discount regression', () {
    testWidgets('the discounted total is what the empty field must '
        'cover', (tester) async {
      final payloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: payloads);
      await pumpHarness(
        tester,
        _overrides(adapter, invoiceDiscount: 10),
      );

      expect(paidText(tester), isEmpty);
      // 100 subtotal − 10 invoice discount.
      expect(find.text('90.00'), findsWidgets,
          reason: 'the discounted total stays visible');

      await enterPaid(tester, '100');
      expect(find.text('10.00'), findsOneWidget,
          reason: 'change against the DISCOUNTED due');

      await enterPaid(tester, '90');
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(payloads, hasLength(1));
      expect(payloads.single['paid'], '90.00');
      expect(tester.takeException(), isNull);
    });
  });
}
