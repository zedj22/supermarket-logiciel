// Phase 13 expense models.
//
// Money always arrives as a decimal STRING (Phase 0 money rule): the
// backend owns NUMERIC(18,3) and Flutter only renders what the API
// returned — it never recomputes a total.
//
// Lifecycle (GATE 1): `posted` → `cancelled`. Cancelled rows keep their
// amount, gain `cancelled_at` / `cancelled_by` / `cancel_reason`, and are
// hidden from the default list and summary (B11).
//
// The title is OPTIONAL (Fix Round 2): the API returns `null` when the
// expense was recorded without one, so `title` is `String?` and every
// renderer goes through [expenseTitleLabel] instead of printing `null`.

import '../../core/strings.dart';

/// Canonical `ExpenseCategory` codes exactly as the backend enum stores
/// them (never localized in the payload — fix for legacy defect L6).
const List<String> kExpenseCategories = <String>[
  'rent',
  'utilities',
  'salary',
  'maintenance',
  'supplies',
  'transport',
  'other',
];

/// Localization key for a category code (`category_<code>`).
String expenseCategoryKey(String code) => 'category_$code';

/// Localization key for a lifecycle status (`expense_status_<code>`).
String expenseStatusKey(String status) => 'expense_status_$status';

/// What a row / dialog prints for an expense title (Fix Round 2).
///
/// An expense may legitimately have no title (`null`, or blank after
/// trim) — never render an empty ListTile or the literal `null`; fall
/// back to the localized category label, which always exists.
String expenseTitleLabel(ExpenseItem expense, String loc) {
  final title = expense.title;
  if (title != null && title.trim().isNotEmpty) return title;
  return AppStrings.t(expenseCategoryKey(expense.category), loc);
}

/// One expense as `GET/POST /api/v1/expenses` returns it.
class ExpenseItem {
  final String id;
  final String? title;
  final String category;

  /// Decimal string, e.g. `'120.500'`.
  final String amount;

  /// Classification flag only — no cash ledger is touched (GATE 5).
  final bool paidFromDrawer;
  final String? note;
  final String status;
  final String? userId;
  final String? deviceId;
  final String? clientRequestId;
  final DateTime expenseDate;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final String? cancelReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool idempotentReplay;

  const ExpenseItem({
    required this.id,
    this.title,
    required this.category,
    required this.amount,
    required this.paidFromDrawer,
    this.note,
    required this.status,
    this.userId,
    this.deviceId,
    this.clientRequestId,
    required this.expenseDate,
    this.cancelledAt,
    this.cancelledBy,
    this.cancelReason,
    this.createdAt,
    this.updatedAt,
    this.idempotentReplay = false,
  });

  factory ExpenseItem.fromJson(Map<String, dynamic> json) {
    return ExpenseItem(
      id: '${json['id'] ?? ''}',
      title: json['title'] as String?,
      category: '${json['category'] ?? 'other'}',
      amount: '${json['amount'] ?? 0}',
      paidFromDrawer: json['paid_from_drawer'] as bool? ?? true,
      note: json['note'] as String?,
      status: '${json['status'] ?? 'posted'}',
      userId: json['user_id'] as String?,
      deviceId: json['device_id'] as String?,
      clientRequestId: json['client_request_id'] as String?,
      expenseDate:
          DateTime.tryParse('${json['expense_date']}') ?? DateTime.now(),
      cancelledAt: json['cancelled_at'] == null
          ? null
          : DateTime.tryParse('${json['cancelled_at']}'),
      cancelledBy: json['cancelled_by'] as String?,
      cancelReason: json['cancel_reason'] as String?,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse('${json['created_at']}'),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse('${json['updated_at']}'),
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
    );
  }

  bool get isCancelled => status == 'cancelled';
}

/// One page of `GET /api/v1/expenses`.
class ExpenseListPage {
  final List<ExpenseItem> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const ExpenseListPage({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 25,
    this.pages = 1,
  });

  factory ExpenseListPage.fromJson(Map<String, dynamic> json) {
    return ExpenseListPage(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => ExpenseItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      pageSize: json['page_size'] as int? ?? 25,
      pages: json['pages'] as int? ?? 1,
    );
  }
}

/// `GET /api/v1/expenses/summary` — count / total / drawer / external.
///
/// `drawerAmount + externalAmount == totalAmount` by construction, and
/// cancelled rows are excluded unless the caller asked for them (B11).
class ExpenseSummary {
  final int count;
  final String totalAmount;
  final String drawerAmount;
  final String externalAmount;

  const ExpenseSummary({
    this.count = 0,
    this.totalAmount = '0',
    this.drawerAmount = '0',
    this.externalAmount = '0',
  });

  factory ExpenseSummary.fromJson(Map<String, dynamic> json) {
    return ExpenseSummary(
      count: json['count'] as int? ?? 0,
      totalAmount: '${json['total_amount'] ?? 0}',
      drawerAmount: '${json['drawer_amount'] ?? 0}',
      externalAmount: '${json['external_amount'] ?? 0}',
    );
  }
}
