// CSV export orchestration for Phase 14 (§12.2).
//
// Flow: build the CSV from the SAME endpoint/filters the screen shows →
// hand UTF-8 bytes to `file_picker.saveFile` (writes them on Windows) →
// localized success toast. Failures surface as localized toasts:
//   * `export_row_limit` — the report exceeds 50 000 rows (§12.2),
//   * localized message for 403/422 (`reportsApiMessage`),
//   * `export_failed` — write/dialog failure.
//
// The export button itself is only rendered with `export_data` (§10);
// the request-time 403 is still enforced by the backend.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/strings.dart';
import '../pos/pos_toast.dart';
import 'report_csv.dart';
import 'report_models.dart';
import 'reports_error.dart';
import 'reports_providers.dart';

/// Export cannot complete; [messageKey] is localized by the caller.
class ReportExportException implements Exception {
  ReportExportException(this.messageKey);

  /// One of `export_row_limit` / `export_failed`.
  final String messageKey;

  @override
  String toString() => messageKey;
}

// ---------------------------------------------------------------------------
// Page walk for row-level reports (§12.2: same endpoint, page_size=100)
// ---------------------------------------------------------------------------

/// `GET /reports/products` until every page is collected (R2 export).
Future<ProductReportPage> fetchAllProducts(
  Dio dio,
  ReportFilter filter, {
  required String sort,
}) async {
  final items = <ProductReportRow>[];
  ProductReportPage? last;
  var page = 1;
  while (true) {
    final response = await dio.get(
      '$kReportsPath/products',
      queryParameters: <String, dynamic>{
        ...filter.rangeParams(),
        'sort': sort,
        'page': page,
        'page_size': kReportPageSize,
      },
    );
    last = ProductReportPage.fromJson(
      response.data as Map<String, dynamic>? ?? const {},
    );
    if (last.total > kExportRowLimit) {
      throw ReportExportException('export_row_limit');
    }
    items.addAll(last.items);
    if (page >= last.pages || last.items.isEmpty) break;
    page++;
  }
  return ProductReportPage(
    dateFrom: last.dateFrom,
    dateTo: last.dateTo,
    deviceId: last.deviceId,
    sort: last.sort,
    items: items,
    total: last.total,
    page: 1,
    pageSize: last.pageSize,
    pages: 1,
    totals: last.totals,
  );
}

/// `GET /reports/voided` until every page is collected (R8 export).
Future<VoidedReportPage> fetchAllVoided(
  Dio dio,
  ReportFilter filter,
) async {
  final items = <VoidedSaleRow>[];
  VoidedReportPage? last;
  var page = 1;
  while (true) {
    final response = await dio.get(
      '$kReportsPath/voided',
      queryParameters: <String, dynamic>{
        ...filter.rangeParams(),
        'page': page,
        'page_size': kReportPageSize,
      },
    );
    last = VoidedReportPage.fromJson(
      response.data as Map<String, dynamic>? ?? const {},
    );
    if (last.total > kExportRowLimit) {
      throw ReportExportException('export_row_limit');
    }
    items.addAll(last.items);
    if (page >= last.pages || last.items.isEmpty) break;
    page++;
  }
  return VoidedReportPage(
    dateFrom: last.dateFrom,
    dateTo: last.dateTo,
    deviceId: last.deviceId,
    items: items,
    total: last.total,
    page: 1,
    pageSize: last.pageSize,
    pages: 1,
  );
}

/// `GET /reports/sales` until every page is collected (R9 export).
Future<SalesDetailPage> fetchAllSales(
  Dio dio,
  ReportFilter filter, {
  required String status,
  String? paymentMethod,
}) async {
  final items = <SalesDetailRow>[];
  SalesDetailPage? last;
  var page = 1;
  while (true) {
    final response = await dio.get(
      '$kReportsPath/sales',
      queryParameters: <String, dynamic>{
        ...filter.rangeParams(),
        'status': status,
        if (paymentMethod != null && paymentMethod.isNotEmpty)
          'payment_method': paymentMethod,
        'page': page,
        'page_size': kReportPageSize,
      },
    );
    last = SalesDetailPage.fromJson(
      response.data as Map<String, dynamic>? ?? const {},
    );
    if (last.total > kExportRowLimit) {
      throw ReportExportException('export_row_limit');
    }
    items.addAll(last.items);
    if (page >= last.pages || last.items.isEmpty) break;
    page++;
  }
  return SalesDetailPage(
    dateFrom: last.dateFrom,
    dateTo: last.dateTo,
    status: last.status,
    items: items,
    total: last.total,
    page: 1,
    pageSize: last.pageSize,
    pages: 1,
    totals: last.totals,
  );
}

/// `GET /reports/slow-moving` until every page is collected (R7 export).
Future<SlowMovingPage> fetchAllSlowMoving(
  Dio dio, {
  required int days,
  required int threshold,
}) async {
  final items = <SlowMovingRow>[];
  SlowMovingPage? last;
  var page = 1;
  while (true) {
    final response = await dio.get(
      '$kReportsPath/slow-moving',
      queryParameters: <String, dynamic>{
        'days': days,
        'threshold': threshold,
        'page': page,
        'page_size': kReportPageSize,
      },
    );
    last = SlowMovingPage.fromJson(
      response.data as Map<String, dynamic>? ?? const {},
    );
    if (last.total > kExportRowLimit) {
      throw ReportExportException('export_row_limit');
    }
    items.addAll(last.items);
    if (page >= last.pages || last.items.isEmpty) break;
    page++;
  }
  return SlowMovingPage(
    days: last.days,
    threshold: last.threshold,
    items: items,
    total: last.total,
    page: 1,
    pageSize: last.pageSize,
    pages: 1,
  );
}

// ---------------------------------------------------------------------------
// Save dialog + toasts
// ---------------------------------------------------------------------------

/// Full §12.2 export flow for one report surface:
/// [build] produces the CSV text (possibly after paging), then the save
/// dialog receives the BOM-prefixed UTF-8 bytes.
///
/// Returns `true` only when the file was handed to the picker (the user
/// did not cancel). Every failure path shows ONE localized toast — never
/// a partial file (bytes are written only after the user confirms).
Future<bool> exportReportCsv({
  required BuildContext context,
  required String loc,
  required String reportSlug,
  required String dateFrom,
  required String dateTo,
  required Future<String> Function() build,
}) async {
  try {
    final String csv;
    try {
      csv = await build();
    } on ReportExportException catch (e) {
      if (context.mounted) _fail(context, AppStrings.t(e.messageKey, loc));
      return false;
    } on DioException catch (e) {
      if (context.mounted) _fail(context, reportsApiMessage(e, loc));
      return false;
    }
    final fileName = reportCsvFilename(
      report: reportSlug,
      dateFrom: dateFrom,
      dateTo: dateTo,
      now: DateTime.now(),
    );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: AppStrings.t('export_csv', loc),
      fileName: fileName,
      bytes: Uint8List.fromList(csvBytes(csv)),
    );
    if (path == null) return false; // user cancelled — no toast
    if (!context.mounted) return true;
    showPosToast(
      context,
      message: AppStrings.t('export_done', loc),
      detail: fileName,
      kind: PosToastKind.success,
      key: const Key('reports-export-toast'),
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
    key: const Key('reports-export-toast'),
  );
}
