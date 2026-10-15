// Documentation Center — localized content for the registered chapters
// (Phase 3: Getting Started, Dashboard, POS).
//
// Every string is keyed by a stable id; the same key must exist in all
// three locales (en, fr, ar) — enforced by doc_registry_test.dart.
// Content claims come only from verified current behavior; see the
// Phase 1 audit and the widget/unit tests for each feature.
//
// No real store data, credentials, contact details, or unverified
// features appear here. Screenshots are intentionally absent until the
// Phase 4 demo dataset exists (screenshotRefs stays empty).

/// locale → contentKey → text.
const Map<String, Map<String, String>> docContent = <String, Map<String, String>>{
  // -------------------------------------------------------------------------
  // English
  // -------------------------------------------------------------------------
  'en': <String, String>{
    // Chapter titles.
    'chapter.getting_started.title': 'Getting Started',
    'chapter.dashboard.title': 'Dashboard',
    'chapter.pos.title': 'Point of Sale',

    // ------------------------------------------------------------------
    // Chapter 1 — Getting Started
    // ------------------------------------------------------------------
    'gs_first_launch.title': 'First launch and network setup',
    'gs_first_launch.summary':
        'Choose the machine role and connect clients to the server.',
    'gs_first_launch.s1.heading': 'Choose this machine\u2019s role',
    'gs_first_launch.s1.p1':
        'On its very first launch the application opens a setup wizard. '
        'You must choose a role before anything else can run.',
    'gs_first_launch.s1.step1':
        'Server — the main machine that hosts the database. It opens the '
        'dashboard directly and does not pair with itself.',
    'gs_first_launch.s1.step2':
        'Client — a cashier or back-office PC that connects to the server '
        'over the local network.',
    'gs_first_launch.s1.tip1':
        'The wizard cannot be closed on first run; the choice is required.',
    'gs_first_launch.s2.heading': 'Connect a client to the server',
    'gs_first_launch.s2.step1':
        'On a client, the wizard searches the local network for the server '
        'automatically.',
    'gs_first_launch.s2.step2':
        'Select the discovered server, or enter its address manually if '
        'discovery fails.',
    'gs_first_launch.s2.step3':
        'Enter the pairing code shown on the client when asked.',
    'gs_first_launch.s2.step4':
        'An administrator approves the new device from the Devices section '
        'before the client can sign in.',
    'gs_first_launch.s3.heading': 'Prerequisites',
    'gs_first_launch.s3.p1':
        'All machines must be on the same local network, and the server '
        'machine must be running for clients to connect. Later, the wizard '
        'is reachable again from Settings for device management.',
    'gs_first_launch.s3.warn1':
        'A client that has never completed the wizard cannot be used — '
        'there is no device identity yet.',

    'gs_admin_login.title': 'Administrator account and login',
    'gs_admin_login.summary':
        'Create the first administrator, then sign in with a PIN.',
    'gs_admin_login.s1.heading': 'Create the first administrator',
    'gs_admin_login.s1.p1':
        'Right after the network step, the application asks for the first '
        'administrator account: a full name and a PIN, entered twice to '
        'confirm it.',
    'gs_admin_login.s1.warn1':
        'There is no default password. Choose your own PIN during setup and '
        'keep it private — the application never ships with a built-in one.',
    'gs_admin_login.s2.heading': 'Signing in',
    'gs_admin_login.s2.p1':
        'The login screen lists the users an administrator has created. '
        'Pick your name and enter your PIN on the keypad.',
    'gs_admin_login.s2.p2':
        'After signing in you land on the Dashboard. Your user name and '
        'roles are shown in the top bar, where you can also log out.',

    'gs_navigation.title': 'Navigating the main sections',
    'gs_navigation.summary':
        'The navigation rail, the main screens, and the global shortcuts.',
    'gs_navigation.s1.heading': 'The navigation rail',
    'gs_navigation.s1.p1':
        'A navigation rail on the side lists the application sections in '
        'groups. Items you do not have permission for are hidden, so the '
        'rail only shows what your account can actually use.',
    'gs_navigation.s2.heading': 'Main sections',
    'gs_navigation.s2.step1': 'Dashboard — an overview of today and your stock.',
    'gs_navigation.s2.step2': 'Point of Sale — ringing up sales (F1).',
    'gs_navigation.s2.step3': 'Products — manage your catalog (F2).',
    'gs_navigation.s2.step4':
        'Stock, Sales, Clients, Debts, Purchases, Promotions, Packs, '
        'Expenses, Facturation and Reports — organized by your permissions.',
    'gs_navigation.s2.tip1':
        'Global shortcuts work anywhere: F1 opens the POS, F2 Products, '
        'and F4 focuses the search field of the current page.',
    'gs_navigation.s3.heading': 'Help and this manual',
    'gs_navigation.s3.p1':
        'The question-mark button in the top bar opens the keyboard '
        'shortcuts list. The About page (Settings group) shows the app and '
        'server versions and links to this Documentation Center.',

    'gs_workflow.title': 'A practical first-use workflow',
    'gs_workflow.summary': 'From an empty install to your first test sale.',
    'gs_workflow.s1.heading': 'Suggested order of work',
    'gs_workflow.s1.step1': 'Sign in as the administrator.',
    'gs_workflow.s1.step2':
        'Open Products and create a few products with barcodes and prices.',
    'gs_workflow.s1.step3':
        'Optionally create packs or promotions if you use them.',
    'gs_workflow.s1.step4':
        'Open the Point of Sale (F1) and try a test sale with cash payment.',
    'gs_workflow.s1.step5':
        'Print or preview the receipt if printing is configured.',
    'gs_workflow.s1.step6':
        'Open the Dashboard to see the sale reflected in today\u2019s numbers.',
    'gs_workflow.s1.tip1':
        'You can change language and theme at any time in Settings.',

    // ------------------------------------------------------------------
    // Chapter 2 — Dashboard
    // ------------------------------------------------------------------
    'dash_overview.title': 'What the dashboard shows',
    'dash_overview.summary':
        'Key numbers, recent sales and top products at a glance.',
    'dash_overview.s1.heading': 'Purpose and access',
    'dash_overview.s1.p1':
        'The Dashboard is the first screen after login. It summarizes '
        'today\u2019s activity, your inventory position and customer debts '
        'so you can decide what to do next.',
    'dash_overview.s1.p2':
        'It requires the financial reports permission. Without it you see a '
        'permission-denied message instead of data.',
    'dash_overview.s2.heading': 'The summary cards',
    'dash_overview.s2.p1':
        'Cards are grouped into three rows. Today: sales, invoices, profit '
        'and expenses for the current day. Products & stock: product count, '
        'stock value and how many products are low on stock. Customers & '
        'debts: customer count, customers with debt and total debt.',
    'dash_overview.s2.tip1':
        'The Today row always shows the current day\u2019s figures, '
        'whatever period is selected below.',
    'dash_overview.s3.heading': 'Recent sales and top products',
    'dash_overview.s3.p1':
        'Recent sales lists the latest completed sales of the selected '
        'period, up to five: invoice number, date, payment method and total.',
    'dash_overview.s3.p2':
        'Top products shows the five best-selling products of the period as '
        'a simple bar chart and a list with quantity sold, net sales and '
        'profit.',
    'dash_overview.s3.warn1':
        'These lists are summaries only — open Sales or Reports for the '
        'full history. Empty periods simply show "No data for this period".',

    'dash_controls.title': 'Period filters and actions',
    'dash_controls.summary': 'Change the period, refresh, open Reports.',
    'dash_controls.s1.heading': 'Choosing a period',
    'dash_controls.s1.p1':
        'The period bar offers presets (today, yesterday, last 7 days, this '
        'month and longer ranges) plus a custom range through the two date '
        'buttons.',
    'dash_controls.s1.p2':
        'Changing the period reloads the recent sales and top products '
        'lists for the chosen dates.',
    'dash_controls.s2.heading': 'Refresh and Reports',
    'dash_controls.s2.step1':
        'The refresh button reloads the current data without losing your '
        'selection.',
    'dash_controls.s2.step2':
        'The Reports button opens the full Reports section with the same '
        'period applied — use it for exports and detailed analysis.',
    'dash_controls.s2.step3':
        'If loading fails, a Retry button appears; previous data stays on '
        'screen while reloading.',

    // ------------------------------------------------------------------
    // Chapter 3 — Point of Sale
    // ------------------------------------------------------------------
    'pos_opening.title': 'Opening the POS and layout',
    'pos_opening.summary': 'Find the screen, the search field and the cart.',
    'pos_opening.s1.heading': 'Opening the screen',
    'pos_opening.s1.p1':
        'Open the Point of Sale from the navigation rail or press F1 from '
        'anywhere. The product search field is focused automatically so you '
        'can scan or type immediately.',
    'pos_opening.s2.heading': 'What is on the screen',
    'pos_opening.s2.step1':
        'The search field at the top: scan a barcode or type a name, then '
        'press Enter.',
    'pos_opening.s2.step2':
        'The catalog below, switchable between a grid and a list view; '
        'your choice is remembered.',
    'pos_opening.s2.step3':
        'A favorites row on wide windows, and a Packs button that opens the '
        'pack picker.',
    'pos_opening.s2.step4':
        'The cart panel with the lines, quantity controls and totals. On '
        'narrow windows the cart becomes a slide-in panel.',
    'pos_opening.s3.heading': 'Adding a product',
    'pos_opening.s3.p1':
        'Press Enter in the search field to add the exact barcode, name or '
        'SKU match — or the first result. A short delay after typing shows '
        'matching products you can click instead.',
    'pos_opening.s3.warn1':
        'Archived products cannot be added, and products with no stock are '
        'blocked with a clear message.',

    'pos_selling.title': 'Adding products and quantities',
    'pos_selling.summary': 'Variants, selling units, and quantity entry.',
    'pos_selling.s1.heading': 'Variants and selling units',
    'pos_selling.s1.p1':
        'If a product has a single variant it is selected automatically. '
        'With several variants, a picker asks which one you want.',
    'pos_selling.s1.p2':
        'When a product has selling units (for example the piece and the '
        'box), a picker asks you to choose; the base unit is always offered '
        'first.',
    'pos_selling.s2.heading': 'Changing quantities',
    'pos_selling.s2.step1':
        'Use the plus and minus buttons on the cart line; the quantity can '
        'never go below one.',
    'pos_selling.s2.step2':
        'Type a number in the quantity field and press Enter to apply it.',
    'pos_selling.s2.step3':
        'Press the star key (*) to open a small dialog and enter the exact '
        'quantity, including expressions like 10*24.',
    'pos_selling.s2.tip1':
        'After adding a product, the new line\u2019s quantity field is '
        'focused so you can adjust it right away.',

    'pos_pricing.title': 'Prices, wholesale and discounts',
    'pos_pricing.summary': 'How retail, wholesale, promotions and discounts '
        'interact on a line.',
    'pos_pricing.s1.heading': 'Automatic pricing',
    'pos_pricing.s1.p1':
        'Lines start at the product\u2019s retail price. When the quantity '
        'reaches the wholesale threshold, the line switches to the '
        'wholesale price and shows a small wholesale label.',
    'pos_pricing.s1.p2':
        'A promotion is applied automatically when it qualifies, and the '
        'line shows a promotion label with the original price struck '
        'through.',
    'pos_pricing.s1.warn1':
        'Wholesale pricing applies to the base unit at or above the '
        'threshold. Custom selling units, pack lines and lines with an '
        'explicit price are never switched to wholesale or promo '
        'automatically.',
    'pos_pricing.s2.heading': 'Discounts you control',
    'pos_pricing.s2.p1':
        'Each line has a discount field for reducing that line only.',
    'pos_pricing.s2.p2':
        'The invoice discount button (or F7) applies to the whole cart. It '
        'requires the discount permission, and the amount cannot exceed the '
        'subtotal.',
    'pos_pricing.s3.heading': 'The totals panel',
    'pos_pricing.s3.p1':
        'The totals panel always shows the subtotal, the discounts applied '
        'and the final total in the store currency.',

    'pos_payment.title': 'Completing a sale',
    'pos_payment.summary': 'Payment methods, confirmation and safety.',
    'pos_payment.s1.heading': 'Opening payment',
    'pos_payment.s1.p1':
        'Press the PAY button or the SPACE key to open the payment dialog. '
        'With an empty cart you get a friendly hint instead.',
    'pos_payment.s2.heading': 'Payment methods',
    'pos_payment.s2.step1':
        'Cash — enter the amount received; the change is calculated for '
        'you.',
    'pos_payment.s2.step2': 'Card — confirm the total as paid by card.',
    'pos_payment.s2.step3':
        'Partial — pay part now and leave a balance on the customer\u2019s '
        'debt. Requires a selected customer and the credit-sale permission.',
    'pos_payment.s2.step4':
        'Credit — put the full amount on the customer\u2019s debt. Also '
        'requires a customer and the credit-sale permission.',
    'pos_payment.s3.heading': 'Safety and confirmation',
    'pos_payment.s3.p1':
        'If checkout fails, your cart is kept exactly as it was so you can '
        'retry safely.',
    'pos_payment.s3.p2':
        'A customer credit cannot exceed their configured debt ceiling; a '
        'rejection explains the amounts involved.',
    'pos_payment.s3.p3':
        'On success a message shows the invoice number and the cart is '
        'cleared for the next customer.',

    'pos_printing.title': 'Printing receipts',
    'pos_printing.summary': 'Automatic printing after a sale and reprints.',
    'pos_printing.s1.heading': 'Print settings',
    'pos_printing.s1.p1':
        'Store settings control printing: the default paper (80 mm roll, '
        'A4 or roll), whether to ask before printing, and whether to print '
        'automatically after each sale.',
    'pos_printing.s2.heading': 'After a sale',
    'pos_printing.s2.p1':
        'If automatic printing is on, the receipt is printed right after '
        'checkout. If the ask option is on, a small dialog asks you to '
        'confirm. With both options off, nothing is printed automatically.',
    'pos_printing.s2.warn1':
        'A printing problem never fails the sale — the sale stays '
        'completed and an error message is shown.',
    'pos_printing.s3.heading': 'Printing again later',
    'pos_printing.s3.p1':
        'Open the sales history (F11), select the sale, then use Print or '
        'Reprint. A preview lets you pick the paper, save the PDF, or send '
        'it to the system printer.',

    'pos_history.title': 'Sales history and sale details',
    'pos_history.summary': 'Review past sales, copy invoices, reprint.',
    'pos_history.s1.heading': 'Opening the history',
    'pos_history.s1.p1':
        'Press F11 or the history button on the POS. The dialog lists the '
        'most recent sales, fifty per page, with a refresh button and a '
        'previous-page button for older pages.',
    'pos_history.s1.warn1':
        'The history is a recency list — it has no date filter or invoice '
        'search in this version.',
    'pos_history.s2.heading': 'Sale details',
    'pos_history.s2.p1':
        'Selecting a row opens the full sale: invoice number, date and '
        'status, every line with its quantity and price, the totals, the '
        'payment method and the customer when one is linked.',
    'pos_history.s3.heading': 'Actions on a sale',
    'pos_history.s3.step1': 'Copy the invoice number to the clipboard.',
    'pos_history.s3.step2': 'Reprint or print the receipt.',
    'pos_history.s3.step3':
        'Create a return for the sale (requires the return permission).',
    'pos_history.s3.step4':
        'Void the sale with a mandatory reason (requires the void '
        'permission).',

    'pos_shortcuts.title': 'Keyboard shortcuts',
    'pos_shortcuts.summary': 'The full verified shortcut list.',
    'pos_shortcuts.s1.heading': 'Global shortcuts',
    'pos_shortcuts.s1.step1': 'F1 — open the Point of Sale.',
    'pos_shortcuts.s1.step2': 'F2 — open Products.',
    'pos_shortcuts.s1.step3':
        'F3 or Ctrl+N — add a product (needs the create permission).',
    'pos_shortcuts.s1.step4': 'F4 or Ctrl+F — focus the search field.',
    'pos_shortcuts.s1.step5': 'F5 — refresh the current list, never the cart.',
    'pos_shortcuts.s1.step6':
        'Escape — close a dialog, or clear the search field.',
    'pos_shortcuts.s2.heading': 'Point of Sale shortcuts',
    'pos_shortcuts.s2.step1': 'Enter — add the scanned or searched product.',
    'pos_shortcuts.s2.step2': 'F6 — choose the customer.',
    'pos_shortcuts.s2.step3': 'F7 — invoice discount.',
    'pos_shortcuts.s2.step4': 'SPACE — open payment.',
    'pos_shortcuts.s2.step5': 'F9 — hold the current sale.',
    'pos_shortcuts.s2.step6': 'F10 — open held sales.',
    'pos_shortcuts.s2.step7': 'F11 — open sales history.',
    'pos_shortcuts.s2.step8': 'F12 — clear the cart (with confirmation).',
    'pos_shortcuts.s2.step9':
        'Plus / minus / star — add one, remove one, or enter a quantity.',
    'pos_shortcuts.s2.tip1':
        'The same list is available any time from the question-mark button '
        'in the top bar.',

    'pos_returns.title': 'Return mode',
    'pos_returns.summary': 'Register a return for the items currently in '
        'the cart.',
    'pos_returns.s1.heading': 'Entering return mode',
    'pos_returns.s1.p1':
        'With items in the cart, a Return button appears if your account '
        'has the return permission. It switches the cart into return mode, '
        'shown by a banner — the lines themselves are not changed.',
    'pos_returns.s2.heading': 'Confirming the return',
    'pos_returns.s2.p1':
        'In return mode the payment button becomes "Confirm return" and '
        'SPACE confirms instead of opening payment. Holding a sale is '
        'disabled while returning.',
    'pos_returns.s2.step1':
        'Adjust the quantities you are returning, if needed.',
    'pos_returns.s2.step2': 'Press Confirm return and review the result.',
    'pos_returns.s2.warn1':
        'A cart line that contains a pack anywhere blocks the whole '
        'return — pack returns are not supported from this screen.',
    'pos_returns.s3.heading': 'What happens next',
    'pos_returns.s3.p1':
        'The return is sent once, safely: if the server does not confirm, '
        'the cart and mode are kept so you can retry. On success a message '
        'shows the refunded total.',

    // ------------------------------------------------------------------
    // Chapter 4 — Products and Catalog
    // ------------------------------------------------------------------
    'chapter.products.title': 'Products and Catalog',
    'cat_basics.title': 'Creating and editing products',
    'cat_basics.summary':
        'Add products, organize them in categories, and find them fast.',
    'cat_basics.s1.heading': 'Creating a product',
    'cat_basics.s1.p1':
        'Open Products (F2) and use the add button. A product needs at '
        'least a name and a price; barcode, SKU, category, unit, '
        'low-stock threshold, VAT rate, description and expiry date are '
        'optional.',
    'cat_basics.s1.step1':
        'Enter the name, then the selling price. The cost field (and the '
        'live profit/margin row) requires the product-update permission.',
    'cat_basics.s1.step2':
        'Scan or type a barcode if you use one — barcode scanners work '
        'keyboard-style anywhere in the form.',
    'cat_basics.s1.step3':
        'Pick a category, or open Manage categories to create one first.',
    'cat_basics.s1.step4':
        'Set the low-stock threshold (default 5) so low stock is flagged '
        'on the dashboard and stock screen.',
    'cat_basics.s2.heading': 'Editing and quantity',
    'cat_basics.s2.p1':
        'Edit reopens the same form. On an existing product the quantity '
        'field is read-only unless you also have the adjust-stock '
        'permission; changing it then records a stock adjustment with the '
        'reason "Product stock update".',
    'cat_basics.s2.p2':
        'Products are never hard-deleted. The archive action hides a '
        'product from the POS and the active list while keeping its '
        'history; archived products stay visible under the Archived '
        'filter.',
    'cat_basics.s3.heading': 'Searching and filtering',
    'cat_basics.s3.p1':
        'The toolbar searches by name, barcode or SKU as you type. '
        'Filters cover status (active / archived / all) and category, '
        'plus sorting by name, price or quantity. Pages of 20 to 100 '
        'rows are available.',
    'cat_basics.s3.tip1':
        'Select rows and use Print labels to print price labels for the '
        'chosen products.',

    'cat_children.title': 'Selling units, purchase units, and variants',
    'cat_children.summary':
        'Sell the same product by the piece, the box, or per variant.',
    'cat_children.s1.heading': 'Selling units',
    'cat_children.s1.p1':
        'A selling unit lets one product be sold in another presentation, '
        'for example the piece and the box. Each unit has a name, a type '
        '(piece, kg, liter…), a multiplier and its own selling price.',
    'cat_children.s1.step1':
        'Open Manage selling units from the product form.',
    'cat_children.s1.step2':
        'Exactly one unit must be the base unit with multiplier 1; it is '
        'always offered first at the POS.',
    'cat_children.s1.step3':
        'Leave a unit\u2019s price empty to inherit the product price, or '
        'set a specific price per unit.',
    'cat_children.s1.warn1':
        'Wholesale pricing never applies to custom selling units — only '
        'to the base unit.',
    'cat_children.s2.heading': 'Purchase units',
    'cat_children.s2.p1':
        'Purchase units describe how you buy the product (for example a '
        'carton of 24). They carry a multiplier and an optional default '
        'flag, but no selling price — cost lives on purchase documents.',
    'cat_children.s3.heading': 'Variants',
    'cat_children.s3.p1':
        'Variants are named versions of one product (size, colour…). Each '
        'variant has its own barcode, stock and optional price and cost '
        'overrides; a single-variant product is selected automatically at '
        'the POS.',
    'cat_children.s3.p2':
        'Variants and units are archived, never deleted, and the sole '
        'base selling unit cannot be removed.',

    'cat_pricing.title': 'Wholesale pricing and promotions',
    'cat_pricing.summary':
        'Volume pricing on the base unit, and store-wide promotions.',
    'cat_pricing.s1.heading': 'Wholesale price',
    'cat_pricing.s1.p1':
        'On the product form, the Wholesale section takes a wholesale '
        'price and a minimum quantity. Both must be filled together (or '
        'both left empty).',
    'cat_pricing.s1.p2':
        'At the POS, once the base-unit quantity reaches the minimum, the '
        'line switches to the wholesale price and shows a wholesale '
        'label. The threshold counts base units.',
    'cat_pricing.s2.heading': 'Promotions',
    'cat_pricing.s2.p1':
        'The Promotions screen creates percentage or fixed-price '
        'promotions on a chosen set of products. Promotions can be '
        'toggled active without deleting them.',
    'cat_pricing.s2.p2':
        'An active promotion is applied automatically at the POS when the '
        'line uses the retail price and the base unit. Lines with a '
        'custom unit, an explicit price, or a pack are never promoted '
        'automatically.',
    'cat_pricing.s2.warn1':
        'Promotions have no start or end dates in this version — they '
        'apply while active.',

    // ------------------------------------------------------------------
    // Chapter 5 — Inventory and Stock
    // ------------------------------------------------------------------
    'chapter.inventory.title': 'Inventory and Stock',
    'inv_levels.title': 'Stock levels and statuses',
    'inv_levels.summary':
        'See what is in stock, what is low, and what is out.',
    'inv_levels.s1.heading': 'The stock screen',
    'inv_levels.s1.p1':
        'The Inventory screen lists every product with its quantity, '
        'average cost, stock value and status. Summary cards show the '
        'total stock value, product count, and the number of low and out '
        'of stock products.',
    'inv_levels.s1.p2':
        'A product is Out of stock at quantity 0 or less, and Low stock '
        'at or below its low-stock threshold. Search, a status filter '
        'and a low-stock-only switch narrow the list.',
    'inv_levels.s2.heading': 'Product detail',
    'inv_levels.s2.p1':
        'Selecting a product opens its detail panel: current quantity, '
        'average cost (PMP), stock value, variants, purchase units, and '
        'the last few movements.',
    'inv_levels.s2.tip1':
        'The same threshold set on the product drives the dashboard '
        '"Low stock" card and this screen\u2019s statuses.',

    'inv_adjust.title': 'Stock adjustments',
    'inv_adjust.summary':
        'Correct stock by hand with an audited reason.',
    'inv_adjust.s1.heading': 'Making an adjustment',
    'inv_adjust.s1.step1':
        'Open Inventory, find the product and press Adjust (requires the '
        'adjust-stock permission).',
    'inv_adjust.s1.step2':
        'Choose the operation: Increase, Decrease, or Set to an exact '
        'quantity.',
    'inv_adjust.s1.step3':
        'Enter the quantity. Decrease and Set require a reason; Increase '
        'records a default reason if you leave it blank.',
    'inv_adjust.s1.step4':
        'Optionally add a unit cost — it updates the average cost (PMP) '
        'when increasing into stock — then confirm. The new quantity is '
        'previewed before you commit.',
    'inv_adjust.s2.heading': 'Rules and restrictions',
    'inv_adjust.s2.p1':
        'Adjustments are in the product\u2019s base unit only. Stock '
        'cannot go negative unless the product allows it. Decreases never '
        'change the average cost.',
    'inv_adjust.s2.p2':
        'Every adjustment writes an immutable movement to the journal, '
        'with who performed it, when, and why.',
    'inv_adjust.s2.warn1':
        'Creating a product with an initial quantity also records a '
        'movement, so new products never appear "out of nowhere".',

    'inv_movements.title': 'Movement history and diagnosis',
    'inv_movements.summary':
        'Trace every change: sales, purchases, returns, adjustments.',
    'inv_movements.s1.heading': 'The movement journal',
    'inv_movements.s1.p1':
        'The Movement history tab lists every stock change across the '
        'store, newest first. Filter by type: sale, purchase, return, '
        'adjustment, package receive and package break.',
    'inv_movements.s1.p2':
        'Each row shows the signed quantity change, the unit cost, the '
        'average cost after the change, the reason, the user, the device '
        'and the source document when there is one.',
    'inv_movements.s2.heading': 'Diagnosing a discrepancy',
    'inv_movements.s2.step1':
        'Open the product\u2019s movements (the detail panel or the '
        'journal filtered to that product).',
    'inv_movements.s2.step2':
        'Match each recent change to a known event: a sale, a received '
        'purchase, a return, or a manual adjustment.',
    'inv_movements.s2.step3':
        'If something is wrong, correct it with an adjustment and a clear '
        'reason — the journal keeps both the error and the correction.',
    'inv_movements.s2.tip1':
        'Voided sales appear as their own movement type, so a void '
        'always restores stock visibly.',

    // ------------------------------------------------------------------
    // Chapter 6 — Purchasing and Suppliers
    // ------------------------------------------------------------------
    'chapter.purchasing.title': 'Purchasing and Suppliers',
    'purch_suppliers.title': 'Managing suppliers',
    'purch_suppliers.summary':
        'Supplier records, balances, and payments.',
    'purch_suppliers.s1.heading': 'Supplier records',
    'purch_suppliers.s1.p1':
        'The Suppliers screen stores each supplier\u2019s name, phone, '
        'address, email, contact person and notes. The balance shown is '
        'read-only — it is calculated from purchases and payments, never '
        'typed in.',
    'purch_suppliers.s2.heading': 'Payments and balance',
    'purch_suppliers.s2.p1':
        'Receiving a purchase increases the supplier balance by whatever '
        'was not paid at receipt. Recording a payment decreases it; you '
        'cannot pay more than the current balance.',
    'purch_suppliers.s2.p2':
        'The supplier ledger lists every purchase invoice, payment and '
        'cancellation in order.',
    'purch_suppliers.s2.warn1':
        'A supplier cannot be archived while a balance remains — settle '
        'or cancel first.',
    'purch_suppliers.s3.heading': 'Permissions',
    'purch_suppliers.s3.p1':
        'Viewing suppliers needs the supplier-view permission; creating, '
        'editing and archiving need supplier-manage.',

    'purch_docs.title': 'Purchase documents and receiving',
    'purch_docs.summary':
        'Draft a purchase, receive it into stock, and reverse it safely.',
    'purch_docs.s1.heading': 'Creating a purchase',
    'purch_docs.s1.step1':
        'Open Purchases and create a document: choose the supplier, then '
        'add product lines with a quantity and a unit cost.',
    'purch_docs.s1.step2':
        'Lines can use a purchase unit (for example a carton of 24); the '
        'quantity is then in whole packages, and the base equivalent is '
        'shown.',
    'purch_docs.s1.step3':
        'Save as draft to keep editing, or Save and receive to finish in '
        'one step.',
    'purch_docs.s4.heading': 'Unit cost or total cost',
    'purch_docs.s4.p1':
        'Each line stores the cost per purchase unit. By default the '
        'amount you type is that per-unit cost. Switch on "Total cost" '
        'when the supplier quotes one amount for the whole line: the app '
        'divides it by the entered quantity and shows the derived unit '
        'cost before you save.',
    'purch_docs.s4.p2':
        'Boxes are converted as usual. Example: 10 boxes of 5 pieces '
        'with a total cost of 100 DA → 10 DA per box, 2 DA per piece; '
        'receiving adds 50 pieces to stock and values them at 2 DA per '
        'piece. With "Total cost" off, 100 DA stays the price per box '
        '(20 DA per piece).',
    'purch_docs.s4.tip1':
        'The line preview (total quantity, unit cost, line total) '
        'updates live while you type; it is a calculation preview only '
        '— nothing is saved or added to stock until the purchase is '
        'saved (and received).',
    'purch_docs.s2.heading': 'What receiving does',
    'purch_docs.s2.p1':
        'Receiving is one atomic action: stock quantities increase, the '
        'average cost is updated, the supplier balance grows by the '
        'unpaid amount, and the document becomes received.',
    'purch_docs.s2.p2':
        'The purchase date is set by the server when the document is '
        'created — it cannot be backdated.',
    'purch_docs.s3.heading': 'Cancelling and deleting',
    'purch_docs.s3.p1':
        'Cancelling a received purchase reverses its stock and balance '
        'effects. Only drafts can be deleted. Received and cancelled '
        'documents are otherwise immutable.',
    'purch_docs.s3.warn1':
        'There are no purchase returns and no tax on purchase documents '
        'in this version — cancel and re-enter if something is wrong.',

    // ------------------------------------------------------------------
    // Chapter 7 — Customers, Credit Sales, and Debts
    // ------------------------------------------------------------------
    'chapter.customers.title': 'Customers, Credit Sales, and Debts',
    'cust_records.title': 'Customer records',
    'cust_records.summary':
        'Names, contact details, debt ceilings, and balances.',
    'cust_records.s1.heading': 'Customer fields',
    'cust_records.s1.p1':
        'A customer has a name (required), phone, address and an '
        'optional debt ceiling. The balance is read-only and maintained '
        'by sales and payments.',
    'cust_records.s2.heading': 'Debt ceiling',
    'cust_records.s2.p1':
        'The debt ceiling is the maximum total debt a customer may hold. '
        'A ceiling of 0 means unlimited. The server enforces it: a credit '
        'or partial sale that would exceed the ceiling is rejected with '
        'an explanation.',
    'cust_records.s2.warn1':
        'A customer with an outstanding balance cannot be archived.',
    'cust_records.s3.heading': 'Permissions',
    'cust_records.s3.p1':
        'The Customers screen needs customer-view; creating, editing and '
        'archiving need customer-manage.',

    'cust_debts.title': 'Credit sales and debt payments',
    'cust_debts.summary':
        'Sell on credit at the POS, then collect and track payments.',
    'cust_debts.s1.heading': 'Making a credit sale',
    'cust_debts.s1.p1':
        'At the POS, choose the customer (F6), open payment, and select '
        'Partial (pay part now, rest on debt) or Credit (full amount on '
        'debt). Both require the credit-sale permission and a selected '
        'customer.',
    'cust_debts.s1.p2':
        'If the amount would push the customer past their debt ceiling, '
        'the sale is rejected before anything is saved.',
    'cust_debts.s2.heading': 'Recording payments',
    'cust_debts.s2.p1':
        'The Debts screen lists customers with outstanding balances and '
        'summary totals. From a customer you can record a payment; you '
        'cannot pay more than the balance, and each payment is '
        'idempotent.',
    'cust_debts.s2.p2':
        'Each customer\u2019s debt history lists every sale that created '
        'debt and every payment that reduced it.',
    'cust_debts.s3.heading': 'Limitations',
    'cust_debts.s3.p1':
        'There are no printed customer statements and no automatic '
        'payment reminders in this version. Use the per-customer debt '
        'history as the account record.',

    // ------------------------------------------------------------------
    // Chapter 8 — Loyalty (Loyalty Phase F)
    // ------------------------------------------------------------------
    'chapter.loyalty.title': 'Loyalty',
    'loy_overview.title': 'Points and cashback overview',
    'loy_overview.summary':
        'How customers earn and spend loyalty rewards.',
    'loy_overview.s1.heading': 'What loyalty does',
    'loy_overview.s1.p1':
        'The loyalty program lets customers earn points and/or cashback '
        'on their purchases, then spend those rewards on later sales. '
        'Points are earned per currency unit spent according to '
        'the store\u2019s points rate; cashback accrues as a monetary '
        'balance at the store\u2019s cashback rate. Every 100 points '
        'unlock one reward, and a reward gives a percent discount on a '
        'sale — points themselves are never money.',
    'loy_overview.s1.p2':
        'Each customer has one loyalty account holding both balances. '
        'Accounts are per-customer (identified by phone at the POS), '
        'and balances — including how many whole rewards they unlock '
        '— are always computed by the server: no screen stores or '
        'recalculates them.',
    'loy_overview.s2.heading': 'Permissions',
    'loy_overview.s2.p1':
        'Earning and using rewards happen inside the normal sale flow, '
        'so they follow the sale permissions. Viewing a customer\u2019s '
        'balance or history needs customer view; changing the loyalty '
        'rules needs the loyalty-settings permission.',

    'loy_settings.title': 'Loyalty settings',
    'loy_settings.summary':
        'Enable earning, set rates, and set the maximum reward '
        'discount.',
    'loy_settings.s1.heading': 'Configuring the rules',
    'loy_settings.s1.p1':
        'Loyalty is configured once for the whole store from the '
        'loyalty settings screen. Both rewards can be enabled '
        'independently, and either can be turned off at any time.',
    'loy_settings.s1.step1':
        'Enable points, cashback, or both, and set their rates.',
    'loy_settings.s1.step2':
        'Set the maximum reward discount — the highest percent a '
        'single reward may take off a sale (0 to 100).',
    'loy_settings.s1.step3':
        'Optionally enable earning on debt settlement, so a customer '
        'earns when paying off a credit balance.',
    'loy_settings.s2.heading': 'Reward discount limit',
    'loy_settings.s2.p1':
        'One limit controls reward redemption: the maximum percent of '
        'a sale\u2019s amount a single reward may discount. It ranges '
        'from 0 to 100; setting it to 0 parks reward redemption while '
        'customers keep earning.',
    'loy_settings.s2.warn1':
        'Rate changes apply to future sales only. Balances already '
        'earned keep their original value.',

    'loy_earning.title': 'Earning rewards',
    'loy_earning.summary':
        'Points and cashback accrue on sales and debt settlements.',
    'loy_earning.s1.heading': 'On sales',
    'loy_earning.s1.p1':
        'When a customer is selected at the POS, a completed sale '
        'credits points and/or cashback based on the amounts actually '
        'paid. Voided sales never earn; a full return of a sale also '
        'reverses what that sale earned, so rewards always match the '
        'net sales actually kept.',
    'loy_earning.s2.heading': 'On debt settlement',
    'loy_earning.s2.p1':
        'When the earn-on-debt-settlement option is on, recording a '
        'debt payment also earns points and cashback on the amount '
        'actually applied to the debt — so paying later still rewards '
        'the customer fairly.',

    'loy_redeem.title': 'Using rewards',
    'loy_redeem.summary':
        'Turn 100 points into a percent discount at the POS.',
    'loy_redeem.s1.heading': 'Using a reward at the POS',
    'loy_redeem.s1.step1':
        'Select the customer (F6) before or during the sale.',
    'loy_redeem.s1.step2':
        'At payment, pick a reward percent from the loyalty selector: '
        'it only offers percents up to the store\u2019s configured '
        'maximum, and it appears only when the customer holds at '
        'least one reward (100 points). The preview shows the exact '
        'discount and the amount left to pay.',
    'loy_redeem.s1.step3':
        'Confirm — the server applies the discount to the sale, '
        'consumes exactly 100 points for that reward, and the '
        'amount due drops accordingly.',
    'loy_redeem.s1.p1':
        'The client only ever sends the selected percent. The server '
        'checks that the customer holds a reward, that the percent is '
        'within the configured maximum, recomputes the discount from '
        'the sale itself, and re-validates everything at checkout — '
        'so nothing sent from the screen can claim a larger discount '
        'or spend points the customer does not have.',
    'loy_redeem.s2.heading': 'Returns and voids',
    'loy_redeem.s2.warn1':
        'Returning items from a sale that used a reward restores the '
        'matching share of the reward discount and the matching '
        'points; voiding such a sale restores the full reward '
        'discount and its 100 points. Points come back only up to '
        'what the customer still holds — a shortfall can remain if '
        'they were spent in the meantime.',

    'loy_report.title': 'The loyalty report',
    'loy_report.summary':
        'Period activity, current balances, and the full reward ledger.',
    'loy_report.s1.heading': 'Overview',
    'loy_report.s1.p1':
        'The Loyalty tab in Reports answers two questions for any '
        'period: what rewards moved during that period, and what the '
        'store currently owes its customers. It shows sales context '
        'beside the reward figures so the two can be read together.',
    'loy_report.s2.heading': 'Report sections',
    'loy_report.s2.p1':
        'The report has four areas: sales context (gross sales and '
        'invoices, same figures as the financial report), period '
        'activity (points and cashback earned, reward discounts '
        'applied, reversed, restored, and unrecovered shortfalls), '
        'current balances (outstanding points and cashback, plus how '
        'many customers hold a balance), and the event ledger — a '
        'paginated, customer-by-customer history of every reward '
        'movement.',
    'loy_report.s2.warn1':
        'Balances are current totals, not period figures: they '
        'reflect every account as it stands now, regardless of the '
        'selected date range.',
    'loy_report.s3.heading': 'Access and export',
    'loy_report.s3.p1':
        'Viewing the loyalty report needs the financial-reports '
        'permission — the same scope as every other report tab. The '
        'shared period and device filters apply, and the report '
        'exports through the same CSV / XLSX / PDF flows as the other '
        'report tabs.',

    // ------------------------------------------------------------------
    // Chapter 9 — Expenses and Financial Operations
    // ------------------------------------------------------------------
    'chapter.expenses.title': 'Expenses and Financial Operations',
    'exp_manage.title': 'Recording and cancelling expenses',
    'exp_manage.summary':
        'Track store expenses; corrections are cancel-and-recreate.',
    'exp_manage.s1.heading': 'Recording an expense',
    'exp_manage.s1.step1':
        'Open Expenses and add an expense: category, amount, an optional '
        'title and note.',
    'exp_manage.s1.step2':
        'The paid-from-drawer switch classifies the expense as paid from '
        'the cash drawer or externally; it is a label, not a cash '
        'movement.',
    'exp_manage.s1.step3':
        'Categories are a fixed list: rent, utilities, salary, '
        'maintenance, supplies, transport, other.',
    'exp_manage.s2.heading': 'Corrections',
    'exp_manage.s2.p1':
        'Expenses cannot be edited or deleted. To correct one, cancel it '
        'with a required reason, then create a new correct expense. '
        'Cancelled rows stay in the list with their reason and who '
        'cancelled them.',
    'exp_manage.s3.heading': 'In reports',
    'exp_manage.s3.p1':
        'Expenses feed the dashboard\u2019s "Today expenses" card and the '
        'financial report, where they reduce net profit and are split '
        'between drawer and external. Viewing either requires the '
        'financial-reports permission.',
    'exp_manage.s3.warn1':
        'The expense date is set by the server and cannot be backdated.',

    // ------------------------------------------------------------------
    // Chapter 10 — Facturation
    // ------------------------------------------------------------------
    'chapter.facturation.title': 'Facturation',
    'fac_types.title': 'Document types and creation',
    'fac_types.summary':
        'FAC, DEV, PRO, BC and BL documents: what they are and how to '
        'create one.',
    'fac_types.s1.heading': 'The five document types',
    'fac_types.s1.step1':
        'FAC — customer invoice (facture).',
    'fac_types.s1.step2': 'DEV — credit note (avoir).',
    'fac_types.s1.step3': 'PRO — quote (devis).',
    'fac_types.s1.step4': 'BC — purchase order (bon de commande).',
    'fac_types.s1.step5': 'BL — delivery note (bon de livraison).',
    'fac_types.s2.heading': 'Creating a document',
    'fac_types.s2.p1':
        'Open Facturation, choose the type, then select a client. Every '
        'document needs a client. Add lines: product-linked lines '
        'pre-fill price and VAT from the product; free-text lines need a '
        'description, a price and a VAT rate.',
    'fac_types.s2.p2':
        'Numbering is automatic per type and year, for example '
        'FAC-2026-0004. Numbers never change.',
    'fac_types.s2.tip1':
        'Invoices can also be created from invoice clients — a dedicated '
        'list separate from POS customers.',

    'fac_totals.title': 'VAT, stamp duty, and totals',
    'fac_totals.summary':
        'How net, VAT, total and timbre are calculated on a document.',
    'fac_totals.s1.heading': 'VAT (TVA)',
    'fac_totals.s1.p1':
        'Each line carries a VAT rate of 0%, 9% or 19%. The server '
        'computes the document totals from the raw line amounts — never '
        'trust a hand-typed total.',
    'fac_totals.s2.heading': 'Stamp duty (timbre fiscal)',
    'fac_totals.s2.p1':
        'On cash invoices (FAC paid in cash) a stamp duty can be applied '
        'with the timbre switch: 0 up to 300 DA total, then a percentage '
        'that rises with the total, with a minimum of 5 DA when it '
        'applies. The amount to pay becomes total plus timbre.',
    'fac_totals.s2.p2':
        'The timbre row appears only when it is switched on and the '
        'amount is above zero. It is not used on POS sales.',
    'fac_totals.s2.warn1':
        'Totals are always recalculated by the server; the preview shows '
        'the authoritative numbers.',

    'fac_pdf_post.title': 'PDF, posting as a sale, and immutability',
    'fac_pdf_post.summary':
        'Preview, PDF export, and registering an invoice as a real sale.',
    'fac_pdf_post.s1.heading': 'Preview and PDF',
    'fac_pdf_post.s1.p1':
        'The invoice form shows a live A4 preview from the server. From '
        'a saved document you can download the same layout as a PDF.',
    'fac_pdf_post.s2.heading': 'Registering as a sale',
    'fac_pdf_post.s2.p1':
        'An FAC can be registered as a real POS-style sale: stock moves, '
        'sales reports update, and the document links to the created '
        'sale. Every line must reference a product or pack — free-text '
        'lines cannot be posted.',
    'fac_pdf_post.s2.p2':
        'Use the Register as sale switch when creating, or post later '
        'from the document. Posting requires facturation-manage (and '
        'sale permission when posting separately) and is idempotent.',
    'fac_pdf_post.s3.heading': 'Immutability',
    'fac_pdf_post.s3.p1':
        'Documents are never deleted. Once posted, the client, payment '
        'and lines are locked; notes and display flags remain editable. '
        'The number, type, year and date never change.',

    // ------------------------------------------------------------------
    // Chapter 11 — Reports and Exports
    // ------------------------------------------------------------------
    'chapter.reports.title': 'Reports and Exports',
    'rep_overview.title': 'The report tabs',
    'rep_overview.summary':
        'Ten report views and what each one answers.',
    'rep_overview.s1.heading': 'The tabs',
    'rep_overview.s1.step1':
        'Financial — profit and loss for the period, with a per-device '
        'breakdown.',
    'rep_overview.s1.step2':
        'Product performance — what sold, quantities, revenue and profit '
        'per product.',
    'rep_overview.s1.step3':
        'Category analysis — sales aggregated by category.',
    'rep_overview.s1.step4': 'Daily and Hourly — timelines of sales.',
    'rep_overview.s1.step5':
        'Peak hours — the busiest hours over a lookback window.',
    'rep_overview.s1.step6':
        'Slow moving — products that have not sold within a chosen '
        'number of days.',
    'rep_overview.s1.step7':
        'Voided invoices — cancelled sales with reasons.',
    'rep_overview.s1.step8':
        'Sales detail — row-level sales with status and payment filters.',
    'rep_overview.s1.step9':
        'Supplier report — what is owed to suppliers.',
    'rep_overview.s2.heading': 'Access',
    'rep_overview.s2.p1':
        'The whole Reports section requires the financial-reports '
        'permission.',

    'rep_exports.title': 'Filters and exports',
    'rep_exports.summary':
        'Date ranges, other filters, and CSV / XLSX / PDF export.',
    'rep_exports.s1.heading': 'Filters',
    'rep_exports.s1.p1':
        'Every tab shares the period presets (today, yesterday, last 7 '
        'days, this month and longer ranges) and custom from/to dates. '
        'Sales detail adds status and payment filters; Peak hours and '
        'Slow moving have their own extra parameters.',
    'rep_exports.s2.heading': 'Exporting',
    'rep_exports.s2.step1':
        'Load the report, then press Export (requires the data-export '
        'permission).',
    'rep_exports.s2.step2':
        'Choose CSV (built on this machine), XLSX or PDF (generated by '
        'the server).',
    'rep_exports.s2.step3':
        'Large exports are capped at 50,000 rows; narrow the period if '
        'the server refuses the request.',
    'rep_exports.s2.tip1':
        'The dashboard\u2019s Reports button opens this section with the '
        'same period already applied.',

    // ------------------------------------------------------------------
    // Chapter 12 — Printing and Receipts
    // ------------------------------------------------------------------
    'chapter.printing.title': 'Printing and Receipts',
    'prt_overview.title': 'Receipts, labels, and document printing',
    'prt_overview.summary':
        'What this application can and cannot send to a printer.',
    'prt_overview.s1.heading': 'Supported printing',
    'prt_overview.s1.p1':
        'Receipts print through the operating system\u2019s print dialog '
        'after a sale (see also the Point of Sale chapter). Papers: '
        '80 mm roll or A4, chosen in store settings or per reprint.',
    'prt_overview.s1.p2':
        'Price labels can be printed from the Products screen for '
        'selected products. Facturation documents are exported as A4 '
        'PDFs.',
    'prt_overview.s2.heading': 'The print workflow',
    'prt_overview.s2.p1':
        'Printing opens the system dialog: pick a printer or "Save as '
        'PDF". Cancelling that dialog never fails the sale — the sale '
        'stays completed.',
    'prt_overview.s3.heading': 'Not supported',
    'prt_overview.s3.p1':
        'Direct ESC/POS printer control, cash-drawer kick, and customer '
        'display hardware are not integrated in this version. Use the '
        'system dialog and a printer that supports your paper size.',
    'prt_overview.s3.warn1':
        'If printing fails with "Printer unavailable", the system '
        'reports no usable printer — check the OS printer setup first.',

    // ------------------------------------------------------------------
    // Chapter 13 — LAN and Multi-PC Setup
    // ------------------------------------------------------------------
    'chapter.lan.title': 'LAN and Multi-PC Setup',
    'lan_pairing.title': 'Pairing and connection',
    'lan_pairing.summary':
        'How a client PC finds the server and stays connected.',
    'lan_pairing.s1.heading': 'Pairing a client',
    'lan_pairing.s1.step1':
        'On the client, the first-run wizard searches the local network '
        'for the server, or you can enter its address manually.',
    'lan_pairing.s1.step2':
        'On the server, an administrator generates a six-digit pairing '
        'code from the Devices screen (valid for ten minutes).',
    'lan_pairing.s1.step3':
        'Enter the code on the client; the request waits until an '
        'administrator approves the device.',
    'lan_pairing.s2.heading': 'Staying connected',
    'lan_pairing.s2.p1':
        'The status chip in the top bar shows Connected, Reconnecting, '
        'Disconnected, or a database warning. Short network blips are '
        'retried automatically with increasing delays; the cashier is '
        'never interrupted by a mid-session outage.',
    'lan_pairing.s2.warn1':
        'A connection problem at startup shows a dialog once: try again, '
        'or enter the server address manually. Sales are never stored '
        'offline — the server must be reachable to complete a sale.',

    'lan_devices.title': 'Device management',
    'lan_devices.summary':
        'Approve, reject, and revoke client devices.',
    'lan_devices.s1.heading': 'The Devices screen',
    'lan_devices.s1.p1':
        'Requires the device-manage permission. The screen shows the '
        'pairing code, the server\u2019s network addresses (tap to copy), '
        'then pending and registered devices.',
    'lan_devices.s1.p2':
        'Each device row shows its identifier, status, last known IP '
        'address, app version and last seen time.',
    'lan_devices.s2.heading': 'Actions',
    'lan_devices.s2.step1':
        'Approve — lets a pending device connect (confirmation required).',
    'lan_devices.s2.step2': 'Reject — refuses a pending device.',
    'lan_devices.s2.step3':
        'Revoke — cuts off an approved device immediately; it must pair '
        'again.',
    'lan_devices.s2.warn1':
        'Never share pairing codes or server addresses outside the '
        'store\u2019s own network.',

    // ------------------------------------------------------------------
    // Chapter 14 — Settings, Backup, and Restore
    // ------------------------------------------------------------------
    'chapter.settings.title': 'Settings, Backup, and Restore',
    'set_general.title': 'Language, theme, and store settings',
    'set_general.summary':
        'Personal preferences and store-wide configuration.',
    'set_general.s1.heading': 'Language and theme',
    'set_general.s1.p1':
        'Settings > Language switches Arabic, French or English for this '
        'machine only. Theme offers dark, light and grey; both choices '
        'are remembered locally.',
    'set_general.s2.heading': 'Store settings',
    'set_general.s2.p1':
        'With the settings-manage permission you can set the store name, '
        'phone and address; the receipt footer; the default paper (80 mm '
        'or A4); ask-before-print and auto-print switches; whether '
        'customers may owe at the POS; and the default low-stock '
        'threshold.',
    'set_general.s3.heading': 'Company information',
    'set_general.s3.p1':
        'The company section stores wilaya, email and the fiscal '
        'identifiers (RC, NIF, AI, NIS) used on documents.',

    'set_backup.title': 'Backup and restore',
    'set_backup.summary':
        'Create server backups and restore them with care.',
    'set_backup.s1.heading': 'Creating a backup',
    'set_backup.s1.p1':
        'With the backup-restore permission, the Settings page lists '
        'server backups and offers Create backup. Backups are SQL dumps '
        'with a manifest, stored on the server\u2019s disk — they are not '
        'downloaded to this PC.',
    'set_backup.s2.heading': 'Restoring',
    'set_backup.s2.p1':
        'Restoring replaces the entire current database with the chosen '
        'backup. A confirmation explains that this cannot be undone. '
        'Each file\u2019s integrity is verified before it is applied.',
    'set_backup.s2.warn1':
        'Create a fresh backup before any restore. Restoring is the '
        'most destructive action in the application.',
    'set_backup.s3.heading': 'If backup tools are missing',
    'set_backup.s3.p1':
        'The server needs its database dump tools installed. If the '
        'application reports that backup tools are missing, ask whoever '
        'maintains the server to install them.',

    // ------------------------------------------------------------------
    // Chapter 15 — Troubleshooting
    // ------------------------------------------------------------------
    'chapter.troubleshooting.title': 'Troubleshooting',
    'ts_connection.title': 'Connection and server issues',
    'ts_connection.summary':
        'What to check when a client cannot reach the server.',
    'ts_connection.s1.heading': 'Client shows Disconnected',
    'ts_connection.s1.step1':
        'Check that the server PC is on and the backend is running.',
    'ts_connection.s1.step2':
        'Check both machines are on the same network and can ping each '
        'other.',
    'ts_connection.s1.step3':
        'Watch the status chip — it reconnects automatically; use the '
        'startup dialog\u2019s manual entry to re-point the client at the '
        'correct server address.',
    'ts_connection.s1.step4':
        'If the chip is green but data fails to load, the server\u2019s '
        'database may be unavailable — the chip shows a database '
        'warning; the server needs attention.',
    'ts_connection.s2.heading': 'Login rejected after a server change',
    'ts_connection.s2.p1':
        'An expired session returns you to the login screen — sign in '
        'again with your PIN. A replaced server requires pairing the '
        'device again.',
    'ts_connection.s2.warn1':
        'Never "fix" a connection by resetting the database or disabling '
        'security. Re-point the client, or ask an administrator to '
        're-approve the device.',

    'ts_print_pdf.title': 'Printing, PDF, and search issues',
    'ts_print_pdf.summary':
        'Receipts not printing, PDFs missing, products not found.',
    'ts_print_pdf.s1.heading': 'Printing problems',
    'ts_print_pdf.s1.step1':
        'A completed sale is never lost to a print failure — reprint '
        'from sales history (F11) instead of re-entering the sale.',
    'ts_print_pdf.s1.step2':
        '"Printer unavailable" means the system has no usable printer — '
        'check the OS printer settings, or use Save as PDF.',
    'ts_print_pdf.s1.step3':
        'No receipt after checkout? Check the ask-before-print and '
        'auto-print switches in store settings.',
    'ts_print_pdf.s2.heading': 'Products not found by barcode',
    'ts_print_pdf.s2.step1':
        'Press Enter once: an exact barcode, name or SKU match is added '
        'directly; otherwise the first search result is added.',
    'ts_print_pdf.s2.step2':
        'Archived products and out-of-stock products are blocked with a '
        'message — check the product\u2019s status on the Products screen.',
    'ts_print_pdf.s2.step3':
        'If the barcode was entered on another device, refresh (F5) so '
        'the catalog is current.',

    'ts_data.title': 'Stock, debt, permission, and layout issues',
    'ts_data.summary':
        'Unexpected numbers, missing buttons, and display questions.',
    'ts_data.s1.heading': 'Stock or debt looks wrong',
    'ts_data.s1.step1':
        'Open the movement journal (stock) or the customer\u2019s debt '
        'history and check each entry against known events.',
    'ts_data.s1.step2':
        'Correct stock with an adjustment and a clear reason; record a '
        'debt payment for over-collected amounts. The history always '
        'keeps both the original and the correction.',
    'ts_data.s2.heading': 'A button or screen is missing',
    'ts_data.s2.p1':
        'Screens and actions follow permissions. If something is '
        'missing, an administrator can grant the matching permission '
        '(for example adjust-stock, credit-sale, or reports). There is '
        'no hidden menu — missing means not permitted for your role.',
    'ts_data.s3.heading': 'Text or layout looks wrong',
    'ts_data.s3.p1':
        'Arabic runs right-to-left throughout; versions, barcodes and '
        'invoice numbers stay left-to-right on purpose. Resize the '
        'window wider if panels feel cramped — the application adapts '
        'from phone-width up to full desktop.',
    'ts_data.s3.tip1':
        'Language and theme changes apply instantly in Settings and only '
        'affect this machine.',
  },

  // -------------------------------------------------------------------------
  // العربية
  // -------------------------------------------------------------------------
  'ar': <String, String>{
    'chapter.getting_started.title': 'البدء',
    'chapter.dashboard.title': 'لوحة التحكم',
    'chapter.pos.title': 'نقطة البيع',

    'gs_first_launch.title': 'الإطلاق الأول وإعداد الشبكة',
    'gs_first_launch.summary': 'اختر نوع الجهاز واربط الأجهزة بالخادم.',
    'gs_first_launch.s1.heading': 'اختر نوع هذا الجهاز',
    'gs_first_launch.s1.p1':
        'في أول تشغيل للتطبيق يظهر معالج إعداد إجباري. يجب اختيار النوع '
        'قبل إمكانية المتابعة.',
    'gs_first_launch.s1.step1':
        'خادم — الجهاز الرئيسي الذي يستضيف قاعدة البيانات. يفتح لوحة '
        'التحكم مباشرة ولا يرتبط بنفسه.',
    'gs_first_launch.s1.step2':
        'عميل — جهاز كاشير أو مكتب خلفي يتصل بالخادم عبر الشبكة المحلية.',
    'gs_first_launch.s1.tip1': 'لا يمكن إغلاق المعالج في أول تشغيل؛ الاختيار إجباري.',
    'gs_first_launch.s2.heading': 'ربط عميل بالخادم',
    'gs_first_launch.s2.step1':
        'على العميل يبحث المعالج عن الخادم تلقائياً في الشبكة المحلية.',
    'gs_first_launch.s2.step2':
        'اختر الخادم المكتشف، أو أدخل عنوانه يدوياً في حال فشل الاكتشاف.',
    'gs_first_launch.s2.step3': 'أدخل رمز الاقتران المعروض على العميل عند طلبه.',
    'gs_first_launch.s2.step4':
        'يوافق مدير النظام على الجهاز الجديد من قسم الأجهزة قبل أن يتمكن '
        'العميل من تسجيل الدخول.',
    'gs_first_launch.s3.heading': 'المتطلبات الأساسية',
    'gs_first_launch.s3.p1':
        'يجب أن تكون جميع الأجهزة على الشبكة المحلية نفسها، وأن يكون جهاز '
        'الخادم يعمل ليتمكن العملاء من الاتصال. ويمكن لاحقاً فتح المعالج من '
        'الإعدادات لإدارة الأجهزة.',
    'gs_first_launch.s3.warn1':
        'لا يمكن استخدام عميل لم يكمل المعالج قط — لا يوجد هوية جهاز بعد.',

    'gs_admin_login.title': 'حساب المدير وتسجيل الدخول',
    'gs_admin_login.summary': 'أنشئ أول مدير ثم سجّل الدخول برمز PIN.',
    'gs_admin_login.s1.heading': 'إنشاء أول مدير',
    'gs_admin_login.s1.p1':
        'بعد خطوة الشبكة يطلب التطبيق إنشاء أول حساب مدير: الاسم الكامل '
        'ورمز PIN، يُدخل مرتين للتأكيد.',
    'gs_admin_login.s1.warn1':
        'لا توجد كلمة مرور افتراضية. اختر رمزك أثناء الإعداد واحتفظ به '
        'سريةً — لا يوفر التطبيق رمزاً مدمجاً.',
    'gs_admin_login.s2.heading': 'تسجيل الدخول',
    'gs_admin_login.s2.p1':
        'شاشة الدخول تعرض المستخدمين الذين أنشأهم المدير. اختر اسمك وأدخل '
        'رمزك على لوحة الأرقام.',
    'gs_admin_login.s2.p2':
        'بعد الدخول تصل إلى لوحة التحكم. يظهر اسمك وصلاحياتك في الشريط '
        'العلوي حيث يمكنك أيضاً تسجيل الخروج.',

    'gs_navigation.title': 'التنقل بين الأقسام الرئيسية',
    'gs_navigation.summary': 'شريط التنقل والشاشات الرئيسية واختصارات لوحة المفاتيح.',
    'gs_navigation.s1.heading': 'شريط التنقل',
    'gs_navigation.s1.p1':
        'يعرض شريط التنقل الجانبي أقسام التطبيق في مجموعات. الأقسام التي '
        'لا تملك صلاحية لها مخفية، فلا يعرض الشريط إلا ما يمكّن حسابك من '
        'استخدامه فعلاً.',
    'gs_navigation.s2.heading': 'الأقسام الرئيسية',
    'gs_navigation.s2.step1': 'لوحة التحكم — نظرة عامة على اليوم والمخزون.',
    'gs_navigation.s2.step2': 'نقطة البيع — تسجيل المبيعات (F1).',
    'gs_navigation.s2.step3': 'المنتجات — إدارة الكتالوج (F2).',
    'gs_navigation.s2.step4':
        'المخزون والمبيعات والعملاء والديون والمشتريات والعروض والطرود '
        'والمصاريف والفوترة والتقارير — حسب صلاحياتك.',
    'gs_navigation.s2.tip1':
        'الاختصارات العامة تعمل في كل مكان: F1 تفتح نقطة البيع، F2 '
        'المنتجات، وF4 ينقل التركيز إلى حقل البحث.',
    'gs_navigation.s3.heading': 'المساعدة والدليل',
    'gs_navigation.s3.p1':
        'زر علامة الاستفهة في الشريط العوي يفتح قائمة الاختصارات. وصفحة '
        'حول التطبيق (مجموعة الإعدادات) تعرض إصدارات التطبيق والخادم وتفتح '
        'مركز التوثيق.',

    'gs_workflow.title': 'سير عمل عملي لأول استخدام',
    'gs_workflow.summary': 'من التثبيت الفارغ إلى أول عملية بيع تجريبية.',
    'gs_workflow.s1.heading': 'ترتيب العمل المقترح',
    'gs_workflow.s1.step1': 'سجّل الدخول بحساب المدير.',
    'gs_workflow.s1.step2':
        'افتح المنتجات وأنشئ عدة منتجات مع الباركود والأسعار.',
    'gs_workflow.s1.step3': 'أنشئ إن أردت الطرود أو العروض الترويجية.',
    'gs_workflow.s1.step4':
        'افتح نقطة البيع (F1) وجرّب عملية بيع نقدية تجريبية.',
    'gs_workflow.s1.step5': 'اطبع أو عاين الإيصال إن كانت الطباعة مضبوطة.',
    'gs_workflow.s1.step6':
        'افتح لوحة التحكم لترى البيعة في أرقام اليوم.',
    'gs_workflow.s1.tip1': 'يمكنك تغيير اللغة والمظهر في أي وقت من الإعدادات.',

    'dash_overview.title': 'ما تعرضه لوحة التحكم',
    'dash_overview.summary': 'الأرقام الرئيسية والمبيعات الحديثة والمنتجات الأكثر مبيعاً.',
    'dash_overview.s1.heading': 'الغرض والوصول',
    'dash_overview.s1.p1':
        'لوحة التحكم هي أول شاشة بعد تسجيل الدخول. تلخص نشاط اليوم ووضع '
        'المخزون وديون العملاء لتساعدك على قرار خطوتك التالية.',
    'dash_overview.s1.p2':
        'تتطلب صلاحية التقارير المالية؛ بدونها تظهر رسالة رفض صلاحية بدل '
        'البيانات.',
    'dash_overview.s2.heading': 'بطاقات الملخص',
    'dash_overview.s2.p1':
        'البطاقات في ثلاث مجموعات. اليوم: المبيعات والفواتير والأرباح '
        'والمصاريف لليوم الحالي. المنتجات والمخزون: عدد المنتجات وقيمة '
        'المخزون والمنتجات منخفضة المخزون. العملاء والديون: عدد العملاء '
        'والمدينون وإجمالي الدين.',
    'dash_overview.s2.tip1':
        'مجموعة اليوم تعرض دائماً أرقام اليوم الحالي مهما كان الفترة المختارة أدناه.',
    'dash_overview.s3.heading': 'المبيعات الحديثة والمنتجات الأعلى',
    'dash_overview.s3.p1':
        'المبيعات الحديثة تعرض آخر المبيعات المكتملة خلال الفترة المختارة '
        'حتى خمس مبيعات: رقم الفاتورة والتاريخ وطريقة الدفع والإجمالي.',
    'dash_overview.s3.p2':
        'المنتجات الأعلى تعرض أفضل خمس منتجات مبيعاً كرسم أعمدة بسيط '
        'وقائمة بالكمية المباعة وصافي المبيعات والربح.',
    'dash_overview.s3.warn1':
        'هذه القوائم ملخصات فقط — افتح المبيعات أو التقارير للسجل الكامل. '
        'الفترات الفارغة تعرض "لا توجد بيانات لهذه الفترة".',

    'dash_controls.title': 'فلاتر الفترة والإجراءات',
    'dash_controls.summary': 'غيّر الفترة وحدّث وافتح التقارير.',
    'dash_controls.s1.heading': 'اختيار الفترة',
    'dash_controls.s1.p1':
        'شريط الفترة يوفر إعدادات جاهزة (اليوم والأمس وآخر 7 أيام وهذا '
        'الشهر وفترات أطول) ومدى مخصص عبر زرَّي التاريخ.',
    'dash_controls.s1.p2':
        'تغيير الفترة يعيد تحميل قوائم المبيعات الحديثة والمنتجات الأعلى '
        'لتواريخها.',
    'dash_controls.s2.heading': 'التحديث والتقارير',
    'dash_controls.s2.step1': 'زر التحديث يعيد تحميل البيانات الحالية دون فقدان اختيارك.',
    'dash_controls.s2.step2':
        'زر التقارير يفتح قسم التقارير الكامل بنفس الفترة — استخدمه للتصدير '
        'والتحليل المفصل.',
    'dash_controls.s2.step3':
        'في حال فشل التحميل يظهر زر إعادة المحاولة؛ تبقى البيانات السابقة '
        'ظاهرة أثناء التحديث.',

    'pos_opening.title': 'فتح نقطة البيع وتخطيطها',
    'pos_opening.summary': 'اعرف الشاشة وحقل البحث وسلة المشتريات.',
    'pos_opening.s1.heading': 'فتح الشاشة',
    'pos_opening.s1.p1':
        'افتح نقطة البيع من شريط التنقل أو اضغط F1 من أي مكان. يحصل حقل '
        'بحث المنتجات على التركيز تلقائياً لتمسح أو تكتب فوراً.',
    'pos_opening.s2.heading': 'ما على الشاشة',
    'pos_opening.s2.step1':
        'حقل البحث في الأعلى: امسح الباركود أو اكتب الاسم ثم اضغط Enter.',
    'pos_opening.s2.step2':
        'الكتالوج أسفله، يبدَّل بين عرض الشبكة والقائمة؛ ويُحفظ اختيارك.',
    'pos_opening.s2.step3':
        'صف المفضلة على النوافذ العريضة، وزر الطرود الذي يفتح منتقي الطرود.',
    'pos_opening.s2.step4':
        'لوحة السلة بالبنود وأدوات الكمية والإجماليات. على النوافذ الضيقة '
        'تصبح السلة لوحة منزلقة.',
    'pos_opening.s3.heading': 'إضافة منتج',
    'pos_opening.s3.p1':
        'اضغط Enter في حقل البحث لإضافة المطابقة الدقيقة للباركود أو الاسم '
        'أو SKU — أو أول نتيجة. وبعد قليل من الكتابة تظهر نتائج يمكنك '
        'النقر عليها.',
    'pos_opening.s3.warn1':
        'لا يمكن إضافة المنتجات المؤرشفة، ويُمنع إضافة المنتجات بلا مخزون '
        'مع رسالة واضحة.',

    'pos_selling.title': 'إضافة المنتجات والكميات',
    'pos_selling.summary': 'الأشكال ووحدات البيع وإدخال الكمية.',
    'pos_selling.s1.heading': 'الأشكال ووحدات البيع',
    'pos_selling.s1.p1':
        'إن كان للمنتج شكل واحد يُختار تلقائياً. ومع عدة أشكال يظهر منتقي '
        'لطلب الشكل المطلوب.',
    'pos_selling.s1.p2':
        'عندما يملك المنتج وحدات بيع (مثلاً القطعة والعلبة) يظهر منتقي '
        'للاختيار؛ الوحدة الأساسية معروضة دائماً أولاً.',
    'pos_selling.s2.heading': 'تغيير الكميات',
    'pos_selling.s2.step1': 'استخدم زري زائد وناقص على بنود السلة؛ لا تقل الكمية عن واحد.',
    'pos_selling.s2.step2': 'اكتب رقماً في حقل الكمية واضغط Enter لتطبيقه.',
    'pos_selling.s2.step3':
        'اضغط مفتاح النجمة (*) لفتح نافذة صغيرة وإدخال الكمية الدقيقة '
        'بما فيها التعبيرات مثل 10*24.',
    'pos_selling.s2.tip1':
        'بعد إضافة منتج يحصل حقل الكمية في السطر الجديد على التركيز '
        'لتعديله فوراً.',

    'pos_pricing.title': 'الأسعار والجملة والخصومات',
    'pos_pricing.summary': 'كيف تتفاعل الأسعار والجملة والعروض والخصومات.',
    'pos_pricing.s1.heading': 'التسعير التلقائي',
    'pos_pricing.s1.p1':
        'تبدأ البنود بسعر التجزئة. وعند بلوغ كمية الجملة يتحول السطر إلى '
        'سعر الجملة ويظهر عليه وسم جملة.',
    'pos_pricing.s1.p2':
        'يُطبق العرض الترويجي تلقائياً عند đủ الشروط، ويظهر وسم ترويجي مع '
        'شطب السعر الأصلي.',
    'pos_pricing.s1.warn1':
        'سعر الجملة يُطبق على الوحدة الأساسية عند بلوغ الحد. وحدات البيع '
        'المخصصة وسطور الطرود والأسطر ذات السعر الصريح لا تتحول تلقائياً '
        'إلى جملة أو عرض.',
    'pos_pricing.s2.heading': 'الخصومات التي تتحكم بها',
    'pos_pricing.s2.p1': 'لكل سطر حقل خصم لتقليل ذلك السطر فقط.',
    'pos_pricing.s2.p2':
        'زر خصم الفاتورة (أو F7) يطبق على السلة كاملة. يتطلب صلاحية الخصم، '
        'ولا يتجاوز المبلغ الإجمالي الفرعي.',
    'pos_pricing.s3.heading': 'لوحة الإجماليات',
    'pos_pricing.s3.p1':
        'تعرض لوحة الإجماليات دائماً الإجمالي الفرعي والخصومات والمجمل النهائي '
        'بعملة المتجر.',

    'pos_payment.title': 'إتمام عملية البيع',
    'pos_payment.summary': 'طرق الدفع والتأكيد وضمان الأمان.',
    'pos_payment.s1.heading': 'فتح الدفع',
    'pos_payment.s1.p1':
        'اضغط زر الدفع أو مفتاح المسافة SPACE لفتح نافذة الدفع. مع سلة '
        'فارغة يظهر تلميح ودّي بدلاً منها.',
    'pos_payment.s2.heading': 'طرق الدفع',
    'pos_payment.s2.step1': 'نقداً — أدخل المبلغ المستلم ويُحسب الباقي لك.',
    'pos_payment.s2.step2': 'بطاقة — أكّد الإجمالي كمدفوع بالبطاقة.',
    'pos_payment.s2.step3':
        'جزئي — ادفع جزءاً الآن واترك الرصيد على دين العميل. يتطلب عميلاً '
        'مختاراً وصلاحية البيع بالائتمان.',
    'pos_payment.s2.step4':
        'آجل — ضع المبلغ كله على دين العميل. يتطلب أيضاً عميلاً وصلاحية '
        'البيع بالائتمان.',
    'pos_payment.s3.heading': 'الأمان والتأكيد',
    'pos_payment.s3.p1':
        'في حال فشل الدفع تبقى سلتك كما هي لتتمكن من إعادة المحاولة بأمان.',
    'pos_payment.s3.p2':
        'لا يمكن أن يتجاوز دين العميل سقف الدين المحدد له؛ ورسالة الرفض '
        'توضح المبالغ.',
    'pos_payment.s3.p3':
        'عند النجاح تظهر رسالة برقم الفاتورة وتُفرَّغ السلة للعميل التالي.',

    'pos_printing.title': 'طباعة الإيصالات',
    'pos_printing.summary': 'الطباعة التلقائية بعد البيع وإعادة الطباعة.',
    'pos_printing.s1.heading': 'إعدادات الطباعة',
    'pos_printing.s1.p1':
        'تتحكم إعدادات المتجر بالطباعة: الورق الافتراضي (لفة 80 مم أو A4 '
        'أو لفة)، والسؤال قبل الطباعة، والطباعة التلقائية بعد كل بيع.',
    'pos_printing.s2.heading': 'بعد البيع',
    'pos_printing.s2.p1':
        'إن كانت الطباعة التلقائية مفعّلة يُطبع الإيصال فوراً بعد الدفع. '
        'وإن كان خيار السؤال مفعّلاً تظهر نافذة صغيرة للتأكيد. وبتعطيل '
        'الخيارين لا تُطبع أي شيء تلقائياً.',
    'pos_printing.s2.warn1':
        'مشكلة الطباعة لا تفشل البيع أبداً — تبقى البيعة مكتملة وتظهر '
        'رسالة خطأ.',
    'pos_printing.s3.heading': 'الطباعة لاحقاً',
    'pos_printing.s3.p1':
        'افتح سجل المبيعات (F11) واختر البيعة ثم استخدم طباعة أو إعادة '
        'الطباعة. تتيح المعاينة اختيار الورق أو حفظ PDF أو الإرسال إلى '
        'طابعة النظام.',

    'pos_history.title': 'سجل المبيعات وتفاصيل البيع',
    'pos_history.summary': 'راجع المبيعات السابقة وانسخ الفواتير وأعد الطباعة.',
    'pos_history.s1.heading': 'فتح السجل',
    'pos_history.s1.p1':
        'اضغط F11 أو زر السجل في نقطة البيع. تعرض النافذة أحدث المبيعات، '
        'خمسين في كل صفحة، مع زر تحديث وزر الصفحة السابقة للمبيعات الأقدم.',
    'pos_history.s1.warn1':
        'السجل قائمة بالأحدث فقط — لا يملك فلتر تاريخ أو بحثاً برقم الفاتورة '
        'في هذه النسخة.',
    'pos_history.s2.heading': 'تفاصيل البيعة',
    'pos_history.s2.p1':
        'اختيار صف يفتح البيعة كاملة: رقم الفاتورة والتاريخ والحالة، وكل '
        'سطر بكميته وسعره، والإجماليات وطريقة الدفع والعميل إن وُجد.',
    'pos_history.s3.heading': 'إجراءات على البيعة',
    'pos_history.s3.step1': 'نسخ رقم الفاتورة إلى الحافظة.',
    'pos_history.s3.step2': 'إعادة طباعة الإيصال أو طباعته.',
    'pos_history.s3.step3': 'إنشاء إرجاع للبيعة (يتطلب صلاحية الإرجاع).',
    'pos_history.s3.step4':
        'إلغاء البيعة بسبب إلزامي (يتطلب صلاحية الإلغاء).',

    'pos_shortcuts.title': 'اختصارات لوحة المفاتيح',
    'pos_shortcuts.summary': 'قائمة الاختصارات الكاملة الموثقة.',
    'pos_shortcuts.s1.heading': 'اختصارات عامة',
    'pos_shortcuts.s1.step1': 'F1 — فتح نقطة البيع.',
    'pos_shortcuts.s1.step2': 'F2 — فتح المنتجات.',
    'pos_shortcuts.s1.step3': 'F3 أو Ctrl+N — إضافة منتج (تتطلب صلاحية الإنشاء).',
    'pos_shortcuts.s1.step4': 'F4 أو Ctrl+F — التركيز على حقل البحث.',
    'pos_shortcuts.s1.step5': 'F5 — تحديث القائمة الحالية، ولا يمس السلة أبداً.',
    'pos_shortcuts.s1.step6': 'Escape — إغلاق نافذة أو مسح حقل البحث.',
    'pos_shortcuts.s2.heading': 'اختصارات نقطة البيع',
    'pos_shortcuts.s2.step1': 'Enter — إضافة المنتج الممسوح أو المُبحث عنه.',
    'pos_shortcuts.s2.step2': 'F6 — اختيار العميل.',
    'pos_shortcuts.s2.step3': 'F7 — خصم الفاتورة.',
    'pos_shortcuts.s2.step4': 'SPACE — فتح الدفع.',
    'pos_shortcuts.s2.step5': 'F9 — تعليق البيعة الحالية.',
    'pos_shortcuts.s2.step6': 'F10 — فتح البيع المعلّق.',
    'pos_shortcuts.s2.step7': 'F11 — فتح سجل المبيعات.',
    'pos_shortcuts.s2.step8': 'F12 — إفراغ السلة (مع تأكيد).',
    'pos_shortcuts.s2.step9': 'زائد / ناقص / نجمة — إضافة أو حذف أو إدخال كمية.',
    'pos_shortcuts.s2.tip1':
        'نفس القائمة متاحة دائماً من زر علامة الاستفهة في الشريط العلوي.',

    'pos_returns.title': 'وضع الإرجاع',
    'pos_returns.summary': 'سجّل إرجاعاً لعناصر السلة الحالية.',
    'pos_returns.s1.heading': 'دخول وضع الإرجاع',
    'pos_returns.s1.p1':
        'مع عناصر في السلة يظهر زر الإرجاع إن كانت صلاحيتك تسمح بها. '
        'يحوّل الزر السلة إلى وضع الإرجاع يظهر بلافتة — دون تغيير البنود.',
    'pos_returns.s2.heading': 'تأكيد الإرجاع',
    'pos_returns.s2.p1':
        'في وضع الإرجاع يصبح زر الدفع "تأكيد الإرجاع" ويفتح SPACE التأكيد '
        'بدلاً من الدفع. تعليق البيع معطّل أثناء الإرجاع.',
    'pos_returns.s2.step1': 'عدّل الكميات المرتجعة عند الحاجة.',
    'pos_returns.s2.step2': 'اضغط تأكيد الإرجاع وراجع النتيجة.',
    'pos_returns.s2.warn1':
        'بند السلة الذي يحتوي طرداً يمنع الإرجاع كاملاً — إرجاع الطرود غير '
        'مدعوم من هذه الشاشة.',
    'pos_returns.s3.heading': 'ما بعد التأكيد',
    'pos_returns.s3.p1':
        'يُرسل الإرجاع مرة واحدة بأمان: إن لم يؤكده الخادم تبقى السلة '
        'والوضع لتكرار المحاولة. وعند النجاح تظهر رسالة بالمبلغ المرتجع.',

    // ------------------------------------------------------------------
    // الفصل 4 — المنتجات والكتالوج
    // ------------------------------------------------------------------
    'chapter.products.title': 'المنتجات والكتالوج',
    'cat_basics.title': 'إنشاء المنتجات وتعديلها',
    'cat_basics.summary':
        'أضف المنتجات، ونظّمها في التصنيفات، واعثر عليها بسرعة.',
    'cat_basics.s1.heading': 'إنشاء منتج',
    'cat_basics.s1.p1':
        'افتح المنتجات (F2) واستخدم زر الإضافة. يحتاج المنتج إلى اسم '
        'وسعر على الأقل؛ الباركود وSKU والتصنيف والوحدة وحدّ المخزون '
        'المنخفض ومعدل الضريبة والوصف وتاريخ الصلاحية اختيارية.',
    'cat_basics.s1.step1':
        'أدخل الاسم ثم سعر البيع. حقل التكلفة (ومربحة/هامش الربح '
        'الحي) يتطلب صلاحية تعديل المنتجات.',
    'cat_basics.s1.step2':
        'امسح أو اكتب الباركود إن وُجد — تعمل قارئات الباركود بأسلوب '
        'لوحة المفاتيح في أي مكان داخل النموذج.',
    'cat_basics.s1.step3':
        'اختر تصنيفاً، أو افتح إدارة التصنيفات لإنشائه أولاً.',
    'cat_basics.s1.step4':
        'اضبط حدّ المخزون المنخفض (الافتراضي 5) ليُعلَّم المخزون '
        'المنخفض على لوحة التحكم وشاشة المخزون.',
    'cat_basics.s2.heading': 'التعديل والكمية',
    'cat_basics.s2.p1':
        'إعادة التعديل تفتح النموذج نفسه. عند وجود منتج موجود، حقل '
        'الكمية للقراءة فقط ما لم تملك أيضاً صلاحية تعديل المخزون؛ '
        'تغييره يسجّل حينها تعديلاً بسبب "تحديث مخزون المنتج".',
    'cat_basics.s2.p2':
        'لا تُحذف المنتجات نهائياً. أرشفة المنتج يُخفيه من نقطة البيع '
        'والقائمة النشطة مع الحفاظ على تاريخه؛ تبقى المنتجات المؤرشفة '
        'ظاهرة تحت فلتر المؤرشفة.',
    'cat_basics.s3.heading': 'البحث والتصفية',
    'cat_basics.s3.p1':
        'شريط الأدوات يبحث بالاسم أو الباركود أو SKU أثناء الكتابة. '
        'تشمل عوامل التصفية الحالة (نشط / مؤرشف / الكل) والتصنيف، مع '
        'ترتيب حسب الاسم أو السعر أو الكمية. صفحات من 20 إلى 100 '
        'صف.',
    'cat_basics.s3.tip1':
        'حدّد الصفوف واستخدم طباعة الملصقات لطباعة ملصقات الأسعار '
        'للمنتجات المختارة.',

    'cat_children.title': 'وحدات البيع ووحدات الشراء والمتغيرات',
    'cat_children.summary':
        'بِع نفس المنتج بالقطعة أو بالصندوق أو حسب المتغير.',
    'cat_children.s1.heading': 'وحدات البيع',
    'cat_children.s1.p1':
        'تسمح وحدة البيع لبيع المنتج نفسه بتقديم آخر، مثل القطعة '
        'والصندوق. لكل وحدة اسم ونوع (قطعة، كغ، لتر…) ومُضاعِف وسعر '
        'بيع خاص بها.',
    'cat_children.s1.step1':
        'افتح إدارة وحدات البيع من نموذج المنتج.',
    'cat_children.s1.step2':
        'يجب أن تكون وحدة واحدة على الأقل هي الوحدة الأساسية '
        'بمُضاعِف 1؛ تُقدَّم دائماً أولاً عند نقطة البيع.',
    'cat_children.s1.step3':
        'اترك سعر وحدة فارغاً ليُورَث سعر المنتج، أو ضبط سعر خاص لكل '
        'وحدة.',
    'cat_children.s1.warn1':
        'التسعير بالجملة لا ينطبق أبداً على وحدات البيع المخصصة — بل '
        'على الوحدة الأساسية فقط.',
    'cat_children.s2.heading': 'وحدات الشراء',
    'cat_children.s2.p1':
        'تصف وحدات الشراء طريقة شراء المنتج (مثلاً كرتونة من 24). '
        'تحمل مُضاعِفاً وخيار افتراضي اختيارياً، لكن ليس لها سعر بيع — '
        'التكلفة تعيش على وثائق المشتريات.',
    'cat_children.s3.heading': 'المتغيرات',
    'cat_children.s3.p1':
        'المتغيرات نسخ مسمّاة من المنتج نفسه (المقاس، اللون…). لكل '
        'متغير باركود ومخزون خاص، وتجاوز اختياري للسعر والتكلفة؛ '
        'المنتج ذو المتغير الواحد يُختار تلقائياً عند نقطة البيع.',
    'cat_children.s3.p2':
        'تُؤرشف المتغيرات والوحدات ولا تُحذف، ولا يمكن حذف وحدة البيع '
        'الأساسية الوحيدة.',

    'cat_pricing.title': 'التسعير بالجملة والعروض الترويجية',
    'cat_pricing.summary':
        'تسعير بالجملة على الوحدة الأساسية، وعروض على مستوى المتجر.',
    'cat_pricing.s1.heading': 'السعر بالجملة',
    'cat_pricing.s1.p1':
        'في نموذج المنتج، يأخذ قسم الجملة سعراً بالجملة وحدّاً '
        'أدنى للكمية. يجب ملء الاثنين معاً (أتركهما فارغين معاً).',
    'cat_pricing.s1.p2':
        'عند نقطة البيع، وبمجرد وصول كمية الوحدة الأساسية إلى الحدّ '
        'الأدنى، يتحوّل السطر إلى السعر بالجملة ويعرض شارة جملة. '
        'الحدّ يُعدّ بالوحدات الأساسية.',
    'cat_pricing.s2.heading': 'العروض الترويجية',
    'cat_pricing.s2.p1':
        'شاشة العروض تنشئ عروضاً بنسبة أو بسعر ثابت على مجموعة '
        'مختارة من المنتجات. يمكن تفعيل العروض وإيقافها دون حذفها.',
    'cat_pricing.s2.p2':
        'يُطبَّق العرض النشط تلقائياً عند نقطة البيع عندما يستخدم '
        'السطر السعر التجزئة والوحدة الأساسية. لا تُطبَّق تلقائياً '
        'السطور بوحدة مخصصة أو سعر صريح أو مُجمَّعة.',
    'cat_pricing.s2.warn1':
        'لا تواريخ بدء أو انتهاء للعروض في هذه النسخة — تُطبَّق ما '
        'دام مفعّلاً.',

    // ------------------------------------------------------------------
    // الفصل 5 — المخزون
    // ------------------------------------------------------------------
    'chapter.inventory.title': 'المخزون والكميات',
    'inv_levels.title': 'مستويات المخزون والحالات',
    'inv_levels.summary':
        'اعرف ما هو في المخزون، وما هو منخفض، وما هو نافد.',
    'inv_levels.s1.heading': 'شاشة المخزون',
    'inv_levels.s1.p1':
        'تعرض شاشة المخزون كل منتج مع كميته ومتوسط تكلفته وقيمة '
        'مخزونه وحالته. تُظهر البطاقات الإجمالي قيمة المخزون وعدد '
        'المنتجات وعدد منخفض ونافد المخزون.',
    'inv_levels.s1.p2':
        'يُعدّ المنتج نافداً عند كمية 0 أو أقل، ومنخفضاً عند حدّ '
        'المخزون المنخفض أو أقل. البحث وفلتر الحالة ومفتاح '
        'المنخفض فقط يضيّق القائمة.',
    'inv_levels.s2.heading': 'تفاصيل المنتج',
    'inv_levels.s2.p1':
        'اختيار منتج يفتح لوحته: الكمية الحالية ومتوسط التكلفة '
        '(PMP) وقيمة المخزون والمتغيرات ووحدات الشراء وآخر الحركات.',
    'inv_levels.s2.tip1':
        'الحدّ المنخفض المضبوط على المنتج نفسه يقود بطاقة '
        '"المخزون المنخفض" وحالات هذه الشاشة.',

    'inv_adjust.title': 'تعديلات المخزون',
    'inv_adjust.summary':
        'صحّح المخزون يدوياً بسبب موثّق.',
    'inv_adjust.s1.heading': 'إجراء تعديل',
    'inv_adjust.s1.step1':
        'افتح المخزون، اعثر على المنتج واضغط تعديل (يتطلب صلاحية '
        'تعديل المخزون).',
    'inv_adjust.s1.step2':
        'اختر العملية: زيادة، إنقاص، أو ضبط على كمية محددة.',
    'inv_adjust.s1.step3':
        'أدخل الكمية. الإنقاص والضبط يتطلبان سبباً؛ الزيادة تسجّل '
        'سبباً افتراضياً إن تركته فارغاً.',
    'inv_adjust.s1.step4':
        'يمكنك اختيارياً إضافة تكلفة وحدة — تحدّث متوسط التكلفة '
        '(PMP) عند الزيادة — ثم أكّد. تُعرض الكمية الجديدة قبل '
        'التنفيذ.',
    'inv_adjust.s2.heading': 'القواعد',
    'inv_adjust.s2.p1':
        'التعديلات بوحدة المنتج الأساسية فقط. لا ينزل المخزون تحت '
        'الصفر إلا إن كان المنتج يسمح. الإنقاص لا يغيّر متوسط '
        'التكلفة أبداً.',
    'inv_adjust.s2.p2':
        'كل تعديل يكتب حركة غير قابلة للتعديل في السجل، مع من نفّذه '
        'ومتى ولماذا.',
    'inv_adjust.s2.warn1':
        'إنشاء منتج بكمية ابتدائية يسجّل حركة أيضاً، فلا تظهر '
        'المنتجات الجديدة "من العدم".',

    'inv_movements.title': 'سجل الحركات والتشخيص',
    'inv_movements.summary':
        'تتبّع كل تغيير: المبيعات والمشتريات والإرجاعات والتعديلات.',
    'inv_movements.s1.heading': 'سجل الحركات',
    'inv_movements.s1.p1':
        'تبويب سجل الحركات يعرض كل تغيير في المخزون عبر المتجر، '
        'الأحدث أولاً. صفِّ حسب النوع: بيع، شراء، إرجاع، تعديل، استلام '
        'مُجمَّعات، وتفكيك مُجمَّعات.',
    'inv_movements.s1.p2':
        'كل صف يعرض تغيّر الكمية بإشارته وتكلفة الوحدة ومتوسط '
        'التكلفة بعد التغيير والسبب والجهاز والوثيقة المصدر عند '
        'وجودها.',
    'inv_movements.s2.heading': 'تشخيص فرق في المخزون',
    'inv_movements.s2.step1':
        'افتح حركات المنتج (لوحة التفصيل أو السجل مصفّى على ذلك '
        'المنتج).',
    'inv_movements.s2.step2':
        'طابق كل تغيير حديث بحدث معروف: بيع، شراء مستلم، إرجاع، أو '
        'تعديل يدوي.',
    'inv_movements.s2.step3':
        'إن وجدت خطأ، صحّحه بتعديل وسبب واضح — يحتفظ السجل بالخطأ '
        'وبالتصحيح معاً.',
    'inv_movements.s2.tip1':
        'تظهر المبيعات الملغاة كنوع حركة خاص، فالإلغاء يستعيد '
        'المخزون دائماً بشكل مرئي.',

    // ------------------------------------------------------------------
    // الفصل 6 — المشتريات والموردون
    // ------------------------------------------------------------------
    'chapter.purchasing.title': 'المشتريات والموردون',
    'purch_suppliers.title': 'إدارة الموردين',
    'purch_suppliers.summary':
        'سجلات الموردين والأرصدة والمدفوعات.',
    'purch_suppliers.s1.heading': 'سجلات الموردين',
    'purch_suppliers.s1.p1':
        'شاشة الموردين تحفظ اسم كل مورد وهاتفه وعنوانه وبريد '
        'الإلكتروني وجهة الاتصال وملاحظاته. الرصيد المعروض للقراءة '
        'فقط — يُحسب من المشتريات والمدفوعات ولا يُكتب يدوياً.',
    'purch_suppliers.s2.heading': 'المدفوعات والرصيد',
    'purch_suppliers.s2.p1':
        'استلام شراء يزيد رصيد المورد بكل ما لم يُدفع عند الاستلام. '
        'تسجيل دفعة ينقصه؛ لا يمكنك دفع أكثر من الرصيد الحالي.',
    'purch_suppliers.s2.p2':
        'كشف حساب المورد يدرج كل فاتورة شراء ودفعة وإلغاء بالترتيب.',
    'purch_suppliers.s2.warn1':
        'لا يمكن أرشفة مورد ما دام هناك رصيد — سوّّ أو ألغِ أولاً.',
    'purch_suppliers.s3.heading': 'الصلاحيات',
    'purch_suppliers.s3.p1':
        'عرض الموردين يتطلب صلاحية عرض الموردين؛ الإنشاء والتعديل '
        'والأرشفة يتطلب إدارة الموردين.',

    'purch_docs.title': 'وثائق الشراء والاستلام',
    'purch_docs.summary':
        'مسودة شراء، استلامه في المخزون، وإلغاؤه بأمان.',
    'purch_docs.s1.heading': 'إنشاء شراء',
    'purch_docs.s1.step1':
        'افتح المشتريات وأنشئ وثيقة: اختر المورد ثم أضف سطور منتجات '
        'بكمية وتكلفة وحدة.',
    'purch_docs.s1.step2':
        'يمكن للسطور استخدام وحدة شراء (مثلاً كرتونة من 24)، وتكون '
        'الكمية حينها بالعبوات الصحيحة، مع إظهار المكافئ الأساسي.',
    'purch_docs.s1.step3':
        'احفظ كمسودة للمتابعة، أو احفظ واستلم للإنهاء بخطوة واحدة.',
    'purch_docs.s4.heading': 'تكلفة الوحدة أو التكلفة الإجمالية',
    'purch_docs.s4.p1':
        'كل سطر يخزن تكلفة وحدة الشراء. افترياً، المبلغ الذي تدخله هو '
        'تكلفة الوحدة. فعّل «التكلفة الإجمالية» عندما يذكر المورد مبلغاً '
        'واحداً للسطر كاملاً: يقسمه التطبيق على الكمية المدخلة ويعرض '
        'تكلفة الوحدة المشتقة قبل الحفظ.',
    'purch_docs.s4.p2':
        'العبوات تُحوَّل كالمعتاد. مثال: 10 علب من 5 قطع بكلفة إجمالية '
        '100 دج ← 10 دج للعلبة، 2 دج للقطعة؛ الاستلام يضيف 50 قطعة '
        'للمخزون ويقيّمها بـ 2 دج للقطعة. وعند إيقاف «التكلفة الإجمالية» '
        'يبقى 100 دج سعر العلبة (20 دج للقطعة).',
    'purch_docs.s4.tip1':
        'معاينة السطر (الكمية الإجمالية، تكلفة الوحدة، الإجمالي) تتحدث '
        'أثناء الكتابة؛ إنها معاينة حسابية فقط — لا يُحفظ شيء ولا يدخل '
        'المخزون حتى تُحفظ فاتورة الشراء (وتُستلم).',
    'purch_docs.s2.heading': 'ما يفعله الاستلام',
    'purch_docs.s2.p1':
        'الاستلام فعل ذرّي واحد: تزداد كميات المخزون ويُحدَّث متوسط '
        'التكلفة ويرتفع رصيد المورد بالمبلغ غير المدفوع وتصبح '
        'الوثيقة مستلمة.',
    'purch_docs.s2.p2':
        'يضبط الخادم تاريخ الشراء عند إنشاء الوثيقة — لا يمكن '
        'استرجاع تاريخها.',
    'purch_docs.s3.heading': 'الإلغاء والحذف',
    'purch_docs.s3.p1':
        'إلغاء شراء مستلم يعكس أثره على المخزون والرصيد. تُحذف '
        'المسودات فقط. تبقى الوثائق المستلمة والملغاة غير قابلة '
        'للتغيير.',
    'purch_docs.s3.warn1':
        'لا إرجاع مشتريات ولا ضريبة على وثائق الشراء في هذه النسخة '
        '— ألغِ وأعد الإدخال إن كان ثمة خطأ.',

    // ------------------------------------------------------------------
    // الفصل 7 — العملاء والمبيعات بالآجل والديون
    // ------------------------------------------------------------------
    'chapter.customers.title': 'العملاء والمبيعات بالآجل والديون',
    'cust_records.title': 'سجلات العملاء',
    'cust_records.summary':
        'الأسماء وبيانات الاتصال وسقوف الدين والأرصدة.',
    'cust_records.s1.heading': 'حقول العميل',
    'cust_records.s1.p1':
        'للعميل اسم (مطلوب) وهاتف وعنوان وسقف دين اختياري. الرصيد '
        'للقراءة فقط ويُحدَّث بالبيع والمدفوعات.',
    'cust_records.s2.heading': 'سقف الدين',
    'cust_records.s2.p1':
        'سقف الدين هو أقصى إجمالي دين يجوز للعميل حمله. السقف 0 '
        'يعني بلا حدّ. الخادم يفرضه: البيع الآجل أو الجزئي الذي '
        'سيتجاوز السقف يُرفض بشرح.',
    'cust_records.s2.warn1':
        'لا يمكن أرشفة عميل له رصيد مستحق.',
    'cust_records.s3.heading': 'الصلاحيات',
    'cust_records.s3.p1':
        'شاشة العملاء تحتاج عرض العملاء؛ الإنشاء والتعديل '
        'والأرشفة تحتاج إدارة العملاء.',

    'cust_debts.title': 'المبيعات بالآجل ودفوعات الدين',
    'cust_debts.summary':
        'بِع بالآجل من نقطة البيع ثم تحصّل وتتبّع الدفعات.',
    'cust_debts.s1.heading': 'بيع بالآجل',
    'cust_debts.s1.p1':
        'عند نقطة البيع اختر العميل (F6)، افتح الدفع، ثم اختر جزئي '
        '(تدفع جزءاً والباقي دين) أو آجل (المبلغ كله دين). كلاهما '
        'يتطلب صلاحية البيع الآجل وعميلاً مختاراً.',
    'cust_debts.s1.p2':
        'إن كان المبلغ سيدفع العميل فوق سقفه، يُرفض البيع قبل حفظ '
        'أي شيء.',
    'cust_debts.s2.heading': 'تسجيل الدفعات',
    'cust_debts.s2.p1':
        'شاشة الديون تعرض أصحاب الأرصدة المستحقة والإجماليات. من '
        'العميل يمكنك تسجيل دفعة؛ لا تدفع أكثر من الرصيد، وكل دفعة '
        'محمية من التكرار.',
    'cust_debts.s2.p2':
        'يعرض تاريخ دين كل عميل كل بيع أنشأ ديناً وكل دفعة '
        'قلّصته.',
    'cust_debts.s3.heading': 'القيود',
    'cust_debts.s3.p1':
        'لا كشوف حساب عملاء مطبوعة ولا تذكير تلقائي بالدفعات في '
        'هذه النسخة. استخدم تاريخ دين العميل كسجل حسابه.',

    // ------------------------------------------------------------------
    // الفصل 8 — الولاء (مرحلة F)
    // ------------------------------------------------------------------
    'chapter.loyalty.title': 'الولاء',
    'loy_overview.title': 'نظرة عامة على النقاط والاسترداد النقدي',
    'loy_overview.summary': 'كيف يكسب العملاء مكافآت الولاء وينفقونها.',
    'loy_overview.s1.heading': 'ما يفعله برنامج الولاء',
    'loy_overview.s1.p1':
        'يتيح برنامج الولاء للعملاء كسب نقاط و/أو استرداد نقدي '
        'من مشترياتهم، ثم إنفاق هذه المكافآت في مبيعات لاحقة. '
        'تُكسب النقاط عن كل وحدة نقدية إنفقها العميل حسب معدل النقاط '
        'المحدد للمتجر؛ ويتراكم الاسترداد النقدي كرصيد مالي بمعدل '
        'المتجر. وكل 100 نقطة تفتح مكافأة واحدة، تمنح نسبة خصم على '
        'البيع — النقاط نفسها ليست مالاً.',
    'loy_overview.s1.p2':
        'لكل عميل حساب ولاء واحد يحمل الرصيدين معاً. الحسابات '
        'تخص كل عميل (يُعرّف برقم هاتفه عند نقطة البيع)، وتحسب '
        'الأرصدة — بما فيها عدد المكافآت الكاملة التي تفتحها — دائماً '
        'على الخادم: لا يخزّن أي شاشة الأرصدة ولا يعيد حسابها.',
    'loy_overview.s2.heading': 'الصلاحيات',
    'loy_overview.s2.p1':
        'الكسب والاستخدام يتمان ضمن تدفق البيع العادي، فيتبعان '
        'صلاحيات البيع. عرض رصيد العميل أو تاريخه يحتاج عرض '
        'العملاء؛ وتعديل قواعد الولاء يحتاج صلاحية إعدادات الولاء.',

    'loy_settings.title': 'إعدادات الولاء',
    'loy_settings.summary':
        'تفعيل الكسب وتحديد المعدلات وضبط أقصى نسبة خصم المكافأة.',
    'loy_settings.s1.heading': 'إعداد القواعد',
    'loy_settings.s1.p1':
        'تُضبط إعدادات الولاء مرة واحدة لكامل المتجر من شاشة '
        'إعدادات الولاء. يمكن تفعيل المكافأتين بشكل مستقل، ويمكن '
        'إيقاف أي منهما في أي وقت.',
    'loy_settings.s1.step1':
        'فعّل النقاط أو الاسترداد النقدي أو كليهما، وحدد معدلاتهما.',
    'loy_settings.s1.step2':
        'حدد أقصى نسبة خصم المكافأة — النسبة القصوى التي قد تخصمها '
        'مكافأة واحدة من البيع (من 0 إلى 100).',
    'loy_settings.s1.step3':
        'اختياراً، فعّل الكسب عند تسديد الديون ليكسب العميل عند '
        'سداد رصيد آجل.',
    'loy_settings.s2.heading': 'حد نسبة خصم المكافأة',
    'loy_settings.s2.p1':
        'تحكم قاعدة واحدة في استخدام المكافآت: النسبة القصوى من '
        'مبلغ البيع التي قد تخصمها مكافأة واحدة. تتراوح بين 0 '
        'و100؛ ووضعها على 0 يوقف استخدام المكافآت مؤقتاً مع '
        'استمرار الكسب.',
    'loy_settings.s2.warn1':
        'تغييرات المعدلات تنطبق على المبيعات المستقبلية فقط. '
        'الأرصدة المكتسبة سابقاً تحتفظ بقيتها الأصلية.',

    'loy_earning.title': 'كسب المكافآت',
    'loy_earning.summary':
        'تتراكم النقاط والاسترداد النقدي على المبيعات وتسديد الديون.',
    'loy_earning.s1.heading': 'على المبيعات',
    'loy_earning.s1.p1':
        'عند اختيار عميل عند نقطة البيع، يضيف البيع المكتمل نقاطاً '
        'و/أو استرداداً نقدياً حسب المبالغ المدفوعة فعلياً. المبيعات '
        'الملغاة لا تكسب شيئاً؛ وإرجاع بيع كامل يعكس ما كسبه ذلك '
        'البيع أيضاً، فتتطابق المكافآت دائماً مع صافي المبيعات '
        'المحتفظ بها فعلاً.',
    'loy_earning.s2.heading': 'عند تسديد الدين',
    'loy_earning.s2.p1':
        'عند تفعيل خيار الكسب عند تسديد الديون، تسجيل دفعة دين '
        'يضيف أيضاً نقاطاً واسترداداً نقدياً على المبلغ المطبق فعلياً '
        'على الدين — فيكافأ العميل بإنصاف حتى عند الدفع لاحقاً.',

    'loy_redeem.title': 'استخدام المكافآت',
    'loy_redeem.summary':
        'تحويل 100 نقطة إلى نسبة خصم عند نقطة البيع.',
    'loy_redeem.s1.heading': 'استخدام مكافأة عند نقطة البيع',
    'loy_redeem.s1.step1':
        'اختر العميل (F6) قبل البيع أو خلاله.',
    'loy_redeem.s1.step2':
        'عند الدفع، اختر نسبة المكافأة من قائمة الولاء: لا تعرض سوى '
        'النسب ضمن الحد الأقصى المحدد للمتجر، ولا تظهر إلا عندما '
        'يملك العميل مكافأة واحدة على الأقل (100 نقطة). وتُظهر '
        'المعاينة قيمة الخصم الدقيقة والمبلغ المتبقي للدفع.',
    'loy_redeem.s1.step3':
        'أكّد — يطبّق الخادم الخصم على البيع، ويستهلك 100 نقطة '
        'بالضبط لمكافأة واحدة، وينخفض المبلغ المستحق تبعاً لذلك.',
    'loy_redeem.s1.p1':
        'لا ترسل الشاشة سوى النسبة المحددة. يتحقق الخادم من أن '
        'العميل يملك مكافأة، وأن النسبة ضمن الحد الأقصى المحدد، '
        'ويحسب الخصم من البيع نفسه، ويعيد التحقق من كل شيء عند '
        'إتمام البيع — فلا تملك أي رسالة من الشاشة أن تطالب بخصم '
        'أكبر أو بإنفاق نقاط لا يملكها العميل.',
    'loy_redeem.s2.heading': 'المرتجعات والإلغاءات',
    'loy_redeem.s2.warn1':
        'إرجاع أصناف من بيع استخدم مكافأة يستعيد النسبة المقابلة من '
        'خصم المكافأة والنقاط المقابلة؛ وإلغاء كهذا البيع يستعيد '
        'خصم المكافأة كاملاً و100 نقطة معه. لا تعود النقاط إلا بحد '
        'أقصى ما يملكه العميل بعد؛ وقد يبقى عجز إن تم إنفاقها في '
        'الأثناء.',

    'loy_report.title': 'تقرير الولاء',
    'loy_report.summary':
        'نشاط الفترة والأرصدة الحالية وسجل المكافآت الكامل.',
    'loy_report.s1.heading': 'نظرة عامة',
    'loy_report.s1.p1':
        'تبويب الولاء في التقارير يجيب عن سؤالين لأي فترة: ما '
        'المكافآت التي تحركت خلالها، وما يخصّص المتجر حالياً لعملائه. '
        'يعرض سياق المبيعات بجانب أرقام المكافآت لتُقرأ معاً.',
    'loy_report.s2.heading': 'أقسام التقرير',
    'loy_report.s2.p1':
        'يضم التقرير أربعة مجالات: سياق المبيعات (إجمالي المبيعات '
        'والفواتير، بنفس أرقام التقرير المالي)، نشاط الفترة '
        '(النقاط والاسترداد النقدي المكتسب وخصومات المكافأة المطبقة '
        'والمعكوسة والمستعادة والأعطال غير المستردة)، الأرصدة '
        'الحالية (النقاط والاسترداد النقدي القائم وعدد العملاء '
        'الذين يحملون رصيداً)، وسجل الأحداث — تاريخ مفصل لكل حركة '
        'مكافأة لكل عميل مع الصفحات.',
    'loy_report.s2.warn1':
        'الأرصدة إجماليات حالية وليست أرقام فترة: '
        'تعكس كل حساب كما هو الآن، بغض النظر عن النطاق الزمني '
        'المحدد.',
    'loy_report.s3.heading': 'الوصول والتصدير',
    'loy_report.s3.p1':
        'عرض تقرير الولاء يحتاج صلاحية التقارير المالية — النطاق '
        'نفسه كباقي تبويبات التقارير. يُطبق المرشح المشترك للفترة '
        'والجهاز، ويُصدَّر التقرير عبر مسارات CSV / XLSX / PDF نفسها.',

    // ------------------------------------------------------------------
    // الفصل 9 — المصاريف والعمليات المالية
    // ------------------------------------------------------------------
    'chapter.expenses.title': 'المصاريف والعمليات المالية',
    'exp_manage.title': 'تسجيل المصاريف وإلغاؤها',
    'exp_manage.summary':
        'تتبّع مصاريف المتجر؛ التصحيح بإلغاء وإعادة إنشاء.',
    'exp_manage.s1.heading': 'تسجيل مصروف',
    'exp_manage.s1.step1':
        'افتح المصاريف وأضف مصروفاً: الفئة والمبلغ وعنوان اختياري '
        'وملاحظة.',
    'exp_manage.s1.step2':
        'مفتاح مدفوع من الصندوق يصنّف المصروف كمدفوع من صندوق '
        'النقدية أو خارجياً؛ إنه تصنيف وليس حركة نقدية.',
    'exp_manage.s1.step3':
        'الفئات قائمة ثابتة: إيجار، فواتير، رواتب، صيانة، مستلزمات، '
        'نقل، أخرى.',
    'exp_manage.s2.heading': 'التصحيح',
    'exp_manage.s2.p1':
        'لا تُعدَّل المصاريف ولا تُحذف. للتصحيح ألغِه بسبب مطلوب ثم '
        'أنشئ مصروفاً صحيحاً جديداً. تبقى الصفوف الملغاة في القائمة '
        'مع سبب الإلغاء ومن ألغاه.',
    'exp_manage.s3.heading': 'في التقارير',
    'exp_manage.s3.p1':
        'تتغذى المصاريف من بطاقة "مصاريف اليوم" في لوحة التحكم '
        'وتقرير المالية، حيث تقلّل صافي الربح وتُقسم بين الصندوق '
        'والخارج. عرضهما يتطلب صلاحية التقارير المالية.',
    'exp_manage.s3.warn1':
        'يضبط الخادم تاريخ المصروف ولا يمكن استرجاعه.',

    // ------------------------------------------------------------------
    // الفصل 10 — الفوترة
    // ------------------------------------------------------------------
    'chapter.facturation.title': 'الفوترة',
    'fac_types.title': 'أنواع الوثائق وإنشاؤها',
    'fac_types.summary':
        'وثائق FAC وDEV وPRO وBC وBL: ما هي وكيف تنشئ واحدة.',
    'fac_types.s1.heading': 'أنواع الوثائق الخمسة',
    'fac_types.s1.step1': 'FAC — فاتورة عميل.',
    'fac_types.s1.step2': 'DEV — إشعار دائن (أفيور).',
    'fac_types.s1.step3': 'PRO — عرض سعر (دوفيس).',
    'fac_types.s1.step4': 'BC — أمر شراء (بون دي كوموند).',
    'fac_types.s1.step5': 'BL — بوليصة توصيل (بون دي ليفروازون).',
    'fac_types.s2.heading': 'إنشاء وثيقة',
    'fac_types.s2.p1':
        'افتح الفوترة، اختر النوع ثم اختر عميلاً. كل وثيقة تحتاج '
        'عميلاً. أضف سطور: سطور المنتجات تملأ السعر والضريبة من '
        'المنتج؛ والسطور النصية تحتاج وصفاً وسعراً ومعدّل ضريبة.',
    'fac_types.s2.p2':
        'الترقيم تلقائي حسب النوع والسنة، مثل FAC-2026-0004. لا '
        'تتغير الأرقام أبداً.',
    'fac_types.s2.tip1':
        'يمكن إنشاء الفواتير أيضاً من عملاء الفوترة — قائمة منفصلة '
        'عن عملاء نقطة البيع.',

    'fac_totals.title': 'الضريبة والطابع والمجاميع',
    'fac_totals.summary':
        'كيف تُحسب الصافي والضريبة والمجموع والطابع على الوثيقة.',
    'fac_totals.s1.heading': 'الضريبة (TVA)',
    'fac_totals.s1.p1':
        'لكل سطر معدّل ضريبة 0% أو 9% أو 19%. الخادم يحسب مجاميع '
        'الوثيقة من مبالغ السطور الخام — لا تثق بيدك في المجاميع.',
    'fac_totals.s2.heading': 'الطابع الجبائي',
    'fac_totals.s2.p1':
        'على الفواتير النقدية (FAC المدفوعة نقداً) قد يُطبَّق طابع '
        'جباي بمفتاح الطابع: 0 حتى 300 دج مجموع، ثم نسبة ترتفع مع '
        'المجموع، بحدّ أدنى 5 دج عند انطباقه. المبلغ المستحق '
        'يصبح المجموع زائد الطابع.',
    'fac_totals.s2.p2':
        'يظهر سطر الطابع فقط عند تفعيله وكون المبلغ فوق صفر. لا '
        'يُستخدم في مبيعات نقطة البيع.',
    'fac_totals.s2.warn1':
        'يُعاد حساب المجاميع دائماً من الخادم؛ المعاينة تعرض الأرقام '
        'المرجعية.',

    'fac_pdf_post.title': 'PDF والتسجيل كبيع وعدم التغيير',
    'fac_pdf_post.summary':
        'معاينة وتصدير PDF وتسجيل فاتورة كبيع حقيقي.',
    'fac_pdf_post.s1.heading': 'المعاينة وPDF',
    'fac_pdf_post.s1.p1':
        'نموذج الفاتورة يعرض معاينة A4 حية من الخادم. من وثيقة '
        'محفوظة يمكنك تنزيل التخطيط نفسه كملف PDF.',
    'fac_pdf_post.s2.heading': 'التسجيل كبيع',
    'fac_pdf_post.s2.p1':
        'يمكن تسجيل FAC كبيع حقيقي بأسلوب نقطة البيع: يتحرك '
        'المخزون وتتحدث تقارير المبيعات وترتبط الوثيقة بالبيع '
        'المنشأ. كل سطر يجب أن يشير لمنتج أو مُجمَّع — السطور '
        'النصية لا تُرحَّل.',
    'fac_pdf_post.s2.p2':
        'استخدم مفتاح الترحيل عند الإنشاء، أو رحّل لاحقاً من '
        'الوثيقة. الترحيل يتطلب إدارة الفوترة (وحقة البيع عند '
        'الترحيل المنفصل) ومحمي من التكرار.',
    'fac_pdf_post.s3.heading': 'عدم التغيير',
    'fac_pdf_post.s3.p1':
        'لا تُحذف الوثائق أبداً. بعد الترحيل يُقفل العميل والدفع '
        'والسطور؛ تبقى الملاحظات وواجهة العرض قابلة للتعديل. الرقم '
        'والنوع والسنة والتاريخ لا تتغير أبداً.',

    // ------------------------------------------------------------------
    // الفصل 11 — التقارير والتصدير
    // ------------------------------------------------------------------
    'chapter.reports.title': 'التقارير والتصدير',
    'rep_overview.title': 'أقسام التقارير',
    'rep_overview.summary': 'عشرة تقارير وما يجيب عنه كل منها.',
    'rep_overview.s1.heading': 'الأقسام',
    'rep_overview.s1.step1':
        'المالية — الأرباح والخسائر للفترة مع تفصيل حسب الجهاز.',
    'rep_overview.s1.step2':
        'أداء المنتجات — ما بيع وكميات وإيرادات وربح لكل منتج.',
    'rep_overview.s1.step3':
        'تحليل التصنيفات — مبيعات مجمّعة حسب التصنيف.',
    'rep_overview.s1.step4':
        'يومي وساعي — خطوط زمنية للمبيعات.',
    'rep_overview.s1.step5':
        'الساعات الذروة — أكثر الساعات ازدحاماً خلال نافذة مرجعية.',
    'rep_overview.s1.step6':
        'البطيء — منتجات لم تُبع خلال عدد أيام مختار.',
    'rep_overview.s1.step7':
        'الفواتير الملغاة — مبيعات ملغاة مع الأسباب.',
    'rep_overview.s1.step8':
        'تفصيل المبيعات — مبيعات بصف مع فلاتر الحالة والدفع.',
    'rep_overview.s1.step9':
        'تقرير المورد — المستحق للموردين.',
    'rep_overview.s2.heading': 'الوصول',
    'rep_overview.s2.p1':
        'قسم التقارير كله يتطلب صلاحية التقارير المالية.',

    'rep_exports.title': 'الفلاتر والتصدير',
    'rep_exports.summary':
        'الفترات وفلاتر أخرى وتصدير CSV وXLSX وPDF.',
    'rep_exports.s1.heading': 'الفلاتر',
    'rep_exports.s1.p1':
        'كل تبويب يشارك إعدادات الفترة (اليوم، أمس، آخر 7 أيام، هذا '
        'الشهر وفترات أطول) وتواريخ من/إلى مخصصة. تفصيل المبيعات '
        'يضيف فلاتر الحالة والدفع؛ الذروة والبطيء لهما معايير '
        'إضافية.',
    'rep_exports.s2.heading': 'التصدير',
    'rep_exports.s2.step1':
        'حمّل التقرير ثم اضغط تصدير (يتطلب صلاحية تصدير البيانات).',
    'rep_exports.s2.step2':
        'اختر CSV (يُبنى على هذا الجهاز) أو XLSX أو PDF (ينتجه '
        'الخادم).',
    'rep_exports.s2.step3':
        'التصديرات الكبيرة محدودة بـ 50,000 صف؛ ضيّق الفترة إن '
        'رفض الخادم الطلب.',
    'rep_exports.s2.tip1':
        'زر التقارير في لوحة التحكم يفتح هذا القسم بنفس الفترة '
        'مطبّقة.',

    // ------------------------------------------------------------------
    // الفصل 12 — الطباعة والإيصالات
    // ------------------------------------------------------------------
    'chapter.printing.title': 'الطباعة والإيصالات',
    'prt_overview.title': 'الإيصالات والملصقات وطباعة الوثائق',
    'prt_overview.summary':
        'ما يستطيع هذا التطبيق إرساله للطابع وما لا يستطيع.',
    'prt_overview.s1.heading': 'الطباعة المدعومة',
    'prt_overview.s1.p1':
        'تُطبع الإيصالات عبر مربع حوار طباعة نظام التشغيل بعد '
        'البيع (راجع أيضاً فصل نقطة البيع). الورق: لفّة 80 مم أو '
        'A4، يُختار في إعدادات المتجر أو عند إعادة الطباعة.',
    'prt_overview.s1.p2':
        'يمكن طباعة ملصقات الأسعار من شاشة المنتجات للمنتجات '
        'المختارة. تُصدَّر وثائق الفوترة كملفات PDF بحجم A4.',
    'prt_overview.s2.heading': 'سير عمل الطباعة',
    'prt_overview.s2.p1':
        'تفتح الطباعة مربع حوار النظام: اختر طابعة أو "حفظ كـ PDF". '
        'إلغاء هذا المربع لا يُفشل البيع أبداً — يبقى البيع مكتملاً.',
    'prt_overview.s3.heading': 'غير مدعوم',
    'prt_overview.s3.p1':
        'التحكم المباشر بطابعات ESC/POS وفتح صندوق النقد وأجهزة '
        'عرض العملاء غير مدمجة في هذه النسخة. استخدم مربع حوار '
        'النظام وطابعة تدعم حجم ورقك.',
    'prt_overview.s3.warn1':
        'إن فشلت الطباعة برسالة "الطابعة غير متاحة"، فالنظام لا '
        'يجد طابعة قابلة للاستخدام — راجع إعدادات الطابعة في النظام '
        'أولاً.',

    // ------------------------------------------------------------------
    // الفصل 13 — الشبكة متعددة الأجهزة
    // ------------------------------------------------------------------
    'chapter.lan.title': 'الشبكة وتشغيل عدة أجهزة',
    'lan_pairing.title': 'الاقتران والاتصال',
    'lan_pairing.summary':
        'كيف يجد جهاز العميل الخادم ويبقى متصلًا.',
    'lan_pairing.s1.heading': 'اقتران عميل',
    'lan_pairing.s1.step1':
        'على العميل، يبحث معالج التشغيل الأول عن الخادم في الشبكة، '
        'أو تدخل عنوانه يدوياً.',
    'lan_pairing.s1.step2':
        'على الخادم، يولّد المدير رمز اقتران من ستة أرقام من شاشة '
        'الأجهزة (صالح عشر دقائق).',
    'lan_pairing.s1.step3':
        'أدخل الرمز على العميل؛ ينتظر الطلب حتى يوافق المدير على '
        'الجهاز.',
    'lan_pairing.s2.heading': 'البقاء متصلاً',
    'lan_pairing.s2.p1':
        'تعرض شارة الحالة أعلى الشاشة: متصل، يعيد الاتصال، منقطع، '
        'أو تحذير قاعدة بيانات. تُعاد المحاولة تلقائياً عند انقطاع '
        'قصير بفواصل متزايدة؛ لا يُقاطع الصندوق بأعطاب الشبكة.',
    'lan_pairing.s2.warn1':
        'مشكلة اتصال عند الإقلاع تُظهر مربع حوار مرة واحدة: أعد '
        'المحاولة أو أدخل عنوان الخادم يدوياً. لا تُخزَّن المبيعات '
        'دون اتصال — يجب أن يكون الخادم قابلاً للوصول لإتمام البيع.',

    'lan_devices.title': 'إدارة الأجهزة',
    'lan_devices.summary':
        'الموافقة على أجهزة العميل ورفضها وسحبها.',
    'lan_devices.s1.heading': 'شاشة الأجهزة',
    'lan_devices.s1.p1':
        'تتطلب صلاحية إدارة الأجهزة. تعرض الشاشة رمز الاقتران '
        'وعناوين الخادم على الشبكة (انقر للنسخ) ثم الأجهزة '
        'المعلّقة والمسجّلة.',
    'lan_devices.s1.p2':
        'لكل جهاز معرّف وحالة وآخر عنوان IP معروف وإصدار التطبيق '
        'وقبل آخر اتصال.',
    'lan_devices.s2.heading': 'الإجراءات',
    'lan_devices.s2.step1':
        'الموافقة — تسمح لجهاز معلّق بالاتصال (تحتاج تأكيداً).',
    'lan_devices.s2.step2': 'الرفض — يرفض جهازاً معلّقاً.',
    'lan_devices.s2.step3':
        'السحب — يقطع جهازاً موافقاً فوراً؛ يجب أن يُقترن مجدداً.',
    'lan_devices.s2.warn1':
        'لا تشارك رموز الاقتران أو عناوين خارج شبكة المتجر نفسه.',

    // ------------------------------------------------------------------
    // الفصل 14 — الإعدادات والنسخ الاحتياطي والاستعادة
    // ------------------------------------------------------------------
    'chapter.settings.title': 'الإعدادات والنسخ الاحتياطي والاستعادة',
    'set_general.title': 'اللغة والمظهر وإعدادات المتجر',
    'set_general.summary':
        'تفضيلات شخصية وتكوين على مستوى المتجر.',
    'set_general.s1.heading': 'اللغة والمظهر',
    'set_general.s1.p1':
        'الإعدادات > اللغة يبدّل العربية أو الفرنسية أو الإنجليزية '
        'لهذا الجهاز فقط. المظهر يعرض داكناً وفاتحاً ورمادياً؛ '
        'كلا الاختيارين يُحفظان محلياً.',
    'set_general.s2.heading': 'إعدادات المتجر',
    'set_general.s2.p1':
        'بصلاحية إدارة الإعدادات يمكنك ضبط اسم المتجر والهاتف '
        'والعنوان وتذييل الإيصال والورق الافتراضي (80 مم أو A4) '
        'ومفاتيح السؤال قبل الطباعة والطباعة التلقائية وهل يُسمح '
        'للعملاء بالدين عند نقطة البيع وحدّ المخزون المنخفض '
        'الافتراضي.',
    'set_general.s3.heading': 'بيانات الشركة',
    'set_general.s3.p1':
        'قسم الشركة يخزّن الولاية والبريد والمعرّفات الجبائية '
        '(RC وNIF وAI وNIS) المستخدمة على الوثائق.',

    'set_backup.title': 'النسخ الاحتياطي والاستعادة',
    'set_backup.summary':
        'أنشئ نسخاً احتياطية للخادم واستعدها بحذر.',
    'set_backup.s1.heading': 'إنشاء نسخة احتياطية',
    'set_backup.s1.p1':
        'بصلاحية النسخ والاستعادة، تعرض صفحة الإعدادات النسخ '
        'الاحتياطية للخادم وتقترح إنشاء نسخة. النسخ ملفات SQL '
        'ومانيفست على قرص الخادم — لا تُنزَّل إلى هذا الجهاز.',
    'set_backup.s2.heading': 'الاستعادة',
    'set_backup.s2.p1':
        'الاستعادة تستبدل قاعدة البيانات الحالية كلها بالنسخة '
        'المختارة. يوضح التأكيد أن ذلك لا يمكن التراجع عنه. '
        'يُتحقّق من سلامة كل ملف قبل تطبيقه.',
    'set_backup.s2.warn1':
        'أنشئ نسخة جديدة قبل أي استعادة. الاستعادة أخطر إجراء في '
        'التطبيق.',
    'set_backup.s3.heading': 'إن فُقدت أدوات النسخ',
    'set_backup.s3.p1':
        'يحتاج الخادم لتركيب أدوات تصدير قاعدة البيانات. إن أفادك '
        'التطبيق بأن الأدوات ناقصة، اطلب من مسؤول الخادم تركيبها.',

    // ------------------------------------------------------------------
    // الفصل 15 — استكشاف الأخطاء وإصلاحها
    // ------------------------------------------------------------------
    'chapter.troubleshooting.title': 'استكشاف الأخطاء وإصلاحها',
    'ts_connection.title': 'مشكلات الاتصال والخادم',
    'ts_connection.summary':
        'ما تفحصه حين لا يصل العميل إلى الخادم.',
    'ts_connection.s1.heading': 'العميل يعرض منقطع',
    'ts_connection.s1.step1':
        'تحقق من أن جهاز الخادم يعمل والخدمة قيد التشغيل.',
    'ts_connection.s1.step2':
        'تحقق من أن الجهازين على الشبكة نفسها ويمكنهما الاتصال '
        'بالآخر.',
    'ts_connection.s1.step3':
        'راقب شارة الحالة — تُعيد الاتصال تلقائياً؛ استخدم الإدخال '
        'اليدوي في مربع الإقلاع لتأشير العميل على عنوان الخادم '
        'الصحيح.',
    'ts_connection.s1.step4':
        'إن كانت الشارة خضراء وفشل تحميل البيانات، فقد تكون قاعدة '
        'بيانات الخادم غير متاحة — تعرض الشارة تحذير قاعدة بيانات؛ '
        'يحتاج الخادم لتدخل.',
    'ts_connection.s2.heading': 'رفض الدخول بعد تغيير الخادم',
    'ts_connection.s2.p1':
        'الجلسة المنتهية تعيدك لشاشة الدخول — سجّل الدخول مجدداً '
        'برمزك. خادم بديل يحتاج إعادة اقتران الجهاز.',
    'ts_connection.s2.warn1':
        'لا "تصلح" اتصالاً بتصفير قاعدة البيانات أو تعطيل الأمان. '
        'أعد توجيه العميل، أو اطلب من المدير إعادة الموافقة على '
        'الجهاز.',

    'ts_print_pdf.title': 'مشكلات الطباعة وPDF والبحث',
    'ts_print_pdf.summary':
        'الإيصالات لا تُطبع، PDF مفقودة، المنتجات غير موجودة.',
    'ts_print_pdf.s1.heading': 'مشاكل الطباعة',
    'ts_print_pdf.s1.step1':
        'البيع المكتمل لا يضيع بسبب فشل الطباعة — أعد الطباعة من '
        'سجل المبيعات (F11) بدلاً من إعادة إدخال البيع.',
    'ts_print_pdf.s1.step2':
        '"الطابعة غير متاحة" تعني أن النظام بلا طابعة قابلة '
        'للاستخدام — راجع إعدادات الطابعة، أو استخدم حفظ كـ PDF.',
    'ts_print_pdf.s1.step3':
        'لا إيصال بعد الدفع؟ راجع مفتاح السؤال قبل الطباعة '
        'والطباعة التلقائية في إعدادات المتجر.',
    'ts_print_pdf.s2.heading': 'المنتج غير موجود بالباركود',
    'ts_print_pdf.s2.step1':
        'اضغط Enter مرة واحدة: تطابق الباركود أو الاسم أو SKU '
        'يُضاف مباشرة؛ وإلا يُضاف أول نتيجة بحث.',
    'ts_print_pdf.s2.step2':
        'المنتجات المؤرشفة والنافدة ممنوعة مع رسالة — راجع حالة '
        'المنتج على شاشة المنتجات.',
    'ts_print_pdf.s2.step3':
        'إن كان الباركود أُدخل من جهاز آخر، حدّث (F5) ليكون '
        'الكتالوج محدّثاً.',

    'ts_data.title': 'مشكلات المخزون والدين والصلاحيات والتخطيط',
    'ts_data.summary':
        'أرقام غير متوقعة وأزرار مفقودة وأسئلة عرض.',
    'ts_data.s1.heading': 'المخزون أو الدين يبدو خاطئاً',
    'ts_data.s1.step1':
        'افتح سجل الحركات (المخزون) أو تاريخ دين العميل وراجع كل '
        'مدخلة مقابل أحداث معروفة.',
    'ts_data.s1.step2':
        'صحّح المخزون بتعديل وسبب واضح؛ سجّل دفعة ديون للمبالغ '
        'المحصّلة زائداً. يحتفظ التاريخ دائماً بالأصل وبالتصحيح.',
    'ts_data.s2.heading': 'زر أو شاشة مفقودة',
    'ts_data.s2.p1':
        'الشاشات والأفعال تتبع الصلاحيات. إن فُقد شيء، يستطيع '
        'المدير منح الصلاحية المطابقة (مثل تعديل المخزون أو البيع '
        'الآجل أو التقارير). لا قائمة مخفية — المفقود غير مسموح '
        'لدورك.',
    'ts_data.s3.heading': 'النص أو التخطيط يبدو خاطئاً',
    'ts_data.s3.p1':
        'العربية تُكتب من اليمين لليسار في كل التطبيق؛ الإصدارات '
        'والباركود وأرقام الفواتير تبقى من اليسار لليمين عمداً. '
        'وسّع النافذة إن بدت اللوحات ضيقة — يتكيّف التطبيق من عرض '
        'الهاتف حتى سطح المكتب الكامل.',
    'ts_data.s3.tip1':
        'تغيّر اللغة والمظهر يُطبّق فوراً في الإعدادات وعلى هذا '
        'الجهاز فقط.',
  },

  // -------------------------------------------------------------------------
  // Français
  // -------------------------------------------------------------------------
  'fr': <String, String>{
    'chapter.getting_started.title': 'Prise en main',
    'chapter.dashboard.title': 'Tableau de bord',
    'chapter.pos.title': 'Point de vente',

    'gs_first_launch.title': 'Premier lancement et configuration réseau',
    'gs_first_launch.summary':
        'Choisissez le rôle de la machine et connectez les postes au serveur.',
    'gs_first_launch.s1.heading': 'Choisir le rôle de cette machine',
    'gs_first_launch.s1.p1':
        'Au tout premier lancement, l\u2019application ouvre un assistant '
        'de configuration. Un rôle doit être choisi avant toute autre étape.',
    'gs_first_launch.s1.step1':
        'Serveur — la machine principale qui héberge la base de données. '
        'Elle ouvre directement le tableau de bord et ne s\u2019apparie '
        'pas à elle-même.',
    'gs_first_launch.s1.step2':
        'Client — une caisse ou un poste de back-office qui se connecte au '
        'serveur sur le réseau local.',
    'gs_first_launch.s1.tip1':
        'L\u2019assistant ne peut pas être fermé au premier lancement ; le '
        'choix est obligatoire.',
    'gs_first_launch.s2.heading': 'Connecter un client au serveur',
    'gs_first_launch.s2.step1':
        'Sur un client, l\u2019assistant recherche automatiquement le '
        'serveur sur le réseau local.',
    'gs_first_launch.s2.step2':
        'Sélectionnez le serveur découvert, ou saisissez son adresse '
        'manuellement si la découverte échoue.',
    'gs_first_launch.s2.step3':
        'Saisissez le code d\u2019appairage affiché sur le client lorsqu\u2019il '
        'est demandé.',
    'gs_first_launch.s2.step4':
        'Un administrateur doit approuver le nouvel appareil depuis la '
        'section Appareils avant que le client puisse se connecter.',
    'gs_first_launch.s3.heading': 'Prérequis',
    'gs_first_launch.s3.p1':
        'Toutes les machines doivent être sur le même réseau local, et la '
        'machine serveur doit être en marche. Par la suite, l\u2019assistant '
        'est à nouveau accessible depuis les Paramètres pour la gestion des '
        'appareils.',
    'gs_first_launch.s3.warn1':
        'Un client qui n\u2019a jamais terminé l\u2019assistant est '
        'inutilisable — il n\u2019a pas encore d\u2019identité d\u2019appareil.',

    'gs_admin_login.title': 'Compte administrateur et connexion',
    'gs_admin_login.summary':
        'Créez le premier administrateur, puis connectez-vous avec un PIN.',
    'gs_admin_login.s1.heading': 'Créer le premier administrateur',
    'gs_admin_login.s1.p1':
        'Juste après l\u2019étape réseau, l\u2019application demande le '
        'premier compte administrateur : un nom complet et un PIN, saisi '
        'deux fois pour confirmation.',
    'gs_admin_login.s1.warn1':
        'Il n\u2019y a aucun mot de passe par défaut. Choisissez votre PIN '
        'pendant la configuration et gardez-le confidentiel.',
    'gs_admin_login.s2.heading': 'Se connecter',
    'gs_admin_login.s2.p1':
        'L\u2019écran de connexion liste les utilisateurs créés par un '
        'administrateur. Choisissez votre nom et saisissez votre PIN sur le '
        'pavé numérique.',
    'gs_admin_login.s2.p2':
        'Après la connexion, vous arrivez au tableau de bord. Votre nom et '
        'vos rôles sont affichés dans la barre supérieure, d\u2019où vous '
        'pouvez aussi vous déconnecter.',

    'gs_navigation.title': 'Naviguer dans les sections principales',
    'gs_navigation.summary':
        'Le rail de navigation, les écrans principaux et les raccourcis.',
    'gs_navigation.s1.heading': 'Le rail de navigation',
    'gs_navigation.s1.p1':
        'Un rail latéral liste les sections de l\u2019application par '
        'groupes. Les éléments pour lesquels vous n\u2019avez pas la '
        'permission sont masqués : le rail ne montre que ce que votre '
        'compte peut réellement utiliser.',
    'gs_navigation.s2.heading': 'Sections principales',
    'gs_navigation.s2.step1':
        'Tableau de bord — un aperçu du jour et de votre stock.',
    'gs_navigation.s2.step2': 'Point de vente — encaisser les ventes (F1).',
    'gs_navigation.s2.step3': 'Produits — gérer votre catalogue (F2).',
    'gs_navigation.s2.step4':
        'Stock, Ventes, Clients, Dettes, Achats, Promotions, Packs, '
        'Dépenses, Facturation et Rapports — selon vos permissions.',
    'gs_navigation.s2.tip1':
        'Les raccourcis globaux fonctionnent partout : F1 ouvre le PDV, F2 '
        'Produits, et F4 place le curseur dans la recherche de la page.',
    'gs_navigation.s3.heading': 'Aide et ce manuel',
    'gs_navigation.s3.p1':
        'Le bouton point d\u2019interrogation de la barre supérieure ouvre '
        'la liste des raccourcis clavier. La page À propos (groupe '
        'Paramètres) affiche les versions application et serveur et ouvre '
        'ce Centre de documentation.',

    'gs_workflow.title': 'Un flux de travail pratique pour débuter',
    'gs_workflow.summary':
        'D\u2019une installation vide à votre première vente d\u2019essai.',
    'gs_workflow.s1.heading': 'Ordre de travail suggéré',
    'gs_workflow.s1.step1': 'Connectez-vous en tant qu\u2019administrateur.',
    'gs_workflow.s1.step2':
        'Ouvrez Produits et créez quelques produits avec codes-barres et '
        'prix.',
    'gs_workflow.s1.step3':
        'Créez si besoin des packs ou des promotions.',
    'gs_workflow.s1.step4':
        'Ouvrez le Point de vente (F1) et essayez une vente d\u2019essai en '
        'espèces.',
    'gs_workflow.s1.step5':
        'Imprimez ou prévisualisez le ticket si l\u2019impression est '
        'configurée.',
    'gs_workflow.s1.step6':
        'Ouvrez le tableau de bord pour voir la vente reflétée dans les '
        'chiffres du jour.',
    'gs_workflow.s1.tip1':
        'Vous pouvez changer de langue et de thème à tout moment dans les '
        'Paramètres.',

    'dash_overview.title': 'Ce que montre le tableau de bord',
    'dash_overview.summary':
        'Chiffres clés, ventes récentes et produits les plus vendus.',
    'dash_overview.s1.heading': 'Objectif et accès',
    'dash_overview.s1.p1':
        'Le tableau de bord est le premier écran après la connexion. Il '
        'résume l\u2019activité du jour, la position du stock et les dettes '
        'clients pour vous aider à décider de la suite.',
    'dash_overview.s1.p2':
        'Il nécessite la permission de rapports financiers. Sans elle, un '
        'message de permission refusée s\u2019affiche.',
    'dash_overview.s2.heading': 'Les cartes de synthèse',
    'dash_overview.s2.p1':
        'Les cartes sont groupées en trois rangées. Aujourd\u2019hui : '
        'ventes, tickets, profit et dépenses du jour courant. Produits et '
        'stock : nombre de produits, valeur du stock et produits en stock '
        'bas. Clients et dettes : nombre de clients, clients endettés et '
        'dette totale.',
    'dash_overview.s2.tip1':
        'La rangée Aujourd\u2019hui affiche toujours les chiffres du jour '
        'courant, quelle que soit la période choisie ci-dessous.',
    'dash_overview.s3.heading': 'Ventes récentes et meilleurs produits',
    'dash_overview.s3.p1':
        'Ventes récentes liste les dernières ventes finalisées de la '
        'période, jusqu\u2019à cinq : numéro de ticket, date, mode de '
        'paiement et total.',
    'dash_overview.s3.p2':
        'Meilleurs produits montre les cinq produits les plus vendus de la '
        'période sous forme de simple histogramme et d\u2019une liste avec '
        'quantité vendue, ventes nettes et profit.',
    'dash_overview.s3.warn1':
        'Ces listes ne sont que des synthèses — ouvrez Ventes ou Rapports '
        'pour l\u2019historique complet. Les périodes vides affichent '
        '« Aucune donnée pour cette période ».',

    'dash_controls.title': 'Filtres de période et actions',
    'dash_controls.summary': 'Changer la période, actualiser, ouvrir Rapports.',
    'dash_controls.s1.heading': 'Choisir une période',
    'dash_controls.s1.p1':
        'La barre de période propose des préréglages (aujourd\u2019hui, '
        'hier, 7 derniers jours, ce mois-ci et des plages plus longues) '
        'ainsi qu\u2019une plage personnalisée via les deux boutons de date.',
    'dash_controls.s1.p2':
        'Changer la période recharge les listes des ventes récentes et des '
        'meilleurs produits pour les dates choisies.',
    'dash_controls.s2.heading': 'Actualisation et rapports',
    'dash_controls.s2.step1':
        'Le bouton d\u2019actualisation recharge les données affichées sans '
        'perdre votre sélection.',
    'dash_controls.s2.step2':
        'Le bouton Rapports ouvre la section Rapports complète avec la même '
        'période — utilisez-le pour les exports et analyses détaillées.',
    'dash_controls.s2.step3':
        'Si le chargement échoue, un bouton Réessayer apparaît ; les '
        'données précédentes restent à l\u2019écran pendant le rechargement.',

    'pos_opening.title': 'Ouvrir le PDV et son interface',
    'pos_opening.summary':
        'Repérer l\u2019écran, le champ de recherche et le panier.',
    'pos_opening.s1.heading': 'Ouvrir l\u2019écran',
    'pos_opening.s1.p1':
        'Ouvrez le Point de vente depuis le rail de navigation ou appuyez '
        'sur F1 depuis n\u2019importe où. Le champ de recherche produit est '
        'focus automatiquement pour scanner ou taper immédiatement.',
    'pos_opening.s2.heading': 'Ce que contient l\u2019écran',
    'pos_opening.s2.step1':
        'Le champ de recherche en haut : scannez un code-barres ou tapez un '
        'nom, puis appuyez sur Entrée.',
    'pos_opening.s2.step2':
        'Le catalogue en dessous, commutable entre grille et liste ; votre '
        'choix est mémorisé.',
    'pos_opening.s2.step3':
        'Une rangée de favoris sur les fenêtres larges, et un bouton Packs '
        'qui ouvre le sélecteur de packs.',
    'pos_opening.s2.step4':
        'Le panneau panier avec les lignes, les quantités et les totaux. Sur '
        'les fenêtres étroites, le panier devient un tiroir latéral.',
    'pos_opening.s3.heading': 'Ajouter un produit',
    'pos_opening.s3.p1':
        'Appuyez sur Entrée dans la recherche pour ajouter la correspondance '
        'exacte du code-barres, du nom ou du SKU — ou le premier résultat. '
        'Un court délai après la frappe affiche les produits correspondants '
        'que vous pouvez cliquer.',
    'pos_opening.s3.warn1':
        'Les produits archivés ne peuvent pas être ajoutés, et les produits '
        'sans stock sont bloqués avec un message clair.',

    'pos_selling.title': 'Ajouter produits et quantités',
    'pos_selling.summary':
        'Variantes, unités de vente et saisie des quantités.',
    'pos_selling.s1.heading': 'Variantes et unités de vente',
    'pos_selling.s1.p1':
        'Si un produit a une seule variante, elle est choisie '
        'automatiquement. Avec plusieurs variantes, un sélecteur demande '
        'laquelle vous voulez.',
    'pos_selling.s1.p2':
        'Quand un produit a des unités de vente (par exemple la pièce et '
        'la boîte), un sélecteur vous invite à choisir ; l\u2019unité de '
        'base est toujours proposée en premier.',
    'pos_selling.s2.heading': 'Modifier les quantités',
    'pos_selling.s2.step1':
        'Utilisez les boutons plus et moins sur la ligne du panier ; la '
        'quantité ne peut jamais descendre sous un.',
    'pos_selling.s2.step2':
        'Tapez un nombre dans le champ quantité et appuyez sur Entrée pour '
        'l\u2019appliquer.',
    'pos_selling.s2.step3':
        'Appuyez sur la touche astérisque (*) pour ouvrir une petite '
        'fenêtre et saisir la quantité exacte, y compris des expressions '
        'comme 10*24.',
    'pos_selling.s2.tip1':
        'Après l\u2019ajout d\u2019un produit, le champ quantité de la '
        'nouvelle ligne prend le focus pour être ajusté tout de suite.',

    'pos_pricing.title': 'Prix, gros et remises',
    'pos_pricing.summary':
        'Interactions entre prix détail, gros, promotions et remises.',
    'pos_pricing.s1.heading': 'Tarification automatique',
    'pos_pricing.s1.p1':
        'Les lignes démarrent au prix de détail. Dès que la quantité '
        'atteint le seuil de gros, la ligne passe au prix de gros et '
        'affiche une petite étiquette gros.',
    'pos_pricing.s1.p2':
        'Une promotion s\u2019applique automatiquement lorsqu\u2019elle est '
        'éligible ; la ligne montre une étiquette promotion avec le prix '
        'original barré.',
    'pos_pricing.s1.warn1':
        'Le prix de gros s\u2019applique à l\u2019unité de base à partir du '
        'seuil. Les unités de vente personnalisées, les lignes pack et les '
        'lignes à prix explicite ne basculent jamais automatiquement en gros '
        'ou en promo.',
    'pos_pricing.s2.heading': 'Remises que vous maîtrisez',
    'pos_pricing.s2.p1':
        'Chaque ligne a un champ de remise pour réduire cette ligne seule.',
    'pos_pricing.s2.p2':
        'Le bouton de remise sur la facture (ou F7) s\u2019applique au '
        'panier entier. Il nécessite la permission de remise, et le montant '
        'ne peut dépasser le sous-total.',
    'pos_pricing.s3.heading': 'Le panneau des totaux',
    'pos_pricing.s3.p1':
        'Le panneau des totaux affiche toujours le sous-total, les remises '
        'appliquées et le total final dans la devise du magasin.',

    'pos_payment.title': 'Finaliser une vente',
    'pos_payment.summary':
        'Modes de paiement, confirmation et sécurité.',
    'pos_payment.s1.heading': 'Ouvrir le paiement',
    'pos_payment.s1.p1':
        'Appuyez sur le bouton PAY ou sur la touche ESPACE pour ouvrir la '
        'fenêtre de paiement. Avec un panier vide, un message amical '
        's\u2019affiche à la place.',
    'pos_payment.s2.heading': 'Modes de paiement',
    'pos_payment.s2.step1':
        'Espèces — saisissez le montant reçu ; la monnaie est calculée pour '
        'vous.',
    'pos_payment.s2.step2': 'Carte — confirmez le total comme payé par carte.',
    'pos_payment.s2.step3':
        'Partiel — payez une partie maintenant et laissez un solde sur la '
        'dette du client. Nécessite un client sélectionné et la permission '
        'de vente à crédit.',
    'pos_payment.s2.step4':
        'Crédit — mettez le montant entier sur la dette du client. Nécessite '
        'aussi un client et la permission de vente à crédit.',
    'pos_payment.s3.heading': 'Sécurité et confirmation',
    'pos_payment.s3.p1':
        'Si l\u2019encaissement échoue, votre panier est conservé tel quel '
        'pour réessayer sans risque.',
    'pos_payment.s3.p2':
        'La dette d\u2019un client ne peut dépasser son plafond configuré ; '
        'un rejet explique les montants concernés.',
    'pos_payment.s3.p3':
        'En cas de succès, un message affiche le numéro de ticket et le '
        'panier est vidé pour le client suivant.',

    'pos_printing.title': 'Imprimer les tickets',
    'pos_printing.summary':
        'Impression automatique après vente et réimpressions.',
    'pos_printing.s1.heading': 'Paramètres d\u2019impression',
    'pos_printing.s1.p1':
        'Les paramètres du magasin contrôlent l\u2019impression : papier par '
        'défaut (rouleau 80 mm, A4 ou rouleau), demande avant impression, '
        'et impression automatique après chaque vente.',
    'pos_printing.s2.heading': 'Après une vente',
    'pos_printing.s2.p1':
        'Si l\u2019impression automatique est activée, le ticket est imprimé '
        'juste après l\u2019encaissement. Si la demande est activée, une '
        'petite fenêtre demande confirmation. Avec les deux options '
        'désactivées, rien n\u2019est imprimé automatiquement.',
    'pos_printing.s2.warn1':
        'Un problème d\u2019impression ne fait jamais échouer la vente — la '
        'vente reste finalisée et un message d\u2019erreur s\u2019affiche.',
    'pos_printing.s3.heading': 'Réimprimer plus tard',
    'pos_printing.s3.p1':
        'Ouvrez l\u2019historique des ventes (F11), sélectionnez la vente, '
        'puis utilisez Imprimer ou Réimprimer. Un aperçu permet de choisir '
        'le papier, d\u2019enregistrer le PDF, ou de l\u2019envoyer à '
        'l\u2019imprimante système.',

    'pos_history.title': 'Historique des ventes et détails',
    'pos_history.summary':
        'Consulter les ventes passées, copier les tickets, réimprimer.',
    'pos_history.s1.heading': 'Ouvrir l\u2019historique',
    'pos_history.s1.p1':
        'Appuyez sur F11 ou le bouton historique du PDV. La fenêtre liste '
        'les ventes les plus récentes, cinquante par page, avec un bouton '
        'Actualiser et un bouton Page précédente pour les pages plus '
        'anciennes.',
    'pos_history.s1.warn1':
        'L\u2019historique est une liste des plus récentes — sans filtre de '
        'date ni recherche par numéro de ticket dans cette version.',
    'pos_history.s2.heading': 'Détails d\u2019une vente',
    'pos_history.s2.p1':
        'Sélectionner une ligne ouvre la vente complète : numéro de ticket, '
        'date et statut, chaque ligne avec sa quantité et son prix, les '
        'totaux, le mode de paiement et le client s\u2019il y en a un.',
    'pos_history.s3.heading': 'Actions sur une vente',
    'pos_history.s3.step1': 'Copier le numéro de ticket dans le presse-papiers.',
    'pos_history.s3.step2': 'Réimprimer ou imprimer le ticket.',
    'pos_history.s3.step3':
        'Créer un retour pour la vente (nécessite la permission de retour).',
    'pos_history.s3.step4':
        'Annuler la vente avec une raison obligatoire (nécessite la '
        'permission d\u2019annulation).',

    'pos_shortcuts.title': 'Raccourcis clavier',
    'pos_shortcuts.summary': 'La liste complète des raccourcis vérifiés.',
    'pos_shortcuts.s1.heading': 'Raccourcis globaux',
    'pos_shortcuts.s1.step1': 'F1 — ouvrir le Point de vente.',
    'pos_shortcuts.s1.step2': 'F2 — ouvrir Produits.',
    'pos_shortcuts.s1.step3':
        'F3 ou Ctrl+N — ajouter un produit (nécessite la permission créer).',
    'pos_shortcuts.s1.step4': 'F4 ou Ctrl+F — placer le curseur dans la recherche.',
    'pos_shortcuts.s1.step5':
        'F5 — actualiser la liste courante, jamais le panier.',
    'pos_shortcuts.s1.step6':
        'Échap — fermer une fenêtre, ou vider le champ de recherche.',
    'pos_shortcuts.s2.heading': 'Raccourcis du Point de vente',
    'pos_shortcuts.s2.step1': 'Entrée — ajouter le produit scanné ou recherché.',
    'pos_shortcuts.s2.step2': 'F6 — choisir le client.',
    'pos_shortcuts.s2.step3': 'F7 — remise sur la facture.',
    'pos_shortcuts.s2.step4': 'ESPACE — ouvrir le paiement.',
    'pos_shortcuts.s2.step5': 'F9 — mettre la vente en attente.',
    'pos_shortcuts.s2.step6': 'F10 — ouvrir les ventes en attente.',
    'pos_shortcuts.s2.step7': 'F11 — ouvrir l\u2019historique des ventes.',
    'pos_shortcuts.s2.step8': 'F12 — vider le panier (avec confirmation).',
    'pos_shortcuts.s2.step9':
        'Plus / moins / astérisque — ajouter un, retirer un, ou saisir une '
        'quantité.',
    'pos_shortcuts.s2.tip1':
        'La même liste est toujours disponible depuis le bouton point '
        'd\u2019interrogation de la barre supérieure.',

    'pos_returns.title': 'Mode retour',
    'pos_returns.summary':
        'Enregistrer un retour pour les articles actuellement dans le panier.',
    'pos_returns.s1.heading': 'Entrer en mode retour',
    'pos_returns.s1.p1':
        'Avec des articles dans le panier, un bouton Retour apparaît si '
        'votre compte a la permission de retour. Il bascule le panier en '
        'mode retour, signalé par une bannière — les lignes ne sont pas '
        'modifiées.',
    'pos_returns.s2.heading': 'Confirmer le retour',
    'pos_returns.s2.p1':
        'En mode retour, le bouton de paiement devient « Confirmer le '
        'retour » et ESPACE confirme au lieu d\u2019ouvrir le paiement. La '
        'mise en attente est désactivée pendant un retour.',
    'pos_returns.s2.step1':
        'Ajustez les quantités que vous retournez, si nécessaire.',
    'pos_returns.s2.step2':
        'Appuyez sur Confirmer le retour et vérifiez le résultat.',
    'pos_returns.s2.warn1':
        'Une ligne de panier contenant un pack à un endroit bloqué — les '
        'retours de packs ne sont pas pris en charge depuis cet écran.',
    'pos_returns.s3.heading': 'Et ensuite',
    'pos_returns.s3.p1':
        'Le retour est envoyé une seule fois, en sécurité : si le serveur ne '
        'confirme pas, le panier et le mode sont conservés pour réessayer. '
        'En cas de succès, un message montre le montant remboursé.',

    // ------------------------------------------------------------------
    // Chapitre 4 — Produits et catalogue
    // ------------------------------------------------------------------
    'chapter.products.title': 'Produits et catalogue',
    'cat_basics.title': 'Créer et modifier des produits',
    'cat_basics.summary':
        'Ajoutez des produits, organisez-les par catégories et '
        'retrouvez-les vite.',
    'cat_basics.s1.heading': 'Créer un produit',
    'cat_basics.s1.p1':
        'Ouvrez Produits (F2) et utilisez le bouton d\u2019ajout. Un produit '
        'exige au minimum un nom et un prix ; code-barres, SKU, '
        'catégorie, unité, seuil de stock bas, taux de TVA, description '
        'et date de péremption sont facultatifs.',
    'cat_basics.s1.step1':
        'Saisissez le nom, puis le prix de vente. Le champ coût (et la '
        'ligne bénéfice/marge en direct) requiert la permission de '
        'modification des produits.',
    'cat_basics.s1.step2':
        'Scannez ou tapez un code-barres si vous en utilisez — les '
        'douchettes fonctionnent au clavier dans tout le formulaire.',
    'cat_basics.s1.step3':
        'Choisissez une catégorie, ou ouvrez Gérer les catégories pour '
        'en créer une d\u2019abord.',
    'cat_basics.s1.step4':
        'Définissez le seuil de stock bas (5 par défaut) pour signaler '
        'le stock bas sur le tableau de bord et l\u2019écran de stock.',
    'cat_basics.s2.heading': 'Modifier et quantité',
    'cat_basics.s2.p1':
        'Modifier rouvre le même formulaire. Sur un produit existant, le '
        'champ quantité est en lecture seule sauf si vous avez aussi la '
        'permission d\u2019ajustement de stock ; le changer enregistre alors un '
        'ajustement avec le motif « Mise à jour du stock produit ».',
    'cat_basics.s2.p2':
        'Les produits ne sont jamais supprimés. L\u2019archivage masque un '
        'produit du PDV et de la liste active tout en gardant son '
        'historique ; les produits archivés restent visibles sous le '
        'filtre Archivé.',
    'cat_basics.s3.heading': 'Recherche et filtres',
    'cat_basics.s3.p1':
        'La barre d\u2019outils recherche par nom, code-barres ou SKU en '
        'écrivant. Les filtres couvrent le statut (actif / archivé / '
        'tous) et la catégorie, avec un tri par nom, prix ou quantité. '
        'Des pages de 20 à 100 lignes sont disponibles.',
    'cat_basics.s3.tip1':
        'Sélectionnez des lignes et utilisez Imprimer les étiquettes '
        'pour les produits choisis.',

    'cat_children.title': 'Unités de vente, unités d\u2019achat et variantes',
    'cat_children.summary':
        'Vendez le même produit à la pièce, à la boîte ou par variante.',
    'cat_children.s1.heading': 'Unités de vente',
    'cat_children.s1.p1':
        'Une unité de vente permet de vendre un même produit sous une '
        'autre présentation, par exemple la pièce et la boîte. Chaque '
        'unité a un nom, un type (pièce, kg, litre…), un multiplicateur '
        'et son propre prix de vente.',
    'cat_children.s1.step1':
        'Ouvrez Gérer les unités de vente depuis le formulaire produit.',
    'cat_children.s1.step2':
        'Exactement une unité doit être l\u2019unité de base avec le '
        'multiplicateur 1 ; elle est toujours proposée en premier au '
        'PDV.',
    'cat_children.s1.step3':
        'Laissez le prix d\u2019une unité vide pour hériter du prix du produit, '
        'ou fixez un prix spécifique par unité.',
    'cat_children.s1.warn1':
        'La tarification en gros ne s\u2019applique jamais aux unités de vente '
        'personnalisées — uniquement à l\u2019unité de base.',
    'cat_children.s2.heading': 'Unités d\u2019achat',
    'cat_children.s2.p1':
        'Les unités d\u2019achat décrivent comment vous achetez le produit (par '
        'exemple un carton de 24). Elles portent un multiplicateur et un '
        'drapeau par défaut facultatif, mais pas de prix de vente — le '
        'coût vit sur les documents d\u2019achat.',
    'cat_children.s3.heading': 'Variantes',
    'cat_children.s3.p1':
        'Les variantes sont des versions nommées d\u2019un produit (taille, '
        'couleur…). Chaque variante a son propre code-barres, son stock '
        'et des dépassements de prix et de coût facultatifs ; un produit '
        'à variante unique est choisi automatiquement au PDV.',
    'cat_children.s3.p2':
        'Les variantes et unités sont archivées, jamais supprimées, et '
        'la seule unité de vente de base ne peut être retirée.',

    'cat_pricing.title': 'Tarification en gros et promotions',
    'cat_pricing.summary':
        'Prix de gros sur l\u2019unité de base et promotions en magasin.',
    'cat_pricing.s1.heading': 'Prix de gros',
    'cat_pricing.s1.p1':
        'Sur le formulaire produit, la section Gros prend un prix de gros '
        'et une quantité minimale. Les deux doivent être remplis ensemble '
        '(ou laissés vides ensemble).',
    'cat_pricing.s1.p2':
        'Au PDV, dès que la quantité en unités de base atteint le '
        'minimum, la ligne passe au prix de gros et affiche une étiquette '
        'de gros. Le seuil compte en unités de base.',
    'cat_pricing.s2.heading': 'Promotions',
    'cat_pricing.s2.p2':
        'Une promotion active s\u2019applique automatiquement au PDV quand la '
        'ligne utilise le prix de détail et l\u2019unité de base. Les lignes '
        'avec une unité personnalisée, un prix explicite ou un pack ne '
        'sont jamais promues automatiquement.',
    'cat_pricing.s2.p1':
        'L\u2019écran Promotions crée des promotions en pourcentage ou à prix '
        'fixe sur un ensemble choisi de produits. Les promotions peuvent '
        'être activées ou désactivées sans être supprimées.',
    'cat_pricing.s2.warn1':
        'Pas de dates de début ou de fin dans cette version — elles '
        's\u2019appliquent tant qu\u2019elles sont actives.',

    // ------------------------------------------------------------------
    // Chapitre 5 — Inventaire et stock
    // ------------------------------------------------------------------
    'chapter.inventory.title': 'Inventaire et stock',
    'inv_levels.title': 'Niveaux de stock et statuts',
    'inv_levels.summary':
        'Voir ce qui est en stock, ce qui est bas et ce qui est épuisé.',
    'inv_levels.s1.heading': 'L\u2019écran de stock',
    'inv_levels.s1.p1':
        'L\u2019écran Inventaire liste chaque produit avec sa quantité, son '
        'coût moyen, la valeur du stock et son statut. Les cartes '
        'résumées affichent la valeur totale du stock, le nombre de '
        'produits et le nombre de produits en stock bas et épuisés.',
    'inv_levels.s1.p2':
        'Un produit est Épuisé à quantité 0 ou moins, et Stock bas à '
        'son seuil de stock bas ou moins. La recherche, un filtre de '
        'statut et un interrupteur « stock bas seulement » réduisent la '
        'liste.',
    'inv_levels.s2.heading': 'Détail produit',
    'inv_levels.s2.p1':
        'Sélectionner un produit ouvre son panneau : quantité actuelle, '
        'coût moyen (PMP), valeur du stock, variantes, unités d\u2019achat et '
        'les derniers mouvements.',
    'inv_levels.s2.tip1':
        'Le même seuil défini sur le produit pilote la carte « Stock '
        'bas » du tableau de bord et les statuts de cet écran.',

    'inv_adjust.title': 'Ajustements de stock',
    'inv_adjust.summary':
        'Corrigez le stock à la main avec un motif audité.',
    'inv_adjust.s1.heading': 'Faire un ajustement',
    'inv_adjust.s1.step1':
        'Ouvrez Inventaire, trouvez le produit et appuyez sur Ajuster '
        '(requiert la permission d\u2019ajustement de stock).',
    'inv_adjust.s1.step2':
        'Choisissez l\u2019opération : augmenter, diminuer, ou fixer à une '
        'quantité exacte.',
    'inv_adjust.s1.step3':
        'Saisissez la quantité. Diminuer et Fixer exigent un motif ; '
        'augmenter enregistre un motif par défaut si vous le laissez '
        'vide.',
    'inv_adjust.s1.step4':
        'Ajoutez éventuellement un coût unitaire — il met à jour le coût '
        'moyen (PMP) en augmentant le stock — puis confirmez. La '
        'nouvelle quantité est prévisualisée avant validation.',
    'inv_adjust.s2.heading': 'Règles',
    'inv_adjust.s2.p1':
        'Les ajustements sont uniquement en unité de base du produit. '
        'Le stock ne peut pas passer sous zéro sauf si le produit '
        'l\u2019autorise. Les diminutions ne changent jamais le coût moyen.',
    'inv_adjust.s2.p2':
        'Chaque ajustement écrit un mouvement immuable dans le journal, '
        'avec qui l\u2019a fait, quand et pourquoi.',
    'inv_adjust.s2.warn1':
        'Créer un produit avec une quantité initiale enregistre aussi un '
        'mouvement : les nouveaux produits n\u2019apparaissent jamais « de '
        'rien ».',

    'inv_movements.title': 'Historique des mouvements et diagnostic',
    'inv_movements.summary':
        'Tracez chaque changement : ventes, achats, retours, '
        'ajustements.',
    'inv_movements.s1.heading': 'Le journal des mouvements',
    'inv_movements.s1.p1':
        'L\u2019onglet Historique des mouvements liste chaque changement de '
        'stock dans le magasin, du plus récent au plus ancien. Filtrez '
        'par type : vente, achat, retour, ajustement, réception de pack '
        'et déballage.',
    'inv_movements.s1.p2':
        'Chaque ligne montre le changement de quantité signé, le coût '
        'unitaire, le coût moyen après le changement, le motif, '
        'l\u2019utilisateur, l\u2019appareil et le document source le cas échéant.',
    'inv_movements.s2.heading': 'Diagnostiquer un écart',
    'inv_movements.s2.step1':
        'Ouvrez les mouvements du produit (panneau de détail ou journal '
        'filtré sur ce produit).',
    'inv_movements.s2.step2':
        'Associez chaque changement récent à un événement connu : vente, '
        'achat reçu, retour ou ajustement manuel.',
    'inv_movements.s2.step3':
        'Si quelque chose cloche, corrigez par un ajustement avec un '
        'motif clair — le journal garde l\u2019erreur et la correction.',
    'inv_movements.s2.tip1':
        'Les ventes annulées apparaissent comme type de mouvement '
        'propre : une annulation restaure toujours le stock de façon '
        'visible.',

    // ------------------------------------------------------------------
    // Chapitre 6 — Achats et fournisseurs
    // ------------------------------------------------------------------
    'chapter.purchasing.title': 'Achats et fournisseurs',
    'purch_suppliers.title': 'Gérer les fournisseurs',
    'purch_suppliers.summary':
        'Fiches fournisseurs, soldes et paiements.',
    'purch_suppliers.s1.heading': 'Fiches fournisseurs',
    'purch_suppliers.s1.p1':
        'L\u2019écran Fournisseurs enregistre le nom, le téléphone, '
        'l\u2019adresse, l\u2019e-mail, le contact et les notes de chaque '
        'fournisseur. Le solde affiché est en lecture seule — il est '
        'calculé à partir des achats et des paiements, jamais tapé.',
    'purch_suppliers.s2.heading': 'Paiements et solde',
    'purch_suppliers.s2.p1':
        'Recevoir un achat augmente le solde du fournisseur du montant '
        'non payé à la réception. Enregistrer un paiement le diminue ; '
        'vous ne pouvez pas payer plus que le solde actuel.',
    'purch_suppliers.s2.p2':
        'Le grand livre du fournisseur liste chaque facture d\u2019achat, '
        'paiement et annulation dans l\u2019ordre.',
    'purch_suppliers.s2.warn1':
        'Un fournisseur ne peut pas être archivé tant qu\u2019un solde reste '
        '— soldez ou annulez d\u2019abord.',
    'purch_suppliers.s3.heading': 'Permissions',
    'purch_suppliers.s3.p1':
        'Voir les fournisseurs requiert la permission fournisseur-'
        'affichage ; créer, modifier et archiver requièrent gestion '
        'fournisseurs.',

    'purch_docs.title': 'Documents d\u2019achat et réception',
    'purch_docs.summary':
        'Rédigez un achat, recevez-le en stock et annulez-le en sécurité.',
    'purch_docs.s1.heading': 'Créer un achat',
    'purch_docs.s1.step1':
        'Ouvrez Achats et créez un document : choisissez le fournisseur, '
        'puis ajoutez des lignes produit avec quantité et coût '
        'unitaire.',
    'purch_docs.s1.step2':
        'Les lignes peuvent utiliser une unité d\u2019achat (par exemple un '
        'carton de 24) ; la quantité est alors en paquets entiers, et '
        'l\u2019équivalent de base est affiché.',
    'purch_docs.s1.step3':
        'Enregistrez en brouillon pour continuer à modifier, ou '
        'Enregistrer et recevoir pour finir en une étape.',
    'purch_docs.s4.heading': 'Coût unitaire ou coût total',
    'purch_docs.s4.p1':
        'Chaque ligne enregistre le coût de l\u2019unité d\u2019achat. Par '
        'défaut, le montant saisi est ce coût unitaire. Activez « Coût '
        'total » lorsque le fournisseur annonce un montant unique pour '
        'toute la ligne : l\u2019application le divise par la quantité '
        'saisie et affiche le coût unitaire dérivé avant '
        'l\u2019enregistrement.',
    'purch_docs.s4.p2':
        'Les cartons sont convertis comme d\u2019habitude. Exemple : 10 '
        'cartons de 5 pièces pour un coût total de 100 DA → 10 DA par '
        'carton, 2 DA par pièce ; la réception ajoute 50 pièces au stock '
        'valorisées à 2 DA la pièce. Avec « Coût total » désactivé, 100 '
        'DA reste le prix du carton (20 DA la pièce).',
    'purch_docs.s4.tip1':
        'L\u2019aperçu de la ligne (quantité totale, coût unitaire, total) '
        'se met à jour en direct ; c\u2019est un aperçu de calcul uniquement '
        '— rien n\u2019est enregistré ni ajouté au stock avant '
        'l\u2019enregistrement (et la réception) de l\u2019achat.',
    'purch_docs.s2.heading': 'Ce que fait la réception',
    'purch_docs.s2.p1':
        'La réception est une action atomique : les quantités de stock '
        'augmentent, le coût moyen est mis à jour, le solde du '
        'fournisseur augmente du montant impayé, et le document devient '
        'reçu.',
    'purch_docs.s2.p2':
        'La date d\u2019achat est fixée par le serveur à la création — elle '
        'ne peut pas être antidatée.',
    'purch_docs.s3.heading': 'Annuler et supprimer',
    'purch_docs.s3.p1':
        'Annuler un achat reçu inverse ses effets sur le stock et le '
        'solde. Seuls les brouillons peuvent être supprimés. Les '
        'documents reçus et annulés sont autrement immuables.',
    'purch_docs.s3.warn1':
        'Pas de retours d\u2019achat ni de taxe sur les documents d\u2019achat dans '
        'cette version — annulez et ressaisissez si quelque chose '
        'cloche.',

    // ------------------------------------------------------------------
    // Chapitre 7 — Clients, ventes à crédit et dettes
    // ------------------------------------------------------------------
    'chapter.customers.title': 'Clients, ventes à crédit et dettes',
    'cust_records.title': 'Fiches clients',
    'cust_records.summary':
        'Noms, coordonnées, plafonds de dette et soldes.',
    'cust_records.s1.heading': 'Champs client',
    'cust_records.s1.p1':
        'Un client a un nom (obligatoire), un téléphone, une adresse et '
        'un plafond de dette facultatif. Le solde est en lecture seule '
        'et tenu par les ventes et les paiements.',
    'cust_records.s2.heading': 'Plafond de dette',
    'cust_records.s2.p1':
        'Le plafond de dette est le total maximal qu\u2019un client peut '
        'devoir. Un plafond de 0 signifie illimité. Le serveur '
        'l\u2019applique : une vente à crédit ou partielle qui le '
        'dépasserait est refusée avec une explication.',
    'cust_records.s2.warn1':
        'Un client avec un solde dû ne peut pas être archivé.',
    'cust_records.s3.heading': 'Permissions',
    'cust_records.s3.p1':
        'L\u2019écran Clients requiert client-affichage ; créer, modifier et '
        'archiver requièrent gestion clients.',

    'cust_debts.title': 'Ventes à crédit et paiements de dettes',
    'cust_debts.summary':
        'Vendez à crédit au PDV, puis encaissez et suivez les '
        'paiements.',
    'cust_debts.s1.heading': 'Une vente à crédit',
    'cust_debts.s1.p1':
        'Au PDV, choisissez le client (F6), ouvrez le paiement, puis '
        'sélectionnez Partiel (payer une partie, le reste en dette) ou '
        'Crédit (montant entier en dette). Les deux requièrent la '
        'permission de vente à crédit et un client sélectionné.',
    'cust_debts.s1.p2':
        'Si le montant pousserait le client au-delà de son plafond, la '
        'vente est refusée avant tout enregistrement.',
    'cust_debts.s2.heading': 'Enregistrer des paiements',
    'cust_debts.s2.p1':
        'L\u2019écran Dettes liste les clients avec soldes dus et totaux '
        'résumés. Depuis un client, vous pouvez enregistrer un '
        'paiement ; vous ne pouvez pas payer plus que le solde, et '
        'chaque paiement est idempotent.',
    'cust_debts.s2.p2':
        'La dette de chaque client liste chaque vente ayant créé de la '
        'dette et chaque paiement l\u2019ayant réduite.',
    'cust_debts.s3.heading': 'Limites',
    'cust_debts.s3.p1':
        'Pas d\u2019extraits de compte clients imprimés ni de rappels '
        'automatiques dans cette version. Utilisez l\u2019historique de dette '
        'par client comme relevé.',

    // ------------------------------------------------------------------
    // Chapitre 8 — Fidélité (Phase F)
    // ------------------------------------------------------------------
    'chapter.loyalty.title': 'Fidélité',
    'loy_overview.title': 'Points et cashback : vue d\u2019ensemble',
    'loy_overview.summary':
        'Comment les clients gagnent et dépensent leurs récompenses.',
    'loy_overview.s1.heading': 'Ce que fait la fidélité',
    'loy_overview.s1.p1':
        'Le programme de fidélité permet aux clients de gagner des '
        'points et/ou du cashback sur leurs achats, puis d\u2019utiliser ces '
        'récompenses sur des ventes ultérieures. Les points sont '
        'gagnés par unité monétaire dépensée selon le taux de points '
        'du magasin ; le cashback s\u2019accumule comme un solde monétaire '
        'au taux de cashback du magasin. Tous les 100 points ouvrent '
        'une récompense, qui donne un pourcentage de remise sur une '
        'vente — les points en eux-mêmes ne sont jamais de l\u2019argent.',
    'loy_overview.s1.p2':
        'Chaque client a un compte de fidélité unique portant les deux '
        'soldes. Les comptes sont individuels (identifiés par téléphone '
        'à la caisse), et les soldes — y compris le nombre de '
        'récompenses complètes qu\u2019ils ouvrent — sont toujours calculés '
        'par le serveur : aucun écran ne les enregistre ni ne les '
        'recalcule.',
    'loy_overview.s2.heading': 'Autorisations',
    'loy_overview.s2.p1':
        'Le gain et l\u2019utilisation se déroulent dans le flux de vente '
        'habituel et suivent donc les autorisations de vente. Voir le '
        'solde ou l\u2019historique d\u2019un client nécessite l\u2019affichage clients ; '
        'modifier les règles de fidélité nécessite l\u2019autorisation des '
        'paramètres de fidélité.',

    'loy_settings.title': 'Paramètres de fidélité',
    'loy_settings.summary':
        'Activer le gain, fixer les taux et fixer la remise maximale '
        'de récompense.',
    'loy_settings.s1.heading': 'Configurer les règles',
    'loy_settings.s1.p1':
        'La fidélité se configure une fois pour tout le magasin depuis '
        'l\u2019écran des paramètres de fidélité. Les deux récompenses '
        'peuvent être activées indépendamment et l\u2019une ou l\u2019autre peut '
        'être désactivée à tout moment.',
    'loy_settings.s1.step1':
        'Activez les points, le cashback, ou les deux, et fixez leurs '
        'taux.',
    'loy_settings.s1.step2':
        'Fixez la remise maximale de récompense — le pourcentage le '
        'plus élevé qu\u2019une seule récompense puisse déduire d\u2019une '
        'vente (0 à 100).',
    'loy_settings.s1.step3':
        'Si vous le souhaitez, activez le gain sur règlement de dette '
        'pour que le client gagne en remboursant un crédit.',
    'loy_settings.s2.heading': 'Limite de remise de récompense',
    'loy_settings.s2.p1':
        'Une seule règle régit l\u2019utilisation des récompenses : le '
        'pourcentage maximal du montant d\u2019une vente qu\u2019une seule '
        'récompense peut déduire. Il va de 0 à 100 ; le mettre à 0 '
        'suspend l\u2019utilisation des récompenses tout en continuant à '
        'gagner.',
    'loy_settings.s2.warn1':
        'Les changements de taux ne s\u2019appliquent qu\u2019aux ventes '
        'futures. Les soldes déjà gagnés conservent leur valeur '
        'd\u2019origine.',

    'loy_earning.title': 'Gagner des récompenses',
    'loy_earning.summary':
        'Points et cashback s\u2019ajoutent sur les ventes et les règlements '
        'de dette.',
    'loy_earning.s1.heading': 'Sur les ventes',
    'loy_earning.s1.p1':
        'Lorsqu\u2019un client est sélectionné à la caisse, une vente '
        'terminée crédite des points et/ou du cashback selon les '
        'montants réellement payés. Les ventes annulées ne gagnent '
        'rien ; un retour intégral d\u2019une vente annule aussi ce que '
        'cette vente avait gagné — les récompenses suivent donc '
        'toujours le net des ventes effectivement conservées.',
    'loy_earning.s2.heading': 'Sur le règlement de dette',
    'loy_earning.s2.p1':
        'Quand l\u2019option de gain sur règlement de dette est active, '
        'enregistrer un paiement de dette génère aussi des points et '
        'du cashback sur le montant réellement appliqué à la dette — '
        'payer plus tard récompense donc toujours le client équitablement.',

    'loy_redeem.title': 'Utiliser les récompenses',
    'loy_redeem.summary':
        'Transformer 100 points en pourcentage de remise à la caisse.',
    'loy_redeem.s1.heading': 'Utiliser une récompense à la caisse',
    'loy_redeem.s1.step1':
        'Sélectionnez le client (F6) avant ou pendant la vente.',
    'loy_redeem.s1.step2':
        'Au paiement, choisissez le pourcentage de récompense dans le '
        'sélecteur de fidélité : il ne propose que les pourcentages '
        'jusqu\u2019au maximum configuré par le magasin, et il n\u2019apparaît '
        'que si le client détient au moins une récompense (100 '
        'points). L\u2019aperçu montre la remise exacte et le montant '
        'restant à payer.',
    'loy_redeem.s1.step3':
        'Confirmez — le serveur applique la remise à la vente, '
        'consomme exactement 100 points pour cette récompense, et le '
        'reste à payer baisse en conséquence.',
    'loy_redeem.s1.p1':
        'L\u2019écran n\u2019envoie jamais que le pourcentage choisi. Le '
        'serveur vérifie que le client détient une récompense, que le '
        'pourcentage est dans le maximum configuré, recalcule la '
        'remise sur la vente elle-même, et revérifie tout au moment '
        'de la vente — aucun message écran ne peut donc réclamer une '
        'remise plus grande ni dépenser des points que le client '
        'n\u2019a pas.',
    'loy_redeem.s2.heading': 'Retours et annulations',
    'loy_redeem.s2.warn1':
        'Retourner des articles d\u2019une vente ayant utilisé une '
        'récompense restaure la part correspondante de la remise et '
        'les points correspondants ; annuler une telle vente restaure '
        'la remise complète et ses 100 points. Les points ne reviennent '
        'que dans la mesure où le client les détient encore ; un '
        'manquant peut rester s\u2019ils ont été dépensés entre-temps.',

    'loy_report.title': 'Le rapport de fidélité',
    'loy_report.summary':
        'Activité de période, soldes actuels et grand livre complet.',
    'loy_report.s1.heading': 'Vue d\u2019ensemble',
    'loy_report.s1.p1':
        'L\u2019onglet Fidélité des rapports répond à deux questions pour '
        'toute période : quelles récompenses y ont circulé, et ce que '
        'le magasin doit actuellement à ses clients. Il affiche le '
        'contexte des ventes à côté des chiffres de récompenses pour '
        'les lire ensemble.',
    'loy_report.s2.heading': 'Sections du rapport',
    'loy_report.s2.p1':
        'Le rapport comporte quatre zones : contexte des ventes (ventes '
        'brutes et factures, mêmes chiffres que le rapport financier), '
        'activité de la période (points et cashback gagnés, remises de '
        'récompense appliquées, annulées, restaurées et manques non '
        'récupérés), soldes actuels (points et cashback en circulation, '
        'plus le nombre de clients ayant un solde), et le grand livre '
        'des événements — un historique paginé, client par client, de '
        'chaque mouvement de récompense.',
    'loy_report.s2.warn1':
        'Les soldes sont des totaux actuels, pas des chiffres de '
        'période : ils reflètent chaque compte tel qu\u2019il est maintenant, '
        'quelle que soit la plage de dates choisie.',
    'loy_report.s3.heading': 'Accès et export',
    'loy_report.s3.p1':
        'Voir le rapport de fidélité nécessite l\u2019autorisation des '
        'rapports financiers — le même périmètre que tous les autres '
        'onglets de rapports. Les filtres période et appareil partagés '
        's\u2019appliquent, et le rapport s\u2019exporte via les mêmes flux '
        'CSV / XLSX / PDF que les autres onglets.',

    // ------------------------------------------------------------------
    // Chapitre 9 — Dépenses et opérations financières
    // ------------------------------------------------------------------
    'chapter.expenses.title': 'Dépenses et opérations financières',
    'exp_manage.title': 'Enregistrer et annuler des dépenses',
    'exp_manage.summary':
        'Suivez les dépenses du magasin ; les corrections se font par '
        'annulation et nouvelle création.',
    'exp_manage.s1.heading': 'Enregistrer une dépense',
    'exp_manage.s1.step1':
        'Ouvrez Dépenses et ajoutez une dépense : catégorie, montant, '
        'titre et note facultatifs.',
    'exp_manage.s1.step2':
        'L\u2019interrupteur Payé de la caisse classe la dépense comme payée '
        'de la caisse ou en externe ; c\u2019est un libellé, pas un '
        'mouvement de caisse.',
    'exp_manage.s1.step3':
        'Les catégories sont une liste fixe : loyer, services, '
        'salaires, entretien, fournitures, transport, autre.',
    'exp_manage.s2.heading': 'Corrections',
    'exp_manage.s2.p1':
        'Les dépenses ne peuvent pas être modifiées ni supprimées. Pour '
        'en corriger une, annulez-la avec un motif obligatoire, puis '
        'créez une nouvelle dépense correcte. Les lignes annulées '
        'restent dans la liste avec leur motif et qui les a annulées.',
    'exp_manage.s3.heading': 'Dans les rapports',
    'exp_manage.s3.p1':
        'Les dépenses alimentent la carte « Dépenses du jour » du '
        'tableau de bord et le rapport financier, où elles réduisent le '
        'bénéfice net et se répartissent entre caisse et externe. Les '
        'deux nécessitent la permission rapports financiers.',
    'exp_manage.s3.warn1':
        'La date de dépense est fixée par le serveur et ne peut pas '
        'être antidatée.',

    // ------------------------------------------------------------------
    // Chapitre 10 — Facturation
    // ------------------------------------------------------------------
    'chapter.facturation.title': 'Facturation',
    'fac_types.title': 'Types de documents et création',
    'fac_types.summary':
        'Documents FAC, DEV, PRO, BC et BL : ce qu\u2019ils sont et comment en '
        'créer un.',
    'fac_types.s1.heading': 'Les cinq types de documents',
    'fac_types.s1.step1': 'FAC — facture client.',
    'fac_types.s1.step2': 'DEV — avoir (note de crédit).',
    'fac_types.s1.step3': 'PRO — devis.',
    'fac_types.s1.step4': 'BC — bon de commande.',
    'fac_types.s1.step5': 'BL — bon de livraison.',
    'fac_types.s2.heading': 'Créer un document',
    'fac_types.s2.p1':
        'Ouvrez Facturation, choisissez le type, puis sélectionnez un '
        'client. Chaque document exige un client. Ajoutez des lignes : '
        'les lignes liées à un produit préremplissent prix et TVA ; les '
        'lignes en texte libre exigent une description, un prix et un '
        'taux de TVA.',
    'fac_types.s2.p2':
        'La numérotation est automatique par type et par année, par '
        'exemple FAC-2026-0004. Les numéros ne changent jamais.',
    'fac_types.s2.tip1':
        'Les factures peuvent aussi être créées depuis les clients '
        'facture — une liste dédiée distincte des clients PDV.',

    'fac_totals.title': 'TVA, timbre et totaux',
    'fac_totals.summary':
        'Comment sont calculés net, TVA, total et timbre sur un '
        'document.',
    'fac_totals.s1.heading': 'TVA',
    'fac_totals.s1.p1':
        'Chaque ligne porte un taux de TVA de 0 %, 9 % ou 19 %. Le '
        'serveur calcule les totaux à partir des montants bruts des '
        'lignes — ne faites jamais confiance à un total tapé à la '
        'main.',
    'fac_totals.s2.heading': 'Timbre fiscal',
    'fac_totals.s2.p1':
        'Sur les factures au comptant (FAC payée en cash), un timbre '
        'peut s\u2019appliquer avec l\u2019interrupteur timbre : 0 jusqu\u2019à un total '
        'de 300 DA, puis un pourcentage croissant avec un minimum de 5 '
        'DA quand il s\u2019applique. Le montant à payer devient total plus '
        'timbre.',
    'fac_totals.s2.p2':
        'La ligne de timbre n\u2019apparaît que si elle est activée et que le '
        'montant est supérieur à zéro. Elle n\u2019est pas utilisée sur les '
        'ventes PDV.',
    'fac_totals.s2.warn1':
        'Les totaux sont toujours recalculés par le serveur ; '
        'l\u2019aperçu montre les chiffres faisant foi.',

    'fac_pdf_post.title': 'PDF, enregistrement en vente et immuabilité',
    'fac_pdf_post.summary':
        'Aperçu, export PDF et enregistrement d\u2019une facture comme vente '
        'réelle.',
    'fac_pdf_post.s1.heading': 'Aperçu et PDF',
    'fac_pdf_post.s1.p1':
        'Le formulaire de facture montre un aperçu A4 en direct du '
        'serveur. Depuis un document enregistré, vous pouvez '
        'télécharger la même mise en page en PDF.',
    'fac_pdf_post.s2.heading': 'Enregistrer comme vente',
    'fac_pdf_post.s2.p1':
        'Une FAC peut être enregistrée comme vente réelle de type PDV : '
        'le stock bouge, les rapports de ventes se mettent à jour, et '
        'le document est lié à la vente créée. Chaque ligne doit '
        'référencer un produit ou pack — les lignes en texte libre ne '
        'peuvent pas être enregistrées.',
    'fac_pdf_post.s2.p2':
        'Utilisez l\u2019interrupteur Enregistrer comme vente à la création, '
        'ou enregistrez plus tard depuis le document. L\u2019enregistrement '
        'requiert facturation-gestion (et permission de vente si fait '
        'séparément) et est idempotent.',
    'fac_pdf_post.s3.heading': 'Immuabilité',
    'fac_pdf_post.s3.p1':
        'Les documents ne sont jamais supprimés. Une fois enregistrés, '
        'le client, le paiement et les lignes sont verrouillés ; les '
        'notes et drapeaux d\u2019affichage restent modifiables. Le numéro, '
        'le type, l\u2019année et la date ne changent jamais.',

    // ------------------------------------------------------------------
    // Chapitre 11 — Rapports et exports
    // ------------------------------------------------------------------
    'chapter.reports.title': 'Rapports et exports',
    'rep_overview.title': 'Les onglets de rapports',
    'rep_overview.summary':
        'Dix vues de rapports et ce que chacune répond.',
    'rep_overview.s1.heading': 'Les onglets',
    'rep_overview.s1.step1':
        'Financier — pertes et profits de la période, avec répartition '
        'par appareil.',
    'rep_overview.s1.step2':
        'Performance produit — ce qui s\u2019est vendu, quantités, revenus et '
        'bénéfice par produit.',
    'rep_overview.s1.step3':
        'Analyse par catégorie — ventes agrégées par catégorie.',
    'rep_overview.s1.step4': 'Journalier et Horaire — chronologies des '
        'ventes.',
    'rep_overview.s1.step5':
        'Heures de pointe — les heures les plus chargées sur une '
        'fenêtre de référence.',
    'rep_overview.s1.step6':
        'Mouvements lents — produits non vendus depuis un nombre de '
        'jours choisi.',
    'rep_overview.s1.step7':
        'Factures annulées — ventes annulées avec motifs.',
    'rep_overview.s1.step8':
        'Détail des ventes — ventes ligne à ligne avec filtres de '
        'statut et de paiement.',
    'rep_overview.s1.step9':
        'Rapport fournisseur — ce qui est dû aux fournisseurs.',
    'rep_overview.s2.heading': 'Accès',
    'rep_overview.s2.p1':
        'Toute la section Rapports requiert la permission rapports '
        'financiers.',

    'rep_exports.title': 'Filtres et exports',
    'rep_exports.summary':
        'Périodes, autres filtres et export CSV / XLSX / PDF.',
    'rep_exports.s1.heading': 'Filtres',
    'rep_exports.s1.p1':
        'Chaque onglet partage les périodes prédéfinies (aujourd\u2019hui, '
        'hier, 7 derniers jours, ce mois-ci et périodes plus longues) '
        'et des dates de début/fin personnalisées. Le détail des ventes '
        'ajoute des filtres de statut et de paiement ; Heures de pointe '
        'et Mouvements lents ont leurs propres paramètres.',
    'rep_exports.s2.heading': 'Exporter',
    'rep_exports.s2.step1':
        'Chargez le rapport, puis appuyez sur Exporter (requiert la '
        'permission d\u2019export de données).',
    'rep_exports.s2.step2':
        'Choisissez CSV (construit sur cette machine), XLSX ou PDF '
        '(généré par le serveur).',
    'rep_exports.s2.step3':
        'Les grands exports sont plafonnés à 50 000 lignes ; réduisez '
        'la période si le serveur refuse la demande.',
    'rep_exports.s2.tip1':
        'Le bouton Rapports du tableau de bord ouvre cette section avec '
        'la même période déjà appliquée.',

    // ------------------------------------------------------------------
    // Chapitre 12 — Impression et reçus
    // ------------------------------------------------------------------
    'chapter.printing.title': 'Impression et reçus',
    'prt_overview.title': 'Reçus, étiquettes et impression de documents',
    'prt_overview.summary':
        'Ce que cette application peut et ne peut pas envoyer à une '
        'imprimante.',
    'prt_overview.s1.heading': 'Impression prise en charge',
    'prt_overview.s1.p1':
        'Les reçus s\u2019impriment via la boîte de dialogue d\u2019impression du '
        'système après une vente (voir aussi le chapitre Point de '
        'vente). Papiers : rouleau 80 mm ou A4, choisis dans les '
        'paramètres du magasin ou au réimpression.',
    'prt_overview.s1.p2':
        'Des étiquettes de prix peuvent être imprimées depuis '
        'l\u2019écran Produits pour les produits sélectionnés. Les documents '
        'de facturation sont exportés en PDF A4.',
    'prt_overview.s2.heading': 'Le flux d\u2019impression',
    'prt_overview.s2.p1':
        'L\u2019impression ouvre la boîte de dialogue système : choisissez une '
        'imprimante ou « Enregistrer en PDF ». Annuler cette boîte ne '
        'fait jamais échouer la vente — la vente reste terminée.',
    'prt_overview.s3.heading': 'Non pris en charge',
    'prt_overview.s3.p1':
        'Le contrôle direct des imprimantes ESC/POS, l\u2019ouverture de '
        'caisse et le matériel d\u2019affichage client ne sont pas intégrés '
        'dans cette version. Utilisez la boîte de dialogue système et '
        'une imprimante compatible avec votre format de papier.',
    'prt_overview.s3.warn1':
        'Si l\u2019impression échoue avec « Imprimante indisponible », le '
        'système ne trouve aucune imprimante utilisable — vérifiez '
        'd\u2019abord la configuration d\u2019impression du système.',

    // ------------------------------------------------------------------
    // Chapitre 13 — Réseau local et multi-PC
    // ------------------------------------------------------------------
    'chapter.lan.title': 'Réseau local et configuration multi-PC',
    'lan_pairing.title': 'Appairage et connexion',
    'lan_pairing.summary':
        'Comment un client trouve le serveur et reste connecté.',
    'lan_pairing.s1.heading': 'Appairer un client',
    'lan_pairing.s1.step1':
        'Sur le client, l\u2019assistant de premier lancement cherche le '
        'serveur sur le réseau local, ou vous pouvez saisir son adresse '
        'manuellement.',
    'lan_pairing.s1.step2':
        'Sur le serveur, un administrateur génère un code d\u2019appairage à '
        'six chiffres depuis l\u2019écran Appareils (valable dix minutes).',
    'lan_pairing.s1.step3':
        'Saisissez le code sur le client ; la demande attend qu\u2019un '
        'administrateur approuve l\u2019appareil.',
    'lan_pairing.s2.heading': 'Rester connecté',
    'lan_pairing.s2.p1':
        'La pastille d\u2019état en haut montre Connecté, Reconnexion, '
        'Déconnecté, ou une alerte de base de données. Les coupures '
        'brèves sont réessayées automatiquement avec des délais '
        'croissants ; le caissier n\u2019est jamais interrompu par une '
        'panne en plein service.',
    'lan_pairing.s2.warn1':
        'Un problème de connexion au démarrage affiche une boîte une '
        'seule fois : réessayez, ou saisissez l\u2019adresse du serveur '
        'manuellement. Les ventes ne sont jamais stockées hors ligne — '
        'le serveur doit être joignable pour terminer une vente.',

    'lan_devices.title': 'Gestion des appareils',
    'lan_devices.summary':
        'Approuvez, refusez et révoquez les appareils clients.',
    'lan_devices.s1.heading': 'L\u2019écran Appareils',
    'lan_devices.s1.p1':
        'Requiert la permission gestion appareils. L\u2019écran affiche le '
        'code d\u2019appairage, les adresses réseau du serveur (tapez pour '
        'copier), puis les appareils en attente et enregistrés.',
    'lan_devices.s1.p2':
        'Chaque appareil montre son identifiant, son statut, sa '
        'dernière adresse IP connue, la version de l\u2019application et '
        'l\u2019heure de dernière vue.',
    'lan_devices.s2.heading': 'Actions',
    'lan_devices.s2.step1':
        'Approuver — autorise un appareil en attente à se connecter '
        '(confirmation requise).',
    'lan_devices.s2.step2': 'Refuser — rejette un appareil en attente.',
    'lan_devices.s2.step3':
        'Révoquer — coupe immédiatement un appareil approuvé ; il doit '
        'réappairer.',
    'lan_devices.s2.warn1':
        'Ne partagez jamais les codes d\u2019appairage ni les adresses du '
        'serveur en dehors du réseau du magasin.',

    // ------------------------------------------------------------------
    // Chapitre 14 — Paramètres, sauvegarde et restauration
    // ------------------------------------------------------------------
    'chapter.settings.title':
        'Paramètres, sauvegarde et restauration',
    'set_general.title':
        'Langue, thème et paramètres du magasin',
    'set_general.summary':
        'Préférences personnelles et configuration du magasin.',
    'set_general.s1.heading': 'Langue et thème',
    'set_general.s1.p1':
        'Paramètres > Langue bascule entre arabe, français et anglais '
        'pour cette machine uniquement. Le thème propose sombre, clair '
        'et gris ; les deux choix sont mémorisés localement.',
    'set_general.s2.heading': 'Paramètres du magasin',
    'set_general.s2.p1':
        'Avec la permission gestion paramètres, vous pouvez définir le '
        'nom, le téléphone et l\u2019adresse du magasin ; le pied de reçu ; '
        'le papier par défaut (80 mm ou A4) ; les interrupteurs '
        'demander-avant-impression et auto-impression ; si les clients '
        'peuvent devoir au PDV ; et le seuil de stock bas par défaut.',
    'set_general.s3.heading': 'Informations société',
    'set_general.s3.p1':
        'La section société enregistre wilaya, e-mail et les '
        'identifiants fiscaux (RC, NIF, AI, NIS) utilisés sur les '
        'documents.',

    'set_backup.title': 'Sauvegarde et restauration',
    'set_backup.summary':
        'Créez des sauvegardes serveur et restaurez-les avec soin.',
    'set_backup.s1.heading': 'Créer une sauvegarde',
    'set_backup.s1.p1':
        'Avec la permission sauvegarde-restauration, la page '
        'Paramètres liste les sauvegardes serveur et propose Créer une '
        'sauvegarde. Ce sont des dumps SQL avec manifeste, stockés sur '
        'le disque du serveur — ils ne sont pas téléchargés sur cette '
        'machine.',
    'set_backup.s2.heading': 'Restaurer',
    'set_backup.s2.p1':
        'Restaurer remplace toute la base de données courante par la '
        'sauvegarde choisie. Une confirmation explique que cela est '
        'irréversible. L\u2019intégrité de chaque fichier est vérifiée avant '
        'application.',
    'set_backup.s2.warn1':
        'Créez une sauvegarde fraîche avant toute restauration. La '
        'restauration est l\u2019action la plus destructive de '
        'l\u2019application.',
    'set_backup.s3.heading': 'Si les outils de sauvegarde manquent',
    'set_backup.s3.p1':
        'Le serveur doit avoir ses outils de dump installés. Si '
        'l\u2019application signale que les outils de sauvegarde manquent, '
        'demandez à qui maintient le serveur de les installer.',

    // ------------------------------------------------------------------
    // Chapitre 15 — Dépannage
    // ------------------------------------------------------------------
    'chapter.troubleshooting.title': 'Dépannage',
    'ts_connection.title': 'Problèmes de connexion et de serveur',
    'ts_connection.summary':
        'Que vérifier quand un client ne rejoint pas le serveur.',
    'ts_connection.s1.heading': 'Client affiche Déconnecté',
    'ts_connection.s1.step1':
        'Vérifiez que le PC du serveur est allumé et le service '
        'démarré.',
    'ts_connection.s1.step2':
        'Vérifiez que les deux machines sont sur le même réseau et '
        'peuvent se joindre.',
    'ts_connection.s1.step3':
        'Surveillez la pastille d\u2019état — elle se reconnecte '
        'automatiquement ; utilisez la saisie manuelle du démarrage '
        'pour repointer le client vers la bonne adresse.',
    'ts_connection.s1.step4':
        'Si la pastille est verte mais que les données échouent, la '
        'base de données du serveur est peut-être indisponible — la '
        'pastille montre une alerte base ; le serveur demande '
        'attention.',
    'ts_connection.s2.heading': 'Connexion refusée après changement de '
        'serveur',
    'ts_connection.s2.p1':
        'Une session expirée vous renvoie à l\u2019écran de connexion — '
        'reconnectez-vous avec votre code. Un serveur remplacé exige '
        'de réappairer l\u2019appareil.',
    'ts_connection.s2.warn1':
        'Ne « réparez » jamais une connexion en réinitialisant la base '
        'ou en désactivant la sécurité. Repointez le client, ou '
        'demandez à un administrateur de réapprouver l\u2019appareil.',

    'ts_print_pdf.title':
        'Problèmes d\u2019impression, de PDF et de recherche',
    'ts_print_pdf.summary':
        'Reçus non imprimés, PDF manquants, produits introuvables.',
    'ts_print_pdf.s1.heading': 'Problèmes d\u2019impression',
    'ts_print_pdf.s1.step1':
        'Une vente terminée n\u2019est jamais perdue pour un échec '
        'd\u2019impression — réimprimez depuis l\u2019historique des ventes (F11) '
        'plutôt que de ressaisir la vente.',
    'ts_print_pdf.s1.step2':
        '« Imprimante indisponible » signifie qu\u2019il n\u2019y a aucune '
        'imprimante utilisable — vérifiez les paramètres d\u2019impression du '
        'système, ou utilisez Enregistrer en PDF.',
    'ts_print_pdf.s1.step3':
        'Pas de reçu après l\u2019encaissement ? Vérifiez les interrupteurs '
        'demander-avant-impression et auto-impression dans les '
        'paramètres du magasin.',
    'ts_print_pdf.s2.heading': 'Produit introuvable par code-barres',
    'ts_print_pdf.s2.step1':
        'Appuyez sur Entrée une fois : une correspondance exacte de '
        'code-barres, de nom ou de SKU est ajoutée directement ; sinon '
        'la première résultat de recherche est ajouté.',
    'ts_print_pdf.s2.step2':
        'Les produits archivés et en rupture sont bloqués avec un '
        'message — vérifiez le statut du produit sur l\u2019écran Produits.',
    'ts_print_pdf.s2.step3':
        'Si le code-barres a été saisi sur un autre appareil, '
        'actualisez (F5) pour que le catalogue soit à jour.',

    'ts_data.title':
        'Problèmes de stock, de dette, de permissions et de mise en '
        'page',
    'ts_data.summary':
        'Chiffres inattendus, boutons manquants et questions d\u2019affichage.',
    'ts_data.s1.heading': 'Stock ou dette semble faux',
    'ts_data.s1.step1':
        'Ouvrez le journal des mouvements (stock) ou l\u2019historique de '
        'dette du client et comparez chaque entrée à des événements '
        'connus.',
    'ts_data.s1.step2':
        'Corrigez le stock par un ajustement avec un motif clair ; '
        'enregistrez un paiement de dette pour les montants trop '
        'encaissés. L\u2019historique garde toujours l\u2019original et la '
        'correction.',
    'ts_data.s2.heading': 'Un bouton ou un écran manque',
    'ts_data.s2.p1':
        'Les écrans et actions suivent les permissions. Si quelque '
        'chose manque, un administrateur peut accorder la permission '
        'correspondante (par exemple ajustement stock, vente à crédit '
        'ou rapports). Pas de menu caché — manquant signifie non '
        'autorisé pour votre rôle.',
    'ts_data.s3.heading': 'Texte ou mise en page incorrects',
    'ts_data.s3.p1':
        'L\u2019arabe se lit de droite à gauche partout ; les versions, '
        'code-barres et numéros de facture restent de gauche à droite '
        'volontairement. Agrandissez la fenêtre si les panneaux '
        'paraissent serrés — l\u2019application s\u2019adapte de la largeur '
        'téléphone jusqu\u2019au bureau complet.',
    'ts_data.s3.tip1':
        'Changements de langue et de thème s\u2019appliquent instantanément '
        'dans Paramètres et n\u2019affectent que cette machine.',
  },
};

/// Resolves [key] for [locale], falling back to English and then to the
/// raw key so a missing translation can never crash the screen.
String docT(String key, String locale) {
  final localized = docContent[locale];
  if (localized != null) {
    final value = localized[key];
    if (value != null) return value;
  }
  return docContent['en']![key] ?? key;
}

/// True when every locale provides a non-empty, non-identical-to-key
/// translation for [key]. Used by tests; also handy when adding Phase 4
/// content.
bool docKeyResolved(String key) {
  for (final locale in ['ar', 'fr', 'en']) {
    final value = docContent[locale]?[key];
    if (value == null || value.isEmpty || value == key) return false;
  }
  return true;
}
