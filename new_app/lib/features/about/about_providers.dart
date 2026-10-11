// Read-only server metadata for the About page (Phase 2).
//
// `GET /api/v1/system/info` is public, non-business metadata the backend
// has always exposed (`backend/app/api/v1/system.py`): store name, server
// version, environment, protocol and server id. The About page shows only
// the store name and version; everything else stays available for future
// use. A failed load returns `null` — the page renders an "unavailable"
// placeholder instead of surfacing any exception to the operator.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';

/// Server-owned system metadata (`GET /api/v1/system/info`).
@immutable
class SystemInfo {
  const SystemInfo({
    required this.name,
    required this.version,
  });

  /// Relative path of the endpoint (no leading slash, the same join rule
  /// every other feature path uses).
  static const String path = '/api/v1/system/info';

  /// Store name the server reports (`settings.STORE_NAME`).
  final String name;

  /// Server application version (`APP_VERSION`).
  final String version;

  factory SystemInfo.fromJson(Map<String, dynamic> json) {
    return SystemInfo(
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
    );
  }
}

/// Loads the server's system info once per session and never throws:
/// a connection failure, an HTTP error or a session without a reachable
/// server all resolve to `null`, which the About page renders as an
/// "unavailable" placeholder. Cached by Riverpod after the first load, so
/// revisiting the page does not re-hit the network.
final systemInfoProvider = FutureProvider<SystemInfo?>((ref) async {
  final dio = ref.watch(apiClientProvider).dio;
  try {
    final response = await dio.get(SystemInfo.path);
    final data = response.data as Map<String, dynamic>? ?? const {};
    return SystemInfo.fromJson(data);
  } on DioException {
    return null;
  }
});
