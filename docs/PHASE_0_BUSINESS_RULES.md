# Phase 0 — Business Rules

## Rules retained from observed behavior

| Area | Rule | Target decision |
|---|---|---|
| Sale | Cart must not be empty; line quantity > 0; unit price ≥ 0 | retain, server enforce |
| Sale | Conditional stock decrement prevents a regular product/variant becoming negative | retain, lock + aggregate |
| Credit | Credit/partial payment requires a customer; debt is total minus paid | retain |
| Discount | Item/invoice discount cannot be negative or exceed affected amount; high discount needs admin PIN threshold | retain, configurable RBAC approval |
| Pack | A pack sale must have all component stock; components are deducted | retain |
| Purchase | Items have positive quantity/non-negative cost; a supplier balance increases by unpaid net | retain |
| Purchase deletion | Reverses item stock and supplier outstanding balance | retain only with authorization and reversal record |
| Inventory | Every verified stock mutation records direction/reason | retain, add actor/source/variant fields |
| Customer debt | Balance rises on unpaid sale and falls on payment | retain, derive/reconcile from immutable ledger |
| Variant | Variant may override price and has its own quantity | retain |
| Favourite | Manual favourite persists; automatic favourites are top sellers in rolling 30 days | retain as configurable feature |
| Void | Void restores stock and marks sale void rather than removing it | retain, correct debt reversal |

## Rules to correct / explicitly decide

1. A return linked to a sale cannot exceed the unvoided sold quantity less prior returns. Current independent returns are permitted but must carry a reason and authorization.
   *Resolved by Phase 12 fix round 1 (`PHASE_12_RETURNS_VOIDS_ANALYSIS.md` §10, §26): the return reason is **optional** (omitted / null / blank ⇒ NULL); authorization = the actor's `POS_RETURN` scope plus the audit row. Void reasons remain mandatory.*
2. Customer balance and debt ledger are one logical ledger transaction. A balance is a cached projection, rebuilt/reconciled from entries; never update one without the other.
3. Void reverses the *outstanding debt attributable to the sale*, not its `paid_amount`; preserve original financial snapshot and issue a compensating ledger entry.
4. Sales, returns, purchases, voids and stock adjustments are append-only business documents. Corrections use reversals; physical delete is reserved for unposted drafts and requires audit.
5. Product/category/supplier/customer deletion must refuse when historical references exist (or soft-delete); preserve immutable historical descriptions/prices/costs.
6. A pack is saleable only if active and all aggregate component quantities are available. Variants in packs require an explicit target policy; legacy source is not sufficient proof.
7. Payment split, tax, currency rounding, cash-drawer effect, and negative stock policy are **UNVERIFIED**. Product owner approval is required before implementation.

## Permission matrix proposal

| Action | Admin | Manager | Cashier |
|---|---:|---:|---:|
| POS sale, customer selection | yes | yes | yes |
| Credit / discount within threshold | yes | yes | configured |
| Override discount / void / independent return | yes | approval | no |
| Products, inventory adjustment, purchases | yes | yes | no |
| Supplier/customer master data | yes | yes | configured |
| Financial reports/export/backup | yes | configured | no |
| Users, settings, devices, restore | yes | no | no |

All grants are backend scopes; role labels alone are not authorization. Failed and successful sensitive actions must be auditable.
