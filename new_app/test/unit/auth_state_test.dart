import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';

void main() {
  group('AuthState', () {
    test('defaults to checking status', () {
      const state = AuthState();
      expect(state.status, AuthStatus.checking);
      expect(state.user, isNull);
      expect(state.errorMessage, isNull);
      expect(state.setupInProgress, false);
      expect(state.loginInProgress, false);
    });

    test('copyWith preserves existing values', () {
      const state = AuthState(status: AuthStatus.unauthenticated);
      final updated = state.copyWith(errorMessage: 'test error');
      expect(updated.status, AuthStatus.unauthenticated);
      expect(updated.errorMessage, 'test error');
    });

    test('copyWith overrides status', () {
      const state = AuthState(status: AuthStatus.unauthenticated);
      final updated = state.copyWith(status: AuthStatus.authenticated);
      expect(updated.status, AuthStatus.authenticated);
    });

    test('copyWith clears error on new copy without error', () {
      const state = AuthState(errorMessage: 'error');
      final cleared = state.copyWith();
      expect(cleared.errorMessage, isNull);
    });

    test('setupInProgress flag works', () {
      const state = AuthState(setupInProgress: true);
      expect(state.setupInProgress, true);
      final done = state.copyWith(setupInProgress: false);
      expect(done.setupInProgress, false);
    });

    test('loginInProgress flag works', () {
      const state = AuthState(loginInProgress: true);
      expect(state.loginInProgress, true);
    });
  });

  group('AuthStatus', () {
    test('all statuses defined', () {
      expect(AuthStatus.values.length, 7);
      expect(AuthStatus.checking, isNotNull);
      expect(AuthStatus.setupRequired, isNotNull);
      expect(AuthStatus.unauthenticated, isNotNull);
      expect(AuthStatus.authenticating, isNotNull);
      expect(AuthStatus.authenticated, isNotNull);
      expect(AuthStatus.sessionExpired, isNotNull);
      expect(AuthStatus.error, isNotNull);
    });
  });
}
