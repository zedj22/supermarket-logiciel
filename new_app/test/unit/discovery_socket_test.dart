// Phase 16 — real Windows 2-PC QA: the UDP sweep never left PC2 (§11.1).
//
// Observed on PC2 right after the IP-change fix:
//
//   [LAN] cached address http://192.168.1.7:8000 is unusable → UDP rediscovery
//   Unhandled Exception: SocketException: Send failed
//   (OS Error: An attempt was made to access a socket in a way forbidden by
//   its access permissions, errno = 10013)
//   address = 0.0.0.0, port = 0
//       at UdpDiscoveryService._start.sendOnce (discovery_service.dart:265)
//
// while a manual PowerShell broadcast from the SAME machine succeeded and
// PC2 → PC1 HTTP worked. Two statements from `dart:io` explain it:
//
//   * RawDatagramSocket.broadcastEnabled — "IPv4 broadcast needs to be
//     enabled by the sender for sending IPv4 broadcast packages. By default
//     IPv4 broadcast is disabled." → SO_BROADCAST must be set before the
//     first send, otherwise Windows refuses it with WSAEACCES / errno 10013.
//   * RawDatagramSocket.send — "If a local failure to send the datagram
//     occurs then an error event will be added to the Stream." → a local
//     send failure is a socket STREAM event, not an exception thrown out of
//     send(), which is why the `try/catch` around send never fired and the
//     error reached the zone unhandled.
//
// No OS socket is opened here: an injected bind seam hands the service a
// recording fake, so both statements are pinned without a network.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';

void main() {
  group('UdpDiscoveryService socket setup', () {
    test('enables IPv4 broadcast before the first datagram is sent', () async {
      final socket = _FakeDatagramSocket();
      final service = UdpDiscoveryService(
        port: 8000,
        bindSocket: () async => socket,
      );

      final sub = service.discover(budget: const Duration(milliseconds: 400))
          .listen((_) {}, onError: (_) {});
      // `_broadcastTargets` enumerates real network interfaces, so wait for
      // the first send instead of guessing at a pump count.
      await _waitFor(() => socket.sends.isNotEmpty);

      expect(socket.broadcastEnabled, isTrue,
          reason: 'SO_BROADCAST must be turned on before any send');
      expect(socket.sendsWithoutBroadcast, 0,
          reason: 'no datagram may leave the socket while broadcast is off');
      expect(socket.sends, contains('255.255.255.255:8000'));
      expect(socket.sends, contains('127.0.0.1:8000'));

      await sub.cancel();
      await service.dispose();
    });

    test('surfaces socket error events to the subscriber, never the zone',
        () async {
      final socket = _FakeDatagramSocket();
      final service = UdpDiscoveryService(
        port: 8000,
        bindSocket: () async => socket,
      );

      Object? uncaught;
      final delivered = <Object>[];

      await runZonedGuarded(() async {
        final sub =
            service.discover(budget: const Duration(seconds: 2)).listen(
                  (_) {},
                  onError: delivered.add,
                );
        await pumpEventQueue(times: 50);

        // What dart:io actually does when a local send fails (the VM catches
        // it inside send() and reports it through reportError()).
        socket.emitSocketError(
          const SocketException(
            'Send failed',
            osError: OSError(
              'An attempt was made to access a socket in a way forbidden '
              'by its access permissions',
              10013,
            ),
          ),
          StackTrace.current,
        );
        await pumpEventQueue(times: 50);

        await sub.cancel();
        await service.dispose();
      }, (Object error, StackTrace stackTrace) {
        uncaught = error;
      });

      expect(uncaught, isNull,
          reason: 'a discovery socket error must not reach the zone');
      expect(delivered, hasLength(1));
      expect(delivered.single, isA<SocketException>());
      expect(delivered.single.toString(), contains('10013'));
    });

    test('surfaces a socket bind failure on the stream instead of losing it',
        () async {
      Object? uncaught;
      final delivered = <Object>[];

      await runZonedGuarded(() async {
        final service = UdpDiscoveryService(
          port: 8000,
          bindSocket: () async => throw const SocketException(
                'bind denied',
                osError: OSError('Permission denied', 13),
              ),
        );
        final sub = service.discover(budget: const Duration(seconds: 1))
            .listen((_) {}, onError: delivered.add);
        await pumpEventQueue(times: 50);
        await sub.cancel();
      }, (Object error, StackTrace stackTrace) {
        uncaught = error;
      });

      expect(uncaught, isNull);
      expect(delivered, hasLength(1));
      expect(delivered.single, isA<SocketException>());
    });
  });
}

/// Polls [condition] with real (non-zero) delays until it holds or [timeout]
/// elapses — interface enumeration is an OS round trip, not a microtask.
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Records what the service does to the socket, and refuses to pretend a
/// send succeeded while IPv4 broadcast is still off — mirroring Windows,
/// which rejects that send with errno 10013.
class _FakeDatagramSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  final StreamController<RawSocketEvent> _events =
      StreamController<RawSocketEvent>();

  /// One entry per `send()` as `host:port`.
  final List<String> sends = [];

  /// Incremented for every send attempted with broadcast still disabled.
  int sendsWithoutBroadcast = 0;

  @override
  bool broadcastEnabled = false;

  @override
  bool readEventsEnabled = true;

  @override
  bool writeEventsEnabled = true;

  @override
  bool multicastLoopback = true;

  @override
  int multicastHops = 1;

  @override
  // ignore: deprecated_member_use
  NetworkInterface? multicastInterface;

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  @override
  int get port => 0;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (!broadcastEnabled) sendsWithoutBroadcast++;
    sends.add('${address.host}:$port');
    return buffer.length;
  }

  @override
  Datagram? receive() => null;

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {}

  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) {}

  @override
  Uint8List getRawOption(RawSocketOption option) => option.value;

  @override
  void setRawOption(RawSocketOption option) {}

  @override
  void close() {
    if (!_events.isClosed) _events.close();
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _events.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  /// How dart:io reports a local send failure: an event on the socket's own
  /// stream, not an exception thrown out of [send].
  void emitSocketError(Object error, StackTrace stackTrace) {
    _events.addError(error, stackTrace);
  }
}
