// Backend PDF fetch for documents (Phase 15 §12.2).
//
// `POST /api/v1/print` returns application/pdf bytes plus a sanitized
// server-side filename in `Content-Disposition`. Requests use
// `ResponseType.bytes` so the PDF is never run through the JSON
// transformer; error envelopes are decoded back by the shared byte
// helpers so the standard localized error mapping still works.
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../network/byte_download.dart';

/// `POST /api/v1/print` — render sale / return / purchase as PDF.
const String kPrintPath = '/api/v1/print';

/// Rendered document bytes + the server-generated download filename.
class PrintDocument {
  const PrintDocument({
    required this.bytes,
    required this.filename,
    required this.paper,
  });

  final Uint8List bytes;
  final String filename;

  /// `80mm` | `A4` | `roll` — the paper the bytes were rendered for.
  final String paper;
}

/// Renders one document via the backend and returns the bytes + filename.
///
/// Throws [DioException] (envelope-normalized) on failure so callers can
/// run it through the standard localized error mapping.
Future<PrintDocument> fetchPrintDocument(
  Dio dio, {
  required String documentType,
  required String documentId,
  required String paper,
  required String locale,
  String? deviceId,
}) async {
  final Response<Uint8List> response;
  try {
    response = await dio.post<Uint8List>(
      kPrintPath,
      data: <String, dynamic>{
        'document_type': documentType,
        'document_id': documentId,
        'paper': paper,
        'locale': locale,
        if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
      },
      options: Options(
        responseType: ResponseType.bytes,
        headers: <String, dynamic>{
          if (deviceId != null && deviceId.isNotEmpty) 'X-Device-ID': deviceId,
        },
      ),
    );
  } on DioException catch (e) {
    throw decodeByteErrorEnvelope(e);
  }
  return PrintDocument(
    bytes: bytesOfResponse(response.data),
    filename: filenameFromDisposition(
      response.headers.value('content-disposition'),
      '$documentType-$documentId.pdf',
    ),
    paper: paper,
  );
}

/// `POST /api/v1/print/labels` — render product price / barcode labels.
const String kPrintLabelsPath = '/api/v1/print/labels';

/// One selected product: its shelf label printed [quantity] times.
class LabelPrintItem {
  const LabelPrintItem({required this.productId, required this.quantity});

  final String productId;
  final int quantity;
}

/// Renders a label batch as PDF. Prices are resolved SERVER-side (promo
/// price when an active promotion applies) — the client never sends a
/// price; `layout` only carries physical sheet geometry (mm / cols / rows)
/// and may be omitted for the default 50x30 mm A4 grid.
Future<PrintDocument> fetchLabelPdf(
  Dio dio, {
  required List<LabelPrintItem> items,
  required String paper,
  required String locale,
  Map<String, dynamic>? layout,
  String? deviceId,
}) async {
  final Response<Uint8List> response;
  final Map<String, dynamic> body = <String, dynamic>{
    'items': [
      for (final item in items)
        <String, dynamic>{
          'product_id': item.productId,
          'quantity': item.quantity,
        },
    ],
    'paper': paper,
    'locale': locale,
  };
  // Layout only when sent — absence tells the server to auto-fit the grid.
  if (layout != null) body['layout'] = layout;
  if (deviceId != null && deviceId.isNotEmpty) body['device_id'] = deviceId;
  try {
    response = await dio.post<Uint8List>(
      kPrintLabelsPath,
      data: body,
      options: Options(
        responseType: ResponseType.bytes,
        headers: <String, dynamic>{
          if (deviceId != null && deviceId.isNotEmpty) 'X-Device-ID': deviceId,
        },
      ),
    );
  } on DioException catch (e) {
    throw decodeByteErrorEnvelope(e);
  }
  return PrintDocument(
    bytes: bytesOfResponse(response.data),
    filename: filenameFromDisposition(
      response.headers.value('content-disposition'),
      'labels.pdf',
    ),
    paper: paper,
  );
}
