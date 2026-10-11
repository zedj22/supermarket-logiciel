// About Supermarket Pro (Phase 2) — application identity page.
//
// Shows the localized app name, the drawn AppLogoMark, the verified
// capability cards, the Flutter + server version metadata and the Klick
// POS developer credit. The Documentation button opens the in-app
// Documentation Center (Phase 3).
//
// Additive only: no business logic, no new dependencies. Motion is
// lightweight (opacity + a few pixels of rise, ≤ 300 ms) and fully
// disabled when the platform requests reduced motion.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/constants.dart';
import '../../core/strings.dart';
import '../../core/widgets/logo_mark.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme.dart';
import 'about_providers.dart';

/// Developer / brand credit shown on the About page. Approved display
/// name — never derived from build metadata (see Phase 1 audit §9).
const String kDeveloperName = 'Klick POS';

/// Fixed legal line from the Windows resources (`windows/runner/Runner.rc`
/// `LegalCopyright`). Rendered LTR in every locale, like all legal text.
const String kCopyrightLine =
    'Copyright (C) 2026 com.supermarket. All rights reserved.';

/// One verified capability shown as a card. Icons match the navigation
/// rail's for the same feature so the About page reads as a summary of
/// the app the operator already uses.
class _AboutFeature {
  const _AboutFeature({
    required this.id,
    required this.icon,
    required this.titleKey,
    required this.descKey,
  });

  final String id;
  final IconData icon;
  final String titleKey;
  final String descKey;
}

const List<_AboutFeature> _features = <_AboutFeature>[
  _AboutFeature(
    id: 'pos',
    icon: Icons.point_of_sale,
    titleKey: 'about_feature_pos',
    descKey: 'about_feature_pos_desc',
  ),
  _AboutFeature(
    id: 'catalog',
    icon: Icons.inventory_2,
    titleKey: 'about_feature_catalog',
    descKey: 'about_feature_catalog_desc',
  ),
  _AboutFeature(
    id: 'inventory',
    icon: Icons.warehouse,
    titleKey: 'about_feature_inventory',
    descKey: 'about_feature_inventory_desc',
  ),
  _AboutFeature(
    id: 'invoicing',
    icon: Icons.description,
    titleKey: 'about_feature_invoicing',
    descKey: 'about_feature_invoicing_desc',
  ),
  _AboutFeature(
    id: 'reports',
    icon: Icons.summarize,
    titleKey: 'about_feature_reports',
    descKey: 'about_feature_reports_desc',
  ),
  _AboutFeature(
    id: 'lan',
    icon: Icons.devices,
    titleKey: 'about_feature_lan',
    descKey: 'about_feature_lan_desc',
  ),
];

/// Total window in which every staggered card finishes (≤ 300 ms cap).
const Duration _entranceDuration = Duration(milliseconds: 300);

/// Gap between two consecutive card starts (total span 5 × 40 = 200 ms).
const Duration _cardStagger = Duration(milliseconds: 40);

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final systemInfo = ref.watch(systemInfoProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return SingleChildScrollView(
      key: const Key('about-screen'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 32, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FadeRise(
                  reduceMotion: reduceMotion,
                  child: _Hero(
                    loc: loc,
                    theme: theme,
                  ),
                ),
                const SizedBox(height: 32),
                _FeatureGrid(loc: loc, theme: theme, reduceMotion: reduceMotion),
                const SizedBox(height: 32),
                _FadeRise(
                  reduceMotion: reduceMotion,
                  child: _InfoCard(loc: loc, theme: theme, systemInfo: systemInfo),
                ),
                const SizedBox(height: 24),
                _FadeRise(
                  reduceMotion: reduceMotion,
                  child: _Actions(loc: loc),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Entrance motion — fade + a few px of rise, one shared helper
// ---------------------------------------------------------------------------

/// Fades [child] in while it rises ~12 px. Zero duration under reduced
/// motion, so the page simply appears.
class _FadeRise extends StatelessWidget {
  const _FadeRise({required this.child, required this.reduceMotion});

  final Widget child;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: _entranceDuration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({required this.loc, required this.theme});

  final String loc;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('about-hero'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppLogoMark(size: 72),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.t('app_name', loc),
                key: const Key('about-hero-title'),
                style: AppTheme.pageTitle(theme),
              ),
              const SizedBox(height: 6),
              Text(
                AppStrings.t('about_description', loc),
                key: const Key('about-hero-description'),
                style: AppTheme.body(theme).copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                kDeveloperName,
                key: const Key('about-developer-value'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Feature grid
// ---------------------------------------------------------------------------

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({
    required this.loc,
    required this.theme,
    required this.reduceMotion,
  });

  final String loc;
  final ThemeData theme;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 640
            ? 3
            : constraints.maxWidth >= 400
                ? 2
                : 1;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var i = 0; i < _features.length; i++)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 16) / columns,
                height: 148,
                child: _Staggered(
                  index: i,
                  reduceMotion: reduceMotion,
                  child: _FeatureCard(
                    feature: _features[i],
                    loc: loc,
                    theme: theme,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Wraps one card in its staggered entrance. Each card animates for
/// [_entranceDuration] inside a shared window; card `i` starts at
/// `i × _cardStagger`. Clamped so every card completes by the window end.
class _Staggered extends StatelessWidget {
  const _Staggered({
    required this.index,
    required this.child,
    required this.reduceMotion,
  });

  final int index;
  final Widget child;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) return child;
    final totalMs = _entranceDuration.inMilliseconds;
    final start = (index * _cardStagger.inMilliseconds) / totalMs;
    final end = (start + 0.8).clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: _entranceDuration,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.feature,
    required this.loc,
    required this.theme,
  });

  final _AboutFeature feature;
  final String loc;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final accent = theme.colorScheme.primary;
    return Card(
      key: Key('about-feature-${feature.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: AlignmentDirectional.topStart,
                  end: AlignmentDirectional.bottomEnd,
                  colors: [accent, accent.withValues(alpha: 0.75)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(feature.icon, size: 22, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.t(feature.titleKey, loc),
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                AppStrings.t(feature.descKey, loc),
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Version / information card
// ---------------------------------------------------------------------------

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.loc,
    required this.theme,
    required this.systemInfo,
  });

  final String loc;
  final ThemeData theme;
  final AsyncValue<SystemInfo?> systemInfo;

  @override
  Widget build(BuildContext context) {
    final secondary = theme.textTheme.bodySmall;
    return Card(
      key: const Key('about-info-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('about_information', loc),
              style: AppTheme.sectionTitle(theme),
            ),
            const SizedBox(height: 16),
            _InfoRow(
              loc: loc,
              theme: theme,
              label: AppStrings.t('about_application', loc),
              value: AppStrings.t('app_name', loc),
            ),
            _InfoRow(
              loc: loc,
              theme: theme,
              label: AppStrings.t('about_application_version', loc),
              value: AppConstants.appVersion,
              valueKey: const Key('about-app-version'),
            ),
            _ServerInfoRow(loc: loc, theme: theme, systemInfo: systemInfo),
            _InfoRow(
              loc: loc,
              theme: theme,
              label: AppStrings.t('about_developer', loc),
              value: kDeveloperName,
              valueKey: const Key('about-developer-info'),
              valueIsLtr: true,
            ),
            const SizedBox(height: 8),
            Text(
              kCopyrightLine,
              key: const Key('about-copyright'),
              textDirection: TextDirection.ltr,
              style: secondary?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One label/value row. Values that are technical identifiers (versions,
/// the brand name) stay LTR inside an RTL layout.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.loc,
    required this.theme,
    required this.label,
    required this.value,
    this.valueKey,
    this.valueIsLtr = false,
  });

  final String loc;
  final ThemeData theme;
  final String label;
  final String value;
  final Key? valueKey;

  /// True for versions / brand names that must read left-to-right in
  /// every locale.
  final bool valueIsLtr;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Directionality(
            textDirection: valueIsLtr
                ? TextDirection.ltr
                : Directionality.of(context),
            child: Text(
              value,
              key: valueKey,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Server name + version from `GET /api/v1/system/info`, with a loading
/// indicator while the request is in flight and a localized placeholder
/// when the server cannot be reached. Never shows an exception.
class _ServerInfoRow extends StatelessWidget {
  const _ServerInfoRow({
    required this.loc,
    required this.theme,
    required this.systemInfo,
  });

  final String loc;
  final ThemeData theme;
  final AsyncValue<SystemInfo?> systemInfo;

  @override
  Widget build(BuildContext context) {
    return systemInfo.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                AppStrings.t('about_server', loc),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
      error: (_, _) => _unavailable(),
      data: (info) {
        if (info == null) return _unavailable();
        return Column(
          children: [
            _InfoRow(
              loc: loc,
              theme: theme,
              label: AppStrings.t('about_server_store', loc),
              value: info.name,
              valueKey: const Key('about-server-store'),
            ),
            _InfoRow(
              loc: loc,
              theme: theme,
              label: AppStrings.t('about_server_version', loc),
              value: info.version,
              valueKey: const Key('about-server-version'),
              valueIsLtr: true,
            ),
          ],
        );
      },
    );
  }

  Widget _unavailable() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.t('about_server', loc),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              AppStrings.t('about_server_unavailable', loc),
              key: const Key('about-server-unavailable'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

class _Actions extends StatelessWidget {
  const _Actions({required this.loc});

  final String loc;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const Key('about-documentation-button'),
      onPressed: () => context.go('/documentation'),
      icon: const Icon(Icons.menu_book_outlined),
      label: Text(AppStrings.t('about_documentation', loc)),
    );
  }
}
