// Phase 17 large-cart contract — 1 000 / 5 000 / 10 000 DISTINCT lines.
//
// Backend contract: POST /api/v1/sales accepts up to MAX_SALE_LINES =
// 10 000 cart lines (quantity never counts toward the limit — 500 of A +
// 700 of B is 2 lines). The client must therefore hold up to 10 000
// distinct lines with correct totals, stable order, merge/remove
// semantics, and build a checkout payload carrying every line.
//
// There is deliberately NO client-side line cap: the cart ListView is
// lazy and keyed, so a 10 000 line cart only builds the visible rows.
// This test measures the state-layer cost (adds + totals + payload) and
// fails only on correctness or a catastrophic slowdown.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

PosCartNotifier _notifier() =>
    PosCartNotifier(Dio(), () => 'en', () async => 'pos-test');

CartLine _line(int i) => CartLine(
      productId: 'p$i',
      name: 'Product $i',
      quantity: '1',
      unitPrice: '100',
    );

void main() {
  group('large cart (backend limit 10 000 distinct lines)', () {
    for (final size in [1000, 5000, 10000]) {
      test('$size lines: state, totals, payload and edits stay correct', () {
        final cart = _notifier();

        final sw = Stopwatch()..start();
        for (var i = 0; i < size; i++) {
          cart.addLine(_line(i));
        }
        sw.stop();
        final buildMs = sw.elapsedMilliseconds;
        final sw2 = Stopwatch()..start();

        final state = cart.state;

        // ── Every distinct line held, insertion order preserved ──
        expect(state.lines, hasLength(size));
        expect(state.lines.map((l) => l.key).toSet(), hasLength(size));
        for (var i = 0; i < size; i++) {
          expect(state.lines[i].productId, 'p$i');
        }
        expect(state.lastActiveKey, state.lines.last.key);
        expect(state.isEmpty, isFalse);

        // ── Totals correct at scale (qty 1 x price 100 per line) ──
        expect(state.totals.lineCount, size);
        expect(state.totals.total, closeTo(size * 100.0, 0.001));
        expect(state.totals.subtotal, closeTo(size * 100.0, 0.001));

        // ── Checkout payload carries every line (POST /sales items[]) ──
        final items = state.lines.map((l) => l.toSaleJson()).toList();
        expect(items, hasLength(size));
        expect(items.first['product_id'], 'p0');
        expect(items.last['product_id'], 'p${size - 1}');

        // ── Edit a middle line (updateLine is O(n) map + lastActiveKey) ──
        final middleKey = state.lines[size ~/ 2].key;
        cart.updateLine(middleKey, quantity: '4');
        expect(cart.state.lines[size ~/ 2].quantity, '4');
        expect(cart.state.lastActiveKey, middleKey);
        expect(cart.state.lines, hasLength(size));

        // ── Merge semantics hold at scale (same key -> one line) ──
        cart.addLine(_line(size ~/ 2).copyWith(quantity: '2'));
        final merged = cart.state.lines[size ~/ 2];
        expect(cart.state.lines, hasLength(size));
        expect(
          double.parse(merged.quantity),
          closeTo(6.0, 0.001), // 4 (edited above) + 2 (merged)
        );

        // ── Remove a line; order of the rest is untouched ──
        cart.removeLine(middleKey);
        expect(cart.state.lines, hasLength(size - 1));
        expect(cart.state.lines.map((l) => l.key).contains(middleKey), isFalse);
        expect(cart.state.lines.first.productId, 'p0');

        sw2.stop();
        // ignore: avoid_print
        print(
          'cart[$size]: build $buildMs ms, '
          'totals+payload+edits ${sw2.elapsedMilliseconds} ms',
        );

        // ── State-layer budget: quadratic key-rebuilding regression cost
        //    us 14.9 s at 10 000; cached key measures ~0.6 s locally ──
        expect(
          buildMs + sw2.elapsedMilliseconds,
          lessThan(5000),
          reason:
              'building $size cart lines took ${buildMs + sw2.elapsedMilliseconds} ms',
        );
      });
    }
  });
}
