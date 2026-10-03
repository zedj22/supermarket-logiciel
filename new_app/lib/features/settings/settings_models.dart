import 'package:flutter/foundation.dart';

/// Store/application settings — the `GET/PUT /api/v1/settings` body
/// (Phase 17, §17.1).
///
/// These are the **server-owned** settings: everything the backend renders
/// on a receipt/export or enforces in a POS rule.  Language and theme are
/// deliberately absent — they are user/session preferences kept in
/// SharedPreferences (`app_locale` / `app_theme_mode`).
@immutable
class StoreSettings {
  const StoreSettings({
    required this.storeName,
    required this.storePhone,
    required this.storeAddress,
    required this.invoiceFooter,
    required this.defaultPaper,
    required this.askBeforePrint,
    required this.autoPrintInvoice,
    required this.allowDebt,
    required this.lowStockThreshold,
  });

  /// Relative path of both endpoints (no leading slash so Dio's `baseUrl`
  /// joins it the same way every other feature path does).
  static const String settingsPath = '/api/v1/settings';

  /// Paper formats accepted by the backend (`ck_app_settings_default_paper`).
  static const List<String> papers = <String>['80mm', 'A4'];

  final String storeName;
  final String storePhone;
  final String storeAddress;
  final String invoiceFooter;
  final String defaultPaper;
  final bool askBeforePrint;
  final bool autoPrintInvoice;
  final bool allowDebt;
  final int lowStockThreshold;

  factory StoreSettings.fromJson(Map<String, dynamic> json) {
    return StoreSettings(
      storeName: json['store_name'] as String? ?? '',
      storePhone: json['store_phone'] as String? ?? '',
      storeAddress: json['store_address'] as String? ?? '',
      invoiceFooter: json['invoice_footer'] as String? ?? '',
      defaultPaper: json['default_paper'] as String? ?? '80mm',
      askBeforePrint: json['ask_before_print'] as bool? ?? false,
      autoPrintInvoice: json['auto_print_invoice'] as bool? ?? false,
      allowDebt: json['allow_debt'] as bool? ?? true,
      lowStockThreshold: (json['low_stock_threshold'] as num?)?.toInt() ?? 5,
    );
  }

  /// The full body for `PUT /settings`.
  ///
  /// Every field is always sent: the endpoint rejects an empty body, and a
  /// settings form is a single document — there is no "half a form" to save.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'store_name': storeName,
        'store_phone': storePhone,
        'store_address': storeAddress,
        'invoice_footer': invoiceFooter,
        'default_paper': defaultPaper,
        'ask_before_print': askBeforePrint,
        'auto_print_invoice': autoPrintInvoice,
        'allow_debt': allowDebt,
        'low_stock_threshold': lowStockThreshold,
      };

  StoreSettings copyWith({
    String? storeName,
    String? storePhone,
    String? storeAddress,
    String? invoiceFooter,
    String? defaultPaper,
    bool? askBeforePrint,
    bool? autoPrintInvoice,
    bool? allowDebt,
    int? lowStockThreshold,
  }) {
    return StoreSettings(
      storeName: storeName ?? this.storeName,
      storePhone: storePhone ?? this.storePhone,
      storeAddress: storeAddress ?? this.storeAddress,
      invoiceFooter: invoiceFooter ?? this.invoiceFooter,
      defaultPaper: defaultPaper ?? this.defaultPaper,
      askBeforePrint: askBeforePrint ?? this.askBeforePrint,
      autoPrintInvoice: autoPrintInvoice ?? this.autoPrintInvoice,
      allowDebt: allowDebt ?? this.allowDebt,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoreSettings &&
          other.storeName == storeName &&
          other.storePhone == storePhone &&
          other.storeAddress == storeAddress &&
          other.invoiceFooter == invoiceFooter &&
          other.defaultPaper == defaultPaper &&
          other.askBeforePrint == askBeforePrint &&
          other.autoPrintInvoice == autoPrintInvoice &&
          other.allowDebt == allowDebt &&
          other.lowStockThreshold == lowStockThreshold);

  @override
  int get hashCode => Object.hash(
        storeName,
        storePhone,
        storeAddress,
        invoiceFooter,
        defaultPaper,
        askBeforePrint,
        autoPrintInvoice,
        allowDebt,
        lowStockThreshold,
      );

  @override
  String toString() =>
      'StoreSettings(storeName: $storeName, defaultPaper: $defaultPaper, '
      'allowDebt: $allowDebt, lowStockThreshold: $lowStockThreshold)';
}
