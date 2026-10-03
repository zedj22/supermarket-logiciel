// Phase 16 (§13 / §14) connection state machine — pure logic, fake clock.
//
// The backoff ladder, the jitter band and the failure→phase mapping are
// deterministic functions of (attempt, jitter roll), so the whole reconnect
// policy can be pinned without sleeping. The notifier itself only wires
// those functions to Dio and timers.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/constants.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';

void main() {
  group('backoffSecondsFor (§14 ladder)', () {
    test('first reconnect attempt is immediate (no initial delay)', () {
      expect(backoffSecondsFor(0), 0);
      expect(backoffSecondsFor(1), 0);
      expect(backoffDelay(1, jitterRoll: 0), Duration.zero);
      expect(backoffDelay(1, jitterRoll: 99), Duration.zero);
    });

    test('follows 1, 2, 4, 8, 16 then the 30 s cap', () {
      expect([
        for (var attempt = 2; attempt <= 7; attempt++)
          backoffSecondsFor(attempt),
      ], [1, 2, 4, 8, 16, 30]);
    });

    test('never exceeds the cap, however many failures pile up', () {
      for (var attempt = 7; attempt <= 50; attempt++) {
        expect(
          backoffSecondsFor(attempt),
          lessThanOrEqualTo(kBackoffCapSeconds),
          reason: 'attempt $attempt exceeded the cap',
        );
      }
    });

    test('the schedule matches the published constants', () {
      expect(kBackoffScheduleSeconds, [1, 2, 4, 8, 16, 30]);
      expect(kBackoffCapSeconds, 30);
      expect(kBackoffJitterRatio, 0.20);
    });
  });

  group('backoffDelay jitter (±20 %)', () {
    test('neutral roll (50) yields the base delay exactly', () {
      expect(backoffDelay(6, jitterRoll: 50), const Duration(seconds: 16));
      expect(backoffDelay(3, jitterRoll: 50), const Duration(seconds: 2));
    });

    test('roll 0 is the -20 % edge', () {
      expect(backoffDelay(6, jitterRoll: 0), const Duration(milliseconds: 12800));
    });

    test('every roll stays inside the ±20 % band', () {
      for (var attempt = 2; attempt <= 8; attempt++) {
        final base = backoffSecondsFor(attempt) * 1000;
        for (var roll = 0; roll < 100; roll++) {
          final ms = backoffDelay(attempt, jitterRoll: roll).inMilliseconds;
          expect(ms, greaterThanOrEqualTo((base * 0.8).round() - 1),
              reason: 'attempt=$attempt roll=$roll below band');
          expect(ms, lessThanOrEqualTo((base * 1.2).round() + 1),
              reason: 'attempt=$attempt roll=$roll above band');
        }
      }
    });

    test('a pathological roll is clamped before it is used', () {
      final clamped = backoffDelay(6, jitterRoll: 500);
      final atEdge = backoffDelay(6, jitterRoll: 99);
      expect(clamped, atEdge);
      expect(backoffDelay(6, jitterRoll: -5), backoffDelay(6, jitterRoll: 0));
    });
  });

  group('phaseAfterHeartbeatFailures (§13.1)', () {
    test('one failure keeps the connection up (no flapping)', () {
      expect(
        phaseAfterHeartbeatFailures(1),
        AppConstants.heartbeatFailureThreshold == 1
            ? LanPhase.reconnecting
            : LanPhase.connected,
      );
    });

    test('two consecutive failures enter reconnecting', () {
      expect(phaseAfterHeartbeatFailures(2), LanPhase.reconnecting);
      expect(phaseAfterHeartbeatFailures(3), LanPhase.reconnecting);
      expect(phaseAfterHeartbeatFailures(5), LanPhase.reconnecting);
    });

    test('prolonged failure drops to disconnected', () {
      expect(phaseAfterHeartbeatFailures(6), LanPhase.disconnected);
      expect(phaseAfterHeartbeatFailures(100), LanPhase.disconnected);
    });
  });

  group('heartbeat eligibility', () {
    test('only the live states tick', () {
      expect(isHeartbeatActive(LanPhase.connected), isTrue);
      expect(isHeartbeatActive(LanPhase.reconnecting), isTrue);
      expect(isHeartbeatActive(LanPhase.connecting), isTrue);

      expect(isHeartbeatActive(LanPhase.unconfigured), isFalse);
      expect(isHeartbeatActive(LanPhase.discovering), isFalse);
      expect(isHeartbeatActive(LanPhase.serverFound), isFalse);
      expect(isHeartbeatActive(LanPhase.pairingRequested), isFalse);
      expect(isHeartbeatActive(LanPhase.awaitingApproval), isFalse);
      expect(isHeartbeatActive(LanPhase.disconnected), isFalse);
      expect(isHeartbeatActive(LanPhase.rejected), isFalse);
    });

    test('the threshold is 2 (§14)', () {
      expect(AppConstants.heartbeatFailureThreshold, 2);
      expect(AppConstants.heartbeatInterval, const Duration(seconds: 10));
    });
  });

  group('LanConnectionState', () {
    test('defaults to unconfigured with no link', () {
      const state = LanConnectionState();
      expect(state.phase, LanPhase.unconfigured);
      expect(state.baseUrl, isNull);
      expect(state.serverId, isNull);
      expect(state.offers, isEmpty);
      expect(state.mutationsAllowed, isFalse);
      expect(state.isPaired, isFalse);
    });

    test('mutations are only allowed while connected (§15)', () {
      const connected = LanConnectionState(phase: LanPhase.connected);
      expect(connected.mutationsAllowed, isTrue);
      expect(connected.isPaired, isTrue);

      const degraded =
          LanConnectionState(phase: LanPhase.connected, degraded: true);
      expect(degraded.mutationsAllowed, isTrue,
          reason: 'degraded DB is still connected (§13.1)');

      const reconnecting = LanConnectionState(phase: LanPhase.reconnecting);
      expect(reconnecting.mutationsAllowed, isFalse);
    });

    test('pairing/progress states are not yet "paired"', () {
      for (final phase in [
        LanPhase.discovering,
        LanPhase.serverFound,
        LanPhase.pairingRequested,
        LanPhase.awaitingApproval,
      ]) {
        expect(LanConnectionState(phase: phase).isPaired, isFalse,
            reason: '$phase should not count as paired');
      }
      for (final phase in [LanPhase.connecting, LanPhase.connected]) {
        expect(LanConnectionState(phase: phase).isPaired, isTrue,
            reason: '$phase should count as paired');
      }
    });

    test('copyWith keeps an existing link and clearError wipes the detail',
        () {
      final state = LanConnectionState(
        phase: LanPhase.connected,
        baseUrl: 'http://192.168.1.10:8000',
        serverId: 'server-1',
        serverName: 'Store',
        errorMessage: 'something',
        deviceErrorCode: 'device_revoked',
        consecutiveFailures: 2,
        attempt: 3,
      );

      final cleared = state.copyWith(clearError: true);
      expect(cleared.errorMessage, isNull);
      expect(cleared.deviceErrorCode, isNull);
      expect(cleared.baseUrl, state.baseUrl,
          reason: 'clearing an error must never drop the link');
      expect(cleared.serverId, 'server-1');

      final failed = state.copyWith(consecutiveFailures: 3, attempt: 4);
      expect(failed.consecutiveFailures, 3);
      expect(failed.attempt, 4);
      expect(failed.errorMessage, 'something',
          reason: 'a plain copyWith must not clear the message');
    });

    test('clearPairing drops only the pairing handle', () {
      final state = LanConnectionState(
        phase: LanPhase.awaitingApproval,
        pairingId: 'abc',
        baseUrl: 'http://x',
      );
      final cleared = state.copyWith(clearPairing: true);
      expect(cleared.pairingId, isNull);
      expect(cleared.baseUrl, 'http://x');
    });
  });

  group('LanPhase', () {
    test('exposes the nine §13.1 states plus unconfigured', () {
      expect(LanPhase.values.length, 10);
      expect(
        LanPhase.values.map((p) => p.name).toList(),
        [
          'unconfigured',
          'discovering',
          'serverFound',
          'pairingRequested',
          'awaitingApproval',
          'connecting',
          'connected',
          'reconnecting',
          'disconnected',
          'rejected',
        ],
      );
    });
  });

  group('FakeDiscoveryService', () {
    test('emits each configured offer exactly once', () async {
      final offer = ServerOffer(
        address: '192.168.1.10',
        serverId: 'server-1',
        name: 'Store',
        httpPort: 8000,
        tls: false,
        nonce: 'a1b2c3d4e5f60718',
      );
      final fake = FakeDiscoveryService(offers: [offer, offer]);
      expect(await fake.discover(budget: const Duration(seconds: 1)).toList(),
          [offer, offer]);
      await fake.dispose();
      expect(fake.disposed, isTrue);
    });

    test('an empty result completes without emitting', () async {
      final fake = FakeDiscoveryService(offers: const []);
      expect(await fake.discover().toList(), isEmpty);
    });
  });
}
