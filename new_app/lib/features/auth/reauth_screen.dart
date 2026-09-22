import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'auth_provider.dart';
import 'pin_pad.dart';

class ReauthScreen extends ConsumerStatefulWidget {
  final VoidCallback? onVerified;

  const ReauthScreen({super.key, this.onVerified});

  @override
  ConsumerState<ReauthScreen> createState() => _ReauthScreenState();
}

class _ReauthScreenState extends ConsumerState<ReauthScreen> {
  bool _verified = false;
  bool _loading = false;
  String? _error;

  void _onPinEntered(String pin) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final success = await ref.read(authProvider.notifier).reauth(pin);
    setState(() {
      _loading = false;
      if (success) {
        _verified = true;
      } else {
        _error = AppStrings.t(
          'reauth_failed',
          ref.read(localeProvider).flutterLocale.languageCode,
        );
      }
    });
    if (success && widget.onVerified != null) {
      widget.onVerified!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = ref.watch(localeProvider);
    final loc = locale.flutterLocale.languageCode;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.t('reauth_title', loc),
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.t('reauth_subtitle', loc),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 24),
                if (_verified) ...[
                  Icon(
                    Icons.check_circle,
                    color: theme.colorScheme.primary,
                    size: 48,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.t('reauth_success', loc),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ] else ...[
                  PinPad(
                    locale: loc,
                    maxLength: 6,
                    onSubmit: _onPinEntered,
                    enabled: !_loading,
                    errorText: _error,
                  ),
                ],
                if (_loading) ...[
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
