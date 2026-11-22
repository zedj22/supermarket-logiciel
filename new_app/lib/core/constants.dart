class AppConstants {
  /// Product name for surfaces Flutter owns outside `AppStrings` (the
  /// `MaterialApp` title). The localized wordmark is `app_name`.
  static const String appName = 'Store Management System';
  static const String appVersion = '1.0.0';

  static const int minPinLength = 4;
  static const int maxPinLength = 6;
  static const int maxPageItems = 25;
  static const int defaultPageSize = 25;
  static const int moneyDecimalPlaces = 2;

  static const Duration apiTimeout = Duration(seconds: 30);
  static const Duration sessionTimeout = Duration(hours: 8);

  /// Base URL used until the device has been paired with a LAN server
  /// (Phase 16 §8.3): the first-run / single-PC default, and the fallback
  /// the reconnect loop returns to when a remembered server is gone.
  static const String defaultServerBaseUrl = 'http://localhost:8000';

  /// Phase 16 discovery + heartbeat tuning (§11.1 / §14).
  static const Duration discoveryAttemptTimeout = Duration(milliseconds: 750);
  static const int discoveryAttempts = 3;
  static const Duration heartbeatInterval = Duration(seconds: 10);
  static const int heartbeatFailureThreshold = 2;
  static const Duration backoffCap = Duration(seconds: 30);
}
