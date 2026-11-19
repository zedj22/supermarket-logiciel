// Manual line total (double-click) + POS quick custom item — unit tests.
//
// The financial contract under test:
//   * a manual total is expressed as the line DISCOUNT (gross − total), the
//     only field the backend validates and the invoice/returns read;
//   * the override pins the amount, so a later quantity change re-derives the
//     discount instead of erasing the cashier's number;
//   * a custom line has no product, no stock and quantity 1, and its sale
//     payload carries `custom_name` instead of a product id.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_line_total_dialog.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_return_lines.dart';

PosCartNotifier _cart() =>
    PosCartNotifier(Dio(), () => 'en', () async => 'device-1');

CartLine _line({
  String id = 'p1',
  String quantity = '5',
  String unitPrice = '100',
}) =>
    CartLine(
      productId: id,
      name: 'Coca Cola',
      quantity: quantity,
      unitPrice: unitPrice,
      availableStock: '1000',
    );

void main() {
  group('manual line total', () {
    test('500 → 450 keeps the quantity and writes a 50 discount', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;

      cart.setLineTotal(key, '450');

      final line = cart.state.lines.single;
      expect(line.quantity, '5');
      expect(line.unitPrice, '100', reason: 'catalog price is never rewritten');
      expect(line.lineTotal, closeTo(450, 0.001));
      expect(line.discountAmount, closeTo(50, 0.001));
      expect(line.manualTotal, '450');

      final payload = line.toSaleJson();
      expect(payload['quantity'], '5');
      expect(payload['unit_price'], '100');
      expect(double.parse('${payload['line_discount']}'), closeTo(50, 0.001));
      expect(payload.containsKey('product_id'), isTrue);
    });

    test('grand total follows and other lines are untouched', () {
      final cart = _cart();
      cart.addLine(_line());
      cart.addLine(_line(id: 'p2', quantity: '2', unitPrice: '10'));
      final first = cart.state.lines.first.key;

      expect(cart.state.totals.total, closeTo(520, 0.001));
      cart.setLineTotal(first, '450');

      expect(cart.state.totals.total, closeTo(470, 0.001));
      final other = cart.state.lines.last;
      expect(other.lineTotal, closeTo(20, 0.001));
      expect(other.lineDiscount, '0');
      expect(other.manualTotal, isNull);
    });

    test('a later quantity change keeps the pinned total', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;
      cart.setLineTotal(key, '450');

      cart.updateLine(key, quantity: '10');

      final line = cart.state.lines.single;
      expect(line.quantity, '10');
      expect(line.unitPrice, '100');
      expect(line.lineTotal, closeTo(450, 0.001),
          reason: 'the cashier total survives the quantity change');
      expect(line.discountAmount, closeTo(550, 0.001));
      // Payload still balances: gross − discount == pinned total.
      expect(line.lineGross - line.discountAmount, closeTo(450, 0.001));
    });

    test('automatic bundle pricing is not stacked on a manual total', () {
      const auto = CartLine(
        productId: 'p9',
        name: 'Bundle',
        quantity: '6',
        unitPrice: '100',
        availableStock: '1000',
        autoBundleQuantity: '4',
        autoBundlePrice: '300',
      );
      final cart = _cart();
      cart.addLine(auto);
      final key = cart.state.lines.single.key;
      // The bundle discount is DERIVED by copyWith (which is what the add
      // path and every quantity edit use).
      cart.updateLine(key, quantity: '6');
      expect(cart.state.lines.single.discountAmount, closeTo(100, 0.001),
          reason: 'bundle plan: 4×300 + 2×100 = 1400 of 1500');

      cart.setLineTotal(key, '450');

      final line = cart.state.lines.single;
      expect(line.lineTotal, closeTo(450, 0.001));
      // The manual total REPLACES the bundle discount: the line charges
      // exactly 450, it is not 500 (bundle) with a second discount on top.
      expect(line.lineGross - line.discountAmount, closeTo(450, 0.001));
      expect(line.discountAmount, closeTo(150, 0.001));

      // The override also wins on a later quantity change: the total stays
      // pinned and only the discount absorbs the new gross.
      cart.updateLine(key, quantity: '8');
      final after = cart.state.lines.single;
      expect(after.quantity, '8');
      expect(after.lineTotal, closeTo(450, 0.001));
      expect(after.lineGross - after.discountAmount, closeTo(450, 0.001));
      // The bundle plan for 8 units would be 2×300 + 0×100 = 600 — which is
      // NOT what the line charges, so nothing was stacked.
      expect(after.lineTotal, isNot(closeTo(600, 0.001)));
    });

    test('a quantity DROP below the pinned total releases the override', () {
      // 5 × 100 = 500 pinned to 450. Dropping to 2 leaves a gross of 200,
      // which cannot pay 450 with a non-negative discount: the line must
      // fall back to 200 EVERYWHERE (display, payload, cart total) rather
      // than showing 450 while the sale charges 200.
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;
      cart.setLineTotal(key, '450');

      cart.updateLine(key, quantity: '2');

      final line = cart.state.lines.single;
      expect(line.quantity, '2');
      expect(line.manualTotal, isNull,
          reason: 'an unpayable pin must not survive');
      expect(line.lineDiscount, '0');
      expect(line.lineTotal, closeTo(200, 0.001));
      expect(cart.state.totals.total, closeTo(200, 0.001));
      final payload = line.toSaleJson();
      final gross = double.parse('${payload['quantity']}') *
          double.parse('${payload['unit_price']}');
      expect(
        gross - double.parse('${payload['line_discount']}'),
        closeTo(line.lineTotal, 0.001),
        reason: 'displayed total == payload total',
      );
    });

    test('a total above the line gross is refused (no negative discount)', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;

      cart.setLineTotal(key, '900');

      final line = cart.state.lines.single;
      expect(line.lineTotal, closeTo(500, 0.001));
      expect(line.lineDiscount, '0');
      expect(line.manualTotal, isNull);
    });

    test('manual override survives a hold snapshot round trip', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;
      cart.setLineTotal(key, '420.5');

      final json = cart.state.lines.single.toJson();
      final restored = CartLine.fromJson(json);

      expect(restored.manualTotal, '420.5');
      expect(restored.lineTotal, closeTo(420.5, 0.001));
      expect(restored.quantity, '5');
      expect(restored.discountAmount, closeTo(79.5, 0.001));
    });

    test('clearing the override restores the normal line', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;
      cart.setLineTotal(key, '450');
      final cleared = cart.state.lines.single.clearManualTotal();
      expect(cleared.manualTotal, isNull);
      expect(cleared.lineDiscount, '0');
      expect(cleared.lineTotal, closeTo(500, 0.001));
    });

    test('amount parsing rejects non-finite, negative and junk input', () {
      expect(parsePosAmount('450'), closeTo(450, 0.001));
      expect(parsePosAmount('1 250,50'), closeTo(1250.5, 0.001));
      expect(parsePosAmount('1,250.50'), closeTo(1250.5, 0.001));
      expect(parsePosAmount('-5'), isNull);
      expect(parsePosAmount('abc'), isNull);
      expect(parsePosAmount(''), isNull);
      expect(parsePosAmount('0'), 0);
    });
  });

  group('quick custom item', () {
    test('adds a price-only line with quantity 1 and no product', () {
      final cart = _cart();
      cart.addCustomLine(name: 'Unregistered item', total: '350');

      final line = cart.state.lines.single;
      expect(line.customLine, isTrue);
      expect(line.productId, isNull);
      expect(line.packId, isNull);
      expect(line.quantity, '1');
      expect(line.lineTotal, closeTo(350, 0.001));
      expect(line.availableStock, isNull);

      final payload = line.toSaleJson();
      expect(payload.containsKey('product_id'), isFalse);
      expect(payload['custom_name'], 'Unregistered item');
      expect(payload['quantity'], '1');
      expect(payload['unit_price'], '350');
      expect(payload['line_discount'], '0');
    });

    test('two custom items stay two independent lines', () {
      final cart = _cart();
      cart.addCustomLine(name: 'A', total: '100');
      cart.addCustomLine(name: 'B', total: '200');

      expect(cart.state.lines.length, 2);
      expect(cart.state.lines[0].key, isNot(cart.state.lines[1].key));
      expect(cart.state.totals.total, closeTo(300, 0.001));
    });

    test('quantity cannot be changed and the line can be removed', () {
      final cart = _cart();
      cart.addCustomLine(name: 'A', total: '100');
      final key = cart.state.lines.single.key;

      cart.updateLine(key, quantity: '3');
      expect(cart.state.lines.single.quantity, '1');

      cart.removeLine(key);
      expect(cart.state.lines, isEmpty);
      expect(cart.state.totals.total, 0);
    });

    test('its total can be raised (price = total, no discount)', () {
      final cart = _cart();
      cart.addCustomLine(name: 'A', total: '350');
      final key = cart.state.lines.single.key;

      cart.setLineTotal(key, '400');

      final line = cart.state.lines.single;
      expect(line.lineTotal, closeTo(400, 0.001));
      expect(line.price, closeTo(400, 0.001));
      expect(line.discountAmount, 0);
      expect(line.toSaleJson()['unit_price'], '400');
    });

    test('a custom line survives hold serialization', () {
      final cart = _cart();
      cart.addCustomLine(name: 'Gift wrap', total: '75');
      final restored = CartLine.fromJson(cart.state.lines.single.toJson());

      expect(restored.customLine, isTrue);
      expect(restored.name, 'Gift wrap');
      expect(restored.customRef, isNotNull);
      expect(restored.lineTotal, closeTo(75, 0.001));
      expect(restored.toSaleJson()['custom_name'], 'Gift wrap');
    });

    test('POS return mode refuses a custom line (no product to restock)', () {
      final result = buildPosReturnLines(const [
        CartLine(
          name: 'Unregistered item',
          quantity: '1',
          unitPrice: '350',
          customLine: true,
          customRef: 'c1',
        ),
      ]);
      expect(result.isOk, isFalse);
      expect(result.errorKey, 'pos_return_custom_not_supported');
    });
  });

  group('manual total + custom item in the cart lifecycle', () {
    test('removing a manually overridden line drops the override with it', () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;
      cart.setLineTotal(key, '450');

      cart.removeLine(key);
      expect(cart.state.lines, isEmpty);
      expect(cart.state.totals.total, 0);

      // Re-adding the same product starts from the catalog price again:
      // nothing of the removed override survives in the cart.
      cart.addLine(_line());
      expect(cart.state.lines.single.lineTotal, closeTo(500, 0.001));
      expect(cart.state.lines.single.manualTotal, isNull);
    });

    test('an unknown line key is ignored (stale dialog result)', () {
      final cart = _cart();
      cart.addLine(_line());

      cart.setLineTotal('no-such-line', '450');

      expect(cart.state.lines.single.lineTotal, closeTo(500, 0.001));
      expect(cart.state.lines.single.manualTotal, isNull);
    });

    test('negative, zero, non-finite and junk amounts never reach the cart',
        () {
      final cart = _cart();
      cart.addLine(_line());
      final key = cart.state.lines.single.key;

      for (final bad in <String>[
        '-5',
        '0',
        'abc',
        '',
        'Infinity',
        'NaN',
        '1e999',
      ]) {
        cart.setLineTotal(key, bad);
        expect(cart.state.lines.single.manualTotal, isNull, reason: bad);
        expect(cart.state.lines.single.lineTotal, closeTo(500, 0.001),
            reason: bad);
      }

      cart.addCustomLine(name: 'Gift', total: '-1');
      cart.addCustomLine(name: 'Gift', total: 'abc');
      expect(cart.state.lines, hasLength(1),
          reason: 'no invalid custom line is admitted');
    });

    test('a mixed cart balances: cart total == sum of payload lines', () {
      final cart = _cart();
      cart.addLine(_line()); // 5 × 100 = 500
      cart.addLine(_line(id: 'p2', quantity: '2', unitPrice: '10')); // 20
      cart.setLineTotal(cart.state.lines.first.key, '450');
      cart.addCustomLine(name: 'Gift wrap', total: '75');

      // What the backend will re-compute from the payload it is sent:
      // quantity × unit_price − line_discount, per line.
      var payloadNet = 0.0;
      for (final line in cart.state.lines) {
        final json = line.toSaleJson();
        final gross = double.parse('${json['quantity']}') *
            double.parse('${json['unit_price']}');
        payloadNet += gross - double.parse('${json['line_discount']}');
      }
      expect(cart.state.totals.total, closeTo(450 + 20 + 75, 0.001));
      expect(payloadNet, closeTo(cart.state.totals.total, 0.001),
          reason: 'displayed, payload and backend totals must agree');

      // The custom line ships as a name + price, never as a catalog row.
      final custom = cart.state.lines.last.toSaleJson();
      expect(custom['custom_name'], 'Gift wrap');
      expect(custom.containsKey('product_id'), isFalse);
      expect(custom.containsKey('pack_id'), isFalse);
      expect(custom.containsKey('variant_id'), isFalse);
      expect(custom['unit_price'], '75');
    });

    test('a held sale restores the pinned total and the custom line', () {
      final cart = _cart();
      cart.addLine(_line());
      cart.setLineTotal(cart.state.lines.single.key, '450');
      cart.addCustomLine(name: 'Gift', total: '75');

      // A hold stores the cart's own snapshot; resume reads it back.
      final hold = HoldModel(
        id: 'h1',
        createdAt: DateTime(2026, 11, 18),
        items: cart.state.lines
            .map((line) => CartLine.fromJson(line.toJson()))
            .toList(),
      );
      final resumed = _cart()..loadHold(hold);

      expect(resumed.state.lines, hasLength(2));
      expect(resumed.state.lines.first.lineTotal, closeTo(450, 0.001));
      expect(resumed.state.lines.first.manualTotal, '450');
      expect(resumed.state.lines.first.quantity, '5');
      expect(resumed.state.lines.last.customLine, isTrue);
      expect(resumed.state.lines.last.name, 'Gift');
      expect(resumed.state.lines.last.quantity, '1');
      expect(resumed.state.totals.total, closeTo(525, 0.001));
    });

    test('the manual-total badge is translated in ar, fr and en', () {
      final values = <String, String>{};
      for (final loc in ['ar', 'fr', 'en']) {
        final value = AppStrings.t('manual_total_badge', loc);
        expect(value, isNotEmpty, reason: loc);
        expect(value, isNot('manual_total_badge'), reason: loc);
        values[loc] = value;
      }
      expect(values.values.toSet(), hasLength(3),
          reason: 'the three locales must differ');
    });
  });

  // ---------------------------------------------------------------------
  // Checkout WIRE contract: what POST /api/v1/sales actually receives.
  //
  // A custom line is only sellable because the request carries
  // `custom_name` and NO product/pack id. These tests capture the body at
  // the Dio adapter (the real request, not a hand-built map) so a
  // regression here cannot hide behind a passing cart display.
  // ---------------------------------------------------------------------
  group('checkout payload', () {
    test('a custom-only cart posts one custom item and no product id', () async {
      final adapter = _RecordingAdapter();
      final cart = _recordingCart(adapter);
      cart.addCustomLine(name: 'a', total: '100');

      await cart.checkout(method: PaymentMethod.cash, paid: 100);

      expect(adapter.calls, hasLength(1));
      final call = adapter.calls.single;
      expect(call.path, '/api/v1/sales');
      expect(call.body['payment_method'], 'cash');
      expect(call.body['paid'], '100.00');
      expect(call.body['device_id'], 'device-1');

      final items = (call.body['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(1));
      expect(items.single, containsPair('custom_name', 'a'));
      expect(items.single, containsPair('quantity', '1'));
      expect(items.single, containsPair('unit_price', '100'));
      expect(items.single, containsPair('line_discount', '0'));
      expect(items.single.containsKey('product_id'), isFalse,
          reason: 'a custom line must never post a catalog id');
      expect(items.single.containsKey('pack_id'), isFalse);
      expect(items.single.containsKey('variant_id'), isFalse);
      expect(items.single.containsKey('selling_unit_id'), isFalse);
    });

    test('several custom items post one item each', () async {
      final adapter = _RecordingAdapter();
      final cart = _recordingCart(adapter);
      cart.addCustomLine(name: 'Gift wrap', total: '75');
      cart.addCustomLine(name: 'Bag', total: '12');

      await cart.checkout(method: PaymentMethod.cash, paid: 87);

      final items = (adapter.calls.single.body['items'] as List)
          .cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      expect(
        items.map((i) => i['custom_name']).toList(),
        <String>['Gift wrap', 'Bag'],
      );
      expect(items.every((i) => !i.containsKey('product_id')), isTrue);
      expect(adapter.calls.single.body['paid'], '87.00');
    });

    test('a mixed cart posts product_id and custom_name side by side',
        () async {
      final adapter = _RecordingAdapter();
      final cart = _recordingCart(adapter);
      cart.addLine(_line()); // 5 × 100 = 500
      cart.addCustomLine(name: 'Gift wrap', total: '75');

      await cart.checkout(method: PaymentMethod.cash, paid: 575);

      final items = (adapter.calls.single.body['items'] as List)
          .cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      expect(items.first['product_id'], 'p1');
      expect(items.first.containsKey('custom_name'), isFalse,
          reason: 'a catalog line must never carry a custom name');
      expect(items.last['custom_name'], 'Gift wrap');
      expect(items.last.containsKey('product_id'), isFalse);
      expect(adapter.calls.single.body['paid'], '575.00');
    });
  });
}

/// Captures the real checkout body at the transport layer.
class _RecordingAdapter implements HttpClientAdapter {
  final List<({String path, Map<String, dynamic> body})> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    if (data is Map) {
      calls.add((
        path: options.path,
        body: Map<String, dynamic>.from(data),
      ));
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'id': 'sale-1',
        'invoice_number': 'INV-001',
        'status': 'completed',
        'subtotal': '0',
        'discount': '0',
        'total': '0',
        'paid': '0',
        'change': '0',
        'debt': '0',
        'payment_method': 'cash',
        'idempotent_replay': false,
        'price_overrides': <dynamic>[],
      }),
      201,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

PosCartNotifier _recordingCart(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  return PosCartNotifier(dio, () => 'en', () async => 'device-1');
}
