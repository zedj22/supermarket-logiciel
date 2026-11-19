import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'settings_models.dart';

/// Scope guarding `PUT /api/v1/settings` (backend
/// `PermissionScope.SETTINGS_MANAGE`).  Reading is open to every
/// authenticated user, so this is only ever used to gate *editing*.
const String settingsManageScope = 'settings_manage';

enum SettingsStatus {
  /// Nothing requested yet (or the caller is not allowed to manage).
  idle,

  /// `GET` in flight.
  loading,

  /// Settings are in memory and current.
  loaded,

  /// `PUT` in flight.
  saving,

  /// The last request failed; [SettingsState.errorMessage] says why.
  error,
}

@immutable
class SettingsState {
  const SettingsState({
    this.status = SettingsStatus.idle,
    this.settings,
    this.errorMessage,
    this.failedDuringSave = false,
  });

  final SettingsStatus status;

  /// Last known server state.  `null` until the first successful `GET`.
  final StoreSettings? settings;

  /// Human-readable detail for the last failure.
  final String? errorMessage;

  /// True when [errorMessage] came from a `PUT`.  A failed save must never
  /// be presented as success, and the stale-but-valid [settings] are kept so
  /// the form does not silently discard the operator's typing.
  final bool failedDuringSave;

  bool get isLoading => status == SettingsStatus.loading;
  bool get isSaving => status == SettingsStatus.saving;
  bool get hasError => status == SettingsStatus.error;

  SettingsState copyWith({
    SettingsStatus? status,
    StoreSettings? settings,
    String? errorMessage,
    bool? failedDuringSave,
    bool clearSettings = false,
    bool clearError = false,
  }) {
    return SettingsState(
      status: status ?? this.status,
      settings: clearSettings ? null : (settings ?? this.settings),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      failedDuringSave:
          failedDuringSave ?? (clearError ? false : this.failedDuringSave),
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier(this._dio, this._localeCode)
      : super(const SettingsState());

  final Dio _dio;
  final String Function() _localeCode;

  /// `GET /api/v1/settings`.  Safe to call repeatedly; a failed load keeps
  /// whatever was previously loaded so a transient blip does not blank the
  /// form.
  Future<void> load() async {
    if (state.status == SettingsStatus.loading ||
        state.status == SettingsStatus.saving) {
      return;
    }
    state = state.copyWith(
      status: SettingsStatus.loading,
      clearError: true,
    );
    try {
      final response = await _dio.get(StoreSettings.settingsPath);
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = state.copyWith(
        status: SettingsStatus.loaded,
        settings: StoreSettings.fromJson(data),
        clearError: true,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        status: SettingsStatus.error,
        errorMessage: _extractError(e),
        failedDuringSave: false,
      );
    }
  }

  /// `PUT /api/v1/settings` with the whole form.
  ///
  /// Returns `true` **only** when the server answered 2xx — the caller must
  /// use that (not its own optimism) to decide whether to show "saved".
  Future<bool> save(StoreSettings next) async {
    state = state.copyWith(
      status: SettingsStatus.saving,
      clearError: true,
    );
    try {
      final response = await _dio.put(
        StoreSettings.settingsPath,
        data: next.toJson(),
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = state.copyWith(
        status: SettingsStatus.loaded,
        settings: StoreSettings.fromJson(data),
        clearError: true,
      );
      return true;
    } on DioException catch (e) {
      state = state.copyWith(
        status: SettingsStatus.error,
        errorMessage: _extractError(e),
        failedDuringSave: true,
      );
      return false;
    }
  }

  /// Clears the last error banner.
  ///
  /// Only meaningful once there is a snapshot to show: without one the
  /// screen is in its "cannot load" branch, where the retry action (not
  /// this) is the correct response, so the call is a no-op there.
  void clearError() {
    if (!state.hasError || state.settings == null) return;
    state = state.copyWith(status: SettingsStatus.loaded, clearError: true);
  }

  String _extractError(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final licenseKey = licenseErrorKeyFrom(e);
    if (licenseKey != null) return AppStrings.t(licenseKey, loc);
    final backendMessage = backendErrorMessage(e);
    if (backendMessage != null) return backendMessage;
    final statusCode = e.response?.statusCode;
    if (statusCode == 401) return AppStrings.t('authentication_failed', loc);
    if (statusCode == 403) return AppStrings.t('permission_denied', loc);
    if (statusCode == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SettingsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

/// Server-owned settings, fetched at most once per session (§17.6).
///
/// Returns `null` when they cannot be read — offline, a test client with no
/// settings endpoint, or a load already in flight — so callers fall back to
/// the documented fresh-install defaults (80 mm, no auto print) instead of
/// failing the action they were about to perform.
Future<StoreSettings?> loadStoreSettingsOnce(WidgetRef ref) async {
  final current = ref.read(settingsProvider);
  if (current.settings != null) return current.settings;
  if (current.status != SettingsStatus.idle) return null;
  try {
    await ref.read(settingsProvider.notifier).load();
  } catch (_) {
    return null;
  }
  return ref.read(settingsProvider).settings;
}
