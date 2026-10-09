# PHASE 10 — Stage A: Read-Only Localization, QA & Legacy Parity Audit

**Date:** 2026-10-09
**Audit type:** STRICT READ-ONLY (no source, test, schema, dependency, or data modification)
**Baseline commit:** `81f7c35` — `feat: enforce facturation permissions`
**Report file (only permitted write):** `facture-docs/PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md`

---

## 1. Executive Summary

Phase 10 Stage A is a read-only audit of the facturation feature (Phases 1–9)
covering localization completeness, Arabic RTL behavior, calculation parity
against the legacy `factura_simple` reference, document numbering, permissions,
data integrity, and full regression/build evidence.

**Overall verdict: the facturation implementation is technically sound and
release-candidate quality for a controlled deployment, with no P0 or P1
defects confirmed.** All executed automated gates pass at their established
baselines. The highest-priority items are operational (manual re-seed of
permissions on existing databases) and quality-of-life (a raw backend-message
leak in two picker widgets; facturation amounts/dates are not locale-aware in
the Flutter UI). Arabic RTL rendering and the French amount-in-words path are
verified by automated assertions but still require human visual confirmation
of the final PDF. DOCX export remains an undecided optional feature, not a
confirmed requirement.

---

## 2. Current Git State and Baseline

Inspected on 2026-10-09 via `git rev-parse`, `git log`, `git status --short --branch`.

| Item | Value |
|---|---|
| Repository root | `C:\Users\MSI\Desktop\supermarket_logiciel` |
| Branch | `main` (in sync with `origin/main`) |
| HEAD | `81f7c35c91799d9305d4f80517d16aafbbfeab52` |
| HEAD message | `feat: enforce facturation permissions` |
| Confirms prompt baseline `81f7c35` | **YES** — HEAD is exactly the stated commit, not later |
| Recent facturation commits | `81f7c35`, `238b48b`, `26606af`, `771015e`, `d15961a`, `5cac783`, `bff44cd`, `7af4e73`, `bf213c2`, `9d30b0f` |
| Tracked modifications | **none** (working tree clean vs HEAD) |
| Untracked artifacts (preserved, untouched) | `new_app/bar.pdf`, `new_app/bar2.pdf`, `new_app/reports_financial_*.csv`, `new_app/reports_sales_*.csv`, `new_app/sale_INV-*.pdf`, `new_app/test/widget/failures/`, `new_app/test/widget/goldens/` |

No files were staged, committed, pushed, stashed, reset, cleaned, or
checked out during this audit.

---

## 3. Documents and Evidence Inspected

| Document | Path | Status |
|---|---|---|
| Phase 9 Stage C Flutter report | `facture-docs/PHASE_9_STAGE_C_FLUTTER_PERMISSIONS_REPORT.md` | EXISTS (97 lines) |
| Phase 9 Stage B backend permissions report | — | **ABSENT as a file** — delivered in-chat only during Phase 9; backend evidence re-verified in this audit instead |
| Phase 0 architecture / business rules / legacy audit / localization audit | `docs/PHASE_0_*.md` (12 files) | EXISTS |
| Phase 1 setup / test report | `docs/PHASE_1_SETUP.md`, `docs/PHASE_1_TEST_REPORT.md` | EXISTS |
| Phase 15 printing/exports analysis | `docs/PHASE_15_PRINTING_EXPORTS_ANALYSIS.md` | EXISTS (cited for DOCX/dependency evidence) |
| Historical "Phase 10" (Packs) | `docs/PHASE_10_IMPLEMENTATION.md` | EXISTS — **different Phase 10** (packs/bundles roadmap phase, already closed); NOT this facturation Phase 10 |
| Any existing Phase 10 facturation requirements/QA plan | — | **ABSENT** — no facturation Phase 10 spec exists yet |
| Legacy calculation source | `C:\Users\MSI\Desktop\factura_simple\backend\calc.py` (149 L) | EXISTS, read |
| Legacy API/models | `C:\Users\MSI\Desktop\factura_simple\backend\main.py`, `models.py`, `docx_export.py` | EXISTS, read |
| Legacy PDF | `C:\Users\MSI\Desktop\factura_simple\frontend\lib\pdf_invoice.dart` | EXISTS, read |
| Modern domain/service/repo/models/schemas/API/printing | `new_app\backend\app\{domain,services,repositories,models,schemas,api\v1,printing}\` facturation files | EXISTS, read |
| Modern Flutter feature | `new_app\lib\features\facturation\*`, `invoice_clients\*` | EXISTS, read |
| Localization store & tests | `new_app\lib\core\strings.dart` (3397 L), `test\unit\localization_parity_test.dart`, `test\unit\localization_coverage_test.dart` | EXISTS, read |
| Backend tests | `tests\unit\test_facturation*.py`, `test_phase6/7*.py`, `tests\integration\test_phase4/5*.py` | EXISTS, read |

---

## 4. Localization Coverage Matrix

**Store:** `new_app\lib\core\strings.dart` (3397 lines). One nested map
`AppStrings.translations['ar'|'fr'|'en']` → three private maps `_arabic`
(L54–1151), `_french` (L1153–2277), `_english` (L2279–3396). Lookup helper
`AppStrings.t(key, locale)` falls back to the raw key when missing (L4–6).

| Check | ar | fr | en | Result |
|---|---|---|---|---|
| Translation keys | **1041** | **1041** | **1041** | **MATCH** — identical count |
| Key-set parity (6 ordered diffs) | — | — | — | **MATCH** — all set differences empty |
| Empty (`""`) values | 0 | 0 | 0 | **MATCH** |
| `value == key` (raw-key fallback visible) | 0 | 1 (`kg` L1401) | 1 (`kg` L2527) | **ACCEPTED** — allow-listed symbol key in parity test (`_symbolKeys`) |
| Values identical to English (copy detection) | 1 (`currency: 'DA'`) | 0 | — | **MATCH** — 1/1041 = 0.10%; threshold in test is < 25% |
| Placeholder `{...}` parity across locales | — | — | — | **MATCH** — 0 mismatches |
| Arabic values containing wrong-language text | — | — | — | **NONE DETECTED** (25 ar values mix Arabic+Latin for technical terms like `TVA`, `SKU`, `F4` — legitimate) |

**Supported locale identifiers:** `Locale('ar')`, `Locale('fr')`,
`Locale('en')` — `lib\main.dart:16-20`, wired via
`flutter_localizations` delegates (`main.dart:22-27`, `87-89`, `118-120`).
Default locale is **Arabic** (`lib\l10n\locale_provider.dart:10,41,45`;
unknown persisted value also falls back to Arabic, L39-46). No
`localeResolutionCallback`, no `.arb` files, no `l10n.yaml` — `AppStrings`
is the entire l10n system.

**Facturation UI localization:**

| File | `AppStrings.t(` calls | Hard-coded user-visible literals |
|---|---|---|
| `facturation_screen.dart` | 20 | 2 (page `p / n` indicator L249-250; `·` separator L307) |
| `invoice_form_dialog.dart` | 35 | ISO date button L412-414; `×`/`·` in line summary L578-582 |
| `invoice_line_dialog.dart` | 23 | `%` L298 |
| `invoice_detail_dialog.dart` | 23 | `%` L286-287; ISO timestamp L24-31 |
| `facturation_pickers.dart` | 13 | `%` L325-326; **raw backend message as primary error** L96-98, L261-263 (see §11) |
| `invoice_clients_screen.dart` | 14 | page indicator L204-205; **`NIF:` prefix L255** |
| `invoice_client_form_dialog.dart` | 16 | none beyond separators |
| `facturation_error.dart` | 3 | none — full error-code mapper (7 codes + 4 HTTP statuses → `AppStrings.t`) |
| `invoice_clients_error.dart` | 3 | none — 5 codes + statuses |

No `Text('literal word')`, `labelText: 'word'`, `hintText: 'word'`,
`tooltip: 'word'`, or `title: 'word'` exists in either feature directory
(verified by this audit and by the project's own
`localization_coverage_test.dart` regex scan). The 9 hard-coded literals
above are locale-neutral symbols (`%`, `×`, `·`, `NIF:`, ISO dates, `p / n`)
— none are translatable words in a single language.

**Error localization:** `facturation_error.dart:31-58` maps
`INVOICE_CLIENT_ARCHIVED`, `NOT_FOUND`, `VALIDATION_ERROR`,
`FORBIDDEN`/`AUTHORIZATION_ERROR`, `UNAUTHORIZED`/`AUTHENTICATION_ERROR`,
`COMPANY_MISSING`, `PRINT_RENDER_FAILED` plus HTTP-status fallbacks
(401/403/404/422) to localized keys; the raw backend `message` travels only
as a secondary `detail` line. **Exception:** `facturation_pickers.dart:96-98`
and `:261-263` bypass the mapper and render `backendErrorMessage(e)` as the
primary `Text` — flagged as P2 in §11.

**Existing localization tests actually detect regressions:**
- `test\unit\localization_parity_test.dart` (6 tests): asserts maps present;
  **key-set equality across all 6 ordered locale pairs**; no empty values;
  no raw-key fallbacks (minus `kg`); ar/fr not copies of en (< 25% identical);
  exact baseline count 1041 per locale (with documented growth trail to
  "Phase 8 facturation … 54 keys (1041)").
- `test\unit\localization_coverage_test.dart` (3 tests): no hardcoded
  user-visible string in any `lib/**` widget (regex scan); every
  `AppStrings.t` lookup names an existing key; every dynamic key family
  resolves for all enum values.
- 16 per-feature `*_localization_test.dart` files plus
  `widget\localization_init_test.dart` (per-locale exact translations and
  RTL/LTR assertions).

**Machine-detectable gaps:** the two picker raw-message leaks (above) and
the non-locale-aware number/date formatting (below). Everything else in this
section is clean.

---

## 5. RTL Findings and Manual Visual Checks

**Automated evidence:**
- RTL is **implicit**: `MaterialApp(locale: Locale('ar'))` +
  `GlobalWidgetsLocalizations.delegate` supplies
  `Directionality(textDirection: rtl)`. There is no explicit `Directionality`
  widget, no `MaterialApp.builder`, and no `textDirection` override anywhere
  in `lib/main.dart` or the facturation/invoice_clients features.
- Asserted by `test\widget\localization_init_test.dart:185`
  (`Directionality.of(context) == TextDirection.rtl` for Arabic startup) and
  `:225`/`:244` (LTR for French/English).
- `LocaleState.isRtl` (`locale_provider.dart:23`) exists but is **never read
  in `lib/`** (only in `test\unit\locale_test.dart`).
- Explicit `textDirection: TextDirection.ltr` overrides exist only in
  reports/stock/devices numeric-date cells (`report_widgets.dart:277,300,719`,
  `reports_screen.dart:500,508`, `stock_screen.dart:1231+`,
  `adjust_dialog.dart:283`, `devices_screen.dart:340`) — intentional, to keep
  money/percent/dates LTR under RTL.
- Arabic PDF: `locale=ar` default with `shape_text()` bidi/LRM isolation
  (`app\printing\text.py:78-84`, `templates\facture_a4.py`); asserted by
  `test_phase7_facturation_pdf.py:644,665,672`.

**Number/date formatting (facturation UI):** amounts and dates are
**hard-formatted, not locale-aware** — `DateFormat`: 0 occurrences,
`NumberFormat`: 0 occurrences in both feature dirs. Amounts use
`formatMoney` (`customers\customer_models.dart:199`, `.` decimal separator,
trailing-zero trim, no thousand grouping); dates are ISO `yyyy-MM-dd`
(`invoice_form_dialog.dart:412-414`, `invoice_detail_dialog.dart:24-31`).
`intl` is installed but used only in expenses/reports with fixed
`'yyyy-MM-dd'` patterns.

**Requires human visual verification (NOT VERIFIED by automation):**
1. Arabic RTL layout of the Facturation list table, form dialog, line
   dialog, and detail dialog at 1366×768 and 1920×1080 (no overflow, correct
   column mirroring, no mixed-direction label breakage around
   `FAC-2026-0001`-style numbers and `DA` amounts).
2. Arabic PDF visual output (font shaping, table alignment, amount-in-words
   line, multi-page footer) on a real printed or opened PDF.
3. The `NIF: 000999...` prefix in `invoice_clients_screen.dart:255` under
   RTL (hard-coded LTR prefix before a number inside an RTL row).
4. Locale switch (ar → fr → en → ar) while the Facturation screen is open —
   whether the screen rebuilds cleanly or retains stale strings.

---

## 6. Legacy-versus-Modern Calculation Parity Matrix

**Legacy source:** `C:\Users\MSI\Desktop\factura_simple\backend\calc.py`
(149 L), `main.py` (327 L), `models.py` (100 L), `docx_export.py` (175 L),
`frontend\lib\pdf_invoice.dart` (388 L).
**Modern source:** `new_app\backend\app\domain\facturation.py` (439 L),
`services\facturation.py` (1100 L), `repositories\facturation.py` (227 L),
`models\facturation.py` (326 L), `schemas\facturation.py` (276 L),
`printing\{facture_data,text}.py`, `printing\templates\facture_a4.py`.
No legacy code was executed against any database; comparison is source-and-
test-textual, plus the modern suite's own in-process legacy-import parity
sweep (see test evidence below).

### A. Rounding / money math

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| A1 | Money quantum 0.01, `ROUND_HALF_UP` | `calc.py:5,13-14` | `domain\facturation.py:98,176-178` | `test_facturation.py:120` | **MATCH** |
| A2 | Coercion via `Decimal(str(x))`, never float | `calc.py:8-10` | `domain\unit_conversions.py::to_decimal` | — | **MATCH** |
| A3 | Line order: `net_ht = money(gross*(1-d/100))`, `tva = money(RAW net_ht * rate/100)` | `calc.py:29-32` | `facturation.py:190-194` | `test_facturation.py:107` + live parity `480-485` (288 combos) | **MATCH** |
| A4 | Document totals sum already-rounded line values | `calc.py:54-59` | `facturation.py:244-250` | `test_facturation.py:144,153,166` + parity `525-549` | **MATCH** |
| A5 | `total_ttc = money(ht+tva)`, `net_a_payer = money(ttc+timbre)` | `calc.py:59,66` | `facturation.py:250,257` | `test_facturation.py:166` | **MATCH** |
| A6 | Empty lines → zero totals | `calc.py:54` | `facturation.py:244-258` | `test_facturation.py:183` | **MATCH** |

### B. Timbre fiscal (stamp duty)

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| B1 | Applies only when derived `doc_type=="FAC" and payment=="cash"` | `calc.py:35-38`; flag `main.py:156,296` | `facturation.py:214-215`; flag `336` (service `604-632`) | `test_facturation.py:414,422` | **MATCH** |
| B2 | Thresholds `≤300→0`, `≤30000→1%`, `≤100000→1.5%`, else `2%` | `calc.py:40-47` | `facturation.py:217-224` | parity `487-509` (14 boundary values incl. 300/300.01/30000/30000.01/100000/100001) | **MATCH** |
| B3 | `ROUND_CEILING` to whole dinar, floor 5 DA | `calc.py:48-49` | `facturation.py:225-226` | `test_facturation.py:223` (250→0, 11900→119, non-cash→0) | **MATCH** |
| B4 | `show_timbre` gates the calculation, not only display (legacy quirk) | `main.py:160,297` → `calc.py:60` | `facturation.py:321-337,251` | `test_facturation.py:428` | **MATCH** (quirk intentionally preserved) |
| B5 | Duty computed on post-TVA TTC, never taxed itself | `calc.py:59-66` | `facturation.py:250-257` | `test_facturation.py:166` | **MATCH** |
| B6 | Thresholds hard-coded, not settings-driven | `calc.py:40-47` | `facturation.py:204-226` | `test_phase6:596` | **MATCH** |

### C. Document numbering & lifecycle

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| C1 | Format `{doc_type}-{year}-{n:04d}` | `main.py:143` | `repositories\facturation.py:93,156` | `...service.py:185,193`; `...api.py:332` | **MATCH** |
| C2 | Per-`(doc_type, year)` counter; **calendar** year of document date | `models.py:47-50`; `main.py:137-143,199-202` | `models\facturation.py:166-170,296-326`; `services:826-827` | `...service.py:206,216,247,266` | **MATCH** |
| C3 | Omitted date → `date.today()`; date drives the year | `main.py:199` | `services:826` | `...service.py:253`; `...api.py:364` | **MATCH** |
| C4 | Preview proposes next number, read-only | `main.py:299-301,307` | `repositories:162-176`; `services:954` | `...service.py:883` | **MATCH** (advisory) |
| C5 | Preview year basis | always `today.year` (`main.py:299,307`) | `document_date or today` (`services:945-946,954`) | — | **PARTIAL** — differs only when client sends explicit `document_date` to preview (impossible in legacy: `PreviewIn` has no date) |
| C6 | Failed create never consumes a number | single commit `main.py:209-213` | `services:837-860` + flush-not-commit `repositories:108-114` | `...service.py:289`; integration `test_phase5:263` | **MATCH** |
| C7 | Concurrent allocation safety | **none** — read-modify-write, no lock, no unique on `number` | `SELECT…FOR UPDATE` + savepoint seed + `UNIQUE(doc_type,year,number)` (`repositories:92-160`) | integration `test_phase5:193,320` | **MODERN STRONGER** (not a regression) |
| C8 | Number/identity immutable on update | `main.py:221,227-230` | `schemas:128-157` (fields absent) + `services:879-889` | `...service.py:750`; `...api.py:606` | **MATCH** |
| C9 | Update replaces the whole line set atomically | `main.py:233-241` | `services:915-916` (delete-orphan cascade) | `...service.py:715`; `...api.py:666` | **MATCH** |
| C10 | No DELETE for documents | none exists | explicit (no route) `api\v1\factures.py:19-21` | `...api.py:271` | **MATCH** |
| C11 | Update semantics | full PUT, all fields required (`models.py:86-93`) | partial update, `exclude_unset` (`schemas:128-157`) | `...service.py:739,827` | **PARTIAL** — modern is a superset; identical result for full payloads |

### D. Validation

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| D1 | `DOC_TYPES={FAC,DEV,PRO,BC,BL}`, `PAYMENT={cash,transfer,cheque}` | `main.py:15-17,179-183` | `domain:103-106,261-272` + DB CHECKs `models:130-134` | `test_facturation.py:319-335`; `...api.py:373` | **MATCH** |
| D2 | Line rules `qty>0`, `price≥0`, `0≤discount≤100`, `tva∈{0,9,19}` → 422 | `main.py:187-193` | `domain:275-299` + `schemas:88-102` + DB CHECKs | `test_facturation.py:356-390`; `...service.py:513-535`; `...api.py:426,437` | **MATCH** (message language differs — Arabic vs structured English `AppError`) |
| D3 | ≥1 line | `main.py:183-184` | `schemas:125` `min_length=1` | `test_facturation.py:376`; `...service.py:508` | **MATCH** |
| D4 | Client existence → 404 | `main.py:185-186` | `services:825` | `...service.py:462`; `...api.py:384` | **MATCH** (+ archived client 422 = modern extension `...service.py:475`) |
| D5 | Line field defaults when omitted (`qty=1`, `price=0`, `tva=19`, `discount=0`) | `models.py:69-74` | `schemas:73-103` — `quantity` required `>0`; `unit_price_ht`/`tva_rate` required for free-text lines | `...service.py:535` | **MISMATCH (deliberate tightening)** — a legacy default line `{"description":"x"}` is now a 422 |
| D6 | Preview validation | skips invalid lines, no client in payload (`main.py:281-297`) | validates everything, 422 on any bad line, resolves client (`services:933-958`) | `...service.py:923,928`; `...api.py:690,721` | **MISMATCH (deliberate)** |
| D7 | Archived/unknown product on line | no product concept (legacy prefill client-side only) | 404 / archived 422 (`services:977-986`) | `...service.py:483,493` | **MODERN EXTENSION** |

### E. French amount-to-words

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| E1 | `number_to_words_fr` (`soixante et onze`, `quatre-vingts`, `cent(s)`, `mille`, `million`) | `calc.py:71-127` | `facturation.py:342-417` (line-by-line identical) | golden `test_facturation.py:235-265`; **live parity** `576-582` over `0..1200` + 7 extras (1208 integers) | **MATCH** |
| E2 | Sentence: `Arrêté {phrase} à la somme de : {Dinars}… et {centimes} centimes.`, plural rule `>1`, capitalization | `calc.py:130-149` | `facturation.py:111-117,420-439` | `test_facturation.py:267-294`; live parity `551-574` | **MATCH** |
| E3 | Unknown `doc_type` → FAC phrase fallback | `calc.py:148` | `facturation.py:438` | `test_facturation.py:293` | **MATCH** |
| E4 | Words computed from `net_a_payer` | `main.py:174,305` | `services:631` | `...service.py:892` | **MATCH** |
| E5 | Sample `1234.56` → `Mille deux cent trente-quatre dinars algériens et cinquante-six centimes.` | covered by parity `562` and golden `251` | — | **VERIFIED by assertion** |
| E6 | Samples `0.50` and `1234567.89` | not in either param list | logic line-identical (`calc.py:139-149` vs `facturation.py:430-439`); closest covered: `1.5` (`test:279`), `2_500_000` (`:261`) | — | **PARTIAL** — code-identical by source read; no explicit assertion for these two exact values |
| E7 | Words always French regardless of PDF locale | legacy PDF French-only (`pdf_invoice.dart:13-25`) | `facture_data.py:19-20,278` | `test_phase7:644` | **MATCH** |

### F. PDF / document rendering

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| F1 | Totals displayed, never recomputed in printer | `pdf_invoice.dart:93,254-267` | `facture_data.py:13-15` | `test_phase7:477` | **MATCH** |
| F2 | Column/row gating by 5 `show_*` flags | `pdf_invoice.dart:120-128,254-282` | `facture_data.py:233-278`; `facture_a4.py:221-308` | `test_phase7:510,552,593,616` | **MATCH** |
| F3 | `timbre` row only when flag **and** `timbre > 0` | `pdf_invoice.dart:258` | `facture_data.py:242-243` | `test_phase7:593` | **MATCH** |
| F4 | Which date prints | `DateTime.today()` (`pdf_invoice.dart:187`; `docx_export.py:85` — defect) | stored `document.document_date` (`facture_data.py:261`) | `test_phase7:467` (`assert f"Date : {DAY}" in text`, `today not in text`) | **MISMATCH (deliberate defect fix)** |
| F5 | Date display format | `DD/MM/YYYY` (`pdf_invoice.dart:56-59`) | `YYYY-MM-DD` (`text.py:119-120`; asserted `test_phase7:471`) | — | **MISMATCH (display only)** |
| F6 | Money display | `1 234,56 DA` — NBSP grouping + comma (`pdf_invoice.dart:41-49`) | `1234.56 DA` — dot, no grouping (`text.py:93-95`; asserted `test_phase7:489-490` as `f"{Decimal(...):.2f} DA"`) | — | **MISMATCH (display only; values identical)** |
| F7 | Quantity display | whole→int, else full str (`pdf_invoice.dart:51-54`) | ≤3 decimals, trailing zeros stripped (`text.py:98-102`) | `test_phase7:552` | **PARTIAL** — differs only for >3-decimal quantities; modern DB column is `NUMERIC(18,3)` anyway |
| F8 | FR strings (titles, `Espèces/Virement/Chèque`, fiscal identity labels, `Client`, `Net à payer`) | `pdf_invoice.dart:13-25,165-171,254-280` | `labels.py:131,143,153,170-193` | `test_phase7:433,447` | **MATCH** |
| F9 | Notes line | bare text (`pdf_invoice.dart:283-286`) | prefixed `Note : …` (`facture_a4.py:306-308`) | — | **MISMATCH (display only)** |
| F10 | Payment line | `Mode de paiement : X` (`pdf_invoice.dart:278-282`) | `{label} : X` → same in `fr` (`facture_a4.py:302-304`) | — | **MATCH** in fr; localized in ar/en (extension) |
| F11 | Rendering engine | client-side Flutter PDF, Windows Arial, save-dialog | server-side `POST /factures/{id}/pdf`, ReportLab A4 + embedded fonts + audit row | `test_phase7:405,759,785` | **MODERN ARCHITECTURE CHANGE** (functionally equivalent) |
| F12 | Arabic / RTL PDF | none | `locale=ar` + `shape_text()` bidi/LRM | `test_phase7:644,665,672` | **MODERN EXTENSION** |
| F13 | DOCX export | `GET /documents/{id}/docx` (`main.py:260-275`) — **latent bug**: `notes` assigned only inside `if show_payment_method` (`docx_export.py:153-157`) → `UnboundLocalError` when flag off | deliberately absent (`factures.py:19-21`) | — | **MISMATCH (intentional drop; legacy path is buggy)** |
| F14 | Multi-page items/footer repetition | n/a | items header + numbers footer per page | `test_phase7:691` | **MODERN EXTENSION** |

### G. Line payload / product prefill / snapshot

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| G1 | Product → line prefill (`description`, `unit_price_ht`, `tva_rate`) | client-side `invoice_page.dart:209-218` | server-side `_resolve_lines` `services:976-986`; `product_line_prefill` `services:492` | `...service.py:372,383`; `test_facturation_product_prefill.py` (407 L) | **MATCH** (same outcome, moved server-side) |
| G2 | Line is a snapshot (survives product change/deletion) | free-text values only (`models.py:37-44`) | `product_id` FK `ON DELETE SET NULL` + copied columns (`models:256-274`) | integration `test_phase4:98` | **MATCH** |
| G3 | Product TVA default | `tva_rate: float = 19` (`models.py:23`) | `vat_rate` **default 0** (`catalog.py:102-107`); invoice-line `tva_rate` has **no default** (`models\facturation.py:267-268`) | — | **MISMATCH** — legacy silently applied 19; modern products default 0 and free-text lines require an explicit rate (stricter, but a real behavioral delta for product prefill) |
| G4 | Numeric storage | SQLite `float` columns (`models.py:41-44`) | `NUMERIC(18,3)` (`db\base.py:97-110`, `models:265-274`) | `...api.py:310` | **PARTIAL** — values with >3 decimals round in modern; centime results still match for ≤2-dp inputs |
| G5 | Response numeric encoding | JSON numbers/floats (`main.py:166-173`) | decimal **strings** (`schemas:8-10`) | `...api.py:310` | **MISMATCH (wire format, deliberate Phase 0 money rule)** |
| G6 | Client embedded as live reference | `main.py:147,171` | `models\facturation.py:23,48-52` | `...service.py:568` | **MATCH** |
| G7 | Blank `notes` | stored as `""` (`models.py:92`) | trimmed → `NULL` (`services:737-746`) | `...service.py:424` | **MISMATCH (empty string vs null)** |

### H. List / settings / RBAC surface

| # | Behavior | Legacy | Modern | Test | Result |
|---|---|---|---|---|---|
| H1 | List ordering newest-first | `main.py:248` | `services:782` | `...service.py:652`; `...api.py:519` | **MATCH** |
| H2 | List payload | full documents (lines+totals+words per row) | lean summary rows, no lines/totals | `...api.py:509` | **MISMATCH (intentional pagination convention)** |
| H3 | Pagination / filters | none | page/page_size, doc_type, year, client, date range, number `q` | `...service.py:770-805` | **MODERN EXTENSION** |
| H4 | Seller/fiscal identity | `GET/PUT /company`, singleton `Company` row | Phase 6 read view over `app_settings` (`services:1051-1100`) | `test_phase6:296,411,434,452,376` | **PARTIAL** — same fields, different storage surface |
| H5 | Settings never alter Phase 1 math | no settings in `calc.py` | same | `test_phase6:596,672,685` | **MATCH** |
| H6 | RBAC on document routes | none (open API) | `facturation_view` / `facturation_manage` (`factures.py:22-27`) | `...api.py:195,222,259,271` | **MODERN EXTENSION** |

**Live legacy-import parity sweep (evidence quality note):**
`tests\unit\test_facturation.py:44-53` loads
`C:\Users\MSI\Desktop\factura_simple\backend\calc.py` in-process via
`importlib.util.spec_from_file_location` and skips when the path is absent
(`_PARITY_SKIP` L460-463). `TestSourceParity` (L466-582) runs 288 line cases,
28 stamp-duty cases, 240 document-totals cases (5 doc types × 3 payments ×
2 show_timbre × 8 line sets), 90 amount-in-words cases, and 1208
number-to-words integers. This sweep **was executed as part of the backend
unit suite in this audit** (see §10) and passed, confirming runtime parity on
this machine — not just source-textual similarity.

**Mismatches requiring a decision (none silently reconciled):**

| Mismatch | Nature | Release blocker? |
|---|---|---|
| D5 line field defaults dropped (qty/price/tva=19) | Deliberate API tightening | **No** — legacy defaults were footguns; modern returns explicit 422 |
| D6 preview validation strict + client required | Deliberate | **No** |
| F4 PDF prints stored date, not today | Deliberate defect fix | **No** — modern is correct |
| F5/F6/F9 display formats (date/money/notes) | Cosmetic | **No** — values identical; optional polish |
| G3 Product `vat_rate` default 0 (legacy 19) | Behavioral delta | **No for documents** (invoice lines carry explicit rates; prefill reads product value) — **but P3 for product UX**: new products created without choosing a rate prefill 0, not 19 |
| G5 decimal-string wire format | Deliberate Phase 0 rule | **No** |
| G7 notes `""` vs `NULL` | Cosmetic/storage | **No** |
| C5/C11/H2/H3/H4/H7 supersets | Modern extensions | **No** |

---

## 7. Numbering and Document Lifecycle Review

**Format:** `{doc_type}-{year}-{n:04d}` — e.g. `FAC-2026-0001`. Verified at
`repositories\facturation.py:93,156` and legacy `main.py:143`.

**Year selection:** calendar year of `document_date` (default today) —
`services:826-827`; tests `...service.py:206,216,247,266` incl.
`test_year_derived_from_document_date_not_today`.

**Sequence isolation:** one counter row per `(doc_type, year)`; DB unique
constraint `uq_invoice_document_counters_doc_type_year`
(`models\facturation.py:305-310`); document triple unique
`uq_invoice_documents_doc_type_year_number` (`models:140-146`, migration
`0027`). Migration `0026` originally had `(doc_type, number)`; `0027`
replaced it with the triple and added `year INTEGER NOT NULL` + `CHECK year > 0`.

**Concurrent allocation:** `SELECT … FOR UPDATE` row lock, savepoint-based
seed insert with `IntegrityError` retry, bounded 10 attempts → 409 CONFLICT
(`repositories\facturation.py:92-160`). True parallel test:
`test_concurrent_creates_allocate_unique_sequential_numbers`
(`tests\integration\test_phase5_facturation_numbering.py:193-260`) — 6
threads behind a `threading.Barrier`, asserts gapless unique sequential
numbers and counter match. **PostgreSQL-only** (skipif when PG unavailable);
in this audit PG **was** available and the test ran (integration suite §10).

**Immutable identity:** `doc_type`, `year`, `number`, `document_date` are
absent from `InvoiceDocumentUpdateRequest` (`schemas:128-157`) and silently
ignored on hostile input (`StrictBaseModel` has no `extra="forbid"`).
Tests: `test_update_immutable_identity_ignored` (`...api.py:606-626`),
`test_update_immutable_identity_fields_are_inexpressible`
(`...service.py:750-766`). No DB trigger prevents direct SQL UPDATE of
identity columns; the unique triple is the only DB backstop (low risk,
application-level immutability only — flagged §11).

**Failed create never consumes a number:** validation runs before
allocation (`...service.py:280`); allocation flush-not-commit
(`repositories:108-114`); rollback test
`test_failed_persist_rolls_back_number_consumption` (`...service.py:289`)
and integration `test_failed_create_never_consumes_a_number`
(`test_phase5:263-317`).

**Atomic line replacement:** `document.lines = new_lines` via SQLAlchemy
`cascade="all, delete-orphan"` inside one transaction with field updates +
audit row (`services:915-916`). Validation runs **before** the transaction
(`services:870-929`); `test_update_invalid_lines_rolls_back_whole_request`
(`...service.py:814-824`) asserts nothing half-applies.
`test_update_replaces_all_lines_atomically` (`:715-736`) asserts old line
ids are disjoint from new.

---

## 8. Fiscal Stamp and VAT Review

**TVA rates:** strict set `{0, 9, 19}` enforced in domain
(`domain:275-299`), schema (`schemas:88-102`), and DB CHECKs
(`models:240-248`). Per-line TVA computed on the raw (post-discount,
pre-rounding) net base, then rounded to centimes; document TVA is the sum of
already-rounded line values — identical order of operations to legacy
(`calc.py:29-32,54-59`). 288-case live parity sweep confirms.

**Stamp duty (timbre):**
- Trigger: derived `doc_type == "FAC" and payment_method == "cash"` only.
- Thresholds on post-TVA TTC: `≤300 → 0`, `≤30000 → 1%`, `≤100000 → 1.5%`,
  else `2%`; `ROUND_CEILING` to whole dinar, floor 5 DA.
- `show_timbre=False` removes the duty from `net_a_payer` (legacy quirk
  preserved and pinned by `test_facturation.py:428`).
- Duty is never taxed itself; settings are not an input
  (`test_phase6:596`).
- 14-boundary-value parity sweep (`test_stamp_duty_parity`, L487-509)
  covers 300/300.01/30000/30000.01/100000/100001 exactly.

**Settings isolation:** Phase 6 company/fiscal settings
(`services:1051-1100`) are read-only for PDF identity; they never alter
Phase 1 math (`test_phase6:596,672,685`).

---

## 9. API, Permissions, and Data Integrity Review

**Scopes:** `FACTURATION_VIEW`, `FACTURATION_MANAGE`
(`app\models\enums.py:71-73`; 35 total scopes —
`tests\unit\test_enums.py:46`). Seeded to **admin** (all scopes,
`seed.py:42`) and **manager** (`seed.py:82-83`); **cashier has neither**
(`seed.py:88-105`).

**Endpoints (11 total, all permission-checked):**

| Method + path | Permission |
|---|---|
| `POST /api/v1/factures` | `FACTURATION_MANAGE` (`factures.py:149`) |
| `POST /api/v1/factures/preview` | `FACTURATION_VIEW` (`:170`) |
| `GET /api/v1/factures` | `FACTURATION_VIEW` (`:200`) |
| `GET /api/v1/factures/{id}` | `FACTURATION_VIEW` (`:239`) |
| `PUT /api/v1/factures/{id}` | `FACTURATION_MANAGE` (`:256`) |
| `POST /api/v1/factures/{id}/pdf` | `FACTURATION_VIEW` (`:283`) |
| `GET /api/v1/invoice-clients` | `FACTURATION_VIEW` (`invoice_clients.py:88`) |
| `POST /api/v1/invoice-clients` | `FACTURATION_MANAGE` (`:119`) |
| `GET /api/v1/invoice-clients/{id}` | `FACTURATION_VIEW` (`:146`) |
| `PUT /api/v1/invoice-clients/{id}` | `FACTURATION_MANAGE` (`:162`) |
| `DELETE /api/v1/invoice-clients/{id}` | `FACTURATION_MANAGE` (`:178`) |

**Error envelopes** (`app\core\exceptions.py:253-277`):
- 401 `{"error":{"code":"UNAUTHORIZED","message_key":"errors.unauthorized","message":"Missing authentication token"|"Invalid or expired token"|…,"details":{},"request_id":…}}`
- 403 `{"error":{"code":"FORBIDDEN","message_key":"errors.forbidden","message":"Permission denied: facturation_view","details":{"required_permission":"facturation_view"},"request_id":…}}`
- Tested: `...api.py:194-199` (401), `:218-232` (403 + `required_permission`).

**Invoice client archive:** soft delete only (`archived_at` timestamp;
`services:409-428`); idempotent; allowed even while documents reference the
client; documents are never hidden (`factures.py:203-207`,
`repositories:191-197`); new attachments refused with 422
`INVOICE_CLIENT_ARCHIVED` (`services:284-299`); `client_id` FK is
`ondelete="RESTRICT"` (`models:175`). `unarchive` exists in the service
(`services:430-445`) but **no endpoint exposes it** (observation, §11).

**Auth flow:** `POST /api/v1/auth/login` (PIN + user_id, per-IP rate limit)
returns `user.roles[].permissions[].scope`; `GET /auth/me` returns a flat
sorted union. Token validated per-request against `AuthSession`
(existence, `revoked_at`, expiry, `token_hash`) —
`app\api\dependencies.py:69-125`. **No auth bypass / skip-auth flag** exists
in `app\core\config.py`. Placeholder `JWT_SECRET_KEY` is accepted outside
production with a `UserWarning` (`config.py:117-139`) — flagged §11.

**Regression preservation:** router registrations additive-only. Commit
`5cac783` added `factures` router (+1 import +1 include; no line removed);
`238b48b` added `invoice-clients` router (same pattern). Full router list
(`app\api\v1\router.py:48-75`) intact: health, system, auth, users, products,
promotions, packs, categories, customers, suppliers, debts, **factures**,
**invoice-clients**, expenses, inventory, sales, purchases, returns, reports,
exports, print, dashboard, pos, devices, settings, backups. Existing-module
edits in facturation commits are additive (`settings.py` +response fields,
`render.py` +`render_facture`, `labels.py` +keys).

**Seed dependency (deployment gate):** `python -m app.core.seed` is
**required** on existing databases (decision D15; not run at startup —
`seed.py:21-23`, `main.py` lifespan has no seed hook). Upsert is idempotent
and additive (`seed.py:109-165`): creates missing `Permission` rows, then
missing `RolePermission` rows; never deletes. **Until re-seeded, `manager`
(and any role created before Phase 9) lacks both facturation scopes → 403
on all 11 routes (fail-closed, availability impact).** Not run in this audit
(per rules).

---

## 10. Tests and Builds — Exact Commands and Results

All commands executed from the stated working directories on 2026-10-09.
Nothing was installed, migrated, seeded, or served.

| # | Command (cwd) | Executed? | Result |
|---|---|---|---|
| 1 | `pytest tests/unit/test_facturation.py test_facturation_documents_service.py test_facturation_documents_api.py test_facturation_models.py test_facturation_product_prefill.py test_phase6_facturation_settings.py test_phase7_facturation_pdf.py test_invoice_clients_api.py test_enums.py -q` (`new_app\backend`) | **YES** | **2108 passed**, 1 warning, 98.02s |
| 2 | `pytest tests/unit -q` (`new_app\backend`) | **YES** | **3598 passed**, 4 warnings, 703.68s (11m43s) |
| 3 | `pytest tests/integration -q` (`new_app\backend`) | **YES** | **106 passed**, 1 warning, 322.70s (5m23s) — **PostgreSQL available**; includes `test_phase5_facturation_numbering.py` concurrency + constraint tests (not skipped) |
| 4 | `ruff check app tests` (`new_app\backend`) | **YES** | **220 errors** — matches established baseline (no new violations) |
| 5 | `mypy --strict app` (`new_app\backend`) | **YES** | **454 errors in 70 files** — matches established baseline |
| 6 | `flutter analyze` (`new_app`) | **YES** | **No issues found** (2.8s) |
| 7 | `flutter test test/widget/facturation_screen_test.dart test/widget/invoice_clients_screen_test.dart test/widget/facturation_nav_visibility_test.dart test/unit/localization_parity_test.dart test/unit/localization_coverage_test.dart test/unit/locale_test.dart test/unit/facturation_models_test.dart` (`new_app`) | **YES** | **48 passed**, 11s |
| 8 | `flutter test` (`new_app`) | **YES** | **1601 passed**, 2m45s |
| 9 | `flutter build windows --debug` (`new_app`) | **YES** | **PASS** — `build\windows\x64\runner\Debug\supermarket_pos.exe` (36.7s); output under gitignored `build/` |
| 10 | `git diff --check` (repo root) | **YES** | exit 0, clean (no whitespace errors) |
| 11 | `git status --short --branch` (repo root) | **YES** | `## main...origin/main`; 0 modified tracked; only pre-existing untracked artifacts |
| 12 | `alembic upgrade head` / migrations | **NOT RUN** | **Reason:** audit rules forbid running migrations |
| 13 | `python -m app.core.seed` | **NOT RUN** | **Reason:** audit rules forbid seeding |
| 14 | Production/dev server (`uvicorn …`) | **NOT RUN** | **Reason:** audit rules forbid starting servers |
| 15 | Physical printing / real PDF open-and-eyeball | **NOT RUN** | **Reason:** requires hardware + human visual verification; automated PDF-text assertions cover structure only |
| 16 | Real multi-PC LAN operation | **NOT RUN** | **Reason:** requires multiple devices; automated device-guard tests cover logic only |
| 17 | `flutter build windows --release` | **NOT RUN** | **Reason:** debug build already validates toolchain; release signing/config not audited |

**Interpretation caveats (per rules):** a green suite is **not** proof of
physical printing quality, real multi-PC LAN behavior, or production
readiness. The live legacy-parity sweep (command 2) did import
`factura_simple\backend\calc.py` in-process read-only; it did not touch any
legacy database.

---

## 11. Confirmed Findings by Severity

### P0 — release blocker / data integrity / security risk

**None confirmed.** No data-integrity violation, no privilege escalation,
no SQL injection, no unauthenticated access path, and no calculation
divergence from legacy was found in code + executed tests.

### P1 — major functional defect

**None confirmed.** All 11 endpoints, all 5 document types, all 3 TVA rates,
all stamp-duty thresholds, numbering, immutability, rollback, PDF structure,
and amount-in-words behave as specified and pass their assertions.

### P2 — important quality or localization gap

| # | Finding | Evidence | Impact |
|---|---|---|---|
| P2-1 | **Deployment gate:** existing databases seeded before Phase 9 will 403 all roles (including admin) on all 11 facturation routes until `python -m app.core.seed` is run. No startup warning, no migration data-fix. | `seed.py:21-23,109-165`; `main.py` lifespan has no seed hook | Availability, not security (fail-closed). Must be in the release runbook. |
| P2-2 | **Raw backend message leak:** `facturation_pickers.dart:96-98` and `:261-263` render `backendErrorMessage(e)` (untranslated English/structured text) as the **primary** error `Text`, bypassing the proper `facturation_error.dart` mapper. | File:line quoted; mapper contract at `facturation_error.dart:1-6` | Untranslated error flash in AR UI for client/product picker failures. |
| P2-3 | **Facturation amounts/dates not locale-aware in Flutter UI:** always `.` decimal separator, no thousand grouping, ISO `yyyy-MM-dd` dates, in list, form, detail, and line dialogs. | 0 `DateFormat`/`NumberFormat` in both feature dirs; `formatMoney` at `customer_models.dart:199` | Quality gap for fr locale (expects `1 234,56`); ar uses same Western digits, so lower severity there. |
| P2-4 | **Phase 9 Stage B report file is absent** from `facture-docs/` (delivered in-chat only). The permanent record for backend permissions is incomplete. | `Get-ChildItem facture-docs` → only Stage C report | Documentation gap; audit re-verified the backend evidence instead (§9, §10). |
| P2-5 | **Concurrency test is PostgreSQL-gated:** if the PG test DB is unreachable, `test_phase5_facturation_numbering.py` silently skips and the `FOR UPDATE` guarantee has no active gate (SQLite ignores row locks). | `tests\conftest.py:70-84`; `pytestmark` skipif | Test-coverage risk in environments without PG; **not** an issue in this audit (PG was available, 106 integration tests ran). |
| P2-6 | **No unarchive endpoint:** `InvoiceClientService.unarchive` exists but is unreachable via API; restoring an archived client requires out-of-band DB access. | `services:430-445`; `invoice_clients.py` has no unarchive route | Operational friction; archive is soft and reversible in the DB. |

### P3 — optional enhancement

| # | Finding | Evidence |
|---|---|---|
| P3-1 | **DOCX export undecided** — see §13. |
| P3-2 | PDF display formats differ from legacy (date `YYYY-MM-DD` vs `DD/MM/YYYY`; money `1234.56 DA` vs `1 234,56 DA`; notes prefixed `Note :`). Values identical; cosmetic. | `text.py:93-95,119-120`; `pdf_invoice.dart:41-59` |
| P3-3 | Product `vat_rate` defaults to **0** (legacy `tva_rate` defaulted **19**); new products created without choosing a rate prefill 0 onto invoice lines. | `catalog.py:102-107` vs legacy `models.py:23` |
| P3-4 | Preview number year basis differs when client sends explicit `document_date` (modern uses it; legacy always `today.year`). Edge case only. | `services:945-946,954` vs `main.py:299,307` |
| P3-5 | Notes `""` → stored `NULL` (legacy stored `""`). | `services:737-746` vs `models.py:92` |
| P3-6 | Immutable identity is application-level only (no DB trigger on `doc_type`/`number`/`document_date`); no optimistic locking — concurrent PUTs are last-write-wins. | `models:140-146` (unique triple only); no `version` column |
| P3-7 | Placeholder `JWT_SECRET_KEY` / `APP_SECRET_KEY` accepted outside `APP_ENV=production` with only a warning. | `config.py:117-139` |
| P3-8 | `LocaleState.isRtl` is dead code in `lib/` (never read). | `locale_provider.dart:23` |
| P3-9 | Hard-coded `NIF:` prefix in `invoice_clients_screen.dart:255` is not run through `AppStrings.t`. | File:line |
| P3-10 | Samples `0.50` and `1234567.89` have no explicit amount-in-words assertion (logic is line-identical to legacy; covered indirectly by 1208-integer + 90-amount sweeps). | `test_facturation.py:235-294,551-582` |

---

## 12. Missing Coverage and Manual Verification Checklist

### Missing automated test coverage
1. Amount-in-words assertions for exactly `0.50` and `1234567.89` (P3-10).
2. A test that fails when `facturation_pickers.dart` renders a raw backend
   message as primary text (would lock in P2-2).
3. Locale-aware number/date formatting tests for facturation (would lock in
   or defer P2-3).
4. A startup/migration warning test for the seed dependency (would surface
   P2-1 earlier).
5. SQLite-side emulation or a documented skip reason surfacing for the PG-only
   concurrency suite (P2-5).

### Manual verification still required
- [ ] **Arabic RTL visual pass** on Facturation list, form, line dialog,
      detail dialog at 1366×768 and 1920×1080 (§5 items 1–3).
- [ ] **Arabic PDF open-and-inspect:** font shaping, table mirroring,
      amount-in-words line, multi-page footer, fiscal identity block.
- [ ] **Locale switch live** (ar → fr → en → ar) with Facturation screen open.
- [ ] **FAC-cash + timbre end-to-end:** create document cash ≤300 (no stamp),
      301–30000 (1%), 30000.01–100000 (1.5%), >100000 (2%), verify
      `net_a_payer` and PDF stamp row on real UI.
- [ ] **Concurrent create on two PCs** (or two browser tabs) against the same
      PG database — confirm unique sequential numbers under real LAN load
      beyond the automated 6-thread test.
- [ ] **Seed run on a copy of a production-like DB:** confirm `manager` gains
      both scopes, admin unchanged, cashier still denied, and no other
      role/permission rows are altered.
- [ ] **Physical print** of one FR A4 and one AR A4 (or high-res PDF
      open) — automated text extraction cannot validate visual layout.
- [ ] **Archived invoice client** flow: archive → list still shows its
      documents → new document attempt → 422 localized toast.
- [ ] **Permission matrix smoke in the running app:** admin sees both nav
      entries; manager sees both; cashier sees neither; direct URL navigation
      by cashier hits backend 403 (not a blank screen).

### Environment limitations (this audit)
- No physical printer, no second PC for LAN, no production database access.
- `flutter build windows --release` not run (debug build sufficed for
  toolchain validation).

---

## 13. DOCX Requirement Status

**Status: UNDECIDED / OPTIONAL — not a confirmed requirement.**

Evidence:
- `app\api\v1\factures.py:19-20` states explicitly: *"There is deliberately
  NO DELETE endpoint … and no DOCX export."* — a deliberate Phase 5 decision.
- `python-docx` is **not installed** for the modern backend
  (`docs\PHASE_15_PRINTING_EXPORTS_ANALYSIS.md:355`: *"`python-docx`, `qrcode`
  — legacy-only, not installed for the modern backend"*; `pyproject.toml`
  runtime deps do not include it).
- The only repo-root mention (`README.md:68: "Document rendering (PDF/DOCX)"`)
  describes the **excluded legacy B2B module** of the forensic comparison
  package, not the modern app scope (`README.md:71` explicitly excludes
  B2B-only functionality).
- Legacy `docx_export.py` has a **latent bug**: `notes` is assigned only
  inside `if show_payment_method` (`docx_export.py:153-157`), so
  `show_payment_method=False` raises `UnboundLocalError`. Porting it as-is
  would import a defect; a clean-room reimplementation would be needed.

**Recommendation:** keep DOCX out of the Phase 10 scope unless the reviewer
or a customer explicitly requests it. If requested later, treat it as a new
sub-phase with its own parity matrix and bug-free reimplementation — do not
port the legacy file.

---

## 14. Three-Document Parity Fixture Recommendation

**Recommendation: YES — a small three-document fixture is useful**, but its
value is **human visual QA of the PDF + amount-in-words + totals together**,
not calculation coverage (the automated sweeps in §6 already cover the
combinatorial math: 288 line cases, 28 stamp cases, 240 document-totals
cases, 1208+90 word cases).

**Proposed fixture (create in a future stage, NOT in this audit):**

| # | Document | Why |
|---|---|---|
| 1 | **FAC, cash, mixed TVA lines (0/9/19), discount on one line, TTC in the 1% stamp band (e.g. 1 000–5 000 DA)** | Exercises the full timbre path, mixed-rate TVA sum, amount-in-words with centimes, and the `timbre` PDF row — the single most fiscal-critical document. |
| 2 | **DEV, transfer, no discount, TTC in the no-stamp band (≤300 DA)** | Exercises a non-FAC type (no stamp ever), a non-cash payment, a "Zéro dinar algérien." / low-amount words edge, and a different numbering sequence (`DEV-2026-0001` vs `FAC-2026-0001`). |
| 3 | **BL (or PRO), cheque, `show_timbre=False` and `show_amount_words=False`, blank notes** | Exercises the legacy `show_timbre` calculation quirk (duty removed from `net_a_payer` even though the flag is a display flag), the disabled-words PDF section, the blank-notes path, and a third sequence. |

**Edge cases the three documents should together hit:** zero-TVA-only lines;
100% discount line (net 0); quantity with 3 decimals; year boundary
(document dated 31 Dec vs 1 Jan to confirm sequence rollover); archived
invoice client referenced by an existing document (list still shows it).

**Do not import real customer data** into the fixture; use synthetic clients
and products.

---

## 15. Prioritized Phase 10 Implementation Plan

For the reviewer to approve before any implementation begins:

| Priority | Work item | Rationale | Est. risk |
|---|---|---|---|
| **1** | **Release runbook entry + optional startup warning** for `python -m app.core.seed` (P2-1). Either a docs-only fix or a one-line lifespan log when `facturation_view` is absent from the `manager` role. | Highest operational risk; fail-closed 403 for admin on a live deployment. | Low |
| **2** | **Fix raw-message leak** in `facturation_pickers.dart:96-98,261-263` — route through `facturationError`/`invoiceClientsError` mapper like the providers already do (P2-2). Add a widget test asserting the localized primary text. | Small, contained, visible AR-quality win. | Low |
| **3** | **Write the missing Phase 9 Stage B report file** into `facture-docs/` from the in-chat evidence + this audit's §9 (P2-4). | Documentation completeness; cheap. | None |
| **4** | **Arabic RTL + PDF human visual QA pass** (§12 checklist) — no code, just reviewer time. | Closes the largest NOT VERIFIED area. | None |
| **5** | **Three-document parity fixture** (§14) built as automated API-level tests + one manual PDF inspection each. | Locks the fiscal path end-to-end; feeds the visual QA. | Low |
| **6** | **Locale-aware money/date formatting in facturation UI** (P2-3) — decide whether to adopt `intl` `NumberFormat`/`DateFormat` per locale or explicitly keep ISO/Western as a house style. If adopted, apply consistently across POS/stock/reports too (they share the same gap). | Quality; larger blast radius if done only for facturation. | Medium (cross-feature consistency) |
| **7** | **Product `vat_rate` default decision** (P3-3) — either change the default to 19 to match legacy, or add a product-form nudge, or accept 0 and document it. | Small UX/product decision. | Low |
| **8** | **Unarchive endpoint** for invoice clients (P2-6) if the reviewer wants API parity with the service layer. | Nice-to-have. | Low |
| **9** | **Amount-in-words goldens** for `0.50` and `1234567.89` (P3-10); **identity-column DB trigger / optimistic locking** (P3-6); **JWT secret hard-fail outside production** (P3-7); **drop dead `isRtl`** (P3-8); **localize `NIF:`** (P3-9). | Hygiene backlog; none blocking. | Low |
| **10** | **DOCX** — only if explicitly requested (§13). Clean-room, not a port. | Undecided feature. | Medium if taken |

**Explicitly out of scope for Phase 10:** redesigning the calculation core
(it is parity-verified), changing the decimal-string wire format, adding
routes/permissions beyond what exists, or reopening Phase 1–9 architectural
decisions.

---

## 16. Release Readiness Verdict

**Verdict: READY for a controlled release candidate, conditional on the
following being true at deployment time:**

1. `python -m app.core.seed` is run (or confirmed already run) on the target
   database after migrating to a build that includes Phase 9 scopes —
   otherwise all facturation routes 403 for everyone (P2-1).
2. `JWT_SECRET_KEY` and `APP_SECRET_KEY` are set to real secrets and
   `APP_ENV=production` is used outside development (P3-7).
3. The Arabic RTL + Arabic PDF manual visual pass (§12) is executed and signed
   off by a human reviewer — automated tests cover structure and text
   extraction, not visual layout.
4. The reviewer accepts the deliberate legacy mismatches in §6 (stricter
   validation, stored-date PDF, decimal-string wire format, display-format
   differences) as intended modern behavior, not regressions.

**What this verdict is NOT claiming:** physical print quality, real multi-PC
LAN behavior under load, production database migration safety (migrations
were not run in this audit), or that every P2/P3 has been fixed — only that
no P0/P1 defect was found and every executed automated gate passes at its
baseline.

**Blocking items before a broader GA:** none classified P0/P1. The P2s are
quality/operational items that can ship in Phase 10 proper (items 1–4 of §15)
without delaying a controlled RC if the runbook and manual QA are in place.

---

## 17. Git Status After Audit and Report Creation

**Before report creation:**
```
## main...origin/main
?? new_app/bar.pdf
?? new_app/bar2.pdf
?? new_app/reports_financial_2026-09-25_2026-10-01_2026-10-01-092831.csv
?? new_app/reports_sales_2026-09-22_2026-10-01_2026-10-01-115842.csv
?? new_app/sale_INV-20261004-142659-926-0082_2026-10-04-192350.pdf
?? new_app/test/widget/failures/
?? new_app/test/widget/goldens/
```
`git diff --check` → exit 0, clean.

**After creating this report** (the only permitted filesystem write):
- New untracked file: `facture-docs\PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md`
  (this file).
- **Zero** tracked files modified, added, or deleted.
- **Zero** files staged, committed, or pushed.
- All pre-existing untracked artifacts preserved untouched.
- `flutter build windows --debug` wrote only under gitignored `new_app\build\`.
- Backend test runs used in-memory SQLite and the dedicated
  `supermarket_pro_test` PostgreSQL database; the production database was
  never touched. No migrations or seeds were executed.

**Exact report path:**
`C:\Users\MSI\Desktop\supermarket_logiciel\facture-docs\PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md`

---

*End of Phase 10 Stage A read-only audit. Stopping here per the mandate —
Phase 10 implementation must not begin until this report is approved.*
