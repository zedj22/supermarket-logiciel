import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Dark theme
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkCard = Color(0xFF2D2D2D);
  static const Color darkBorder = Color(0xFF404040);
  static const Color darkTextPrimary = Color(0xFFE0E0E0);
  static const Color darkTextSecondary = Color(0xFF9E9E9E);
  static const Color darkAccent = Color(0xFF2196F3);

  // Light theme
  //
  // Secondary text sits on the #F5F5F5 scaffold: 0xFF757575 measured 4.23:1
  // there, just under the WCAG AA 4.5:1 body-text floor. 0xFF6E6E6E gives
  // 4.68:1 on the scaffold and 5.10:1 on white cards — the same neutral
  // grey, two steps darker.
  static const Color lightBackground = Color(0xFFF5F5F5);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE0E0E0);
  static const Color lightTextPrimary = Color(0xFF212121);
  static const Color lightTextSecondary = Color(0xFF6E6E6E);
  static const Color lightAccent = Color(0xFF1976D2);

  // Grey theme
  //
  // Secondary text sits on the #333333 card: 0xFF808080 measured 3.20:1,
  // well under WCAG AA. 0xFF9E9E9E gives 4.72:1 on the card (and 5.36:1 on
  // the surface) and matches the dark theme's secondary, so the two dark
  // palettes stay consistent.
  static const Color greyBackground = Color(0xFF1A1A1A);
  static const Color greySurface = Color(0xFF2A2A2A);
  static const Color greyCard = Color(0xFF333333);
  static const Color greyBorder = Color(0xFF4A4A4A);
  static const Color greyTextPrimary = Color(0xFFD0D0D0);
  static const Color greyTextSecondary = Color(0xFF9E9E9E);
  static const Color greyAccent = Color(0xFF607D8B);

  // Semantic colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFF44336);
  static const Color info = Color(0xFF2196F3);
}
