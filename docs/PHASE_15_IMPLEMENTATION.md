# Phase 15 — Printing / Exports — Implementation Record (Step B)

**Status:** STEP B IMPLEMENTED — backend + Flutter print/export paths and their
test suites complete. **No commits, no pushes** (per execution rules).
**Baseline:** Phase 14 closed at `879c8e5`; Step A analysis in
`docs/PHASE_15_PRINTING_EXPORTS_ANALYSIS.md` (owner answers Q1–Q12 apply).

---

## 0. Verification snapshot (exact results, executed 2026-10-02)

| Gate | Command (cwd) | Result |
|---|---|---|
| Backend tests | `python -m pytest -q` (`new_app/backend`, venv) | **1061 passed, 4 warnings** (warnings pre-existing), 488 s |
| Backend lint (baseline scope) | `python -m ruff check app` | **64 errors — identical to Phase 14 baseline**, 0 in any Phase 15 file |
| Flutter analyzer | `flutter analyze` (`new_app`) | **No issues found!** |
| Flutter tests | `flutter test` (`new_app`) | **1163 passed**, exit 0, ~170 s |
| Windows debug build | `flutter build windows --debug` (`new_app`) | **Built OK** — `build\windows\x64\runner\Debug\supermarket_pos.exe`, exit 0, 16.7 s |
| VCS state | `git log -1` / `git status` | HEAD still `879c8e5 phase-14` — **no Phase 15 commit, no push** |

Phase 15 test additions: backend **108** tests
(`tests/unit/test_print_export.py` 52 + `tests/unit/test_export_render.py` 56);
Flutter **24** tests (`phase15_print_export_test.dart` 12 +
`print_export_localization_test.dart` 9 + reports unified-export group 3;
the pos print-preview group was ported 3→3 on top of the existing 2 print
failure tests).

---

## 1. Files

### Backend — new

| File | Purpose |
|---|---|
| `app/api/v1/print.py` | `POST /api/v1/print` — sale/return → PDF bytes + `Content-Disposition` |
| `app/api/v1/exports.py` | `POST /api/v1/exports` — report → XLSX/PDF bytes + `Content-Disposition` |
| `app/services/print.py` | render orchestration, scope check, audit rows, error codes |
| `app/services/export.py` | same for exports (row limit / too-large guards) |
| `app/printing/` | layout engine (80 mm + A4), one model per document (G8) |
| `app/printing/fonts/` | IBM Plex Sans Arabic (OFL — redistribution-safe, G7) |
| `app/exporting/` | XLSX (openpyxl) + PDF renderers |
| `app/core/filenames.py` | sanitized server-side download names (§10.1) |
| `app/schemas/export.py` | `ExportRequest` / `PrintRequest` (`StrictBaseModel`, no extra fields) |
| `tests/unit/test_print_export.py` | print endpoint suite |
| `tests/unit/test_export_render.py` | export render suite |
| `scripts/g7_spike.py` (+`g7_spike_out/`) | G7 Arabic shaping/bidi spike artifacts |

### Backend — modified

| File | Change |
|---|---|
| `app/api/v1/router.py` | register `exports_router` (`/exports`) + `print_router` (`/print`) |
| `app/models/enums.py` | `AuditAction` += `EXPORT`, `PRINT` (additive; one row per attempt) |
| `app/schemas/sale.py` | `StoreInfo` + additive detail-only `customer_name` / `cashier_name` / `store` (G19) |
| `app/services/sale.py` | populate header display names on the DETAIL path only (`with_header=True`, no list N+1) |
| `pyproject.toml` | deps: `reportlab>=4.0`, `arabic-reshaper>=3.0`, `python-bidi>=0.4.2`, `openpyxl>=3.1` |

### Flutter — new

| File | Purpose |
|---|---|
| `lib/features/pos/print_document.dart` | `fetchPrintDocument` → `POST /print` (`ResponseType.bytes`) |
| `lib/features/pos/print_preview_dialog.dart` | preview-first dialog: fetch → rasterize seam → confirm/cancel/save |
| `lib/features/pos/pdf_preview.dart` | injectable `pdfPreviewProvider` seam (rasterization isolated for tests) |
| `lib/features/reports/report_export_dialog.dart` | unified format dialog: CSV / XLSX / PDF, `null` = cancel |
| `lib/network/byte_download.dart` | byte-endpoint helpers: filename from `Content-Disposition`, envelope re-decode for error mapping |

### Flutter — modified

| File | Change |
|---|---|
| `lib/features/pos/print_service.dart` | `printPdf(bytes, {paper, filename})` via `printing` plugin (`Printing.layoutPdf`); `printText` kept as legacy path; `PrintServiceException.code` (`printer_unavailable`) |
| `lib/features/pos/sale_detail_dialog.dart` | print/reprint run the preview flow; print failure renders localized error, never a success toast (§16.2) |
| `lib/features/reports/report_export.dart` | `exportReportFile`: `POST /exports` → save dialog prefilled with server filename → localized toast |
| `lib/features/reports/reports_error.dart` | envelope codes mapped by identity: `EXPORT_FORMAT_UNSUPPORTED`, `EXPORT_ROW_LIMIT`, `EXPORT_TOO_LARGE`, `EXPORT_RENDER_FAILED`, `PRINT_RENDER_FAILED`, `MISSING_FONT` |
| `lib/features/reports/reports_screen.dart` | one export button → format dialog → CSV (frozen) or XLSX/PDF (server); **export readiness defect fixed** (§5.1) |
| `lib/features/reports/report_export_dialog.dart` | **pop-navigator defect fixed** (§5.2) |
| `lib/core/strings.dart` | 19 Phase 15 keys × ar/fr/en (print dialog, papers, save-PDF, export formats, typed error headlines) |
| `pubspec.yaml` | deps: `printing: ^5.15.1`, `pdf: ^3.13.1` (+ `windows/…` generated plugin registration) |

### Flutter tests — new / modified

- NEW `test/widget/phase15_print_export_test.dart` (12): preview confirm/cancel,
  fetch → typed error → retry, RTL Arabic smoke, save-PDF (success + user
  cancel), format dialog, `exportReportFile` (success body + server filename,
  `EXPORT_FORMAT_UNSUPPORTED`, `EXPORT_TOO_LARGE`).
- NEW `test/unit/print_export_localization_test.dart` (9): 19 keys × 3 locales
  exist / non-empty / never raw key, ar≠en and fr≠en majorities, 8 reused keys.
- MODIFIED `test/widget/reports_screen_test.dart` (+3): format dialog opens and
  cancel is neutral (no request, no toast, button re-enabled); XLSX posts the
  `ExportRequest` (`report/format/locale/dates`) + server filename prefills the
  save dialog + success toast; 422 `EXPORT_FORMAT_UNSUPPORTED` → localized
  toast, save dialog never opens. Harness: typed `post<Uint8List>` stubs,
  `exportRequestBodies` recorder, in-memory `FilePicker` fake,
  `SharedPreferences.setMockInitialValues`.
- MODIFIED `test/widget/pos_screen_test.dart` (3↔3 ported): preview receives
  the fetched bytes and confirm prints exactly those bytes (80 mm); paper toggle
  refetches for A4 and prints A4 bytes; cancel → no print, no toast, sale
  detail intact. Harness: `post<Uint8List>` stubs + `_fakePreview` seam fake.

---

## 2. Decision → implementation map

| Decision | Implementation |
|---|---|
| Q1 no fiscal fields/logo | layouts carry no fiscal/logo fields anywhere (backend renderers omit them) |
| Q2 `STORE_NAME` only | `settings.STORE_NAME` → `store.name` on the detail path (G19) |
| Q3 80 mm via Windows driver | `Printing.layoutPdf` — user picks printer/copies/paper in the system dialog |
| Q4 preview-first, no auto-print | `showPrintPreviewDialog` → explicit Confirm → print; Cancel neutral |
| Q5 documents in scope | sale + reprint + void + return in; purchase deferred |
| Q6 10 reports, XLSX+PDF+CSV | `POST /exports` xlsx/pdf; CSV stays the frozen client-side builder |
| Q7 dashboard PDF deferred | untouched |
| Q8 CSV frozen / XLSX sanitized | Phase 14 CSV path unchanged; XLSX built server-side without formulas/links |
| Q9–Q10 CSV client-side | `_exportCsv` (Phase 14) unchanged |
| Q11 Z-report deferred | untouched |
| G2 PDF-on-backend | `app/printing/` + reportlab — client never renders layout |
| G3 XLSX server-side | `app/exporting/` + openpyxl |
| G7 Arabic gate | OFL IBM Plex Sans Arabic + `arabic-reshaper`/`python-bidi`, spike in `scripts/g7_spike.py` |
| G8 one model both papers | one `DocumentData` per document; 80 mm/A4 are viewports over it |
| §16.2 neutral/error toasts | cancel paths never toast; failures show exactly one localized toast |

## 3. API surface (frozen for Step B)

| Endpoint | Body | Success | Scope |
|---|---|---|---|
| `POST /api/v1/print` | `PrintRequest {document_type ∈ {sale, return}, document_id, paper: 80mm\|A4, locale, device_id?}` (Strict) — `purchase` is NOT accepted (deferred, Step A) and fails validation with 422 `VALIDATION_ERROR` before any scope check or render | `application/pdf` bytes, `Content-Disposition` filename | body-dependent: `sale`→`pos_sale`, `return`→`pos_return` (no purchase scope — purchase printing does not exist in Phase 15) |
| `POST /api/v1/exports` | `ExportRequest {report, format, locale, date_from, date_to, status?, payment_method?, user_id?, sort?, days?, threshold?, lookback_days?, device_id?}` (Strict — no extras) | bytes + `Content-Disposition` | `export_data` |

Typed failures: `EXPORT_FORMAT_UNSUPPORTED` / `EXPORT_ROW_LIMIT` (422),
`EXPORT_TOO_LARGE` (413), `EXPORT_RENDER_FAILED` / `PRINT_RENDER_FAILED` /
`MISSING_FONT` (500) — plus auth/permission/validation envelopes. Every attempt
writes one audit row (`EXPORT` / `PRINT`, optional `X-Device-ID` → device_id).

---

## 4. Flutter flow (contracts the tests pin)

1. **Print:** sale detail → Print/Reprint → `fetchPrintDocument` → preview
   (bytes rendered by the seam, server filename visible) → Confirm returns the
   SAME bytes → `printPdf` (system dialog); user-cancelled dialog is neutral.
   Fetch failure → typed localized headline + Retry; confirm disabled while
   there is no document.
2. **Export:** export button → format dialog → `csv` runs the frozen Phase 14
   builder; `xlsx`/`pdf` → `exportReportFile` → save dialog prefilled with the
   sanitized server filename → success toast carrying the filename; every
   failure = one localized toast; save-dialog cancel = no toast.

---

## 5. Implementation decisions, defects found, deviations

### 5.1 Defect fixed — stale export button (found by the new tests)

`reports_screen.dart` computed `onPressed: … !_exportReady() …` from a plain
`ref.read`, so the button was built BEFORE tab data arrived and never rebuilt
when it loaded (same for tab switches). Production symptom: the export button
could stay disabled until an unrelated rebuild. Fix: the build now
`ref.watch`s the six data-backed tab providers via `select((s) => s.data != null)`
and the tab controller listener rebuilds on index change. Pre-existing Phase 14
code; no behavior change other than correctness of the enabled state.

### 5.2 Defect fixed — format dialog cancel popped a router page

`showReportExportDialog` popped via the CALLER's context; under go_router that
resolves the page navigator, so Cancel popped the current PAGE (go_router
asserted on the empty match list). Fix: pop via the dialog's builder context.

### 5.3 Deviations / notes

- Dashboard PDF, Z-report, purchase print, fiscal/logo fields: **deferred per
  owner decisions** — not partially implemented (purchase print had leaked into
  the Step B implementation and was removed in the pre-QA scope audit, §5.5).
- `printText`/`Out-Printer` retained as the legacy text path only; the sale UI
  no longer uses it (PDF preview supersedes it).
- CSV export intentionally untouched (Q8/Q10).

### 5.4 Tooling notes (reusable)

- **mocktail matches generic type arguments strictly**: byte endpoints call
  `dio.post<Uint8List>(…)`, so stubs must be registered as
  `when(() => dio.post<Uint8List>(any(), data: …, options: …))` or they never
  match (calls return null → `TypeError` swallowed by generic catches). This
  affected `pos_screen_test`, `reports_screen_test`, `phase15_print_export_test`.
- **Riverpod does not re-apply override VALUE changes** on an existing
  `ProviderScope` element — tests that switch locale mid-test must key the
  scope (`ValueKey(locale.name)`).
- Widget tests that hit `posDeviceIdProvider` need
  `SharedPreferences.setMockInitialValues({})` or the export spinner hangs
  `pumpAndSettle`.
- PowerShell mangles UTF-8 output; files with Arabic are only edited with the
  Read/Edit/Write tools.

### 5.5 Scope audit (pre-QA) — purchase printing removed

The pre-commit audit found `document_type="purchase"` implemented end to end
(schema Literal, `purchase_view` scope map entry, service build branch) — a
violation of the Step A scope (Q5: purchase printing deferred). Corrected so
`POST /api/v1/print` supports **only `sale` and `return`**:

- `app/schemas/export.py` — allowlist is `Literal["sale", "return"]`; a
  `purchase` attempt is a 422 `VALIDATION_ERROR` at validation, before any
  document lookup, scope check, render or audit row.
- `app/api/v1/print.py` — `purchase`/`purchase_view` removed from the scope
  map; `purchase_view` therefore grants no print capability.
- `app/services/print.py` — purchase build branch and its imports removed;
  unreachable defensive guard raises `PRINT_RENDER_FAILED` if the allowlist
  is ever bypassed.
- Voided sales are **not** a separate document type: they print through
  `document_type="sale"` (VOID state on the sale payload).
- `build_purchase_document` stays in `app/printing/document_data.py` (Phase 11
  utility covered by its own builder regression test) — it is simply no longer
  reachable from the print API.
- Proof: `test_print_purchase_rejected_as_unsupported` (422 for admin with
  `purchase_view` AND cashier, zero `print` audit rows),
  `test_print_rejects_bad_enum_values[document_type_purchase_deferred]`,
  `test_print_voided_sale_via_sale_type` (VOID sale prints 200 via `sale`).
  The Flutter client never sends `purchase` (only `documentType: 'sale'`).

---

## 6. Verification (technical) — FINAL

```
backend:  pytest -q                  → 1061 passed, 4 warnings (pre-existing)
          ruff check app             → 64 errors (= Phase 14 baseline; 0 in Phase 15 files)
flutter:  analyze                    → No issues found!
          test                       → 1163 passed (exit 0)
          build windows --debug      → OK (supermarket_pos.exe, exit 0)
git:      HEAD                       → 879c8e5 (phase-14) — no commit, no push
```

Test-count arithmetic: 1163 total = 1139 pre-Step-B + 12 phase15 widget +
9 localization + 3 reports export.

---

## 7. Not touched (forbidden / out of scope for Step B)

- No commits, no pushes, no config changes, no dependency removals.
- Phase 14 contracts (CSV builder, report endpoints, RBAC) unchanged.
- No fiscal/legal fields invented; no logo embedding; no Z-report.
- Dashboard, stock, product, purchase screens untouched beyond the listed files.
- Human QA: executed as a QA decision on 2026-10-02 — software QA PASS,
  physical printer tests DEFERRED pending hardware (§8). No ESC/POS, no
  printer workarounds, no scope changes.

## 8. Human QA decision (2026-10-02)

| QA item | Result |
|---|---|
| Automated QA — backend pytest **1061 passed**, `ruff check app` = 64 baseline, Flutter analyze clean, Flutter tests **1163 passed** | **PASS** |
| Windows build — `flutter build windows --debug` → `supermarket_pos.exe`, exit 0 | **PASS** |
| Software print/preview flow — fetch → preview → confirm → Windows print-dialog seam; save-PDF; export format dialog → XLSX/PDF server save + CSV; error/cancel paths (all simulated and pinned by the test suites) | **PASS** |
| Real 80 mm thermal printer QA (physical hardware) | **DEFERRED / PENDING until printer purchase** |
| A4 physical printer QA (physical hardware) | **DEFERRED / PENDING until printer is available** |

The two physical-printer items are deferred **solely because printer hardware
is not currently available — this is NOT a software failure**. They do not
block software phase closure: all software gates of Phase 15 are green (§0,
§6), the approved scope (§2, §3) is unchanged, and no printer workaround,
ESC/POS path, or scope modification was introduced to compensate. The
physical tests will be executed when the hardware arrives.

## 9. Closeout — Phase 15 Step B

Step B is complete and green on every automated gate (backend tests/lint,
Flutter analyzer/tests, Windows debug build). Human QA software items PASS;
physical printer QA deferred per §8 without blocking closure. Ready for:
commit of the Phase 15 change set → push, in the order the execution rules
prescribe.
