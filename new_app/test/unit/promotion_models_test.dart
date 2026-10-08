// Phase 18 promotion model tests — parsing + display helpers.
//
// Money stays a decimal STRING end to end: the models never recompute a
// promotional price, they only carry what the API returned
// (`ProductModel.promotion.price` is the server's number).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/promotions/promotion_models.dart';

void main() {
  group('PromotionItem.fromJson', () {
    test('parses a full payload', () {
      final item = PromotionItem.fromJson({
        'id': 'promo-1',
        'name': 'Ramadan sale',
        'promotion_type': 'percentage',
        'value': '20.000',
        'is_active': true,
        'products': [
          {'id': 'p1', 'name': 'Rice'},
          {'id': 'p2', 'name': 'Sugar'},
        ],
        'product_ids': ['p1', 'p2'],
        'product_count': 2,
        'client_request_id': 'req-1',
        'created_at': '2026-10-01T10:00:00Z',
        'updated_at': '2026-10-02T10:00:00Z',
        'idempotent_replay': false,
      });

      expect(item.id, 'promo-1');
      expect(item.name, 'Ramadan sale');
      expect(item.promotionType, 'percentage');
      expect(item.value, '20.000');
      expect(item.isActive, isTrue);
      expect(item.isPercentage, isTrue);
      expect(item.products.map((p) => p.id), ['p1', 'p2']);
      expect(item.products.first.name, 'Rice');
      expect(item.productIds, ['p1', 'p2']);
      expect(item.productCount, 2);
      expect(item.clientRequestId, 'req-1');
      expect(item.createdAt, isNotNull);
      expect(item.updatedAt, isNotNull);
      expect(item.idempotentReplay, isFalse);
    });

    test('tolerates a minimal payload (server defaults)', () {
      final item = PromotionItem.fromJson(const {
        'id': 'promo-2',
        'name': 'Clearance',
        'promotion_type': 'fixed_price',
        'value': '150',
        'is_active': false,
      });

      expect(item.promotionType, 'fixed_price');
      expect(item.isPercentage, isFalse);
      expect(item.isActive, isFalse);
      expect(item.products, isEmpty);
      expect(item.productIds, isEmpty);
      // product_count falls back to the ref list length (0).
      expect(item.productCount, 0);
      expect(item.idempotentReplay, isFalse);
    });

    test('product_count wins over the products list length when present', () {
      final item = PromotionItem.fromJson(const {
        'id': 'p',
        'name': 'n',
        'promotion_type': 'percentage',
        'value': '10',
        'is_active': true,
        'products': <Map<String, dynamic>>[],
        'product_count': 7,
      });
      expect(item.productCount, 7);
    });
  });

  group('promotionValueLabel', () {
    test('percentage renders without trailing zeros', () {
      final percent = PromotionItem.fromJson(const {
        'id': 'p',
        'name': 'n',
        'promotion_type': 'percentage',
        'value': '20.000',
        'is_active': true,
      });
      expect(promotionValueLabel(percent), '20%');

      final fractional = PromotionItem.fromJson(const {
        'id': 'p',
        'name': 'n',
        'promotion_type': 'percentage',
        'value': '12.500',
        'is_active': true,
      });
      expect(promotionValueLabel(fractional), '12.5%');
    });

    test('fixed price renders as money', () {
      final fixed = PromotionItem.fromJson(const {
        'id': 'p',
        'name': 'n',
        'promotion_type': 'fixed_price',
        'value': '150.500',
        'is_active': true,
      });
      expect(promotionValueLabel(fixed), '150.5');
    });
  });

  group('promotionTypeKey', () {
    test('maps backend type codes to localization keys', () {
      expect(promotionTypeKey('percentage'), 'promotion_type_percentage');
      expect(promotionTypeKey('fixed_price'), 'promotion_type_fixed_price');
    });
  });

  group('PromotionListPage.fromJson', () {
    test('parses the paginated envelope', () {
      final page = PromotionListPage.fromJson(const {
        'items': [
          {
            'id': 'promo-1',
            'name': 'A',
            'promotion_type': 'percentage',
            'value': '10',
            'is_active': true,
          },
          {
            'id': 'promo-2',
            'name': 'B',
            'promotion_type': 'fixed_price',
            'value': '99',
            'is_active': false,
          },
        ],
        'total': 12,
        'page': 2,
        'page_size': 40,
        'pages': 1,
      });

      expect(page.items, hasLength(2));
      expect(page.items.first.id, 'promo-1');
      expect(page.items.last.isActive, isFalse);
      expect(page.total, 12);
      expect(page.page, 2);
      expect(page.pageSize, 40);
      expect(page.pages, 1);
    });

    test('an empty body yields an empty first page', () {
      final page = PromotionListPage.fromJson(const {});
      expect(page.items, isEmpty);
      expect(page.total, 0);
      expect(page.page, 1);
      expect(page.pages, 1);
    });
  });

  group('ProductPromotionInfo (product response attachment)', () {
    test('parses the server-computed effective price', () {
      final info = ProductPromotionInfo.fromJson(const {
        'id': 'promo-1',
        'name': 'Ramadan sale',
        'promotion_type': 'percentage',
        'value': '20.000',
        'price': '80.000',
      });

      expect(info.id, 'promo-1');
      expect(info.isPercentage, isTrue);
      expect(info.price, '80.000',
          reason: 'the SERVER number passes through untouched');
    });

    test('discountBadgeFor: percentage against retail', () {
      const info = ProductPromotionInfo(
        id: 'p',
        name: 'n',
        promotionType: 'percentage',
        value: '20',
        price: '80',
      );
      expect(info.discountBadgeFor('100'), '-20%');
      expect(info.discountBadgeFor('0'), '', reason: 'retail 0 → no badge');
    });

    test('discountBadgeFor: fixed price computes the percent off', () {
      const info = ProductPromotionInfo(
        id: 'p',
        name: 'n',
        promotionType: 'fixed_price',
        value: '80',
        price: '80',
      );
      expect(info.discountBadgeFor('100'), '-20%');
      // A fixed price AT retail (or above — the backend clamps to retail)
      // is not a visible discount: no badge, never a price increase.
      const noDiscount = ProductPromotionInfo(
        id: 'p',
        name: 'n',
        promotionType: 'fixed_price',
        value: '120',
        price: '120',
      );
      expect(noDiscount.discountBadgeFor('100'), '');
    });
  });
}
