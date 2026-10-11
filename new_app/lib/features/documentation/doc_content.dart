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
