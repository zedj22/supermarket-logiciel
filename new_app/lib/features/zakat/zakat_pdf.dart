// PDF export for the Zakat feature — server-rendered bytes + save dialog.
//
// Flow mirrors the Phase 15 export (`report_export.dart`): the backend
// renders the SAME figures the screen shows → the save dialog receives
// the server filename from `Content-Disposition` → one localized success
// toast. Cancel is neutral; every failure shows ONE localized toast and
// never a partial file.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/strings.dart';
import '../../network/byte_download.dart';
import '../pos/pos_toast.dart';
import 'zakat_error.dart';
import 'zakat_models.dart';
import 'zakat_providers.dart';

/// Ad-hoc preview PDF for an UNSAVED calculation (`POST /zakat/pdf`).
Future<bool> exportZakatPreviewPdf({
  required BuildContext context,
  required Dio dio,
  required String loc,
  required ZakatCalculationInput input,
}) {
  return _exportPdf(
    context: context,
    dio: dio,
    loc: loc,
    fallbackName: 'zakat-preview.pdf',
    send: () => dio.post<Uint8List>(
      '$kZakatPath/pdf',
      queryParameters: <String, dynamic>{'locale': loc},
      data: input.toJson(),
      options: Options(responseType: ResponseType.bytes),
    ),
  );
}

/// Snapshot PDF for one saved calculation (`GET /zakat/{id}/pdf`).
Future<bool> exportZakatDetailPdf({
  required BuildContext context,
  required Dio dio,
  required String loc,
  required String calculationId,
}) {
  return _exportPdf(
    context: context,
    dio: dio,
    loc: loc,
    fallbackName: 'zakat-$calculationId.pdf',
    send: () => dio.get<Uint8List>(
      '$kZakatPath/$calculationId/pdf',
      queryParameters: <String, dynamic>{'locale': loc},
      options: Options(responseType: ResponseType.bytes),
    ),
  );
}

Future<bool> _exportPdf({
  required BuildContext context,
  required Dio dio,
  required String loc,
  required String fallbackName,
  required Future<Response<Uint8List>> Function() send,
}) async {
  try {
    final Uint8List bytes;
    final String fileName;
    try {
      final response = await send();
      bytes = bytesOfResponse(response.data);
      fileName = filenameFromDisposition(
        response.headers.value('content-disposition'),
        fallbackName,
      );
    } on DioException catch (e) {
      if (context.mounted) _fail(context, zakatApiMessage(e, loc));
      return false;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: AppStrings.t('zakat_pdf', loc),
      fileName: fileName,
      bytes: bytes,
    );
    if (path == null) return false; // user cancelled — no toast
    if (!context.mounted) return true;
    showPosToast(
      context,
      message: AppStrings.t('export_done', loc),
      detail: fileName,
      kind: PosToastKind.success,
      key: const Key('zakat-export-toast'),
    );
    return true;
  } on Object catch (_) {
    if (context.mounted) _fail(context, AppStrings.t('export_failed', loc));
    return false;
  }
}

void _fail(BuildContext context, String message) {
  showPosToast(
    context,
    message: message,
    kind: PosToastKind.error,
    key: const Key('zakat-export-toast'),
  );
}
