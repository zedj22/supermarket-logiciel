// Display-only short form of a stored server endpoint.
//
// The pairing / connectivity model keeps the FULL URL everywhere it
// matters — SharedPreferences (`server_address`), the ApiClient base URL,
// the reconnect probe, and every clipboard copy (a worker pastes
// `ip:port` into the wizard, so the port must survive the clipboard).
// This helper only shapes what the cashier SEES on screen: the bare
// host — an IP like `192.168.1.10`, or a hostname like `store-server`
// when the endpoint was addressed by name — never scheme, never port.
//
// Pure + total: anything unparseable (empty, garbage, scheme without a
// host) degrades to the trimmed input instead of throwing or blanking a
// label the user needs.

/// Short human-readable host of [endpoint] for display.
///
/// * `http://192.168.1.10:8000` → `192.168.1.10`
/// * `https://192.168.1.100:8443/api` → `192.168.1.100`
/// * `http://pos-server.local:8000` → `pos-server.local`
/// * `http://[fe80::1]:8000` → `fe80::1`
/// * `192.168.1.10:8000` (scheme-less) → `192.168.1.10`
/// * `null` / `''` / whitespace → `''`
/// * anything unparseable (or whose host is not a plausible host) → the
///   trimmed input, unchanged.
String displayServerAddress(String? endpoint) {
  final trimmed = (endpoint ?? '').trim();
  if (trimmed.isEmpty) return '';
  // Tolerate scheme-less input (`192.168.1.10:8000`, `host:8000`) so a
  // remembered value typed by hand still shortens correctly.
  final candidate = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.tryParse(candidate);
  final host = uri?.host ?? '';
  if (!_isPlausibleHost(host)) return trimmed;
  // Dart's Uri.host is already unbracketed for IPv6; keep the strip for
  // safety if a future SDK hands back the bracketed form.
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.substring(1, host.length - 1);
  }
  return host;
}

/// Dart's [Uri] is lenient: it percent-encodes garbage (`not a url` →
/// `not%20a%20url`, `%%%` → `%25%25%25`) instead of failing to parse, so
/// a successful parse alone is not enough — the host must LOOK like one:
/// an IPv6 literal (`:`) or a plain hostname/IP of letters, digits, dots,
/// hyphens and underscores. Anything else falls back to the raw input.
bool _isPlausibleHost(String host) {
  if (host.isEmpty) return false;
  if (host.contains(':')) return true; // IPv6 literal (unbracketed)
  return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);
}
