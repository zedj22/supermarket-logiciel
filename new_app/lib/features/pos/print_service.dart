// Print service abstraction (UX FIX #4 Part B, Phase 15 §6.2).
//
// Sale printing is never part of the sale transaction. The sale commits
// first; print runs only from the sale-detail actions and may fail
// independently. Failure shows a localized error — never "success".
//
// Phase 15: the PRIMARY path is [PrintService.printPdf] — backend PDF
// bytes handed to the Windows print dialog through the `printing` plugin
// (`Printing.layoutPdf`, §6.2 D). `printText` stays as the legacy-internal
// text path (`Out-Printer`); the PDF preview supersedes the text receipt
// for the sale/reprint UI (§6.2 E).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

abstract class PrintService {
  /// Sends the PDF [bytes] to the system print dialog (printer selection,
  /// copies, paper size). [paper] is `80mm` or `A4`.
  ///
  /// Throws [PrintServiceException] on failure. A user-cancelled system
  /// dialog is NOT a failure (cancellation is neutral, §16.2) — it simply
  /// returns.
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  });

  /// Sends [text] to the default system printer (legacy text path).
  /// Throws [PrintServiceException] on failure.
  Future<void> printText(String text);
}

class PrintServiceException implements Exception {
  final String message;

  /// Optional localization key (`printer_unavailable`) — when set the UI
  /// shows the key's translation instead of `print_failed: message`.
  final String? code;

  const PrintServiceException(this.message, {this.code});

  @override
  String toString() => message;
}

/// Windows printer: PDF via the `printing` plugin system dialog, text via
/// PowerShell `Out-Printer` (legacy fallback).
class WindowsPrintService implements PrintService {
  @override
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) async {
    if (bytes.isEmpty) {
      throw const PrintServiceException('empty pdf');
    }
    // `false` = the user cancelled the system dialog — neutral (§16.2).
    try {
      final info = await Printing.info();
      if (!info.canPrint) {
        throw const PrintServiceException(
          'no printer available',
          code: 'printer_unavailable',
        );
      }
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: filename ?? 'document',
        format: paper == 'A4' ? PdfPageFormat.a4 : PdfPageFormat.roll80,
      );
    } on PrintServiceException {
      rethrow;
    } catch (e) {
      throw PrintServiceException('$e');
    }
  }

  @override
  Future<void> printText(String text) async {
    if (text.isEmpty) {
      throw const PrintServiceException('empty receipt');
    }
    final tmpDir = Directory.systemTemp;
    final file = File(
      '${tmpDir.path}${Platform.pathSeparator}'
      'pos_receipt_${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    try {
      await file.writeAsString(text, flush: true);
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"Get-Content -LiteralPath '" +
              file.path.replaceAll("'", "''") +
              r"' | Out-Printer",
        ],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      if (result.exitCode != 0) {
        final err = '${result.stderr}'.trim();
        throw PrintServiceException(
          err.isEmpty ? 'printer exit ${result.exitCode}' : err,
        );
      }
    } on ProcessException catch (e) {
      throw PrintServiceException(e.message);
    } on FileSystemException catch (e) {
      throw PrintServiceException(e.message);
    } finally {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // Temp cleanup is best-effort — never fails the print result.
      }
    }
  }
}

/// Overridable in tests (fake success / fake failure).
final printServiceProvider = Provider<PrintService>((ref) {
  return WindowsPrintService();
});
