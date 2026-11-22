import 'package:flutter/foundation.dart';

/// Post-checkout receipt printing mode (`receipt_print_mode`).
///
/// THE receipt-printing control — the only one the POS consults:
///
/// * [disabled] — no automatic printing and no print prompt.
/// * [ask] — after a successful sale, the cashier is asked whether to
///   print; yes prints, no finishes without printing.
/// * [autoPrint] — the receipt is sent straight to the configured printer
///   through the existing direct-print mechanism, no prompt.
/// * [askAboveThreshold] — when the confirmed receipt total reaches
///   [StoreSettings.receiptMinAmount] the receipt PDF is generated and the
///   native Windows Print Setup dialog opens (no custom preview);
///   cancelling it prints nothing.
///
/// The legacy `ask_before_print` / `auto_print_invoice` fields still travel
/// over the wire for older backends, but they are **inert**: the backend
/// migration folded them into this mode and zeroed them, and this client
/// never reads them.
///
/// The [wire] value is the backend vocabulary
/// (`ck_app_settings_receipt_print_mode`).
enum ReceiptPrintMode {
  disabled('disabled'),
  ask('ask'),
  autoPrint('auto_print'),
  askAboveThreshold('ask_above_threshold');

  const ReceiptPrintMode(this.wire);

  final String wire;

  /// Localization key of the option label.
  String get labelKey => 'receipt_print_mode_$wire';

  /// Unknown/missing values fall back to [disabled] — the documented
  /// default, so a client older than the backend never changes behaviour.
  static ReceiptPrintMode fromWire(Object? value) {
    for (final mode in ReceiptPrintMode.values) {
      if (mode.wire == value) return mode;
    }
    return ReceiptPrintMode.disabled;
  }
}

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
    required this.storeWilaya,
    required this.storeEmail,
    required this.storeNif,
    required this.storeNis,
    required this.storeRc,
    required this.storeAi,
    required this.storeRib,
    required this.defaultPaper,
    required this.askBeforePrint,
    required this.autoPrintInvoice,
    required this.receiptPrintMode,
    required this.receiptMinAmount,
    required this.allowDebt,
    required this.lowStockThreshold,
  });

  /// Relative path of both endpoints (no leading slash so Dio's `baseUrl`
  /// joins it the same way every other feature path does).
  static const String settingsPath = '/api/v1/settings';

  /// Paper formats accepted by the backend (`ck_app_settings_default_paper`).
  static const List<String> papers = <String>['80mm', 'A4'];

  /// Wire keys of the independent receipt-printing control. A settings
  /// response that does not carry BOTH did not persist them (a backend
  /// older than the client), which the provider must never present as a
  /// successful save.
  static const List<String> receiptPrintKeys = <String>[
    'receipt_print_mode',
    'receipt_min_amount',
  ];

  /// True when [json] carries both receipt-printing keys.
  static bool carriesReceiptPrintSettings(Map<String, dynamic> json) =>
      receiptPrintKeys.every(json.containsKey);

  /// Numeric amount from JSON — a `NUMERIC` column may legitimately arrive
  /// as a JSON number or as its decimal string form (PostgreSQL `Decimal`),
  /// so both are accepted instead of throwing and losing the whole form.
  static double _amountFromJson(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }

  final String storeName;
  final String storePhone;
  final String storeAddress;
  final String invoiceFooter;

  /// Phase 6 — company/fiscal identity, the facturation document header
  /// source of truth (legacy factura_simple ``Company``: wilaya, e-mail,
  /// NIF, NIS, RC, AI, RIB/CCP).  Name/address/phone are the three store_*
  /// fields above — together they are the legacy company's 10 fields.
  final String storeWilaya;
  final String storeEmail;
  final String storeNif;
  final String storeNis;
  final String storeRc;
  final String storeAi;
  final String storeRib;

  final String defaultPaper;

  /// Legacy wire fields — kept so the whole form can be PUT back unchanged;
  /// never read by any behaviour (see [ReceiptPrintMode]).
  final bool askBeforePrint;
  final bool autoPrintInvoice;

  /// Post-checkout receipt printing mode — see [ReceiptPrintMode].
  final ReceiptPrintMode receiptPrintMode;

  /// Minimum confirmed receipt total (in currency units) that opens the
  /// receipt print dialog in [ReceiptPrintMode.askAboveThreshold].
  final double receiptMinAmount;

  final bool allowDebt;
  final int lowStockThreshold;

  factory StoreSettings.fromJson(Map<String, dynamic> json) {
    return StoreSettings(
      storeName: json['store_name'] as String? ?? '',
      storePhone: json['store_phone'] as String? ?? '',
      storeAddress: json['store_address'] as String? ?? '',
      invoiceFooter: json['invoice_footer'] as String? ?? '',
      storeWilaya: json['store_wilaya'] as String? ?? '',
      storeEmail: json['store_email'] as String? ?? '',
      storeNif: json['store_nif'] as String? ?? '',
      storeNis: json['store_nis'] as String? ?? '',
      storeRc: json['store_rc'] as String? ?? '',
      storeAi: json['store_ai'] as String? ?? '',
      storeRib: json['store_rib'] as String? ?? '',
      defaultPaper: json['default_paper'] as String? ?? '80mm',
      askBeforePrint: json['ask_before_print'] as bool? ?? false,
      autoPrintInvoice: json['auto_print_invoice'] as bool? ?? false,
      receiptPrintMode: ReceiptPrintMode.fromWire(json['receipt_print_mode']),
      receiptMinAmount: _amountFromJson(json['receipt_min_amount']),
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
        'store_wilaya': storeWilaya,
        'store_email': storeEmail,
        'store_nif': storeNif,
        'store_nis': storeNis,
        'store_rc': storeRc,
        'store_ai': storeAi,
        'store_rib': storeRib,
        'default_paper': defaultPaper,
        'ask_before_print': askBeforePrint,
        'auto_print_invoice': autoPrintInvoice,
        'receipt_print_mode': receiptPrintMode.wire,
        'receipt_min_amount': receiptMinAmount,
        'allow_debt': allowDebt,
        'low_stock_threshold': lowStockThreshold,
      };

  StoreSettings copyWith({
    String? storeName,
    String? storePhone,
    String? storeAddress,
    String? invoiceFooter,
    String? storeWilaya,
    String? storeEmail,
    String? storeNif,
    String? storeNis,
    String? storeRc,
    String? storeAi,
    String? storeRib,
    String? defaultPaper,
    bool? askBeforePrint,
    bool? autoPrintInvoice,
    ReceiptPrintMode? receiptPrintMode,
    double? receiptMinAmount,
    bool? allowDebt,
    int? lowStockThreshold,
  }) {
    return StoreSettings(
      storeName: storeName ?? this.storeName,
      storePhone: storePhone ?? this.storePhone,
      storeAddress: storeAddress ?? this.storeAddress,
      invoiceFooter: invoiceFooter ?? this.invoiceFooter,
      storeWilaya: storeWilaya ?? this.storeWilaya,
      storeEmail: storeEmail ?? this.storeEmail,
      storeNif: storeNif ?? this.storeNif,
      storeNis: storeNis ?? this.storeNis,
      storeRc: storeRc ?? this.storeRc,
      storeAi: storeAi ?? this.storeAi,
      storeRib: storeRib ?? this.storeRib,
      defaultPaper: defaultPaper ?? this.defaultPaper,
      askBeforePrint: askBeforePrint ?? this.askBeforePrint,
      autoPrintInvoice: autoPrintInvoice ?? this.autoPrintInvoice,
      receiptPrintMode: receiptPrintMode ?? this.receiptPrintMode,
      receiptMinAmount: receiptMinAmount ?? this.receiptMinAmount,
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
          other.storeWilaya == storeWilaya &&
          other.storeEmail == storeEmail &&
          other.storeNif == storeNif &&
          other.storeNis == storeNis &&
          other.storeRc == storeRc &&
          other.storeAi == storeAi &&
          other.storeRib == storeRib &&
          other.defaultPaper == defaultPaper &&
          other.askBeforePrint == askBeforePrint &&
          other.autoPrintInvoice == autoPrintInvoice &&
          other.receiptPrintMode == receiptPrintMode &&
          other.receiptMinAmount == receiptMinAmount &&
          other.allowDebt == allowDebt &&
          other.lowStockThreshold == lowStockThreshold);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        storeName,
        storePhone,
        storeAddress,
        invoiceFooter,
        storeWilaya,
        storeEmail,
        storeNif,
        storeNis,
        storeRc,
        storeAi,
        storeRib,
        defaultPaper,
        askBeforePrint,
        autoPrintInvoice,
        receiptPrintMode,
        receiptMinAmount,
        allowDebt,
        lowStockThreshold,
      ]);

  @override
  String toString() =>
      'StoreSettings(storeName: $storeName, defaultPaper: $defaultPaper, '
      'allowDebt: $allowDebt, lowStockThreshold: $lowStockThreshold)';
}
