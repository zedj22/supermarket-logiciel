# Facturation Module — Final QA Report

**Date:** 2026-10-10
**Final checkpoint:** `e2567fe` — *feat: add facturation variant unit and pack selection*
**Previous checkpoint:** `0ae53b1` — *feat: support facturation variants units and packs*
**Scope commits:** `a01f52e` → `88b6412` → `0ae53b1` → `e2567fe`

---

## 1. Final repository state

| Check | Result |
|---|---|
| `HEAD` | `e2567fe537f9a6362dbb0dd8e0f420dd71b14f23` |
| `origin/main` | `e2567fe537f9a6362dbb0dd8e0f420dd71b14f23` (in sync) |
| Working tree | Clean except the 9 preserved untracked artifacts (`bar.pdf`, `bar2.pdf`, 2× `facture_FAC-2026-0001_*.pdf`, 2× `reports_*.csv`, `sale_INV-*.pdf`, `test/widget/failures/`, `test/widget/goldens/`) — untouched |
| Backend delta 0ae53b1→e2567fe | **Empty** (`git diff 0ae53b1 e2567fe -- new_app/backend` = no files; the Flutter checkpoint changed only `new_app/lib` + `new_app/test`) |

## 2. Test results

All commands were **rerun on the final checkpoint `e2567fe`** unless explicitly marked as inherited.

### Rerun on `e2567fe`

| Gate | Command (from) | Result |
|---|---|---|
| Flutter analyze | `flutter analyze` (`new_app/`) | **0 issues** |
| Full Flutter suite | `flutter test` (`new_app/`) | **1682 passed, 0 failed** (baseline 1664 + 18 new tests) |
| RTL layout test | `flutter test test/unit/rtl_layout_test.dart` | **passed** |
| Facturation preview sheet | `flutter test test/widget/invoice_preview_sheet_test.dart` | **11 passed** |
| Localization parity | `flutter test test/unit/localization_parity_test.dart` | **6 passed** (en baseline deliberately updated 1064→1065 for `select_pack`) |
| Backend integration | `.venv\Scripts\python.exe -m pytest tests/integration -q` (`backend/`) | **106 passed** (5m24s) |
| Backend unit (full) | `.venv\Scripts\python.exe -m pytest tests/unit -q` | **3640 passed** (12m03s) — see note |
| Facturation unit subset | `.venv\Scripts\python.exe -m pytest tests/unit -q -k "facturation or facture"` | **2094 passed**, 1546 deselected |
| Ruff (app) | `.venv\Scripts\python.exe -m ruff check app` | **61 findings = 61 baseline** |
| Ruff (tests) | `.venv\Scripts\python.exe -m ruff check tests` | **159 findings = 159 baseline** (combined **220 = 220**) |
| Mypy | `.venv\Scripts\python.exe -m mypy app` | **454 findings in 70 files = 454 baseline** |

**Unit-suite note (3640 vs previously reported 3598):** the backend tree is byte-identical between `0ae53b1` and `e2567fe` (verified with `git diff`), so the suite contents cannot have changed between the two checkpoints. The rerun count of **3640** is authoritative; the earlier 3598 figure was an undercount from how that run was invoked during WP-A2. This is a reporting correction, **not** a regression — the subset count (2094), integration (106), and all baselines match exactly.

### Inherited (not rerun today)

None claimed. Every number above was produced on `e2567fe`.

## 3. Functional acceptance criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Company information/settings | **PASS — automated test verified** | `settings_company_section_test.dart` (7 company/fiscal fields, whole-form save, ar/fr/en labels), `settings_provider_test.dart`, `test_phase6_facturation_settings.py` (singleton row, partial update, strip/blank) |
| 2 | Invoice client isolation from POS Customers | **PASS — automated test verified** | `test_facturation_models.py::test_no_customer_link_and_no_pos_tables_modified`, `test_facturation_product_prefill.py::test_product_customer_domain_separation` |
| 3 | Plain-product, free-text, variant, selling-unit, pack lines | **PASS — automated test verified** | Backend `test_facturation_option_lines.py` (34 tests: combination rules, prefills, resolvers) + `test_facturation_product_prefill.py`; Flutter `facturation_models_test.dart` (12 option tests) + `invoice_line_dialog_options_test.dart` (6 dialog tests) |
| 4 | Correct payload serialization and edit rehydration | **PASS — automated test verified** | Flutter payload round-trips (variant/unit/pack ids sent, plain-product and free-text payloads unchanged) + dialog rehydration widget tests, incl. ids-only name recovery from the "Product · Option" convention |
| 5 | FAC/DEV/PRO/BC/BL document types | **PASS — automated test verified** | `DocTypeValue.all` pin + backend doc-type totals parity (`test_facturation.py::test_document_totals_parity`) |
| 6 | Numbering and immutable document identity | **PASS — automated test verified** | `test_facturation_documents_service.py` (zero-padded, per-type/year counters, rollback, DB unique backstop, immutable fields inexpressible) + API tests `test_numbering_sequence_through_api`, `test_update_immutable_identity_ignored` |
| 7 | TVA 0/9/19; stamp-duty (timbre); French amount-in-words | **PASS — automated test verified** | `test_tva_rates[0/9/19]`, timbre suite (FAC+cash only, threshold 300, `show_timbre=false`), `test_amount_in_words_parity` / `test_number_to_words_parity` vs legacy |
| 8a | Preview sheet rendering (identity, lines, totals, words) | **PASS — automated test verified** | `invoice_preview_sheet_test.dart` (11 tests incl. company_missing degradation) |
| 8b | Server PDF structure/fiscal identity | **PASS — automated test verified** | `test_phase7_facturation_pdf.py` (company+client fiscal identity, `COMPANY_MISSING` refusal) |
| 8c | Arabic RTL appearance and French locale **on the printed PDF / on screen, visually** | **PASS — code reviewed, manual verification still required** | RTL text-layout is enforced by `rtl_layout_test.dart` (no physical left/right alignment in `lib/`), but real PDF font shaping and visual RTL print appearance have not been eyeballed by a human |
| 9 | Permissions and missing-company validation | **PASS — automated test verified** | `test_denied_roles_get_403_envelope`, `test_cashier_is_denied_facturation_create`; `COMPANY_MISSING` (422 before any rendering) in `test_phase7_facturation_pdf.py`; UI degrades to `company_missing` hint without crashing |
| 10 | No stock deductions, reservations, or inventory movements | **PASS — automated test verified** | `test_facturation_option_lines.py::TestInventoryIsolation` (variant/unit/pack/product lines never touch stock) + `test_facturation_product_prefill.py::test_inventory_is_not_touched` |
| 11 | No regressions to POS, Sales, Inventory, Debts, LAN/multi-PC, devices, barcode labels, receipt printing | **PASS — automated test verified** | Facturation commits (`a01f52e^..e2567fe`) touch only facturation files, the settings company section, shared strings, and their tests — no POS/Sales/Inventory/Debts/LAN/device/label/receipt source file changed. Full suites green on final checkpoint: Flutter 1682, backend unit 3640, integration 106 |

## 4. Manual release checklist (Windows)

**Setup**
- [ ] Start backend (migrations run to head incl. `0029_facturation_option_identity`) and the Flutter app; log in as admin.

**Settings**
- [ ] Settings → Company: fill name/address/phone + fiscal fields (RC, NIF, AI, NIS, RIB); save; reload and confirm persistence.
- [ ] In French and Arabic, confirm the company section labels render correctly.

**Client and document creation**
- [ ] Facturation → Invoice Clients: create a client; confirm it does **not** appear under POS → Customers and vice versa.
- [ ] Create a FAC document with a normal product line; save; reopen for edit; confirm the product and quantities round-trip.

**Line types (per product configured with variants/selling units, and one pack)**
- [ ] Add a **variant** line → confirm auto-prefilled price and "Product · Variant" description; select a different variant and confirm the price updates.
- [ ] Add a **selling-unit** line → confirm effective unit price prefill.
- [ ] Add a **pack** line → confirm pack name/price prefill, no product options shown, description optional.
- [ ] Add a **free-text** line (no product) → confirm description/price/TVA all required.
- [ ] Edit each saved line; confirm the variant/unit/pack selection is still shown and saved.
- [ ] Confirm stock quantities are unchanged after creating the document (Inventory screen).

**Fiscal behavior**
- [ ] FAC + cash + total ≥ 300 → timbre (stamp duty) appears; non-FAC or transfer/cheque → no timbre.
- [ ] Lines at 0%, 9%, 19% TVA compute correctly; totals match a manual calculation.
- [ ] Confirm the amount-in-words line matches the net à payer (French).

**Preview and PDF**
- [ ] Open the preview sheet in **Arabic** — RTL layout, Arabic labels, correct order.
- [ ] Repeat in **French**.
- [ ] Export/print the PDF in both locales; visually check Arabic glyph shaping (letters joined, right-to-left), company/client fiscal blocks, and that the PDF matches the preview.
- [ ] Delete the company name in settings and attempt PDF export → expect the `company_missing` error, not a crash.

**Permissions**
- [ ] Log in as a cashier (no `facturation_view`) → facturation UI hidden/403; document create denied.
- [ ] Log in as a role with `facturation_view` but not create → view allowed, create denied.

**Inventory isolation (re-check end-to-end)**
- [ ] Note product stock → create/preview/save a facturation document with variant/unit/pack lines → stock and movement history unchanged.

**LAN / second PC (if available)**
- [ ] From a second PC, open the same facturation list; create a document; confirm the number sequence continues without duplicates and the first PC sees it after refresh.

## 5. Final conclusion

### `READY FOR MANUAL ACCEPTANCE TESTING`

Automated verification is complete and green on the final checkpoint: **Flutter 1682/1682, analyze 0; backend integration 106; backend unit 3640; facturation subset 2094; ruff 220=220; mypy 454=454.** The module is not labeled `READY FOR RELEASE` because required manual checks remain — chiefly visual PDF/RTL appearance (8c), real-device/LAN behavior, and hands-on permission/role confirmation.

**Known limitations**
- Edit-mode variant/unit display names are recovered from the description convention ("Product · Option"); if a legacy line's description was hand-edited, the button may show the edited suffix instead of the true option name (the stored id remains authoritative and is re-sent unchanged).
- Facturation pricing deliberately ignores POS promotions/wholesale; timbre/TVA/numbering semantics were not altered from legacy parity.
- Server PDF remains the authoritative artifact; the in-app preview is a faithful mirror but not the printed output.
- Ruff/mypy findings equal pre-existing baselines; none were introduced by this project (all citations are on pre-existing or renumbered code).

**Checks not performed in this report** — rerun with:
```powershell
cd new_app; flutter analyze; flutter test
cd backend
.venv\Scripts\python.exe -m pytest tests/integration -q
.venv\Scripts\python.exe -m pytest tests/unit -q
.venv\Scripts\python.exe -m pytest tests/unit -q -k "facturation or facture"
.venv\Scripts\python.exe -m ruff check app; .venv\Scripts\python.exe -m ruff check tests
.venv\Scripts\python.exe -m mypy app
```
(All of the above were executed successfully on `e2567fe` as recorded in section 2.)
