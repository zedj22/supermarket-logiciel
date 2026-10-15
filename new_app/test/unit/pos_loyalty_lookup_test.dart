// QR routing + POS loyalty session state machine (reward redesign).
//
// Contract under test (client side only; the server owns all numbers):
//  - `CustomerSearchNotifier` routes a `KLICK:C:` payload to the loyalty
//    lookup and everything else to the plain customer search;
//  - `PosLoyaltyNotifier` keeps balance/preview strictly tied to the
//    currently attached customer + current cart total + selected reward
//    percent (stale answers are discarded, predictable-422 spam above a
//    known cap is suppressed, detaching a customer wipes the session).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_providers.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

const _customerId = '11111111-1111-1111-1111-111111111111';

Map<String, dynamic> _balanceBody() => {
      'customer_id': _customerId,
      'has_account': true,
      'points_balance': '130.000',
      'cashback_balance': '2.500',
      'available_rewards': 1,
      'remaining_points': '30.000',
    };

Map<String, dynamic> _previewBody({
  String grossTotal = '100.00',
  double rewardPercent = 0,
  String pointsEarned = '1.000',
  int availableRewards = 1,
  String remainingPoints = '30.000',
  String maxRewardDiscountPercent = '20.000',
}) {
  final gross = double.tryParse(grossTotal) ?? 0;
  final discount = gross * rewardPercent / 100;
  return {
    'customer_id': _customerId,
    'gross_total': grossTotal,
    'reward_percent': rewardPercent,
    'reward_discount': discount.toStringAsFixed(3),
    'amount_due': (gross - discount).toStringAsFixed(3),
    'available_rewards': availableRewards,
    'remaining_points': remainingPoints,
    'max_reward_discount_percent': maxRewardDiscountPercent,
    'points_balance': '130.000',
    'cashback_balance': '2.500',
    'points_earned': pointsEarned,
    'cashback_earned': '0.000',
  };
}

/// Dio that answers in-process and records the request paths + bodies.
(Dio, List<RequestOptions>) _dioCapture(
    {Map<String, dynamic> Function(RequestOptions)? previewBody}) {
  final captured = <RequestOptions>[];
  final dio = Dio()..options.baseUrl = 'http://test';
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        captured.add(options);
        if (options.path.endsWith('/loyalty/preview')) {
          final body = previewBody?.call(options) ??
              _previewBody(
                rewardPercent:
                    ((options.data['reward_percent'] as num?) ?? 0).toDouble(),
              );
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: body),
          );
          return;
        }
        // Balance endpoint.
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: _balanceBody()),
        );
      },
    ),
  );
  return (dio, captured);
}

void main() {
  group('CustomerSearchNotifier — QR routing', () {
    test('KLICK:C: payload goes to the loyalty lookup endpoint', () async {
      final captured = <RequestOptions>[];
      final dio = Dio()..options.baseUrl = 'http://test';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured.add(options);
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
                'items': [
                  {
                    'id': _customerId,
                    'name': 'Loyal Alice',
                    'phone': null,
                    'balance': '0',
                    'is_archived': false,
                  },
                ],
                'total': 1,
                'page': 1,
                'pages': 1,
              }),
            );
          },
        ),
      );
      final notifier = CustomerSearchNotifier(dio, () => 'en');

      notifier.setQuery('klick:c:$_customerId');
      await notifier.load();

      expect(captured.single.path, '/api/v1/loyalty/lookup');
      expect(captured.single.queryParameters['q'], 'klick:c:$_customerId');
      expect(notifier.state.items, hasLength(1));
      expect(notifier.state.error, isNull);
    });

    test('a plain query keeps going to /customers/search', () async {
      final captured = <RequestOptions>[];
      final dio = Dio()..options.baseUrl = 'http://test';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured.add(options);
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {
                'items': <dynamic>[],
                'total': 0,
                'page': 1,
                'pages': 1,
              }),
            );
          },
        ),
      );
      final notifier = CustomerSearchNotifier(dio, () => 'en');

      notifier.setQuery('5551234');
      await notifier.load();

      expect(captured.single.path, '/api/v1/customers/search');
    });
  });

  group('PosLoyaltyNotifier', () {
    test('setCustomerById loads balance then previews (total 0 = no preview)',
        () async {
      final (dio, captured) = _dioCapture();
      final notifier = PosLoyaltyNotifier(dio, () => 'en');

      await notifier.setCustomerById(_customerId);

      expect(notifier.state.customerId, _customerId);
      expect(notifier.state.balance, isNotNull);
      expect(notifier.state.balance!.pointsBalance, 130.0);
      expect(notifier.state.balance!.availableRewards, 1);
      expect(notifier.state.balance!.remainingPoints, 30.0);
      expect(notifier.state.loading, isFalse);
      // Only the balance call fired — an empty cart has nothing to preview.
      expect(captured.map((o) => o.path),
          ['/api/v1/customers/$_customerId/loyalty']);
    });

    test('setCartTotal schedules a preview that matches current cart',
        () async {
      final (dio, _) = _dioCapture();
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);

      notifier.setCartTotal(100);
      await notifier.previewNow();

      expect(notifier.state.preview, isNotNull);
      expect(notifier.state.previewOnCurrentCart, isTrue);
      expect(notifier.state.previewMatches, isTrue);
      expect(notifier.state.preview!.grossTotal, 100.0);
      expect(notifier.state.preview!.rewardPercent, 0);
      expect(notifier.state.preview!.rewardDiscount, 0);
      expect(notifier.state.availableRewards, 1);
    });

    test('preview is discarded when the cart total moved on meanwhile',
        () async {
      // A slow server: the FIRST preview (for total=100) is held open by a
      // completer; the total moves to 200 while it is in flight; only then
      // does the stale answer land — it must not surface.
      final requestReceived = Completer<void>();
      final gate = Completer<void>();
      final dio = Dio()..options.baseUrl = 'http://test';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/loyalty/preview')) {
              final gross = '${options.data['gross_total']}';
              if (gross == '100.00') {
                if (!requestReceived.isCompleted) requestReceived.complete();
                unawaited(gate.future.then((_) {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: _previewBody(grossTotal: '100.00'),
                    ),
                  );
                }));
                return;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: _previewBody(grossTotal: gross),
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _balanceBody(),
              ),
            );
          },
        ),
      );
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);
      notifier.setCartTotal(100);

      // Fire the slow preview for total=100; wait until it has actually
      // reached the handler before moving the cart on.
      final inFlight = notifier.previewNow();
      await requestReceived.future;

      // The cart moves on while the answer is still in flight.
      notifier.setCartTotal(200);
      gate.complete();
      await inFlight;

      // The stale answer (total=100 against a cart now at 200) is dropped.
      expect(notifier.state.preview, isNull);

      // A fresh preview for the CURRENT total surfaces normally.
      await notifier.previewNow();
      expect(notifier.state.preview!.grossTotal, 200.0);
    });

    test('a percent above the known cap suppresses the preview', () async {
      final (dio, previewCalls) = _dioCapture(
        previewBody: (options) => _previewBody(
          grossTotal: '${options.data['gross_total']}',
          rewardPercent:
              ((options.data['reward_percent'] as num?) ?? 0).toDouble(),
        ),
      );
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);
      notifier.setCartTotal(100);
      await notifier.previewNow();
      // Server cap from the matching preview = 20% → 30% is over the cap.
      expect(notifier.state.maxRewardDiscountPercent, 20.0);
      final before = previewCalls
          .where((o) => o.path.endsWith('/loyalty/preview'))
          .length;

      notifier.setRewardPercent(30);

      expect(notifier.state.exceeds, isTrue);
      expect(notifier.state.preview, isNull);
      // Selecting over the cap must NOT hit the preview endpoint again.
      expect(
        previewCalls.where((o) => o.path.endsWith('/loyalty/preview')).length,
        before,
      );

      // Coming back under the cap clears the flag and previews normally.
      notifier.setRewardPercent(20);
      expect(notifier.state.exceeds, isFalse);
      await notifier.previewNow();
      expect(notifier.state.previewMatches, isTrue);
      expect(notifier.state.preview!.rewardPercent, 20);
      expect(notifier.state.preview!.rewardDiscount, 20.0);
    });

    test('detaching the customer wipes balance, preview and percent', () async {
      final (dio, _) = _dioCapture();
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);
      notifier.setCartTotal(100);
      notifier.setRewardPercent(20);
      await notifier.previewNow();
      expect(notifier.state.preview, isNotNull);

      await notifier.setCustomerById(null);

      expect(notifier.state.customerId, isNull);
      expect(notifier.state.balance, isNull);
      expect(notifier.state.preview, isNull);
      expect(notifier.state.rewardPercent, 0);
      expect(notifier.state.cartTotal, 100); // cart total survives detach
    });

    test('clearReward drops the selection and previews at zero percent',
        () async {
      final (dio, _) = _dioCapture();
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);
      notifier.setCartTotal(100);
      notifier.setRewardPercent(20);
      await notifier.previewNow();
      expect(notifier.state.preview!.rewardPercent, 20);

      notifier.clearReward();
      await notifier.previewNow();

      expect(notifier.state.rewardPercent, 0);
      expect(notifier.state.previewMatches, isTrue);
      expect(notifier.state.preview!.rewardPercent, 0);
      expect(notifier.state.preview!.rewardDiscount, 0);
      expect(notifier.state.rewardDiscount, 0);
    });

    test('a 4xx preview surfaces a localized error and drops the preview',
        () async {
      final dio = Dio()..options.baseUrl = 'http://test';
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/loyalty/preview')) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 422,
                    data: {
                      'detail': [
                        {
                          'msg': 'reward percent exceeds cap',
                          'loc': ['body', 'reward_percent'],
                        },
                      ],
                    },
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: _balanceBody(),
              ),
            );
          },
        ),
      );
      final notifier = PosLoyaltyNotifier(dio, () => 'en');
      await notifier.setCustomerById(_customerId);
      notifier.setCartTotal(100);

      await notifier.previewNow();

      expect(notifier.state.preview, isNull);
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.error, isNot(contains('reward percent exceeds')));
    });
  });
}
