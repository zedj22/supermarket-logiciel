// Rasterizes the drawn Klick POS mark into the PNG sizes the Windows icon
// needs, straight from the widget that ships in the app, so the taskbar
// icon cannot drift from the in-app logo.
//
// This is a build tool, not a regression test: it renders only when run
// with
//
//   flutter test --dart-define=GENERATE_BRAND_ASSETS=true test/tools/generate_brand_icon_test.dart
//
// and writes build/brand/klick_pos_logo_<size>.png (transparent) for
// tool/generate_windows_icon.py to wrap into the .ico. Normal test runs
// execute nothing.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/widgets/klick_logo.dart';

const bool _generate = bool.fromEnvironment('GENERATE_BRAND_ASSETS');

const List<int> _iconSizes = <int>[16, 24, 32, 48, 64, 128, 256];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('brand PNG generator (renders only with GENERATE_BRAND_ASSETS)',
      (tester) async {
    if (!_generate) return;

    final outDir = Directory('build/brand');
    outDir.createSync(recursive: true);

    for (final size in _iconSizes) {
      // Center: the pumpWidget root constraints are tight (full screen),
      // which would stretch the mark instead of letting it size itself.
      await tester.pumpWidget(
        Center(child: KlickPosLogo(size: size.toDouble())),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(KlickPosLogo),
          matching: find.byType(RepaintBoundary),
        ),
      );
      // toImage/toByteData complete on engine callbacks — they need the
      // real async zone, outside the test's fake clock.
      final png = await tester.runAsync<Uint8List>(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      File('${outDir.path}/klick_pos_logo_$size.png').writeAsBytesSync(png!);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
