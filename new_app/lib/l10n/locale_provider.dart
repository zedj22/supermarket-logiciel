import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLocale { ar, fr, en }

class LocaleState {
  final AppLocale locale;

  const LocaleState({this.locale = AppLocale.ar});

  Locale get flutterLocale {
    switch (locale) {
      case AppLocale.ar:
        return const Locale('ar');
      case AppLocale.fr:
        return const Locale('fr');
      case AppLocale.en:
        return const Locale('en');
    }
  }

  bool get isRtl => locale == AppLocale.ar;

  LocaleState copyWith({AppLocale? locale}) {
    return LocaleState(locale: locale ?? this.locale);
  }
}

class LocaleNotifier extends StateNotifier<LocaleState> {
  static const prefsKey = 'app_locale';

  final SharedPreferences? _prefs;

  LocaleNotifier([SharedPreferences? prefs])
      : _prefs = prefs,
        super(LocaleState(locale: _read(prefs)));

  static AppLocale _read(SharedPreferences? prefs) {
    final raw = prefs?.getString(prefsKey);
    if (raw == null || raw.isEmpty) return AppLocale.ar;
    for (final value in AppLocale.values) {
      if (value.name == raw) return value;
    }
    return AppLocale.ar;
  }

  void setLocale(AppLocale locale) {
    state = state.copyWith(locale: locale);
    _persist();
  }

  void cycleLocale() {
    switch (state.locale) {
      case AppLocale.ar:
        state = state.copyWith(locale: AppLocale.fr);
        break;
      case AppLocale.fr:
        state = state.copyWith(locale: AppLocale.en);
        break;
      case AppLocale.en:
        state = state.copyWith(locale: AppLocale.ar);
        break;
    }
    _persist();
  }

  void _persist() {
    _prefs?.setString(prefsKey, state.locale.name);
  }
}

final localeProvider = StateNotifierProvider<LocaleNotifier, LocaleState>((ref) {
  return LocaleNotifier();
});
