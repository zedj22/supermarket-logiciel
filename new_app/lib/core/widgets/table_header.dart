import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The one pinned column-label chrome every tabular screen shares.
///
/// The header is a sibling of the scrolling body (never inside it), so it
/// stays on screen while rows move — but it must be built from the *same*
/// column specs as the rows, or the labels drift away from their cells.
/// Callers therefore pass the identical cell widgets they give the body.
class TableHeaderRow extends StatelessWidget {
  const TableHeaderRow({
    super.key,
    required this.children,
    this.height = 44,
    this.testKey,
    this.padding = EdgeInsets.zero,
  });

  /// Cell widgets, already sized (Expanded / SizedBox) exactly as the body
  /// row builds them.
  final List<Widget> children;

  final double height;

  /// Stable finder key (`products-table-header`, `reports-table-header`…).
  final Key? testKey;

  /// Inset applied around the whole row, for tables whose cells do not
  /// carry their own horizontal padding.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background =
        theme.dataTableTheme.headingRowColor?.resolve(const <WidgetState>{}) ??
            theme.colorScheme.surfaceContainerHighest;
    return Material(
      key: testKey,
      color: background,
      child: Container(
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.dividerColor, width: 1),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }
}

/// Column-label text — the table rung of the type hierarchy.
///
/// Every screen must use this, otherwise one table's header is 12.5px/w700
/// and the next is 14px/w500.
TextStyle tableHeaderStyle(BuildContext context) =>
    AppTheme.tableHeader(Theme.of(context));

/// One header cell, RTL-correct: numeric labels hug the end, everything
/// else starts at the leading edge.
Widget tableHeaderCell(
  BuildContext context, {
  required Widget child,
  required bool numeric,
  int flex = 1,
  double fixedWidth = 0,
}) {
  final inner = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: DefaultTextStyle(
      style: tableHeaderStyle(context),
      child: Align(
        alignment: numeric
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: child,
      ),
    ),
  );
  if (fixedWidth > 0) return SizedBox(width: fixedWidth, child: inner);
  return Expanded(flex: flex, child: inner);
}
