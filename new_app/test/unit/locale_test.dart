import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

void main() {
  group('LocaleState', () {
    test('defaults to Arabic', () {
      final state = const LocaleState();
      expect(state.locale, AppLocale.ar);
      expect(state.isRtl, true);
      expect(state.flutterLocale, const Locale('ar'));
    });

    test('copyWith overrides locale', () {
      final state = const LocaleState();
      final fr = state.copyWith(locale: AppLocale.fr);
      expect(fr.locale, AppLocale.fr);
      expect(fr.isRtl, false);
      expect(fr.flutterLocale, const Locale('fr'));
    });

    test('English is LTR', () {
      final state = const LocaleState().copyWith(locale: AppLocale.en);
      expect(state.isRtl, false);
      expect(state.flutterLocale, const Locale('en'));
    });
  });

  group('LocaleNotifier', () {
    test('defaults to Arabic', () {
      final notifier = LocaleNotifier();
      expect(notifier.state.locale, AppLocale.ar);
    });

    test('setLocale changes locale', () {
      final notifier = LocaleNotifier();
      notifier.setLocale(AppLocale.fr);
      expect(notifier.state.locale, AppLocale.fr);
    });

    test('cycleLocale cycles through locales', () {
      final notifier = LocaleNotifier();
      expect(notifier.state.locale, AppLocale.ar);

      notifier.cycleLocale();
      expect(notifier.state.locale, AppLocale.fr);

      notifier.cycleLocale();
      expect(notifier.state.locale, AppLocale.en);

      notifier.cycleLocale();
      expect(notifier.state.locale, AppLocale.ar);
    });
  });
}
