import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A response produced by [FakeJsonAdapter]'s handler.
typedef FakeJsonResponse = ({int statusCode, Object body});

/// An in-memory `HttpClientAdapter` so feature tests can exercise the real
/// Dio pipeline (path, verb, body, status handling) without a server.
///
/// Every request is recorded in [requests] so tests can assert exactly what
/// the client sent.
class FakeJsonAdapter implements HttpClientAdapter {
  FakeJsonAdapter(this.handler);

  final Future<FakeJsonResponse> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A Dio wired to [adapter] with a stable base URL, ready to be handed to
/// `ApiClient(dio: ...)`.
Dio fakeDio(FakeJsonAdapter adapter) {
  return Dio(
    BaseOptions(
      baseUrl: 'http://fake.test',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  )..httpClientAdapter = adapter;
}

/// A typical `GET /settings` payload as the backend returns it.
const Map<String, Object> kDefaultSettingsJson = <String, Object>{
  'store_name': 'Supermarket Pro',
  'store_phone': '',
  'store_address': '',
  'invoice_footer': '',
  'store_wilaya': '',
  'store_email': '',
  'store_nif': '',
  'store_nis': '',
  'store_rc': '',
  'store_ai': '',
  'store_rib': '',
  'default_paper': '80mm',
  'ask_before_print': false,
  'auto_print_invoice': false,
  'receipt_print_mode': 'disabled',
  'receipt_min_amount': 0,
  'allow_debt': true,
  'low_stock_threshold': 5,
};
