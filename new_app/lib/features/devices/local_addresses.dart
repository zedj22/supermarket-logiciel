import 'dart:io';

/// Addresses a worker can type to reach THIS computer as the store
/// server (Main PC).
///
/// Phase 12 of the UI/UX pass: the person running the Main PC has to be
/// able to read an address off the Devices screen and type it into a
/// till — discovery usually finds it on its own, but a second subnet or
/// a disabled broadcast must never be a dead end.
///
/// Loopback and link-local addresses are dropped (a till on another
/// machine cannot use them); everything else is returned as a ready-to-
/// type `http://ip:port` URL, IPv4 only. Never throws: no socket, no
/// permissions or an offline machine simply yields an empty list and the
/// caller shows the localized "no address" copy.
Future<List<String>> storeServerUrls({int port = 8000}) async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final urls = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        urls.add('http://${address.address}:$port');
      }
    }
    return urls;
  } catch (_) {
    return const [];
  }
}
