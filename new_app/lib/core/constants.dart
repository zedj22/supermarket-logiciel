class AppConstants {
  static const String appName = 'Supermarket POS';
  static const String appVersion = '1.0.0';

  static const int minPinLength = 4;
  static const int maxPinLength = 6;
  static const int maxPageItems = 25;
  static const int defaultPageSize = 25;
  static const int moneyDecimalPlaces = 2;

  static const Duration apiTimeout = Duration(seconds: 30);
  static const Duration sessionTimeout = Duration(hours: 8);
}
