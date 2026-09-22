import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import 'auth_models.dart';
import 'credential_storage.dart';

enum AuthStatus {
  checking,
  setupRequired,
  unauthenticated,
  authenticating,
  authenticated,
  sessionExpired,
  error,
}

class AuthState {
  final AuthStatus status;
  final AuthUser? user;
  final String? errorMessage;
  final bool setupInProgress;
  final bool loginInProgress;

  const AuthState({
    this.status = AuthStatus.checking,
    this.user,
    this.errorMessage,
    this.setupInProgress = false,
    this.loginInProgress = false,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    String? errorMessage,
    bool? setupInProgress,
    bool? loginInProgress,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      errorMessage: errorMessage,
      setupInProgress: setupInProgress ?? this.setupInProgress,
      loginInProgress: loginInProgress ?? this.loginInProgress,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final ApiClient _apiClient;
  final SecureCredentialStorage _credentials;
  final String Function() _localeCode;

  AuthNotifier(
    this._apiClient,
    this._credentials, {
    String Function()? localeCode,
  })  : _localeCode = localeCode ?? (() => 'en'),
        super(const AuthState()) {
    _apiClient.setOnUnauthorized(_onUnauthorized);
    _initialize();
  }

  void _onUnauthorized() {
    if (mounted) {
      state = state.copyWith(
        status: AuthStatus.sessionExpired,
        user: null,
      );
    }
  }

  Future<void> _initialize() async {
    try {
      final hasToken = await _credentials.hasToken();
      if (!hasToken) {
        // Check if setup is needed
        final needsSetup = await _checkSetupNeeded();
        state = AuthState(
          status: needsSetup ? AuthStatus.setupRequired : AuthStatus.unauthenticated,
        );
        return;
      }

      // Try to restore session
      final token = await _credentials.readToken();

      if (token == null) {
        final needsSetup = await _checkSetupNeeded();
        state = AuthState(
          status: needsSetup ? AuthStatus.setupRequired : AuthStatus.unauthenticated,
        );
        return;
      }

      _apiClient.setToken(token);

      // Verify token with backend
      final user = await _verifyToken(token);
      if (user != null) {
        final enriched = await _applyMePermissions(user);
        state = AuthState(
          status: AuthStatus.authenticated,
          user: enriched,
        );
      } else {
        await _credentials.clearAll();
        _apiClient.clearToken();
        final needsSetup = await _checkSetupNeeded();
        state = AuthState(
          status: needsSetup ? AuthStatus.setupRequired : AuthStatus.unauthenticated,
        );
      }
    } catch (e) {
      // Network error or other issue — go to unauthenticated
      final needsSetup = await _checkSetupNeeded().catchError((_) => false);
      state = AuthState(
        status: needsSetup ? AuthStatus.setupRequired : AuthStatus.unauthenticated,
      );
    }
  }

  Future<bool> _checkSetupNeeded() async {
    try {
      final response = await _apiClient.dio.get('/api/v1/auth/setup/check');
      return response.data['setup_needed'] as bool? ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<AuthUser?> _verifyToken(String token) async {
    try {
      final response = await _apiClient.dio.post(
        '/api/v1/auth/verify-token',
        data: {'token': token},
      );
      final valid = response.data['valid'] as bool? ?? false;
      if (valid && response.data['user'] != null) {
        return AuthUser.fromJson(response.data['user'] as Map<String, dynamic>);
      }
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return null;
      rethrow;
    }
  }

  // ── Setup ─────────────────────────────────────────────

  Future<void> setupFirstAdmin({
    required String name,
    required String pin,
    required String pinConfirm,
  }) async {
    state = state.copyWith(setupInProgress: true, errorMessage: null);
    try {
      await _apiClient.dio.post(
        '/api/v1/auth/setup',
        data: {
          'name': name,
          'pin': pin,
          'pin_confirm': pinConfirm,
        },
      );
      state = AuthState(
        status: AuthStatus.unauthenticated,
      );
    } on DioException catch (e) {
      final message = _extractError(e);
      state = state.copyWith(setupInProgress: false, errorMessage: message);
    }
  }

  // ── Login ─────────────────────────────────────────────

  Future<void> login({
    required String userId,
    required String pin,
  }) async {
    state = state.copyWith(
      status: AuthStatus.authenticating,
      loginInProgress: true,
      errorMessage: null,
    );
    try {
      final response = await _apiClient.dio.post(
        '/api/v1/auth/login',
        data: {
          'user_id': userId,
          'pin': pin,
          'device_name': 'Desktop POS',
        },
      );
      final result = LoginResult.fromJson(response.data as Map<String, dynamic>);

      _apiClient.setToken(result.accessToken);

      // Authoritative flat scopes from GET /api/v1/auth/me (CurrentUserResponse).
      // Login's UserResponse has no top-level permissions; nested role scopes
      // are parsed by AuthUser.fromJson, /me is the belt-and-suspenders source
      // the shell's user_manage gate relies on. Failure keeps parsed scopes.
      final user = await _applyMePermissions(result.user);

      // Store credentials
      await _credentials.saveToken(result.accessToken);
      await _credentials.saveUserId(user.id);
      await _credentials.saveUserName(user.fullName);
      await _credentials.saveUserRoles(user.roles);
      await _credentials.saveUserPermissions(user.permissions);

      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
      );
    } on DioException catch (e) {
      final message = _extractError(e);
      state = state.copyWith(
        status: AuthStatus.error,
        loginInProgress: false,
        errorMessage: message,
      );
    }
  }

  // ── Logout ────────────────────────────────────────────

  Future<void> logout() async {
    try {
      final token = await _credentials.readToken();
      if (token != null) {
        await _apiClient.dio.post(
          '/api/v1/auth/logout-token',
          data: {'token': token},
        );
      }
    } catch (e) {
      // Logout should proceed even if API call fails
    }

    await _credentials.clearAll();
    _apiClient.clearToken();

    final needsSetup = await _checkSetupNeeded().catchError((_) => false);
    state = AuthState(
      status: needsSetup ? AuthStatus.setupRequired : AuthStatus.unauthenticated,
    );
  }

  // ── Reauth ────────────────────────────────────────────

  Future<bool> reauth(String pin) async {
    try {
      await _apiClient.dio.post(
        '/api/v1/auth/reauth',
        data: {'pin': pin},
      );
      return true;
    } on DioException catch (e) {
      final message = _extractError(e);
      state = state.copyWith(errorMessage: message);
      return false;
    }
  }

  // ── Helpers ───────────────────────────────────────────

  /// Merge flat `permissions` from `GET /api/v1/auth/me` into [user].
  /// Never fails login/restore: on any error, returns [user] unchanged.
  Future<AuthUser> _applyMePermissions(AuthUser user) async {
    try {
      final response = await _apiClient.dio.get('/api/v1/auth/me');
      final data = response.data;
      if (data is! Map) return user;
      final flat = (data['permissions'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList();
      if (flat.isEmpty) return user;
      final merged = {...user.permissions, ...flat}.toList();
      await _credentials.saveUserPermissions(merged);
      return AuthUser(
        id: user.id,
        fullName: data['full_name'] as String? ?? user.fullName,
        isActive: data['is_active'] as bool? ?? user.isActive,
        roles: user.roles.isNotEmpty
            ? user.roles
            : (data['roles'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((r) => r['name'])
                .whereType<String>()
                .toList(),
        permissions: merged,
      );
    } catch (_) {
      return user;
    }
  }

  void clearError() {
    state = state.copyWith(errorMessage: null);
  }

  String _extractError(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backendMessage = backendErrorMessage(e);
    if (backendMessage != null) return backendMessage;
    final statusCode = e.response?.statusCode;
    if (statusCode == 401) return AppStrings.t('authentication_failed', loc);
    if (statusCode == 403) return AppStrings.t('permission_denied', loc);
    if (statusCode == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient();
});

final credentialStorageProvider = Provider<SecureCredentialStorage>((ref) {
  return SecureCredentialStorage();
});

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final credentials = ref.watch(credentialStorageProvider);
  return AuthNotifier(
    apiClient,
    credentials,
    localeCode: () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// Convenience providers
final currentUserProvider = Provider<AuthUser?>((ref) {
  final authState = ref.watch(authProvider);
  return authState.user;
});

final isAuthenticatedProvider = Provider<bool>((ref) {
  final authState = ref.watch(authProvider);
  return authState.status == AuthStatus.authenticated;
});

final isAdminProvider = Provider<bool>((ref) {
  final user = ref.watch(currentUserProvider);
  return user?.isAdmin ?? false;
});
