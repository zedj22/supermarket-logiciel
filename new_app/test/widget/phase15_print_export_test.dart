// Phase 15 (§19.2) — print preview dialog + export dialog unit/widget tests.
//
// Harness: a minimal ProviderScope + MaterialApp with a launcher widget —
// no router/login flow. Dio is mocked per test so each test controls the
// `POST /print` / `POST /exports` outcome (success, typed envelope error,
// delayed response). The preview seam is faked (no rasterizer/plugin) and
// `FilePicker.platform` is replaced with an in-memory fake for the
// save-PDF / save-export paths.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/print_preview_dialog.dart';
import 'package:supermarket_pos/features/pos/print_service.dart';
import 'package:supermarket_pos/features/reports/report_export.dart';
import 'package:supermarket_pos/features/reports/report_export_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Returns the response, or THROWS to simulate an error.
typedef PostHandler = Response<dynamic> Function(
  String path,
  Map<String, dynamic> data,
);

MockDio _buildDio(PostHandler handler) {
  final dio = MockDio();
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  // Production calls `post<Uint8List>` (byte endpoints) — mocktail matches
  // the generic type argument strictly, so the stubs must declare it too.
  Future<Response<Uint8List>> answer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final raw = invocation.namedArguments[#data];
    final out = handler(
      path,
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
    );
    if (out is DioException) throw out;
    final response = out;
    return Response<Uint8List>(
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      data: response.data is Uint8List ? response.data as Uint8List : null,
      headers: response.headers,
    );
  }

  when(() => dio.post<Uint8List>(any(), data: any(named: 'data')))
      .thenAnswer(answer);
  when(
    () => dio.post<Uint8List>(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(answer);
  return dio;
}

Response<dynamic> _bytes(String path, List<int> bytes, String filename) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: Uint8List.fromList(bytes),
      headers: Headers.fromMap(<String, List<String>>{
        'content-disposition': <String>['attachment; filename="$filename"'],
      }),
    );

DioException _envelope(
  int status,
  String code, {
  String path = '/api/v1/print',
}) =>
    DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: status,
        data: <String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': 'raw backend'},
        },
      ),
    );

class _FakePdfPreview implements PdfPreviewBuilder {
  final List<Uint8List> received = <Uint8List>[];
  final List<String> papers = <String>[];

  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  }) {
    received.add(bytes);
    papers.add(paper);
    return Text('preview:${bytes.length}:$paper:$filename');
  }
}

class _FakePrintService implements PrintService {
  final List<Uint8List> printedPdfs = <Uint8List>[];
  final List<String> printedPapers = <String>[];

  @override
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) async {
    printedPdfs.add(bytes);
    printedPapers.add(paper);
  }

  @override
  Future<void> printText(String text) async {}
}

class _FakeFilePicker extends FilePicker {
  String? savedPath;
  String? lastTitle;
  String? lastFileName;
  Uint8List? lastBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    lastTitle = dialogTitle;
    lastFileName = fileName;
    lastBytes = bytes;
    return savedPath;
  }
}

/// Launcher: three buttons whose completions render as `Key('result')`.
class _Launcher extends ConsumerStatefulWidget {
  const _Launcher({required this.dio});

  final Dio dio;

  @override
  ConsumerState<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends ConsumerState<_Launcher> {
  String _result = 'idle';

  Future<void> _openPrint() async {
    final result = await showPrintPreviewDialog(
      context,
      documentType: 'sale',
      documentId: '11111111-1111-1111-1111-111111111111',
      deviceId: 'POS-1',
    );
    if (!mounted) return;
    setState(() => _result = result == null
        ? 'cancelled'
        : 'confirmed|${result.paper}|${result.filename}|'
            '${result.bytes.length}');
  }

  Future<void> _openFormat() async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final format = await showReportExportDialog(context, loc);
    if (!mounted) return;
    setState(() => _result = format ?? 'cancelled');
  }

  Future<void> _runExport(String format) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final ok = await exportReportFile(
      context: context,
      dio: widget.dio,
      loc: loc,
      reportSlug: 'financial',
      format: format,
      body: const <String, dynamic>{'date_from': '2026-10-01'},
      deviceId: 'POS-1',
    );
    if (!mounted) return;
    setState(() => _result = 'export:$ok');
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            key: const Key('open-print'),
            onPressed: _openPrint,
            child: Text(AppStrings.t('print', loc)),
          ),
          ElevatedButton(
            key: const Key('open-format'),
            onPressed: _openFormat,
            child: const Text('export'),
          ),
          ElevatedButton(
            key: const Key('run-xlsx'),
            onPressed: () => _runExport('xlsx'),
            child: const Text('xlsx'),
          ),
          Text(_result, key: const Key('result')),
        ],
      ),
    );
  }
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required MockDio dio,
  AppLocale locale = AppLocale.en,
  _FakePdfPreview? preview,
  _FakePrintService? printer,
  TextDirection direction = TextDirection.ltr,
}) async {
  final fakePreview = preview ?? _FakePdfPreview();
  await tester.pumpWidget(
    ProviderScope(
      // Keyed by locale: Riverpod does not re-apply override VALUE changes
      // on an existing ProviderScope element, so switching locale inside a
      // test must recreate the scope (and its container).
      key: ValueKey<String>('scope-${locale.name}'),
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        pdfPreviewProvider.overrideWithValue(fakePreview),
        printServiceProvider.overrideWithValue(printer ?? _FakePrintService()),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Directionality(
          textDirection: direction,
          child: _Launcher(dio: dio),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Print preview dialog (§6.2 E)', () {
    testWidgets('confirm returns the fetched bytes + paper + filename',
        (tester) async {
      final dio = _buildDio((path, data) {
        expect(path, '/api/v1/print');
        expect(data['document_type'], 'sale');
        expect(data['paper'], '80mm');
        expect(data['locale'], 'en');
        expect(data['device_id'], 'POS-1');
        return _bytes(path, <int>[37, 80, 68, 70], 'sale_receipt.pdf');
      });
      await _pumpHarness(tester, dio: dio);

      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      expect(
        find.textContaining('sale_receipt.pdf'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('print-preview-confirm')), findsOneWidget);

      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'confirmed|80mm|sale_receipt.pdf|4',
      );
    });

    testWidgets('cancel returns null — no result, no toast', (tester) async {
      final dio = _buildDio(
        (path, data) => _bytes(path, <int>[1, 2, 3], 'x.pdf'),
      );
      await _pumpHarness(tester, dio: dio);

      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('print-preview-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-dialog')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'cancelled',
      );
      expect(find.textContaining(AppStrings.t('print_failed', 'en')),
          findsNothing);
    });

    testWidgets('typed render failure → localized message + retry recovers',
        (tester) async {
      var calls = 0;
      final dio = _buildDio((path, data) {
        calls++;
        if (calls == 1) throw _envelope(500, 'PRINT_RENDER_FAILED');
        return _bytes(path, <int>[9, 9], 'sale_receipt.pdf');
      });
      await _pumpHarness(tester, dio: dio);

      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('print-preview-error')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('print_render_failed', 'en')),
        findsOneWidget,
      );
      // Confirm stays disabled while there is no document.
      expect(
        tester
            .widget<ElevatedButton>(
              find.byKey(const Key('print-preview-confirm')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('print-preview-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print-preview-body')), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('MISSING_FONT and VALIDATION_ERROR keep their identity',
        (tester) async {
      final dio = _buildDio((path, data) {
        throw _envelope(500, 'MISSING_FONT');
      });
      await _pumpHarness(tester, dio: dio);
      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.t('missing_font', 'en')), findsOneWidget);
      await tester.tap(find.byKey(const Key('print-preview-cancel')));
      await tester.pumpAndSettle();

      final dio2 = _buildDio((path, data) {
        throw _envelope(422, 'VALIDATION_ERROR');
      });
      await _pumpHarness(tester, dio: dio2, locale: AppLocale.fr);
      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.t('validation_error', 'fr')), findsOneWidget);
    });

    testWidgets('Arabic RTL smoke: dialog renders without exceptions',
        (tester) async {
      final dio = _buildDio(
        (path, data) => _bytes(path, <int>[1], 'sale_receipt.pdf'),
      );
      await _pumpHarness(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );

      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('print_dialog_title', 'ar')),
          findsOneWidget);
      expect(find.text(AppStrings.t('paper_80mm', 'ar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Save PDF: server filename prefills; success toast',
        (tester) async {
      final dio = _buildDio(
        (path, data) => _bytes(path, <int>[7, 7, 7], 'sale_receipt.pdf'),
      );
      final picker = _FakeFilePicker()..savedPath = 'C:/tmp/out.pdf';
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      await _pumpHarness(tester, dio: dio);
      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('print-save-pdf')));
      await tester.pumpAndSettle();

      expect(picker.lastFileName, 'sale_receipt.pdf');
      expect(picker.lastTitle, AppStrings.t('save_pdf', 'en'));
      expect(picker.lastBytes, isNotEmpty);
      expect(find.byKey(const Key('print-save-pdf-toast')), findsOneWidget);
      expect(find.textContaining(AppStrings.t('pdf_saved', 'en')),
          findsOneWidget);
      // Saving does not close the preview.
      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
    });

    testWidgets('Save PDF cancelled by user → neutral, no toast',
        (tester) async {
      final dio = _buildDio(
        (path, data) => _bytes(path, <int>[7], 'sale_receipt.pdf'),
      );
      final picker = _FakeFilePicker()..savedPath = null;
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      await _pumpHarness(tester, dio: dio);
      await tester.tap(find.byKey(const Key('open-print')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('print-save-pdf')));
      await tester.pumpAndSettle();

      expect(picker.lastFileName, 'sale_receipt.pdf');
      expect(find.byKey(const Key('print-save-pdf-toast')), findsNothing);
    });
  });

  group('Export format dialog (§19.2)', () {
    testWidgets('offers CSV / XLSX / PDF and returns the choice',
        (tester) async {
      final dio = _buildDio((path, data) => _bytes(path, <int>[1], 'x.xlsx'));
      await _pumpHarness(tester, dio: dio);

      await tester.tap(find.byKey(const Key('open-format')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('export-format-dialog')), findsOneWidget);
      expect(find.byKey(const Key('export-format-csv')), findsOneWidget);
      expect(find.byKey(const Key('export-format-xlsx')), findsOneWidget);
      expect(find.byKey(const Key('export-format-pdf')), findsOneWidget);
      expect(
        find.text(AppStrings.t('export_title', 'en')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('export-format-xlsx')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'xlsx',
      );
    });

    testWidgets('cancel returns null (neutral)', (tester) async {
      final dio = _buildDio((path, data) => _bytes(path, <int>[1], 'x.xlsx'));
      await _pumpHarness(tester, dio: dio);

      await tester.tap(find.byKey(const Key('open-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-format-cancel')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'cancelled',
      );
      expect(find.byKey(const Key('reports-export-toast')), findsNothing);
    });
  });

  group('exportReportFile (§12.1)', () {
    testWidgets('POSTs ExportRequest + prefills server filename + toast',
        (tester) async {
      late Map<String, dynamic> sent;
      final dio = _buildDio((path, data) {
        expect(path, '/api/v1/exports');
        sent = data;
        return _bytes(path, <int>[0, 1, 2], 'financial_2026-10-01_2026-10-02.xlsx');
      });
      final picker = _FakeFilePicker()..savedPath = 'C:/tmp/report.xlsx';
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      await _pumpHarness(tester, dio: dio);
      await tester.tap(find.byKey(const Key('run-xlsx')));
      await tester.pumpAndSettle();

      expect(sent['report'], 'financial');
      expect(sent['format'], 'xlsx');
      expect(sent['locale'], 'en');
      expect(sent['date_from'], '2026-10-01');
      expect(picker.lastFileName, 'financial_2026-10-01_2026-10-02.xlsx');
      expect(picker.lastTitle, AppStrings.t('export_xlsx', 'en'));
      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'export:true',
      );
      expect(find.byKey(const Key('reports-export-toast')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('export_done', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('EXPORT_FORMAT_UNSUPPORTED → localized toast, no save',
        (tester) async {
      final dio = _buildDio((path, data) {
        throw _envelope(422, 'EXPORT_FORMAT_UNSUPPORTED', path: path);
      });
      final picker = _FakeFilePicker()..savedPath = 'C:/tmp/report.xlsx';
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());

      await _pumpHarness(tester, dio: dio, locale: AppLocale.ar);
      await tester.tap(find.byKey(const Key('run-xlsx')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-export-toast')), findsOneWidget);
      expect(
        find.text(AppStrings.t('export_format_unsupported', 'ar')),
        findsOneWidget,
      );
      expect(picker.lastFileName, isNull); // save never opened
      expect(
        tester.widget<Text>(find.byKey(const Key('result'))).data,
        'export:false',
      );
    });

    testWidgets('EXPORT_TOO_LARGE (413) keeps its identity', (tester) async {
      final dio = _buildDio((path, data) {
        throw _envelope(413, 'EXPORT_TOO_LARGE', path: path);
      });
      await _pumpHarness(tester, dio: dio, locale: AppLocale.fr);
      await tester.tap(find.byKey(const Key('run-xlsx')));
      await tester.pumpAndSettle();

      expect(
        find.text(AppStrings.t('export_too_large', 'fr')),
        findsOneWidget,
      );
    });
  });
}
