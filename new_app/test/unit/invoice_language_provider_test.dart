// Invoice PDF language provider — independent of the UI locale.
//
// The printed document language is a per-operator preference: a
// French-speaking cashier may still need Arabic invoices. `null` means
// "not chosen yet" and safely follows the UI locale; once picked it is
// sticky for the session and a later UI-language change never overwrites
// it. Not persisted — no schema change for a print preference.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/facturation/facturation_providers.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

void main() {
  group('invoiceLanguageProvider', () {
    test('defaults to null (not chosen yet)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(invoiceLanguageProvider), isNull);
    });

    test('explicit choice is stored', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(invoiceLanguageProvider.notifier).state = 'fr';
      expect(container.read(invoiceLanguageProvider), 'fr');
    });
  });

  group('effectiveInvoiceLanguageProvider', () {
    test('follows the UI locale while no explicit choice', () {
      final container = ProviderContainer(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(AppLocale.en),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(effectiveInvoiceLanguageProvider), 'en');

      container
          .read(localeProvider.notifier)
          .setLocale(AppLocale.ar);
      expect(container.read(effectiveInvoiceLanguageProvider), 'ar');
    });

    test('explicit choice wins over the UI locale', () {
      final container = ProviderContainer(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(AppLocale.ar),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(invoiceLanguageProvider.notifier).state = 'fr';
      expect(container.read(effectiveInvoiceLanguageProvider), 'fr');
    });

    test('changing the UI language never overwrites an explicit choice', () {
      final container = ProviderContainer(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(AppLocale.ar),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(invoiceLanguageProvider.notifier).state = 'en';
      container
          .read(localeProvider.notifier)
          .setLocale(AppLocale.fr);
      // Explicit 'en' sticks; UI is now fr.
      expect(container.read(invoiceLanguageProvider), 'en');
      expect(container.read(effectiveInvoiceLanguageProvider), 'en');
    });

    test('empty string is treated as not chosen (falls back to UI)', () {
      final container = ProviderContainer(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(AppLocale.fr),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(invoiceLanguageProvider.notifier).state = '';
      expect(container.read(effectiveInvoiceLanguageProvider), 'fr');
    });
  });
}
