// Riverpod providers for the Reports feature (Phase 14).
//
// Shape: one shared [reportFilterProvider] (date range + preset + device,
// §8 "common parameters") feeding one typed controller per report surface
// (R1–R9, R13). Every controller is a small StateNotifier that:
//   * fetches `GET /api/v1/reports/<endpoint>` with the shared range,
//   * keeps the previous data visible while refreshing (no flicker),
//   * maps failures through `reportsApiMessage` (localized, §11 codes),
//   * ignores stale responses (request-id guard), same as expenses.
//
// Money stays in decimal strings end to end: the server owns every figure
// (§5) and no screen recomputes anything (§8).
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'report_models.dart';
import 'reports_error.dart';

const String kReportsPath = '/api/v1/reports';

/// Page size used by the on-screen tables (server max is 100, §11).
const int kReportPageSize = 100;

/// `yyyy-MM-dd` of the local calendar day — the server treats both bounds
/// as inclusive calendar dates (§6).
String reportDateParam(DateTime value) =>
    DateFormat('yyyy-MM-dd').format(value.toLocal());

// ---------------------------------------------------------------------------
// Shared filter (range + preset + device)
// ---------------------------------------------------------------------------

/// Preset codes for the range selector (§14 `preset_*` keys), in the
/// order they appear in the dropdowns.
const List<String> kReportPresets = <String>[
  'today',
  'yesterday',
  'last_7_days',
  'this_month',
  'last_month',
  'last_3_months',
  'last_6_months',
  'custom',
];

String reportPresetKey(String preset) => 'preset_$preset';

/// Inclusive calendar range `[dateFrom, dateTo]` shared by every report
/// tab (§8 common parameters). The default matches the dashboard default
/// period = today (§7).
class ReportFilter {
  final String preset;
  final DateTime dateFrom;
  final DateTime dateTo;

  /// `null`/empty = all devices (§8 `device_id?`).
  final String? deviceId;

  const ReportFilter({
    required this.preset,
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
  });

  factory ReportFilter.initial() {
    final now = DateTime.now();
    return ReportFilter(
      preset: 'today',
      dateFrom: DateTime(now.year, now.month, now.day),
      dateTo: DateTime(now.year, now.month, now.day),
    );
  }

  ReportFilter copyWith({
    String? preset,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? deviceId,
    bool clearDevice = false,
  }) {
    return ReportFilter(
      preset: preset ?? this.preset,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
      deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
    );
  }

  /// Resolves a preset to its inclusive range (local calendar days).
  ///
  /// Month presets follow *complete calendar months* — never a rolling
  /// window and never the current partial month: "last month" is the
  /// previous month in full, and the N-month presets run from the 1st of
  /// the month N months back through the last day of the previous month.
  /// Both bounds are always produced together in one [ReportFilter], so a
  /// preset change can never leave a stale or reversed range behind.
  ///
  /// [now] is injectable so tests can pin the reference date (e.g.
  /// 2026-10-01 → `last_6_months` = 2026-04-01 … 2026-09-30).
  static ReportFilter fromPreset(
    String preset, {
    String? deviceId,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    switch (preset) {
      case 'yesterday':
        final y = today.subtract(const Duration(days: 1));
        return ReportFilter(
          preset: preset,
          dateFrom: y,
          dateTo: y,
          deviceId: deviceId,
        );
      case 'last_7_days':
        return ReportFilter(
          preset: preset,
          dateFrom: today.subtract(const Duration(days: 6)),
          dateTo: today,
          deviceId: deviceId,
        );
      case 'this_month':
        return ReportFilter(
          preset: preset,
          dateFrom: DateTime(reference.year, reference.month, 1),
          dateTo: today,
          deviceId: deviceId,
        );
      case 'last_month':
        return ReportFilter(
          preset: preset,
          dateFrom: DateTime(reference.year, reference.month - 1, 1),
          dateTo: DateTime(reference.year, reference.month, 0),
          deviceId: deviceId,
        );
      case 'last_3_months':
        return ReportFilter(
          preset: preset,
          dateFrom: DateTime(reference.year, reference.month - 3, 1),
          dateTo: DateTime(reference.year, reference.month, 0),
          deviceId: deviceId,
        );
      case 'last_6_months':
        return ReportFilter(
          preset: preset,
          dateFrom: DateTime(reference.year, reference.month - 6, 1),
          dateTo: DateTime(reference.year, reference.month, 0),
          deviceId: deviceId,
        );
      case 'today':
      default:
        return ReportFilter(
          preset: preset,
          dateFrom: today,
          dateTo: today,
          deviceId: deviceId,
        );
    }
  }

  /// §11 query params shared by the ranged reports + the device filter.
  Map<String, dynamic> rangeParams() => <String, dynamic>{
        'date_from': reportDateParam(dateFrom),
        'date_to': reportDateParam(dateTo),
        if (deviceId != null && deviceId!.isNotEmpty) 'device_id': deviceId,
      };

  @override
  bool operator ==(Object other) =>
      other is ReportFilter &&
      other.preset == preset &&
      other.dateFrom == dateFrom &&
      other.dateTo == dateTo &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(preset, dateFrom, dateTo, deviceId);
}

class ReportFilterNotifier extends StateNotifier<ReportFilter> {
  ReportFilterNotifier() : super(ReportFilter.initial());

  void setPreset(String preset) {
    state = ReportFilter.fromPreset(preset, deviceId: state.deviceId);
  }

  void setDateFrom(DateTime value) {
    final day = DateTime(value.year, value.month, value.day);
    state = state.copyWith(
      preset: 'custom',
      dateFrom: day,
      dateTo: day.isAfter(state.dateTo) ? day : state.dateTo,
    );
  }

  void setDateTo(DateTime value) {
    final day = DateTime(value.year, value.month, value.day);
    state = state.copyWith(
      preset: 'custom',
      dateTo: day,
      dateFrom: day.isBefore(state.dateFrom) ? day : state.dateFrom,
    );
  }

  void setDevice(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      state = state.copyWith(clearDevice: true);
    } else {
      state = state.copyWith(deviceId: trimmed);
    }
  }

  void reset() => state = ReportFilter.initial();
}

final reportFilterProvider =
    StateNotifierProvider<ReportFilterNotifier, ReportFilter>((ref) {
  return ReportFilterNotifier();
});

// ---------------------------------------------------------------------------
// Per-tab controllers
// ---------------------------------------------------------------------------

/// Shared view state for one report surface.
class ReportTabState<T> {
  final T? data;
  final bool loading;
  final String? error;

  const ReportTabState({this.data, this.loading = false, this.error});

  ReportTabState<T> copyWith({T? data, bool? loading, String? error}) {
    return ReportTabState<T>(
      data: data ?? this.data,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

/// Base controller: one endpoint, one response type, staleness guard.
abstract class ReportTabController<T> extends StateNotifier<ReportTabState<T>> {
  ReportTabController(this._dio, this._localeCode)
      : super(ReportTabState<T>());

  final Dio _dio;
  final String Function() _localeCode;

  int _requestId = 0;
  bool _initialized = false;

  /// True once the tab issued its first load — the shared-filter listener
  /// only reloads tabs the user has actually opened (no request storm).
  bool get initialized => _initialized;

  /// Endpoint segment after `/api/v1/reports/`.
  String get endpoint;

  /// Query parameters for this surface (§11).
  Map<String, dynamic> params();

  /// Parses the JSON envelope into [T].
  T parse(Map<String, dynamic> json);

  Future<void> load() async {
    _initialized = true;
    final requestId = ++_requestId;
    state = ReportTabState<T>(data: state.data, loading: true);
    try {
      final response = await _dio.get(
        '$kReportsPath/$endpoint',
        queryParameters: params(),
      );
      if (requestId != _requestId) return;
      final json = response.data as Map<String, dynamic>? ?? const {};
      state = ReportTabState<T>(data: parse(json), loading: false);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = ReportTabState<T>(
        data: state.data,
        loading: false,
        error: reportsApiMessage(e, _localeCode()),
      );
    }
  }

  void refresh() => load();
}

typedef _FilterReader = ReportFilter Function();

// --- R1 financial ----------------------------------------------------------

class FinancialController
    extends ReportTabController<FinancialReport> {
  FinancialController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  @override
  String get endpoint => 'financial';

  @override
  Map<String, dynamic> params() => _readFilter().rangeParams();

  @override
  FinancialReport parse(Map<String, dynamic> json) =>
      FinancialReport.fromJson(json);
}

/// Every tab controller refreshes itself when the shared filter changes,
/// but only if the user has already opened its tab (initialized) — so a
/// preset change never fires requests for tabs that were never visited.

final financialProvider = StateNotifierProvider<
    FinancialController, ReportTabState<FinancialReport>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = FinancialController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R2 products -----------------------------------------------------------

/// §8 R2 sort options.
const List<String> kReportSorts = <String>[
  'net_revenue',
  'qty_sold',
  'gross_profit',
  'return_qty',
  'margin_pct',
];

String reportSortKey(String sort) {
  switch (sort) {
    case 'net_revenue':
      return 'col_net_revenue';
    case 'qty_sold':
      return 'col_qty';
    case 'gross_profit':
      return 'col_gross_profit';
    case 'return_qty':
      return 'col_returns_qty';
    case 'margin_pct':
      return 'col_margin';
    default:
      return 'col_net_revenue';
  }
}

class ProductsController extends ReportTabController<ProductReportPage> {
  ProductsController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;
  String sort = 'net_revenue';
  int page = 1;

  @override
  String get endpoint => 'products';

  @override
  Map<String, dynamic> params() => <String, dynamic>{
        ..._readFilter().rangeParams(),
        'sort': sort,
        'page': page,
        'page_size': kReportPageSize,
      };

  @override
  ProductReportPage parse(Map<String, dynamic> json) =>
      ProductReportPage.fromJson(json);

  void setSort(String value) {
    sort = value;
    page = 1;
    load();
  }

  void setPage(int value) {
    page = value < 1 ? 1 : value;
    load();
  }
}

final productsProvider = StateNotifierProvider<ProductsController,
    ReportTabState<ProductReportPage>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = ProductsController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R3 categories ---------------------------------------------------------

class CategoriesController extends ReportTabController<CategoryReportPage> {
  CategoriesController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  @override
  String get endpoint => 'categories';

  @override
  Map<String, dynamic> params() => _readFilter().rangeParams();

  @override
  CategoryReportPage parse(Map<String, dynamic> json) =>
      CategoryReportPage.fromJson(json);
}

final categoriesProvider = StateNotifierProvider<CategoriesController,
    ReportTabState<CategoryReportPage>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = CategoriesController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R4 daily --------------------------------------------------------------

class DailyController extends ReportTabController<DailyReportPage> {
  DailyController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  @override
  String get endpoint => 'daily';

  @override
  Map<String, dynamic> params() => _readFilter().rangeParams();

  @override
  DailyReportPage parse(Map<String, dynamic> json) =>
      DailyReportPage.fromJson(json);
}

final dailyProvider =
    StateNotifierProvider<DailyController, ReportTabState<DailyReportPage>>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = DailyController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R5 hourly -------------------------------------------------------------

class HourlyController extends ReportTabController<HourlyReportPage> {
  HourlyController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  @override
  String get endpoint => 'hourly';

  @override
  Map<String, dynamic> params() => _readFilter().rangeParams();

  @override
  HourlyReportPage parse(Map<String, dynamic> json) =>
      HourlyReportPage.fromJson(json);
}

final hourlyProvider =
    StateNotifierProvider<HourlyController, ReportTabState<HourlyReportPage>>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = HourlyController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R6 peak hours ---------------------------------------------------------

class PeakController extends ReportTabController<PeakHoursReport> {
  PeakController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  /// §11 `lookback_days` (1–90, default 30).
  int lookbackDays = 30;

  @override
  String get endpoint => 'peak-hours';

  @override
  Map<String, dynamic> params() => <String, dynamic>{
        'lookback_days': lookbackDays,
        if (_readFilter().deviceId?.isNotEmpty == true)
          'device_id': _readFilter().deviceId,
      };

  @override
  PeakHoursReport parse(Map<String, dynamic> json) =>
      PeakHoursReport.fromJson(json);

  void setLookback(int value) {
    lookbackDays = value < 1 ? 1 : (value > 90 ? 90 : value);
    load();
  }
}

final peakProvider =
    StateNotifierProvider<PeakController, ReportTabState<PeakHoursReport>>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = PeakController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  // Peak-hours only reacts to the device filter (its range is the
  // lookback window, §11).
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next &&
        controller.initialized &&
        previous?.deviceId != next.deviceId) {
      controller.load();
    }
  });
  return controller;
});

// --- R7 slow moving --------------------------------------------------------

class SlowMovingController extends ReportTabController<SlowMovingPage> {
  SlowMovingController(super.dio, super.locale);

  /// §11 `days` (1–365, default 30) and `threshold` (default 0).
  int days = 30;
  int threshold = 0;
  int page = 1;

  @override
  String get endpoint => 'slow-moving';

  @override
  Map<String, dynamic> params() => <String, dynamic>{
        'days': days,
        'threshold': threshold,
        'page': page,
        'page_size': kReportPageSize,
      };

  @override
  SlowMovingPage parse(Map<String, dynamic> json) =>
      SlowMovingPage.fromJson(json);

  void setDays(int value) {
    days = value < 1 ? 1 : (value > 365 ? 365 : value);
    page = 1;
    load();
  }

  void setThreshold(int value) {
    threshold = value < 0 ? 0 : value;
    page = 1;
    load();
  }

  void setPage(int value) {
    page = value < 1 ? 1 : value;
    load();
  }
}

final slowMovingProvider = StateNotifierProvider<SlowMovingController,
    ReportTabState<SlowMovingPage>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SlowMovingController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// --- R8 voided -------------------------------------------------------------

class VoidedController extends ReportTabController<VoidedReportPage> {
  VoidedController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;
  int page = 1;

  @override
  String get endpoint => 'voided';

  @override
  Map<String, dynamic> params() => <String, dynamic>{
        ..._readFilter().rangeParams(),
        'page': page,
        'page_size': kReportPageSize,
      };

  @override
  VoidedReportPage parse(Map<String, dynamic> json) =>
      VoidedReportPage.fromJson(json);

  void setPage(int value) {
    page = value < 1 ? 1 : value;
    load();
  }
}

final voidedProvider =
    StateNotifierProvider<VoidedController, ReportTabState<VoidedReportPage>>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = VoidedController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R9 sales detail -------------------------------------------------------

/// §8 R9 status filter values.
const List<String> kSalesStatuses = <String>['completed', 'void', 'all'];

/// §8 R9 payment-method filter values (`null`/`all` = no filter).
const List<String> kSalesPaymentMethods = <String>[
  'cash',
  'card',
  'partial',
  'credit',
];

class SalesController extends ReportTabController<SalesDetailPage> {
  SalesController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  /// `completed` (default) | `void` | `all` (§8 R9).
  String status = 'completed';

  /// `null` = all methods.
  String? paymentMethod;
  int page = 1;

  @override
  String get endpoint => 'sales';

  @override
  Map<String, dynamic> params() => <String, dynamic>{
        ..._readFilter().rangeParams(),
        'status': status,
        if (paymentMethod != null && paymentMethod!.isNotEmpty)
          'payment_method': paymentMethod,
        'page': page,
        'page_size': kReportPageSize,
      };

  @override
  SalesDetailPage parse(Map<String, dynamic> json) =>
      SalesDetailPage.fromJson(json);

  void setStatus(String value) {
    status = value;
    page = 1;
    load();
  }

  void setPaymentMethod(String? value) {
    paymentMethod = (value == null || value.isEmpty) ? null : value;
    page = 1;
    load();
  }

  void setPage(int value) {
    page = value < 1 ? 1 : value;
    load();
  }
}

final salesProvider =
    StateNotifierProvider<SalesController, ReportTabState<SalesDetailPage>>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = SalesController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});

// --- R13 suppliers ---------------------------------------------------------

class SuppliersReportController
    extends ReportTabController<SupplierReport> {
  SuppliersReportController(super.dio, super.locale, this._readFilter);

  final _FilterReader _readFilter;

  @override
  String get endpoint => 'suppliers';

  @override
  Map<String, dynamic> params() => _readFilter().rangeParams();

  @override
  SupplierReport parse(Map<String, dynamic> json) =>
      SupplierReport.fromJson(json);
}

final suppliersReportProvider = StateNotifierProvider<SuppliersReportController,
    ReportTabState<SupplierReport>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = SuppliersReportController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});
