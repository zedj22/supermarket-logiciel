// Loyalty data models (reward redesign).
//
// Every number here is parsed from a SERVER-computed payload: the client
// never derives balances, discounts or earned rewards on its own.
// Decimal fields arrive either as JSON numbers or as numeric strings
// depending on the serializer, so money parsing accepts both.
import 'package:flutter/foundation.dart';

import '../../core/number_format.dart';

/// Milestone fallback (display-only when the server omits
/// `min_reward_points`; mirrors the server's `POINTS_PER_REWARD`).
const int loyaltyPointsPerReward = 100;

/// Tolerant number parse: `40`, `40.5`, `'40.000'` and `null` all work.
double loyaltyNum(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim()) ?? 0;
}

/// Whole-number parse for counts coming from the server
/// (`available_rewards` is an int ≥ 0).
int loyaltyPoints(dynamic value) {
  final n = loyaltyNum(value);
  if (n <= 0) return 0;
  return n.round();
}

/// Compact points display: `60` → `"60"`, `0.5` → `"0.5"` (server points
/// may arrive quantized like `"60.000"`). Large counts are space-grouped.
String formatLoyaltyPoints(double value) {
  if (value == value.roundToDouble()) {
    return formatGrouped(value.toInt().toString());
  }
  final fixed = value.toStringAsFixed(2);
  return formatGrouped(
    fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), ''),
  );
}

/// `GET/PUT /api/v1/loyalty/settings` — the store's loyalty rules.
@immutable
class LoyaltySettings {
  const LoyaltySettings({
    required this.pointsEnabled,
    required this.pointsRate,
    required this.cashbackEnabled,
    required this.cashbackRate,
    required this.maxRewardDiscountPercent,
    required this.earnOnDebtSettlement,
    required this.amountPerPoint,
    required this.minRewardPoints,
  });

  /// Relative path of both endpoints (same Dio join convention as
  /// `StoreSettings.settingsPath`).
  static const String settingsPath = '/api/v1/loyalty/settings';

  final bool pointsEnabled;
  final double pointsRate;
  final bool cashbackEnabled;
  final double cashbackRate;

  /// Maximum percent a cashier may select when redeeming ONE reward;
  /// 0 parks reward redemption while earning continues.
  final double maxRewardDiscountPercent;
  final bool earnOnDebtSettlement;

  /// Merchant-facing earning rate: DA of a sale that buy ONE point
  /// (the inverse of [pointsRate], server-derived — the client shows it
  /// but never recomputes it).
  final double amountPerPoint;

  /// Points needed to unlock ONE reward (server-configured, 1..1e6).
  final int minRewardPoints;

  factory LoyaltySettings.fromJson(Map<String, dynamic> json) {
    return LoyaltySettings(
      pointsEnabled: json['points_enabled'] as bool? ?? false,
      pointsRate: loyaltyNum(json['points_rate']),
      cashbackEnabled: json['cashback_enabled'] as bool? ?? false,
      cashbackRate: loyaltyNum(json['cashback_rate']),
      maxRewardDiscountPercent:
          loyaltyNum(json['max_reward_discount_percent']),
      earnOnDebtSettlement: json['earn_on_debt_settlement'] as bool? ?? false,
      amountPerPoint: loyaltyNum(json['amount_per_point']),
      minRewardPoints: loyaltyPoints(
        json['min_reward_points'] ?? loyaltyPointsPerReward,
      ),
    );
  }

  /// Full body for `PUT /loyalty/settings` — a settings form is a single
  /// document, so every field is always sent (the endpoint accepts partial
  /// bodies, an all-fields update is simply the complete form).
  ///
  /// Both `points_rate` and `amount_per_point` are sent: the alias wins
  /// server-side, so a stale `points_rate` next to a freshly typed DA
  /// value can never override what the admin meant.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'points_enabled': pointsEnabled,
        'points_rate': pointsRate,
        'cashback_enabled': cashbackEnabled,
        'cashback_rate': cashbackRate,
        'max_reward_discount_percent': maxRewardDiscountPercent,
        'earn_on_debt_settlement': earnOnDebtSettlement,
        'amount_per_point': amountPerPoint,
        'min_reward_points': minRewardPoints,
      };

  LoyaltySettings copyWith({
    bool? pointsEnabled,
    double? pointsRate,
    bool? cashbackEnabled,
    double? cashbackRate,
    double? maxRewardDiscountPercent,
    bool? earnOnDebtSettlement,
    double? amountPerPoint,
    int? minRewardPoints,
  }) {
    return LoyaltySettings(
      pointsEnabled: pointsEnabled ?? this.pointsEnabled,
      pointsRate: pointsRate ?? this.pointsRate,
      cashbackEnabled: cashbackEnabled ?? this.cashbackEnabled,
      cashbackRate: cashbackRate ?? this.cashbackRate,
      maxRewardDiscountPercent:
          maxRewardDiscountPercent ?? this.maxRewardDiscountPercent,
      earnOnDebtSettlement: earnOnDebtSettlement ?? this.earnOnDebtSettlement,
      amountPerPoint: amountPerPoint ?? this.amountPerPoint,
      minRewardPoints: minRewardPoints ?? this.minRewardPoints,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LoyaltySettings &&
          other.pointsEnabled == pointsEnabled &&
          other.pointsRate == pointsRate &&
          other.cashbackEnabled == cashbackEnabled &&
          other.cashbackRate == cashbackRate &&
          other.maxRewardDiscountPercent == maxRewardDiscountPercent &&
          other.earnOnDebtSettlement == earnOnDebtSettlement &&
          other.amountPerPoint == amountPerPoint &&
          other.minRewardPoints == minRewardPoints);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        pointsEnabled,
        pointsRate,
        cashbackEnabled,
        cashbackRate,
        maxRewardDiscountPercent,
        earnOnDebtSettlement,
        amountPerPoint,
        minRewardPoints,
      ]);
}

/// `GET /api/v1/customers/{id}/loyalty` — server-computed balances.
@immutable
class LoyaltyBalance {
  const LoyaltyBalance({
    required this.customerId,
    required this.hasAccount,
    required this.pointsBalance,
    required this.cashbackBalance,
    required this.availableRewards,
    required this.remainingPoints,
    required this.minRewardPoints,
  });

  final String customerId;
  final bool hasAccount;
  final double pointsBalance;
  final double cashbackBalance;

  /// Whole rewards unlocked by the balance (server-derived — the client
  /// never reimplements the milestone rule).
  final int availableRewards;

  /// Points held beyond whole rewards: [0, minRewardPoints).
  final double remainingPoints;

  /// Points needed to unlock ONE reward (server-configured).
  final int minRewardPoints;

  factory LoyaltyBalance.fromJson(Map<String, dynamic> json) {
    final points = loyaltyNum(json['points_balance']);
    final minPoints = loyaltyPoints(
      json['min_reward_points'] ?? loyaltyPointsPerReward,
    );
    return LoyaltyBalance(
      customerId: '${json['customer_id'] ?? ''}',
      hasAccount: json['has_account'] as bool? ?? false,
      pointsBalance: points,
      cashbackBalance: loyaltyNum(json['cashback_balance']),
      availableRewards: loyaltyPoints(json['available_rewards']),
      remainingPoints: json['remaining_points'] != null
          ? loyaltyNum(json['remaining_points'])
          : points % minPoints,
      minRewardPoints: minPoints,
    );
  }
}

/// `POST /api/v1/loyalty/preview` — authoritative cart preview.
@immutable
class LoyaltyPreview {
  const LoyaltyPreview({
    required this.customerId,
    required this.grossTotal,
    required this.rewardPercent,
    required this.rewardDiscount,
    required this.amountDue,
    required this.availableRewards,
    required this.remainingPoints,
    required this.minRewardPoints,
    required this.rewardEligible,
    required this.maxRewardDiscountPercent,
    required this.pointsBalance,
    required this.cashbackBalance,
    required this.pointsEarned,
    required this.cashbackEarned,
    required this.pointsAfterSale,
  });

  final String customerId;
  final double grossTotal;

  /// Percent the cashier selected (0 = none) — echoed by the server.
  final double rewardPercent;

  /// DA discount the server derived for that percent (0 when none).
  final double rewardDiscount;

  /// grossTotal − rewardDiscount: what the payment must cover.
  final double amountDue;

  /// Whole rewards unlocked by the balance right now.
  final int availableRewards;

  /// Points held beyond whole rewards: [0, minRewardPoints).
  final double remainingPoints;

  /// Points needed to unlock ONE reward (server-configured).
  final int minRewardPoints;

  /// May this customer spend a reward on THIS cart: the milestone is
  /// HELD, or THIS SALE's own earning reaches it (first-purchase
  /// redemption). Server-derived — the client only renders it.
  final bool rewardEligible;

  /// Owner-configured cap for the percent selector (0 = parked/disabled).
  final double maxRewardDiscountPercent;
  final double pointsBalance;
  final double cashbackBalance;
  final double pointsEarned;
  final double cashbackEarned;

  /// pointsBalance + pointsEarned (server-computed).
  final double pointsAfterSale;

  factory LoyaltyPreview.fromJson(Map<String, dynamic> json) {
    return LoyaltyPreview(
      customerId: '${json['customer_id'] ?? ''}',
      grossTotal: loyaltyNum(json['gross_total']),
      rewardPercent: loyaltyNum(json['reward_percent']),
      rewardDiscount: loyaltyNum(json['reward_discount']),
      amountDue: loyaltyNum(json['amount_due']),
      availableRewards: loyaltyPoints(json['available_rewards']),
      remainingPoints: loyaltyNum(json['remaining_points']),
      minRewardPoints: loyaltyPoints(
        json['min_reward_points'] ?? loyaltyPointsPerReward,
      ),
      rewardEligible: json['reward_eligible'] as bool? ?? false,
      maxRewardDiscountPercent:
          loyaltyNum(json['max_reward_discount_percent']),
      pointsBalance: loyaltyNum(json['points_balance']),
      cashbackBalance: loyaltyNum(json['cashback_balance']),
      pointsEarned: loyaltyNum(json['points_earned']),
      cashbackEarned: loyaltyNum(json['cashback_earned']),
      pointsAfterSale: loyaltyNum(json['points_after_sale']),
    );
  }
}

/// One append-only loyalty ledger row
/// (`GET /api/v1/customers/{id}/loyalty/history`).
@immutable
class LoyaltyLedgerEntry {
  const LoyaltyLedgerEntry({
    required this.id,
    required this.eventType,
    required this.pointsDelta,
    required this.cashbackDelta,
    required this.balanceAfterPoints,
    required this.balanceAfterCashback,
    this.note,
    this.saleId,
    this.invoiceNumber,
    this.returnId,
    this.createdAt,
  });

  final String id;
  final String eventType;
  final double pointsDelta;
  final double cashbackDelta;
  final double balanceAfterPoints;
  final double balanceAfterCashback;
  final String? note;
  final String? saleId;
  final String? invoiceNumber;
  final String? returnId;
  final DateTime? createdAt;

  factory LoyaltyLedgerEntry.fromJson(Map<String, dynamic> json) {
    return LoyaltyLedgerEntry(
      id: '${json['id'] ?? ''}',
      eventType: '${json['event_type'] ?? ''}',
      pointsDelta: loyaltyNum(json['points_delta']),
      cashbackDelta: loyaltyNum(json['cashback_delta']),
      balanceAfterPoints: loyaltyNum(json['balance_after_points']),
      balanceAfterCashback: loyaltyNum(json['balance_after_cashback']),
      note: json['note'] as String?,
      saleId: json['sale_id'] as String?,
      invoiceNumber: json['invoice_number'] as String?,
      returnId: json['return_id'] as String?,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse('${json['created_at']}'),
    );
  }
}

/// Paginated loyalty history page.
@immutable
class LoyaltyHistoryPage {
  const LoyaltyHistoryPage({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pages = 1,
  });

  final List<LoyaltyLedgerEntry> items;
  final int total;
  final int page;
  final int pages;

  factory LoyaltyHistoryPage.fromJson(Map<String, dynamic> json) {
    return LoyaltyHistoryPage(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => LoyaltyLedgerEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Translation key for one ledger `event_type` (dynamic family checked by
/// `localization_coverage_test.dart`: `loyalty_event_<type>` must exist in
/// all three locales for every value of `LEDGER_EVENT_TYPES`).
String loyaltyEventTypeKey(String eventType) => 'loyalty_event_$eventType';
