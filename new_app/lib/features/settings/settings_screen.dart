import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme_mode.dart';
import '../../theme/theme_provider.dart';

/// Language + theme only — Settings for Phase 6 localization/theme
/// verification. Shell provides Scaffold/AppBar; this is content only.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const Map<AppLocale, String> languageNames = {
    AppLocale.ar: 'العربية',
    AppLocale.fr: 'Français',
    AppLocale.en: 'English',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final localeState = ref.watch(localeProvider);
    final themeState = ref.watch(themeProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.t('settings', loc),
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('language', loc),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<AppLocale>(
                    key: const Key('settings-language-dropdown'),
                    initialValue: localeState.locale,
                    isExpanded: true,
                    items: [
                      for (final entry in languageNames.entries)
                        DropdownMenuItem<AppLocale>(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        ref.read(localeProvider.notifier).setLocale(value);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('theme', loc),
                    style: theme.textTheme.titleMedium,
                  ),
                  RadioGroup<AppThemeMode>(
                    groupValue: themeState.mode,
                    onChanged: (value) {
                      if (value != null) {
                        ref.read(themeProvider.notifier).setTheme(value);
                      }
                    },
                    child: Column(
                      children: [
                        RadioListTile<AppThemeMode>(
                          key: const Key('settings-theme-dark'),
                          title: Text(AppStrings.t('dark_theme', loc)),
                          value: AppThemeMode.dark,
                        ),
                        RadioListTile<AppThemeMode>(
                          key: const Key('settings-theme-light'),
                          title: Text(AppStrings.t('light_theme', loc)),
                          value: AppThemeMode.light,
                        ),
                        RadioListTile<AppThemeMode>(
                          key: const Key('settings-theme-grey'),
                          title: Text(AppStrings.t('grey_theme', loc)),
                          value: AppThemeMode.grey,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
