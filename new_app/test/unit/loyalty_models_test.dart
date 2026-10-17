// Phase E — loyalty model parsing + ledger-event label existence.
//
// Every field here comes from a SERVER payload; the tests pin the tolerant
// parse behaviour (numbers vs numeric strings vs null) and the dynamic
// `loyalty_event_<type>` key family that the coverage test registers.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_models.dart';

void main() {
  group('loyaltyNum', () {
    test('accepts num, numeric string and null', () {
      expect(loyaltyNum(40), 40.0);
      expect(loyaltyNum('40.5'), 40.5);
      expect(loyaltyNum(' 60.000 '), 60.0);
      expect(loyaltyNum(null), 0);
      expect(loyaltyNum('garbage'), 0);
    });
  });

  group('loyaltyPoints', () {
    test('rounds to whole non-negative int only', () {
      expect(loyaltyPoints(60.4), 60);
      expect(loyaltyPoints('59.9'), 60);
      expect(loyaltyPoints(-5), 0);
      expect(loyaltyPoints(null), 0);
      expect(loyaltyPoints('abc'), 0);
    });
  });

  group('formatLoyaltyPoints', () {
    test('strips quantized trailing zeros', () {
      expect(formatLoyaltyPoints(60), '60');
      expect(formatLoyaltyPoints(0.5), '0.5');
      expect(formatLoyaltyPoints(60.000), '60');
    });
  });

  group('loyaltyEventTypeKey', () {
    test('builds the coverage family key', () {
      expect(loyaltyEventTypeKey('sale_earn'), 'loyalty_event_sale_earn');
    });

    test('every backend ledger event type resolves in all 3 locales', () {
      // Mirrors LEDGER_EVENT_TYPES in app/models/loyalty.py — the Flutter
      // side only ever needs the label key to exist.
      const types = <String>{
        'sale_earn',
        'debt_settlement_earn',
        'redeem',
        'return_clawback',
        'void_clawback',
        'adjustment',
        'expiry',
      };
      for (final type in types) {
        final key = loyaltyEventTypeKey(type);
        for (final locale in <String>{'ar', 'fr', 'en'}) {
          final label = AppStrings.t(key, locale);
          expect(label, isNot(key), reason: '$key missing in $locale');
        }
      }
    });
  });

  group('LoyaltySettings', () {
    test('fromJson/toJson round-trips every field', () {
      final settings = LoyaltySettings.fromJson(const {
        'points_enabled': true,
        'points_rate': '0.010',
        'cashback_enabled': false,
        'cashback_rate': '1.000',
        'max_reward_discount_percent': '20.000',
        'earn_on_debt_settlement': true,
        'amount_per_point': '100.000',
        'min_reward_points': '100',
      });
      expect(settings.pointsEnabled, isTrue);
      expect(settings.pointsRate, 0.01);
      expect(settings.cashbackEnabled, isFalse);
      expect(settings.maxRewardDiscountPercent, 20.0);
      expect(settings.earnOnDebtSettlement, isTrue);
      expect(settings.amountPerPoint, 100.0);
      expect(settings.minRewardPoints, 100);

      final back = LoyaltySettings.fromJson(settings.toJson());
      expect(back, settings);
    });

    test('legacy payload without the new fields falls back sensibly', () {
      final settings = LoyaltySettings.fromJson(const {
        'points_enabled': true,
        'points_rate': '0.010',
        'cashback_enabled': false,
        'cashback_rate': '1.000',
        'max_reward_discount_percent': '20.000',
        'earn_on_debt_settlement': true,
      });
      expect(settings.amountPerPoint, 0.0);
      expect(settings.minRewardPoints, 100);
    });

    test('toJson always carries both rate and the DA-per-point alias', () {
      const base = LoyaltySettings(
        pointsEnabled: true,
        pointsRate: 0.01,
        cashbackEnabled: false,
        cashbackRate: 1,
        maxRewardDiscountPercent: 20,
        earnOnDebtSettlement: true,
        amountPerPoint: 100,
        minRewardPoints: 100,
      );
      final body = base.toJson();
      expect(body['points_rate'], 0.01);
      expect(body['amount_per_point'], 100.0);
      expect(body['min_reward_points'], 100);
    });

    test('copyWith + equality are value-based', () {
      const base = LoyaltySettings(
        pointsEnabled: true,
        pointsRate: 0.01,
        cashbackEnabled: false,
        cashbackRate: 1,
        maxRewardDiscountPercent: 20,
        earnOnDebtSettlement: true,
        amountPerPoint: 100,
        minRewardPoints: 100,
      );
      final tweaked =
          base.copyWith(pointsEnabled: false, pointsRate: 0.02);
      expect(tweaked, isNot(base));
      expect(tweaked.copyWith(pointsEnabled: true, pointsRate: 0.01), base);
    });
  });

  group('LoyaltyBalance', () {
    test('parses server-computed balances', () {
      final balance = LoyaltyBalance.fromJson(const {
        'customer_id': 'c-1',
        'has_account': true,
        'points_balance': '60.000',
        'cashback_balance': '12.500',
        'available_rewards': 0,
        'remaining_points': '60.000',
        'min_reward_points': '100',
      });
      expect(balance.customerId, 'c-1');
      expect(balance.hasAccount, isTrue);
      expect(balance.pointsBalance, 60.0);
      expect(balance.cashbackBalance, 12.5);
      expect(balance.availableRewards, 0);
      expect(balance.remainingPoints, 60.0);
      expect(balance.minRewardPoints, 100);
    });

    test('milestone split: 130 points -> 1 reward + 30 remaining', () {
      final balance = LoyaltyBalance.fromJson(const {
        'customer_id': 'c-2',
        'has_account': true,
        'points_balance': '130.000',
        'cashback_balance': '0.000',
        'available_rewards': 1,
        'remaining_points': '30.000',
        'min_reward_points': '100',
      });
      expect(balance.availableRewards, 1);
      expect(balance.remainingPoints, 30.0);
    });

    test('legacy payload without remaining_points falls back to mod 100',
        () {
      final balance = LoyaltyBalance.fromJson(const {
        'customer_id': 'c-3',
        'has_account': true,
        'points_balance': '230.000',
        'cashback_balance': '0.000',
        'available_rewards': 2,
      });
      expect(balance.remainingPoints, 30.0);
      expect(balance.minRewardPoints, 100);
    });
  });

  group('LoyaltyPreview', () {
    test('parses every field', () {
      final preview = LoyaltyPreview.fromJson(const {
        'customer_id': 'c-1',
        'gross_total': '100.00',
        'reward_percent': '20.000',
        'reward_discount': '20.000',
        'amount_due': '80.000',
        'available_rewards': 1,
        'remaining_points': '30.000',
        'min_reward_points': '100',
        'reward_eligible': true,
        'max_reward_discount_percent': '20.000',
        'points_balance': '130.000',
        'cashback_balance': '0.000',
        'points_earned': '0.800',
        'cashback_earned': '0.000',
        'points_after_sale': '130.800',
      });
      expect(preview.rewardPercent, 20.0);
      expect(preview.rewardDiscount, 20.0);
      expect(preview.amountDue, 80.0);
      expect(preview.availableRewards, 1);
      expect(preview.remainingPoints, 30.0);
      expect(preview.minRewardPoints, 100);
      expect(preview.rewardEligible, isTrue);
      expect(preview.maxRewardDiscountPercent, 20.0);
      expect(preview.pointsEarned, 0.8);
      expect(preview.pointsAfterSale, 130.8);
    });

    test('no reward selected parses as zero percent/discount', () {
      final preview = LoyaltyPreview.fromJson(const {
        'customer_id': 'c-1',
        'gross_total': '100.00',
        'reward_percent': '0',
        'reward_discount': '0',
        'amount_due': '100.00',
        'available_rewards': 1,
        'remaining_points': '30.000',
        'min_reward_points': '100',
        'reward_eligible': true,
        'max_reward_discount_percent': '20.000',
        'points_balance': '130.000',
        'cashback_balance': '0.000',
        'points_earned': '1.000',
        'cashback_earned': '0.000',
        'points_after_sale': '131.000',
      });
      expect(preview.rewardPercent, 0);
      expect(preview.rewardDiscount, 0);
      expect(preview.amountDue, 100.0);
    });

    test('legacy payload without the new fields falls back sensibly', () {
      final preview = LoyaltyPreview.fromJson(const {
        'customer_id': 'c-1',
        'gross_total': '100.00',
        'reward_percent': '0',
        'reward_discount': '0',
        'amount_due': '100.00',
        'available_rewards': 0,
        'remaining_points': '30.000',
        'max_reward_discount_percent': '20.000',
        'points_balance': '130.000',
        'cashback_balance': '0.000',
        'points_earned': '1.000',
        'cashback_earned': '0.000',
      });
      expect(preview.minRewardPoints, 100);
      expect(preview.rewardEligible, isFalse);
      expect(preview.pointsAfterSale, 0.0);
    });
  });

  group('LoyaltyLedgerEntry', () {
    test('parses deltas, balances and optional references', () {
      final entry = LoyaltyLedgerEntry.fromJson(const {
        'id': 'e-1',
        'event_type': 'sale_earn',
        'points_delta': '10.000',
        'cashback_delta': '0.000',
        'balance_after_points': '70.000',
        'balance_after_cashback': '0.000',
        'note': null,
        'sale_id': 'sale-1',
        'invoice_number': 'INV-001',
        'return_id': null,
        'created_at': '2026-10-01T12:00:00Z',
      });
      expect(entry.eventType, 'sale_earn');
      expect(entry.pointsDelta, 10.0);
      expect(entry.balanceAfterPoints, 70.0);
      expect(entry.invoiceNumber, 'INV-001');
      expect(entry.createdAt, isNotNull);
      expect(entry.returnId, isNull);
    });
  });

  group('LoyaltyHistoryPage', () {
    test('parses a page of entries with pagination meta', () {
      final page = LoyaltyHistoryPage.fromJson(const {
        'items': [
          {
            'id': 'e-1',
            'event_type': 'redeem',
            'points_delta': '-60.000',
            'cashback_delta': '0.000',
            'balance_after_points': '0.000',
            'balance_after_cashback': '0.000',
          },
        ],
        'total': 1,
        'page': 1,
        'pages': 1,
      });
      expect(page.items, hasLength(1));
      expect(page.items.single.pointsDelta, -60.0);
      expect(page.total, 1);
    });

    test('empty payload yields an empty page, not a crash', () {
      final page = LoyaltyHistoryPage.fromJson(const {});
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });
  });
}
