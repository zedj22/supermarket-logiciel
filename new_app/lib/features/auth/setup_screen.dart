// First-run administrator setup — ONE page, no steps, no dialogs.
//
// Shown only while the backend answers `setup_needed = true` (i.e. no
// admin-role account exists yet); the router refuses every other route in
// that state.  Fields: the administrator account name (the existing user
// model has no separate `username` column — this is the name the login
// screen lists), PIN and PIN confirmation.
//
// Submitting calls `POST /auth/setup`, which creates the admin and mints
// its session in one transaction.  The provider adopts that token, so the
// app navigates straight to the dashboard already signed in; the router's
// redirect does the navigation (`authenticated` + `/setup` → `/`).
//
// Existing installations never see this screen: it is driven by the
// database (an admin exists → `setup_needed` false), never by a local flag.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'auth_provider.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _username = TextEditingController();
  final _pin = TextEditingController();
  final _confirmPin = TextEditingController();
  final _usernameFocus = FocusNode();
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();

  bool _obscurePin = true;
  bool _submitting = false;
  String? _usernameError;
  String? _pinError;
  String? _confirmError;
  String? _formError;

  /// Existing PIN policy: 4–6 digits, digits only (backend `PIN_MIN_LENGTH`
  /// / `PIN_MAX_LENGTH`). Kept identical so the client never accepts what
  /// the server would reject.
  static final RegExp _pinPattern = RegExp(r'^\d{4,6}$');

  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    _confirmPin.dispose();
    _usernameFocus.dispose();
    _pinFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  String get _loc => ref.read(localeProvider).flutterLocale.languageCode;

  void _validateAndSubmit() {
    final loc = _loc;
    final username = _username.text.trim();
    final pin = _pin.text.trim();
    final confirm = _confirmPin.text.trim();

    final usernameError =
        username.isEmpty ? AppStrings.t('setup_username_required', loc) : null;
    final pinError = _pinPattern.hasMatch(pin)
        ? null
        : AppStrings.t('pin_required', loc);
    final confirmError = confirm.isEmpty
        ? AppStrings.t('pin_required', loc)
        : (confirm != pin ? AppStrings.t('pin_mismatch', loc) : null);

    setState(() {
      _usernameError = usernameError;
      _pinError = pinError;
      _confirmError = confirmError;
      _formError = null;
    });
    if (usernameError != null || pinError != null || confirmError != null) {
      return;
    }
    _submit(username: username, pin: pin, confirm: confirm);
  }

  Future<void> _submit({
    required String username,
    required String pin,
    required String confirm,
  }) async {
    setState(() {
      _submitting = true;
      _formError = null;
    });
    final notifier = ref.read(authProvider.notifier);
    await notifier.setupFirstAdmin(
      name: username,
      pin: pin,
      pinConfirm: confirm,
    );
    if (!mounted) return;
    final state = ref.read(authProvider);
    if (state.status == AuthStatus.authenticated) {
      // The router redirect owns the navigation: authenticated + /setup → /.
      // Clear the in-flight state so the button never keeps a spinner alive
      // while the redirect swaps the screen.
      setState(() => _submitting = false);
      return;
    }
    setState(() {
      _submitting = false;
      _formError = state.errorMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.storefront,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppStrings.t('setup_title', loc),
                        key: const Key('setup-title'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppStrings.t('setup_subtitle', loc),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        key: const Key('setup-username-field'),
                        controller: _username,
                        focusNode: _usernameFocus,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        enabled: !_submitting,
                        decoration: InputDecoration(
                          labelText: AppStrings.t('setup_username', loc),
                          helperText:
                              AppStrings.t('setup_username_hint', loc),
                          prefixIcon: const Icon(Icons.person_outline),
                          border: const OutlineInputBorder(),
                          errorText: _usernameError,
                        ),
                        onChanged: (_) {
                          if (_usernameError != null) {
                            setState(() => _usernameError = null);
                          }
                        },
                        onSubmitted: (_) => _pinFocus.requestFocus(),
                      ),
                      const SizedBox(height: 16),
                      _pinField(
                        key: const Key('setup-pin-field'),
                        visibilityKey: const Key('setup-pin-visibility'),
                        controller: _pin,
                        focusNode: _pinFocus,
                        label: AppStrings.t('create_pin', loc),
                        errorText: _pinError,
                        onChanged: (_) {
                          if (_pinError != null) setState(() => _pinError = null);
                        },
                        onSubmitted: (_) => _confirmFocus.requestFocus(),
                      ),
                      const SizedBox(height: 16),
                      _pinField(
                        key: const Key('setup-confirm-pin-field'),
                        visibilityKey: const Key('setup-confirm-pin-visibility'),
                        controller: _confirmPin,
                        focusNode: _confirmFocus,
                        label: AppStrings.t('confirm_pin', loc),
                        errorText: _confirmError,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) {
                          if (_confirmError != null) {
                            setState(() => _confirmError = null);
                          }
                        },
                        onSubmitted: (_) => _validateAndSubmit(),
                      ),
                      if (_formError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _formError!,
                          key: const Key('setup-form-error'),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        key: const Key('setup-submit-button'),
                        onPressed: _submitting ? null : _validateAndSubmit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.admin_panel_settings),
                        label: Text(
                          AppStrings.t(
                            _submitting ? 'setup_creating' : 'create_admin',
                            loc,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pinField({
    required Key key,
    required Key visibilityKey,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required ValueChanged<String> onChanged,
    required ValueChanged<String> onSubmitted,
    String? errorText,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    final loc = _loc;
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      enabled: !_submitting,
      obscureText: _obscurePin,
      keyboardType: TextInputType.number,
      textInputAction: textInputAction,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline),
        border: const OutlineInputBorder(),
        errorText: errorText,
        counterText: '',
        suffixIcon: IconButton(
          key: visibilityKey,
          tooltip: AppStrings.t(_obscurePin ? 'show_pin' : 'hide_pin', loc),
          onPressed: () => setState(() => _obscurePin = !_obscurePin),
          icon: Icon(
            _obscurePin
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}
