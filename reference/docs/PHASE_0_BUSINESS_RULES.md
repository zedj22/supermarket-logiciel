# PHASE 0 — Business Rules

## 1. Sale Transaction (POS)

### Complete Flow (from `main_window.py:10487-10918` and `sales.py:47-378`)

```
1. Validate cart not empty
2. Validate customer selection (if credit/debt sale)
3. Validate pack component stock (if packs in cart)
4. Build items list with product_id, quantity, price, variant_id, is_pack, pack_id, components
5. Calculate items_discount_total = sum of all item_discount values
6. Calculate invoice_discount = sale_discount + items_discount_total
7. Call sales_manager.create_invoice(customer_id, items, invoice_discount, paid, device_name)
8. On success:
   a. Capture product costs for profit tracking (_capture_sale_costs)
   b. Persist item discounts (_persist_item_discounts)
   c. Log action
   d. Record debt if applicable
   e. Clear cart
   f. Print invoice (if enabled)
9. Show toast (success/debt/change)
```

### Inside `SalesManager.create_invoice` (sales.py:47-378):

```
1. Validate inputs (customer_id if > 0 must exist, items not empty)
2. Validate each item:
   - product_id > 0
   - quantity > 0
   - price >= 0
3. Generate invoice number: INV-YYYYMMDD-HHMMSS-XXX
4. BEGIN transaction
5. Insert into sales table
6. For each item:
   a. If pack:
      - Insert pack summary row (product_id=NULL)
      - For each component:
        - Verify component exists
        - Insert component sale_item row
        - Deduct stock: UPDATE products SET quantity = quantity - ? WHERE quantity >= ?
        - Record inventory movement
   b. If variant:
      - Verify variant exists
      - Deduct variant stock: UPDATE product_variants SET quantity = quantity - ? WHERE quantity >= ?
      - Insert sale_item with variant_id
   c. If regular product:
      - Verify product exists and has enough stock
      - Deduct stock: UPDATE products SET quantity = quantity - ? WHERE quantity >= ?
      - Insert sale_item
      - Record inventory movement
7. If customer_id > 0 and there's debt:
   - UPDATE customers SET balance = balance + debt
8. COMMIT
9. Return (True, invoice_number, total, change)
```

### Payment Rules
| Method | Behavior |
|--------|----------|
| `cash` | paid >= total required, change = paid - total |
| `card` | paid >= total required, change = paid - total |
| `partial` | paid < total, debt = total - paid |
| `credit` | paid = 0, debt = total, customer required |

### Discount Rules
- **Item discount**: Per-product discount in cart, stored in `item_discount` field
- **Invoice discount**: Total discount applied to entire invoice
- **Combined**: `total_discount = sale_discount + sum(item_discounts)`
- **PIN requirement**: Discounts above `pin_discount_threshold` setting require admin PIN
- **Negative validation**: Discount cannot be negative or exceed item total

## 2. Stock Deduction

### Optimistic Locking
```sql
UPDATE products SET quantity = quantity - ? WHERE id = ? AND quantity >= ?
```
- If `rowcount == 0`, stock is insufficient → rollback
- Same pattern for variants: `UPDATE product_variants SET quantity = quantity - ? WHERE id = ? AND quantity >= ?`

### Stock Modification Points
| Operation | Direction | Table | Reason Pattern |
|-----------|-----------|-------|----------------|
| Sale | Decrease | products | `بيع - {invoice_number}` |
| Pack sale | Decrease | products | `بيع - {invoice_number}` (components) |
| Variant sale | Decrease | product_variants | same |
| Return | Increase | products | `مرتجع - {invoice_number}` |
| Purchase | Increase | products | `شراء من مورد - {number}` |
| Void invoice | Increase | products | `إلغاء فاتورة - {invoice_number}` |
| Delete purchase | Decrease | products | `حذف فاتورة شراء - {invoice_number}` |
| Manual adjustment | +/- | products | Custom reason |

## 3. Purchase Transaction

### `create_purchase_invoice` (db_manager.py:1804-1962)

```
1. Validate supplier exists (if supplier_id > 0)
2. Validate items (product_id, quantity > 0, price >= 0)
3. Calculate subtotal, apply discount, determine paid_amount, remaining
4. BEGIN
5. Insert purchase header
6. For each item:
   a. Insert purchase_item
   b. UPDATE products SET quantity += qty
   c. If variant: UPDATE product_variants SET quantity += qty
   d. If cost changed: UPDATE products SET cost = price
   e. Insert inventory movement
7. If supplier_id > 0 and remaining > 0:
   - UPDATE suppliers SET balance += remaining
8. COMMIT
9. Return (True, invoice_number, purchase_id, net_total, remaining)
```

### Delete Purchase (`delete_purchase`, db_manager.py:2092-2163)
```
1. Load purchase header
2. Load purchase items
3. BEGIN
4. For each item:
   a. UPDATE products SET quantity -= qty (GREATEST(0, ...))
   b. If variant: UPDATE product_variants SET quantity -= qty
   c. Insert negative inventory movement
5. If supplier has balance: UPDATE suppliers SET balance -= remaining
6. DELETE purchase_items
7. DELETE purchase
8. COMMIT
```

## 4. Invoice Void

### `void_invoice` (db_manager.py:1040-1111)
```
1. Load sale items (product_id, variant_id, quantity)
2. Load sale header
3. BEGIN
4. For each item:
   a. UPDATE products SET quantity += qty
   b. If variant: UPDATE product_variants SET quantity += qty
   c. Insert positive inventory movement
5. If customer has debt from this sale:
   - UPDATE customers SET balance -= paid_amount (GREATEST(0, ...))
6. UPDATE sales SET status='void', total=0, discount=0, paid_amount=0, change_amount=0
7. COMMIT
```

**Known Issue**: Void subtracts `paid_amount` from customer balance, but the comment says it should subtract the debt amount. This may be a bug — if a customer paid partial and the rest was debt, voiding only reverses the paid amount from balance, not the debt portion.

## 5. Returns

### Independent Return (no invoice reference)
- User selects product manually
- Enters quantity/weight/amount
- Stock is restored
- Return is recorded in `returns` table

### Invoice-Based Return
- User enters invoice number
- System loads invoice items
- User selects which items to return and quantities
- Stock is restored for returned quantities
- Return recorded

### Return Effects
- Stock: Increased for returned products
- Financial: Total amount recorded in `returns.total_amount`
- Customer balance: Not directly adjusted (handled separately)
- Reports: Returns are subtracted from net sales in financial reports

## 6. Debt Management

### Dual Tracking
1. **`customers.balance`**: Running balance (positive = owes)
2. **`debt_transactions`**: Individual transaction ledger

### Debt Operations
| Operation | customer.balance | debt_transactions |
|-----------|-----------------|-------------------|
| Sale on credit | `balance += debt` | `record_debt(customer_id, debt, reference=invoice)` |
| Payment | `balance -= payment` | `record_payment(customer_id, payment)` |
| Void sale | `balance -= paid_amount` | None |

**Potential Divergence**: `customers.balance` is updated directly during sales, while `debt_transactions` is updated via `DebtManager`. If one fails, they can diverge.

## 7. Inventory Management

### Stock Adjustment
```python
def change_stock(self, product_id, quantity_change, reason=''):
    current = SELECT quantity FROM products WHERE id = ?
    new_qty = current + quantity_change
    if new_qty < 0: raise error
    UPDATE products SET quantity = new_qty WHERE id = ?
    INSERT INTO inventory_movements (product_id, quantity_change, reason)
```

### Low Stock Threshold
- Default: 5 (configurable in settings)
- Dashboard shows alert when products below threshold
- No automatic notifications

### Movement Tracking
Every stock change is logged in `inventory_movements` with:
- product_id
- quantity_change (positive = add, negative = remove)
- reason (text description)
- movement_date (auto-timestamp)

## 8. Favorites System

### Two Types
1. **Auto favorites**: Top 10 products by sales volume in rolling 30-day window
2. **Manual favorites**: Starred by user (never removed by auto-refresh)

### Refresh Logic
```python
def refresh_auto_favorites():
    top_ids = top_product_ids_by_sales(limit=10, days=30)
    # Remove auto favorites that dropped out
    # Add new top sellers
```

## 9. Pack System

### Pack Structure
- Named bundle of products at a fixed price
- Each component has a product_id and quantity
- Pack has its own selling price

### Pack Sale Behavior
1. Pack summary row inserted (product_id=NULL, pack_id set)
2. Each component inserted as separate sale_item
3. Each component's stock deducted individually
4. Inventory movements recorded per component

### Pack Stock Validation
```python
def check_component_availability(pack_id):
    for component in pack_items:
        stock = SELECT quantity FROM products WHERE id = ?
        if stock < required_qty:
            return False, shortage_report
    return True, None
```

## 10. User Authentication

### PIN System
- PINs stored as SHA-256 hashes with salt
- Format: `salt:hash`
- Roles: `admin`, `cashier`
- Admin required for: settings, void invoices, view passwords, discounts above threshold

### Session Management
- Current user stored in `self.current_user`
- No session timeout
- No concurrent session prevention

## 11. Multi-PC LAN

### Server/Client Model
- Server = main PC with MySQL/MariaDB
- Clients = additional PCs connecting to same database
- All clients share the same database

### Device Discovery
- UDP broadcast on port 50000
- TCP scan of local /24 subnet
- Cached server IP for reconnection

### Pairing System
1. Client sends pairing request
2. Server shows approval dialog
3. Admin approves/denies
4. Approved device added to `authorized_devices`
5. Client connects to database

### Connection Monitoring
- Background thread checks connection every N seconds
- Auto-reconnect on connection loss
- Manual reconnect option
- Status indicator in top bar

## 12. Printing

### Supported Formats
- **80mm thermal**: receipt-style with store info, items, totals
- **A4**: full-page invoice with logo, store info, items table

### Print Libraries
- `reportlab` for PDF generation
- Arabic text support via `arabic-reshaper` + `python-bidi`

## 13. Export

### Formats
- **Excel (xlsx)**: via `openpyxl`
- **CSV (UTF-8)**: standard CSV
- **PDF**: via `reportlab`

### Report Exports
- End-of-shift report
- Financial report
- Product performance
- Category analysis

## 14. Settings

### Store Settings
- Store name, phone, address
- Invoice footer message
- Default paper size
- Auto-print toggle
- Ask before print toggle

### Business Settings
- Allow debt sales toggle
- Low stock threshold
- Discount threshold requiring PIN

### Appearance Settings
- Theme: dark, light, grey
- Language: Arabic, French, English

### Database Settings
- Server host, port, user, password, database name
- Network mode: server, client, local
- Device IP address
