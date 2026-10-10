# PHASE 10 — STAGE C-1: PRESENTATION FORMATTERS

**Status:** COMPLETE — helpers implemented and tested. No UI wiring.
**Baseline:** `d914f3a` (`fix: localize facturation picker errors`), branch `main`, in sync with `origin/main`.

---

## 1. Inspected files and findings

| File | Finding |
|---|---|
| `new_app/lib/core/strings.dart` | `currency: 'DA'` identical in ar/fr/en (`:534`, `:1635`, `:2761`). No existing date/money formatting helper in `lib/core`. |
| `new_app/lib/features/clients/customer_models.dart:168-203` | `formatMoney` is a pure string trailing-zero trim (`.` decimal, no grouping); `milliToMoney`/`moneyToMilli` are integer-thousandths, no floats. `moneyToMilli` rejects `,` decimals and >3 dp (reject-don't-round contract). |
| `new_app/pubspec.yaml:19` | `intl: ^0.20.1` already present — no dependency change needed. |
| `new_app/lib/features/facturation/facturation_models.dart:13` | Feature already imports `milliToMoney`/`moneyToMilli` from `../clients/customer_models.dart`, establishing the cross-feature import pattern used by the new helper. |
| `new_app/test/unit/clients_models_test.dart` | Existing conventions: `flutter_test`, `group`/`test`, exact string assertions, comma-rejection tests (`:34`). |
| Legacy `factura_simple/frontend/lib/pdf_invoice.dart:56-59` | `fmtDate` uses string-split swap (`YYYY-MM-DD` → `DD/MM/YYYY`) with no `DateTime` construction — confirms the timezone-safe approach chosen here. |

## 2. Files changed

**Created (2 files, 0 modifications):**
- `new_app/lib/features/facturation/facturation_format.dart` — new presentation helper.
- `new_app/test/unit/facturation_format_test.dart` — new focused unit tests.

**No existing file was modified.** `git diff --stat` is empty; only untracked files were added.

## 3. Helper behavior and invalid-input policy

Placed in `features/facturation/` (not `lib/core/`) because `lib/core` has no formatting module and the Facturation feature already imports from `features/clients`. This keeps the helper cohesive with its future call sites (C-2) without touching unrelated modules.

### `formatDisplayDate(String isoDate, String loc)`
- **Output:** `DD/MM/YYYY`, Latin digits, identical for `ar`/`fr`/`en`.
- **Mechanism:** strict regex `^(\d{4})-(\d{2})-(\d{2})$` + pure string swap of groups 3/2/1. **No `DateTime` is ever constructed**, so no timezone shift can occur (date-only value, per policy).
- **Why not `DateFormat`:** `intl`'s default `DateSymbols` for `ar` substitute Arabic-Indic digits (`٠١٢...`), which violates the approved Latin-digits policy. Manual string swap is the only way to guarantee ASCII digits across all three locales without locale-data side effects. No new dependency was added.
- **Invalid/empty policy:** empty/whitespace-only input → `''`; any input that does not strictly match `YYYY-MM-DD` (including time components, non-padded parts, already-formatted strings) → returned trimmed and **unchanged** (pass-through, matching `formatMoney`'s "pass what you can't format" convention). This is documented in the code and locked by tests.

### `formatDisplayMoney(String rawMoney, String loc)`
- **Output:** existing `formatMoney` result + single space + `DA` (e.g. `24.800` → `24.8 DA`).
- **Mechanism:** reuses `formatMoney` (no re-parsing, no rounding, no precision change). Empty input → `''`. If the string already ends with `DA`, it is returned unchanged to prevent duplicate suffixes.
- **`loc` parameter:** unused under the current policy (`DA` is identical in all locales) but kept for API symmetry with `AppStrings.t(key, loc)` and future needs.

### Not added
No quantity-specific formatter was added. `formatMoney` already provides the trimmed-zero quantity display used by `invoice_detail_dialog.dart:284`; adding a separate helper now would be speculative. This decision is noted for C-2 review.

## 4. Test commands and exact results

| Command | Workdir | Result |
|---|---|---|
| `flutter test test\unit\facturation_format_test.dart` | `new_app` | **11 passed** (all green) |
| `flutter test test\unit\clients_models_test.dart` | `new_app` | **14 passed** (existing money contracts unchanged) |
| `flutter analyze` | `new_app` | **No issues found** (2.9s) |

New tests cover: DD/MM/YYYY in ar/fr/en; single-digit day/month zero-padding; empty + invalid + time-component + already-formatted pass-through; whitespace trim; DA suffix append + duplicate-DA prevention; empty money input; and regression locks on `formatMoney`, `milliToMoney`, `moneyToMilli` including comma-decimal rejection.

## 5. Untouched confirmations

- **API serialization / payloads:** no model, provider, or payload code touched. `document_date` remains ISO `YYYY-MM-DD`; `moneyToMilli` grammar unchanged.
- **Fiscal calculations / Decimal arithmetic / VAT / timbre / numbering / amount-in-words:** untouched. Helpers are display-only string transforms.
- **PDF / backend code:** no `.py` file modified; `text.py` formatters and Phase 7 PDF tests unchanged.
- **Unrelated modules:** POS, sales, inventory, reports, clients, invoice-clients screens untouched.
- **Dependencies:** no `pubspec.yaml` / `pubspec.lock` change.
- **UI wiring:** `facturation_screen.dart`, `invoice_detail_dialog.dart`, `invoice_form_dialog.dart` untouched — helpers are not imported by any screen yet.

## 6. Final Git status

```
## main...origin/main
?? new_app/bar.pdf
?? new_app/bar2.pdf
?? new_app/lib/features/facturation/facturation_format.dart
?? new_app/reports_financial_2026-09-25_2026-10-01_2026-10-01-092831.csv
?? new_app/reports_sales_2026-09-22_2026-10-01_2026-10-01-115842.csv
?? new_app/sale_INV-20261004-142659-926-0082_2026-10-04-192350.pdf
?? new_app/test/unit/facturation_format_test.dart
?? new_app/test/widget/failures/
?? new_app/test/widget/goldens/
```

- `git diff --check` → exit 0.
- `git diff --stat` → empty (zero tracked-file modifications).
- `git diff --cached --name-only` → empty (nothing staged).
- HEAD unchanged at `d914f3a`; branch in sync with `origin/main`.
- All pre-existing untracked artifacts (`bar.pdf`, `bar2.pdf`, CSVs, sale PDF, `failures/`, `goldens/`) preserved.

**No git stage/commit/push/stash/reset/clean/checkout operation was performed.** Only `write` was used to create the two new files; no blanket git commands were used.
