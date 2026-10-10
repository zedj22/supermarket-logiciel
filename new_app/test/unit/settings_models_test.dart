// Phase 17 (§17.1) — StoreSettings model contract.
//
// The model is the single translation layer between the backend's
// snake_case JSON and the form. Every field must survive a round trip, and
// a missing/extra field must never throw (the API can gain a field before
// the client knows about it).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/settings/settings_models.dart';

void main() {
  group('StoreSettings.fromJson', () {
    test('parses a full backend payload', () {
      final settings = StoreSettings.fromJson(const <String, Object>{
        'store_name': 'بقالة النور',
        'store_phone': '0550 12 34 56',
        'store_address': '12 Rue de la Liberté',
        'invoice_footer': 'Merci de votre visite',
        'store_wilaya': 'Alger',
        'store_email': 'contact@nour.dz',
        'store_nif': '1600000000000001',
        'store_nis': '1600000000000002',
        'store_rc': '16/00-1234567 B 01',
        'store_ai': '1600000000000003',
        'store_rib': '0079 9999 1234 5678 90',
        'default_paper': 'A4',
        'ask_before_print': true,
        'auto_print_invoice': true,
        'allow_debt': false,
        'low_stock_threshold': 12,
      });

      expect(settings.storeName, 'بقالة النور');
      expect(settings.storePhone, '0550 12 34 56');
      expect(settings.storeAddress, '12 Rue de la Liberté');
      expect(settings.invoiceFooter, 'Merci de votre visite');
      expect(settings.storeWilaya, 'Alger');
      expect(settings.storeEmail, 'contact@nour.dz');
      expect(settings.storeNif, '1600000000000001');
      expect(settings.storeNis, '1600000000000002');
      expect(settings.storeRc, '16/00-1234567 B 01');
      expect(settings.storeAi, '1600000000000003');
      expect(settings.storeRib, '0079 9999 1234 5678 90');
      expect(settings.defaultPaper, 'A4');
      expect(settings.askBeforePrint, isTrue);
      expect(settings.autoPrintInvoice, isTrue);
      expect(settings.allowDebt, isFalse);
      expect(settings.lowStockThreshold, 12);
    });

    test('missing fields fall back to the documented defaults', () {
      final settings = StoreSettings.fromJson(const <String, Object>{});

      expect(settings.storeName, '');
      expect(settings.storePhone, '');
      expect(settings.storeAddress, '');
      expect(settings.invoiceFooter, '');
      expect(settings.storeWilaya, '');
      expect(settings.storeEmail, '');
      expect(settings.storeNif, '');
      expect(settings.storeNis, '');
      expect(settings.storeRc, '');
      expect(settings.storeAi, '');
      expect(settings.storeRib, '');
      expect(settings.defaultPaper, '80mm');
      expect(settings.askBeforePrint, isFalse);
      expect(settings.autoPrintInvoice, isFalse);
      expect(settings.allowDebt, isTrue);
      expect(settings.lowStockThreshold, 5);
    });

    test('accepts an int sent as a num (JSON number)', () {
      final settings =
          StoreSettings.fromJson(const <String, Object>{'low_stock_threshold': 7});
      expect(settings.lowStockThreshold, 7);
    });

    test('ignores unknown extra keys', () {
      final settings = StoreSettings.fromJson(const <String, Object>{
        'store_name': 'X',
        'some_future_field': 'ignored',
      });
      expect(settings.storeName, 'X');
    });
  });

  group('StoreSettings.toJson', () {
    test('round trips through fromJson', () {
      const original = StoreSettings(
        storeName: 'Store',
        storePhone: '1',
        storeAddress: '2',
        invoiceFooter: '3',
        storeWilaya: 'Oran',
        storeEmail: 'store@example.com',
        storeNif: 'NIF-1',
        storeNis: 'NIS-1',
        storeRc: 'RC-1',
        storeAi: 'AI-1',
        storeRib: 'RIB-1',
        defaultPaper: 'A4',
        askBeforePrint: true,
        autoPrintInvoice: false,
        allowDebt: false,
        lowStockThreshold: 9,
      );

      final decoded = StoreSettings.fromJson(original.toJson());

      expect(decoded, original);
      expect(decoded.hashCode, original.hashCode);
    });

    test('always carries every field (the PUT body must never be empty)', () {
      const empty = StoreSettings(
        storeName: '',
        storePhone: '',
        storeAddress: '',
        invoiceFooter: '',
        storeWilaya: '',
        storeEmail: '',
        storeNif: '',
        storeNis: '',
        storeRc: '',
        storeAi: '',
        storeRib: '',
        defaultPaper: '80mm',
        askBeforePrint: false,
        autoPrintInvoice: false,
        allowDebt: true,
        lowStockThreshold: 0,
      );

      expect(empty.toJson(), hasLength(16));
      expect(
        empty.toJson().keys,
        containsAll(<String>[
          'store_name',
          'store_phone',
          'store_address',
          'invoice_footer',
          'store_wilaya',
          'store_email',
          'store_nif',
          'store_nis',
          'store_rc',
          'store_ai',
          'store_rib',
          'default_paper',
          'ask_before_print',
          'auto_print_invoice',
          'allow_debt',
          'low_stock_threshold',
        ]),
      );
    });
  });

  group('StoreSettings copyWith / equality', () {
    test('copyWith overrides only the named fields', () {
      const base = StoreSettings(
        storeName: 'A',
        storePhone: 'p',
        storeAddress: 'a',
        invoiceFooter: 'f',
        storeWilaya: 'w',
        storeEmail: 'e',
        storeNif: 'nif',
        storeNis: 'nis',
        storeRc: 'rc',
        storeAi: 'ai',
        storeRib: 'rib',
        defaultPaper: '80mm',
        askBeforePrint: false,
        autoPrintInvoice: false,
        allowDebt: true,
        lowStockThreshold: 5,
      );

      final changed = base.copyWith(storeName: 'B', allowDebt: false);
      final fiscal = base.copyWith(storeNif: 'NIF-NEW', storeRib: 'RIB-NEW');

      expect(changed.storeName, 'B');
      expect(changed.allowDebt, isFalse);
      expect(changed.storePhone, 'p');
      expect(changed.lowStockThreshold, 5);
      expect(base.storeName, 'A', reason: 'copyWith must not mutate');
      expect(fiscal.storeNif, 'NIF-NEW');
      expect(fiscal.storeRib, 'RIB-NEW');
      expect(fiscal.storeWilaya, 'w', reason: 'untouched fields survive');
      expect(base.storeNif, 'nif', reason: 'copyWith must not mutate');
    });

    test('value equality drives the save button and the form key', () {
      const a = StoreSettings(
        storeName: 'S',
        storePhone: '',
        storeAddress: '',
        invoiceFooter: '',
        storeWilaya: '',
        storeEmail: '',
        storeNif: '',
        storeNis: '',
        storeRc: '',
        storeAi: '',
        storeRib: '',
        defaultPaper: '80mm',
        askBeforePrint: false,
        autoPrintInvoice: false,
        allowDebt: true,
        lowStockThreshold: 5,
      );
      final b = a.copyWith();
      final c = a.copyWith(lowStockThreshold: 6);
      final d = a.copyWith(storeWilaya: 'Blida');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d),
          reason: 'a fiscal field change must enable the save button');
    });
  });

  group('constants', () {
    test('papers mirror the backend CHECK constraint', () {
      expect(StoreSettings.papers, <String>['80mm', 'A4']);
    });

    test('settings path targets the versioned API', () {
      expect(StoreSettings.settingsPath, '/api/v1/settings');
    });
  });
}
