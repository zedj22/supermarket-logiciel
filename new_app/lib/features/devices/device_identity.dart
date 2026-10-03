// Phase 16 — device identity + persisted server link (§9, §23.2).
//
// Three-layer separation (§9.3), kept strictly apart:
//
//   1. machine identity  `pos_device_id`  — immutable, generated once,
//      never renamed, never a credential (it is what an admin approves).
//   2. device credential `device_token`   — the one-time token from admin
//      approval; lives in flutter_secure_storage, never logged.
//   3. user session      JWT              — lives in flutter_secure_storage
//      and is cleared on logout; pairing deliberately survives it.
//
// The server address + server_id are ordinary SharedPreferences: leaking
// "the shop is at 192.168.1.10" is not a secret, whereas the token is.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../auth/credential_storage.dart';

/// Immutable storage key for the machine identity. Phase 14 depends on this
/// exact key and on the `pos-<millis>-<rand>` format — never change either.
const String posDeviceIdStorageKey = 'pos_device_id';

/// Persisted address of the paired server (`http://host:port`).
const String pairedServerUrlStorageKey = 'paired_server_url';

/// Persisted `server_id` of the paired server. IP is not identity (§14):
/// a changed address is fine, a changed `server_id` means re-pair.
const String pairedServerIdStorageKey = 'paired_server_id';

/// `server` or `client` — the role chosen in the setup wizard (§8.1).
const String appRunModeStorageKey = 'app_run_mode';

const String appRunModeServer = 'server';
const String appRunModeClient = 'client';

/// Generates (once) and returns this machine's immutable `pos-…` id.
///
/// The format and storage key are a Phase 14 contract: reports group sales
/// by this string and the Phase 16 guard looks it up verbatim.
Future<String> ensurePosDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(posDeviceIdStorageKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final generated = 'pos-${DateTime.now().millisecondsSinceEpoch}-'
      '${Random().nextInt(0x7fffffff)}';
  await prefs.setString(posDeviceIdStorageKey, generated);
  return generated;
}

/// App-level machine identity (§23.2 — promoted out of the POS feature).
final deviceIdProvider = FutureProvider<String>((ref) {
  return ensurePosDeviceId();
});

/// The wizard/role chosen by this install, or null on first run.
Future<String?> readAppRunMode() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(appRunModeStorageKey);
}

Future<void> writeAppRunMode(String mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(appRunModeStorageKey, mode);
}

/// Everything the client needs to talk to a paired server again after a
/// restart. Null values mean "not paired".
class ServerLink {
  final String? url;
  final String? serverId;
  final String? deviceToken;

  const ServerLink({this.url, this.serverId, this.deviceToken});

  bool get isPaired =>
      url != null &&
      url!.isNotEmpty &&
      deviceToken != null &&
      deviceToken!.isNotEmpty;

  ServerLink copyWith({String? url, String? serverId, String? deviceToken}) {
    return ServerLink(
      url: url ?? this.url,
      serverId: serverId ?? this.serverId,
      deviceToken: deviceToken ?? this.deviceToken,
    );
  }
}

/// Reads the persisted link (prefs for address, keystore for the token).
Future<ServerLink> readServerLink() async {
  final prefs = await SharedPreferences.getInstance();
  final token = await SecureCredentialStorage().readDeviceToken();
  return ServerLink(
    url: prefs.getString(pairedServerUrlStorageKey),
    serverId: prefs.getString(pairedServerIdStorageKey),
    deviceToken: token,
  );
}

/// Persists a freshly approved pairing.
Future<void> writeServerLink(ServerLink link) async {
  final prefs = await SharedPreferences.getInstance();
  if (link.url != null) {
    await prefs.setString(pairedServerUrlStorageKey, link.url!);
  }
  if (link.serverId != null) {
    await prefs.setString(pairedServerIdStorageKey, link.serverId!);
  }
  if (link.deviceToken != null) {
    await SecureCredentialStorage().saveDeviceToken(link.deviceToken!);
  }
}

/// Forgets the server link (re-pair, mode reset, or a changed `server_id`).
///
/// The machine identity is intentionally preserved: this install is still
/// the same till.
Future<void> clearServerLink() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(pairedServerUrlStorageKey);
  await prefs.remove(pairedServerIdStorageKey);
  await SecureCredentialStorage().clearDeviceToken();
}

/// True when the app has completed the first-run wizard.
Future<bool> isNetworkConfigured() async {
  final mode = await readAppRunMode();
  if (mode == null || mode.isEmpty) return false;
  if (mode == appRunModeClient) {
    final link = await readServerLink();
    return link.isPaired;
  }
  return true;
}

/// Cached first-run state. Watched by the router so an unpaired client is
/// forced into `/setup-network` before login (§23.2), and invalidated by the
/// wizard the moment a role is chosen.
final networkConfiguredProvider = FutureProvider<bool>((ref) async {
  return isNetworkConfigured();
});

/// True only for installs that went through the real `main()` bootstrap.
///
/// The first-run wizard is enforced by the router, and enforcing it means
/// refusing every other route until a role has been chosen. That is correct
/// for a launched install but wrong for hosts that embed
/// `SupermarketPosApp` without bootstrapping an install (widget-test
/// harnesses, previews): they have no machine identity and no run mode, yet
/// they must keep reaching login. `main()` turns this on for every real
/// launch, so production behaviour is unchanged and harnesses stay inert.
final installBootstrappedProvider = Provider<bool>((ref) => false);

/// Base URL the client should boot with: the remembered server when paired,
/// otherwise the single-PC default.
Future<String> initialBaseUrl() async {
  final link = await readServerLink();
  final url = link.url;
  if (url != null && url.isNotEmpty) return url;
  return AppConstants.defaultServerBaseUrl;
}
