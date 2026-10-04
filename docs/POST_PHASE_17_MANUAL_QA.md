# Post-Phase-17 Manual Acceptance QA — PC1 / PC2 Real-World Test

**Status: PREPARED — checklist not yet executed.** Fill every `Result` cell during the
test (PASS / FAIL / UNVERIFIED + tester initials + date). Nothing in this document has
been verified on real hardware until those cells are filled.

| | |
|---|---|
| Scope | Real-world acceptance of the Phase 1–17 build on two PCs on one LAN, with a 1000-product catalog, line-limit sales (1000 distinct lines in the UI; 5000 / 10000 / 10001 scripted), 5 full-catalog batches, concurrency, reconnect, security, reconciliation |
| Out of scope | Installer / packaging / EXE build, Phase 18 work, architecture changes, changes to Phase 8–16 business logic or API contracts |
| Contract frozen | `POST /sales` accepts **`items[]` with `min 1, max 10000` DISTINCT lines** — `MAX_SALE_LINES = 10_000` in `new_app/backend/app/core/constants.py`, enforced on `CreateSaleRequest.items`, cart-validate `CartValidateRequest.items`, and hold `HoldCreateRequest.items` in `new_app/backend/app/schemas/sale.py`. **Quantity never counts**: 500 of A + 700 of B = 2 lines. Over the cap is HTTP 422 before any write. Returns stay at 200 lines. **Do not raise or lower this limit to make a test pass.** |
| Rule #1 | **No silent fixing.** Every failure, crash, wrong number, or unexpected status is recorded in §14 (defect log) with steps + expected vs actual. Fixes happen only after the test round, in a separate change |
| Rule #2 | Rate limiting, auth, and device guard stay **exactly as shipped** — never disable or loosen them to make a flow work |
| Rule #3 | Anything requiring hardware (printer), a second machine not available, or a scenario not reachable in this build is marked **UNVERIFIED**, never PASS |

---

## 1. Quick reference

### 1.1 Commands (PC1, PowerShell, run from the repo)

```powershell
# Backend — LAN server mode (needed for every two-PC step)
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend
$env:LAN_MODE='1'; $env:DISCOVERY_ENABLED='1'
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000

# Backend — single-PC steps only (PC2 not involved)
$env:LAN_MODE='0'; $env:DISCOVERY_ENABLED='0'
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000

# Frontend (dev) or built exe
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app
flutter run -d windows
# or: flutter build windows --debug   →  build\windows\x64\runner\Debug\supermarket_pos.exe
```

Environment variables above are **per-window**; never edit `new_app\backend\.env`.

### 1.2 QA fixture — exact commands

```powershell
cd C:\Users\MSI\Desktop\supermarket_logiciel\new_app\backend

# 1. seed exactly 1000 products (+ 10 categories) — idempotent, ~6-10 s
.\.venv\Scripts\python.exe scripts\qa_seed_1000_products.py
#    expect: categories: 10/10 present ... products: 0 already present, 1000 to create
#            created 1000 product(s) in ~6-9s      dataset size now: 1000/1000

# 2. re-run — must be a no-op
.\.venv\Scripts\python.exe scripts\qa_seed_1000_products.py
#    expect: 1000 already present, 0 to create

# 3. verify the dataset
.\.venv\Scripts\python.exe scripts\qa_seed_1000_products.py --verify
#    expect: VERIFY PASS  (1000 products, 10 categories, stock range 9999, 0 without movement)

# 4. cleanup — report only (default, changes nothing)
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --include-categories

# 5. cleanup — soft archive (hides from POS/catalog, keeps history + stock movements)
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --archive --include-categories

# 6. cleanup — hard delete QA fixtures only (refuses anything a document references)
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --delete --include-categories

# 7. extend the fixture to 10 000 products — ONLY before §6.2/§6.3 (scripted large sales)
.\.venv\Scripts\python.exe scripts\qa_seed_1000_products.py --products 10000
#    idempotent: re-running keeps the dataset; names/barcodes follow the same QA17 pattern
#    (QA17 Product 1001 … 10000, barcodes QA1700001001 … QA1700010000), stock 9999 each
#    §13.1 then expects 10000 instead of 1000 — record which fixture size the round used
```

All commands print `target: postgresql://host:port/dbname` only — **no credentials are
ever printed**. The scripts read `DATABASE_URL` from `.env` (PC1's acceptance database).

### 1.3 How to recognize QA data

| Table | Marker |
|---|---|
| `products` | `name LIKE 'QA17 Product %'` (`QA17 Product 0001` … `1000`; … `10000` after §1.2 step 7), `barcode LIKE 'QA17%'` (`QA1700000001` … `QA1700001000`; … `QA1700010000` after step 7), `sku LIKE 'QA17-SKU-%'` |
| `categories` | `name LIKE 'QA17 Category %'` (`QA17 Category 01` … `10`) |
| seeded stock | every QA product starts at quantity **9999**, unit `piece`, low-stock 5, cost = 65% of price |
| price rule | deterministic: `price = 10.00 + (index mod 97) × 0.25` (so 0001 = 10.25, 1000 = 17.50) |
| fixture origin | every QA product carries description `QA17 acceptance fixture NNNN (Post-Phase-17 manual QA, safe to delete)` |

### 1.4 Environment matrix

| | PC1 (server / main till) | PC2 (secondary POS client) |
|---|---|---|
| Role | PostgreSQL + FastAPI (`LAN_MODE=1`, `DISCOVERY_ENABLED=1`, `HOST=0.0.0.0`) + Flutter in **server** mode | Flutter only — **no Python, no PostgreSQL, no `.env`** |
| Database | acceptance DB from `.env` | none (talks HTTP only) |
| Connection | `127.0.0.1:8000` for its own till | paired server URL (`http://<pc1-ip>:8000`) |
| Firewall | allow Python/uvicorn inbound TCP 8000 + UDP 8000 (discovery) | allow outbound |

---

## 2. Prerequisites (both PCs) — fill before starting

| # | Check | Expected | Result |
|---|---|---|---|
| 2.1 | PC1 PostgreSQL service running, DB from `.env` reachable | service started | ☐ |
| 2.2 | PC1 migration head | `.\.venv\Scripts\python.exe -m alembic current` shows `5c8d2e1f4a73 (head)` (file `0023_phase17_search_indexes`) | ☐ |
| 2.3 | PC1 backend starts | uvicorn prints `Uvicorn running on http://0.0.0.0:8000` | ☐ |
| 2.4 | PC1 health | `Invoke-RestMethod http://127.0.0.1:8000/api/v1/health` returns healthy | ☐ |
| 2.5 | PC1 backup taken **before** seeding | pg_dump / in-app backup file exists (§12 restores from it) | ☐ |
| 2.6 | Fixture seeded + verified | `--verify` printed `VERIFY PASS` | ☐ |
| 2.7 | PC2 has Flutter (dev) or the built exe, no backend | app launches to first-run/setup wizard | ☐ |
| 2.8 | Both PCs on the same LAN, same subnet; PC1 IP noted | PC1 IP = `____________` | ☐ |
| 2.9 | Admin account + PIN known on PC1 | login works | ☐ |
| 2.10 | Windows firewall prompt accepted for Python on PC1 | inbound 8000 allowed | ☐ |
| 2.11 | (before §6.2/§6.3 only) fixture extended | §1.2 step 7 printed `dataset size now: 10000/10000` | ☐ |

---

## 3. PC1 — server-side checks (backend + own till)

| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | Start backend in LAN mode (§1.1), then `GET /api/v1/health` | 200, healthy; log shows discovery responder started | ☐ |
| 3.2 | `GET /api/v1/system/info` (or UI About) | version/protocol present, no stack traces, no secrets | ☐ |
| 3.3 | Sign in on PC1 Flutter as admin | POS screen opens, no unexpected 401/403 | ☐ |
| 3.4 | Products screen shows the QA catalog | `QA17 Product 0001…` listed with price/stock/category | ☐ |
| 3.5 | Devices screen visible in server mode | pairing code displayed (6 digits, rotates every 5 min) | ☐ |
| 3.6 | Backend log review | no passwords, tokens, or pairing codes printed; secrets redacted | ☐ |
| 3.7 | Restart backend; PC1 till reconnects | PC1 keeps working against `127.0.0.1:8000` | ☐ |

---

## 4. PC2 — connection / discovery / pairing (§6 of the plan)

Steps 1–10, in order. Stop at the first failure and log it.

| # | Step | Expected | Result |
|---|---|---|---|
| 4.1 | PC2 app first run → wizard → **"Connect to an existing server"** | wizard stores `app_run_mode=client`; no backend/DB required | ☐ |
| 4.2 | Discovery runs (UDP broadcast) | PC2 finds server `server_id` + store name from PC1's responder | ☐ |
| 4.3 | Confirm store name shown on PC2 | matches PC1's store name (legacy A4 UX) | ☐ |
| 4.4 | PC1 → Devices screen shows the rotating 6-digit code | code readable, refreshes ≤ every 5 min | ☐ |
| 4.5 | Enter code on PC2 → `POST /devices/pair` | PC2 shows `pending`, starts 2 s polling (5 min timeout) | ☐ |
| 4.6 | PC1 → Devices → pending device appears → **Approve** | status `approved`; audit `device_approve`; PC2 receives token **exactly once** | ☐ |
| 4.7 | PC2 reaches `paired`/`connected`, shows login | normal sign-in over `http://<pc1-ip>:8000` | ☐ |
| 4.8 | Sign in on PC2, open POS, search `QA1700000001` | product returns; no 401/403 (device token + `X-Device-ID` accepted) | ☐ |
| 4.9 | **Deny path** (fresh pair attempt → Deny on PC1) | PC2 shows localized rejection, never a token | ☐ |
| 4.10 | **Re-pair** approved device with a new code | status returns to pending → approve → works again | ☐ |

---

## 5. 1000-product catalog — search, browse, POS add

Perform on **PC1 and PC2**.

| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | Products screen: browse full list, scroll to end | all 1000 QA products + 10 QA categories load, no crash, no missing rows | ☐ |
| 5.2 | Search exact barcode `QA1700000500` | single exact match shown immediately | ☐ |
| 5.3 | Search `QA17 Product 05` (prefix) | 0500–0599 + related matches, responsive (subjectively fast, ≤ ~100 ms feel) | ☐ |
| 5.4 | Search a term matching nothing | "not found" state, no error dialog | ☐ |
| 5.5 | POS: type barcode `QA1700000001` + Enter | product selected via exact match; add to cart succeeds (stock 9999 > 0) | ☐ |
| 5.6 | POS: search by name and add another QA product | cart shows 2 lines, correct prices (server price is authoritative) | ☐ |
| 5.7 | Add a QA product with stock manually set to 0 (pick one, adjust down) | POS refuses to add, shows out-of-stock message | ☐ |
| 5.8 | Category filter on Products + POS picker | each QA category lists its ~100 products | ☐ |
| 5.9 | Time 10 consecutive barcode searches | subjectively instant; note the slowest in ms: `____` | ☐ |

---

## 6. Sale line limit — 1000 lines (UI), 5000 / 10000 / 10001 (scripted)

The cap counts **DISTINCT cart lines, never quantity** (500 of A + 700 of B = 2 lines).
Contract: `MAX_SALE_LINES = 10_000` (header "Contract frozen"); over-cap `items[]` is HTTP 422
**before any write**. Building 5000+ lines by hand is impractical, so 6.1/6.5 are real-UI tests and
6.2–6.4 are scripted. The same contract is covered by automated tests:
`tests/unit/test_sale_line_limit.py` and `tests/integration/test_sale_line_limit_pg.py`.

| Part | Lines | How | Note tag |
|---|---|---|---|
| 6.1 | 1000 distinct | real UI, PC1 (repeat on PC2 as 6.1b if time allows) | `QA17-LINE1000` |
| 6.2 | 5000 distinct | scripted (§1.1 single-PC mode) | `QA17-LINE5000` |
| 6.3 | 10 000 distinct — **at** the cap | scripted | `QA17-LINE10000` |
| 6.4 | 10 001 → 422, zero write | scripted — runs with every script run | `QA17-LINE10001` |
| 6.5 | quantity never counts: 500 + 700 = **2** lines | real UI | — |

### 6.1 UI sale with 1000 distinct lines — steps A…G

One sale containing **all 1000 distinct products** `QA17 Product 0001 … 1000`, quantity 1 each,
on PC1 (repeat on PC2 as 6.1b if time allows). Put note `QA17-LINE1000` on the sale.

| # | Step | Expected | Result |
|---|---|---|---|
| **A** | Build the cart: add all 1000 distinct QA products (scan/search + add) | cart shows 1000 lines, no duplicate merges, live subtotal updates; adding stays responsive at this scale | ☐ |
| **A2** | Over-cap behavior | the POS has **no client-side cart guard** (by design — `pos_screen.dart`); the 10 000-line cap is enforced by the **schema at checkout**, proven by the scripted 10 001 probe in 6.4 (HTTP 422, zero write). Do **not** add a client-side guard and do not change the cap to make a test pass | ☐ |
| **B** | Checkout with `payment_method=cash`, `paid = exact total` | HTTP 201 exactly once; UI shows the invoice with the 1000 lines; no timeout | ☐ |
| **C** | DB: `SELECT count(*) FROM sale_lines WHERE sale_id = <id>` | **1000** | ☐ |
| **C2** | DB: sale `subtotal`/`total` equal the sum of `line_total` over its 1000 lines | equal (SQL §13.3) | ☐ |
| **D** | Inventory: each of the 1000 products stock 9999 → 9998, one `sale` movement each | exact (§13.4) | ☐ |
| **E** | Payment: `sales.paid` / `sales.change` correct, one cash row in `sale_payments`, `debt = 0` | correct | ☐ |
| **F** | Invoice/receipt UI: number, date/time, store identity, all 1000 lines, totals | renders completely, totals match C2 (physical print = §12.14) | ☐ |
| **G** | Reports/Dashboard/Day-close for today include this sale **once** | reconciles with §13 | ☐ |
| **G2** | Re-submit the same checkout (same `client_request_id`) — POS retry simulation | idempotent replay: original sale returned, **no second sale** (§13.2 stays at 1 for this note) | ☐ |

Expected values to record: subtotal `__________` total `__________` paid `__________`
change `__________` sale id `________________________` invoice `____________`.

### 6.2 / 6.3 Scripted sales — 5000 and 10 000 lines

**Preconditions**

1. Fixture extended to 10 000 products: §1.2 step 7 (`--products 10000`), §2.11 ☑.
2. Backend running in **single-PC mode** (§1.1 second block). The script is a raw HTTP call with no
   device token; in LAN mode the device guard would (correctly) reject it (§10.3) — **do not disable
   or loosen the guard**. Two-PC UI steps stay in LAN mode as usual.
3. Admin PIN from §2.9 (`pin = '1234'` below is the fixture default).
4. `curl.exe` ships with Windows 10+; PowerShell is 5.1.

**Script** — paste into a PowerShell window on PC1 (or save as `qa17_large_sale.ps1` and run
`powershell -NoProfile -ExecutionPolicy Bypass -File ...`). Run once with `$N = 5000`, then once
with `$N = 10000`.

```powershell
$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:8000'
$N = 5000                      # then re-run with $N = 10000

# 1) login as admin
$users = (Invoke-RestMethod "$base/api/v1/auth/login-users").items
$admin = $users | Where-Object { $_.full_name -eq 'Admin' } | Select-Object -First 1
if (-not $admin) { $admin = $users | Select-Object -First 1 }
$login = Invoke-RestMethod "$base/api/v1/auth/login" -Method Post `
    -ContentType 'application/json' `
    -Body (@{ user_id = $admin.id; pin = '1234' } | ConvertTo-Json)
$token = $login.access_token

# 2) page through the catalog (server caps page_size at 100)
$items = New-Object 'System.Collections.Generic.List[object]'
$page = 1
$r = $null
do {
    $r = Invoke-RestMethod "$base/api/v1/products?page=$page&page_size=100" `
        -Headers @{ Authorization = "Bearer $token" }
    foreach ($p in $r.items) {
        if ($items.Count -lt $N) {
            $items.Add(@{
                product_id    = $p.id
                quantity      = '1.000'
                unit_price    = ('{0:F3}' -f $p.price)
                line_discount = '0.000'
            })
        }
    }
    $page++
} while ($page -le $r.pages -and $items.Count -lt $N)
if ($items.Count -lt $N) { throw "only $($items.Count) products - run fixture step 7 first" }
Write-Output "items: $($items.Count)"

# 3) payload (WriteAllText => UTF-8 without BOM, which curl needs)
$sum = 0.0
foreach ($i in $items) { $sum += [double]$i.unit_price }
$clientRequestId = "qa17-line$N-$([guid]::NewGuid().Guid)"
$payload = @{
    client_request_id = $clientRequestId
    items             = $items
    invoice_discount  = '0.000'
    payment_method    = 'cash'
    paid              = ('{0:F3}' -f $sum)
    device_id         = 'QA17-SCRIPT'
    note              = "QA17-LINE$N"
} | ConvertTo-Json -Depth 8
$path = Join-Path $env:TEMP 'qa17_large_sale.json'
[IO.File]::WriteAllText($path, $payload)

# 4) checkout
$respPath = Join-Path $env:TEMP 'qa17_large_sale_resp.json'
$code = curl.exe -s -o $respPath -w "%{http_code}" -X POST "$base/api/v1/sales" `
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "@$path"
Write-Output "POST /sales -> HTTP $code"
if ($code -ne '201') { Get-Content $respPath -Raw; exit 1 }
$resp = Get-Content $respPath -Raw | ConvertFrom-Json
Write-Output ("sale id={0} invoice={1} lines={2} total={3} replay={4}" -f `
    $resp.id, $resp.invoice_number, $resp.lines.Count, $resp.total, $resp.idempotent_replay)

# 5) idempotent replay: exact same payload again
$code2 = curl.exe -s -o $respPath -w "%{http_code}" -X POST "$base/api/v1/sales" `
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "@$path"
$resp2 = Get-Content $respPath -Raw | ConvertFrom-Json
Write-Output ("replay -> HTTP {0} same_id={1} idempotent_replay={2}" -f `
    $code2, ($resp2.id -eq $resp.id), $resp2.idempotent_replay)

# 6) over-cap probe (6.4): 10 001 lines, one real product repeated -> 422, zero write
$over = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt 10001; $i++) {
    $over.Add(@{ product_id = $items[0].product_id; quantity = '1.000'; unit_price = '10.000'; line_discount = '0.000' })
}
$overPayload = @{
    client_request_id = "qa17-line10001-$([guid]::NewGuid().Guid)"
    items             = $over
    invoice_discount  = '0.000'
    payment_method    = 'cash'
    paid              = '100010.000'
    device_id         = 'QA17-SCRIPT'
    note              = 'QA17-LINE10001'
} | ConvertTo-Json -Depth 8
$overPath = Join-Path $env:TEMP 'qa17_over_limit.json'
[IO.File]::WriteAllText($overPath, $overPayload)
$code3 = curl.exe -s -o $respPath -w "%{http_code}" -X POST "$base/api/v1/sales" `
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "@$overPath"
$body3 = Get-Content $respPath -Raw | ConvertFrom-Json
Write-Output ("over-limit -> HTTP {0} code={1} details.items={2}" -f `
    $code3, $body3.error.code, $body3.error.details.items)
```

**Expected — 6.2 (`$N = 5000`) and 6.3 (`$N = 10000`)**

| Check | Expected | Result |
|---|---|---|
| `items:` line | `5000` / `10000` (paged 100/page → 50 / 100 requests) | ☐ |
| `POST /sales` | HTTP **201**; `lines=` equals `$N`; total = sum of the first `$N` QA prices; payload ≈ 1.26 MB / 2.52 MB | ☐ |
| Duration | whole script ≈ **12 s** / ≈ **24 s** (checkout alone ≈ 6 s / ≈ 12 s — must stay under the 30 s API timeout) | ☐ |
| replay line | HTTP 201, `same_id=True`, `idempotent_replay=True`; still exactly **one** sale row | ☐ |
| over-limit line | HTTP **422** with `VALIDATION_ERROR` (always, on every run) — detail in 6.4 | ☐ |
| DB after both runs | SQL block below: one sale per note, line counts = the note's number, stock consistent | ☐ |
| UI while/after | POS UI stays responsive during the script; after refresh the sale appears in reports/Day-close | ☐ |

```sql
-- one sale per note tag, line counts equal the tag's number (also feeds 13.2)
SELECT s.note, count(DISTINCT s.id) AS sales, count(l.id) AS lines
FROM sales s LEFT JOIN sale_lines l ON l.sale_id = s.id
WHERE s.note LIKE 'QA17-LINE%' GROUP BY s.note;
-- expect QA17-LINE1000 1/1000, QA17-LINE5000 1/5000, QA17-LINE10000 1/10000, no QA17-LINE10001 row

-- one -1 movement per line of the 10 000-line sale
SELECT count(*), min(quantity_change), max(quantity_change)
FROM inventory_movements
WHERE movement_type = 'sale'
  AND source_document_id IN (SELECT id FROM sales WHERE note = 'QA17-LINE10000');
-- expect 10000, -1, -1

-- totals equal their lines (runs for every QA17-% note)
-- SQL from 13.3
```

### 6.4 Over the cap — 10 001 lines → HTTP 422, zero write

Runs automatically as step 6 of every script run (6.2/6.3). The probe repeats one real product id
10 001 times: rejection happens during **request validation**, before any product is resolved or
any row is touched — so distinctness of the probe itself is irrelevant.

| Check | Expected | Result |
|---|---|---|
| HTTP | **422**, `error.code = VALIDATION_ERROR`, `error.details.items` = `List should have at most 10000 items after validation, not 10001` | ☐ |
| Zero write | `SELECT count(*) FROM sales WHERE note = 'QA17-LINE10001'` → **0**; no sale_lines / movements / sale_payments for that `client_request_id`; no stock change (§13.5) | ☐ |
| Boundary | 10 000 lines → 201 (6.3), 10 001 → 422: the cap is **inclusive**; 1 line → 201 (§5.5) | ☐ |
| Recovery | after the failed call, a normal UI checkout still succeeds (1-line sale) — cart/session not corrupted | ☐ |

### 6.5 Quantity is never counted (UI)

| # | Step | Expected | Result |
|---|---|---|---|
| 6.5a | Cart: one distinct QA product × **500**, another distinct QA product × **700** (quantity control) | cart shows exactly **2 lines**; subtotal = 500×p1 + 700×p2 | ☐ |
| 6.5b | Checkout `cash`, paid = exact total | 201; `SELECT count(*) FROM sale_lines WHERE sale_id = <id>` → **2** (not 1200) | ☐ |
| 6.5c | Stock: product1 9999 → 9499, product2 9999 → 9299; movements `−500` and `−700` | exact (§13.4) | ☐ |

---

## 7. Five batches covering all 1000 products — payments A…E

Five sales, each with **200 distinct QA products**, tag each with its note:

| Batch | Products | Payment method | Note tag | Special pre-condition |
|---|---|---|---|---|
| A | 0001–0200 | `cash` | `QA17-BATCH-A` | none |
| B | 0201–0400 | `credit` (full customer debt) | `QA17-BATCH-B` | customer exists with **non-zero** `debt_ceiling` (0 = debt forbidden) |
| C | 0401–0600 | `partial` (part paid, rest debt) | `QA17-BATCH-C` | same/other customer with ceiling covering the remainder |
| D | 0601–0800 | `card` | `QA17-BATCH-D` | none |
| E | 0801–1000 | `cash` | `QA17-BATCH-E` | none |

| # | Step | Expected | Result |
|---|---|---|---|
| 7.1 | Batch A completes (200 lines, cash) | success; stock decremented; reports include it | ☐ |
| 7.2 | Batch B: credit sale, `paid = 0` | success; customer balance += total; debt ledger row; ceiling not exceeded | ☐ |
| 7.3 | Batch C: partial payment | success; `debt = total - paid > 0`; balance and ledger correct | ☐ |
| 7.4 | Batch D: card payment | success; payment method recorded `card` | ☐ |
| 7.5 | Batch E: cash | success | ☐ |
| 7.6 | Attempt a credit sale that would **exceed** the ceiling | HTTP 422 `DEBT_CEILING_EXCEEDED`, nothing persisted | ☐ |
| 7.7 | Attempt credit with `paid > 0` and method `credit` | rejected (`credit` requires `paid = 0`) | ☐ |
| 7.8 | Verify all 1000 QA products have now been sold at least once (each batch hit its 200) | §13.6 `sold_products = 1000` | ☐ |
| 7.9 | Run on **PC2** for at least one batch (B or C) | identical result, `device_id` of PC2 attributed on those sales | ☐ |

---

## 8. PC1 + PC2 concurrency

| # | Step | Expected | Result |
|---|---|---|---|
| 8.1 | Simultaneously: PC1 adds batch E lines to its cart while PC2 searches/browses | PC2 search stays responsive, PC1 cart unaffected | ☐ |
| 8.2 | Simultaneously checkout two sales (one per PC) within the same second | both succeed; no lost sale, no duplicate totals, both in reports | ☐ |
| 8.3 | Two cash sales of the **same product** racing (both PCs, one product each) | stock decremented twice correctly, never negative, no 500 | ☐ |
| 8.4 | PC1 voids/returns a line while PC2 sells the same product | no deadlock/500; stock and totals consistent afterwards | ☐ |
| 8.5 | Repeat each race 3× | consistent, no flaky failure; record any 4xx/5xx: `____________` | ☐ |
| 8.6 | PC1 checks out its §6.1 1000-line cart at the same moment PC2 completes a normal sale | both succeed (no 409/500/timeout); both appear once in reports; stock correct for both | ☐ |

---

## 9. Reconnect / IP change / rediscovery

| # | Step | Expected | Result |
|---|---|---|---|
| 9.1 | Stop backend 30 s while PC2 is at POS | PC2 shows disconnected/offline state, queued UI is sane, no crash, no data loss | ☐ |
| 9.2 | Restart backend | PC2 reconnects automatically, login/session intact, working state restored | ☐ |
| 9.3 | Kill PC2 app, restart it | reconnects (cached address → UDP rediscovery fallback logged on PC2) | ☐ |
| 9.4 | Change PC1's IP (DHCP/static change) and restart backend | PC2 rediscovers via UDP and adopts the new address without re-pairing | ☐ |
| 9.5 | With PC1 **stopped**, retry from PC2 | clear "server unavailable" message, retry/backoff visible, never a silent hang | ☐ |
| 9.6 | Revoke PC2's device from PC1's Devices screen **while PC2 is signed in** | PC2's next API call fails with `DEVICE_REVOKED`, UI offers re-pair; no token leakage | ☐ |
| 9.7 | Backend restarted **mid-sale** (cart open) | no partial sale written; cart either recovered or cleanly reset (record which) | ☐ |

---

## 10. Auth / security regression (do not loosen anything)

| # | Step | Expected | Result |
|---|---|---|---|
| 10.1 | Wrong PIN repeatedly (≥5) | lockout/throttling applies; no unbounded guessing window | ☐ |
| 10.2 | Hammer `POST /devices/pair` with bad codes (≥6 in a minute) | rate-limited 429 from the 5/min/IP + 10/min global limits — **leave the limits in place** | ☐ |
| 10.3 | Call an API without `X-Device-Token` from PC2 (LAN mode) | rejected (device guard), no data returned | ☐ |
| 10.4 | Call with a revoked token | `DEVICE_REVOKED`, no data | ☐ |
| 10.5 | Non-manager account tries settings/backup/devices actions | 403 with clean message; UI hides/gates the action | ☐ |
| 10.6 | Scan backend logs for secrets | no passwords, JWTs, device tokens, or pairing codes present | ☐ |
| 10.7 | 200/201/401/403/422/429 responses | structured error envelope, no stack traces, no SQL fragments | ☐ |
| 10.8 | Unexpected 401/403/429 during normal flows (login, POS, reports) | none; record every occurrence in §14 | ☐ |

---

## 11. Inventory / customers / returns / purchases / reports

| # | Area | Step | Expected | Result |
|---|---|---|---|---|
| 11.1 | Inventory | Stock screen: QA products show 9999 − sold | matches §13.4 exactly | ☐ |
| 11.2 | Inventory | Manual adjustment +5 / −5 on one QA product | movement rows (before/after) recorded, PMP unchanged by pure adjustment | ☐ |
| 11.3 | Inventory | Low-stock view after selling one product below its threshold of 5 | appears in low-stock list | ☐ |
| 11.4 | Customers | Create customer with `debt_ceiling = 0`, try credit sale | rejected (0 = no debt allowed) | ☐ |
| 11.5 | Customers | Pay part of the batch-B debt; balance and ledger update | balance decreases, ledger rows match, audit written | ☐ |
| 11.6 | Returns | Return lines from an earlier QA sale (partial return) | stock restored, refund/credit recorded, sale shows returned state | ☐ |
| 11.7 | Voids | Void a same-day sale | sale status `voided`, stock restored, reports exclude it, audit has actor | ☐ |
| 11.8 | Purchases | Receive stock for one QA product (supplier invoice) | stock +, PMP/avg cost updates, purchase + lines persisted | ☐ |
| 11.9 | Suppliers | Supplier balance after purchase and after payment | correct | ☐ |
| 11.10 | Expenses | Create expense for today | appears in expenses list and day totals | ☐ |
| 11.11 | Reports | Sales report filtered to today: totals = §13 sums | equal, no double counting of replays | ☐ |
| 11.12 | Dashboard | Today's revenue/payment split/low-stock cards | reconcile with reports and §13 | ☐ |
| 11.13 | Day close | Run/inspect day-close for today | consistent totals; rerun is idempotent | ☐ |
| 11.14 | Export | CSV export of today's sales | row count and totals match reports (file lands outside the repo, or is deleted) | ☐ |

---

## 12. Backup / restore / printing / localization / failure

| # | Area | Step | Expected | Result |
|---|---|---|---|---|
| 12.1 | Backup | Take a backup from the app (PC1) | file created, success message, no credentials shown | ☐ |
| 12.2 | Restore | Restore **into a scratch/test database only** (never over the acceptance DB mid-test) | restores cleanly, counts match the dump | ☐ |
| 12.3 | Backup integrity | `pg_restore --list` (or equivalent) on the file | no errors | ☐ |
| 12.4 | Printing | Print a receipt on real hardware | prints correct layout → **UNVERIFIED if no printer attached** | ☐ |
| 12.5 | Print settings | Toggle `ask_before_print` / auto-print in settings | prompt behaves per setting; no print job when auto-print off | ☐ |
| 12.6 | Localization | Switch AR / FR / EN | every visible string translated, numbers/currency formats follow locale | ☐ |
| 12.7 | RTL | Switch to Arabic | full RTL mirroring, no clipped/overlapping text on POS, dialogs, reports | ☐ |
| 12.8 | Themes | Light/dark (and system) | readable contrast everywhere, no invisible text | ☐ |
| 12.9 | Localization persistence | Restart app | language/theme kept | ☐ |
| 12.10 | Failure | Kill the Flutter app at the checkout confirm moment | no partial sale on restart (either committed once or not at all) | ☐ |
| 12.11 | Failure | Unplug/disable PC2 network mid-request | timeout → clear error → retry works; no duplicate sale after retry (§6 G2) | ☐ |
| 12.12 | Failure | Backend exception (force a 500 if reachable, else skip) | structured 500 envelope, backend stays up, client shows recoverable message | ☐ |
| 12.13 | Rollback | After any failed restore/cancel action | DB state equals pre-action state (counts unchanged) | ☐ |
| 12.14 | Large invoice | Invoice/receipt UI for the §6.1 1000-line sale: full list, totals, paging/scroll | all 1000 lines render, totals match §6.1 C2; physical print → **UNVERIFIED if no printer attached** | ☐ |

---

## 13. Final DB reconciliation (run on PC1 after all sales)

> Record results in §15. Replace nothing — report what the database actually says.

**13.1 QA dataset**

```sql
SELECT count(*) FROM products  WHERE name LIKE 'QA17 Product %';   -- expect 1000 (10000 after §1.2 step 7)
SELECT count(*) FROM categories WHERE name LIKE 'QA17 Category %'; -- expect 10
SELECT count(DISTINCT category_id) FROM products WHERE name LIKE 'QA17 Product %'; -- expect 10
SELECT min(quantity), max(quantity) FROM products WHERE name LIKE 'QA17 Product %';
-- before sales: 9999/9999; after: 9999 minus sold qty
```

**13.2 Batch / line-limit sales**

```sql
SELECT note, count(*) AS sales, sum(total) AS total, sum(subtotal) AS subtotal
FROM sales WHERE note LIKE 'QA17-BATCH-%' OR note LIKE 'QA17-LINE%'
GROUP BY note ORDER BY note;
-- expect one row per executed tag: BATCH-A..E + LINE1000 + LINE5000 + LINE10000,
-- sales = 1 per note; NO row for QA17-LINE10001 (that request was rejected, 6.4)

SELECT s.note, count(l.id) AS lines
FROM sales s JOIN sale_lines l ON l.sale_id = s.id
WHERE s.note LIKE 'QA17-LINE%' GROUP BY s.note;
-- expect LINE1000 = 1000, LINE5000 = 5000, LINE10000 = 10000 distinct lines per sale

SELECT count(DISTINCT product_id) FROM sale_lines l
JOIN sales s ON s.id = l.sale_id WHERE s.note LIKE 'QA17-BATCH-%';
-- expect 1000 when all five batches ran
```

**13.3 Sale totals must equal their lines**

```sql
SELECT s.id, s.subtotal, s.total,
       (SELECT sum(l.line_total) FROM sale_lines l WHERE l.sale_id = s.id) AS lines_sum
FROM sales s WHERE s.note LIKE 'QA17-%'
-- s.total == lines_sum for every row (allow for server-applied invoice discount = 0)
```

**13.4 Inventory drift (sale effect)**

```sql
SELECT p.name, p.quantity,
       (SELECT coalesce(sum(quantity_change),0) FROM inventory_movements m
         WHERE m.product_id = p.id AND m.movement_type = 'sale') AS sold
FROM products p WHERE p.name LIKE 'QA17 Product %'
ORDER BY p.name;
-- sold > 0 for every product touched by a batch; quantity == 9999 - sold
-- (minus purchases/returns/adjustments performed in §11)
```

**13.5 Documents / audit**

```sql
SELECT count(*) FROM sales           WHERE note LIKE 'QA17-%';
SELECT count(*) FROM sale_lines      WHERE sale_id IN (SELECT id FROM sales WHERE note LIKE 'QA17-%');
SELECT count(*) FROM sale_payments   WHERE sale_id IN (SELECT id FROM sales WHERE note LIKE 'QA17-%');
SELECT count(*) FROM audit_logs      WHERE created_at >= <test start>;
-- payments exist for every sale; audit rows exist for sales/returns/voids/approvals/settings
```

**13.6 Sold coverage + debt**

```sql
SELECT count(DISTINCT product_id) FROM sale_lines;                 -- 1000 after 5 batches
SELECT customer_id, sum(total - paid) FROM sales
 WHERE note IN ('QA17-BATCH-B','QA17-BATCH-C') GROUP BY customer_id; -- = customer balance increase
```

**13.7 Cleanup (after the round is signed off)**

```powershell
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --include-categories   # report
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --delete --include-categories
# products referenced by a sale are reported and kept - archive them instead if preferred:
.\.venv\Scripts\python.exe scripts\qa_cleanup_1000_products.py --archive --include-categories
```

---

## 14. Defect log (§23 rules — one row per defect, no silent fixing)

| # | Date/tester | Area (§) | Steps to reproduce | Expected | Actual (status code / message / screenshot) | Severity (S1–S4) | Fixed in |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |

Severity: **S1** data loss/money/stock wrong · **S2** feature unusable · **S3** workaround
exists · **S4** cosmetic.

Rules: capture the exact HTTP status + error `code`, the backend log line, and the DB
row count that proves it. Do **not** edit code, config, rate limits, or contracts during
the round — file the row and continue.

---

## 15. Sign-off summary

| Group | Sections | PASS | FAIL | UNVERIFIED | Notes |
|---|---|---|---|---|---|
| Prerequisites / fixture | §2 | | | | |
| Server-side (PC1) | §3 | | | | |
| Pairing / two-PC | §4 | | | | |
| 1000-product search | §5 | | | | |
| Line-limit sales | §6 | | | | |
| 5 batches / payments | §7 | | | | |
| Concurrency | §8 | | | | |
| Reconnect / IP change | §9 | | | | |
| Security | §10 | | | | |
| Inventory→reports | §11 | | | | |
| Backup/print/localization/failure | §12 | | | | |
| DB reconciliation | §13 | | | | |

**Outcome:** ☐ PASS (all sections PASS) ☐ PASS WITH DEFECTS (no S1/S2 open) ☐ FAIL
(S1/S2 open)

Tester `__________` date `__________` reviewer `__________`

### Carried UNVERIFIED items (expected, not failures)

- Physical printing without a printer attached (§12.4).
- Navigation `< 100 ms` SLO — no Flutter performance harness exists (carried from §17.9).
- Installer/service auto-start packaging — explicitly out of scope for this round.
