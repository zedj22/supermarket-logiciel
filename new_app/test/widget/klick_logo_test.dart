// Klick POS — the drawn brand mark.
//
// Pins the production sizes used by the shell (28), the setup wizard (44)
// and the about screen (72): AppLogoMark must render the vector
// KlickPosLogo (never an image asset) at exactly the requested size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/widgets/klick_logo.dart';
import 'package:supermarket_pos/core/widgets/logo_mark.dart';

void main() {
  Future<RenderBox> pumpMark(WidgetTester tester, double size) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: AppLogoMark(size: size),
        ),
      ),
    );
    final box = tester.renderObject<RenderBox>(
      find.byType(KlickPosLogo),
    );
    return box;
  }

  testWidgets('AppLogoMark renders the vector KlickPosLogo', (tester) async {
    await pumpMark(tester, 44);
    expect(find.byType(KlickPosLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in const <double>[28, 44, 72]) {
    testWidgets('honours the production size $size', (tester) async {
      final box = await pumpMark(tester, size);
      expect(box.size, Size(size, size));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('paints without a theme or image asset dependency', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: KlickPosLogo(size: 96)),
      ),
    );
    expect(find.byType(KlickPosLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
