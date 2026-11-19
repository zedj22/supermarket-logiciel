import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../core/widgets/status_chip.dart';
import '../../theme/app_theme.dart';
import 'license_info.dart';
import 'license_providers.dart';
import 'license_snapshot.dart';

Color _accentOf(BuildContext context, LicenseStatus status) => switch (status) {
      LicenseStatus.active => AppColors.success,
      LicenseStatus.expired => AppColors.error,
      LicenseStatus.unavailable => AppColors.info,
    };

StatusTone _toneOf(LicenseStatus status) => switch (status) {
      LicenseStatus.active => StatusTone.success,
      LicenseStatus.expired => StatusTone.error,
      LicenseStatus.unavailable => StatusTone.neutral,
    };

IconData _iconOf(LicenseStatus status) => switch (status) {
      LicenseStatus.active => Icons.schedule,
      LicenseStatus.expired => Icons.event_busy,
      LicenseStatus.unavailable => Icons.help_outline,
    };

String _labelOf(LicenseStatus status, String loc) => switch (status) {
      LicenseStatus.active => AppStrings.t('license_trial_active', loc),
      LicenseStatus.expired => AppStrings.t('license_trial_expired', loc),
      LicenseStatus.unavailable =>
        AppStrings.t('license_status_unavailable', loc),
    };

String _remainingText(LicenseInfo license, DateTime now, String loc) {
  final left = license.remainingAt(now);
  final days = left.inDays;
  final hours = (left.inHours % 24);
  final minutes = (left.inMinutes % 60);
  return AppStrings.t('license_time_remaining', loc)
      .replaceAll('{d}', '$days')
      .replaceAll('{h}', '$hours')
      .replaceAll('{m}', '$minutes');
}

String _expiresText(LicenseInfo license, String loc) {
  final expires = license.expiresAt;
  final date =
      expires == null ? '' : DateFormat('yyyy-MM-dd').format(expires.toLocal());
  return AppStrings.t('license_expires_on', loc).replaceAll('{date}', date);
}

String _trialDaysText(LicenseInfo license, String loc) {
  return AppStrings.t('license_trial_days', loc)
      .replaceAll('{n}', '${license.trialDays ?? 0}');
}

/// Rebuilds [builder] once a minute so the countdown and the local-clock
/// expiry flip stay current between system-info responses. The timer only
/// exists while a license snapshot is on screen.
class _LiveLicenseView extends StatefulWidget {
  const _LiveLicenseView({required this.license, required this.builder});

  final LicenseInfo license;
  final Widget Function(BuildContext context, DateTime now, LicenseInfo license)
      builder;

  @override
  State<_LiveLicenseView> createState() => _LiveLicenseViewState();
}

class _LiveLicenseViewState extends State<_LiveLicenseView> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now, widget.license);
}

/// Slim, always-visible trial strip for the authenticated shell. Hidden
/// until a system-info response has produced a snapshot (`null` = nothing
/// known yet — never rendered as an active license). Tapping it opens the
/// licensing screen.
class TrialStatusBanner extends ConsumerWidget {
  const TrialStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Phase L2-C: a verified Lifetime snapshot outranks the trial block —
    // a licensed install never shows a red "trial expired" strip.
    final lifetime = ref.watch(licenseSnapshotProvider)?.isLifetime ?? false;
    final license = ref.watch(licenseStatusProvider);
    if (!lifetime && license == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    if (lifetime) {
      final onAccent = AppColors.onTint(AppColors.success, theme.brightness);
      return Material(
        color: AppColors.tint(AppColors.success, theme.brightness),
        child: InkWell(
          key: const Key('license-banner'),
          onTap: () => context.go('/licensing'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.verified, size: 18, color: onAccent),
                const SizedBox(width: 10),
                StatusChip(
                  label: AppStrings.t('license_lifetime_active', loc),
                  tone: StatusTone.success,
                  testKey: const Key('license-banner-chip'),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    AppStrings.t('license_lifetime_notice', loc),
                    key: const Key('license-banner-lifetime'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.caption(theme).copyWith(
                      color: onAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _LiveLicenseView(
      license: license!,
      builder: (context, now, license) {
        final theme = Theme.of(context);
        final loc = Localizations.localeOf(context).languageCode;
        final status = license.effectiveStatusAt(now);
        final accent = _accentOf(context, status);
        final onAccent = AppColors.onTint(accent, theme.brightness);
        return Material(
          color: AppColors.tint(accent, theme.brightness),
          child: InkWell(
            key: const Key('license-banner'),
            onTap: () => context.go('/licensing'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(_iconOf(status), size: 18, color: onAccent),
                  const SizedBox(width: 10),
                  StatusChip(
                    label: _labelOf(status, loc),
                    tone: _toneOf(status),
                    testKey: const Key('license-banner-chip'),
                  ),
                  if (status == LicenseStatus.active) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _remainingText(license, now, loc),
                        key: const Key('license-banner-remaining'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.caption(theme).copyWith(
                          color: onAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (license.expiresAt != null) ...[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _expiresText(license, loc),
                          key: const Key('license-banner-expires'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.caption(theme).copyWith(
                            color: onAccent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Detailed license card for the licensing screen: status chip, remaining
/// time, expiration date, trial length, and the state-specific message
/// (active notice / expired guidance / unavailable explanation).
class TrialStatusCard extends StatelessWidget {
  const TrialStatusCard({super.key, required this.license});

  final LicenseInfo license;

  @override
  Widget build(BuildContext context) {
    return _LiveLicenseView(
      license: license,
      builder: (context, now, license) {
        final theme = Theme.of(context);
        final loc = Localizations.localeOf(context).languageCode;
        final status = license.effectiveStatusAt(now);
        final accent = _accentOf(context, status);
        return Card(
          key: const Key('license-card'),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.6),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_iconOf(status), color: accent, size: 22),
                    const SizedBox(width: 10),
                    StatusChip(
                      label: _labelOf(status, loc),
                      tone: _toneOf(status),
                      testKey: const Key('license-card-chip'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (status == LicenseStatus.active) ...[
                  _CardRow(
                    icon: Icons.schedule,
                    text: _remainingText(license, now, loc),
                    textKey: const Key('license-card-remaining'),
                  ),
                  if (license.expiresAt != null) ...[
                    const SizedBox(height: 8),
                    _CardRow(
                      icon: Icons.event,
                      text: _expiresText(license, loc),
                      textKey: const Key('license-card-expires'),
                    ),
                  ],
                  if (license.trialDays != null) ...[
                    const SizedBox(height: 8),
                    _CardRow(
                      icon: Icons.today,
                      text: _trialDaysText(license, loc),
                      textKey: const Key('license-card-days'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.t('license_trial_notice', loc),
                    key: const Key('license-card-notice'),
                    style: AppTheme.secondary(theme),
                  ),
                ] else if (status == LicenseStatus.expired)
                  Text(
                    AppStrings.t('license_expired_message', loc),
                    key: const Key('license-card-message'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                else
                  Text(
                    AppStrings.t('license_unavailable_message', loc),
                    key: const Key('license-card-message'),
                    style: AppTheme.secondary(theme),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Detailed status card for a verified Lifetime license (Phase L2-C):
/// success chip, activation date, license id and the lifetime notice.
/// Rendered in place of [TrialStatusCard] whenever the licensing
/// snapshot reports `mode: lifetime` — the trial block is no longer the
/// story of a licensed install.
class LifetimeStatusCard extends StatelessWidget {
  const LifetimeStatusCard({super.key, required this.snapshot});

  final LicenseSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final activatedAt = snapshot.activatedAt;
    return Card(
      key: const Key('lifetime-card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified, color: AppColors.success, size: 22),
                const SizedBox(width: 10),
                StatusChip(
                  label: AppStrings.t('license_lifetime_active', loc),
                  tone: StatusTone.success,
                  testKey: const Key('lifetime-card-chip'),
                ),
              ],
            ),
            if (activatedAt != null) ...[
              const SizedBox(height: 16),
              _CardRow(
                icon: Icons.event_available,
                text: AppStrings.t('license_activation_activated_on', loc)
                    .replaceAll(
                  '{date}',
                  activatedAt.toLocal().toString().split('T').first,
                ),
                textKey: const Key('lifetime-card-activated'),
              ),
            ],
            if (snapshot.licenseId != null) ...[
              const SizedBox(height: 8),
              _CardRow(
                icon: Icons.tag,
                text: AppStrings.t('license_lifetime_license_id', loc)
                    .replaceAll('{id}', snapshot.licenseId!),
                textKey: const Key('lifetime-card-id'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              AppStrings.t('license_lifetime_notice', loc),
              key: const Key('lifetime-card-notice'),
              style: AppTheme.secondary(theme),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.icon, required this.text, this.textKey});

  final IconData icon;
  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            key: textKey,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
