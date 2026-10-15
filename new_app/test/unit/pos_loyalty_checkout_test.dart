// Checkout payload contract — loyalty reward plumbing (reward redesign).
//
// Contract under test (client side only; the server is the authority):
//  - `checkout` sends `loyalty_reward_percent` as the PERCENT the cashier
//    selected (never points, never a monetary value, never a claimed
//    balance) and only when > 0, so a non-loyalty checkout payload stays
//    byte-identical to one without a reward;
//  - the additive loyalty summary fields on the response parse into
//    `CheckoutResult` (null on legacy responses).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

Map<String, dynamic> _successBody() => {
      'id': 'sale-1',
      'invoice_number': 'INV-001',
      'status': 'completed',
      'subtotal': '100.00',
      'discount': '0',
      'total': '100.00',
      'paid': '40.00',
      'change': '0',
      'debt': '0',
      'payment_method': 'cash',
      'idempotent_replay': false,
      'price_overrides': <dynamic>[],
      'amount_due': '80.000',
      'loyalty_points_earned': '0',
      'loyalty_cashback_earned': '0.000',
      'loyalty_points_redeemed': '100',
      'loyalty_redeemed_value': '20.000',
    };

/// Notifier whose Dio resolves every request in-process, capturing bodies.
(PosCartNotifier, List<Map<String, dynamic>>) _notifierWithCapture() {
  final captured = <Map<String, dynamic>>[];
  final dio = Dio()..options.baseUrl = 'http://test';
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        captured.add(Map<String, dynamic>.from(options.data as Map));
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 201,
            data: _successBody(),
          ),
        );
      },
    ),
  );
  final notifier = PosCartNotifier(dio, () => 'en', () async => 'pos-test');
  return (notifier, captured);
}

PosCustomer _customer() => PosCustomer.fromJson({
      'id': '11111111-1111-1111-1111-111111111111',
      'name': 'Loyal Alice',
      'phone': null,
      'balance': '0',
      'is_archived': false,
    });

void main() {
  group('checkout payload — loyalty_reward_percent', () {
    test('omitted entirely when no reward is selected', () async {
      final (notifier, captured) = _notifierWithCapture();
      notifier.addLine(CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '1',
        unitPrice: '100',
      ));
      notifier.setCustomer(_customer());

      final result =
          await notifier.checkout(method: PaymentMethod.cash, paid: 100);

      expect(result, isNotNull);
      expect(captured, hasLength(1));
      expect(captured.single.keys, isNot(contains('loyalty_reward_percent')));
      // Legacy payload keys are untouched when no reward is used.
      expect(captured.single.keys, containsAll([
        'client_request_id',
        'payment_method',
        'paid',
        'items',
        'customer_id',
        'device_id',
      ]));
    });

    test('carries the selected percent when a reward is applied', () async {
      final (notifier, captured) = _notifierWithCapture();
      notifier.addLine(CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '1',
        unitPrice: '100',
      ));
      notifier.setCustomer(_customer());

      final result = await notifier.checkout(
        method: PaymentMethod.cash,
        paid: 80,
        loyaltyRewardPercent: 20,
      );

      expect(result, isNotNull);
      expect(captured.single['loyalty_reward_percent'], 20);
      expect(captured.single['loyalty_reward_percent'], isA<num>());
      // Percent only — never points, a monetary value, or a balance.
      expect(captured.single.keys, isNot(contains('loyalty_redeem_points')));
      expect(captured.single.keys, isNot(contains('loyalty_redeemed_value')));
      expect(captured.single.keys, isNot(contains('points_balance')));
      // The response summary parsed through.
      expect(result!.amountDue, '80.000');
      expect(result.loyaltyPointsRedeemed, '100');
      expect(result.loyaltyRedeemedValue, '20.000');
      expect(result.loyaltyPointsEarned, '0');
      expect(result.loyaltyCashbackEarned, '0.000');
    });
  });
}
