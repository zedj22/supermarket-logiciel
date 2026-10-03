import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../devices/connection_provider.dart';
import 'auth_provider.dart';
import 'auth_models.dart';
import 'pin_pad.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  List<UserListItem> _users = [];
  UserListItem? _selectedUser;
  bool _loadingUsers = true;
  String? _usersError;
  bool _showPinPad = false;
  String _pin = '';
  final FocusNode _loginFocusNode =
      FocusNode(debugLabel: 'login-key-handler');
  final GlobalKey<PinPadState> _pinPadKey = GlobalKey<PinPadState>();

  @override
  void dispose() {
    _loginFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loadingUsers = true;
      _usersError = null;
    });
    try {
      final apiClient = ref.read(apiClientProvider);
      final response = await apiClient.dio.get('/api/v1/auth/login-users');
      final items = (response.data['items'] as List<dynamic>)
          .map((u) => UserListItem.fromJson(u as Map<String, dynamic>))
          .where((u) => u.isActive)
          .toList();
      setState(() {
        _users = items;
        _loadingUsers = false;
      });
    } on DioException catch (e) {
      setState(() {
        _loadingUsers = false;
        _usersError = _loadUsersErrorMessage(e);
      });
    }
  }

  /// Retry must do more than re-issue the same request against an address
  /// that may be dead (§23.3): re-run the cached-address-first / UDP
  /// rediscovery acquisition first, then load the list from whatever
  /// address the connection layer is using now. A paired client that
  /// cannot authenticate yet has no shell, so this is the only reconnect
  /// affordance it can reach.
  Future<void> _loadUsersAfterRecovery() async {
    setState(() {
      _loadingUsers = true;
      _usersError = null;
    });
    await ref.read(lanConnectionProvider.notifier).reacquireServer();
    await _loadUsers();
  }

  String _loadUsersErrorMessage(DioException e) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    if (e.response?.statusCode == 401) {
      return backendErrorMessage(e) ??
          AppStrings.t('authentication_failed', loc);
    }
    if (e.response?.statusCode == 403) {
      return backendErrorMessage(e) ?? AppStrings.t('permission_denied', loc);
    }
    if (e.response?.statusCode == 422) {
      return backendErrorMessage(e) ?? AppStrings.t('validation_error', loc);
    }
    return backendErrorMessage(e) ?? AppStrings.t('api_error_retry', loc);
  }

  void _selectUser(UserListItem user) {
    setState(() {
      _selectedUser = user;
      _showPinPad = true;
      _pin = '';
    });
  }

  bool get _pinIsValid =>
      _pin.length >= AppConstants.minPinLength &&
      _pin.length <= AppConstants.maxPinLength &&
      RegExp(r'^\d+$').hasMatch(_pin);

  void _tryLogin() {
    final authState = ref.read(authProvider);
    if (authState.status == AuthStatus.authenticating ||
        authState.loginInProgress) {
      return;
    }
    if (_selectedUser == null || !_pinIsValid) return;
    ref.read(authProvider.notifier).login(userId: _selectedUser!.id, pin: _pin);
  }

  /// Map a physical keyboard key to its ASCII digit, or null.
  /// Covers main-row digit0-9 and numpad0-numpad9 (Windows desktop).
  static String? _digitFromLogicalKey(LogicalKeyboardKey key) {
    // Non-const maps: LogicalKeyboardKey does not have primitive equality.
    final main = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
    };
    final numpad = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
    };
    return main[key] ?? numpad[key];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = ref.watch(localeProvider);
    final authState = ref.watch(authProvider);
    final loc = locale.flutterLocale.languageCode;

    ref.listen<AuthState>(authProvider, (prev, next) {
      final loginFailed = prev?.status == AuthStatus.authenticating &&
          next.status == AuthStatus.error &&
          next.errorMessage != null;

      if (loginFailed) {
        // Failed PIN is NOT a logout/session-expiry event.
        // Stay on this LoginScreen instance (router no longer remounts it),
        // preserve selectedUser, clear only the PIN, show the error on the
        // PIN screen, and refocus for an immediate retry.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _pinPadKey.currentState?.clearPin();
          _pinPadKey.currentState?.requestPinFocus();
        });
        // Keep errorMessage in state so PinPad.errorText stays visible.
        // It is cleared on the next login() attempt or when the user
        // backs out to the user list.
        return;
      }

      if (next.errorMessage != null) {
        // Non-login-failure errors (e.g. transient API issues elsewhere):
        // same snackbar behavior as before.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: theme.colorScheme.error,
          ),
        );
        ref.read(authProvider.notifier).clearError();
      }
    });

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.store, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    AppStrings.t('app_name', loc),
                    style: theme.textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 32),
                  if (_loadingUsers) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      AppStrings.t('loading', loc),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ] else if (_usersError != null) ...[
                    Text(
                      _usersError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadUsersAfterRecovery,
                      child: Text(AppStrings.t('retry', loc)),
                    ),
                  ] else if (_users.isEmpty) ...[
                    Text(
                      AppStrings.t('no_users', loc),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ] else if (!_showPinPad) ...[
                    Text(
                      AppStrings.t('select_user', loc),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    ..._users.map((user) => _buildUserTile(user, theme, loc)),
                  ] else ...[
                    if (_selectedUser != null) ...[
                      Text(
                        _selectedUser!.fullName,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _selectedUser!.roleNames.join(', '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedUser = null;
                            _showPinPad = false;
                            _pin = '';
                          });
                          // Leaving the PIN screen also dismisses any
                          // leftover authentication error display.
                          ref.read(authProvider.notifier).clearError();
                        },
                        child: Text(AppStrings.t('select_user', loc)),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Focus(
                      key: const Key('login-key-handler'),
                      focusNode: _loginFocusNode,
                      // PIN TextField autofocuses; this node is a fallback
                      // handler when focus is on the wrapper (not the field).
                      autofocus: false,
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;

                        if (key == LogicalKeyboardKey.enter ||
                            key == LogicalKeyboardKey.numpadEnter) {
                          _tryLogin();
                          return KeyEventResult.handled;
                        }

                        // Digits / Backspace / Delete: this handler only
                        // receives keys the focused PIN TextField did NOT
                        // consume (Focus propagation stops at handled
                        // events), so route them into the same PinPad state
                        // — no second PIN state, no double-insert.
                        final pinState = _pinPadKey.currentState;
                        if (pinState != null) {
                          final digit = _digitFromLogicalKey(key);
                          if (digit != null) {
                            pinState.inputDigit(digit);
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.backspace) {
                            pinState.deleteLast();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.delete) {
                            pinState.clearPin();
                            return KeyEventResult.handled;
                          }
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PinPad(
                            key: _pinPadKey,
                            locale: loc,
                            maxLength: AppConstants.maxPinLength,
                            onChanged: (pin) => setState(() => _pin = pin),
                            onSubmit: (_) => _tryLogin(),
                            enabled:
                                authState.status != AuthStatus.authenticating,
                            errorText: authState.status == AuthStatus.error
                                ? authState.errorMessage
                                : null,
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: 280,
                            height: 48,
                            child: ElevatedButton(
                              key: const Key('login-submit-button'),
                              onPressed:
                                  _pinIsValid && _selectedUser != null &&
                                          authState.status !=
                                              AuthStatus.authenticating &&
                                          !authState.loginInProgress
                                      ? _tryLogin
                                      : null,
                              child:
                                  authState.loginInProgress ||
                                          authState.status ==
                                              AuthStatus.authenticating
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          AppStrings.t('login_submit', loc),
                                        ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserTile(UserListItem user, ThemeData theme, String loc) {
    final isSelected = _selectedUser?.id == user.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: 300,
        child: Card(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : null,
          child: InkWell(
            onTap: () => _selectUser(user),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primary,
                    child: Text(
                      user.fullName.isNotEmpty
                          ? user.fullName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.fullName, style: theme.textTheme.titleMedium),
                        Text(
                          user.roleNames.join(', '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
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
