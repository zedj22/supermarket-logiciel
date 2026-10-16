// Phase 10 Stage C-1 — presentation-only formatting helpers for Facturation.
//
// These helpers exist solely for on-screen display. They MUST NOT be used
// to construct API payloads, persisted values, or fiscal calculations.
// Dates stay ISO `YYYY-MM-DD` in requests/persistence; money strings stay
// the server's `.`-decimal form in models. PDF formatting is owned by the
// backend (`app/printing/text.py`) and renders space-grouped thousands
// with `%.2f DA` + ISO dates + French amount-in-words.
//
// Approved display policy:
// - Dates render `DD/MM/YYYY` with Latin digits in ar / fr / en.
// - Money renders with a single `DA` suffix in the Facturation UI.
// - Timezone is never involved: these are date-only, string-only transforms.

import '../clients/customer_models.dart' show formatMoney;

/// Currency suffix used by the Facturation UI. Matches `AppStrings`
/// `currency` and backend `CURRENCY` — identical in all locales.
const String kFacturationCurrencySuffix = 'DA';

/// Formats an ISO `YYYY-MM-DD` date string as `DD/MM/YYYY` (Latin digits)
/// for every supported locale (`ar`, `fr`, `en`).
///
/// This is a pure string rearrangement of a date-only value: no `DateTime`
/// is constructed, so no timezone shift can occur.
///
/// The `loc` parameter is part of the API for symmetry with the rest of the
/// codebase (`AppStrings.t(key, loc)`) and future locale-specific needs,
/// but the approved policy is identical `DD/MM/YYYY` for all three locales.
///
/// Invalid or empty input is returned trimmed and unchanged (empty stays
/// empty), matching the "pass through what you can't format" convention of
/// `formatMoney`.
String formatDisplayDate(String isoDate, String loc) {
  final trimmed = isoDate.trim();
  if (trimmed.isEmpty) return '';

  // Strict date-only ISO. Anything with a time component or malformed
  // digits is passed through untouched rather than silently corrupted.
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trimmed);
  if (match == null) return trimmed;

  return '${match.group(3)}/${match.group(2)}/${match.group(1)}';
}

/// Formats a raw money string (e.g. `24.800`) for display with the `DA`
/// suffix (e.g. `24.8 DA`).
///
/// Reuses the existing `formatMoney` trailing-zero trim. Does not parse the
/// string as a number. If the input already ends with `DA` (case-insensitive,
/// so `120 da` / `120 Da` are also recognised), it is returned trimmed and
/// unchanged to prevent duplicate suffixes.
String formatDisplayMoney(String rawMoney, String loc) {
  final trimmed = rawMoney.trim();
  if (trimmed.isEmpty) return '';

  if (trimmed.toUpperCase().endsWith(kFacturationCurrencySuffix)) {
    return trimmed;
  }

  return '${formatMoney(trimmed)} $kFacturationCurrencySuffix';
}
