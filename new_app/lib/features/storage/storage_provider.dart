// Storage & Data Usage — Riverpod state for the storage page.
//
// One refresh measures BOTH scopes in parallel and never throws:
// * local  — a background-isolate filesystem probe of this computer
//   (injectable via `localStorageProbeProvider` so tests never touch a
//   real disk);
// * server — `GET /api/v1/storage`, authenticated and admin-gated on the
//   backend, with a bounded receive timeout.
//
// A failed scope keeps the previous successful section (its timestamp is
// the *last successful measurement*) and surfaces a localized error key;
// if nothing has ever been measured the state becomes `error` and the
// screen offers a retry.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../devices/device_identity.dart';
import 'local_storage_measure.dart';
import 'storage_models.dart';

/// Backend route (registered with prefix `/storage` in the API router).
const String storageUsagePath = '/api/v1/storage';

/// Bounded waits: the backend walks share a 5 s budget, so 15 s is a
/// generous network ceiling before the UI reports an error.
const Duration kStorageServerTimeout = Duration(seconds: 15);
const Duration kStorageLocalTimeout = Duration(seconds: 12);

typedef LocalStorageProbe = Future<StorageSection> Function();

/// Seam so widget tests can inject sections without a real filesystem
/// scan (the real app uses `measureLocalStorageInBackground`).
final localStorageProbeProvider = Provider<LocalStorageProbe>((ref) {
  return measureLocalStorageInBackground;
});

/// The setup-wizard role of this install (`server` / `client` / null) —
/// used only to explain where the server section is being measured.
final storageRunModeProvider = FutureProvider<String?>((ref) {
  return readAppRunMode();
});

enum StorageStatus { idle, loading, loaded, error }

@immutable
class StorageState {
  const StorageState({
    this.status = StorageStatus.idle,
    this.local,
    this.server,
    this.localErrorKey,
    this.serverErrorKey,
  });

  final StorageStatus status;
  final StorageSection? local;
  final StorageSection? server;
  final String? localErrorKey;
  final String? serverErrorKey;

  bool get isBusy => status == StorageStatus.loading;
  bool get hasData => local != null || server != null;
  bool get hasError => status == StorageStatus.error && !hasData;
  bool get hasInlineError => localErrorKey != null || serverErrorKey != null;

  /// True only when BOTH scopes were measured and every measurable
  /// category in them is available — otherwise the shown total is
  /// explicitly partial.
  bool get overallComplete =>
      local != null &&
      server != null &&
      local!.complete &&
      server!.complete;

  int get totalBytes =>
      (local?.totalBytes ?? 0) + (server?.totalBytes ?? 0);

  StorageState copyWith({
    StorageStatus? status,
    StorageSection? local,
    StorageSection? server,
    String? localErrorKey,
    String? serverErrorKey,
    bool clearErrors = false,
  }) {
    return StorageState(
      status: status ?? this.status,
      local: local ?? this.local,
      server: server ?? this.server,
      localErrorKey: clearErrors ? null : localErrorKey ?? this.localErrorKey,
      serverErrorKey: clearErrors ? null : serverErrorKey ?? this.serverErrorKey,
    );
  }
}

class StorageNotifier extends StateNotifier<StorageState> {
  StorageNotifier(this._dio, this._probe) : super(const StorageState());

  final Dio _dio;
  final LocalStorageProbe _probe;

  /// Guarded refresh: re-entry while a measurement is running is ignored.
  Future<void> refresh() async {
    if (state.isBusy) return;
    state = state.copyWith(status: StorageStatus.loading, clearErrors: true);

    final results = await Future.wait<(StorageSection?, String?)>([
      _loadLocal(),
      _loadServer(),
    ]);
    final (local, localErrorKey) = results[0];
    final (server, serverErrorKey) = results[1];

    // Keep the previous section on failure: its timestamp then *is* the
    // last successful measurement for that scope.
    final nextLocal = local ?? state.local;
    final nextServer = server ?? state.server;
    final status = nextLocal == null && nextServer == null
        ? StorageStatus.error
        : StorageStatus.loaded;
    state = StorageState(
      status: status,
      local: nextLocal,
      server: nextServer,
      localErrorKey: localErrorKey,
      serverErrorKey: serverErrorKey,
    );
  }

  Future<(StorageSection?, String?)> _loadLocal() async {
    try {
      final section = await _probe().timeout(kStorageLocalTimeout);
      return (section, null);
    } on Object {
      return (null, 'storage_load_failed');
    }
  }

  Future<(StorageSection?, String?)> _loadServer() async {
    try {
      final response = await _dio.get<dynamic>(
        storageUsagePath,
        options: Options(receiveTimeout: kStorageServerTimeout),
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return (null, 'storage_load_failed');
      }
      return (StorageSection.fromJson(storageScopeServer, data), null);
    } on DioException catch (error) {
      return (null, _serverErrorKey(error));
    } on Object {
      return (null, 'storage_load_failed');
    }
  }

  /// Localized message key for a server failure — connection problems,
  /// authorization and generic backend errors each read differently.
  static const Set<DioExceptionType> _networkFailures = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
  };

  static String _serverErrorKey(DioException error) {
    if (_networkFailures.contains(error.type)) return 'network_error_retry';
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) return 'storage_no_permission';
    return 'api_error_retry';
  }
}

final storageProvider = StateNotifierProvider<StorageNotifier, StorageState>((
  ref,
) {
  final dio = ref.watch(apiClientProvider).dio;
  return StorageNotifier(dio, ref.watch(localStorageProbeProvider));
});
