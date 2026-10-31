// Phase 17 (§17.3) — localization parity across ar/fr/en.
//
// `AppStrings.t` falls back to the **key** when a locale is missing a
// translation, so an untranslated string does not fail loudly: it prints
// `settings_load_failed` on the operator's screen in the middle of Arabic
// or French prose.  These tests turn that silent degradation into a hard
// failure and make the exact gap visible.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys whose value is *allowed* to equal the key: SI / unit symbols that
/// are genuinely written the same way in every locale (`kg` is `kg` in
/// English and French, `كغ` in Arabic).  Everything else matching would be
/// `AppStrings.t`'s raw-key fallback leaking onto the screen.
const _symbolKeys = {'kg'};

Map<String, String> _map(String locale) =>
    AppStrings.translations[locale] ?? const <String, String>{};

Set<String> _missing(String from, String to) =>
    _map(from).keys.toSet().difference(_map(to).keys.toSet());

void main() {
  group('localization parity (Phase 17 §17.3)', () {
    test('all three locale maps are present', () {
      for (final locale in _locales) {
        expect(_map(locale), isNotEmpty, reason: 'missing locale: $locale');
      }
    });

    test('every locale carries exactly the same key set', () {
      final gaps = <String>[];
      for (final from in _locales) {
        for (final to in _locales) {
          if (from == to) continue;
          final missing = _missing(from, to).toList()..sort();
          if (missing.isNotEmpty) {
            gaps.add('$from → $to (${missing.length}): $missing');
          }
        }
      }
      expect(
        gaps,
        isEmpty,
        reason: 'key sets differ between locales:\n${gaps.join('\n')}',
      );
    });

    test('no value is empty in any locale', () {
      final empty = <String>[];
      for (final locale in _locales) {
        _map(locale).forEach((key, value) {
          if (value.trim().isEmpty) empty.add('$key@$locale');
        });
      }
      expect(empty, isEmpty, reason: 'empty translations: $empty');
    });

    test('no value is a raw key (the t() fallback made visible)', () {
      final raw = <String>[];
      for (final locale in _locales) {
        _map(locale).forEach((key, value) {
          if (value == key && !_symbolKeys.contains(key)) {
            raw.add('$key@$locale');
          }
        });
      }
      expect(raw, isEmpty, reason: 'untranslated (value == key): $raw');
    });

    test('the three locales are actually translated, not copies', () {
      // A handful of keys are legitimately identical across locales
      // (`80mm`, `A4`, `OK`, brand/product codes…), so the bar is "most
      // differ", not "all differ".
      final identicalArEn = <String>[];
      final identicalFrEn = <String>[];
      final en = _map('en');
      en.forEach((key, value) {
        if (_map('ar')[key] == value) identicalArEn.add(key);
        if (_map('fr')[key] == value) identicalFrEn.add(key);
      });
      expect(
        identicalArEn.length,
        lessThan(en.length ~/ 4),
        reason: 'Arabic looks copied from English: $identicalArEn',
      );
      expect(
        identicalFrEn.length,
        lessThan(en.length ~/ 4),
        reason: 'French looks copied from English: $identicalFrEn',
      );
    });

    test('key count matches the Phase 17 baseline', () {
      // Measured at §17.3 (859); §17.6 added `ask_before_print_question`
      // (860); the product-quantity save added `product_and_stock_updated`,
      // `quantity_readonly` and `product_stock_reason` (863); §18 added the
      // keyboard-shortcuts help surface — 41 keys (`shortcuts_*` + the
      // `sc_a_*` / `sc_d_*` action/description pairs, 904); Phase 17 pricing
      // added the wholesale / TVA / margin labels — 5 keys (909); Phase 18
      // added the promotions surface — 31 keys (940); the UI/UX redesign
      // added the nav/dashboard KPI groups and the LAN store-address +
      // wizard-step surfaces — 20 keys (960); the barcode-label subphase
      // added the print-labels / sheet-layout surface — 15 keys (975);
      // the roll-label subphase added the paper-type + roll geometry
      // surface — 12 keys (987); Phase 8 facturation added the
      // invoice-clients + documents surface — 54 keys (1041); Stage 1 of the
      // legacy-parity project added the settings-company section title and
      // the RIB field label — 2 keys (1043); Stage 2 added the full invoice
      // preview sheet labels (doc titles, fiscal identity, item-table and
      // totals headers, signature) mirroring backend printing/labels.py —
      // 21 keys (1064).  Stage 3A facturation options added the pack
      // picker title — 1 key (1065).  The PDF layout/language pass added
      // the invoice-language selector label and the three language-name
      // labels — 4 keys (1069).  The optional sale-posting pass added the
      // register-as-sale checkbox label and the posted-as-sale status
      // label — 2 keys (1071).  The POS return-mode pass added the return
      // button / mode / hint / confirm / pack-unsupported labels — 5 keys
      // (1076).  The About page pass added the page, hero, info, server,
      // developer, documentation and six feature-card title/description
      // labels — 24 keys (1100).  The Documentation Center pass added the
      // screen chrome (search, prev/next, empty states, callout labels)
      // — 12 keys (1112).  The purchase total-cost pass added the
      // checkbox label, its hint, and the live-preview total-quantity
      // label — 3 keys (1115).  The audit-trail UI pass added the Audit
      // Log surface — screen chrome, summary cards, filters, the 22-module
      // / 18-action / 4-outcome vocabularies and the detail-dialog labels —
      // 84 keys (1199).  The facturation price-selection pass added the
      // unit-price (DA) label and the reference-price chips — header,
      // regular price and the wholesale-unavailable explanation —
      // 4 keys (1203).  The Klick POS weight/length amount-entry pass
      // added the quantity-vs-amount mode toggle, amount input, computed
      // quantity, requested amount and the zero/invalid-price explanation —
      // 6 keys (1209).  The Klick POS loyalty pass (Phase E) added the
      // loyalty surface — balance/redeem labels, the amount-due and
      // earned rows, the settings screen labels, the lookup/QR errors,
      // the history dialog and the 7 ledger event-type labels —
      // 29 new keys (1238; `amount_due` already existed in the payment
      // section with identical wording).  The Loyalty Phase F report pass
      // added the Reports → Loyalty surface — the tab name, the period
      // activity / balance-snapshot KPI labels, the four section titles
      // and the ledger table headers — 25 keys (1263).  The loyalty reward
      // redesign pass replaced the points-as-money surface with milestone
      // reward discounts: removed 4 legacy labels (point value, min/max
      // redemption, reward liability) and added 3 (reward selector title,
      // the "none" option, the max-reward-discount setting label) — 1262.
      // The Storage & Data Usage pass added the storage page chrome
      // (title, measuring/failed/permission states, totals + partial chip,
      // the two scope titles, last-measured/disk rows) plus the seven
      // category labels, the six measurement-reason labels, the
      // unavailable fallback, the settings entry-button label and its
      // description — 28 keys (1290).  The Zakat (Zakat al-Tijarah) pass
      // added the calculator surface — the report labels mirroring
      // backend printing/labels.py, the 21 warning codes, the screen
      // sections/fields/actions, the payment dialog and history labels,
      // the missing-field and eligibility chips — 130 keys (1420).
      // The loyalty earning-rate redesign pass added the merchant-facing
      // DA-per-point setting label and the configurable milestone label —
      // 2 keys (1422). The purchase → POS stock-sync pass added the
      // cashier warning shown when a held cart line's available quantity
      // shrank — 1 key (1423). The POS layout-switch pass added the
      // toolbar toggle action label and the two layout mode names —
      // 3 keys (1426). The Objective 4 pass (product import/export,
      // portable backup/restore, connected-device discovery) added the
      // three Administration rail labels, the three new audit action
      // labels (import / backup download / backup upload), the data
      // transfer surface (26), the backup inspect/download/upload
      // surface (15) and the hardware overview surface (26) —
      // 73 keys (1499). The purchase quick-add / optional-supplier pass
      // added the "no supplier" placeholder shown by the purchase editor,
      // list rows and detail header — 1 key (1500). The POS barcode-
      // scanner integration pass added the not-found toast shown when a
      // scanned code resolves nowhere (canonical barcode lookup miss) —
      // 1 key (1501). The configurable scan-actions pass added the
      // settings section title plus the label/description of each of the
      // two scan-action toggles (unknown barcode → Add Product,
      // out-of-stock scan → Adjust Stock) — 5 keys (1506). The Phase A
      // privacy-safe scan-diagnostics pass added the settings section
      // title, its privacy description, the four session controls
      // (start/stop/clear/copy), the copy confirmation, the idle/running
      // status labels, the total/dropped counters, the gateway buffer
      // label, the armed/idle labels and the empty-history hint —
      // 15 keys (1521). The raw-scanner PoC pass added the settings PoC
      // card surface — title, description, toggle, on/off status, layout
      // selector label + the three layout names, learn + armed hint,
      // learned-devices label + empty state, the raw-seen / matched /
      // suppressed / passed counters, the order-violations label, reset,
      // the last-decoded label + empty state and the unavailable note —
      // 22 keys (1543). The POS discount / quick-sale pass added the two
      // invoice-discount input-mode labels (amount DZD / percentage), the
      // percent-ceiling error, the POS-actions settings section title plus
      // the quick-sale-with-Space toggle label + help text, and the
      // quick-sale action/description shown on the Space row of the
      // shortcuts map while the setting is ON — 8 keys (1551). The
      // purchase-save constraint regression pass added the database
      // constraint headline used by the purchases/POS mappers when the
      // backend reports a DB integrity failure (never a stock
      // conflict) — 1 key (1552). The Zakat inventory-valuation pass
      // added the wholesale valuation-basis option, the wholesale→
      // retail fallback warning and the stock-only breakdown surface
      // (remaining quantity, cost value, market selling value, the
      // 2.5% stock-only estimate and its not-the-full-zakat note) —
      // 7 keys (1559). The product-form markup-on-cost pass added the
      // pricing-row percentage label (markup on cost, distinct from the
      // products table's margin) — 1 key (1560). The POS customer-picker
      // quick-add pass added the picker's "Add new customer" button label
      // (shared by the ar/fr/en maps) — 1 key (1561). The POS keyboard
      // shortcut pass added the two shortcuts-map descriptions for
      // Shift+F6 (add customer) and Shift+F7 (use points) — the action
      // labels reuse the existing `add_client` / `loyalty_redeem` keys —
      // 2 keys (1563). The safe permanent-deletion pass for variants /
      // selling units / purchase units added the three per-entity delete
      // action labels, the shared "Delete permanently" button, the
      // confirmation dialog title + message, the three per-entity
      // deletion-success notifications and the localized "record in use —
      // archive instead" blocked-deletion message — 10 keys (1573).
      // Update this deliberately when a subphase
      // adds strings — an unexplained drop means keys were deleted from
      // one map only.
      expect(_map('en').keys.length, 1573);
      expect(_map('ar').keys.length, _map('en').keys.length);
      expect(_map('fr').keys.length, _map('en').keys.length);
    });
  });
}
