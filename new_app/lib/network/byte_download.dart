// Shared helpers for `ResponseType.bytes` downloads (Phase 15).
//
// The export/print endpoints return raw file bytes with a sanitized
// server-side filename in `Content-Disposition`. Error envelopes that
// arrive as raw bytes are decoded back to JSON here so the standard
// localized error mapping (`backendErrorCode` / `backendErrorMessage`)
// keeps working for byte requests too.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

final _filenamePattern = RegExp(r'filename="([^"]+)"');

/// Parses `attachment; filename="x.pdf"` (server-sanitized, §10.1).
/// Returns [fallback] when the header or the filename is absent.
String filenameFromDisposition(String? disposition, String fallback) {
  if (disposition == null) return fallback;
  final match = _filenamePattern.firstMatch(disposition);
  final name = match?.group(1)?.trim();
  if (name == null || name.isEmpty) return fallback;
  return name;
}

/// Coerces a byte-typed response body to [Uint8List].
Uint8List bytesOfResponse(Object? data) {
  if (data is Uint8List) return data;
  if (data is List<int>) return Uint8List.fromList(data);
  if (data is String) return Uint8List.fromList(utf8.encode(data));
  throw const FormatException('response body is not bytes');
}

/// Decodes a `ResponseType.bytes` error body back into the JSON envelope.
/// Non-JSON bodies (HTML error pages) are left untouched.
DioException decodeByteErrorEnvelope(DioException error) {
  final data = error.response?.data;
  if (data is List<int> && data.isNotEmpty) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map) {
        error.response?.data = decoded;
      }
    } catch (_) {
      // Not JSON — keep the raw bytes.
    }
  }
  return error;
}
