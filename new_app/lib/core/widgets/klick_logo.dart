import 'package:flutter/material.dart';

import '../colors.dart';

/// The Klick POS brand mark: a shopping cart carrying three rising bars.
///
/// Drawn on a 100×100 design grid and scaled to [size]. The same geometry
/// is hand-mirrored in `assets/brand/klick_pos_logo.svg` (design source of
/// truth) and rasterized from this painter into the Windows `.ico`, so the
/// in-app mark, the shipped asset and the taskbar icon cannot drift apart.
///
/// There is no image asset in the runtime bundle on purpose — same as
/// [AppLogoMark], the app must render identically on every machine,
/// offline, with no font or image fetch. The palette is a single mark
/// colour plus a knockout colour drawn *inside* the blue shapes, so the
/// logo reads on light and dark surfaces alike.
class KlickPosLogo extends StatelessWidget {
  const KlickPosLogo({
    super.key,
    this.size = 32,
    this.markColor = AppColors.darkAccent,
    this.knockoutColor = Colors.white,
  });

  /// Edge length of the square the mark is drawn into.
  final double size;

  /// The brand blue of the cart, handle and wheels.
  final Color markColor;

  /// The colour knocked out of the basket: bars and wheel hubs.
  final Color knockoutColor;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _KlickLogoPainter(
            markColor: markColor,
            knockoutColor: knockoutColor,
          ),
        ),
      ),
    );
  }
}

class _KlickLogoPainter extends CustomPainter {
  const _KlickLogoPainter({
    required this.markColor,
    required this.knockoutColor,
  });

  final Color markColor;
  final Color knockoutColor;

  static const double _grid = 100;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / _grid;
    canvas
      ..translate((size.width - _grid * unit) / 2, (size.height - _grid * unit) / 2)
      ..scale(unit);

    final markStroke = Paint()
      ..color = markColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final markFill = Paint()
      ..color = markColor
      ..style = PaintingStyle.fill;
    final knockout = Paint()
      ..color = knockoutColor
      ..style = PaintingStyle.fill;

    // Handle: top bar down into the basket's upper-left corner.
    canvas.drawPath(
      Path()
        ..moveTo(7, 17)
        ..lineTo(21, 17)
        ..lineTo(31, 31),
      markStroke,
    );

    // Basket: trapezoid, rounded by a round-joined stroke of its own fill.
    final basket = Path()
      ..moveTo(36, 31)
      ..lineTo(91, 31)
      ..lineTo(80, 61)
      ..lineTo(47, 61)
      ..close();
    canvas
      ..drawPath(basket, markFill)
      ..drawPath(
        basket,
        Paint()
          ..color = markColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

    // Growth bars knocked out of the basket.
    for (final bar in const <Rect>[
      Rect.fromLTRB(47, 49, 56, 59),
      Rect.fromLTRB(59, 42, 68, 59),
      Rect.fromLTRB(71, 35, 80, 59),
    ]) {
      canvas.drawRRect(RRect.fromRectXY(bar, 4.5, 4.5), knockout);
    }

    // Wheels with knocked-out hubs.
    for (final center in const <Offset>[
      Offset(53, 75),
      Offset(74, 75),
    ]) {
      canvas
        ..drawCircle(center, 7, markFill)
        ..drawCircle(center, 2.5, knockout);
    }
  }

  @override
  bool shouldRepaint(_KlickLogoPainter oldDelegate) =>
      oldDelegate.markColor != markColor ||
      oldDelegate.knockoutColor != knockoutColor;
}
