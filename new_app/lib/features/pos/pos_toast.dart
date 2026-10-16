// Compact floating POS feedback toast (Phase 8 FIX #9A, FIX #10).
//
// Replaces the old full-width SnackBar bar with a small bottom-center
// rounded card that floats near the window bottom whenever it clears the
// cart side panel and above the cart footer (TOTAL + PAY) when it does
// not. Visual only — never touches cart calculations, totals, stock,
// payment, holds, history or printing.
//
// One toast at a time: a new toast replaces the visible one (never
// stacks giant bars over the cart).
import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../core/numeric_text.dart';
import 'pos_layout.dart';

/// Semantic toast category — drives background, icon and duration.
enum PosToastKind { success, error, warning, info }

/// Normal / info / success / warning lifetime (spec: 3 s).
const Duration kPosToastDuration = Duration(seconds: 3);

/// Errors stay a little longer (spec: 4–5 s).
const Duration kPosToastErrorDuration = Duration(milliseconds: 4500);

/// Card width cap (spec FIX #10: 420–460) — the card is
/// `min(screenWidth - 32, kPosToastMaxWidth)` wide so it never reaches
/// the screen edges.
const double kPosToastMaxWidth = 440;
const double kPosToastMinWidth = 280;

/// Minimum horizontal distance from each screen edge (kept by the
/// `screenWidth - 2 * gutter` width formula).
const double kPosToastHorizontalGutter = 16;

/// Entry: fade + small vertical slide (spec: 150–200 ms); exit: reverse.
const Duration kPosToastAnimationDuration = Duration(milliseconds: 180);
const Duration kPosToastExitDuration = Duration(milliseconds: 160);

/// Vertical safe area only: estimated cart footer (totals + PAY) height.
/// Used on narrow viewports where a toast at 24 px would cover TOTAL/PAY
/// (`posToastBottomFor` decides which offset applies).
double posToastFooterFor(Size size) {
  if (size.height < 560) return 140;
  if (size.height < 700) return 160;
  return 176;
}

/// Whether the bottom-centered toast card ends at (or before) the cart
/// side panel's left edge — i.e. the card floats in free space beside the
/// cart, so a low 24 px offset cannot cover TOTAL/PAY.
///
/// Below `800` the cart is a full-width drawer, so a centered card never
/// clears it (the footer-safe offset applies instead).
bool posToastClearsCartFor(Size size) {
  if (size.width < 800) return false;
  final double toastRight = (size.width + posToastWidthFor(size.width)) / 2;
  return toastRight <= size.width - posCartWidthFor(size.width);
}

/// Toast bottom offset from the screen bottom (FIX #10B micro-fix —
/// vertical position only, adaptive so PAY/TOTAL stay unobstructed).
/// - **24 px** when the centered toast clears the cart side panel
///   ([posToastClearsCartFor]): there is free space beside the cart, so
///   the card hugs the bottom edge with only a small safe margin.
/// - Otherwise — narrow `< 800` (cart is a full-width drawer) **and**
///   medium/wide viewports where the cart sits directly under the centered
///   card — footer-safe `footer + 6`, which keeps TOTAL/PAY clear.
double posToastBottomFor(Size size) {
  if (posToastClearsCartFor(size)) return 24;
  return posToastFooterFor(size) + 6;
}

/// Toast card width: `min(availableWidth - 32, 440)` (fits narrow
/// windows without clipping, never exceeds the 440 max).
double posToastWidthFor(double screenWidth) {
  final double available =
      screenWidth - (2 * kPosToastHorizontalGutter);
  if (available >= kPosToastMaxWidth) return kPosToastMaxWidth;
  return available; // below 280 only on tiny windows — fit, never clip.
}

/// Existing theme semantic colors (never hardcoded ad-hoc hues).
Color posToastBackground(PosToastKind kind) {
  switch (kind) {
    case PosToastKind.success:
      return AppColors.success;
    case PosToastKind.error:
      return AppColors.error;
    case PosToastKind.warning:
      return AppColors.warning;
    case PosToastKind.info:
      return AppColors.info;
  }
}

/// Readable contrast on the semantic background: white on the cool/warm
/// colors, near-black on amber warning.
Color posToastForeground(PosToastKind kind) {
  if (kind == PosToastKind.warning) return AppColors.lightTextPrimary;
  return Colors.white;
}

IconData posToastIcon(PosToastKind kind) {
  switch (kind) {
    case PosToastKind.success:
      return Icons.check_circle_outline;
    case PosToastKind.error:
      return Icons.close;
    case PosToastKind.warning:
      return Icons.priority_high;
    case PosToastKind.info:
      return Icons.info_outline;
  }
}

/// Shows one compact floating POS toast (bottom-center, footer-safe).
///
/// Replaces any visible toast so notifications never stack. [duration]
/// defaults to 3 s (4.5 s for errors). [detail] renders a small second
/// line (invoice number, hint). [actionLabel]/[onAction] add a compact
/// action button (e.g. Retry).
void showPosToast(
  BuildContext context, {
  required String message,
  PosToastKind kind = PosToastKind.info,
  String? detail,
  Key? key,
  Key? messageKey,
  String? actionLabel,
  VoidCallback? onAction,
  Key? actionKey,
  Duration? duration,
}) {
  final Size size = MediaQuery.sizeOf(context);
  final double width = posToastWidthFor(size.width);
  final double bottom = posToastBottomFor(size);
  final double sideGutter = (size.width - width) / 2;
  final Color foreground = posToastForeground(kind);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

  // Spec §9: replace the current toast — never stack notifications.
  messenger.clearSnackBars();

  messenger.showSnackBar(
    SnackBar(
      key: key,
      behavior: SnackBarBehavior.floating,
      // Symmetric horizontal margins = horizontally centered card;
      // bottom keeps the adaptive offset (FIX #10: bottomCenter,
      // FIX #10B micro-fix: 24px when the card clears the cart panel,
      // footer + 6 otherwise).
      // Width and margin cannot be combined on SnackBar, so the width
      // is expressed through the margins instead.
      margin: EdgeInsets.fromLTRB(
        sideGutter,
        0,
        sideGutter,
        bottom,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      elevation: 3,
      backgroundColor: posToastBackground(kind),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      duration: duration ??
          (kind == PosToastKind.error
              ? kPosToastErrorDuration
              : kPosToastDuration),
      content: PosToast(
        kind: kind,
        message: message,
        detail: detail,
        messageKey: messageKey,
        foreground: foreground,
        showClose: kind == PosToastKind.error || message.length > 60,
      ),
      action: actionLabel == null
          ? null
          : SnackBarAction(
              key: actionKey,
              label: actionLabel,
              textColor: foreground,
              onPressed: onAction ?? () {},
            ),
    ),
    snackBarAnimationStyle: const AnimationStyle(
      duration: kPosToastAnimationDuration,
      reverseDuration: kPosToastExitDuration,
    ),
  );
}

/// Compact toast body: icon + message (max 2 lines) + optional secondary
/// detail line + optional compact close button (44×44 hit area).
class PosToast extends StatefulWidget {
  const PosToast({
    super.key,
    required this.kind,
    required this.message,
    required this.foreground,
    this.detail,
    this.messageKey,
    this.showClose = false,
  });

  final PosToastKind kind;
  final String message;
  final String? detail;
  final Key? messageKey;
  final Color foreground;
  final bool showClose;

  @override
  State<PosToast> createState() => _PosToastState();
}

class _PosToastState extends State<PosToast> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    // Kick off the subtle fade + slide entry after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color fg = widget.foreground;
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: kPosToastAnimationDuration,
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : const Offset(0, 0.3),
        duration: kPosToastAnimationDuration,
        curve: Curves.easeOut,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(posToastIcon(widget.kind), size: 21, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.message,
                    key: widget.messageKey,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (widget.detail != null) ...[
                    const SizedBox(height: 2),
                    numericText(
                      widget.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: fg.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.showClose) ...[
              const SizedBox(width: 4),
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  key: const Key('pos-toast-close'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                  iconSize: 18,
                  color: fg,
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => ScaffoldMessenger.of(context)
                      .hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
