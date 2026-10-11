// POS return mode — cart state bookkeeping (mode flag, attempt id).
//
// The POST itself is orchestrated by the screen through the existing
// ReturnsApi; these tests pin the state machine the UI relies on:
// mode flips never touch lines, one client_request_id per attempt is
// reused on retry, and a confirmed success (clearCart) resets everything.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

PosCartNotifier _notifier() =>
    PosCartNotifier(Dio(), () => 'en', () async => 'pos-test');

CartLine _line({String quantity = '2'}) => CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: quantity,
      unitPrice: '10',
    );

void main() {
  group('PosCartNotifier return mode', () {
    test('entering the mode keeps the cart lines untouched', () {
      final notifier = _notifier();
      notifier.addLine(_line());
      notifier.setReturnMode(true);

      final state = notifier.state;
      expect(state.returnMode, isTrue);
      expect(state.lines, hasLength(1));
      expect(state.lines.single.name, 'Bread');
      expect(state.pendingReturnClientRequestId, isNull);
    });

    test('exiting the mode keeps the cart lines untouched', () {
      final notifier = _notifier();
      notifier.addLine(_line());
      notifier.setReturnMode(true);
      notifier.setReturnMode(false);

      final state = notifier.state;
      expect(state.returnMode, isFalse);
      expect(state.lines, hasLength(1));
    });

    test('beginReturnAttempt issues ONE id, reused across retries', () {
      final notifier = _notifier();
      notifier.addLine(_line());
      notifier.setReturnMode(true);

      final first = notifier.beginReturnAttempt();
      expect(notifier.state.returnPending, isTrue);
      expect(notifier.state.pendingReturnClientRequestId, first);

      notifier.failReturnAttempt();
      expect(notifier.state.returnPending, isFalse);
      // The failed attempt keeps its id — the retry replays it.
      expect(notifier.state.pendingReturnClientRequestId, first);

      final retry = notifier.beginReturnAttempt();
      expect(retry, first);
    });

    test('a new mode session starts a fresh attempt id', () {
      final notifier = _notifier();
      notifier.addLine(_line());
      notifier.setReturnMode(true);
      final first = notifier.beginReturnAttempt();
      notifier.failReturnAttempt();

      notifier.setReturnMode(false);
      expect(notifier.state.pendingReturnClientRequestId, isNull);
      notifier.setReturnMode(true);
      final second = notifier.beginReturnAttempt();
      expect(second, isNot(first));
    });

    test('clearCart (confirmed success) resets mode, pending flag and id',
        () {
      final notifier = _notifier();
      notifier.addLine(_line());
      notifier.setReturnMode(true);
      notifier.beginReturnAttempt();

      notifier.clearCart();
      final state = notifier.state;
      expect(state.returnMode, isFalse);
      expect(state.returnPending, isFalse);
      expect(state.pendingReturnClientRequestId, isNull);
      expect(state.lines, isEmpty);
    });

    test('copyWith preserves the return fields by default', () {
      final notifier = _notifier();
      notifier.setReturnMode(true);
      final id = notifier.beginReturnAttempt();

      final next = notifier.state.copyWith(clearError: true);
      expect(next.returnMode, isTrue);
      expect(next.returnPending, isTrue);
      expect(next.pendingReturnClientRequestId, id);
    });
  });
}
