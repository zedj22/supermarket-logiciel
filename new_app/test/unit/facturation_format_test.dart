// Phase 10 Stage C-1 — presentation formatter unit tests.
//
// Covers formatDisplayDate / formatDisplayMoney and locks the existing
// formatMoney / milliToMoney / moneyToMilli contracts (including comma
// rejection) so presentation changes cannot silently alter fiscal math.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/clients/customer_models.dart';
import 'package:supermarket_pos/features/facturation/facturation_format.dart';

void main() {
  group('formatDisplayDate', () {
    test('renders DD/MM/YYYY with Latin digits in ar, fr, en', () {
      expect(formatDisplayDate('2026-03-15', 'ar'), '15/03/2026');
      expect(formatDisplayDate('2026-03-15', 'fr'), '15/03/2026');
      expect(formatDisplayDate('2026-03-15', 'en'), '15/03/2026');
    });

    test('zero-pads single-digit day and month', () {
      expect(formatDisplayDate('2026-01-05', 'en'), '05/01/2026');
      expect(formatDisplayDate('2026-12-09', 'fr'), '09/12/2026');
      expect(formatDisplayDate('2026-01-01', 'ar'), '01/01/2026');
    });

    test('returns empty string for empty input', () {
      expect(formatDisplayDate('', 'en'), '');
      expect(formatDisplayDate('   ', 'fr'), '');
    });

    test('passes through invalid input unchanged', () {
      expect(formatDisplayDate('not-a-date', 'en'), 'not-a-date');
      expect(formatDisplayDate('2026-3-5', 'en'), '2026-3-5');
      expect(
        formatDisplayDate('2026-03-15T10:00:00Z', 'en'),
        '2026-03-15T10:00:00Z',
      );
      expect(formatDisplayDate('15/03/2026', 'en'), '15/03/2026');
    });

    test('trims surrounding whitespace before formatting', () {
      expect(formatDisplayDate('  2026-03-15  ', 'en'), '15/03/2026');
    });
  });

  group('formatDisplayMoney', () {
    test('appends a single DA suffix after formatMoney trim', () {
      expect(formatDisplayMoney('24.800', 'en'), '24.8 DA');
      expect(formatDisplayMoney('300.000', 'fr'), '300 DA');
      expect(formatDisplayMoney('120.050', 'ar'), '120.05 DA');
      expect(formatDisplayMoney('100', 'en'), '100 DA');
      expect(formatDisplayMoney('0.000', 'fr'), '0 DA');
    });

    test('does not duplicate an existing DA suffix', () {
      expect(formatDisplayMoney('100 DA', 'en'), '100 DA');
      expect(formatDisplayMoney('120.5 DA', 'fr'), '120.5 DA');
    });

    test('recognises lowercase and mixed-case DA suffixes', () {
      expect(formatDisplayMoney('120 da', 'en'), '120 da');
      expect(formatDisplayMoney('120 Da', 'fr'), '120 Da');
      expect(formatDisplayMoney('120.5 da', 'ar'), '120.5 da');
    });

    test('trims surrounding whitespace before the suffix check', () {
      expect(formatDisplayMoney('120 DA ', 'en'), '120 DA');
      expect(formatDisplayMoney(' 120 DA', 'fr'), '120 DA');
      expect(formatDisplayMoney(' 120 da ', 'ar'), '120 da');
    });

    test('returns empty string for empty input', () {
      expect(formatDisplayMoney('', 'en'), '');
      expect(formatDisplayMoney('   ', 'fr'), '');
    });
  });

  group('existing helpers unchanged', () {
    test('formatMoney contract preserved', () {
      expect(formatMoney('300.000'), '300');
      expect(formatMoney('120.500'), '120.5');
      expect(formatMoney('0.000'), '0');
      expect(formatMoney('120.050'), '120.05');
    });

    test('milliToMoney / moneyToMilli contract preserved', () {
      expect(milliToMoney(120500), '120.500');
      expect(moneyToMilli('120.500'), 120500);
      expect(moneyToMilli('7'), 7000);
    });

    test('moneyToMilli still rejects comma decimal input', () {
      expect(moneyToMilli('1,5'), isNull);
      expect(moneyToMilli('1,'), isNull);
      expect(moneyToMilli('1.2345'), isNull);
      expect(moneyToMilli('-5'), isNull);
    });
  });
}
