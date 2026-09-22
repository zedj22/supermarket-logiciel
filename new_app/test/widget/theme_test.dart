import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppTheme returns valid ThemeData', () {
    setUp(() {
      GoogleFonts.config.allowRuntimeFetching = false;
    });

    testWidgets('dark theme renders', (tester) async {
      final theme = AppTheme.dark();
      expect(theme, isA<ThemeData>());
      expect(theme.brightness, Brightness.dark);
    });

    testWidgets('light theme renders', (tester) async {
      final theme = AppTheme.light();
      expect(theme, isA<ThemeData>());
      expect(theme.brightness, Brightness.light);
    });

    testWidgets('grey theme renders', (tester) async {
      final theme = AppTheme.grey();
      expect(theme, isA<ThemeData>());
      expect(theme.brightness, Brightness.dark);
    });
  });
}
