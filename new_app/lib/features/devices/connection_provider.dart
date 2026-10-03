// Phase 16 — client connection state machine (§13, §14).
//
// The enum and the `backoff*` helpers are pure so `connection_state_test`
// can drive them with a fake clock / injected jitter roll; this notifier is
// the thin IO shell around them.
//
// Design rules baked in here:
//   * heartbeat = GET /api/v1/health every 10 s, 2 consecutive failures to
//     leave `connected` (§14);
//   * backoff 1,2,4,8,16 then a 30 s cap, ±20 % jitter, first attempt
//     immediate (§14);
//   * `server_id` is identity, the IP is not — a changed `server_id` stops
//     the loop and asks for a re-pair (§14 / §9.3);
//   * reconnect = cached address first, then UDP rediscovery (§23.3): when
//     `paired_server_url` stops answering, the paired server is searched
//     again on the LAN and `paired_server_url` is rewritten — a DHCP/IP
//     change must never force a re-pair;
//   * NO offline writes: when not `connected`, mutations are disabled by
//     the UI (§15). This layer never queues anything.
import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'device_identity.dart';
import 'discovery_service.dart';

// ---------------------------------------------------------------------------
// Pure model (unit-tested without IO)
// ---------------------------------------------------------------------------

enum LanPhase {
  /// No role chosen yet (first run).
  unconfigured,

  /// UDP probes in flight.
  discovering,

  /// A candidate passed the TCP probe.
  serverFound,

  /// POST /devices/pair is out.
  pairingRequested,

  /// Polling GET /devices/pairings/{id}.
  awaitingApproval,

  /// Token stored; first guarded call in flight.
  connecting,

  /// Heartbeat succeeding.
  connected,

  /// Backoff loop after a failure.
  reconnecting,

  /// Prolonged failure; retrying at a slower cadence.
  disconnected,

  /// Denied, revoked, or a different server behind the same address.
  rejected,
}

/// Backoff ladder in seconds (§14). Index = attempt - 1.
const List<int> kBackoffScheduleSeconds = <int>[1, 2, 4, 8, 16, 30];

const int kBackoffCapSeconds = 30;

/// ±20 % jitter (§14).
const double kBackoffJitterRatio = 0.20;

/// Base delay for [attempt] (1-based). Attempt 0/1 is immediate so the
/// first reconnect attempt has no initial delay (§14).
int backoffSecondsFor(int attempt) {
  if (attempt <= 1) return 0;
  final index = attempt - 2;
  final base = index < kBackoffScheduleSeconds.length
      ? kBackoffScheduleSeconds[index]
      : kBackoffCapSeconds;
  return base > kBackoffCapSeconds ? kBackoffCapSeconds : base;
}

/// Backoff delay with jitter.
///
/// [jitterRoll] is an injected 0..99 value so tests get an exact result:
/// 50 is the neutral roll (no offset), 0/99 are the extremes.
Duration backoffDelay(int attempt, {required int jitterRoll}) {
  final base = backoffSecondsFor(attempt);
  if (base == 0) return Duration.zero;
  final roll = jitterRoll.clamp(0, 99);
  final offset = (roll - 50) / 50.0; // -1.0 .. +0.98
  final seconds = base + (base * kBackoffJitterRatio * offset);
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Phase after a heartbeat failure, given how many failed in a row.
LanPhase phaseAfterHeartbeatFailures(int consecutiveFailures) {
  if (consecutiveFailures < AppConstants.heartbeatFailureThreshold) {
    return LanPhase.connected;
  }
  if (consecutiveFailures >= AppConstants.heartbeatFailureThreshold + 4) {
    return LanPhase.disconnected;
  }
  return LanPhase.reconnecting;
}

/// States in which the heartbeat timer may run.
const Set<LanPhase> kHeartbeatPhases = <LanPhase>{
  LanPhase.connected,
  LanPhase.reconnecting,
  LanPhase.connecting,
};

bool isHeartbeatActive(LanPhase phase) => kHeartbeatPhases.contains(phase);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class LanConnectionState {
  final LanPhase phase;

  /// Base URL of the candidate/paired server.
  final String? baseUrl;

  /// `server_id` of the paired server (identity, §9.3).
  final String? serverId;

  /// Store name shown in the confirm step (legacy UX A4).
  final String? serverName;

  final String? pairingId;

  final List<ServerOffer> offers;

  /// Machine error code from the guard (`device_revoked`, …).
  final String? deviceErrorCode;

  /// Human-facing failure detail (backend message or probe reason).
  final String? errorMessage;

  /// Health said the server's database is down while HTTP still answers
  /// (§13.1 "connected-but-degraded" — NOT a disconnected state).
  final bool degraded;

  final int consecutiveFailures;
  final int attempt;
  final int nextRetryInSeconds;

  final DateTime? lastHeartbeatAt;

  /// Seconds spent in `awaiting_approval` (5 min cap, §13.1).
  final int pairingWaitSeconds;

  const LanConnectionState({
    this.phase = LanPhase.unconfigured,
    this.baseUrl,
    this.serverId,
    this.serverName,
    this.pairingId,
    this.offers = const <ServerOffer>[],
    this.deviceErrorCode,
    this.errorMessage,
    this.degraded = false,
    this.consecutiveFailures = 0,
    this.attempt = 0,
    this.nextRetryInSeconds = 0,
    this.lastHeartbeatAt,
    this.pairingWaitSeconds = 0,
  });

  bool get isPaired =>
      phase != LanPhase.unconfigured &&
      phase != LanPhase.discovering &&
      phase != LanPhase.serverFound &&
      phase != LanPhase.pairingRequested &&
      phase != LanPhase.awaitingApproval;

  bool get mutationsAllowed => phase == LanPhase.connected;

  LanConnectionState copyWith({
    LanPhase? phase,
    String? baseUrl,
    String? serverId,
    String? serverName,
    String? pairingId,
    List<ServerOffer>? offers,
    String? deviceErrorCode,
    String? errorMessage,
    bool? degraded,
    int? consecutiveFailures,
    int? attempt,
    int? nextRetryInSeconds,
    DateTime? lastHeartbeatAt,
    int? pairingWaitSeconds,
    bool clearError = false,
    bool clearPairing = false,
  }) {
    return LanConnectionState(
      phase: phase ?? this.phase,
      baseUrl: baseUrl ?? this.baseUrl,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      pairingId: clearPairing ? null : (pairingId ?? this.pairingId),
      offers: offers ?? this.offers,
      deviceErrorCode: clearError ? null : (deviceErrorCode ?? this.deviceErrorCode),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      degraded: degraded ?? this.degraded,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      attempt: attempt ?? this.attempt,
      nextRetryInSeconds: nextRetryInSeconds ?? this.nextRetryInSeconds,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      pairingWaitSeconds: pairingWaitSeconds ?? this.pairingWaitSeconds,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier (IO shell)
// ---------------------------------------------------------------------------

/// One pairing poll carries the whole server answer.
class PairingPollResult {
  final String status;
  final String? deviceToken;
  final String? serverId;
  final String? serverName;
  final String? errorCode;

  const PairingPollResult({
    required this.status,
    this.deviceToken,
    this.serverId,
    this.serverName,
    this.errorCode,
  });

  bool get approved => status == 'approved';
  bool get rejected => status == 'rejected';
}

/// One-shot guard for the boot-time reconnect modal.
///
/// §14 keeps the legacy policy: a modal may only appear during boot/wizard.
/// Once the shell is up, the status chip alone reports health so a flapping
/// network never interrupts a cashier mid-sale.
final reconnectPromptShownProvider = StateProvider<bool>((ref) => false);

class LanConnectionNotifier extends StateNotifier<LanConnectionState> {
  final ApiClient _api;
  final DiscoveryService Function(int port) _discoveryFactory;

  /// `/health` + `/system/info` validation (§11.2). Injectable so the
  /// address-recovery path can be driven without sockets in tests; the
  /// production default is the real [probeServer].
  final Future<ServerProbe> Function(String url) _probe;

  Timer? _heartbeat;
  Timer? _retry;
  Timer? _pairingTicker;
  StreamSubscription<ServerOffer>? _discoverySub;
  DiscoveryService? _discovery;
  final Random _random;
  final Duration heartbeatInterval;
  final Duration pairingPollInterval;
  final Duration pairingTimeout;

  LanConnectionNotifier(
    this._api, {
    DiscoveryService Function(int port)? discoveryFactory,
    Future<ServerProbe> Function(String url)? probe,
    Random? random,
    this.heartbeatInterval = AppConstants.heartbeatInterval,
    this.pairingPollInterval = const Duration(seconds: 2),
    this.pairingTimeout = const Duration(minutes: 5),
  })  : _discoveryFactory = discoveryFactory ?? ((port) => UdpDiscoveryService(port: port)),
        _probe = probe ?? probeServer,
        _random = random ?? Random(),
        super(const LanConnectionState());

  // -- lifecycle -----------------------------------------------------------

  /// Re-attaches the persisted device link and resumes the heartbeat.
  ///
  /// Called once at boot. Never throws: an unpaired install simply stays
  /// `unconfigured` and the wizard takes over (§23.1).
  Future<LanPhase> bootstrap() async {
    final link = await readServerLink();
    if (!link.isPaired) {
      final mode = await readAppRunMode();
      state = LanConnectionState(
        phase: mode == null
            ? LanPhase.unconfigured
            : (mode == appRunModeClient
                ? LanPhase.disconnected
                : LanPhase.connected),
      );
      return state.phase;
    }

    await _applyLink(link.url!, link.deviceToken!);
    state = LanConnectionState(
      phase: LanPhase.connecting,
      baseUrl: link.url,
      serverId: link.serverId,
      serverName: state.serverName,
    );
    _startHeartbeat();

    // §23.3 — "cached-address-first, then UDP rediscovery". The remembered
    // address is validated with the same /health + /system/info probe the
    // wizard uses (2 s budget), so a DHCP/IP change costs seconds instead
    // of the 30 s API timeout, and the heartbeat below then starts against
    // an address that actually answers.
    await _recoverAddress(link);

    await _heartbeatTick(verifyIdentity: true);
    return state.phase;
  }

  // -- address recovery (§23.3: IP change without a re-pair) ---------------

  /// True when [url] answers `/health` + `/system/info` as THIS paired
  /// server. A dead host, an unrelated service or another store sitting
  /// behind the old address all mean "the cached address is unusable".
  Future<bool> _answersAsPairedServer(String url, String? pairedServerId) async {
    try {
      final probe = await _probe(url);
      if (pairedServerId == null || pairedServerId.isEmpty) return true;
      return probe.serverId == pairedServerId;
    } catch (_) {
      return false;
    }
  }

  bool _isOtherServer(String candidate, String? pairedServerId) =>
      pairedServerId != null &&
      pairedServerId.isNotEmpty &&
      candidate != pairedServerId;

  /// One UDP sweep of the discovery port, collecting every validated offer
  /// until the budget elapses (§11.1). The socket is always disposed.
  Future<List<ServerOffer>> _sweepOffers({
    Duration budget = const Duration(seconds: 3),
  }) async {
    final service = _discoveryFactory(8000);
    try {
      return await service.discover(budget: budget).toList();
    } finally {
      await service.dispose();
    }
  }

  /// Cached address first, then UDP rediscovery (§23.3 / §14).
  ///
  /// Returns true once a candidate for the SAME `server_id` has answered
  /// `/health` + `/system/info`. The shared [ApiClient] is then pointed at
  /// it and `paired_server_url` is rewritten so the next boot skips the
  /// sweep — but the device token is deliberately NOT rewritten: a moved
  /// server keeps its pairing, because identity is `server_id`, never the
  /// address (§9.3). Offers belonging to any other server are ignored.
  Future<bool> _recoverAddress(ServerLink link) async {
    final url = link.url;
    final token = link.deviceToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return false;
    }
    if (await _answersAsPairedServer(url, link.serverId)) return true;

    debugPrint('[LAN] cached address $url is unusable → UDP rediscovery');

    List<ServerOffer> offers;
    try {
      offers = await _sweepOffers();
    } catch (_) {
      return false;
    }

    for (final offer in offers) {
      if (_isOtherServer(offer.serverId, link.serverId)) continue;
      try {
        final probe = await _probe(offer.baseUrl);
        if (probe.serverId != offer.serverId ||
            _isOtherServer(probe.serverId, link.serverId)) {
          continue;
        }
      } catch (_) {
        continue;
      }
      await writeServerLink(ServerLink(
        url: offer.baseUrl,
        serverId: offer.serverId,
      ));
      await _applyLink(offer.baseUrl, token);
      state = state.copyWith(
        baseUrl: offer.baseUrl,
        serverId: offer.serverId,
        serverName: offer.name,
        clearError: true,
      );
      debugPrint('[LAN] rediscovered the paired server at ${offer.baseUrl}');
      return true;
    }
    debugPrint(
        '[LAN] rediscovery found no offer for server_id ${link.serverId}');
    return false;
  }

  /// Re-runs the cached-address-first / UDP-rediscovery acquisition for the
  /// persisted link. This is the entry point the login screen's Retry uses:
  /// a client that cannot authenticate yet has no shell, so the login screen
  /// is the only reconnect affordance it can reach.
  Future<bool> reacquireServer() async {
    try {
      final link = await readServerLink();
      if (!link.isPaired) return false;
      return await _recoverAddress(link);
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _retry?.cancel();
    _pairingTicker?.cancel();
    _discoverySub?.cancel();
    _discovery?.dispose();
    super.dispose();
  }

  // -- discovery (wizard) --------------------------------------------------

  /// Starts the UDP sweep. Offers accumulate in [LanConnectionState.offers].
  void startDiscovery({Duration budget = const Duration(seconds: 3)}) {
    _discoverySub?.cancel();
    _discovery?.dispose();
    final service = _discoveryFactory(8000);
    _discovery = service;
    state = state.copyWith(
      phase: LanPhase.discovering,
      offers: const <ServerOffer>[],
      clearError: true,
    );
    _discoverySub = service.discover(budget: budget).listen(
      (offer) {
        final current = state.offers;
        if (current.contains(offer)) return;
        state = state.copyWith(offers: [...current, offer]);
      },
      onError: (_) {
        if (state.phase == LanPhase.discovering) {
          state = state.copyWith(phase: LanPhase.unconfigured);
        }
      },
      onDone: () {
        if (state.phase == LanPhase.discovering && state.offers.isEmpty) {
          state = state.copyWith(phase: LanPhase.unconfigured);
        }
      },
    );
  }

  Future<void> stopDiscovery() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    await _discovery?.dispose();
    _discovery = null;
  }

  /// Probes a candidate (UDP offer or manually typed host) over HTTP.
  Future<bool> probe(String baseUrl) async {
    try {
      final probe = await _probe(baseUrl.trim());
      state = state.copyWith(
        phase: LanPhase.serverFound,
        baseUrl: probe.baseUrl,
        serverId: probe.serverId,
        serverName: probe.storeName,
        clearError: true,
      );
      return true;
    } on NotASupermarketServerException catch (e) {
      state = state.copyWith(
        errorMessage: e.reason,
        clearPairing: true,
      );
      return false;
    } on DioException catch (e) {
      state = state.copyWith(
        errorMessage: isConnectionError(e) ? 'unreachable' : 'probe_failed',
      );
      return false;
    } catch (_) {
      state = state.copyWith(errorMessage: 'unreachable');
      return false;
    }
  }

  // -- pairing -------------------------------------------------------------

  /// POST /devices/pair. Transitions to `awaiting_approval`.
  ///
  /// The ApiClient's base URL is pointed at the candidate for the duration
  /// of the call and restored on any failure — a rejected pairing must
  /// never leave the rest of the app talking to a server we are not paired
  /// with.
  Future<bool> requestPairing({
    required String code,
    required String displayName,
  }) async {
    final baseUrl = state.baseUrl;
    if (baseUrl == null) return false;
    final previousBaseUrl = _api.baseUrl;
    state = state.copyWith(phase: LanPhase.pairingRequested, clearError: true);
    try {
      final deviceId = await ensurePosDeviceId();
      _api.setBaseUrl(baseUrl);
      final response = await _api.dio.post(
        '/api/v1/devices/pair',
        data: {
          'device_id': deviceId,
          'display_name': displayName,
          'client_version': AppConstants.appVersion,
          'pairing_code': code.trim(),
        },
      );
      final data = response.data is Map
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
      final pairingId = data['pairing_id'];
      if (pairingId is! String || pairingId.isEmpty) {
        _api.setBaseUrl(previousBaseUrl);
        state = state.copyWith(phase: LanPhase.serverFound);
        return false;
      }
      state = state.copyWith(
        phase: LanPhase.awaitingApproval,
        pairingId: pairingId,
        pairingWaitSeconds: 0,
      );
      _startPairingPoll();
      return true;
    } on DioException catch (e) {
      _api.setBaseUrl(previousBaseUrl);
      state = state.copyWith(
        phase: LanPhase.serverFound,
        errorMessage: backendErrorCode(e) ??
            backendErrorMessage(e) ??
            (isConnectionError(e) ? 'unreachable' : 'pairing_failed'),
      );
      return false;
    } catch (_) {
      _api.setBaseUrl(previousBaseUrl);
      state = state.copyWith(
        phase: LanPhase.serverFound,
        errorMessage: 'pairing_failed',
      );
      return false;
    }
  }

  void _startPairingPoll() {
    _pairingTicker?.cancel();
    _pairingTicker = Timer.periodic(pairingPollInterval, (_) => pollPairing());
  }

  /// One poll of GET /devices/pairings/{pairing_id}.
  Future<void> pollPairing() async {
    final pairingId = state.pairingId;
    if (pairingId == null) return;
    if (state.phase != LanPhase.awaitingApproval) return;

    final waited = state.pairingWaitSeconds + pairingPollInterval.inSeconds;
    if (waited >= pairingTimeout.inSeconds) {
      _stopPairingPoll();
      state = state.copyWith(
        phase: LanPhase.rejected,
        errorMessage: 'pairing_timeout',
        pairingWaitSeconds: waited,
      );
      return;
    }

    try {
      final response =
          await _api.dio.get('/api/v1/devices/pairings/$pairingId');
      final data = response.data is Map
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
      final result = PairingPollResult(
        status: (data['status'] as String?) ?? 'pending',
        deviceToken: data['device_token'] as String?,
        serverId: data['server_id'] as String?,
        serverName: data['server_name'] as String?,
      );

      if (result.status == 'pending') {
        state = state.copyWith(pairingWaitSeconds: waited);
        return;
      }

      _stopPairingPoll();
      if (result.approved && result.deviceToken != null) {
        final url = state.baseUrl!;
        final serverId = result.serverId ?? state.serverId;
        await writeServerLink(ServerLink(
          url: url,
          serverId: serverId,
          deviceToken: result.deviceToken,
        ));
        await _applyLink(url, result.deviceToken!);
        state = state.copyWith(
          phase: LanPhase.connecting,
          serverId: serverId,
          serverName: result.serverName ?? state.serverName,
          clearPairing: true,
          clearError: true,
        );
        _startHeartbeat();
        await _heartbeatTick(verifyIdentity: true);
      } else {
        state = state.copyWith(
          phase: LanPhase.rejected,
          errorMessage: 'pairing_rejected',
          clearPairing: true,
        );
      }
    } catch (_) {
      // A transient poll failure must not end the wait; only the 5 min
      // budget does (§13.1).
      state = state.copyWith(pairingWaitSeconds: waited);
    }
  }

  void _stopPairingPoll() {
    _pairingTicker?.cancel();
    _pairingTicker = null;
  }

  /// User pressed "pair again" from `rejected`.
  void requestRepair() {
    _stopPairingPoll();
    state = state.copyWith(
      phase: state.baseUrl == null ? LanPhase.unconfigured : LanPhase.serverFound,
      clearPairing: true,
      clearError: true,
    );
  }

  // -- heartbeat / reconnect ----------------------------------------------

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => _heartbeatTick());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _retry?.cancel();
    _retry = null;
  }

  Future<void> _heartbeatTick({bool verifyIdentity = false}) async {
    if (!isHeartbeatActive(state.phase)) return;
    try {
      final response = await _api.dio.get(
        '/api/v1/health',
        options: Options(receiveTimeout: const Duration(seconds: 4)),
      );
      final data = response.data is Map
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
      final database = data['database'];

      if (verifyIdentity && state.serverId != null) {
        final info = await _api.dio.get(
          '/api/v1/system/info',
          options: Options(receiveTimeout: const Duration(seconds: 4)),
        );
        final infoData = info.data is Map
            ? info.data as Map<String, dynamic>
            : <String, dynamic>{};
        final remoteId = infoData['server_id'];
        if (remoteId is String &&
            remoteId.isNotEmpty &&
            remoteId != state.serverId) {
          // Same address, different machine (§14 identity check).
          await forgetServer(reason: 'server_changed');
          return;
        }
      }

      state = state.copyWith(
        phase: LanPhase.connected,
        degraded: database != 'connected',
        consecutiveFailures: 0,
        attempt: 0,
        nextRetryInSeconds: 0,
        lastHeartbeatAt: DateTime.now(),
        clearError: true,
      );
    } on DioException catch (e) {
      if (isConnectionError(e)) {
        // No response at all: the ADDRESS did not answer (§23.3). Surfaced
        // so the reconnect dialog can say "the server did not answer" and
        // so tests can tell a dead address from a failing server.
        state = state.copyWith(errorMessage: 'unreachable');
      }
      _onHeartbeatFailure();
    } catch (_) {
      _onHeartbeatFailure();
    }
  }

  void _onHeartbeatFailure() {
    if (!isHeartbeatActive(state.phase)) return;
    final failures = state.consecutiveFailures + 1;
    final phase = phaseAfterHeartbeatFailures(failures);
    final attempt = state.attempt + 1;
    final delay = backoffDelay(attempt, jitterRoll: _random.nextInt(100));

    state = state.copyWith(
      phase: phase,
      consecutiveFailures: failures,
      attempt: attempt,
      nextRetryInSeconds: delay.inSeconds,
    );

    _retry?.cancel();
    _retry = Timer(delay, () {
      if (!isHeartbeatActive(state.phase)) return;
      state = state.copyWith(nextRetryInSeconds: 0);
      _heartbeatTick(verifyIdentity: state.consecutiveFailures >
          AppConstants.heartbeatFailureThreshold);
    });
  }

  /// User pressed "retry now" in the reconnect dialog.
  ///
  /// §23.3: a retry re-runs the cached-address-first / UDP-rediscovery
  /// acquisition first — re-issuing the very same request against an
  /// address that has gone stale is not a retry.
  Future<void> retryNow() async {
    if (state.phase != LanPhase.reconnecting &&
        state.phase != LanPhase.disconnected &&
        state.phase != LanPhase.rejected) {
      return;
    }
    _retry?.cancel();
    state = state.copyWith(
      phase: LanPhase.connecting,
      nextRetryInSeconds: 0,
      clearError: true,
    );
    _startHeartbeat();
    try {
      final link = await readServerLink();
      if (link.isPaired) await _recoverAddress(link);
    } catch (_) {
      // Keep the remembered address; the heartbeat below still reports it.
    }
    await _heartbeatTick(verifyIdentity: true);
  }

  // -- device guard reactions ---------------------------------------------

  /// A 401 carrying `device_required` / `device_not_paired` /
  /// `device_revoked` (§23.2). The user session is left alone.
  Future<void> handleDeviceError(String code) async {
    if (state.phase == LanPhase.rejected && state.deviceErrorCode == code) {
      return;
    }
    _stopHeartbeat();
    if (code == 'device_revoked') {
      await clearServerLink();
      _api.setDeviceIdentity(deviceId: null, deviceToken: null);
    }
    state = state.copyWith(
      phase: LanPhase.rejected,
      deviceErrorCode: code,
      errorMessage: code,
    );
  }

  /// Full reset of the device link (mode change, re-pair, server change).
  Future<void> forgetServer({String? reason}) async {
    _stopHeartbeat();
    _stopPairingPoll();
    await clearServerLink();
    _api.setDeviceIdentity(deviceId: null, deviceToken: null);
    state = LanConnectionState(
      phase: LanPhase.unconfigured,
      errorMessage: reason,
    );
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// Test seam: move the machine to [next] with no IO at all, so widget
  /// tests can render every state without sockets, timers or a server.
  @visibleForTesting
  void debugSetState(LanConnectionState next) => state = next;

  // -- helpers -------------------------------------------------------------

  /// Points the shared ApiClient at [url] with this machine's identity
  /// headers. The machine id is read (and generated once) here rather than
  /// kept in state so a restart can re-attach exactly the same identity.
  Future<void> _applyLink(String url, String token) async {
    final deviceId = await ensurePosDeviceId();
    _api.setBaseUrl(url);
    _api.setDeviceIdentity(deviceId: deviceId, deviceToken: token);
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Discovery port is the same number as HTTP (§11.1 / Q13).
final lanDiscoveryPortProvider = Provider<int>((ref) => 8000);

final lanConnectionProvider =
    StateNotifierProvider<LanConnectionNotifier, LanConnectionState>((ref) {
  final api = ref.watch(apiClientProvider);
  final notifier = LanConnectionNotifier(
    api,
    discoveryFactory: (port) => UdpDiscoveryService(port: port),
  );

  // The guard's `device_*` 401s reach the connection layer, never the
  // session-expiry handler (§23.2).
  api.setOnDeviceError(notifier.handleDeviceError);
  ref.onDispose(() => api.setOnDeviceError((_) {}));

  // Re-attach the persisted link and resume the heartbeat on first use.
  Future.microtask(() async {
    try {
      await notifier.bootstrap();
    } catch (_) {
      // An unpaired or offline install must still render; the wizard owns
      // whatever comes next (§23.1).
    }
  });

  return notifier;
});
