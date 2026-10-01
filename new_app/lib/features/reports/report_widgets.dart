// Shared building blocks for the Phase 14 report screens (§9/§10).
//
// No money math anywhere: every cell is a raw server string run through
// `formatMoney` (trailing-zero trim only) or a date label (§8 note: no
// screen may compute money). Charts are plain Flutter widgets per G24 —
// bar heights are display-only ratios of already-computed values.
import 'package:flutter/material.dart';

import '../../core/strings.dart';
import 'report_tones.dart';
import 'reports_providers.dart';

/// `2026-09-01T14:30:00Z` → `2026-09-01 16:30` (local, minute precision);
/// returns the raw value when it is not parseable.
String reportDateTimeLabel(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  return parsed.toLocal().toString().substring(0, 16);
}

/// `2026-09-01T13:00:00Z` → `2026-09-01 15:00` (local hour bucket).
String reportHourLabel(String iso) => reportDateTimeLabel(iso);

/// Peak-hour index (0–23) → `00:00` … `23:00`.
String reportPeakHourLabel(int hour) =>
    '${hour.toString().padLeft(2, '0')}:00';

// ---------------------------------------------------------------------------
// Loading / error / empty states (§17.2)
// ---------------------------------------------------------------------------

/// Wraps one tab body: spinner while nothing is loaded, localized error +
/// retry, empty message, otherwise the content.
class ReportStateView<T> extends StatelessWidget {
  const ReportStateView({
    super.key,
    required this.state,
    required this.isEmpty,
    required this.onRetry,
    required this.emptyKey,
    required this.loc,
    required this.child,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyTone,
  });

  final ReportTabState<T> state;
  final bool isEmpty;
  final VoidCallback onRetry;

  /// Localization key shown when data loaded but has no rows.
  final String emptyKey;
  final String loc;
  final Widget child;

  /// Muted illustration for the empty state (semantic, not decorative).
  final IconData emptyIcon;

  /// Semantic accent of the tab the empty state belongs to (`null` →
  /// primary blue). Drives the icon + tinted circle only.
  final ReportMetricTone? emptyTone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Nothing loaded yet (first frame or in-flight first load): show the
    // localized loading state — never a "no data" flash before the
    // initState-triggered request lands (§17.2 loading state).
    if (state.data == null && state.error == null) {
      return Center(
        key: const Key('report-loading'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(key: Key('report-spinner')),
            const SizedBox(height: 12),
            Text(AppStrings.t('state_loading', loc)),
          ],
        ),
      );
    }
    if (state.data == null) {
      return Center(
        key: const Key('report-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!, key: const Key('report-error-message')),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('report-retry'),
              onPressed: onRetry,
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (isEmpty && state.error == null) {
      // Empty ≠ broken: a semantic icon in a subtle tinted circle plus
      // muted copy, instead of a bare line of text.
      final accent = emptyTone == null
          ? theme.colorScheme.primary
          : resolveReportTone(emptyTone!, theme);
      return Center(
        key: const Key('report-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(emptyIcon, size: 28, color: accent),
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.t(emptyKey, loc),
              key: const Key('report-empty-text'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      );
    }
    if (state.error != null) {
      // Refresh failure with data still on screen: show the message in a
      // compact line above the stale content instead of dropping it.
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              state.error!,
              key: const Key('report-error-message'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      );
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// Table (§8 columns)
// ---------------------------------------------------------------------------

/// One report column: localized at build time via [labelKey].
class ReportColumn {
  const ReportColumn(this.labelKey, {this.width, this.numeric = false});

  final String labelKey;
  final double? width;

  /// Right-aligns numeric columns.
  final bool numeric;
}

/// Horizontally scrollable `DataTable` with an optional totals footer
/// (§12.2 mirrors this row in CSV exports).
class ReportTable extends StatelessWidget {
  const ReportTable({
    super.key,
    required this.columns,
    required this.rows,
    this.totalsRow,
    required this.loc,
    this.rowKeyPrefix = 'report-row',
  });

  final List<ReportColumn> columns;
  final List<List<String>> rows;
  final List<String>? totalsRow;
  final String loc;
  final String rowKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.bodySmall
        ?.copyWith(fontWeight: FontWeight.w700);
    final bodyStyle = theme.textTheme.bodyMedium;
    final stripeColor = theme.colorScheme.surfaceContainerLow;
    // Semantic column accents (profit green, returns orange — else null).
    final colTones = <ReportMetricTone?>[
      for (final col in columns) reportColumnTone(col.labelKey),
    ];

    /// Sign-aware text color for one cell; non-numeric columns stay neutral.
    Color? cellColor(int c, String raw) => columns[c].numeric
        ? reportValueColor(raw, colTones[c], theme)
        : null;

    // The DataTable sits inside a horizontal scroll view; pinning its
    // minWidth to the viewport and giving every column a flex width makes
    // the table fill the available width (columns share the slack) while
    // still scrolling horizontally when the intrinsic columns overflow.
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: viewport),
            child: SingleChildScrollView(
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHighest,
                ),
                columns: [
                  for (final col in columns)
                    DataColumn(
                      label: Text(
                        AppStrings.t(col.labelKey, loc),
                        key: Key('${col.labelKey}-header'),
                        style: headerStyle,
                      ),
                      numeric: col.numeric,
                      columnWidth: const IntrinsicColumnWidth(flex: 1.0),
                    ),
                ],
                rows: [
                  for (var i = 0; i < rows.length; i++)
                    DataRow(
                      // Light zebra striping — theme tonal color only, so
                      // light/dark and both brand themes stay coherent.
                      color: i.isOdd
                          ? WidgetStatePropertyAll<Color?>(stripeColor)
                          : null,
                      cells: [
                        for (var c = 0;
                            c < columns.length && c < rows[i].length;
                            c++)
                          DataCell(
                            Text(
                              rows[i][c],
                              key: Key('$rowKeyPrefix-$i-$c'),
                              style: cellColor(c, rows[i][c]) == null
                                  ? bodyStyle
                                  : bodyStyle?.copyWith(
                                      color: cellColor(c, rows[i][c]),
                                    ),
                              // Money/percent/dates stay LTR under the
                              // RTL locale so negatives never mirror.
                              textDirection: columns[c].numeric
                                  ? TextDirection.ltr
                                  : null,
                              textAlign: columns[c].numeric
                                  ? TextAlign.end
                                  : TextAlign.start,
                            ),
                          ),
                      ],
                    ),
                  if (totalsRow != null)
                    DataRow(
                      // Stronger + tinted + bold: the totals row must read
                      // as the summary line, not one more data row.
                      color: WidgetStatePropertyAll(
                        Color.alphaBlend(
                          theme.colorScheme.primary.withValues(alpha: 0.06),
                          theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                      cells: [
                        for (var c = 0;
                            c < columns.length && c < totalsRow!.length;
                            c++)
                          DataCell(
                            Text(
                              totalsRow![c],
                              key: Key('report-totals-$c'),
                              style: bodyStyle?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cellColor(c, totalsRow![c]),
                              ),
                              textDirection: columns[c].numeric
                                  ? TextDirection.ltr
                                  : null,
                              textAlign: columns[c].numeric
                                  ? TextAlign.end
                                  : TextAlign.start,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pagination (§8: page/page_size ≤100)
// ---------------------------------------------------------------------------

class ReportPagination extends StatelessWidget {
  const ReportPagination({
    super.key,
    required this.page,
    required this.pages,
    required this.total,
    required this.loading,
    required this.onPrev,
    required this.onNext,
    required this.loc,
  });

  final int page;
  final int pages;
  final int total;
  final bool loading;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final String loc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('report-pagination'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('report-prev'),
            onPressed: (page > 1 && !loading) ? onPrev : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('$page / $pages', key: const Key('report-page')),
          IconButton(
            key: const Key('report-next'),
            onPressed: (page < pages && !loading) ? onNext : null,
            icon: const Icon(Icons.chevron_right),
          ),
          const SizedBox(width: 16),
          Text(
            '${AppStrings.t('label_documents', loc)}: $total',
            key: const Key('report-documents'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Plain-widget bar chart (G24 — no chart package)
// ---------------------------------------------------------------------------

/// One bar: [value] is already computed by the server; the chart only
/// scales it against the max for display height (no money arithmetic on
/// displayed figures — heights are proportions, never rendered values).
class ReportBar {
  const ReportBar({required this.label, required this.value, this.caption});

  final String label;
  final double value;
  final String? caption;
}

/// Vertical bar chart made of plain `Container`s (G24).
class ReportBarChart extends StatelessWidget {
  const ReportBarChart({
    super.key,
    required this.bars,
    this.height = 160,
    this.barKeyPrefix = 'report-bar',
    this.tone,
  });

  final List<ReportBar> bars;
  final double height;
  final String barKeyPrefix;

  /// Semantic accent of the measured metric (`null` → primary blue, the
  /// default for dashboard charts).
  final ReportMetricTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor = tone == null
        ? theme.colorScheme.primary
        : resolveReportTone(tone!, theme);
    if (bars.isEmpty) {
      return SizedBox(height: height, child: const SizedBox.shrink());
    }
    final max = bars
        .map((b) => b.value)
        .fold<double>(0, (a, b) => b > a ? b : a);
    return SizedBox(
      // caption + gap + bar + gap + label. The two bodySmall lines need
      // ~36px combined with the app's Cairo font (1.3 line height), so
      // the budget is height + 40 — a hard `height + 34` overflowed the
      // Column by ~2px in layout tests.
      height: height + 40,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < bars.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (bars[i].caption != null)
                      Text(
                        bars[i].caption!,
                        key: Key('$barKeyPrefix-$i-caption'),
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    // Track fills the chart area; the value bar sits on
                    // top of it (restrained tonal color, both themes).
                    Container(
                      height: height,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        key: Key('$barKeyPrefix-$i'),
                        height: _barHeight(bars[i].value, max, height),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      bars[i].label,
                      key: Key('$barKeyPrefix-$i-label'),
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Display-only ratio; negative server values (net sales can go below
  /// zero, §5.1 unclamped) render as a stub bar — never a negative size.
  static double _barHeight(double value, double max, double height) {
    if (max <= 0 || value <= 0) return 2.0;
    final ratio = (value / max).clamp(0.0, 1.0);
    return (ratio * height).clamp(2.0, height);
  }
}

// ---------------------------------------------------------------------------
// Small KPI tile (shared by financial tab + dashboard cards)
// ---------------------------------------------------------------------------

class ReportKpiTile extends StatelessWidget {
  const ReportKpiTile({
    super.key,
    required this.labelKey,
    required this.value,
    this.testKey,
    this.highlight = false,
    this.tone,
  });

  final String labelKey;
  final String value;
  final String? testKey;
  final bool highlight;

  /// Overrides the automatic label → tone mapping (`null` → resolve from
  /// [reportKpiTone] — neutral labels render no accent at all).
  final ReportMetricTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final metricTone = tone ?? reportKpiTone(labelKey);
    final accent =
        metricTone == null ? null : resolveReportTone(metricTone, theme);
    // Subtle surface tint: 6% accent blended over the card color — enough
    // to separate metric families without turning cards into color blocks.
    final cardColor = accent == null
        ? null
        : Color.alphaBlend(accent.withValues(alpha: 0.06), theme.cardColor);
    final valueColor = highlight
        ? theme.colorScheme.primary
        : reportValueColor(value, metricTone, theme);
    return Card(
      key: testKey == null ? null : Key(testKey!),
      margin: EdgeInsets.zero,
      color: cardColor,
      // No intrinsic `double.infinity` here: the dashboard's Wrap must
      // keep hugging card content (fixed widths come from the reports
      // grid's tight SizedBox cells), otherwise every dashboard card
      // goes full-width and the lazy ListView pushes sections off-screen.
      child: Container(
        // RTL-aware accent strip on the leading (start) edge.
        decoration: accent == null
            ? null
            : BoxDecoration(
                border: BorderDirectional(
                  start: BorderSide(color: accent, width: 3),
                ),
              ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: accent == null ? 14 : 12,
            vertical: 10,
          ),
          // MainAxisSize.min + no flex children: the card hugs its
          // content in loose contexts (the dashboard's Wrap), while the
          // reports grid's tight SizedBox cells still make it fill the
          // cell. An Expanded child here would force full-width cards
          // and push the dashboard's lazy ListView sections off-screen.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (accent != null) ...[
                Container(
                  key: testKey == null ? null : Key('$testKey-icon'),
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    reportToneIcon(metricTone!),
                    size: 18,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.t(labelKey, loc),
                    key: testKey == null ? null : Key('$testKey-label'),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    key: testKey == null ? null : Key('$testKey-value'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: valueColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Negatives never mirror under the RTL locale.
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds the params for a fresh page walk used by exports — exposed so
/// tests can assert the serialized query (§17.2 query serialization).
Map<String, dynamic> reportPageParams(
  ReportFilter filter, {
  int page = 1,
  int pageSize = kReportPageSize,
  String? extraKey,
  Object? extraValue,
}) {
  final params = <String, dynamic>{
    ...filter.rangeParams(),
    'page': page,
    'page_size': pageSize,
  };
  if (extraKey != null) params[extraKey] = extraValue;
  return params;
}
