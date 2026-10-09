# PHASE 9 — Stage C: Flutter Permission-Gated Navigation

**Date:** 2026-10-09
**Status:** Complete — ready for review
**Stage B backend:** complete (see Stage B report reference below)

---

## 1. Objective

Gate the Facturation (`/facturation`) and Invoice Clients (`/invoice-clients`)
navigation destinations in the Flutter app behind the `facturation_view`
permission scope, matching the backend RBAC enforced in Stage B.

---

## 2. Scope & Policy

| Scope | Admin | Manager | Cashier | No roles/scopes |
|---|---|---|---|---|
| `facturation_view` | ✅ (all scopes) | ✅ (granted via role) | ❌ | ❌ |
| Facturation nav entry | Visible | Visible | Hidden | Hidden |
| Invoice Clients nav entry | Visible | Visible | Hidden | Hidden |

All other module authorization is **unchanged** — only the two facturation
destinations are gated.

---

## 3. Security Boundary

- **Backend RBAC (Stage B) is the security boundary.** Hiding a nav entry is
  UI-only; direct navigation or API calls are still blocked by
  `require_permission(...)` on every facturation endpoint.
- **No route-level redirect guard was added** — per approved rules, nav
  visibility is cosmetic; the backend 403 is authoritative.

---

## 4. Files Changed (Flutter only — 5 modified, 1 new)

| File | Change |
|---|---|
| `new_app/lib/features/shell/nav_items.dart` | Added `NavScopes.facturationView = 'facturation_view'`; wrapped `/facturation` and `/invoice-clients` NavItems in `if (can(NavScopes.facturationView))`; both now carry `scope: NavScopes.facturationView`. |
| `new_app/lib/router/app_router.dart` | Added `facturationViewScope` re-export constant (doc comment: backend RBAC remains the security boundary). |
| `new_app/test/widget/facturation_screen_test.dart` | Mock admin login body now includes `facturation_view` permission. |
| `new_app/test/widget/invoice_clients_screen_test.dart` | Same login-body update; "rail entry is always visible" renamed → "rail entries visible when facturation_view is granted". |
| `new_app/test/widget/nav_rail_overflow_test.dart` | `_allScopes` now includes `facturation_view`. |
| **`new_app/test/widget/facturation_nav_visibility_test.dart`** | **NEW** — role-visibility matrix (4 tests). |

**Diff stat:** 5 files, 41 insertions, 19 deletions (+ new visibility test file).

---

## 5. Implementation Details

- `buildNavGroups({required bool Function(String scope) can})` already
  supported filtering; facturation entries were previously un-gated
  (`scope: null`, always visible to any logged-in user).
- `ScaffoldWithNav` wires `can: (scope) => ref.watch(hasPermissionProvider(scope))`
  — reuses existing `hasPermissionProvider` from
  `lib/features/auth/permission_helpers.dart` with **no new state code**.
- Scopes are parsed from the login response `roles[].permissions[]`
  (`lib/features/auth/auth_models.dart`) — **no backend payload change needed**;
  `facturation_view` flows through the existing permission list.

---

## 6. Tests Added / Modified

### NEW: `facturation_nav_visibility_test.dart` (4 tests)

| Test | Result |
|---|---|
| Admin sees both Facturation and Invoice Clients | ✅ |
| Manager sees both Facturation and Invoice Clients | ✅ |
| Cashier sees neither; POS & Clients still visible | ✅ |
| Guest (no roles) sees neither | ✅ |

### Modified existing tests (no logic change, mock-data update only)
- `facturation_screen_test.dart`, `invoice_clients_screen_test.dart`,
  `nav_rail_overflow_test.dart` — updated mock login scopes.

---

## 7. Test & Analysis Results

| Suite | Result |
|---|---|
| `flutter analyze` | **No issues found** |
| Focused facturation/visibility tests | **18 / 18 passed** |
| `flutter test test/widget` (all widget tests) | **813 / 813 passed** |
| **Full `flutter test`** | **1601 / 1601 passed** |

No pre-existing failures detected.

---

## 8. Backend (Stage B) — Not Touched in Stage C

The 9 backend files changed in Stage B remain unchanged in this stage:
`enums.py`, `seed.py`, `factures.py`, `invoice_clients.py`, plus 5 test files.
Stage B results (from Stage B report): focused 242 passed, unrelated-module
regression 450 passed, full unit 3598 passed, integration 106 passed,
`ruff check` = 220 (baseline), `mypy --strict` = 454 (baseline).

---

## 9. Git Status

- `git diff --check` → clean (LF→CRLF warnings only, no whitespace errors).
- `git status --short` → only the 14 intended files modified + 1 new test file.
  Pre-existing untracked artifacts (`bar.pdf`, `bar2.pdf`, `reports_*.csv`,
  `sale_*.pdf`, `test/widget/failures/`, `test/widget/goldens/`) untouched.
- **Nothing committed, pushed, or staged** — awaiting review.

---

## 10. Risks / Follow-ups

| Risk | Mitigation |
|---|---|
| Existing DBs seeded before Stage B lack `facturation_view`/`facturation_manage` in the `manager` role. | Manual run required: `python -m app.core.seed` per deployment (documented in Stage B report). |
| A user with `facturation_view` but not `facturation_manage` can see the nav and open lists but create/update actions will 403. | Acceptable per approved policy (view vs. manage separation); UI does not yet hide action buttons — could be a future refinement. |
| Nav hiding is cosmetic only. | Backend 403 is the security boundary (documented above). |

---

## 11. Conclusion

Stage C is complete. Facturation and Invoice Clients nav entries are now
visible only to Admin and Manager (users with `facturation_view`), reusing
the existing permission infrastructure with no new state management. Full
Flutter suite (1601 tests) and `flutter analyze` pass cleanly. Backend Stage B
work is unchanged and preserved. Ready for review — **no commit, push, or
staging performed**.
