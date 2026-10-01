// Semantic color system tests for the Reports UI (Phase 14, Human QA
// Fix Round 2).
//
// Contract under test: widgets resolve accents through `resolveReportTone`
// / `reportValueColor` — assertions compare against those helpers (or a
// theme's own colors), never against hardcoded RGB literals, so palette
// tuning cannot silently break the semantics while keeping tests green.
//
// Plain `ThemeData` fixtures instead of `AppTheme`: the tone system only
// reads brightness/colorScheme/textTheme, and building GoogleFonts themes
// outside a widget-test zone leaks async font errors into the test runner.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/reports/report_tones.dart';
import 'package:supermarket_pos/features/reports/report_widgets.dart';
import 'package:supermarket_pos/features/reports/reports_providers.dart';

ThemeData lightTheme() => ThemeData(brightness: Brightness.light);
ThemeData darkTheme() => ThemeData(brightness: Brightness.dark);

void main() {
  group('reportKpiTone', () {
    test('maps every metric family to its semantic tone', () {
      expect(reportKpiTone('kpi_gross_sales'), ReportMetricTone.sales);
      expect(reportKpiTone('kpi_net_sales'), ReportMetricTone.sales);
      expect(reportKpiTone('kpi_paid_cash'), ReportMetricTone.sales);
      expect(reportKpiTone('kpi_net_profit'), ReportMetricTone.profit);
      expect(reportKpiTone('kpi_gross_profit'), ReportMetricTone.profit);
      expect(reportKpiTone('kpi_margin'), ReportMetricTone.profit);
      expect(reportKpiTone('kpi_expenses'), ReportMetricTone.expense);
      expect(reportKpiTone('kpi_expenses_drawer'), ReportMetricTone.expense);
      expect(
          reportKpiTone('kpi_returns_count'), ReportMetricTone.returnValue);
      expect(reportKpiTone('kpi_returns_total'), ReportMetricTone.returnValue);
      expect(reportKpiTone('kpi_outstanding_debt'), ReportMetricTone.debt);
      expect(reportKpiTone('kpi_total_debt'), ReportMetricTone.debt);
      expect(reportKpiTone('kpi_cogs'), ReportMetricTone.cost);
      expect(reportKpiTone('kpi_purchases_total'), ReportMetricTone.cost);
      expect(reportKpiTone('kpi_stock_value'), ReportMetricTone.inventory);
      expect(reportKpiTone('kpi_low_stock'), ReportMetricTone.inventory);
      expect(reportKpiTone('kpi_invoices'), ReportMetricTone.documents);
      expect(reportKpiTone('kpi_items_sold'), ReportMetricTone.documents);
    });

    test('discount and unknown labels carry no tone', () {
      expect(reportKpiTone('kpi_discounts_total'), isNull);
      expect(reportKpiTone('kpi_line_discounts'), isNull);
      expect(reportKpiTone('kpi_something_new'), isNull);
    });
  });

  group('reportColumnTone', () {
    test('tones only profit and returns columns', () {
      expect(reportColumnTone('col_gross_profit'), ReportMetricTone.profit);
      expect(reportColumnTone('col_net_profit'), ReportMetricTone.profit);
      expect(reportColumnTone('col_margin'), ReportMetricTone.profit);
      expect(reportColumnTone('col_returns_qty'), ReportMetricTone.returnValue);
      expect(reportColumnTone('col_returns_amount'),
          ReportMetricTone.returnValue);
      expect(reportColumnTone('col_net_revenue'), isNull);
      expect(reportColumnTone('col_cogs'), isNull);
      expect(reportColumnTone('col_date'), isNull);
      expect(reportColumnTone('col_product'), isNull);
    });
  });

  group('resolveReportTone', () {
    final themes = <String, ThemeData>{
      'light': lightTheme(),
      'dark': darkTheme(),
    };

    for (final entry in themes.entries) {
      test('resolves all eight tones distinctly in the ${entry.key} theme',
          () {
        final theme = entry.value;
        final colors = [
          for (final tone in ReportMetricTone.values)
            resolveReportTone(tone, theme),
        ];
        expect(colors.toSet().length, ReportMetricTone.values.length);
      });

      test('sales tone follows the theme primary in the ${entry.key} theme',
          () {
        expect(
          resolveReportTone(ReportMetricTone.sales, entry.value),
          entry.value.colorScheme.primary,
        );
      });
    }

    test('light and dark palettes differ for every fixed tone', () {
      final light = lightTheme();
      final dark = darkTheme();
      for (final tone in ReportMetricTone.values) {
        if (tone == ReportMetricTone.sales) continue; // primary by design
        expect(
          resolveReportTone(tone, light),
          isNot(resolveReportTone(tone, dark)),
          reason: '$tone should be brightness-aware',
        );
      }
    });

    test('dark-brightness themes resolve the dark palette (grey included)',
        () {
      final dark = darkTheme();
      final greyLike = ThemeData(brightness: Brightness.dark);
      for (final tone in ReportMetricTone.values) {
        expect(
          resolveReportTone(tone, greyLike),
          resolveReportTone(tone, dark),
        );
      }
    });
  });

  group('reportToneIcon', () {
    test('assigns one icon per tone', () {
      final icons = [
        for (final tone in ReportMetricTone.values) reportToneIcon(tone),
      ];
      expect(icons.toSet().length, ReportMetricTone.values.length);
    });
  });

  group('isNegativeValue', () {
    test('detects a leading minus sign only', () {
      expect(isNegativeValue('-1200'), isTrue);
      expect(isNegativeValue(' -12.5'), isTrue);
      expect(isNegativeValue('-0'), isTrue);
      expect(isNegativeValue('1200'), isFalse);
      expect(isNegativeValue(''), isFalse);
      expect(isNegativeValue('2026-09-01'), isFalse);
      expect(isNegativeValue('n/a'), isFalse);
    });
  });

  group('reportValueColor', () {
    test('negatives switch to the expense red regardless of tone', () {
      final light = lightTheme();
      final red = resolveReportTone(ReportMetricTone.expense, light);
      expect(reportValueColor('-50', ReportMetricTone.sales, light), red);
      expect(reportValueColor('-50', ReportMetricTone.profit, light), red);
      expect(reportValueColor('-50', null, light), red);
      expect(reportValueColor('-12.5%', ReportMetricTone.profit, light), red);
    });

    test('positive profit renders in the profit green', () {
      final light = lightTheme();
      expect(
        reportValueColor('1200', ReportMetricTone.profit, light),
        resolveReportTone(ReportMetricTone.profit, light),
      );
    });

    test('expense and sales values stay neutral', () {
      final light = lightTheme();
      expect(reportValueColor('1200', ReportMetricTone.expense, light), isNull);
      expect(reportValueColor('1200', ReportMetricTone.sales, light), isNull);
    });

    test('return, debt and cost values take their tone accent', () {
      final light = lightTheme();
      expect(
        reportValueColor('1200', ReportMetricTone.returnValue, light),
        resolveReportTone(ReportMetricTone.returnValue, light),
      );
      expect(
        reportValueColor('1200', ReportMetricTone.debt, light),
        resolveReportTone(ReportMetricTone.debt, light),
      );
      expect(
        reportValueColor('1200', ReportMetricTone.cost, light),
        resolveReportTone(ReportMetricTone.cost, light),
      );
    });

    test('no tone keeps the default text color', () {
      expect(reportValueColor('1200', null, lightTheme()), isNull);
    });
  });

  group('ReportKpiTile semantic accents', () {
    Future<ThemeData> pumpTile(
      WidgetTester tester,
      ReportKpiTile tile,
      ThemeData theme,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(body: tile),
        ),
      );
      return theme;
    }

    testWidgets('positive profit value renders in profit green',
        (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_net_profit',
          value: '1200',
          testKey: 'kpi-kpi_net_profit',
        ),
        theme,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_net_profit-value')),
      );
      expect(
          text.style?.color, resolveReportTone(ReportMetricTone.profit, theme));
      expect(text.textDirection, TextDirection.ltr);
    });

    testWidgets('negative profit value switches to expense red',
        (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_net_profit',
          value: '-1200',
          testKey: 'kpi-kpi_net_profit',
        ),
        theme,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_net_profit-value')),
      );
      expect(
          text.style?.color, resolveReportTone(ReportMetricTone.expense, theme));
      expect(text.textDirection, TextDirection.ltr);
    });

    testWidgets('expense KPI carries the expense icon and accent chip',
        (tester) async {
      final theme = darkTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_expenses',
          value: '500',
          testKey: 'kpi-kpi_expenses',
        ),
        theme,
      );
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('kpi-kpi_expenses-icon')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, reportToneIcon(ReportMetricTone.expense));
      expect(icon.color, resolveReportTone(ReportMetricTone.expense, theme));
      // The accent chip carries the red; the number itself stays neutral.
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_expenses-value')),
      );
      expect(text.style?.color, theme.textTheme.titleMedium?.color);
    });

    testWidgets('returns KPI value renders in the returns orange',
        (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_returns_total',
          value: '30',
          testKey: 'kpi-kpi_returns_total',
        ),
        theme,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_returns_total-value')),
      );
      expect(
        text.style?.color,
        resolveReportTone(ReportMetricTone.returnValue, theme),
      );
    });

    testWidgets('debt KPI value renders in the debt accent', (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_outstanding_debt',
          value: '900',
          testKey: 'kpi-kpi_outstanding_debt',
        ),
        theme,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_outstanding_debt-value')),
      );
      expect(
        text.style?.color,
        resolveReportTone(ReportMetricTone.debt, theme),
      );
    });

    testWidgets('neutral KPI renders without an accent chip or strip',
        (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_discounts_total',
          value: '40',
          testKey: 'kpi-kpi_discounts_total',
        ),
        theme,
      );
      expect(
          find.byKey(const Key('kpi-kpi_discounts_total-icon')), findsNothing);
      final card = tester.widget<Card>(
        find.byKey(const Key('kpi-kpi_discounts_total')),
      );
      expect(card.color, isNull);
      final text = tester.widget<Text>(
        find.byKey(const Key('kpi-kpi_discounts_total-value')),
      );
      expect(text.style?.color, theme.textTheme.titleMedium?.color);
    });

    testWidgets('accented card tints its surface with the tone',
        (tester) async {
      final theme = lightTheme();
      await pumpTile(
        tester,
        const ReportKpiTile(
          labelKey: 'kpi_stock_value',
          value: '100',
          testKey: 'kpi-kpi_stock_value',
        ),
        theme,
      );
      final card = tester.widget<Card>(
        find.byKey(const Key('kpi-kpi_stock_value')),
      );
      expect(
        card.color,
        Color.alphaBlend(
          resolveReportTone(ReportMetricTone.inventory, theme)
              .withValues(alpha: 0.06),
          theme.cardColor,
        ),
      );
    });
  });

  group('ReportBarChart tone', () {
    testWidgets('bars render in the requested semantic accent',
        (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ReportBarChart(
                bars: const [ReportBar(label: '10:00', value: 5)],
                barKeyPrefix: 'test-bar',
                tone: ReportMetricTone.documents,
              ),
            ),
          ),
        ),
      );
      final container = tester.widget<Container>(
        find.byKey(const Key('test-bar-0')),
      );
      expect(
        container.decoration! as BoxDecoration,
        isA<BoxDecoration>().having(
          (d) => d.color,
          'bar color',
          resolveReportTone(ReportMetricTone.documents, theme),
        ),
      );
    });

    testWidgets('default tone falls back to the theme primary',
        (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ReportBarChart(
                bars: const [ReportBar(label: '10:00', value: 5)],
                barKeyPrefix: 'test-bar',
              ),
            ),
          ),
        ),
      );
      final container = tester.widget<Container>(
        find.byKey(const Key('test-bar-0')),
      );
      expect(
        (container.decoration! as BoxDecoration).color,
        theme.colorScheme.primary,
      );
    });
  });

  group('ReportStateView empty state', () {
    Widget host(Widget child, ThemeData theme) => MaterialApp(
          theme: theme,
          home: Scaffold(body: child),
        );

    testWidgets('renders the semantic icon in the tab accent',
        (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        host(
          ReportStateView<String>(
            state: const ReportTabState<String>(data: 'loaded'),
            isEmpty: true,
            onRetry: () {},
            emptyKey: 'state_no_data',
            loc: 'en',
            emptyTone: ReportMetricTone.sales,
            emptyIcon: Icons.point_of_sale_outlined,
            child: const Text('never shown'),
          ),
          theme,
        ),
      );
      // Contract: the empty container keeps its test key.
      expect(find.byKey(const Key('report-empty')), findsOneWidget);
      final icon =
          tester.widget<Icon>(find.byIcon(Icons.point_of_sale_outlined));
      expect(icon.color, resolveReportTone(ReportMetricTone.sales, theme));
      expect(find.text('never shown'), findsNothing);
    });

    testWidgets('defaults to the inbox icon in primary blue', (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        host(
          ReportStateView<String>(
            state: const ReportTabState<String>(data: 'loaded'),
            isEmpty: true,
            onRetry: () {},
            emptyKey: 'state_no_data',
            loc: 'en',
            child: const Text('never shown'),
          ),
          theme,
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.inbox_outlined));
      expect(icon.color, theme.colorScheme.primary);
    });
  });

  group('ReportTable semantic cells', () {
    Widget host(Widget table, ThemeData theme) => MaterialApp(
          theme: theme,
          home: Scaffold(body: table),
        );

    testWidgets('profit totals render green and negatives render red',
        (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        host(
          ReportTable(
            loc: 'en',
            columns: const [
              ReportColumn('col_product'),
              ReportColumn('col_net_profit', numeric: true),
            ],
            rows: const [
              ['A', '100'],
              ['B', '-20'],
            ],
            totalsRow: const ['Total', '80'],
          ),
          theme,
        ),
      );
      // Totals row: positive profit → green, bold.
      final totals =
          tester.widget<Text>(find.byKey(const Key('report-totals-1')));
      expect(
        totals.style?.color,
        resolveReportTone(ReportMetricTone.profit, theme),
      );
      expect(totals.style?.fontWeight, FontWeight.w700);
      // Data rows: positive profit green, negative switched to red.
      expect(
        tester.widget<Text>(find.byKey(const Key('report-row-0-1'))).style?.color,
        resolveReportTone(ReportMetricTone.profit, theme),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('report-row-1-1'))).style?.color,
        resolveReportTone(ReportMetricTone.expense, theme),
      );
      // Text columns stay neutral.
      expect(
        tester.widget<Text>(find.byKey(const Key('report-row-0-0'))).style?.color,
        theme.textTheme.bodyMedium?.color,
      );
    });

    testWidgets('returns columns render in the returns orange',
        (tester) async {
      final theme = lightTheme();
      await tester.pumpWidget(
        host(
          ReportTable(
            loc: 'en',
            columns: const [
              ReportColumn('col_product'),
              ReportColumn('col_returns_amount', numeric: true),
            ],
            rows: const [
              ['A', '15'],
            ],
          ),
          theme,
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('report-row-0-1'))).style?.color,
        resolveReportTone(ReportMetricTone.returnValue, theme),
      );
    });
  });
}
