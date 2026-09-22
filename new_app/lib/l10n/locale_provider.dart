import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  LocaleNotifier() : super(const LocaleState());

  void setLocale(AppLocale locale) {
    state = state.copyWith(locale: locale);
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
  }
}

final localeProvider = StateNotifierProvider<LocaleNotifier, LocaleState>((ref) {
  return LocaleNotifier();
});
