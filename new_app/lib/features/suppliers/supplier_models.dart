/// Supplier + supplier-ledger models (Phase 11).
///
/// Money fields are decimal STRINGS (Phase 8 convention: `balance:
/// '1500.000'`) — never parsed to double for arithmetic. Exact
/// 3-decimal helpers (`moneyToMilli`, `milliToMoney`, `formatMoney`)
/// are re-exported from the Phase 9 client models — same semantics.
library;

import '../clients/customer_models.dart' show moneyToMilli;

export '../clients/customer_models.dart'
    show moneyToMilli, milliToMoney, formatMoney, formatMoneyPlain;

class SupplierModel {
  final String id;
  final String name;
  final String? phone;
  final String? address;
  final String? email;
  final String? contactPerson;
  final String? notes;

  /// Cached ledger projection as a decimal string, e.g. `'500.000'`.
  /// Read-only — the backend never accepts it on create/update.
  final String balance;
  final bool isArchived;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const SupplierModel({
    required this.id,
    required this.name,
    this.phone,
    this.address,
    this.email,
    this.contactPerson,
    this.notes,
    this.balance = '0',
    this.isArchived = false,
    this.createdAt,
    this.updatedAt,
  });

  factory SupplierModel.fromJson(Map<String, dynamic> json) {
    return SupplierModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      email: json['email'] as String?,
      contactPerson: json['contact_person'] as String?,
      notes: json['notes'] as String?,
      balance: '${json['balance'] ?? 0}',
      isArchived: json['is_archived'] as bool? ?? false,
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }

  /// True when anything is still owed to the supplier.
  bool get hasBalance =>
      moneyToMilli(balance) != null && moneyToMilli(balance)! > 0;
}

/// One append-only supplier payables ledger row.
class SupplierLedgerEntryModel {
  final String id;
  final String supplierId;

  /// `purchase` (+) | `payment` (-) | `purchase_cancel` (-, capped).
  final String entryType;
  final String amount;
  final String? note;
  final String? referencePurchaseId;
  final String? invoiceNumber;
  final String? userId;
  final String? userName;
  final DateTime? entryDate;

  /// Running supplier balance AFTER this entry (computed server-side
  /// from the full ledger, never stored).
  final String? balanceAfter;

  const SupplierLedgerEntryModel({
    required this.id,
    required this.supplierId,
    required this.entryType,
    required this.amount,
    this.note,
    this.referencePurchaseId,
    this.invoiceNumber,
    this.userId,
    this.userName,
    this.entryDate,
    this.balanceAfter,
  });

  factory SupplierLedgerEntryModel.fromJson(Map<String, dynamic> json) {
    return SupplierLedgerEntryModel(
      id: json['id'] as String,
      supplierId: json['supplier_id'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? '',
      amount: '${json['amount'] ?? 0}',
      note: json['note'] as String?,
      referencePurchaseId: json['reference_purchase_id'] as String?,
      invoiceNumber: json['invoice_number'] as String?,
      userId: json['user_id'] as String?,
      userName: json['user_name'] as String?,
      entryDate: DateTime.tryParse('${json['entry_date'] ?? ''}'),
      balanceAfter: json['balance_after'] as String?,
    );
  }
}

/// POST /api/v1/suppliers/{id}/payments result.
class SupplierPaymentResult {
  final String id;
  final String supplierId;
  final String entryType;
  final String amount;

  /// Supplier balance after this command (current balance on replay).
  final String balance;
  final String? note;
  final String? clientRequestId;
  final DateTime? entryDate;
  final bool idempotentReplay;

  const SupplierPaymentResult({
    required this.id,
    required this.supplierId,
    required this.entryType,
    required this.amount,
    required this.balance,
    this.note,
    this.clientRequestId,
    this.entryDate,
    this.idempotentReplay = false,
  });

  factory SupplierPaymentResult.fromJson(Map<String, dynamic> json) {
    return SupplierPaymentResult(
      id: json['id'] as String,
      supplierId: json['supplier_id'] as String? ?? '',
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
