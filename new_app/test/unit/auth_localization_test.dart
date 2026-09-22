import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

void main() {
  group('Auth Localization Strings', () {
    const authKeys = [
      'welcome',
      'setup_title',
      'create_admin',
      'admin_name',
      'enter_admin_name',
      'create_pin',
      'confirm_pin',
      'create_account',
      'continue_to_login',
      'admin_created',
      'select_user',
      'enter_your_pin',
      'login_button',
      'login_submit',
      'invalid_pin',
      'account_locked',
      'account_disabled',
      'authentication_failed',
      'login_failed',
      'no_users',
      'tap_to_select',
      'logout_confirm',
      'logged_out',
      'reauth_title',
      'reauth_subtitle',
      'reauth_button',
      'reauth_success',
      'reauth_failed',
      'permission_denied',
      'session_expired_login',
      'network_error_retry',
      'user_list',
      'create_user',
      'edit_user',
      'delete_user_confirm',
      'user_created',
      'user_updated',
      'user_deleted',
      'cannot_delete_last_admin',
      'role',
      'admin',
      'manager',
      'cashier',
      'active',
      'inactive',
      'change_pin',
      'new_pin',
      'confirm_new_pin',
      'pin_changed',
      'select_role',
      'clear',
      'backspace',
      'submit',
    ];

    test('all auth keys exist in Arabic', () {
      for (final key in authKeys) {
        final value = AppStrings.translate(key, 'ar');
        expect(value, isNot(equals(key)),
            reason: 'Missing Arabic translation for key: $key');
      }
    });

    test('all auth keys exist in French', () {
      for (final key in authKeys) {
        final value = AppStrings.translate(key, 'fr');
        expect(value, isNot(equals(key)),
            reason: 'Missing French translation for key: $key');
      }
    });

    test('all auth keys exist in English', () {
      for (final key in authKeys) {
        final value = AppStrings.translate(key, 'en');
        expect(value, isNot(equals(key)),
            reason: 'Missing English translation for key: $key');
      }
    });

    test('Arabic RTL strings are correct', () {
      expect(AppStrings.translate('welcome', 'ar'), 'مرحباً بك');
      expect(AppStrings.translate('login_button', 'ar'), 'تسجيل الدخول');
      expect(AppStrings.translate('invalid_pin', 'ar'), 'رقم التعريف الشخصي غير صحيح');
    });

    test('French strings are correct', () {
      expect(AppStrings.translate('welcome', 'fr'), 'Bienvenue');
      expect(AppStrings.translate('login_button', 'fr'), 'Connexion');
      expect(AppStrings.translate('invalid_pin', 'fr'), 'Code PIN invalide');
    });

    test('English strings are correct', () {
      expect(AppStrings.translate('welcome', 'en'), 'Welcome');
      expect(AppStrings.translate('login_button', 'en'), 'Login');
      expect(AppStrings.translate('invalid_pin', 'en'), 'Invalid PIN');
    });

    test('t() method returns same as translate()', () {
      for (final key in authKeys) {
        final tResult = AppStrings.t(key, 'en');
        final translateResult = AppStrings.translate(key, 'en');
        expect(tResult, translateResult);
      }
    });
  });
}
