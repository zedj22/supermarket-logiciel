import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/colors.dart';

void main() {
  group('AppColors', () {
    test('dark colors are defined', () {
      expect(AppColors.darkBackground, isNotNull);
      expect(AppColors.darkSurface, isNotNull);
      expect(AppColors.darkAccent, isNotNull);
    });

    test('light colors are defined', () {
      expect(AppColors.lightBackground, isNotNull);
      expect(AppColors.lightSurface, isNotNull);
      expect(AppColors.lightAccent, isNotNull);
    });

    test('grey colors are defined', () {
      expect(AppColors.greyBackground, isNotNull);
      expect(AppColors.greySurface, isNotNull);
      expect(AppColors.greyAccent, isNotNull);
    });

    test('semantic colors are defined', () {
      expect(AppColors.success, isNotNull);
      expect(AppColors.warning, isNotNull);
      expect(AppColors.error, isNotNull);
      expect(AppColors.info, isNotNull);
    });
  });
}
