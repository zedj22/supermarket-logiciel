// Print service abstraction (UX FIX #4 Part B).
//
// Sale printing is never part of the sale transaction. The sale commits
// first; print runs only from the sale-detail actions and may fail
// independently. Failure shows a localized error — never "success".
//
// Default Windows implementation: write the text receipt to a temp file
// and hand it to PowerShell `Out-Printer`. No extra pubspec packages.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class PrintService {
  /// Sends [text] to the default system printer.
  /// Throws [PrintServiceException] on failure.
  Future<void> printText(String text);
}

class PrintServiceException implements Exception {
  final String message;
  const PrintServiceException(this.message);

  @override
  String toString() => message;
}

/// Windows text-receipt printer via PowerShell Out-Printer.
class WindowsPrintService implements PrintService {
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
