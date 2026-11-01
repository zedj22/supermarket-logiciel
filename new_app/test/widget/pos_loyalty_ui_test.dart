// The loyalty rows in the payment dialog (reward redesign).
//
// Contract under test (client side only; the server owns all numbers):
//  - when the POS loyalty session holds a preview that matches the CURRENT
//    cart + selected reward percent, the dialog shows the reward discount
//    (percent + money) and the amount due (= total − discount); the paid
//    field always starts EMPTY — the cashier enters the amount received
//    (the amount due is shown, never typed in for them);
//  - submitting sends `loyalty_reward_percent` as the selected percent
//    and `paid` as the amount due (cash settles the amount due once the
//    entered amount covers it);
//  - with no matching preview the dialog is bit-for-bit the pre-loyalty
//    one (no rows, empty paid field, no loyalty key in the payload).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_models.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_providers.dart';
import 'package:supermarket_pos/features/pos/payment_dialog.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const _customerId = '11111111-1111-1111-1111-111111111111';

const _balanceJson = <String, Object>{
  'customer_id': _customerId,
  'has_account': true,
  'points_balance': '130.000',
  'cashback_balance': '0.000',
  'available_rewards': 1,
  'remaining_points': '30.000',
};

const _saleJson = <String, Object>{
  'id': 'sale-1',
  'invoice_number': 'INV-001',
  'status': 'completed',
  'subtotal': '100.00',
  'discount': '0',
  'total': '100.00',
  'paid': '80.00',
  'change': '0',
  'debt': '0',
  'payment_method': 'cash',
  'idempotent_replay': false,
  'price_overrides': <Object>[],
  'amount_due': '80.000',
  'loyalty_points_earned': '0',
  'loyalty_cashback_earned': '0.000',
  'loyalty_points_redeemed': '100',
  'loyalty_redeemed_value': '20.000',
};

/// A backend stand-in: loyalty balance, preview (echoing the request) and
/// checkout all answer in-process; every request is recorded for payload
/// assertions.
FakeJsonAdapter _adapter({List<Map<String, Object>>? salePayloads}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (path.endsWith('/loyalty/preview')) {
      final data = options.data as Map<String, dynamic>;
      final gross = double.parse('${data['gross_total']}');
      final percent = ((data['reward_percent'] as num?) ?? 0).toDouble();
      final discount = gross * percent / 100;
      return (
        statusCode: 200,
        body: <String, Object>{
          'customer_id': _customerId,
          'gross_total': data['gross_total'] as String,
          'reward_percent': percent,
          'reward_discount': discount.toStringAsFixed(3),
          'amount_due': (gross - discount).toStringAsFixed(3),
          'available_rewards': 1,
          'remaining_points': '30.000',
          'max_reward_discount_percent': '20.000',
          'points_balance': '130.000',
          'cashback_balance': '0.000',
          'points_earned': '0.800',
          'cashback_earned': '0.000',
        },
      );
    }
    if (path.endsWith('/sales')) {
      salePayloads?.add(Map<String, Object>.from(options.data as Map));
      return (statusCode: 201, body: _saleJson);
    }
    // Loyalty balance.
    return (statusCode: 200, body: _balanceJson);
  });
}

const AuthUser _cashier = AuthUser(
  id: 'u-1',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: ['cashier'],
  permissions: <String>[],
);

/// Test seam: [PosLoyaltyNotifier.state] is @protected, so seeding a
/// snapshot without round-tripping through Dio needs a subclass. The
/// seeded state is exactly what the real notifier API would produce for
/// a matching preview (see pos_loyalty_lookup_test.dart).
class _SeededLoyaltyNotifier extends PosLoyaltyNotifier {
  _SeededLoyaltyNotifier(super.dio, super.localeCode);

  void seed(PosLoyaltyState value) => state = value;
}

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
List<Override> _seededOverrides(
  FakeJsonAdapter adapter, {
  required bool withPreview,
}) {
  final dio = fakeDio(adapter);
  final cart = PosCartNotifier(dio, () => 'en', () async => 'device-test');
  cart.addLine(const CartLine(
    productId: 'p1',
    name: 'Bread',
    quantity: '1',
    unitPrice: '100',
  ));
  cart.setCustomer(const PosCustomer(
    id: _customerId,
    name: 'Loyal Alice',
  ));

  final loyalty = _SeededLoyaltyNotifier(dio, () => 'en');
  final balance = LoyaltyBalance.fromJson(_balanceJson);
  if (withPreview) {
    // Exactly the snapshot `previewNow()` produces for total=100 /
    // reward percent=20 (cap 20) — `previewMatches` holds.
    loyalty.seed(PosLoyaltyState(
      customerId: _customerId,
      balance: balance,
      preview: const LoyaltyPreview(
        customerId: _customerId,
        grossTotal: 100,
        rewardPercent: 20,
        rewardDiscount: 20,
        amountDue: 80,
        availableRewards: 1,
        remainingPoints: 30,
        minRewardPoints: 100,
        rewardEligible: true,
        maxRewardDiscountPercent: 20,
        pointsBalance: 130,
        cashbackBalance: 0,
        pointsEarned: 0.8,
        cashbackEarned: 0,
        pointsAfterSale: 130.8,
      ),
      rewardPercent: 20,
      cartTotal: 100,
    ));
  } else {
    // Customer attached, balances loaded, NO reward selected — the plain
    // cashier flow.
    loyalty.seed(PosLoyaltyState(
      customerId: _customerId,
      balance: balance,
      cartTotal: 100,
    ));
  }

  return [
    posCartProvider.overrideWith((ref) => cart),
    posLoyaltyProvider.overrideWith((ref) => loyalty),
    currentUserProvider.overrideWithValue(_cashier),
    localeProvider.overrideWith(
      (ref) => LocaleNotifier()..setLocale(AppLocale.en),
    ),
  ];
}

void main() {
  Future<void> pumpHarness(
    WidgetTester tester,
    List<Override> overrides,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const _PaymentHarness(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-payment')));
    await tester.pumpAndSettle();
  }

  group('PaymentDialog — loyalty reward', () {
    testWidgets(
        'shows reward discount + amount-due rows and keeps the paid field '
        'empty for the cashier to fill in', (tester) async {
      final adapter = _adapter();
      await pumpHarness(tester, _seededOverrides(adapter, withPreview: true));

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(find.byKey(const Key('payment-loyalty-redeemed')), findsOneWidget);
      expect(find.byKey(const Key('payment-amount-due')), findsOneWidget);
      // 100.00 total − 20.00 reward discount = 80 due.
      expect(find.text('80.00'), findsWidgets);

      final paidField = tester.widget<TextField>(
        find.byKey(const Key('payment-paid-input')),
      );
      expect(paidField.controller!.text, isEmpty,
          reason: 'the amount received is typed in, never pre-filled — '
              'not the total, not the amount due, not 0');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'submit sends the reward percent + the amount due to /sales',
        (tester) async {
      final salePayloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: salePayloads);
      await pumpHarness(tester, _seededOverrides(adapter, withPreview: true));

      await tester.enterText(
        find.byKey(const Key('payment-paid-input')),
        '80.00',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(salePayloads, hasLength(1));
      final body = salePayloads.single;
      expect(body['loyalty_reward_percent'], 20);
      expect(body['loyalty_reward_percent'], isA<num>());
      expect(body['paid'], '80.00');
      // No points, monetary value, or balance ever travels up.
      expect(body.keys, isNot(contains('loyalty_redeem_points')));
      expect(body.keys, isNot(contains('loyalty_redeemed_value')));
      expect(body.keys, isNot(contains('points_balance')));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'without a matching preview the dialog stays the pre-loyalty one',
        (tester) async {
      final salePayloads = <Map<String, Object>>[];
      final adapter = _adapter(salePayloads: salePayloads);
      await pumpHarness(tester, _seededOverrides(adapter, withPreview: false));

      expect(find.byKey(const Key('payment-loyalty-redeemed')), findsNothing);
      expect(find.byKey(const Key('payment-amount-due')), findsNothing);

      final paidField = tester.widget<TextField>(
        find.byKey(const Key('payment-paid-input')),
      );
      expect(paidField.controller!.text, isEmpty,
          reason: 'no reward means no amount-due row either — still no '
              'pre-filled total');

      await tester.enterText(
        find.byKey(const Key('payment-paid-input')),
        '100.00',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle();

      expect(salePayloads, hasLength(1));
      final body = salePayloads.single;
      expect(body.keys, isNot(contains('loyalty_reward_percent')));
      expect(body['paid'], '100.00');
      expect(tester.takeException(), isNull);
    });
  });
}
