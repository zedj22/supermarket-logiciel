// Phase 9 — customer/debt model parsing + exact decimal helpers.
//
// Money arrives from FastAPI as decimal strings ("300.000") and must
// never be routed through double arithmetic. moneyToMilli /
// milliToMoney / formatMoney are the ONLY conversion helpers the
// clients feature uses, so they carry the decimal-safety contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/clients/customer_models.dart';

void main() {
  group('moneyToMilli (exact, no floats)', () {
    test('parses whole and fractional values', () {
      expect(moneyToMilli('120.500'), 120500);
      expect(moneyToMilli('7'), 7000);
      expect(moneyToMilli('0'), 0);
      expect(moneyToMilli('0.001'), 1);
      expect(moneyToMilli('300.000'), 300000);
      expect(moneyToMilli('  42.5  '), 42500);
    });

    test('accepts 1-3 decimal places', () {
      expect(moneyToMilli('1.5'), 1500);
      expect(moneyToMilli('1.55'), 1550);
      expect(moneyToMilli('1.555'), 1555);
    });

    test('rejects invalid input instead of rounding', () {
      expect(moneyToMilli(''), isNull);
      expect(moneyToMilli('   '), isNull);
      expect(moneyToMilli('abc'), isNull);
      expect(moneyToMilli('1.2345'), isNull); // >3 dp — never silently round
      expect(moneyToMilli('-5'), isNull); // no negatives in client math
      expect(moneyToMilli('1.2.3'), isNull);
      expect(moneyToMilli('1,'), isNull);
      expect(moneyToMilli('NaN'), isNull);
    });
  });

  group('milliToMoney', () {
    test('renders three decimals', () {
      expect(milliToMoney(120500), '120.500');
      expect(milliToMoney(1), '0.001');
      expect(milliToMoney(0), '0.000');
      expect(milliToMoney(300000), '300.000');
    });

    test('round-trips with moneyToMilli', () {
      for (final raw in ['0', '0.001', '7', '42.5', '120.500', '999999.999']) {
        expect(milliToMoney(moneyToMilli(raw)!), isNotEmpty);
        expect(moneyToMilli(milliToMoney(moneyToMilli(raw)!)), moneyToMilli(raw));
      }
    });
  });

  group('formatMoney (display)', () {
    test('trims trailing zeros but keeps meaningful digits', () {
      expect(formatMoney('300.000'), '300');
      expect(formatMoney('120.500'), '120.5');
      expect(formatMoney('0.000'), '0');
      expect(formatMoney('120.050'), '120.05');
      expect(formatMoney('100'), '100');
      expect(formatMoney('0.001'), '0.001');
    });
  });

  group('CustomerModel', () {
    test('parses envelope fields, money as strings', () {
      final model = CustomerModel.fromJson({
        'id': 'c1',
        'name': 'Alice Market',
        'phone': '0555000001',
        'address': 'Rue 1',
        'balance': '1500.000',
        'debt_ceiling': '5000.000',
        'is_archived': false,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
      });
      expect(model.name, 'Alice Market');
      expect(model.balance, '1500.000');
      expect(model.debtCeiling, '5000.000');
      expect(model.isArchived, isFalse);
      expect(model.createdAt, isNotNull);
      expect(model.updatedAt, isNotNull);
    });

    test('defaults missing optional fields', () {
      final model = CustomerModel.fromJson({'id': 'c2', 'name': 'No Phone'});
      expect(model.phone, isNull);
      expect(model.address, isNull);
      expect(model.balance, '0');
      expect(model.debtCeiling, '0');
      expect(model.isArchived, isFalse);
    });

    test('hasDebt reflects strictly positive balance', () {
      CustomerModel withBalance(String value) => CustomerModel.fromJson(
            {'id': 'c', 'name': 'n', 'balance': value},
          );
      expect(withBalance('0.000').hasDebt, isFalse);
      expect(withBalance('0').hasDebt, isFalse);
      expect(withBalance('0.001').hasDebt, isTrue);
      expect(withBalance('1500.000').hasDebt, isTrue);
    });
  });

  group('DebtEntryModel', () {
    test('parses ledger row', () {
      final entry = DebtEntryModel.fromJson({
        'id': 'e1',
        'customer_id': 'c1',
        'entry_type': 'sale',
        'amount': '1500.000',
        'note': 'credit sale',
        'reference_sale_id': 's1',
        'invoice_number': 'INV-0001',
        'user_id': 'u1',
        'user_name': 'Admin',
        'entry_date': '2026-02-01T10:00:00Z',
        'balance_after': '1500.000',
      });
      expect(entry.entryType, 'sale');
      expect(entry.amount, '1500.000');
      expect(entry.invoiceNumber, 'INV-0001');
      expect(entry.userName, 'Admin');
      expect(entry.entryDate, isNotNull);
      expect(entry.balanceAfter, '1500.000');
    });

    test('balance_after is null when absent (older payload)', () {
      final entry = DebtEntryModel.fromJson({
        'id': 'e2',
        'customer_id': 'c1',
        'entry_type': 'payment',
        'amount': '100.000',
        'entry_date': '2026-02-02T10:00:00Z',
      });
      expect(entry.balanceAfter, isNull);
    });
  });

  group('DebtPaymentResult', () {
    test('parses pay response incl. idempotent replay flag', () {
      final result = DebtPaymentResult.fromJson({
        'id': 'p1',
        'customer_id': 'c1',
        'entry_type': 'payment',
        'amount': '500.000',
        'balance': '1000.000',
        'note': 'cash',
        'client_request_id': 'req-1',
        'entry_date': '2026-02-02T10:00:00Z',
        'idempotent_replay': true,
      });
      expect(result.amount, '500.000');
      expect(result.balance, '1000.000');
      expect(result.clientRequestId, 'req-1');
      expect(result.idempotentReplay, isTrue);
    });

    test('replay flag defaults to false', () {
      final result = DebtPaymentResult.fromJson({
        'id': 'p1',
        'customer_id': 'c1',
        'entry_type': 'payment',
        'amount': '1.000',
        'balance': '0.000',
      });
      expect(result.idempotentReplay, isFalse);
    });
  });

  group('DebtSummaryModel', () {
    test('parses AR summary', () {
      final summary = DebtSummaryModel.fromJson({
        'total_debt': '4500.000',
        'customers_with_debt': 3,
      });
      expect(summary.totalDebt, '4500.000');
      expect(summary.customersWithDebt, 3);
    });
  });
}
