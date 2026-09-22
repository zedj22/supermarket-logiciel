# Phase 0 — Localization and RTL Audit

The legacy system defines an approximately 500-key `_TRANSLATIONS` dictionary in `MainWindow`; Arabic source phrases are keys and `t()` falls back to the original text when an English/French mapping is missing. There is also `locales/translations_new_additions.json`. This is not a centralized, validated catalogue: UI strings appear throughout the 15k-line file, dialogs/technical errors/format strings and print/export paths contain hardcoded Arabic, French and English. Dynamic f-strings make grammatical translation unreliable. Coverage observed: navigation/settings/common labels are broadly mapped; tooltips, empty/loading/error states, report/print details and technical messages are incomplete. Exact runtime coverage is **UNVERIFIED**.

## Legacy RTL observations

Arabic direction/alignment is applied manually per widget. Tables, mixed Arabic/Latin identifiers, numbers, modal layout, chart labels, PDF/thermal receipt rendering and print fonts require individual handling. ReportLab PDF paths reshape Arabic and apply bidi transformation; this is not a general UI layout solution. Dates/numbers/currency formats are manually assembled in several paths.

## Target contract

- Flutter uses ARB semantic keys (`pos.completeSale`, not Arabic phrases), ICU plural/select variables, and generated localization classes for `ar`, `fr`, `en`.
- Backend returns stable error codes/message keys and data, not user-visible hardcoded prose. Server print templates use the same semantic catalogue.
- CI fails missing key in a required locale, unused/dead keys where practical, direct user-visible literals outside approved adapter/test code, and untranslated permission/report/error names.
- Use `Directionality`/locale-aware widgets, mirrored navigation/icons only where semantically appropriate, logical `start/end`, locale date/number/currency formatting, Arabic-capable embedded fonts, and visual RTL snapshots for POS, tables, dialogs, invoices and PDFs.
- Establish a terminology glossary before Phase 1 for sale/invoice/return/debt/credit/customer/supplier/stock/discount/change and DZD presentation.
