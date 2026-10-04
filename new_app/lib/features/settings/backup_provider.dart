import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'backup_models.dart';

/// Scope guarding `POST /api/v1/backups` and
/// `POST /api/v1/backups/{id}/restore` (backend
/// `PermissionScope.BACKUP_RESTORE` — admin only).
const String backupRestoreScope = 'backup_restore';

enum BackupStatus {
  /// Nothing requested yet.
  idle,

  /// `GET` in flight.
  loading,

  /// Catalogue is in memory and current.
  loaded,

  /// The last request failed; [BackupState.errorMessage] says why.
  error,
}

@immutable
class BackupState {
  const BackupState({
    this.status = BackupStatus.idle,
    this.items = const <BackupInfo>[],
    this.errorMessage,
    this.busy = false,
    this.pendingRestoreId,
    this.failedDuringAction = false,
  });

  final BackupStatus status;

  /// Newest first, exactly as the server returned it.
  final List<BackupInfo> items;

  /// Human-readable detail for the last failure (or `null` on success).
  final String? errorMessage;

  /// A create or a restore is in flight.
  final bool busy;

  /// Id of the backup being restored, so the right row can show a spinner
  /// while the others stay usable.
  final int? pendingRestoreId;

  /// True when [errorMessage] came from a create/restore rather than from
  /// the list request — the two need different headlines, and calling a
  /// failed *create* a "load" failure would send the operator looking in
  /// the wrong place.
  final bool failedDuringAction;

  bool get isLoading => status == BackupStatus.loading;
  bool get hasError => status == BackupStatus.error;

  BackupState copyWith({
    BackupStatus? status,
    List<BackupInfo>? items,
    String? errorMessage,
    bool? busy,
    int? pendingRestoreId,
    bool? failedDuringAction,
    bool clearError = false,
    bool clearPending = false,
  }) {
    return BackupState(
      status: status ?? this.status,
      items: items ?? this.items,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      busy: busy ?? this.busy,
      pendingRestoreId:
          clearPending ? null : (pendingRestoreId ?? this.pendingRestoreId),
      failedDuringAction:
          failedDuringAction ?? (clearError ? false : this.failedDuringAction),
    );
  }
}

class BackupNotifier extends StateNotifier<BackupState> {
  BackupNotifier(this._dio, this._localeCode)
      : super(const BackupState());

  final Dio _dio;
  final String Function() _localeCode;

  /// `GET /api/v1/backups`.  A failed refresh keeps the previous list so a
  /// transient blip does not empty the screen.
  Future<void> load() async {
    if (state.busy || state.status == BackupStatus.loading) return;
    state = state.copyWith(
      status: BackupStatus.loading,
      clearError: true,
    );
    try {
      final response = await _dio.get(BackupInfo.backupsPath);
      state = state.copyWith(
        status: BackupStatus.loaded,
        items: parseBackupList(response.data),
        clearError: true,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        status: BackupStatus.error,
        errorMessage: _extractError(e),
      );
    }
  }

  /// `POST /api/v1/backups`.  Returns `true` **only** on a 2xx answer —
  /// the caller must not announce a backup that was not taken.
  Future<bool> create() async {
    state = state.copyWith(busy: true, clearError: true, clearPending: true);
    try {
      await _dio.post(BackupInfo.backupsPath);
      await _refreshAfterMutation();
      state = state.copyWith(busy: false, clearError: true);
      return true;
    } on DioException catch (e) {
      state = state.copyWith(
        status: BackupStatus.error,
        errorMessage: _extractError(e),
        busy: false,
        failedDuringAction: true,
      );
      return false;
    }
  }

  /// `POST /api/v1/backups/{id}/restore`.
  ///
  /// Returns `true` only when the server confirms the restore.  Anything
  /// else — including a 422 from a tampered file — is surfaced as an error
  /// and never reported as success.
  Future<bool> restore(int backupId) async {
    state = state.copyWith(
      busy: true,
      pendingRestoreId: backupId,
      clearError: true,
    );
    try {
      await _dio.post('${BackupInfo.backupsPath}/$backupId/restore');
      // The database was replaced: re-read the catalogue rather than
      // trusting whatever we had before.
      await _refreshAfterMutation();
      state = state.copyWith(busy: false, clearPending: true, clearError: true);
      return true;
    } on DioException catch (e) {
      state = state.copyWith(
        status: BackupStatus.error,
        errorMessage: _extractError(e),
        busy: false,
        clearPending: true,
        failedDuringAction: true,
      );
      return false;
    }
  }

  void clearError() {
    if (!state.hasError) return;
    state = state.copyWith(
      status: state.items.isEmpty ? BackupStatus.idle : BackupStatus.loaded,
      clearError: true,
    );
  }

  Future<void> _refreshAfterMutation() async {
    try {
      final response = await _dio.get(BackupInfo.backupsPath);
      state = state.copyWith(
        status: BackupStatus.loaded,
        items: parseBackupList(response.data),
        clearError: true,
      );
    } on DioException {
      // A refresh failure must not turn a confirmed operation into an
      // error; the operator is told it worked and can hit refresh.
      state = state.copyWith(status: BackupStatus.loaded);
    }
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
    if (statusCode == 404) return AppStrings.t('not_found', loc);
    if (statusCode == 422) return AppStrings.t('validation_error', loc);
    if (statusCode == 503) return AppStrings.t('backup_tools_missing', loc);
    return AppStrings.t('api_error_retry', loc);
  }
}

final backupProvider =
    StateNotifierProvider<BackupNotifier, BackupState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return BackupNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
