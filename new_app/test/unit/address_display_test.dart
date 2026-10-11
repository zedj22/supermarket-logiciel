// Display-only server address shortening (host, never scheme/port).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/address_display.dart';

void main() {
  group('displayServerAddress', () {
    test('strips scheme and port from an IP endpoint', () {
      expect(displayServerAddress('http://192.168.1.10:8000'),
          '192.168.1.10');
    });

    test('strips scheme, port and path from an https endpoint', () {
      expect(displayServerAddress('https://192.168.1.100:8443/api'),
          '192.168.1.100');
    });

    test('keeps a hostname endpoint as its host', () {
      expect(displayServerAddress('http://pos-server.local:8000'),
          'pos-server.local');
    });

    test('unbrackets an IPv6 endpoint', () {
      expect(displayServerAddress('http://[fe80::1]:8000'), 'fe80::1');
    });

    test('tolerates scheme-less input', () {
      expect(displayServerAddress('192.168.1.10:8000'), '192.168.1.10');
      expect(displayServerAddress('store-server:8000'), 'store-server');
    });

    test('null / empty / whitespace collapse to empty', () {
      expect(displayServerAddress(null), '');
      expect(displayServerAddress(''), '');
      expect(displayServerAddress('   '), '');
    });

    test('unparseable input degrades to the trimmed value', () {
      expect(displayServerAddress('http://'), 'http://');
      expect(displayServerAddress('%%%'), '%%%');
      expect(displayServerAddress('  not a url  '), 'not a url');
      expect(displayServerAddress('http://not a url'), 'http://not a url');
    });

    test('never mutates the input (pure)', () {
      const stored = 'http://192.168.1.10:8000';
      expect(displayServerAddress(stored), '192.168.1.10');
      // The stored URL the connectivity stack uses is untouched.
      expect(stored, 'http://192.168.1.10:8000');
    });
  });
}
