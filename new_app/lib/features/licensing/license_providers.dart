import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'license_info.dart';
import 'license_snapshot.dart';

/// Latest license snapshot from any `GET /api/v1/system/info` response.
///
/// `null` means "no system-info response yet" (nothing is inferred);
/// a non-null value with [LicenseInfo.unknown] means "the server answered
/// but sent no usable license block".
///
/// Kept strictly separate from the LAN connection state: a connectivity
/// failure never writes here, and an unavailable license never changes
/// the connection phase.
final licenseStatusProvider = StateProvider<LicenseInfo?>((ref) => null);

/// Latest `GET /api/v1/license/status` (or activate) snapshot — Phase L2-C.
///
/// `null` means "no licensing-status response yet". A Lifetime value here
/// is what stops the client from presenting a licensed install as
/// trial-limited; a failure never overwrites a known snapshot (mirroring
/// the backend rule that a failed activation writes nothing).
final licenseSnapshotProvider = StateProvider<LicenseSnapshot?>((ref) => null);

/// Feeds [licenseStatusProvider] from every `/system/info` response that
/// flows through the shared [ApiClient] (bootstrap heartbeat identity
/// check, About page, reconnect verification). One interceptor hook, no
/// additional request and no polling.
final licenseIngestorProvider = Provider<void>((ref) {
  final api = ref.watch(apiClientProvider);
  api.setOnSystemInfo((data) {
    ref.read(licenseStatusProvider.notifier).state =
        LicenseInfo.fromSystemInfoPayload(data);
  });
  ref.onDispose(() => api.setOnSystemInfo(null));
  // Phase L2-C: one best-effort licensing-status fetch at startup so a
  // Lifetime install is recognized from the first screen (banner, router
  // gate) without waiting for the licensing screen to be opened. It is
  // strictly additive, may fail without any user-visible effect, and must
  // never break startup — every failure is swallowed here.
  Future<void>(() async {
    try {
      final response = await api.dio.get('/api/v1/license/status');
      final snapshot = LicenseSnapshot.tryParse(response.data);
      if (snapshot != null) {
        ref.read(licenseSnapshotProvider.notifier).state = snapshot;
      }
    } catch (_) {
      // Best-effort only: the backend `license_guard` remains the
      // authority regardless of what the client has managed to fetch.
    }
  });
});

/// What one activation attempt concluded (Phase L2-C).
enum ActivationPhase {
  /// Nothing has been requested yet.
  idle,

  /// `POST /license/activation-request` is in flight.
  requesting,

  /// `POST /license/activate` is in flight.
  submitting,

  /// The backend accepted the signed code (state refreshed from the
  /// response, then re-fetched from `GET /license/status`).
  success,

  /// The attempt failed; [ActivationState.errorMessageKey] carries the
  /// localization key of the actual backend error.
  failure,
}

/// Immutable state of the activation flow: the generated request code
/// (kept across attempts), the current phase and the failure message key
/// derived from the real backend error code.
@immutable
class ActivationState {
  const ActivationState({
    this.phase = ActivationPhase.idle,
    this.requestCode,
    this.fingerprintDisplayCode,
    this.errorMessageKey,
    this.errorCode,
  });

  final ActivationPhase phase;
  final String? requestCode;
  final String? fingerprintDisplayCode;

  /// Localization key for [phase] == [ActivationPhase.failure], else null.
  final String? errorMessageKey;

  /// Raw backend `error.code` of the failure (diagnostics + tests);
  /// never rendered raw to the operator.
  final String? errorCode;

  bool get hasRequest =>
      requestCode != null && requestCode!.trim().isNotEmpty;

  /// Same request fields (an existing code survives every transition),
  /// the new phase, and no error — a fresh phase always clears the last
  /// failure.
  ActivationState _withPhase(ActivationPhase phase) => ActivationState(
        phase: phase,
        requestCode: requestCode,
        fingerprintDisplayCode: fingerprintDisplayCode,
      );

  ActivationState _failure(String key, {String? code}) => ActivationState(
        phase: ActivationPhase.failure,
        requestCode: requestCode,
        fingerprintDisplayCode: fingerprintDisplayCode,
        errorMessageKey: key,
        errorCode: code,
      );
}

/// Maps one activation failure to its localization key using the actual
/// backend error code (Phase L2-C): the eight licensing codes keep their
/// dedicated sentences via [licenseErrorKey], the request-shape and
/// rate-limit codes get activation-specific ones, anything else with a
/// response is a server error, and no response at all is a network error.
String activationErrorKey(DioException e) {
  if (isConnectionError(e)) return 'license_activation_error_network';
  final code = backendErrorCode(e);
  final licensing = licenseErrorKey(code);
  if (licensing != null) return licensing;
  switch (code) {
    case 'VALIDATION_ERROR':
      return 'license_activation_error_validation';
    case 'RATE_LIMITED':
      return 'license_activation_error_rate_limited';
    default:
      // A response arrived (so not a network failure) but carried no
      // recognizable licensing identity: report it as a server error.
      return 'license_activation_error_server';
  }
}

/// Drives the Lifetime activation flow (Phase L2-C) through the three
/// existing L2-A endpoints — no contract of theirs is altered:
///
/// * `POST /api/v1/license/activation-request` → request code + display
///   fingerprint code for the owner's offline Generator;
/// * `POST /api/v1/license/activate` → `{"activation_code": …}` and the
///   refreshed status straight from the response;
/// * `GET  /api/v1/license/status` → the same snapshot re-fetched right
///   after a successful activation (and once at first use).
///
/// A failed attempt never touches [licenseSnapshotProvider] (the backend
/// writes nothing on failure — the client mirrors that), while a
/// successful one updates it immediately so the UI reflects the new
/// license without an application restart.
class ActivationController extends StateNotifier<ActivationState> {
  ActivationController({
    required this.api,
    required this.setSnapshot,
    required this.currentSnapshot,
  }) : super(const ActivationState());

  final ApiClient api;
  final void Function(LicenseSnapshot?) setSnapshot;
  final LicenseSnapshot? Function() currentSnapshot;

  /// Best-effort refresh of the licensing snapshot. Leaves any known
  /// snapshot untouched when the endpoint cannot be reached.
  Future<void> ensureStatus() async {
    try {
      final response = await api.dio.get('/api/v1/license/status');
      final snapshot = LicenseSnapshot.tryParse(response.data);
      if (snapshot != null && mounted) setSnapshot(snapshot);
    } catch (_) {
      // Best-effort: an unreachable status endpoint must never surface
      // as an error on a screen whose job is to fix the license.
    }
  }

  /// Generates (or regenerates) the unsigned request code. The code is
  /// kept in state across later failures so a failed activation never
  /// hides what the user must send to the owner.
  Future<void> requestCode() async {
    if (!mounted) return;
    state = state._withPhase(ActivationPhase.requesting);
    try {
      final response = await api.dio.post('/api/v1/license/activation-request');
      if (!mounted) return;
      final data = response.data;
      if (data is! Map) {
        state = state._failure('license_activation_error_server');
        return;
      }
      final code = data['request_code'];
      final fingerprint = data['fingerprint_display_code'];
      if (code is! String || code.isEmpty) {
        state = state._failure('license_activation_error_server');
        return;
      }
      state = ActivationState(
        requestCode: code,
        fingerprintDisplayCode: fingerprint is String ? fingerprint : null,
      );
    } on DioException catch (e) {
      if (mounted) {
        state = state._failure(activationErrorKey(e),
            code: backendErrorCode(e));
      }
    } catch (_) {
      if (mounted) state = state._failure('license_activation_error_server');
    }
  }

  /// Submits [rawCode] (trimmed); returns true only when the backend
  /// accepted it and the status was refreshed.
  Future<bool> activate(String rawCode) async {
    if (!mounted) return false;
    final code = rawCode.trim();
    if (code.isEmpty) {
      state = state._failure('license_activation_error_empty');
      return false;
    }
    state = state._withPhase(ActivationPhase.submitting);
    try {
      final response = await api.dio.post(
        '/api/v1/license/activate',
        data: {'activation_code': code},
      );
      if (!mounted) return false;
      // The activate response IS the refreshed status — apply it first
      // so the UI updates immediately, then re-fetch as the authoritative
      // refresh (its failure keeps the response snapshot).
      final immediate = LicenseSnapshot.tryParse(response.data);
      if (immediate != null) setSnapshot(immediate);
      await _refreshAfterActivation();
      // The request code stays in state (same invariant as every other
      // transition): a remount of the panel must see `hasRequest` and
      // never regenerate over a completed activation.
      if (mounted) state = state._withPhase(ActivationPhase.success);
      return true;
    } on DioException catch (e) {
      if (mounted) {
        state = state._failure(activationErrorKey(e),
            code: backendErrorCode(e));
      }
      return false;
    } catch (_) {
      if (mounted) state = state._failure('license_activation_error_server');
      return false;
    }
  }

  Future<void> _refreshAfterActivation() async {
    try {
      final response = await api.dio.get('/api/v1/license/status');
      final snapshot = LicenseSnapshot.tryParse(response.data);
      if (snapshot != null && mounted) setSnapshot(snapshot);
    } catch (_) {
      // Keep the snapshot already applied from the activate response.
    }
  }

  /// Current snapshot (for callers deciding whether a fetch is needed).
  LicenseSnapshot? get snapshot => currentSnapshot();
}

/// The activation flow controller. Non-autoDispose on purpose: the
/// generated request code and the last outcome survive navigation so
/// returning to the licensing screen shows the same state.
final activationControllerProvider =
    StateNotifierProvider<ActivationController, ActivationState>((ref) {
  final api = ref.watch(apiClientProvider);
  return ActivationController(
    api: api,
    setSnapshot: (snapshot) =>
        ref.read(licenseSnapshotProvider.notifier).state = snapshot,
    currentSnapshot: () => ref.read(licenseSnapshotProvider),
  );
});
