import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'auth_provider.dart';
import 'pin_pad.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _nameController = TextEditingController();
  final _nameFocusNode = FocusNode();
  String _pin = '';
  String _pinConfirm = '';
  int _step = 0; // 0: name, 1: pin, 2: confirm pin

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _onNameSubmitted() {
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _step = 1);
  }

  void _onPinEntered(String pin) {
    setState(() {
      _pin = pin;
      _step = 2;
    });
  }

  void _onPinConfirmEntered(String pinConfirm) {
    setState(() => _pinConfirm = pinConfirm);
    if (_pin != pinConfirm) {
      return;
    }
    _submitSetup();
  }

  Future<void> _submitSetup() async {
    await ref.read(authProvider.notifier).setupFirstAdmin(
          name: _nameController.text.trim(),
          pin: _pin,
          pinConfirm: _pinConfirm,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = ref.watch(localeProvider);
    final loc = locale.flutterLocale.languageCode;

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: theme.colorScheme.error,
          ),
        );
        ref.read(authProvider.notifier).clearError();
        setState(() {
          _step = 1;
          _pin = '';
          _pinConfirm = '';
        });
      }
    });

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
                  Icons.store,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.t('welcome', loc),
                  style: theme.textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.t('setup_title', loc),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 32),
                if (_step == 0) _buildNameStep(theme, loc),
                if (_step == 1) _buildPinStep(theme, loc),
                if (_step == 2) _buildPinConfirmStep(theme, loc),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNameStep(ThemeData theme, String loc) {
    return Column(
      children: [
        Text(
          AppStrings.t('admin_name', loc),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 300,
          child: TextField(
            controller: _nameController,
            focusNode: _nameFocusNode,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: AppStrings.t('enter_admin_name', loc),
              prefixIcon: const Icon(Icons.person),
            ),
            onSubmitted: (_) => _onNameSubmitted(),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _onNameSubmitted,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }

  Widget _buildPinStep(ThemeData theme, String loc) {
    return Column(
      children: [
        Text(
          AppStrings.t('create_pin', loc),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          AppStrings.t('pin', loc),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 16),
        PinPad(
          locale: loc,
          maxLength: 6,
          onSubmit: _onPinEntered,
        ),
      ],
    );
  }

  Widget _buildPinConfirmStep(ThemeData theme, String loc) {
    final pinMismatch = _pinConfirm.isNotEmpty && _pin != _pinConfirm;
    return Column(
      children: [
        Text(
          AppStrings.t('confirm_pin', loc),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        PinPad(
          locale: loc,
          maxLength: 6,
          onSubmit: _onPinConfirmEntered,
          errorText:
              pinMismatch ? AppStrings.t('invalid_pin', loc) : null,
        ),
      ],
    );
  }
}
