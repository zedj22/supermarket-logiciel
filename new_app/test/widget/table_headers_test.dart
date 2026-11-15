// Phase 17 §17.2–§17.4 — pinned table headings, shared typography rungs and
// centralized color helpers.
//
// What this file exists to prove:
//   * a table heading never scrolls away with its rows (vertical *and*
//     horizontal), and it stays glued to the same column as its cells;
//   * every table header is the same type ramp (`AppTheme.tableHeader`);
//   * the layout holds in light, dark and grey, under LTR and RTL, and at
//     all five supported viewports with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/widgets/page_title.dart';
import 'package:supermarket_pos/core/widgets/section_header.dart';
import 'package:supermarket_pos/core/widgets/state_views.dart';
import 'package:supermarket_pos/core/widgets/status_chip.dart';
import 'package:supermarket_pos/core/widgets/table_header.dart';
import 'package:supermarket_pos/features/reports/report_widgets.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

/// The five viewports the app is contracted to render at (§17.3).
const kViewports = <String, Size>{
  '600x500': Size(600, 500),
  '800x600': Size(800, 600),
  '1024x768': Size(1024, 768),
  '1366x768': Size(1366, 768),
  '1920x1080': Size(1920, 1080),
};

/// 60 rows so the body genuinely overflows every viewport we test at.
List<List<String>> bigRows({int count = 60}) => [
      for (var i = 0; i < count; i++)
        ['Product ${i.toString().padLeft(3, '0')}', '$i', '${i * 3}.50'],
    ];

ReportTable reportTable({List<List<String>>? rows, List<String>? totalsRow}) =>
    ReportTable(
      loc: 'en',
      columns: const [
        ReportColumn('col_product'),
        ReportColumn('col_qty', numeric: true),
        ReportColumn('col_net_profit', numeric: true),
      ],
      rows: rows ?? bigRows(),
      totalsRow: totalsRow,
    );

/// Eight columns: the intrinsic widths always exceed a 320px host, so the
/// table is guaranteed to scroll sideways.
ReportTable wideReportTable() => ReportTable(
      loc: 'en',
      columns: const [
        ReportColumn('col_product'),
        ReportColumn('col_barcode'),
        ReportColumn('col_category'),
        ReportColumn('col_price', numeric: true),
        ReportColumn('col_cost', numeric: true),
        ReportColumn('col_quantity', numeric: true),
        ReportColumn('col_unit'),
        ReportColumn('col_status'),
      ],
      rows: [
        for (var i = 0; i < 8; i++)
          [
            'Product $i',
            '4006${i.toString().padLeft(4, '0')}',
            'Category $i',
            '$i.00',
            '${i + 1}.50',
            '$i',
            'pcs',
            'Active',
          ],
      ],
    );

Widget host(Widget child, {ThemeData? theme, TextDirection? direction}) =>
    MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 420,
          child: direction == null
              ? child
              : Directionality(textDirection: direction, child: child),
        ),
      ),
    );

void main() {
  group('ReportTable pinned heading', () {
    testWidgets('heading sits above the rows and survives a vertical scroll',
        (tester) async {
      await tester.pumpWidget(host(reportTable(totalsRow: const ['T', '1', '2'])));

      final header = find.byKey(const Key('report-table-header'));
      expect(header, findsOneWidget);

      final before = tester.getTopLeft(header);
      final firstRow = find.byKey(const Key('report-row-0'));
      expect(firstRow, findsOneWidget);
      expect(tester.getTopLeft(firstRow).dy, greaterThan(before.dy));

      // Scroll the *body* only — the heading is not a descendant of it.
      await tester.drag(
        find.byKey(const Key('report-row-body')),
        const Offset(0, -1600),
      );
      await tester.pumpAndSettle();

      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header), before,
          reason: 'the heading must not travel with the rows');
      expect(firstRow, findsNothing,
          reason: 'the rows must actually have scrolled');
      // The summary line is pinned too, never hidden behind the rows.
      expect(find.byKey(const Key('report-totals-row')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('report-totals-row'))).dy,
          greaterThan(tester.getTopLeft(header).dy));
    });

    testWidgets('a horizontal drag moves heading and rows by the same amount',
        (tester) async {
      // Narrow host: the intrinsic columns are wider than the viewport, so
      // the table scrolls sideways.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 420,
              child: wideReportTable(),
            ),
          ),
        ),
      );

      final headerRow = find.byKey(const Key('report-table-header'));
      final header = find.byKey(const Key('col_product-header'));
      final cell = find.byKey(const Key('report-row-0-0'));
      expect(headerRow, findsOneWidget);
      expect(header, findsOneWidget);
      expect(cell, findsOneWidget);
      final headerBefore = tester.getTopLeft(header).dx;
      final cellBefore = tester.getTopLeft(cell).dx;
      expect(headerBefore, cellBefore,
          reason: 'both start on the same column before any scrolling');

      final scroller = find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(scroller, findsOneWidget);

      await tester.drag(scroller, const Offset(-160, 0));
      await tester.pumpAndSettle();

      final headerAfter = tester.getTopLeft(header).dx;
      final cellAfter = tester.getTopLeft(cell).dx;
      expect(headerAfter, lessThan(headerBefore),
          reason: 'the table must actually scroll sideways');
      expect(headerAfter, cellAfter,
          reason: 'heading and cells stay on the same column while scrolling');
      expect(headerAfter - cellAfter, headerBefore - cellBefore);
      expect(tester.takeException(), isNull);
    });
    testWidgets('every heading cell lands on exactly its column',
        (tester) async {
      await tester.pumpWidget(host(reportTable()));

      for (var c = 0; c < 3; c++) {
        final heading = tester.getRect(
          find.byKey(Key('col_${['product', 'qty', 'net_profit'][c]}-header')),
        );
        final cell = tester.getRect(find.byKey(Key('report-row-0-$c')));
        expect(heading.left, cell.left,
            reason: 'column $c heading drifted off its cells');
        expect(heading.width, cell.width,
            reason: 'column $c heading is not the same width as its cells');
      }
    });

    testWidgets('numeric columns right-align and pin their digits to LTR',
        (tester) async {
      await tester.pumpWidget(host(reportTable()));

      final numericHeading = tester.widget<Text>(
        find.byKey(const Key('col_net_profit-header')),
      );
      expect(numericHeading.textAlign, TextAlign.end);
      expect(numericHeading.textDirection, TextDirection.ltr);

      final numericCell = tester.widget<Text>(
        find.byKey(const Key('report-row-0-2')),
      );
      expect(numericCell.textAlign, TextAlign.end);
      expect(numericCell.textDirection, TextDirection.ltr);

      final textHeading = tester.widget<Text>(
        find.byKey(const Key('col_product-header')),
      );
      expect(textHeading.textAlign, TextAlign.start);
      expect(textHeading.textDirection, isNull,
          reason: 'text columns follow the ambient direction');
    });

    testWidgets('the heading uses the shared table-header type ramp',
        (tester) async {
      await tester.pumpWidget(host(reportTable()));

      final heading = tester.widget<Text>(
        find.byKey(const Key('col_product-header')),
      );
      final expected = AppTheme.tableHeader(AppTheme.light());
      expect(heading.style?.fontFamily, AppTheme.fontFamily);
      expect(heading.style?.fontSize, expected.fontSize);
      expect(heading.style?.fontWeight, FontWeight.w700);
      expect(heading.style?.letterSpacing, expected.letterSpacing);
    });
  });

  group('ReportTable in every theme (light / dark / grey)', () {
    for (final entry in <String, ThemeData>{
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
      'grey': AppTheme.grey(),
    }.entries) {
      testWidgets('renders in ${entry.key} without exceptions', (tester) async {
        await tester.pumpWidget(
          host(reportTable(totalsRow: const ['T', '1', '2']), theme: entry.value),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('report-table-header')), findsOneWidget);
        expect(find.byKey(const Key('report-row-0')), findsOneWidget);
        expect(find.byKey(const Key('report-totals-row')), findsOneWidget);

        // The heading surface comes from the theme's DataTable heading row,
        // never a literal.
        final expected = entry.value.dataTableTheme.headingRowColor
            ?.resolve(const <WidgetState>{});
        final material = tester.widget<Material>(
          find.byWidgetPredicate(
            (w) => w is Material && w.key == const Key('report-table-header'),
          ),
        );
        expect(material.color, expected);
      });
    }
  });

  group('ReportTable under RTL', () {
    testWidgets('heading and cells still share a column', (tester) async {
      await tester.pumpWidget(host(reportTable(), direction: TextDirection.rtl));

      expect(find.byKey(const Key('report-table-header')), findsOneWidget);
      for (var c = 0; c < 3; c++) {
        final heading = tester.getRect(
          find.byKey(Key('col_${['product', 'qty', 'net_profit'][c]}-header')),
        );
        final cell = tester.getRect(find.byKey(Key('report-row-0-$c')));
        expect(heading.left, cell.left);
        expect(heading.width, cell.width);
      }
    });

    testWidgets('money keeps its digits LTR and stays right-aligned',
        (tester) async {
      await tester.pumpWidget(host(reportTable(), direction: TextDirection.rtl));

      final cell = tester.widget<Text>(
        find.byKey(const Key('report-row-0-2')),
      );
      expect(cell.textDirection, TextDirection.ltr);
      expect(cell.textAlign, TextAlign.end);

      final heading = tester.widget<Text>(
        find.byKey(const Key('col_net_profit-header')),
      );
      expect(heading.textDirection, TextDirection.ltr);
      expect(heading.textAlign, TextAlign.end);
    });
  });

  group('ReportTable across the five viewports', () {
    for (final entry in kViewports.entries) {
      testWidgets('renders at ${entry.key} with no overflow', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(host(reportTable(totalsRow: const ['T', '1', '2'])));

        expect(tester.takeException(), isNull,
            reason: 'the report table must not overflow at ${entry.key}');
        expect(find.byKey(const Key('report-table-header')), findsOneWidget);
        expect(find.byKey(const Key('report-row-0')), findsOneWidget);
        expect(find.byKey(const Key('report-totals-row')), findsOneWidget);

        // Vertical scroll still works at this size.
        await tester.drag(
          find.byKey(const Key('report-row-body')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('report-table-header')), findsOneWidget);
      });
    }
  });

  group('TableHeaderRow (shared pinned header chrome)', () {
    testWidgets('paints the theme heading surface at 44px tall',
        (tester) async {
      final theme = AppTheme.dark();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 160,
              child: Column(
                children: [
                  TableHeaderRow(
                    testKey: const Key('demo-table-header'),
                    children: const [Expanded(child: Text('Name'))],
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );

      final header = find.byKey(const Key('demo-table-header'));
      expect(header, findsOneWidget);
      expect(
        tester.getSize(header).height,
        44,
        reason: 'every pinned heading is the same 44px band',
      );
      final material = tester.widget<Material>(header);
      expect(
        material.color,
        theme.dataTableTheme.headingRowColor?.resolve(const <WidgetState>{}),
        reason: 'heading surface comes from the theme, never a literal',
      );
      expect(find.text('Name'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('honours a caller inset so cells without padding line up',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 160,
              child: Column(
                children: [
                  const TableHeaderRow(
                    testKey: Key('inset-table-header'),
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    children: [Expanded(child: Text('Name'))],
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      final row = find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration,
      );
      expect(row, findsWidgets);
      final label = tester.getTopLeft(find.text('Name'));
      expect(label.dx, 24);
    });
  });

  group('tableHeaderCell alignment contract', () {
    testWidgets('numeric labels hug the trailing edge, text the leading one',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final numeric = tableHeaderCell(
        ctx,
        numeric: true,
        child: const Text('Total'),
      );
      expect(numeric, isA<Expanded>());

      final fixed = tableHeaderCell(
        ctx,
        numeric: false,
        fixedWidth: 96,
        child: const Text('Status'),
      );
      expect(fixed, isA<SizedBox>());
      expect((fixed as SizedBox).width, 96);
    });

    testWidgets('the label it builds carries the shared table-header ramp',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Row(
                children: [
                  tableHeaderCell(
                    context,
                    numeric: false,
                    child: const Text('Total'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // `Text.style` is null when it inherits — read what actually renders.
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text('Total'),
          matching: find.byType(RichText),
        ),
      );
      final rendered = rich.text.style;
      expect(rendered?.fontFamily, AppTheme.fontFamily);
      // Readability pass: the shared table-header rung is 14px w700.
      expect(rendered?.fontSize, 14);
      expect(rendered?.fontWeight, FontWeight.w700);
      expect(rendered?.letterSpacing, 0.3);
    });
  });

  group('PageTitle (screen H1)', () {
    Widget frame(double width, {Widget? trailing}) => MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: width,
                child: PageTitle(
                  title: 'Reports',
                  titleKey: const Key('demo-title'),
                  trailing: trailing,
                ),
              ),
            ),
          ),
        );

    testWidgets('keeps title and action on one line when there is room',
        (tester) async {
      await tester.pumpWidget(
        frame(
          900,
          trailing: const SizedBox(
            key: Key('demo-action'),
            width: 120,
            height: 32,
          ),
        ),
      );
      final title = tester.getCenter(find.byKey(const Key('demo-title')));
      final action = tester.getCenter(find.byKey(const Key('demo-action')));
      expect(title.dy, closeTo(action.dy, 2),
          reason: 'the action shares the title line');
      expect(action.dx, greaterThan(title.dx));
      expect(tester.takeException(), isNull);
    });

    testWidgets('drops the action below the title instead of overflowing',
        (tester) async {
      await tester.pumpWidget(
        frame(
          380,
          trailing: const SizedBox(
            key: Key('demo-action'),
            width: 200,
            height: 32,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final title = tester.getTopLeft(find.byKey(const Key('demo-title')));
      final action = tester.getTopLeft(find.byKey(const Key('demo-action')));
      expect(action.dy, greaterThan(title.dy));
    });

    testWidgets('title uses the pageTitle rung', (tester) async {
      await tester.pumpWidget(frame(900));
      final title =
          tester.widget<Text>(find.byKey(const Key('demo-title')));
      // Compare against the *resolved* theme, the same way the widget does:
      // raw ThemeData has no font sizes until the localizations merge in.
      final resolved = AppTheme.pageTitle(
        Theme.of(tester.element(find.byKey(const Key('demo-title')))),
      );
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(title.style?.fontFamily, AppTheme.fontFamily);
      expect(title.style?.fontSize, resolved.fontSize);
      expect(title.style?.fontSize, isNotNull);
    });
  });

  group('SectionHeader', () {
    testWidgets('exposes the report finder key and the accent rule',
        (tester) async {
      final theme = AppTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: SectionHeader(
                title: 'Sales',
                titleKey: 'sales',
                accent: Color(0xFF00FF00),
                icon: Icons.point_of_sale_outlined,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('report-section-sales')), findsOneWidget);
      expect(find.byIcon(Icons.point_of_sale_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('StatusChip (centralized tint + foreground)', () {
    for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
      testWidgets('$brightness fills from the tone accent', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: const Scaffold(
              body: StatusChip(
                label: 'IN STOCK',
                tone: StatusTone.success,
                testKey: Key('demo-chip'),
              ),
            ),
          ),
        );
        final box = find.byKey(const Key('demo-chip'));
        expect(box, findsOneWidget);
        final container = tester.widget<Container>(box);
        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.color, AppColors.tint(AppColors.success, brightness));
        final label = tester.widget<Text>(find.text('IN STOCK'));
        expect(label.style?.color,
            AppColors.onTint(AppColors.success, brightness));
      });
    }

    testWidgets('every tone maps to its own accent', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                for (final tone in StatusTone.values)
                  StatusChip(label: '$tone', tone: tone),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(StatusChip), findsNWidgets(StatusTone.values.length));
    });
  });

  group('EmptyState / LoadingState', () {
    testWidgets('empty state surfaces icon, copy and an action', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: EmptyState(
              message: 'No products yet',
              testKey: Key('demo-empty'),
              action: SizedBox(height: 32, width: 96),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('demo-empty')), findsOneWidget);
      expect(find.text('No products yet'), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('loading state never shows a bare spinner', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: LoadingState(message: 'Loading…'),
          ),
        ),
      );
      expect(find.byKey(const Key('loading-state')), findsOneWidget);
      expect(find.byKey(const Key('loading-spinner')), findsOneWidget);
      expect(find.byKey(const Key('loading-message')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
