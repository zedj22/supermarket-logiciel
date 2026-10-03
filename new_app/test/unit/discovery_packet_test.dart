// Phase 16 (§11) discovery packet codec — pure functions, no sockets.
//
// The contract these tests pin down:
//   * framing is MAGIC + 0x00 + utf8(json) on both directions;
//   * a request is ≤ 256 B, an offer ≤ 512 B;
//   * anything that is not ours (wrong magic, wrong app, wrong version,
//     wrong type, oversized, malformed) is silently rejected — never a
//     throw, never a crash (§11.2 step 4);
//   * no packet ever carries a credential (the shapes are asserted here so
//     a future field cannot be added without a test changing).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';

void main() {
  const nonce = 'a1b2c3d4e5f60718';

  String rawJson(List<int> bytes) =>
      utf8.decode(bytes.sublist(utf8.encode(discoveryMagic).length + 1));

  group('buildDiscoverPacket', () {
    test('is framed with the magic prefix and a NUL separator', () {
      final packet = buildDiscoverPacket(nonce);
      final magic = utf8.decode(packet.sublist(0, discoveryMagic.length));
      expect(magic, discoveryMagic);
      expect(packet[discoveryMagic.length], 0);
    });

    test('carries version, app, type and the echoed nonce', () {
      final payload = jsonDecode(rawJson(buildDiscoverPacket(nonce)))
          as Map<String, dynamic>;
      expect(payload['v'], 1);
      expect(payload['app'], 'supermarket_pro');
      expect(payload['t'], 'discover');
      expect(payload['nonce'], nonce);
    });

    test('stays within the 256 byte request budget (§11.1)', () {
      expect(
        buildDiscoverPacket(nonce).length,
        lessThanOrEqualTo(maxDiscoverRequestBytes),
      );
      expect(buildDiscoverPacket('f' * 64).length,
          lessThanOrEqualTo(maxDiscoverRequestBytes));
    });

    test('never contains a credential-shaped field', () {
      final payload = jsonDecode(rawJson(buildDiscoverPacket(nonce)))
          as Map<String, dynamic>;
      for (final forbidden in [
        'token',
        'device_token',
        'code',
        'pairing_code',
        'password',
        'database',
        'postgres',
        'jwt',
      ]) {
        expect(payload.containsKey(forbidden), isFalse,
            reason: 'forbidden field in discover packet: $forbidden');
      }
    });
  });

  group('buildOfferPacket', () {
    test('echoes the nonce and carries identity, name and port', () {
      final packet = buildOfferPacket(
        nonce: nonce,
        serverId: '8f1f2a3b-0000-4000-8000-000000000001',
        name: 'My Store',
        httpPort: 8000,
      );
      final offer = parseOfferPacket(packet, fromAddress: '192.168.1.10');
      expect(offer, isNotNull);
      expect(offer!.nonce, nonce);
      expect(offer.serverId, '8f1f2a3b-0000-4000-8000-000000000001');
      expect(offer.name, 'My Store');
      expect(offer.httpPort, 8000);
      expect(offer.baseUrl, 'http://192.168.1.10:8000');
      expect(offer.tls, isFalse);
    });

    test('stays within the 512 byte response budget (§11.1)', () {
      final packet = buildOfferPacket(
        nonce: nonce,
        serverId: '8f1f2a3b-0000-4000-8000-000000000001',
        name: 'ن' * 80,
        httpPort: 8000,
      );
      expect(packet.length, lessThanOrEqualTo(maxOfferResponseBytes));
    });

    test('never contains a credential-shaped field', () {
      final payload = jsonDecode(rawJson(buildOfferPacket(
        nonce: nonce,
        serverId: 'server',
        name: 'Store',
        httpPort: 8000,
      ))) as Map<String, dynamic>;
      for (final forbidden in ['token', 'device_token', 'code', 'jwt']) {
        expect(payload.containsKey(forbidden), isFalse);
      }
    });
  });

  group('parseDiscoverPacket', () {
    test('returns the nonce for a well formed request', () {
      expect(parseDiscoverPacket(buildDiscoverPacket(nonce)), nonce);
    });

    test('rejects a nonce outside the 8..64 character window', () {
      expect(parseDiscoverPacket(buildDiscoverPacket('short')), isNull);
      expect(parseDiscoverPacket(buildDiscoverPacket('x' * 65)), isNull);
    });
  });

  group('parseOfferPacket rejection', () {
    List<int> offerBytes() => buildOfferPacket(
          nonce: nonce,
          serverId: 'server-1',
          name: 'Store',
          httpPort: 8000,
        );

    test('empty input', () {
      expect(parseOfferPacket(const []), isNull);
    });

    test('wrong magic', () {
      final bytes = offerBytes();
      bytes[0] = 0x58;
      expect(parseOfferPacket(bytes), isNull);
    });

    test('missing NUL separator', () {
      final bytes = offerBytes();
      bytes[discoveryMagic.length] = 0x20;
      expect(parseOfferPacket(bytes), isNull);
    });

    test('malformed JSON', () {
      final magic = utf8.encode(discoveryMagic);
      final bytes = [...magic, 0, ...utf8.encode('{not json')];
      expect(parseOfferPacket(bytes), isNull);
    });

    test('unknown app', () {
      final bytes = buildOfferPacket(
        nonce: nonce,
        serverId: 'server-1',
        name: 'Store',
        httpPort: 8000,
      );
      final payload =
          jsonDecode(rawJson(bytes)) as Map<String, dynamic>;
      payload['app'] = 'other_software';
      expect(
        parseOfferPacket([...utf8.encode(discoveryMagic), 0,
          ...utf8.encode(jsonEncode(payload))]),
        isNull,
      );
    });

    test('wrong protocol version', () {
      final payload = jsonDecode(rawJson(offerBytes())) as Map<String, dynamic>;
      payload['v'] = 99;
      expect(
        parseOfferPacket([...utf8.encode(discoveryMagic), 0,
          ...utf8.encode(jsonEncode(payload))]),
        isNull,
      );
    });

    test('wrong packet type (a discover packet is not an offer)', () {
      expect(
        parseOfferPacket(buildDiscoverPacket(nonce), fromAddress: '10.0.0.2'),
        isNull,
      );
    });

    test('oversized datagram', () {
      expect(parseOfferPacket(List<int>.filled(600, 0x41)), isNull);
    });

    test('missing or invalid http_port', () {
      final payload = jsonDecode(rawJson(offerBytes())) as Map<String, dynamic>;
      payload['http_port'] = 0;
      expect(
        parseOfferPacket([...utf8.encode(discoveryMagic), 0,
          ...utf8.encode(jsonEncode(payload))]),
        isNull,
      );
    });

    test('falls back to the datagram source when no sender is supplied', () {
      final offer =
          parseOfferPacket(offerBytes(), fromAddress: '192.168.0.7');
      expect(offer!.address, '192.168.0.7');
    });

    test('offers with the same address+id are equal (dedupe in the sweep)',
        () {
      final a = parseOfferPacket(offerBytes(), fromAddress: '10.0.0.5');
      final b = parseOfferPacket(offerBytes(), fromAddress: '10.0.0.5');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });
  });

  group('probeServer contract', () {
    test('supportedProtocolVersion is 1 (§19)', () {
      expect(supportedProtocolVersion, 1);
    });

    test('probe timeout is 2 s (§11.2)', () {
      expect(probeTimeout, const Duration(seconds: 2));
    });

    test('NotASupermarketServerException carries a reason and the URL', () {
      const e = NotASupermarketServerException('missing server_id', 'http://x');
      expect(e.reason, 'missing server_id');
      expect(e.baseUrl, 'http://x');
      expect(e.toString(), contains('http://x'));
    });
  });
}
