// Phase 16 — first-run / network setup wizard (§23.1).
//
// Flow (§13.1 left half):
//   role → searching → confirm → pairing code → waiting approval → done
//                       ↘ timeout / not-a-server → manual entry
//
// Mandatory on first run (unclosable): a client that has never chosen a
// role cannot present a device identity, so there is nothing sensible to
// show behind it. Later it is reachable from Settings with `device_manage`.
//
// Nothing here writes business data — pairing only creates a `pending`
// device row that an administrator must approve (§12.2).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/strings.dart';
import '../../../core/widgets/logo_mark.dart';
import '../../../core/widgets/state_views.dart';
import '../../../l10n/locale_provider.dart';
import 'connection_provider.dart';
import 'device_identity.dart';
import 'discovery_service.dart';

enum WizardStep { role, searching, confirm, code, waiting, failed }

class SetupWizardScreen extends ConsumerStatefulWidget {
  /// True on first run: the wizard cannot be dismissed.
  final bool mandatory;

  const SetupWizardScreen({super.key, this.mandatory = true});

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  WizardStep _step = WizardStep.role;
  ServerOffer? _offer;
  final _hostController = TextEditingController();
  final _codeController = TextEditingController();
  String? _errorKey;
  Timer? _searchTimer;
  int _remaining = 300;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _hostController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // -- role ----------------------------------------------------------------

  Future<void> _chooseRole(String mode) async {
    await writeAppRunMode(mode);
    // Let the router re-evaluate the first-run guard immediately.
    ref.invalidate(networkConfiguredProvider);
    if (!mounted) return;
    if (mode == appRunModeServer) {
      // The server does not pair with itself; it is the box others pair to.
      context.go('/');
      return;
    }
    setState(() {
      _step = WizardStep.searching;
      _errorKey = null;
    });
    _startSearch();
  }

  // -- discovery -----------------------------------------------------------

  void _startSearch() {
    ref.read(lanConnectionProvider.notifier).startDiscovery();
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _step == WizardStep.searching) {
        setState(() {});
      }
    });
  }

  Future<void> _selectOffer(ServerOffer offer) async {
    final ok = await ref.read(lanConnectionProvider.notifier).probe(offer.baseUrl);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _offer = offer;
        _step = WizardStep.confirm;
        _errorKey = null;
      });
    } else {
      setState(() => _errorKey = 'lan_server_not_supermarket');
    }
  }

  Future<void> _manualConnect() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    final port = 8000;
    final url = host.startsWith('http') ? host : 'http://$host:$port';
    final ok = await ref.read(lanConnectionProvider.notifier).probe(url);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _step = WizardStep.confirm;
        _errorKey = null;
      });
    } else {
      setState(() => _errorKey = 'lan_server_not_supermarket');
    }
  }

  // -- pairing -------------------------------------------------------------

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _errorKey = 'lan_pairing_code_invalid');
      return;
    }
    final conn = ref.read(lanConnectionProvider.notifier);
    final displayName = _offer?.name.isNotEmpty == true
        ? _offer!.name
        : Platform.localHostname;
    final ok = await conn.requestPairing(code: code, displayName: displayName);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _step = WizardStep.waiting;
        _errorKey = null;
        _remaining = 300;
      });
      _tickCountdown();
    } else {
      final error = ref.read(lanConnectionProvider).errorMessage;
      setState(() {
        _errorKey = error == 'PAIRING_CODE_INVALID'
            ? 'lan_pairing_code_invalid'
            : (error == 'unreachable'
                ? 'lan_server_unreachable'
                : 'lan_pairing_code_invalid');
      });
    }
  }

  void _tickCountdown() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final phase = ref.read(lanConnectionProvider).phase;
      if (phase == LanPhase.connected) {
        timer.cancel();
        ref.invalidate(networkConfiguredProvider);
        context.go('/');
        return;
      }
      if (phase == LanPhase.rejected) {
        timer.cancel();
        setState(() {
          _step = WizardStep.failed;
          _errorKey = _rejectedKey();
        });
        return;
      }
      if (_remaining <= 0) {
        timer.cancel();
        setState(() {
          _step = WizardStep.failed;
          _errorKey = 'lan_pairing_timeout';
        });
        return;
      }
      setState(() => _remaining--);
    });
  }

  String _rejectedKey() {
    final code = ref.read(lanConnectionProvider).deviceErrorCode;
    if (code == 'device_revoked') return 'lan_device_revoked_body';
    if (code == 'PAIRING_CODE_INVALID') return 'lan_pairing_code_invalid';
    return 'lan_pairing_rejected_body';
  }

  void _retrySearch() {
    setState(() {
      _step = WizardStep.searching;
      _errorKey = null;
      _codeController.clear();
    });
    _startSearch();
  }

  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final conn = ref.watch(lanConnectionProvider);
    final offers = conn.offers;

    final body = switch (_step) {
      WizardStep.role => _buildRole(loc),
      WizardStep.searching => _buildSearching(loc, offers),
      WizardStep.confirm => _buildConfirm(loc),
      WizardStep.code => _buildCode(loc, conn.errorMessage),
      WizardStep.waiting => _buildWaiting(loc),
      WizardStep.failed => _buildFailed(loc),
    };

    return PopScope(
      canPop: !widget.mandatory,
      child: Scaffold(
        appBar: AppBar(
          title: Text(AppStrings.t('lan_wizard_title', loc)),
          automaticallyImplyLeading: !widget.mandatory,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _stepBar(loc),
                    const SizedBox(height: 16),
                    body,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -- step indicator (§ PART 12) -----------------------------------------

  /// Pill strip of the five pairing stages, shown above every step so the
  /// worker always knows how far along the setup is. `Wrap` (not `Row`) so
  /// the longer French/Arabic labels flow onto a second line on a 560px
  /// column instead of overflowing; the failed step highlights its origin
  /// (the pairing code), not a phantom stage.
  Widget _stepBar(String loc) {
    const steps = <(WizardStep, String)>[
      (WizardStep.role, 'lan_step_role'),
      (WizardStep.searching, 'lan_step_search'),
      (WizardStep.confirm, 'lan_step_confirm'),
      (WizardStep.code, 'lan_step_code'),
      (WizardStep.waiting, 'lan_step_approve'),
    ];
    final active = switch (_step) {
      WizardStep.role => 0,
      WizardStep.searching => 1,
      WizardStep.confirm => 2,
      WizardStep.code || WizardStep.failed => 3,
      WizardStep.waiting => 4,
    };
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Wrap(
      key: const Key('wizard-step-bar'),
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < steps.length; i++)
          Container(
            key: Key('wizard-step-$i'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: i == active
                  ? accent
                  : i < active
                      ? accent.withValues(alpha: 0.12)
                      : theme.dividerColor.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i < active)
                  Icon(Icons.check, size: 13, color: accent)
                else
                  Text(
                    '${i + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: i == active
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 5),
                Text(
                  AppStrings.t(steps[i].$2, loc),
                  key: Key('wizard-step-label-$i'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: i == active
                        ? theme.colorScheme.onPrimary
                        : i < active
                            ? accent
                            : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRole(String loc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: AppLogoMark(size: 44)),
        const SizedBox(height: 16),
        Text(
          AppStrings.t('lan_wizard_title', loc),
          key: const Key('wizard-title'),
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t('lan_first_run_hint', loc),
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _RoleCard(
          key: const Key('role-server'),
          icon: Icons.dns_outlined,
          title: AppStrings.t('lan_server_role', loc),
          body: AppStrings.t('lan_role_server_desc', loc),
          onTap: () => _chooseRole(appRunModeServer),
        ),
        const SizedBox(height: 12),
        _RoleCard(
          key: const Key('role-client'),
          icon: Icons.computer_outlined,
          title: AppStrings.t('lan_client_role', loc),
          body: AppStrings.t('lan_role_client_desc', loc),
          onTap: () => _chooseRole(appRunModeClient),
        ),
      ],
    );
  }

  Widget _buildSearching(String loc, List<ServerOffer> offers) {
    final timedOut = (_searchTimer?.isActive ?? false) == false && offers.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(key: Key('wizard-searching')),
          ),
        ),
        Text(
          AppStrings.t('lan_searching_server', loc),
          key: const Key('wizard-searching-label'),
          textAlign: TextAlign.center,
        ),
        if (timedOut)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            // Friendly dead-end state: icon + copy instead of a bare red
            // line — the manual entry below it is the way out.
            child: EmptyState(
              message: AppStrings.t('lan_search_timeout', loc),
              messageKey: const Key('wizard-timeout'),
              icon: Icons.wifi_off_outlined,
              accent: Theme.of(context).colorScheme.error,
              compact: true,
            ),
          ),
        const SizedBox(height: 16),
        for (final offer in offers)
          Card(
            child: ListTile(
              key: Key('offer-${offer.serverId}'),
              leading: const Icon(Icons.store),
              title: Text(offer.name.isEmpty
                  ? AppStrings.t('lan_server_found', loc)
                  : offer.name),
              subtitle: Text('${offer.address}:${offer.httpPort}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectOffer(offer),
            ),
          ),
        const SizedBox(height: 24),
        Text(
          AppStrings.t('lan_manual_entry', loc),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('manual-host'),
                controller: _hostController,
                decoration: InputDecoration(
                  labelText: AppStrings.t('lan_ip_label', loc),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('manual-connect'),
              onPressed: _manualConnect,
              child: Text(AppStrings.t('lan_connect', loc)),
            ),
          ],
        ),
        if (_errorKey != null) ...[
          const SizedBox(height: 12),
          Text(
            AppStrings.t(_errorKey!, loc),
            key: const Key('wizard-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: _startSearch,
          child: Text(AppStrings.t('lan_retry', loc)),
        ),
      ],
    );
  }

  Widget _buildConfirm(String loc) {
    final name = ref.read(lanConnectionProvider).serverName ?? '';
    final url = ref.read(lanConnectionProvider).baseUrl ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppStrings.t('lan_confirm_store', loc),
          key: const Key('confirm-title'),
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(url, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(AppStrings.t('lan_confirm_store_body', loc)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('confirm-connect'),
          onPressed: () => setState(() {
            _step = WizardStep.code;
            _errorKey = null;
          }),
          child: Text(AppStrings.t('lan_yes_connect', loc)),
        ),
        TextButton(
          onPressed: _retrySearch,
          child: Text(AppStrings.t('lan_retry', loc)),
        ),
      ],
    );
  }

  Widget _buildCode(String loc, String? serverError) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppStrings.t('lan_pairing_code', loc),
          key: const Key('code-title'),
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('pairing-code-field'),
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
          decoration: InputDecoration(
            counterText: '',
            labelText: AppStrings.t('lan_enter_pairing_code', loc),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submitCode(),
        ),
        if (_errorKey != null) ...[
          const SizedBox(height: 8),
          Text(
            AppStrings.t(_errorKey!, loc),
            key: const Key('code-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ] else if (serverError != null && serverError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            serverError == 'unreachable'
                ? AppStrings.t('lan_server_unreachable', loc)
                : AppStrings.t('lan_pairing_code_invalid', loc),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('code-submit'),
          onPressed: _submitCode,
          child: Text(AppStrings.t('lan_connect', loc)),
        ),
        TextButton(
          onPressed: _retrySearch,
          child: Text(AppStrings.t('lan_retry', loc)),
        ),
      ],
    );
  }

  Widget _buildWaiting(String loc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(key: Key('wizard-waiting')),
          ),
        ),
        Text(
          AppStrings.t('lan_waiting_approval', loc),
          key: const Key('waiting-title'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t('lan_waiting_seconds', loc)
              .replaceAll('{s}', '$_remaining'),
          key: const Key('waiting-countdown'),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildFailed(String loc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.error_outline,
          size: 56,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(
          AppStrings.t('lan_pairing_rejected', loc),
          key: const Key('failed-title'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t(_errorKey ?? 'lan_pairing_rejected_body', loc),
          key: const Key('failed-body'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.t('lan_repair_required', loc),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('failed-retry'),
          onPressed: _retrySearch,
          child: Text(AppStrings.t('lan_retry', loc)),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  const _RoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 40),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(body, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
