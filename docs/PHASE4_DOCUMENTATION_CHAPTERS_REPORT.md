# Phase 4 — Documentation Center: Chapters 4–14 & Screenshot Infrastructure

**Status:** Content complete; screenshot capture blocked on this machine (§5.3 report below).
**HEAD at start:** `d915b3f` (Phase 3). Nothing staged, committed, or pushed (per instructions — manual review first).

---

## 1. What was delivered

### Chapters 4–14 (11 new chapters, 24 new articles)
All content written in **en / ar / fr** in
`new_app/lib/features/documentation/doc_content.dart`, and registered in
`new_app/lib/features/documentation/doc_registry.dart`.

| Chapter id | Title (en) | Articles |
|---|---|---|
| `products` | Products and Catalog | `cat_basics`, `cat_children`, `cat_pricing` |
| `inventory` | Inventory and Stock | `inv_levels`, `inv_adjust`, `inv_movements` |
| `purchasing` | Purchasing and Suppliers | `purch_suppliers`, `purch_docs` |
| `customers` | Customers, Credit Sales, and Debts | `cust_records`, `cust_debts` |
| `expenses` | Expenses and Financial Operations | `exp_manage` |
| `facturation` | Facturation | `fac_types`, `fac_totals`, `fac_pdf_post` |
| `reports` | Reports and Exports | `rep_overview`, `rep_exports` |
| `printing` | Printing and Receipts | `prt_overview` |
| `lan` | LAN and Multi-PC Setup | `lan_pairing`, `lan_devices` |
| `settings` | Settings, Backup, and Restore | `set_general`, `set_backup` |
| `troubleshooting` | Troubleshooting | `ts_connection`, `ts_print_pdf`, `ts_data` |

Totals: **14 chapters / 38 articles** (was 3/14). `pos_shortcuts` kept as an article
under `pos` (existing organization preserved, per plan).

Every fact was verified against source (`file:line`) before writing: debt ceiling is
server-enforced, history has no date filter, Today KPIs are UTC-today, facturation
totals are server-computed (0.01 ROUND_HALF_UP, TVA {0,9,19}), no DELETE on posted
documents, etc. Phase 3 content was left untouched (already verified accurate).

### Screenshot rendering infrastructure
- `new_app/assets/docshots/` created with `.gitkeep` only (no fabricated images).
- `pubspec.yaml`: added `assets: - assets/docshots/` (no new dependencies).
- `doc_widgets.dart` `DocArticleView`: renders `article.screenshotRefs` as
  `Image.asset('assets/docshots/$ref')` with:
  - `errorBuilder` → `SizedBox.shrink()` (graceful fallback, never a broken-image icon),
  - `Semantics(image: true, label: '<title> — <ref>')` for accessibility,
  - stable `Key('documentation-screenshot-$ref')` for tests.
- `DocArticle.screenshotRefs` remains `const []` — **no screenshots are shipped**
  because safe capture is blocked (see §5).

### Tests
- `doc_registry_test.dart`: pinned the 14 chapter ids and 38 article ids; adjacency
  updated (`pos_returns` → `cat_basics` boundary; `ts_data` is the new last article);
  added a screenshot-safety test (every ref, if ever non-empty, must exist on disk).
- `doc_search_test.dart`: French “appairage” test updated — the new `lan_pairing`
  article now also matches; test asserts both `gs_first_launch` and `lan_pairing` are
  found instead of pinning `.first`.
- All other Phase 3 tests untouched and passing.

---

## 2. Verification results (all green)

| Check | Result |
|---|---|
| `flutter analyze` (whole project) | **No issues found** |
| `flutter test` (full suite) | **1775 tests passed** (baseline was 1774; +1 new screenshot-safety test) |
| `flutter test test/unit/doc_registry_test.dart test/unit/doc_search_test.dart test/unit/localization_parity_test.dart` | 24/24 passed |
| Localization parity baseline | still **1112** (no UI strings added; content lives in `doc_content.dart`, not `strings.dart`) |
| `flutter build windows --release` | **√ Built** `build\windows\x64\runner\Release\supermarket_pos.exe` (62.6s) |
| Every registry content key resolves in en/ar/fr | verified by test (`allDocContentKeys` + `docKeyResolved`) |
| `git diff --check` | clean (only harmless `LF→CRLF` warnings on Windows) |

Manual review of content: no secrets, no LAN addresses, no real store data;
demo naming uses generic examples. No business logic, DB, API, auth, POS,
facturation, reports, printing, LAN, or backup code was touched.

---

## 3. Screenshot capture — BLOCKED (reported per spec §5.3)

The plan required genuine screenshots from an isolated demo dataset. Investigation
concluded this is **not safely possible on this machine**:

1. **Production backend is live.** PostgreSQL 18 is running; the user’s backend
   occupies `localhost:8000` against the production DB (`supermarket_pro`). The
   Flutter app’s server-mode base URL is hard-fixed to port 8000
   (`initialBaseUrl()` in `lib/features/devices/device_identity.dart:160`).
2. **The machine’s app is already paired/configured.** The user actively uses this
   install (generated sale PDFs and CSV exports are present as untracked artifacts).
   Running the GUI for capture would either:
   - re-run the first-run wizard and **overwrite the user’s paired-server identity /
     machine config**, or
   - connect to the live backend and **risk writes against the production DB**.

Per the phase constraints (“never touch production DB”, “preserve the user’s
install”), capture was **stopped** rather than risked. Consequences:

- `DocArticle.screenshotRefs` stays empty for all 38 articles.
- `assets/docshots/` ships with only `.gitkeep`.
- The rendering path (`DocArticleView`) and its safety test are in place, so adding
  real screenshots later is a pure content change (drop files in `assets/docshots/`,
  append refs to the relevant `DocArticle`s).
- A guarded demo-database seeding script was **deferred** (it would be unused while
  capture itself is impossible; shipping dead tooling was judged worse than
  documenting the blocker). The existing `qa_seed_1000_products.py` /
  `create_test_db.py` patterns remain the reference for whoever enables capture on
  an isolated machine later.

**Recommended unblock path (for a future phase / isolated machine):** create a
dedicated demo DB (e.g. `supermarket_pro_demo_docs`) via `create_test_db.py`, seed
fictional data with the existing `qa_seed` pattern, run a second backend instance on
a non-default port with a patched client base URL (or a temporary local override),
capture, then restore. This was not attempted here because it cannot be done without
touching the user’s install or the live backend.

---

## 4. Files changed (working tree, not staged)

Modified (6):
- `new_app/lib/features/documentation/doc_content.dart` — +~1000 lines: ch.4–14 content ×3 locales.
- `new_app/lib/features/documentation/doc_registry.dart` — 11 new `DocChapter` entries.
- `new_app/lib/features/documentation/doc_widgets.dart` — screenshot rendering block in `DocArticleView`.
- `new_app/pubspec.yaml` — `assets: - assets/docshots/`.
- `new_app/test/unit/doc_registry_test.dart` — pinned ids, adjacency, screenshot-safety test.
- `new_app/test/unit/doc_search_test.dart` — French test now expects both appairage hits.

Added (untracked):
- `new_app/assets/docshots/.gitkeep` — empty asset dir placeholder.

Pre-existing untracked artifacts (preserved, untouched):
`docs/FACTURATION_QA_REPORT.md`, `new_app/{bar.pdf,bar2.pdf,fac,fac2,fac2.pdf}`,
`new_app/facture_FAC-*.pdf` (×3), `new_app/reports_{financial,sales}_*.csv`,
`new_app/sale_INV-*.pdf`, `new_app/test/widget/{failures,goldens}/`.

---

## 5. Constraints honored

- No stage / commit / push (awaiting manual review).
- No production DB touched; no backend code changed; no new dependencies.
- No secrets / LAN addresses / real store data in content or scripts.
- Existing organization preserved (`pos_shortcuts` stays an article).
- Localization parity baseline unchanged (1112).
- All pre-existing untracked artifacts preserved.

---

## 6. Suggested next steps (Phase 5, pending review)

1. Manual review of the diff above (6 modified + 1 new file).
2. When approved: stage the 7 intended paths explicitly (never `git add .`),
   commit, push.
3. Phase 5 (PDF/Markdown export) can proceed independently of the screenshot
   blocker; screenshots can be added incrementally once an isolated capture
   environment exists.
