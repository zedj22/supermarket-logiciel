// PDF preview seam (Phase 15 §6.2 E).
//
// The default implementation rasterizes the backend bytes with the
// `printing` package's `PdfPreview` (page-accurate, zoomable — preview
// shows EXACTLY what will be printed). Tests override
// [pdfPreviewProvider] with a lightweight widget so no rasterizer/plugin
// channel is required in the widget-test environment (§19.2).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// Page format for a `paper` code (`80mm` | `A4` | `roll`).
///
/// Purely an initial viewport hint — the rasterized pages come from the
/// actual PDF bytes, so a `roll` document previews at its true media
/// size (the narrow roll80 hint is the closest built-in format).
PdfPageFormat pdfPageFormatFor(String paper) =>
    paper == 'A4' ? PdfPageFormat.a4 : PdfPageFormat.roll80;

/// Renders the preview widget for one rendered document.
abstract class PdfPreviewBuilder {
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  });
}

/// Production preview: `PdfPreview` from the `printing` package.
class PrintingPdfPreview implements PdfPreviewBuilder {
  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  }) {
    return PdfPreview(
      key: const ValueKey<String>('pdf-preview'),
      build: (_) async => bytes,
      initialPageFormat: pdfPageFormatFor(paper),
      pdfFileName: filename,
      allowPrinting: false,
      allowSharing: false,
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      useActions: false,
      actions: const <Widget>[],
      dynamicLayout: false,
    );
  }
}

/// Overridable in tests (no rasterizer / no plugin channels).
final pdfPreviewProvider = Provider<PdfPreviewBuilder>((ref) {
  return PrintingPdfPreview();
});
