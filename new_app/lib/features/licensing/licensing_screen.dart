import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'activation_panel.dart';
import 'license_info.dart';
import 'license_providers.dart';
import 'license_snapshot.dart';
import 'license_widgets.dart';

/// Dedicated licensing surface (Phase L1-C, Phase L2-C activation).
/// Reachable before login from the login screen's "View license" action
/// and parked on automatically when the trial is expired. It presents
/// the trial (or Lifetime) status and hosts the Lifetime activation
/// panel; the backend `license_guard` remains the enforcement authority —
/// this screen only presents, asks and reports.
class LicensingScreen extends ConsumerWidget {
  const LicensingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final auth = ref.watch(authProvider);
    final license = ref.watch(licenseStatusProvider) ??
        const LicenseInfo.unknown();
    final LicenseSnapshot? snapshot = ref.watch(licenseSnapshotProvider);
    final licensed = snapshot?.isLifetime ?? false;
    final expired = license.effectiveStatusAt(DateTime.now()) ==
        LicenseStatus.expired;
    final authenticated = auth.status == AuthStatus.authenticated;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(AppStrings.t('license_screen_title', loc)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.security,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.t('license_screen_title', loc),
                    key: const Key('license-screen-title'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  // Phase L2-C: a verified Lifetime license replaces the
                  // trial card entirely — the install is not trial-limited.
                  if (licensed && snapshot != null)
                    LifetimeStatusCard(snapshot: snapshot)
                  else
                    TrialStatusCard(license: license),
                  const SizedBox(height: 20),
                  // Phase L2-C: the activation entry itself, always
                  // reachable — including on an expired trial (the rescue
                  // path) and before login.
                  ActivationPanel(licensed: licensed),
                  const SizedBox(height: 20),
                  // A licensed install is never parked here by an expired
                  // trial, so the normal navigation action returns.
                  if (!expired || licensed)
                    TextButton(
                      key: const Key('license-back-button'),
                      onPressed: () =>
                          context.go(authenticated ? '/' : '/login'),
                      child: Text(
                        AppStrings.t(
                          authenticated ? 'license_back' : 'license_back_to_login',
                          loc,
                        ),
                      ),
                    )
                  else if (authenticated)
                    TextButton(
                      key: const Key('license-logout-button'),
                      onPressed: () =>
                          ref.read(authProvider.notifier).logout(),
                      child: Text(AppStrings.t('logout', loc)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
