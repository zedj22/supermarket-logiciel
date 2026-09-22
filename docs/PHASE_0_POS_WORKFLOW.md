# PHASE 0 — POS Workflow

## Complete POS Flow

### 1. POS Screen Initialization

```
show_pos(preserve_cart=False)
├── Guard: Check database is ready
├── If not preserve_cart: Reset cart, total, customer, filters
├── Build header: Title, action buttons (New Sale, Hold, History, Return)
├── Build product browser:
│   ├── Search bar with debounced search
│   ├── Filter buttons (All, Available, Low Stock, Out of Stock)
│   ├── Category filter dropdown
│   ├── Favorites section (horizontal scroll)
│   └── Product list (paginated, 40 items per page)
└── Build cart panel:
    ├── Cart header (title, item count)
    ├── Customer selector
    ├── Cart items (scrollable)
    ├── Summary (subtotal, discount, total)
    ├── Pay button (F8)
    ├── Hold button
    └── Clear cart button
```

### 2. Product Search Flow

```
User types in search bar
├── pos_search_preview() triggered on KeyRelease
│   ├── Debounce: Wait 200ms after last keystroke
│   ├── If barcode (pure digits): Direct barcode lookup
│   ├── Else: Name search with LIKE
│   └── Render matching products
├── Product display:
│   ├── Product card with image, name, price, stock status
│   ├── Filter by status (available/low/out)
│   ├── Filter by category
│   └── Sort by name/price/stock
└── Click/Enter to add to cart
```

### 3. Add to Cart Flow

```
add_to_cart(event=None)
├── If search bar has barcode (digits):
│   ├── product_manager.get_product_by_barcode(barcode)
│   ├── If found: add_product_to_cart(product)
│   └── If not found: Try variant barcode lookup
├── If search bar has text:
│   ├── products.search_product(text)
│   ├── If exactly 1 result: add_product_to_cart(product)
│   ├── If multiple results: Show selection dialog
│   └── If no results: Show "not found" message
└── Focus back to search bar

add_product_to_cart(product)
├── Check if product has variants:
│   ├── If yes: Show variant picker dialog
│   │   ├── Display all variants with stock
│   │   ├── User selects variant
│   │   └── Add variant to cart
│   └── If no: Check if weighted product:
│       ├── If yes (kg/g/liter): Show quantity dialog
│       │   ├── User enters weight/quantity
│       │   ├── Validate: quantity > 0, quantity <= stock
│       │   └── Add to cart with quantity
│       └──If no (piece): Add 1 to cart
├── Update cart display
└── Update total
```

### 4. Cart Management

```
update_cart_display()
├── Clear existing cart widgets
├── For each item in cart:
│   ├── Render cart item row:
│   │   ├── Product name (or pack name)
│   │   ├── Unit price × quantity
│   │   ├── Total price
│   │   ├── Quantity controls (- / +)
│   │   ├── Item discount button
│   │   └── Remove button
│   └── If pack: Render pack row with components
├── Update subtotal
├── Apply invoice discount
├── Calculate total = subtotal - discount
└── Update total label

update_cart_quantity(index, change)
├── Get item at index
├── new_quantity = current + change
├── Validate: new_quantity > 0
├── Validate: new_quantity <= stock
├── Update item quantity
├── Recalculate item total
└── Update display

remove_from_cart(index)
├── Remove item at index
└── Update display

clear_cart()
├── Reset cart to empty
├── Reset total to 0
├── Reset customer to None
└── Update display
```

### 5. Customer Selection

```
select_customer()
├── Open customer search dialog
├── User types name or phone
├── customer_manager.search_customer(query)
├── Display matching customers
├── User selects customer
├── Store: self.selected_customer = customer
└── Update customer label in cart

Payment dialog customer selection:
├── Same flow as above
├── Show current debt balance
└── Calculate new balance after sale
```

### 6. Discount Application

```
edit_sale_discount()
├── Open discount dialog
├── User enters discount amount
├── Validate: discount >= 0
├── Validate: discount <= subtotal
├── If discount > pin_threshold:
│   ├── require_pin("Apply discount", "admin")
│   ├── If PIN fails: Cancel discount
│   └── If PIN succeeds: Apply discount
├── Store: self.sale_discount = discount
└── Update cart display

_open_item_discount_dialog(index)
├── Open item discount dialog
├── Show item subtotal
├── User enters discount amount
├── Validate: discount >= 0
├── Validate: discount <= item total
├── Store: item["item_discount"] = discount
└── Update cart display
```

### 7. Payment Flow

```
complete_sale()
├── Validate: cart not empty
├── Open payment window
├── Display: total amount
├── Show payment methods:
│   ├── Cash (default)
│   ├── Card
│   ├── Partial payment
│   └── Full credit (debt)
├── User enters paid amount
├── Calculate:
│   ├── If cash/card: change = paid - total
│   ├── If partial: debt = total - paid
│   └── If credit: debt = total, paid = 0
├── Validate:
│   ├── If cash/card: paid >= total
│   ├── If partial: paid < total
│   ├── If credit: customer selected
│   └── If debt > 0: allow_debt setting enabled
├── Validate pack stock (if packs in cart)
└── Confirm payment
```

### 8. Sale Completion (Backend)

```
confirm_payment() → sales_manager.create_invoice()
├── Validate inputs
├── Generate invoice number
├── BEGIN transaction
├── Insert sale record
├── For each cart item:
│   ├── If pack:
│   │   ├── Insert pack summary row
│   │   ├── For each component:
│   │   │   ├── Verify stock
│   │   │   ├── Deduct stock (optimistic lock)
│   │   │   ├── Insert sale_item
│   │   │   └── Record inventory movement
│   ├── If variant:
│   │   ├── Verify variant stock
│   │   ├── Deduct variant stock
│   │   └── Insert sale_item with variant_id
│   └── If regular:
│       ├── Verify product stock
│       ├── Deduct product stock
│       ├── Insert sale_item
│       └── Record inventory movement
├── If customer and debt > 0:
│   ├── UPDATE customers SET balance += debt
│   └── Record debt transaction
├── COMMIT
├── Return (True, invoice_number, total, change)
├── Capture product costs for profit tracking
├── Persist item discounts
├── Log action
└── Show success toast
```

### 9. Post-Sale Actions

```
After successful sale:
├── Clear cart
├── Reset customer
├── Update cart display
├── Refresh POS screen
├── If ask_before_print setting:
│   ├── Show "Print invoice?" dialog
│   └── If yes: Print invoice
├── Else if auto_print setting:
│   └── Print invoice automatically
├── Show toast:
│   ├── If debt: "Sale complete. Debt: X DZD"
│   ├── If change: "Sale complete. Change: X DZD"
│   └── If exact: "Sale complete successfully"
└── Focus back to search bar
```

### 10. Hold/Restore Sale

```
hold_current_sale():
├── Save current cart to self.held_sales list
├── Store: cart, customer, discount, timestamp
├── Show toast "Sale held"
└── Reset POS for new sale

restore_held_sale():
├── If no held sales: Show message
├── Show held sales dialog
├── Display list of held sales with timestamps
├── User selects sale to restore
├── Replace current cart with held cart
├── Restore customer and discount
└── Update display
```

### 11. Invoice Void

```
void_invoice(sale_id):
├── require_pin("Void invoice", "admin")
├── Confirm void action
├── db_manager.void_invoice(sale_id)
│   ├── BEGIN transaction
│   ├── Load sale items
│   ├── For each item:
│   │   ├── Restore product stock
│   │   ├── Restore variant stock (if applicable)
│   │   └── Record positive inventory movement
│   ├── If customer had debt:
│   │   └── Reduce customer balance
│   ├── UPDATE sales SET status='void'
│   └── COMMIT
├── Log action
└── Refresh invoice list
```

### 12. Return Flow

```
show_independent_return_dialog():
├── User searches for product
├── Selects product
├── Enters return quantity
├── Validates: quantity > 0, quantity <= original quantity
├── Creates return record
├── Restores stock
├── Records inventory movement
└── Shows confirmation

show_return_dialog(invoice_number):
├── Load invoice items
├── Display items with quantities
├── User selects items to return
├── User enters return quantities
├── Validates quantities
├── Creates return record
├── Restores stock for each returned item
├── Records inventory movements
└── Shows confirmation
```
