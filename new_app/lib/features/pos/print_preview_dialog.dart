// Print preview dialog (Phase 15 §6.2 E / §16.2).
//
// Preview-first: the backend PDF for the chosen paper is fetched, then
// rasterized by the injectable [pdfPreviewProvider] seam (PdfPreview in
// production). Cancel closes with no print and no toast; Confirm hands
// the SAME bytes back to the caller, which runs `printPdf` through the
// system dialog (§6.2 D). Save-PDF is always available (QA fallback 12).
//
// Failures are localized, never swallowed: a fetch failure shows the
// typed message (`print_render_failed` / `missing_font` / …) with a
// retry, a save failure shows the existing `export_failed` toast, and a
// print failure is rendered by the CALLER (never a success toast, §16.2).
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'pos_error_message.dart';
import 'pos_toast.dart';
import 'pdf_preview.dart';
import 'print_document.dart';

/// Result of a confirmed print preview: the bytes to print + their paper.
class PrintPreviewResult {
  const PrintPreviewResult({
    required this.bytes,
    required this.paper,
    required this.filename,
  });

  final Uint8List bytes;
  final String paper;
  final String filename;
}

Future<PrintPreviewResult?> showPrintPreviewDialog(
  BuildContext context, {
  required String documentType,
  required String documentId,
  String initialPaper = '80mm',
  String? deviceId,
}) {
  return showDialog<PrintPreviewResult>(
    context: context,
    builder: (_) => PrintPreviewDialog(
      documentType: documentType,
      documentId: documentId,
      initialPaper: initialPaper,
      deviceId: deviceId,
    ),
  );
}

class PrintPreviewDialog extends ConsumerStatefulWidget {
  const PrintPreviewDialog({
    super.key,
    required this.documentType,
    required this.documentId,
    this.initialPaper = '80mm',
    this.deviceId,
  });

  final String documentType;
  final String documentId;
  final String initialPaper;
  final String? deviceId;

  @override
  ConsumerState<PrintPreviewDialog> createState() => _PrintPreviewDialogState();
}

class _PrintPreviewDialogState extends ConsumerState<PrintPreviewDialog> {
  String _paper = '80mm';
  PrintDocument? _doc;
  bool _loading = true;
  String? _error;
  bool _saving = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _paper = widget.initialPaper;
    Future.microtask(() => _fetch(_paper));
  }

  String get _loc => ref.read(localeProvider).flutterLocale.languageCode;

  Future<void> _fetch(String paper) async {
    final requestId = ++_requestId;
    setState(() {
      _paper = paper;
      _loading = true;
      _error = null;
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final doc = await fetchPrintDocument(
        dio,
        documentType: widget.documentType,
        documentId: widget.documentId,
        paper: paper,
        locale: _loc,
        deviceId: widget.deviceId,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _doc = doc;
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _doc = null;
        _loading = false;
        // Typed envelope codes first (§16.1), generic preview key after.
        _error = _printFetchMessage(e, _loc);
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _doc = null;
        _loading = false;
        _error = AppStrings.t('print_preview_failed', _loc);
      });
    }
  }

  /// Localized headline for a failed `POST /print` (envelope code first).
  String _printFetchMessage(DioException error, String loc) {
    switch (backendErrorCode(error)) {
      case 'PRINT_RENDER_FAILED':
        return AppStrings.t('print_render_failed', loc);
      case 'MISSING_FONT':
        return AppStrings.t('missing_font', loc);
      case 'VALIDATION_ERROR':
        return AppStrings.t('validation_error', loc);
      case 'FORBIDDEN':
      case 'AUTHORIZATION_ERROR':
        return AppStrings.t('permission_denied', loc);
      case 'UNAUTHORIZED':
      case 'AUTHENTICATION_ERROR':
        return AppStrings.t('session_expired_login', loc);
      case 'NOT_FOUND':
        return AppStrings.t('print_preview_failed', loc);
      default:
        return posApiError(
          error,
          loc,
          fallbackKey: 'print_preview_failed',
        ).message;
    }
  }

  Future<void> _savePdf() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    final loc = _loc;
    setState(() => _saving = true);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: AppStrings.t('save_pdf', loc),
        fileName: doc.filename,
        bytes: doc.bytes,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (path == null) return; // user cancelled — neutral, no toast (§16.2)
      showPosToast(
        context,
        message: AppStrings.t('pdf_saved', loc),
        detail: doc.filename,
        kind: PosToastKind.success,
        key: const Key('print-save-pdf-toast'),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showPosToast(
        context,
        message: AppStrings.t('export_failed', loc),
        kind: PosToastKind.error,
        key: const Key('print-save-pdf-toast'),
      );
    }
  }

  void _confirm() {
    final doc = _doc;
    if (doc == null || _loading) return;
    Navigator.of(context).pop(
      PrintPreviewResult(
        bytes: doc.bytes,
        paper: doc.paper,
        filename: doc.filename,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final doc = _doc;

    return AlertDialog(
      key: const Key('print-preview-dialog'),
      title: Text(AppStrings.t('print_dialog_title', loc)),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              key: const Key('print-paper-toggle'),
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: '80mm',
                  label: Text(AppStrings.t('paper_80mm', loc)),
                ),
                ButtonSegment<String>(
                  value: 'A4',
                  label: Text(AppStrings.t('paper_a4', loc)),
                ),
              ],
              selected: <String>{_paper},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                final next = selection.first;
                if (next != _paper) _fetch(next);
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(
                      key: Key('print-preview-loading'),
                      child: CircularProgressIndicator(),
                    )
                  : _error != null
                  ? Center(
                      key: const Key('print-preview-error'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            key: const Key('print-preview-retry'),
                            onPressed: () => _fetch(_paper),
                            child: Text(AppStrings.t('retry', loc)),
                          ),
                        ],
                      ),
                    )
                  : doc == null
                  ? const SizedBox.shrink()
                  : KeyedSubtree(
                      key: const Key('print-preview-body'),
                      child: ref
                          .read(pdfPreviewProvider)
                          .build(
                            doc.bytes,
                            paper: doc.paper,
                            filename: doc.filename,
                          ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('print-preview-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        TextButton(
          key: const Key('print-save-pdf'),
          onPressed: (doc == null || _saving) ? null : _savePdf,
          child: Text(AppStrings.t('save_pdf', loc)),
        ),
        ElevatedButton(
          key: const Key('print-preview-confirm'),
          onPressed: (doc == null || _loading) ? null : _confirm,
          child: Text(AppStrings.t('print', loc)),
        ),
      ],
    );
  }
}
