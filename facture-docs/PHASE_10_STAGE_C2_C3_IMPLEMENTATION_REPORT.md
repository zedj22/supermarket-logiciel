# PHASE 10 — STAGES C-2 + C-3: FACTURATION UI INTEGRATION AND REGRESSION TESTS

**Status:** COMPLETE — awaiting review. No Git write operation was performed.
**Baseline:** `d914f3a` (`fix: localize facturation picker errors`), branch `main`, in sync with `origin/main`.
**Preceding stage:** C-1 approved (`facturation_format.dart` + `facturation_format_test.dart` + `PHASE_10_STAGE_C1_IMPLEMENTATION_REPORT.md`).

---

## 1. Files changed

| File | Change | Rationale |
|---|---|---|
| `new_app/lib/features/facturation/facturation_screen.dart` | 2 call sites | List date cells (narrow subtitle + wide table column) were printing the raw ISO `document_date`. |
| `new_app/lib/features/facturation/invoice_detail_dialog.dart` | 8 call sites | Detail meta date was ISO; line-table unit price / line total and all five totals rows printed raw money strings with no currency marker. |
| `new_app/lib/features/facturation/invoice_form_dialog.dart` | 10 call sites | Form date button label + edit-mode identity line were ISO; line-preview unit price / line total, preview totals rows and the pre-preview footer subtotal/tva used raw or `milliToMoney` output (the footer inconsistency of C-2 §5). |
| `new_app/lib/features/facturation/invoice_line_dialog.dart` | 2 call sites | Line-total preview (`lineHt` + optional TVA amount) had no currency marker. |
| `new_app/lib/features/facturation/facturation_format.dart` | hardened `formatDisplayMoney` | C-2 §6: case-insensitive suffix detection (`120 da` / `120 Da`) plus surrounding-whitespace trim before the suffix check, so no duplicate `DA` is ever emitted. |
| `new_app/test/unit/facturation_format_test.dart` | +2 tests | Explicit lowercase-suffix and trailing-space-suffix tests required by C-2 §6 (11 → 13 tests). |
| `new_app/test/widget/facturation_screen_test.dart` | +9 tests, harness extended | C-3 regression coverage: locale override in `pumpApp`, list-item override, POST/PUT call logging, client-picker stub. |

Nothing else was touched. No backend/Python file, no PDF renderer or PDF test, no model/provider/payload/serialization code, no dependency, no route guard, no permission policy.

## 2. Formatter call sites changed

`formatDisplayDate` (5):
- `facturation_screen.dart:306` — narrow-layout list subtitle date.
- `facturation_screen.dart:404` — wide-layout list date column (`facturation-date-$index`).
- `invoice_detail_dialog.dart:223` — detail meta `document_date` line.
- `invoice_form_dialog.dart:413` — create-mode date **button label** only (`invoice-form-date`).
- `invoice_form_dialog.dart:457` — edit-mode identity line (`invoice-form-identity`).

`formatDisplayMoney` (18):
- Detail: `invoice_detail_dialog.dart:287` (line unit price), `:292` (line total HT), `:313`/`:319`/`:325`/`:332`/`:338` (total HT, TVA, TTC, timbre, net à payer).
- Form: `invoice_form_dialog.dart:583` (line-preview unit price), `:587` (line-preview line total), `:633`/`:639`/`:645`/`:652`/`:658` (preview totals rows), `:677`/`:679` (pre-preview footer HT/TVA subtotals).
- Line dialog: `invoice_line_dialog.dart:338` (preview `lineHt`), `:339` (preview TVA amount).

Deliberately **not** formatted (stay on `formatMoney`, no `DA`):
- `invoice_detail_dialog.dart:285` — line **quantity**.
- `invoice_detail_dialog.dart:289`, `:290` — TVA rate and discount **percentages** (`…%`).
- `invoice_form_dialog.dart:583` — the quantity operand of `qty × price` and the `TVA …%` / `-…%` segments.
- Input `TextField`s in `invoice_line_dialog.dart` (raw user entry, never display-formatted).
- `doc.createdAt` timestamp in the detail meta (`_timestampOf`) — a timestamp, outside the date-only display policy; documented in the test comment.
- Amount-in-words strings (`invoice-detail-words`, `invoice-form-preview-words`) — server/backend-owned French wording, frozen.

Footer subtotal inconsistency (C-2 §5) resolved **only at the presentation call sites**: `milliToMoney(_subtotalHtMilli)` / `milliToMoney(_subtotalTvaMilli)` are now wrapped in `formatDisplayMoney`. The milli arithmetic (`_subtotalHtMilli`, `_subtotalTvaMilli`, `lineHtMilli`) is byte-identical to before.

## 3. API ISO payload verification

- `invoice_form_dialog.dart:159-163` (`_createPayload`) is the **only** place `document_date` is serialized; it is built from `_documentDate` with `padLeft` zero-padding → `YYYY-MM-DD`. It is not display-formatted.
- `invoice_form_dialog.dart:177-190` (`_updatePayload`) never emits `document_date` (immutable identity).
- Widget-verified end to end:
  - *create payload keeps ISO document_date (English end-to-end)* — the Material picker date is display-formatted on the button (`DD/MM/YYYY`, asserted against the button subtree), while `POST /api/v1/factures/preview` body `document_date` matches `^\d{4}-\d{2}-\d{2}$` and equals the picked date round-tripped from the label (the picker opens on the current month, so the expectation is derived rather than hardcoded — this keeps the test time-independent).
  - *update payload never carries document_date (edit mode)* — `PUT /api/v1/factures/d1` body has no `document_date` key (and no key containing `date`), while the on-screen identity line shows `15/03/2026`.

## 4. Tests run and exact results

| Command (workdir `new_app`) | Result |
|---|---|
| `flutter test test/unit/facturation_format_test.dart test/unit/facturation_models_test.dart test/widget/facturation_screen_test.dart` | **All tests passed** — 13 formatter/model unit tests + 19 widget tests (15 in `facturation_screen_test.dart` incl. 4 pre-existing, counted with the models file). |
| `flutter test test/unit/facturation_format_test.dart test/unit/facturation_models_test.dart test/widget/facturation_nav_visibility_test.dart test/widget/facturation_pickers_error_test.dart test/widget/invoice_clients_screen_test.dart test/unit/rtl_layout_test.dart test/unit/localization_parity_test.dart test/unit/localization_coverage_test.dart` | **+61, All tests passed** (2:19). |
| `flutter analyze` | **No issues found!** (ran in 69.5s) |
| `flutter test` (full suite) | **+1635, All tests passed!** (6:23). |
| `git diff --check` | exit 0, clean (only the pre-existing LF→CRLF notice). |

### C-3 coverage map
- `DD/MM/YYYY` on list / detail / form for **all three locales**: list loop test (ar/fr/en, with an explicit `Directionality` assertion — RTL only for `ar`, LTR for fr/en), detail tests per locale, form edit-identity + date-label loop (ar/fr/en), create-form date button (en).
- Single-digit day/month: list test `2026-01-05` → `05/01/2026`, plus unit tests.
- ISO payload: create/preview + update tests above.
- Exactly one `DA` on every Facturation money surface: detail totals row keys (`invoice-detail-total-*`), line unit price (`10.000` → `10 DA`), form preview totals (`invoice-form-total-*`), form footer (`0.000` → `0 DA`), form line preview (`1 × 100 DA`), line-dialog preview.
- Quantities/percentages suffix-free: detail asserts `19%`, `0%` and that `2 DA` never appears; form line subtitle asserts `1 × 100 DA`.
- Footer subtotal consistency: `invoice-form-display-totals` contains `0 DA` and no longer contains `0.000`.
- Money parsing/precision: unit tests lock `formatMoney`, `milliToMoney`, `moneyToMilli` and comma-decimal rejection.
- Arabic RTL: directionality assertion in the ar list test (plus the app-wide `rtl_layout_test` and `localization_*` suites).
- No regression to navigation / permissions / pickers / PDF contracts: `facturation_nav_visibility_test`, `facturation_pickers_error_test`, `invoice_clients_screen_test`, `permission_helpers_test` and the full suite all pass unchanged.

## 5. Confirmation of untouched scope

- **Backend / Python:** no `.py` file modified (`git diff --stat` contains only the five Flutter files above).
- **PDF:** no renderer or PDF test touched; the PDF contract (`%.2f DA`, ISO dates, French amount-in-words) is unchanged and is not routed through these helpers.
- **Fiscal calculations, VAT, timbre, numbering, persisted amounts:** untouched. The helpers are display-only string transforms; `facturation_models.dart` is byte-identical to `d914f3a`.
- **API contracts / serialization:** untouched (see §3).
- **POS / sales / inventory / reports / clients:** untouched.
- **Permissions / route guard:** untouched.
- **Dependencies:** `pubspec.yaml` / `pubspec.lock` unchanged.
- **Artifacts:** all pre-existing untracked PDFs, CSVs, `failures/`, `goldens/` and the C-1 report are preserved. No `git clean`, no blanket staging.

## 6. Remaining limitations / skipped items

- The form **line-preview unit price** echoes the user's typed string (`_lines[i].unitPriceHt`) and is now display-formatted; empty price renders as before (`qty × ` with a trailing space), matching prior behaviour.
- The create-form date label is asserted in English end-to-end; the French create-form label is not separately exercised (the ar/fr/en loop covers the form's date label in edit mode, which uses the same `formatDisplayDate` call).
- The `created_at` timestamp in the detail meta still prints in its raw form — intentional, per the date-only display policy.
- `formatDisplayMoney` keeps its `loc` parameter (approved API); output is identical for ar/fr/en by policy.

## 7. Final Git status (read-only inspection)

```
## main...origin/main
 M new_app/lib/features/facturation/facturation_screen.dart
 M new_app/lib/features/facturation/invoice_detail_dialog.dart
 M new_app/lib/features/facturation/invoice_form_dialog.dart
 M new_app/lib/features/facturation/invoice_line_dialog.dart
 M new_app/test/widget/facturation_screen_test.dart
?? facture-docs/PHASE_10_STAGE_C1_IMPLEMENTATION_REPORT.md
?? new_app/bar.pdf
?? new_app/bar2.pdf
?? new_app/lib/features/facturation/facturation_format.dart
?? new_app/reports_financial_2026-09-25_2026-10-01_2026-10-01-092831.csv
?? new_app/reports_sales_2026-09-22_2026-10-01_2026-10-01-115842.csv
?? new_app/sale_INV-20261004-142659-926-0082_2026-10-04-192350.pdf
?? new_app/test/unit/facturation_format_test.dart
?? new_app/test/widget/failures/
?? new_app/test/widget/goldens/
?? facture-docs/PHASE_10_STAGE_C2_C3_IMPLEMENTATION_REPORT.md
```

`git diff --stat`: 5 tracked files, +470 / −36.

**No Git write operation was performed**: no `git add`, `commit`, `push`, `stash`, `reset`, `clean`, or `checkout`. HEAD remains `d914f3a`. Stopped after C-2 and C-3 as instructed — final release QA not started.
