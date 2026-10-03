// Phase 16 — device discovery, client side (§11).
//
// Two halves:
//
//   * UDP broadcast find  — `buildDiscoverPacket` / `parseOfferPacket` are
//     pure functions (unit-testable with no sockets at all), while
//     [UdpDiscoveryService] owns the real `RawDatagramSocket`.
//   * TCP probe/validate  — [probeServer] reuses the existing
//     `/api/v1/health` + `/api/v1/system/info` endpoints (no new endpoint)
//     and rejects anything that is not a Supermarket Pro server before a
//     pairing attempt is ever made (§11.2 step 4).
//
// Nothing in a packet is a secret: magic + version + nonce + store name +
// port. Never JWTs, never the pairing code, never the device token, never
// PostgreSQL anything (§11.1 "Never in packets").
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants.dart';

/// Cheap ASCII filter so unrelated UDP chatter is dropped before parsing
/// (legacy-style magic prefix, versioned).
const String discoveryMagic = 'SUPERMARKET_PRO_DISCOVER_V1';

const int discoveryProtocolVersion = 1;
const String discoveryAppId = 'supermarket_pro';

const int maxDiscoverRequestBytes = 256;
const int maxOfferResponseBytes = 512;

/// Framing is `MAGIC + 0x00 + utf8(json)` — one explicit separator byte so
/// the magic can be matched by prefix without scanning.
Uint8List _frame(Map<String, Object> payload) {
  final body = utf8.encode(jsonEncode(payload));
  final magic = utf8.encode(discoveryMagic);
  final out = BytesBuilder()
    ..add(magic)
    ..addByte(0)
    ..add(body);
  return out.toBytes();
}

/// Builds a `discover` request (≤ 256 B).
///
/// [nonce] is echoed back by the server so a delayed or forged offer from a
/// previous sweep can be discarded (8–64 chars, §12.4 style entropy).
Uint8List buildDiscoverPacket(String nonce) {
  return _frame({
    'v': discoveryProtocolVersion,
    'app': discoveryAppId,
    't': 'discover',
    'nonce': nonce,
  });
}

/// Builds an `offer` response (≤ 512 B) — the server half of the handshake.
Uint8List buildOfferPacket({
  required String nonce,
  required String serverId,
  required String name,
  required int httpPort,
  bool tls = false,
}) {
  return _frame({
    'v': discoveryProtocolVersion,
    'app': discoveryAppId,
    't': 'offer',
    'nonce': nonce,
    'server_id': serverId,
    'name': name,
    'http_port': httpPort,
    'tls': tls,
  });
}

/// A validated offer. [address] is the responder's IP — a *candidate*, never
/// an identity: identity is [serverId], verified again over HTTP (§11.2).
class ServerOffer {
  final String address;
  final String serverId;
  final String name;
  final int httpPort;
  final bool tls;
  final String nonce;

  const ServerOffer({
    required this.address,
    required this.serverId,
    required this.name,
    required this.httpPort,
    required this.tls,
    required this.nonce,
  });

  String get baseUrl => 'http://$address:$httpPort';

  @override
  bool operator ==(Object other) =>
      other is ServerOffer &&
      other.address == address &&
      other.serverId == serverId;

  @override
  int get hashCode => Object.hash(address, serverId);

  @override
  String toString() =>
      'ServerOffer($address:$httpPort id=$serverId name=$name)';
}

/// Parses a raw datagram into an offer.
///
/// Returns null (never throws) when the packet is oversized, not ours,
/// malformed JSON, or missing/mistyped fields — an unrelated program
/// answering the port must be a silent rejection, not a crash (§11.2 step 4).
ServerOffer? parseOfferPacket(List<int> bytes, {String? fromAddress}) {
  final payload = _decode(bytes, expectType: 'offer');
  if (payload == null) return null;
  final address = payload['sender'] as String? ?? fromAddress;
  final serverId = payload['server_id'];
  final name = payload['name'];
  final port = payload['http_port'];
  if (address == null || address.isEmpty) return null;
  if (serverId is! String || serverId.isEmpty) return null;
  if (name is! String) return null;
  if (port is! int || port <= 0 || port > 65535) return null;
  final nonce = payload['nonce'];
  return ServerOffer(
    address: address,
    serverId: serverId,
    name: name,
    httpPort: port,
    tls: payload['tls'] == true,
    nonce: nonce is String ? nonce : '',
  );
}

/// Parses a raw `discover` request. Returns the nonce on success, else null.
String? parseDiscoverPacket(List<int> bytes) {
  final payload = _decode(bytes, expectType: 'discover');
  if (payload == null) return null;
  final nonce = payload['nonce'];
  if (nonce is! String) return null;
  if (nonce.length < 8 || nonce.length > 64) return null;
  return nonce;
}

Map<String, Object?>? _decode(
  List<int> bytes, {
  required String expectType,
}) {
  if (bytes.isEmpty) return null;
  if (bytes.length > maxOfferResponseBytes) return null;
  final magic = utf8.encode(discoveryMagic);
  if (bytes.length < magic.length + 1) return null;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return null;
  }
  if (bytes[magic.length] != 0) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes.sublist(magic.length + 1)));
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  if (decoded['v'] != discoveryProtocolVersion) return null;
  if (decoded['app'] != discoveryAppId) return null;
  if (decoded['t'] != expectType) return null;
  return decoded;
}

// ---------------------------------------------------------------------------
// Seam
// ---------------------------------------------------------------------------

/// Discovery abstraction so the wizard can be driven by a fake in tests.
abstract class DiscoveryService {
  /// Broadcasts `discover` packets for [AppConstants.discoveryAttempts]
  /// rounds and emits every distinct validated offer until [budget] elapses.
  Stream<ServerOffer> discover({Duration budget});

  Future<void> dispose();
}

/// In-memory fake used by widget/unit tests — no sockets, deterministic.
class FakeDiscoveryService implements DiscoveryService {
  final List<ServerOffer> offers;
  final Duration tickInterval;
  bool disposed = false;

  FakeDiscoveryService({
    required this.offers,
    this.tickInterval = const Duration(milliseconds: 10),
  });

  @override
  Stream<ServerOffer> discover({Duration budget = const Duration(seconds: 2)}) {
    if (offers.isEmpty) return const Stream.empty();
    return Stream.periodic(tickInterval, (i) => offers[i % offers.length])
        .take(offers.length)
        .timeout(budget, onTimeout: (sink) => sink.close());
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Creates the datagram socket for a sweep. Injectable so a test can observe
/// socket setup (IPv4 broadcast, target selection) without an OS socket.
typedef DatagramBinder = Future<RawDatagramSocket> Function();

/// Real UDP implementation (§11.1).
class UdpDiscoveryService implements DiscoveryService {
  final int port;
  final DatagramBinder _bind;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _timer;

  UdpDiscoveryService({required this.port, DatagramBinder? bindSocket})
      : _bind = bindSocket ??
            (() => RawDatagramSocket.bind(
                  InternetAddress.anyIPv4,
                  0,
                  reuseAddress: true,
                ));

  @override
  Stream<ServerOffer> discover({Duration budget = const Duration(seconds: 3)}) {
    final controller = StreamController<ServerOffer>();
    final seen = <String>{};

    _start(budget, controller, seen).catchError((Object e) {
      if (!controller.isClosed) controller.addError(e);
      controller.close();
    });

    return controller.stream;
  }

  Future<void> _start(
    Duration budget,
    StreamController<ServerOffer> controller,
    Set<String> seen,
  ) async {
    final socket = await _bind();
    // `dart:io` DOES expose SO_BROADCAST: RawDatagramSocket.broadcastEnabled
    // — "IPv4 broadcast needs to be enabled by the sender for sending IPv4
    // broadcast packages. By default IPv4 broadcast is disabled." Without it
    // Windows refuses every send to 255.255.255.255 with WSAEACCES
    // (errno 10013), so the sweep never leaves this machine. Enable it
    // BEFORE the first send. A failure here must abort the sweep loudly —
    // `_start` is wrapped in `.catchError` by `discover`.
    socket.broadcastEnabled = true;
    _socket = socket;

    final nonce = _newNonce();
    final packet = buildDiscoverPacket(nonce);
    if (packet.length > maxDiscoverRequestBytes) {
      throw StateError('discover packet exceeds $maxDiscoverRequestBytes B');
    }

    final targets = await _broadcastTargets(port);
    var sent = 0;
    void sendOnce() {
      sent++;
      for (final target in targets) {
        try {
          socket.send(packet, target, port);
        } catch (e) {
          // A single refusing interface must not abort the sweep, but the
          // failure is reported — never suppressed silently.
          debugPrint(
              '[LAN] discovery send to ${target.host}:$port failed: $e');
        }
      }
    }

    sendOnce();
    _timer = Timer.periodic(AppConstants.discoveryAttemptTimeout, (t) {
      if (sent >= AppConstants.discoveryAttempts) {
        t.cancel();
        return;
      }
      sendOnce();
    });

    _sub = socket.listen(
      (event) {
        if (event != RawSocketEvent.read || controller.isClosed) return;
        final dg = socket.receive();
        if (dg == null) return;
        final offer = parseOfferPacket(dg.data, fromAddress: dg.address.host);
        if (offer == null) return;
        if (!seen.add('${offer.address}:${offer.serverId}')) return;
        controller.add(offer);
      },
      // A local send failure never reaches the `catch` above: `dart:io`
      // documents that it is reported as an event on this very stream ("If
      // a local failure to send the datagram occurs then an error event
      // will be added to the Stream"), and the VM schedules it through
      // reportError() → controller.addError. Without an onError handler it
      // lands in the zone as an unhandled SocketException.
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[LAN] discovery socket error: $error');
        if (!controller.isClosed) controller.addError(error, stackTrace);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );

    Timer(budget, () {
      if (!controller.isClosed) controller.close();
    });
  }

  Future<List<InternetAddress>> _broadcastTargets(int port) async {
    final targets = <InternetAddress>{
      InternetAddress('255.255.255.255'),
      InternetAddress('127.0.0.1'), // loopback lets a two-process local QA run
    };
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } catch (_) {
      // Interface enumeration is best-effort; the limited broadcast remains.
    }
    return targets.toList();
  }

  static String _newNonce() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(8, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _sub?.cancel();
    _socket?.close();
    _timer = null;
    _sub = null;
    _socket = null;
  }
}

// ---------------------------------------------------------------------------
// TCP probe / validate (§11.2)
// ---------------------------------------------------------------------------

/// Everything a client needs to trust a candidate before pairing.
class ServerProbe {
  final String baseUrl;
  final String serverId;
  final String storeName;
  final int protocol;
  final String version;
  final String database;
  final bool databaseConnected;

  const ServerProbe({
    required this.baseUrl,
    required this.serverId,
    required this.storeName,
    required this.protocol,
    required this.version,
    required this.database,
    required this.databaseConnected,
  });

  bool get healthy => databaseConnected;
}

/// Raised when the candidate answers but is not a Supermarket Pro server
/// (unrelated software, wrong app, incompatible protocol).
class NotASupermarketServerException implements Exception {
  final String reason;
  final String baseUrl;
  const NotASupermarketServerException(this.reason, this.baseUrl);

  @override
  String toString() => 'NotASupermarketServer($baseUrl): $reason';
}

const int supportedProtocolVersion = 1;
const Duration probeTimeout = Duration(seconds: 2);

/// Probes `GET /health` then `GET /system/info` (both are on the guard's
/// bootstrap allowlist, so this works before the device is paired).
///
/// Throws [NotASupermarketServerException] for anything that is not a
/// compatible Supermarket Pro server; connection failures surface as the
/// underlying [DioException].
Future<ServerProbe> probeServer(
  String baseUrl, {
  Dio? client,
  int expectedProtocol = supportedProtocolVersion,
}) async {
  final dio = client ??
      Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: probeTimeout,
          receiveTimeout: probeTimeout,
          headers: {'Accept': 'application/json'},
        ),
      );

  final health = await dio.get('/api/v1/health');
  final healthData = health.data;
  if (healthData is! Map) {
    throw NotASupermarketServerException('bad health payload', baseUrl);
  }

  final info = await dio.get('/api/v1/system/info');
  final data = info.data;
  if (data is! Map) {
    throw NotASupermarketServerException('bad system info payload', baseUrl);
  }

  final serverId = data['server_id'];
  final protocol = data['protocol'];
  if (serverId is! String || serverId.isEmpty) {
    throw NotASupermarketServerException('missing server_id', baseUrl);
  }
  if (protocol is! int) {
    throw NotASupermarketServerException('missing protocol', baseUrl);
  }
  if (protocol != expectedProtocol) {
    throw NotASupermarketServerException(
      'protocol $protocol != $expectedProtocol',
      baseUrl,
    );
  }

  // `GET /system/info` → name/version/database_status; `GET /health` →
  // database. Either being absent means this is not our contract.
  final storeName = data['name'];
  final version = data['version'];
  final dbStatus = data['database_status'] ?? healthData['database'];
  if (storeName is! String) {
    throw NotASupermarketServerException('missing name', baseUrl);
  }
  if (version is! String) {
    throw NotASupermarketServerException('missing version', baseUrl);
  }

  return ServerProbe(
    baseUrl: baseUrl,
    serverId: serverId,
    storeName: storeName,
    protocol: protocol,
    version: version,
    database: dbStatus is String ? dbStatus : 'unknown',
    databaseConnected: dbStatus == 'connected',
  );
}
