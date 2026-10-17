// Filter-chip label regression tests.
//
// The facturation (client) and purchases (supplier) chips used to keep
// their label ONLY in the page's State, which does not survive
// navigation: the id stayed applied to the query, so the list kept
// filtering while the chip that revealed (and cleared) it disappeared.
// The label now travels with the id in the query itself — never sent to
// the server, purely display.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/facturation/facturation_providers.dart';
import 'package:supermarket_pos/features/purchases/purchases_providers.dart';

void main() {
  group('FacturationQuery client label', () {
    test('is stored with the id and dropped on clearClient', () {
      final seeded = const FacturationQuery(search: 'inv')
          .copyWith(clearClient: true, page: 1)
          .copyWith(clientId: 'c-1', clientName: 'ACME SARL');

      expect(seeded.search, 'inv');
      expect(seeded.clientId, 'c-1');
      expect(seeded.clientName, 'ACME SARL');
      expect(seeded.page, 1);

      final cleared = seeded.copyWith(clearClient: true);
      expect(cleared.clientId, isNull);
      expect(cleared.clientName, isNull);
    });

    test('a second client cannot inherit the first label', () {
      final first = const FacturationQuery()
          .copyWith(clearClient: true, page: 1)
          .copyWith(clientId: 'c-1', clientName: 'ACME');

      final second =
          first.copyWith(clearClient: true, page: 1).copyWith(clientId: 'c-2');

      expect(second.clientId, 'c-2');
      expect(second.clientName, isNull,
          reason: 'setClientFilter clears first, so labels never leak');
    });

    test('unrelated copyWith calls keep the label', () {
      const seeded = FacturationQuery(clientId: 'c-1', clientName: 'ACME');
      final paged = seeded.copyWith(page: 3);
      expect(paged.clientId, 'c-1');
      expect(paged.clientName, 'ACME');
    });
  });

  group('PurchasesQuery supplier label', () {
    test('is stored with the id and dropped on clearSupplier', () {
      final seeded = const PurchasesQuery(search: 'inv')
          .copyWith(clearSupplier: true, page: 1)
          .copyWith(supplierId: 's-1', supplierName: 'Atlas Distribution');

      expect(seeded.search, 'inv');
      expect(seeded.supplierId, 's-1');
      expect(seeded.supplierName, 'Atlas Distribution');
      expect(seeded.page, 1);

      final cleared = seeded.copyWith(clearSupplier: true);
      expect(cleared.supplierId, isNull);
      expect(cleared.supplierName, isNull);
    });

    test('a second supplier cannot inherit the first label', () {
      final first = const PurchasesQuery()
          .copyWith(clearSupplier: true, page: 1)
          .copyWith(supplierId: 's-1', supplierName: 'Atlas');

      final second =
          first.copyWith(clearSupplier: true, page: 1).copyWith(supplierId: 's-2');

      expect(second.supplierId, 's-2');
      expect(second.supplierName, isNull);
    });

    test('unrelated copyWith calls keep the label', () {
      const seeded =
          PurchasesQuery(supplierId: 's-1', supplierName: 'Atlas');
      final paged = seeded.copyWith(page: 4);
      expect(paged.supplierId, 's-1');
      expect(paged.supplierName, 'Atlas');
    });
  });
}
