import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../theme/app_theme.dart';
import 'license_providers.dart';

/// The Lifetime activation surface (Phase L2-C), embedded in the
/// pre-login [LicensingScreen]: generates and shows the activation
/// request code (with copy-to-clipboard), accepts the signed `SMP1.…`
/// code, submits it through `POST /api/v1/license/activate`, and renders
/// every outcome with the localization key carried by the actual backend
/// error — success, invalid code/signature, wrong machine, unknown key,
/// already activated, rate limited and network/server failures.
///
/// The backend remains the enforcement authority; this panel only asks,
/// reports and refreshes. Layout stays direction-agnostic so Arabic RTL
/// mirrors correctly.
class ActivationPanel extends ConsumerStatefulWidget {
  const ActivationPanel({super.key, required this.licensed});

  /// True when the current snapshot already reports a verified Lifetime
  /// license — rendered as the "already activated" state above the form.
  final bool licensed;

  @override
  ConsumerState<ActivationPanel> createState() => _ActivationPanelState();
}

class _ActivationPanelState extends ConsumerState<ActivationPanel> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // First mount: know the current status (best-effort) and make sure a
    // request code is on screen without requiring a tap. Every step is
    // guarded — a disposed widget or an unreachable server must not
    // surface as an unhandled error.
    Future<void>(() async {
      if (!mounted) return;
      final controller = ref.read(activationControllerProvider.notifier);
      if (ref.read(licenseSnapshotProvider) == null) {
        await controller.ensureStatus();
      }
      if (!mounted) return;
      if (!ref.read(activationControllerProvider).hasRequest) {
        await controller.requestCode();
      }
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final loc = Localizations.localeOf(context).languageCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          AppStrings.t('license_activation_copied', loc),
          key: const Key('license-activation-copied-snack'),
        ),
      ),
    );
  }

  Future<void> _submit(ActivationState state) async {
    final accepted = await ref
        .read(activationControllerProvider.notifier)
        .activate(_codeController.text);
    if (accepted && mounted) _codeController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final state = ref.watch(activationControllerProvider);
    final submitting = state.phase == ActivationPhase.submitting;
    final requesting = state.phase == ActivationPhase.requesting;
    final failure = state.phase == ActivationPhase.failure;
    final success = state.phase == ActivationPhase.success;

    return Card(
      key: const Key('license-activation-panel'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.add_task, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    AppStrings.t('license_activation_title', loc),
                    key: const Key('license-activation-title'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('license_activation_intro', loc),
              key: const Key('license-activation-intro'),
              style: AppTheme.secondary(theme),
            ),
            if (widget.licensed) ...[
              const SizedBox(height: 12),
              _NoticeBox(
                color: AppColors.success,
                icon: Icons.verified,
                text: AppStrings.t('license_activation_already', loc),
                textKey: const Key('license-activation-already'),
              ),
            ],
            const SizedBox(height: 16),
            // ---- Request code (generated, copyable) --------------------
            if (requesting && !state.hasRequest)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    key: Key('license-activation-request-progress'),
                  ),
                ),
              )
            else ...[
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  key: const Key('license-activation-request-button'),
                  onPressed:
                      requesting ? null : () => ref
                          .read(activationControllerProvider.notifier)
                          .requestCode(),
                  icon: const Icon(Icons.manage_search),
                  label: Text(AppStrings.t('license_activation_request', loc)),
                ),
              ),
              if (state.hasRequest) ...[
                const SizedBox(height: 12),
                _CopyableRow(
                  label: AppStrings.t('license_activation_request_label', loc),
                  labelKey: const Key('license-activation-request-label'),
                  value: state.requestCode!,
                  valueKey: const Key('license-activation-request-code'),
                  copyKey: const Key('license-activation-copy-request'),
                  onPressed: () => _copy(state.requestCode!),
                ),
                if (state.fingerprintDisplayCode != null) ...[
                  const SizedBox(height: 8),
                  _CopyableRow(
                    label:
                        AppStrings.t('license_activation_fingerprint_label', loc),
                    labelKey: const Key('license-activation-fingerprint-label'),
                    value: state.fingerprintDisplayCode!,
                    valueKey: const Key('license-activation-fingerprint'),
                    copyKey: const Key('license-activation-copy-fingerprint'),
                    onPressed: () =>
                        _copy(state.fingerprintDisplayCode!),
                  ),
                ],
              ],
            ],
            const SizedBox(height: 16),
            // ---- Signed activation code entry --------------------------
            TextField(
              key: const Key('license-activation-input'),
              controller: _codeController,
              minLines: 2,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: AppStrings.t('license_activation_code_label', loc),
                hintText: AppStrings.t('license_activation_code_hint', loc),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                key: const Key('license-activation-submit'),
                onPressed: submitting ? null : () => _submit(state),
                child: submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          key: Key('license-activation-progress'),
                        ),
                      )
                    : Text(AppStrings.t('license_activation_submit', loc)),
              ),
            ),
            if (failure && state.errorMessageKey != null) ...[
              const SizedBox(height: 12),
              Text(
                AppStrings.t(state.errorMessageKey!, loc),
                key: const Key('license-activation-error'),
                textAlign: TextAlign.start,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (success) ...[
              const SizedBox(height: 12),
              _NoticeBox(
                color: AppColors.success,
                icon: Icons.check_circle_outline,
                text: AppStrings.t('license_activation_success', loc),
                textKey: const Key('license-activation-success'),
                trailing: _activatedOnText(context, loc),
                trailingKey: const Key('license-activation-success-date'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _activatedOnText(BuildContext context, String loc) {
    final snapshot = ref.read(licenseSnapshotProvider);
    final activatedAt = snapshot?.activatedAt;
    if (activatedAt == null) return null;
    final date = activatedAt.toLocal().toString().split('T').first;
    return AppStrings.t('license_activation_activated_on', loc)
        .replaceAll('{date}', date);
  }
}

/// Tinted information strip used for the "already activated" and
/// "activation succeeded" states.
class _NoticeBox extends StatelessWidget {
  const _NoticeBox({
    required this.color,
    required this.icon,
    required this.text,
    required this.textKey,
    this.trailing,
    this.trailingKey,
  });

  final Color color;
  final IconData icon;
  final String text;
  final Key textKey;
  final String? trailing;
  final Key? trailingKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.tint(color, theme.brightness),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  key: textKey,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (trailing != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 26),
              child: Text(
                trailing!,
                key: trailingKey,
                style: AppTheme.secondary(theme),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Label + selectable long value + copy action, RTL-safe (the Row flips
/// with the ambient directionality).
class _CopyableRow extends StatelessWidget {
  const _CopyableRow({
    required this.label,
    required this.labelKey,
    required this.value,
    required this.valueKey,
    required this.copyKey,
    required this.onPressed,
  });

  final String label;
  final Key labelKey;
  final String value;
  final Key valueKey;
  final Key copyKey;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, key: labelKey, style: AppTheme.secondary(theme)),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                key: valueKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: copyKey,
              onPressed: onPressed,
              tooltip: AppStrings.t(
                'license_activation_copy',
                Localizations.localeOf(context).languageCode,
              ),
              icon: const Icon(Icons.copy, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}
