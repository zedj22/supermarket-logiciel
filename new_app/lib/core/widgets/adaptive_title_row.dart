import 'package:flutter/material.dart';

/// Screen header: title (+ optional subtitle) with a trailing action
/// cluster (add / refresh / search / filters) that NEVER overflows.
///
/// Layout contract (same convention as the Products screen's medium
/// toolbar):
///  - Both sides share the row as equal flexible halves, so neither can
///    push the other off-screen at any window width (RTL or LTR).
///  - The title block wraps its texts onto extra lines instead of
///    clipping them.
///  - The action cluster wraps its controls onto extra rows AND is
///    end-aligned, so on wide windows it still pins to the trailing
///    edge exactly like the original `Row + Spacer` headers, while on
///    narrow windows every button stays visible.
class AdaptiveTitleRow extends StatelessWidget {
  const AdaptiveTitleRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.actions,
  });

  /// Primary heading (already styled by the caller, with its finder key).
  final Widget title;

  /// Optional secondary line rendered next to the title.
  final Widget? subtitle;

  /// Trailing controls; end-aligned as one wrapping cluster.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        title,
        ?subtitle,
      ],
    );
    final actionCluster = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    );
    return Row(
      children: [
        Flexible(child: titleBlock),
        const SizedBox(width: 8),
        Flexible(
          // Tight width so the Wrap actually re-flows instead of
          // keeping its one-line intrinsic width inside the Row.
          child: SizedBox(width: double.infinity, child: actionCluster),
        ),
      ],
    );
  }
}
