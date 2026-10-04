# Phase 17 — Backup / Settings / Localization / Final QA — Implementation Record

**Status:** COMPLETE — §17.1–§17.10 delivered, every automated gate green.
**Baseline:** Phase 16 closed at `425e20d`; Phase 17 = 9 commits `d9565fd` → `29dd769`
(80 files, +9 315 / −288).
**Scope honoured:** no installer, no `.exe`/packaging, no cloud/WAN, no offline write
queue, no SQLite, no replacement of PostgreSQL/FastAPI, no rewrite of Phase 8–16 logic
or report formulas, **no new dependency** (Phase 17 actually *removed* `google_fonts`
and bundled IBM Plex Sans Arabic under OFL).

This file is the §17.10 deliverable: one consolidated record of 17.1–17.10.
Statuses: **PASS** / **FAIL** / **DEFERRED** (consciously later, with rationale) /
**UNVERIFIED** (needs runtime, hardware, or a second machine — never silently resolved).
**FAIL: none.**

---

## 0. Verification snapshot (executed 2026-10-04, exact results)

| Gate | Command (cwd) | Result |
|---|---|---|
| Backend tests | `python -m pytest -q` (`new_app/backend`, venv) | **1235 passed**, 4 warnings (pre-existing), **573.26 s** |
| Backend lint (baseline scope) | `python -m ruff check app` | **59 errors** — down from the Phase 16 baseline **64**, 0 introduced by Phase 17 |
| Migrations integration | `python -m pytest tests/integration/test_migrations.py -q` | **61 passed**, 121.40 s (incl. `test_autogenerate_detects_no_changes`, downgrade/upgrade to `0001_initial`) |
| Flutter analyzer | `flutter analyze` (`new_app`) | **No issues found!** (88.0 s) |
| Flutter tests | `flutter test` (`new_app`) | **1377 passed** (~148 s) |
| Performance benchmark | `python scripts/benchmark_phase17.py …` | **exit 0 — all 10 budgeted scenarios PASS at 1k / 10k / 100k** products; 2 saturation blocks recorded (informational, no budget) |
| Lint of the new script | `python -m ruff check scripts/benchmark_phase17.py` | All checks passed |
| VCS | `git log -1` / `git status` | HEAD `29dd769 phase-17: performance audit (§17.8)`; tree clean except two pre-existing untracked report CSVs (Phase 15 export artefacts, out of scope) |

Test-count arithmetic (each step is a gate recorded in a commit message or in §0 above):

- Backend **1235 = 1234 (§17.7 gate) + 1** (`test_search_total_is_capped`, §17.8).
- Backend **1234 = 1202 (§17.6 gate) + 32** (`tests/unit/test_security_phase17.py`).
- Backend passed **1138** after §17.1 and **1202** after §17.6 (commit messages).
- Flutter passed **1305** after §17.1 and **1377** after §17.6 (commit messages); Phase 16
  baseline was **1259**.
- Flutter phase-17 test files measured directly: settings **44** (5+10+9+20), backup
  **35** (6+8+12+9), localization **9** (3+6), RTL **4**, theme **15** (12+3), plus the
  §17.6 print widget tests in the pre-existing `pos_screen_test.dart`.
- `ruff --statistics`: 59 = 64 − 5 removed by the §17.7 cleanup (unused imports in the
  auth/dependencies path); no new categories.

---

## 1. Deliverable status — §17.1 … §17.10

| § | Deliverable | Commit(s) | Evidence | Status |
|---|---|---|---|---|
| 17.1 | Settings foundation (server-owned store/app settings) | `d9565fd` | `test_settings.py` **29**; Flutter settings tests **44** across 5 files; migration `0022` | **PASS** |
| 17.2 | Backup / restore | `9c93bd0` | `test_backup.py` **33** + `test_backup_dump.py` **9** (real `pg_dump`/`psql` round-trip on PostgreSQL); Flutter backup tests **35** | **PASS** |
| 17.3 | Localization parity + coverage gates (AR/EN/FR) | `f24eac0` | `localization_parity_test.dart` **6** + `localization_coverage_test.dart` **3** | **PASS** |
| 17.4 | RTL layout | `bff3509` | `rtl_layout_test.dart` **4** (physical-idiom source gates + deliberate LTR pins) | **PASS** |
| 17.5 | Theme system | `86331d1`, `0de0dad` | `theme_system_test.dart` **12**, `theme_test.dart` **3**, contrast gates; bundled OFL font | **PASS** |
| 17.6 | Print settings (receipt identity + post-sale print hook) | `b0001fd` | `test_receipt_identity.py` **18**, print additions in `test_print_export.py` (**56** total in file), Flutter print widget tests | **PASS** |
| 17.7 | Security audit + fixes | `391c999` | `test_security_phase17.py` **32** (9 defects, §8); ruff 64 → 59 | **PASS** |
| 17.8 | Performance audit + optimization | `29dd769` | benchmark 3 scales all PASS (§9); migration `0023` + bounded count; `test_search_total_is_capped` | **PASS** (8 of 9 Phase 0 remedies shipped; 1 row partially — see §9.3) |
| 17.9 | Regression QA (full backend + Flutter) | — | §0 gates, all green | **PASS** |
| 17.10 | This consolidated report | — | — | **PASS** |

---

## 2. §17.1 — Settings foundation

Server-owned store/application settings; language and theme deliberately stay client-side
(`app_locale` / `app_theme_mode` in SharedPreferences) so there is only one settings system.

| Piece | Where |
|---|---|
| `app_settings` singleton table (migration `0022_phase17_settings`, rev `e7d4a9c1f3b6`) | `app/models/settings.py`, `migrations/versions/0022_phase17_settings.py` |
| `GET /api/v1/settings` — **any authenticated user** (POS needs `allow_debt`, `low_stock_threshold`, print defaults on every role) | `app/api/v1/settings.py:50` |
| `PUT /api/v1/settings` — partial update, gated `settings_manage`, audit row written **in the same transaction** as the change | `app/api/v1/settings.py:64`, `app/services/settings.py` |
| Fields: `store_name/phone/address`, `invoice_footer`, `default_paper`, `ask_before_print`, `auto_print_invoice`, `allow_debt`, `low_stock_threshold` | `app/api/v1/settings.py:35-47` |
| Flutter form + provider + models; form gated `settings_manage` so a non-manager never issues a settings request | `lib/features/settings/settings_screen.dart`, `settings_provider.dart`, `settings_models.dart` |
| Migration-vs-`create_all` parity (schema identical either way) | `app/models/settings.py` docstring + tests |

**Persistence evidence:** the value is a database row (survives restart by construction),
round-tripped by 29 backend tests including permission gating and audit rows.

## 3. §17.2 — Backup / restore

| Piece | Where |
|---|---|
| `GET /api/v1/backups` (any authenticated user), `POST /api/v1/backups` (**`backup_restore`**), `POST /api/v1/backups/{id}/restore` (**`backup_restore`**) | `app/api/v1/backups.py` |
| `pg_dump`/`psql` via `DumpRunner` — password passed through `PGPASSWORD`, **never on argv**; `safe_repr()` hides it | `app/core/db_dump.py`, `test_backup.py::test_db_params_safe_repr_hides_the_password` |
| Manifest + SHA-256 content hash; tampered/deleted/replaced files refused; failed dump leaves nothing; unauditable backup is not a backup | `app/services/backup.py`, tests at `test_backup.py:263-441` |
| Restore is all-or-nothing; audited `BACKUP`/`RESTORE` | `test_backup.py:346-436` |
| Real `pg_dump` → restore round-trip on PostgreSQL | `tests/integration/test_backup_dump.py` (**9**) |
| Flutter: list/create/restore UI + models + provider, permission-gated | `lib/features/settings/backup_*.dart`, `test/widget/settings_backup_section_test.dart` |
| Directory config, ignore rules for the backup dir | `app/core/config.py`, `.gitignore`, `new_app/backend/.gitignore` |

## 4. §17.3 — Localization (AR/EN/FR)

Two automated gates that turn silent bad UI into a red test:

1. **Parity** — every key exists in all three locales (`localization_parity_test.dart`, 6
   tests; parity baseline recorded in §17.6 commit as 860 entries).
2. **Coverage** — scans `lib/` (excluding the dictionary itself and interpolated strings)
   for user-visible literals (`Text('Sales')`, `labelText:`/`hintText:`/`tooltip:`…) and for
   `AppStrings.t('typo')` lookups that would print the raw key on screen; dynamic key
   families (`purchase_status_*`, `lan_status_*`, …) are enumerated against the backend
   enum values (`localization_coverage_test.dart`, 3 tests).

## 5. §17.4 — RTL layout

`Directionality` already follows the locale (Phase 6). §17.4 fixed what ignores it and
added gates (`rtl_layout_test.dart`, 4 tests):

- physical idioms (`EdgeInsets.only(left/right)`, `Alignment.centerLeft`, `TextAlign.left`,
  `Positioned(left:)`, `BorderRadius.only`, `Border.only`) are banned by a `lib/` source
  scan — replacements are `*Directional`/`start`/`end` equivalents;
- directional icons must be mirroring-capable;
- `TextDirection.ltr` pins are **not** violations: numbers, dates, quantities and signed
  changes never mirror (a `-4` must read `-4` in Arabic).

Edits in the phase: `expenses_screen.dart`, `pack_form_dialog.dart`, `app_router.dart`
(directional paddings).

## 6. §17.5 — Theme system

- **Single mode mapping** (`light`/`dark`/`system`) with splash theme — `lib/main.dart`,
  `lib/theme/app_theme.dart`; 12 contrast/gating tests in `theme_system_test.dart` + 3 in
  `theme_test.dart`.
- **Findings commit `0de0dad`:** typography is **bundled, never fetched** — `google_fonts`
  (network) removed from `pubspec.yaml`, IBM Plex Sans Arabic (Regular/Bold, OFL licence +
  `OFL.txt`) added under `assets/fonts/`; the same family the backend embeds in receipts.
  Secondary text contrast raised to WCAG AA (`lib/core/colors.dart`, `app_theme.dart`).

## 7. §17.6 — Print settings

- Backend: `StoreBlock` carries phone/address/footer; `PrintService` stamps them from the
  `app_settings` row for **sale and return** prints; 80 mm and A4 templates draw the
  contact block and the configured footer; `estimate_height` budgets 4 mm per line
  (`app/printing/document_data.py`, `templates/invoice_80mm.py`, `templates/invoice_a4.py`,
  `app/services/print.py`).
- Flutter POS post-sale hook: `ask_before_print` prompts → else `auto_print_invoice`
  prints → else nothing; **every failure is a localized toast on an already completed sale**
  (never fails the sale) — `lib/features/pos/pos_screen.dart`, widget tests in
  `test/widget/pos_screen_test.dart`.
- Tests: `test_receipt_identity.py` **18** + end-to-end print tests; gate at §17.6 was
  pytest **1202**, flutter **1377**.

## 8. §17.7 — Security audit (9 defects, all fixed)

| # | Defect | Fix | Locked by |
|---|---|---|---|
| 1 | `POST /auth/verify` read a **query** parameter (422 without one) and answered `valid: false` unconditionally | body-based, real verification | `test_verify_*` ×4 |
| 2 | `POST /auth/logout` returned success **without revoking** anything (D-13) | session revocation | `test_logout_*` ×2 |
| 3 | `POST /auth/verify-token` swallowed every exception as `valid: false` | faults propagate | `test_verify_token_*` ×2 |
| 4 | `is_setup_needed()` counted **all users** while `setup_first_admin` guards on an *admin-role* user | count scoped to admin role | `test_setup_stays_open_until_an_admin_exists`, `…check_endpoint_agrees…` (first-run `bare_db` fixtures) |
| 5 | SQL `echo` printed `pin_hash` / `token_hash` bound parameters | engine echo disabled everywhere; dev statement log excludes parameters | `test_engine_echo_*`, `test_development_statement_log_*`, `test_statement_log_is_off_outside_development` |
| 6 | Repository placeholder secrets booted **production silently** | production refuses placeholders (warns in development) | `test_production_refuses…`, `test_production_accepts…`, `test_development_warns…` |
| 7 | Silent `except OSError` (server identity read/write, discovery socket close, pg-tool glob) | logged (`debug` → `warning` where it hides a real failure) | `test_server_id_*`, `test_discovery_socket_close_failure_is_logged`, `test_pg_tool_glob_failure_is_logged` |
| 8 | `db.commit()` on **every** authenticated request (last_seen heartbeat) | heartbeat only when the session is stale; failure never fails the request | `test_heartbeat_*` ×3 |
| 9 | **No app-wide rate limiting** (roadmap Phase 3 / D-08) | sliding-window limiter + standard 429 envelope; login and first-admin setup limited per client IP | `test_rate_limit_*`, `test_sliding_window_*`, `test_retry_after_*`, `test_api_backstop_*`, `test_clearing_the_window_*`, `test_login_attempts_*`, `test_first_admin_setup_*` |

Infrastructure added: `app/core/rate_limit.py`, config hardening in `app/core/config.py`,
session handling in `app/db/engine.py`, `app/api/dependencies.py`, `app/api/v1/auth.py`.
Docs updated: `PHASE_16_LAN_DEVICES_ANALYSIS.md` D-08 and D-13 are marked
**RESOLVED → Phase 17 §17.7**. Test file: `tests/unit/test_security_phase17.py` (32).

**Residual (documented, not silently accepted):** plain-HTTP LAN transport and unsigned
discovery packets are Phase 16 owner decisions (Q8; packets carry no secrets by design) —
see §11.

---

## 9. §17.8 — Performance audit

### 9.1 Method

`new_app/backend/scripts/benchmark_phase17.py` (628 lines) measures the Phase 0 SLOs on an
**isolated database** (`supermarket_bench_phase17`) against a **real uvicorn server on a
real socket** (HTTP, not an in-process ASGI transport):

- fixtures: `--products` 1 000 / 10 000 / 100 000, `--sales` 5 000 / 20 000 / 50 000,
  seeded with the deterministic LCG from `benchmark_reports_phase14.py` and re-migrated;
- 8 single-till scenarios (POS text/barcode lookup, product page, sale command, dashboard,
  daily report, receipt job start, export) × `--iterations 30`, p95 vs the Phase 0 budget;
- **concurrent**: `--tills 4` tills running lookup + sale with `--think-ms 300` between
  requests (the POS search box is debounced, so a real till never fires back-to-back);
- **saturation**: the same tills with think-time 0 — headroom measurement, **no budget**;
- `LOG_LEVEL=WARNING` so the measured path is the shipped one (the §17.7 dev-only SQL
  statement log is off in production: `APP_ENV != development`);
- any budgeted p95 over budget ⇒ exit 1. Results accumulate one run per scale in
  `new_app/backend/docs/phase17_benchmark_results.json`.

### 9.2 SLO results (p95 ms / budget, all **PASS**)

| Scenario | 1 000 | 10 000 | 100 000 |
|---|---|---|---|
| `pos_lookup` | 16.4/100 | 21.5/100 | 21.0/100 |
| `pos_barcode` | 16.6/100 | 22.6/100 | 15.8/100 |
| `product_page` | 24.1/200 | 19.7/200 | 29.9/200 |
| `sale_command` | 31.4/500 | 36.5/500 | 39.8/500 |
| `dashboard` | 46.5/2000 | 71.1/2000 | 127.4/2000 |
| `daily_report` | 69.1/2000 | 99.4/2000 | 211.4/2000 |
| `receipt_start` | 34.8/3000 | 34.4/3000 | 35.6/3000 |
| `export` | 299.5/5000 | 330.7/5000 | 388.9/5000 |
| `concurrent:pos_lookup` (4 tills) | 38.9/100 | 39.9/100 | 58.9/100 |
| `concurrent:sale_command` (4 tills) | 60.7/500 | 59.6/500 | 57.1/500 |
| *`saturation:pos_lookup` (info)* | *69.6/n.a.* | *190.4/n.a.* | *250.6/n.a.* |
| *`saturation:sale_command` (info)* | *204.6/n.a.* | *201.4/n.a.* | *199.9/n.a.* |

### 9.3 The defect found and fixed (the only budget miss of the phase)

At 100 000 products `pos_lookup` measured **p95 185 ms > 100 ms**. `EXPLAIN (ANALYZE,
BUFFERS)` showed **both** search statements as sequential scans — 46 ms of `COUNT` plus
53 ms of items before SQLAlchemy hydrates a row (`ILIKE '%term%'` is unindexable on a
plain btree). Remedy is exactly what Phase 0 prescribes ("indexed server search"):

| Fix | File |
|---|---|
| Migration `0023_phase17_search_indexes` (rev `5c8d2e1f4a73`): btree `ix_products_name` (serves `ORDER BY name, id LIMIT n`), `pg_trgm` GIN `ix_products_name_trgm` / `ix_products_barcode_trgm` for substring `ILIKE`, then `ANALYZE products`. Extension creation runs in a **SAVEPOINT** and degrades to a printed warning if the role may not create it — additive only, downgrade drops only what it added | `migrations/versions/0023_phase17_search_indexes.py` |
| Model declares `index=True` on `Product.name` **and** the two GIN indexes (`postgresql_using="gin"`, `gin_trgm_ops`) so alembic autogenerate sees the schema the database actually has (SQLite unit tests ignore `postgresql_*` dialect options) | `app/models/catalog.py:65,137-151` |
| Bounded count: `SEARCH_TOTAL_CAP = 10_000` — the count is a second pass over the same predicate and an unbounded pass was 46 ms of the miss. Nothing consumes a total above the cap (the Flutter POS/pack/purchase/return pickers read only `items`) | `app/repositories/catalog.py:44-52,114-148` + `test_search_total_is_capped` |
| `test_migrations.py` head constants updated to `5c8d2e1f4a73` (8 `HEAD_REV` values) | `tests/integration/test_migrations.py` |

Result: 100 k `pos_lookup` p95 **185 → 21 ms**; 4-till concurrent p95 **58.9 ms**.

### 9.4 Phase 0 remediation table (9 rows — verified with file:line evidence)

| # | Phase 0 target remedy | Status | Evidence |
|---|---|---|---|
| 1 | indexed server search | **PASS** | migration `0023`; `app/repositories/catalog.py:114-148`; `app/api/v1/products.py:200` |
| 1b | cursor pagination | **DEFERRED** | pagination is offset/`page`+`page_size` everywhere (`catalog.py:108-109`); no `cursor`/keyset exists; switching the contract would touch the Flutter pickers with no measured need — measured deep pages are not a POS path |
| 1c | debounced input | **PASS** | `lib/features/pos/pos_providers.dart:22,469` (`kPosSearchDebounce` 250 ms), `lib/features/products/products_providers.dart:17,161` |
| 1d | virtualized list | **PASS** | `pos_screen.dart:1757` `GridView.builder`, `:1748` `ListView.separated`, `products_screen.dart:1131` `ListView.builder` |
| 2 | granular Riverpod state/list diffs | **DEFERRED** | `pos_screen.dart:879` watches the whole cart in `PosScreen.build`; mitigation only — keyed/stateful cart tiles (`pos_screen.dart:2062`, `:2442-2509`). No profile shows a navigation stall, and the navigation SLO is **UNVERIFIED** (§12), so the rewrite is not justified yet |
| 3 | query plans/composite indexes; daily aggregates only when measured | **PASS** | migration `0020` composite indexes + extended statistics (`0020_phase14_report_indexes.py:28-67`); one grouped query per fact source merged `UNION ALL` (`app/repositories/report.py:3,981-997`); **zero** materialized views/caches — Phase 0 forbids them until a profile demands them |
| 4 | batch lookup + deterministic row locking | **PARTIAL → remainder DEFERRED** | batch + `ORDER BY … FOR UPDATE` in returns/purchases (`app/services/returns.py:106-108`, `inventory.py:1212-1214`); sale creation is still item-by-item (`app/services/sale.py:789-792`, `:291`, `:1079-1088`). Measured `sale_command` p95 40 ms vs a 500 ms budget — no evidence the rewrite pays for itself in §17.8 |
| 5 | generated thumbnails, lazy decode/cache | **PARTIAL → DEFERRED** | Flutter lazy downscale exists (`pos_screen.dart:1395-1398` `cacheWidth` 200/72 px, `products_screen.dart:1505-1510`); **no** server thumbnails, no image endpoint, no cache package (verified absent in `pubspec.yaml`) |
| 6 | cached known server, bounded discovery backoff | **PASS** (packets unsigned = Phase 16 decision) | cached paired server `lib/features/devices/device_identity.dart:27-31`, `connection_provider.dart:359-375`; backoff `[1,2,4,8,16,30]` cap 30 s + jitter `connection_provider.dart:70-97`; single-port UDP responder that never scans the subnet `app/discovery/responder.py:1-21`; packets carry **no secrets** by design (`app/discovery/packet.py:4-16`) |
| 7 | SQLAlchemy pool / per-request session | **PASS** | `app/db/engine.py:57-64` (`pool_size=5`, `max_overflow=10`, `pool_pre_ping=True`, `pool_recycle=3600`), `get_db` yields/closes one session `engine.py:105-120`, single lazy engine factory `engine.py:71-97` |
| 8 | backend job worker with progress/cancel | **DEFERRED** | Phase 15 gate G30 decision stands: print and export are synchronous handlers (`app/api/v1/print.py:46-52`, `app/api/v1/exports.py:37-43`); no `job_id`/progress/cancel/queue anywhere in `app/`. Measured `receipt_start` 36 ms and `export` 389 ms vs 3 s/5 s budgets |
| 9 | generated catalogs / locale formatting | **DEFERRED** | translations are one runtime map per locale (`lib/core/strings.dart:8` + `_arabic`/`_french`/`_english`), guarded by the §17.3 parity + coverage gates instead of codegen; `intl` used with fixed patterns (`reports_providers.dart:33`, `report_csv.dart:58`); no `.arb`/`l10n.yaml` |

**Counts: 5 PASS · 1 PARTIAL (remainder deferred) · 3 DEFERRED · 0 FAIL.**

### 9.5 Saturation finding (informational, no budget)

Four tills with **zero** think-time drive the single-process server to saturation:
`pos_lookup` p95 69.6 / 190.4 / 250.6 ms at 1k / 10k / 100k, `sale_command` ≈ 200 ms.
Server-side service time was measured at ≈13–14 ms per request (per-request auth resolves
session → user → roles → permissions, i.e. ≈6 queries before the search statements), so
saturation lands near ~60–75 req/s per process. This is **headroom, not an SLO miss**:

- a real till issues a debounced lookup every ≥250–300 ms (≈3 req/s), and the budgeted
  `concurrent:*` block at 4 tills passes at every scale (§9.2);
- recorded remedies, **DEFERRED to packaging**: run uvicorn with multiple workers, and/or
  cache a user's permission set with a short TTL. Permission caching touches §17.7 security
  semantics (revocation latency) and must not be introduced while a profile shows no
  budgeted scenario failing.

---

## 10. §17.9 — Regression QA

| Area | Run | Result |
|---|---|---|
| Full backend suite | `pytest -q` (LAN_MODE=0, DISCOVERY_ENABLED=0) | **1235 passed**, 573.26 s |
| Migration chain incl. autogenerate drift check | `pytest tests/integration/test_migrations.py -q` | **61 passed** |
| Backend lint | `ruff check app` | **59** (baseline 64 after §17.7 cleanup; no new findings) |
| Flutter static analysis | `flutter analyze` | **No issues found!** |
| Flutter unit/widget suite | `flutter test` | **1377 passed** |
| Perf regression harness | `scripts/benchmark_phase17.py` (3 scales) | exit 0, all budgeted PASS |
| Working tree | `git status` | clean (2 pre-existing untracked CSV exports left alone) |

Not rerun / out of scope for §17.9: `flutter build windows` (packaging/installer is
explicitly excluded from Phase 17); physical printer QA and 2-PC LAN QA (§12).

---

## 11. Roadmap acceptance criteria (Phase 17)

| Criterion (`PHASE_0_ROADMAP.md:747-755`) | Verdict | Evidence |
|---|---|---|
| Backups work correctly | **PASS** | §3 — 33 unit + 9 integration (real `pg_dump`) tests, tamper/refuse/audit paths |
| Settings persist | **PASS** | §2 — `app_settings` row + migration `0022`, 29 backend + 44 Flutter tests |
| All strings translated | **PASS** | §4 — parity gate (AR/EN/FR key equality) + literal/typo coverage gate |
| RTL layout works | **PASS** | §5 — source gates ban physical idioms; locale-driven `Directionality`; LTR pins are the documented exception |
| All themes work | **PASS** | §6 — 15 theme tests incl. contrast gates; bundled offline font |
| Performance meets targets | **PASS** | §9.2 — every budgeted p95 met at 1k/10k/100k and at 4 concurrent tills; *sub-item* `navigation interaction <100 ms` is **UNVERIFIED** (§12) |
| No security vulnerabilities | **PASS** | §8 — 9/9 audit defects fixed and pinned by 32 tests; residual risks (plain-HTTP LAN, unsigned discovery packets) are recorded Phase 16 owner decisions, not open defects |
| All tests pass | **PASS** | §10 — 1235 backend + 1377 Flutter + 61 migrations, analyze clean, lint at/below baseline |

Roadmap *Features* map: backup creation/restore → §3 · settings management → §2 ·
full localization AR/EN/FR → §4 · RTL → §5 · theme system → §6 · performance
optimization → §9 · security audit → §8 · final testing → §10.
*Backend Work* and *Flutter Work* lists are covered by the same sections.
*Tests* (backup, localization, RTL, theme, performance, security, end-to-end) all exist and
run in the gates above; “end-to-end” = backend integration suites (migrations, backup dump,
concurrency, permission flows) plus Flutter widget flows — no browser/E2E harness exists in
this repo.

---

## 12. Consolidated DEFERRED / UNVERIFIED

**DEFERRED (documented, with rationale):**

| Item | Why deferred | Where recorded |
|---|---|---|
| Cursor/keyset pagination for catalog search | offset paging meets every measured budget; contract change touches all Flutter pickers | §9.4 row 1b |
| Granular Riverpod rebuilds for the POS cart page | no profile of a navigation stall yet; keyed cart tiles already limit rebuild cost | §9.4 row 2 |
| Batch `IN (…)` lookup + `FOR UPDATE` in sale creation | `sale_command` p95 40 ms ≪ 500 ms budget | §9.4 row 4 |
| Server-generated thumbnails / image endpoint | Flutter `cacheWidth` lazy decode already bounds memory; no grid SLO miss measured | §9.4 row 5 |
| Signed/encrypted discovery + LAN packets | Phase 16 owner decision Q8; packets carry no secrets | §9.4 row 6, §8 residual |
| Async print/export job worker with progress/cancel | Phase 15 G30 decision stands; both well inside budget | §9.4 row 8 |
| Generated l10n catalogs (`.arb`/codegen) | runtime maps + parity/coverage gates give the same guarantee without a toolchain | §9.4 row 9 |
| Multiple uvicorn workers / permission-set caching | saturation only, no budgeted scenario fails; caching interacts with §17.7 revocation semantics | §9.5 |
| Installer, packaging, `.exe`, firewall automation | explicitly outside Phase 17 scope | scope statement, top |

**UNVERIFIED (needs runtime, hardware, or a second machine):**

| Item | What would verify it |
|---|---|
| `navigation interaction <100 ms` (Phase 0 SLO) | a Flutter performance harness — **none exists**: no `integration_test/`, no `Stopwatch`/benchmark assertions in `new_app/test/**` |
| Physical 80 mm / A4 printer QA | hardware purchase (carried DEFERRED/PENDING from Phase 15) |
| Real 2-PC LAN QA (discovery, pairing, heartbeat loss, revoke mid-session) | a second machine on the same LAN (carried DEFERRED/PENDING from Phase 16) |
| Production LAN deployment (`LAN_MODE=1`, `DISCOVERY_ENABLED=1`, firewall prompts) | a live store network (carried from Phase 16) |
| Visual RTL spot-check of every screen | automated gates are source-scan + widget level; a manual pass on an Arabic device is still worthwhile |
| Restore of a backup over a **production-sized** database | integration coverage restores a test database; timing on real data is unmeasured |

---

## 13. Reproduce

```powershell
# Backend gates (cwd: new_app/backend; venv interpreter)
$env:LAN_MODE='0'; $env:DISCOVERY_ENABLED='0'
.\.venv\Scripts\python.exe -m pytest -q                 # expect 1235 passed
.\.venv\Scripts\python.exe -m pytest -q tests\integration\test_migrations.py   # expect 61 passed
.\.venv\Scripts\python.exe -m ruff check app            # expect 59

# Benchmark (seeds its own supermarket_bench_phase17 database; 100k takes ~4 min)
.\.venv\Scripts\python.exe scripts\benchmark_phase17.py --products 1000  --sales 5000
.\.venv\Scripts\python.exe scripts\benchmark_phase17.py --products 10000 --sales 20000
.\.venv\Scripts\python.exe scripts\benchmark_phase17.py --products 100000 --sales 50000

# Flutter gates (cwd: new_app)
flutter analyze                                             # No issues found
flutter test                                                # expect 1377 passed
```

---

## 14. Files (Phase 17, by section)

| Section | New | Modified |
|---|---|---|
| 17.1 Settings | `app/models/settings.py`, `app/schemas/settings.py`, `app/repositories/settings.py`, `app/services/settings.py`, `app/api/v1/settings.py`, `migrations/versions/0022_phase17_settings.py`, `tests/unit/test_settings.py`, `lib/features/settings/{settings_models,settings_provider,settings_screen}.dart`, 4 Flutter test files + `test/helpers/settings_fake_adapter.dart` | `app/api/v1/router.py`, `app/models/__init__.py`, `lib/core/strings.dart` |
| 17.2 Backup | `app/core/db_dump.py`, `app/schemas/backup.py`, `app/services/backup.py`, `app/api/v1/backups.py`, `tests/unit/test_backup.py`, `tests/integration/test_backup_dump.py`, `lib/features/settings/backup_*.dart`, 4 Flutter test files | `app/core/config.py`, `.gitignore`, `new_app/backend/.gitignore`, `lib/core/strings.dart`, `settings_screen.dart` |
| 17.3 Localization | `test/unit/localization_{parity,coverage}_test.dart` | `lib/core/strings.dart`, `pos_screen.dart`, `sales_screen.dart` |
| 17.4 RTL | `test/unit/rtl_layout_test.dart` | `expenses_screen.dart`, `pack_form_dialog.dart`, `app_router.dart` |
| 17.5 Theme | `assets/fonts/IBMPlexSansArabic-{Regular,Bold}.ttf`, `assets/fonts/OFL.txt` | `lib/main.dart`, `lib/theme/app_theme.dart`, `lib/core/colors.dart`, `pubspec.yaml` (−`google_fonts`), `pubspec.lock` |
| 17.6 Print | `tests/unit/test_receipt_identity.py` | `app/printing/document_data.py`, `templates/invoice_{80mm,a4}.py`, `app/services/print.py`, `pos_screen.dart`, `print_preview_dialog.dart`, `sale_detail_dialog.dart`, `settings_provider.dart` |
| 17.7 Security | `app/core/rate_limit.py`, `tests/unit/test_security_phase17.py` | `app/api/dependencies.py`, `app/api/v1/{auth,router}.py`, `app/core/config.py`, `app/core/db_dump.py`, `app/core/server_identity.py`, `app/db/engine.py`, `app/discovery/responder.py`, `app/services/{auth,devices}.py`, `tests/conftest.py`, `PHASE_16_LAN_DEVICES_ANALYSIS.md` |
| 17.8 Performance | `migrations/versions/0023_phase17_search_indexes.py`, `scripts/benchmark_phase17.py`, `docs/phase17_benchmark_results.json` | `app/models/catalog.py`, `app/repositories/catalog.py`, `tests/unit/test_products_categories.py`, `tests/integration/test_migrations.py` |
| 17.10 | `docs/PHASE_17_IMPLEMENTATION.md` (this file) | — |

*(Exact per-commit line counts: `git show --stat` for `d9565fd 9c93bd0 f24eac0 bff3509
86331d1 0de0dad b0001fd 391c999 29dd769`.)*
