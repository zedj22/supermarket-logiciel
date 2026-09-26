/// Customer / debt models (Phase 9).
///
/// Money fields are decimal STRINGS (Phase 8 convention: `balance:
/// '120.500'`) — never parsed to double for arithmetic. Use
/// [moneyToMilli] / [formatMoney] for exact 3-decimal math.
library;

class CustomerModel {
  final String id;
  final String name;
  final String? phone;
  final String? address;

  /// Cached ledger projection as a decimal string, e.g. `'1500.000'`.
  final String balance;

  /// Credit ceiling as a decimal string. Stored/validated only — the
  /// backend never enforces it during checkout (Phase 9 decision gate).
  final String debtCeiling;
  final bool isArchived;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const CustomerModel({
    required this.id,
    required this.name,
    this.phone,
    this.address,
    this.balance = '0',
    this.debtCeiling = '0',
    this.isArchived = false,
    this.createdAt,
    this.updatedAt,
  });

  factory CustomerModel.fromJson(Map<String, dynamic> json) {
    return CustomerModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      balance: '${json['balance'] ?? 0}',
      debtCeiling: '${json['debt_ceiling'] ?? 0}',
      isArchived: json['is_archived'] as bool? ?? false,
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }

  /// True when the customer owes anything (drives the payment action).
  bool get hasDebt => moneyToMilli(balance) != null && moneyToMilli(balance)! > 0;
}

/// One append-only debt ledger row.
class DebtEntryModel {
  final String id;
  final String customerId;

  /// `sale` (debt incurred) | `payment` (debt reduced) | `adjustment`.
  final String entryType;
  final String amount;
  final String? note;
  final String? referenceSaleId;
  final String? invoiceNumber;
  final String? userId;
  final String? userName;
  final DateTime? entryDate;

  /// Running debt balance AFTER this entry (computed server-side from
  /// the full ledger: sale +, payment -, adjustment 0). Null when the
  /// API does not provide it.
  final String? balanceAfter;

  const DebtEntryModel({
    required this.id,
    required this.customerId,
    required this.entryType,
    required this.amount,
    this.note,
    this.referenceSaleId,
    this.invoiceNumber,
    this.userId,
    this.userName,
    this.entryDate,
    this.balanceAfter,
  });

  factory DebtEntryModel.fromJson(Map<String, dynamic> json) {
    return DebtEntryModel(
      id: json['id'] as String,
      customerId: json['customer_id'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? '',
      amount: '${json['amount'] ?? 0}',
      note: json['note'] as String?,
      referenceSaleId: json['reference_sale_id'] as String?,
      invoiceNumber: json['invoice_number'] as String?,
      userId: json['user_id'] as String?,
      userName: json['user_name'] as String?,
      entryDate: DateTime.tryParse('${json['entry_date'] ?? ''}'),
      balanceAfter: json['balance_after'] as String?,
    );
  }
}

/// POST /api/v1/customers/{id}/pay result.
class DebtPaymentResult {
  final String id;
  final String customerId;
  final String entryType;
  final String amount;

  /// Customer balance after this command (current balance on replay).
  final String balance;
  final String? note;
  final String? clientRequestId;
  final DateTime? entryDate;
  final bool idempotentReplay;

  const DebtPaymentResult({
    required this.id,
    required this.customerId,
    required this.entryType,
    required this.amount,
    required this.balance,
    this.note,
    this.clientRequestId,
    this.entryDate,
    this.idempotentReplay = false,
  });

  factory DebtPaymentResult.fromJson(Map<String, dynamic> json) {
    return DebtPaymentResult(
      id: json['id'] as String,
      customerId: json['customer_id'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? 'payment',
      amount: '${json['amount'] ?? 0}',
      balance: '${json['balance'] ?? 0}',
      note: json['note'] as String?,
      clientRequestId: json['client_request_id'] as String?,
      entryDate: DateTime.tryParse('${json['entry_date'] ?? ''}'),
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
    );
  }
}

/// GET /api/v1/debts/summary result.
class DebtSummaryModel {
  final String totalDebt;
  final int customersWithDebt;

  const DebtSummaryModel({
    required this.totalDebt,
    required this.customersWithDebt,
  });

  factory DebtSummaryModel.fromJson(Map<String, dynamic> json) {
    return DebtSummaryModel(
      totalDebt: '${json['total_debt'] ?? 0}',
      customersWithDebt: json['customers_with_debt'] as int? ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Exact decimal helpers (thousandths of the currency unit)
// ---------------------------------------------------------------------------

final RegExp _moneyPattern = RegExp(r'^(\d+)(?:\.(\d{1,3}))?$');

/// Parses a money string to integer thousandths without floating point.
///
/// `'120.500'` → `120500`, `'7'` → `7000`. Returns null for empty,
/// negative, or more-than-3-decimal input (reject instead of rounding
/// client-side — the backend is authoritative).
int? moneyToMilli(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final match = _moneyPattern.firstMatch(value);
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null) return null;
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  final frac = int.tryParse(fraction);
  if (frac == null) return null;
  return whole * 1000 + frac;
}

/// Renders thousandths back to a money string: `120500` → `'120.500'`.
String milliToMoney(int milli) {
  final negative = milli < 0;
  final abs = milli.abs();
  final whole = abs ~/ 1000;
  final fraction = (abs % 1000).toString().padLeft(3, '0');
  return '${negative ? '-' : ''}$whole.$fraction';
}

/// Display form without trailing zeros: `'300.000'` → `'300'`,
/// `'120.500'` → `'120.5'`.
String formatMoney(String raw) {
  final value = raw.trim();
  if (!value.contains('.')) return value;
  return value.replaceFirst(RegExp(r'\.?0+$'), '');
}
