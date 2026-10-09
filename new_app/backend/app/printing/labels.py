"""Localized labels for document/report rendering (Phase 15 §7.4, §9, §10.1).

Server-side mirror of the frozen client keys in `new_app/lib/core/strings.dart`
(report headers come from the Phase 14 CSV contract — same keys, same values).
Keys that exist client-side carry the exact same wording in all 3 locales;
`doc_*`/`pack_marker`/`generated`/`page_*` are new document-only labels.
"""

from __future__ import annotations

DEFAULT_LOCALE = "ar"
LOCALES = ("ar", "fr", "en")

# Currency suffix — identical in all 3 locales (strings.dart `currency`).
CURRENCY = "DA"

LABELS: dict[str, tuple[str, str, str]] = {
    # ---- report titles (sheet name / PDF title) ----
    "report_financial": ("التقرير المالي", "Rapport financier", "Financial report"),
    "report_products": ("أداء المنتجات", "Performance des produits", "Product performance"),
    "report_categories": ("تحليل الفئات", "Analyse des catégories", "Category analysis"),
    "report_daily": ("اليومي", "Quotidien", "Daily"),
    "report_hourly": ("بالساعة", "Par heure", "Hourly"),
    "report_peak_hours": ("أفضل ساعات البيع", "Heures de pointe", "Peak hours"),
    "report_slow_moving": ("المنتجات الراكدة", "Stock dormant", "Slow moving"),
    "report_voided": ("الفواتير الملغاة", "Factures annulées", "Voided invoices"),
    "report_sales": ("تفاصيل المبيعات", "Détail des ventes", "Sales detail"),
    "report_suppliers": ("تقرير الموردين", "Rapport fournisseurs", "Supplier report"),
    # ---- KPI headers (financial CSV column keys) ----
    "kpi_gross_sales": ("إجمالي المبيعات", "Ventes brutes", "Gross sales"),
    "kpi_line_discounts": ("خصومات البنود", "Remises lignes", "Line discounts"),
    "kpi_invoice_discounts": ("خصومات الفاتورة", "Remises facture", "Invoice discounts"),
    "kpi_discounts_total": ("إجمالي الخصومات", "Total des remises", "Total discounts"),
    "kpi_sales_after_discounts": (
        "المبيعات بعد الخصومات",
        "Ventes après remises",
        "Sales after discounts",
    ),
    "kpi_net_sales": ("صافي المبيعات", "Ventes nettes", "Net sales"),
    "kpi_returns_count": ("المرتجعات", "Retours", "Returns"),
    "kpi_returns_total": ("قيمة المرتجعات", "Montant des retours", "Returns amount"),
    "kpi_invoices": ("الفواتير", "Factures", "Invoices"),
    "kpi_items_sold": ("القطع المباعة", "Articles vendus", "Items sold"),
    "kpi_cogs": ("تكلفة البضاعة المباعة", "Coût des ventes", "COGS"),
    "kpi_returns_cost": ("تكلفة المرتجعات", "Coût des retours", "Returns cost"),
    "kpi_cogs_net": ("صافي التكلفة", "Coût net", "Net COGS"),
    "kpi_expenses": ("المصروفات", "Dépenses", "Expenses"),
    "kpi_expenses_drawer": ("من الدرج", "Caisse", "From drawer"),
    "kpi_expenses_external": ("خارجية", "Externes", "External"),
    "kpi_gross_profit": ("الربح الإجمالي", "Bénéfice brut", "Gross profit"),
    "kpi_net_profit": ("صافي الربح", "Bénéfice net", "Net profit"),
    "kpi_margin": ("هامش الربح", "Marge", "Margin"),
    "kpi_paid_cash": ("مدفوع نقدًا", "Payé espèces", "Paid cash"),
    "kpi_paid_card": ("مدفوع بالبطاقة", "Payé carte", "Paid card"),
    "kpi_paid_partial": ("دفعات جزئية", "Payé partiel", "Paid partial"),
    "kpi_collected": ("المحصَّل", "Encaissé", "Collected"),
    "kpi_debt_created": ("الديون المنشأة", "Dette créée", "Debt created"),
    "kpi_change": ("الباقي المدفوع", "Rendu", "Change given"),
    "kpi_outstanding_debt": ("ديون الفترة", "Dette de la période", "Debt in period"),
    "kpi_debt_collected": ("الديون المحصَّلة", "Dette encaissée", "Debt collected"),
    "kpi_ar_outstanding": ("ذمم العملاء", "Créances clients", "Outstanding AR"),
    "kpi_customers_with_debt": (
        "العملاء المدينون",
        "Clients endettés",
        "Customers with debt",
    ),
    "kpi_supplier_payable": ("مستحقات الموردين", "Dette fournisseur", "Supplier payable"),
    "kpi_purchases_total": ("المشتريات", "Achats", "Purchases"),
    "kpi_supplier_paid": ("مدفوع للموردين", "Payé aux fournisseurs", "Paid to suppliers"),
    "kpi_suppliers_with_balance": (
        "الموردون ذوو الرصيد",
        "Fournisseurs avec solde",
        "Suppliers with balance",
    ),
    # ---- table headers (CSV column keys) ----
    "col_invoice": ("الفاتورة", "Facture", "Invoice"),
    "col_date": ("التاريخ", "Date", "Date"),
    "col_time": ("الوقت", "Heure", "Time"),
    "col_customer": ("العميل", "Client", "Customer"),
    "col_user": ("المستخدم", "Utilisateur", "User"),
    "col_device": ("الجهاز", "Appareil", "Device"),
    "col_method": ("الطريقة", "Méthode", "Method"),
    "col_subtotal": ("المجموع الفرعي", "Sous-total", "Subtotal"),
    "col_line_discounts": ("خصومات البنود", "Remises lignes", "Line discounts"),
    "col_invoice_discount": ("خصم الفاتورة", "Remise facture", "Invoice discount"),
    "col_total": ("المجموع", "Total", "Total"),
    "col_paid": ("المدفوع", "Payé", "Paid"),
    "col_change": ("الباقي", "Rendu", "Change"),
    "col_qty": ("الكمية", "Qté", "Qty"),
    "col_unit": ("الوحدة", "Unité", "Unit"),
    "col_gross": ("الإجمالي", "Brut", "Gross"),
    "col_net_revenue": ("الإيراد الصافي", "Revenu net", "Net revenue"),
    "col_returns_qty": ("كمية المرتجع", "Qté retournée", "Returns qty"),
    "col_returns_amount": ("قيمة المرتجع", "Montant retourné", "Returns amount"),
    "col_cogs": ("التكلفة", "Coût", "COGS"),
    "col_gross_profit": ("الربح الإجمالي", "Bénéfice brut", "Gross profit"),
    "col_margin": ("الهامش", "Marge", "Margin"),
    "col_expenses": ("المصروفات", "Dépenses", "Expenses"),
    "col_net_profit": ("صافي الربح", "Bénéfice net", "Net profit"),
    "col_category": ("الفئة", "Catégorie", "Category"),
    "col_product": ("المنتج", "Produit", "Product"),
    "col_sku": ("الرمز", "Réf.", "SKU"),
    "col_stock_value": ("قيمة المخزون", "Valeur du stock", "Stock value"),
    "col_last_sale": ("آخر عملية بيع", "Dernière vente", "Last sale"),
    "col_voided_at": ("تاريخ الإلغاء", "Annulée le", "Voided at"),
    "col_void_reason": ("سبب الإلغاء", "Motif d’annulation", "Void reason"),
    "col_hour": ("الساعة", "Heure", "Hour"),
    "col_share": ("الحصة", "Part", "Share"),
    "col_count": ("العدد", "Nombre", "Count"),
    # ---- totals / states / misc ----
    "label_total": ("الإجمالي", "Total", "Total"),
    "label_unknown_device": ("جهاز غير معروف", "Appareil inconnu", "Unknown device"),
    "label_uncategorized": ("بدون فئة", "Sans catégorie", "Uncategorized"),
    "label_period": ("الفترة", "Période", "Period"),
    "label_snapshot": ("لقطة", "Instantané", "Snapshot"),
    "label_percent": ("النسبة المئوية", "Pourcentage", "Percent"),
    "label_off": ("خصم", "Remise", "OFF"),
    "filter_status": ("الحالة", "Statut", "Status"),
    "filter_device": ("الجهاز", "Appareil", "Device"),
    "filter_sort": ("ترتيب حسب", "Trier par", "Sort by"),
    "filter_lookback": ("الفترة (أيام)", "Période (jours)", "Lookback (days)"),
    "filter_threshold": ("الحد الأدنى", "Seuil", "Threshold"),
    "filter_payment": ("الدفع", "Paiement", "Payment"),
    # ---- status / payment labels ----
    "status_completed": ("مكتملة", "Terminée", "Completed"),
    "status_void": ("ملغاة", "Annulée", "Void"),
    "status_all": ("الكل", "Toutes", "All"),
    "purchase_status_draft": ("مسودة", "Brouillon", "Draft"),
    "purchase_status_received": ("مستلم", "Reçu", "Received"),
    "purchase_status_cancelled": ("ملغي", "Annulé", "Cancelled"),
    "label_cash": ("نقدًا", "Espèces", "Cash"),
    "label_card": ("بطاقة", "Carte", "Card"),
    "label_partial": ("جزئي", "Partiel", "Partial"),
    "label_credit": ("آجل", "Crédit", "Credit"),
    # ---- receipt / document labels (client keys reused) ----
    "total": ("المجموع", "Total", "Total"),
    "subtotal": ("المجموع الفرعي", "Sous-total", "Subtotal"),
    "quantity": ("الكمية", "Quantité", "Quantity"),
    "price": ("السعر", "Prix", "Price"),
    "base": ("أساسي", "Base", "Base"),
    "barcode": ("الباركود", "Code-barres", "Barcode"),
    "amount_paid": ("المبلغ المدفوع", "Montant payé", "Amount Paid"),
    "payment_method": ("طريقة الدفع", "Mode de paiement", "Payment Method"),
    "discount": ("خصم", "Remise", "Discount"),
    "change": ("الباقي", "Rendu", "Change"),
    "debt": ("دين", "Dette", "Debt"),
    "invoice_number": ("رقم الفاتورة", "N° de facture", "Invoice number"),
    "return_number": ("رقم المرتجع", "N° de retour", "Return number"),
    "sale_history": ("تاريخ البيع", "Date de vente", "Sale date"),
    "status": ("الحالة", "Statut", "Status"),
    "date": ("التاريخ", "Date", "Date"),
    "time": ("الوقت", "Heure", "Time"),
    "customer": ("العميل", "Client", "Customer"),
    "cashier": ("البائع", "Caissier", "Cashier"),
    "note": ("ملاحظة", "Note", "Note"),
    # ---- new document-only labels ----
    "doc_invoice": ("فاتورة", "Facture", "Invoice"),
    "doc_return": ("مرتجع", "Retour", "Return"),
    "doc_purchase": ("فاتورة شراء", "Achat", "Purchase"),
    "cash_customer": ("عميل نقدي", "Client comptant", "Cash customer"),
    "pack_marker": ("[حزمة]", "[pack]", "[pack]"),
    "generated": ("تاريخ الإنشاء", "Généré le", "Generated"),
    "no_data": ("لا توجد بيانات", "Aucune donnée", "No data"),
    "page": ("صفحة", "Page", "Page"),
    "supplier": ("المورد", "Fournisseur", "Supplier"),
    # ---- facturation documents (Phase 7 — factura_simple pdf_invoice) ----
    # Doc titles: legacy `_titles` (French only) localized for SP; the code
    # (FAC / DEV / PRO / BC / BL) is printed separately and never translated.
    "doc_facture": ("فاتورة", "FACTURE", "INVOICE"),
    "doc_devis": ("عرض السعر", "DEVIS", "QUOTE"),
    "doc_proforma": ("فاتورة مؤقتة", "FACTURE PROFORMA", "PROFORMA INVOICE"),
    "doc_bon_commande": ("أمر الشراء", "BON DE COMMANDE", "PURCHASE ORDER"),
    "doc_bon_livraison": ("وصل التسليم", "BON DE LIVRAISON", "DELIVERY NOTE"),
    # Fiscal identity lines (legacy `_id` labels — skipped when unset).
    "fiscal_nif": ("رقم التعريف الجبائي", "NIF", "NIF"),
    "fiscal_nis": ("رقم التعريف الإحصائي", "NIS", "NIS"),
    "fiscal_rc": ("السجل التجاري", "RC", "RC"),
    "fiscal_ai": ("التسجيل الجبائي", "AI", "AI"),
    "fiscal_rib": ("الحساب البنكي", "RIB/CCP", "RIB/CCP"),
    "fiscal_wilaya": ("الولاية", "Wilaya", "Wilaya"),
    "fiscal_email": ("البريد الإلكتروني", "E-mail", "Email"),
    "phone": ("الهاتف", "Tél", "Phone"),
    # Item table + totals (legacy French headers).
    "col_description": ("البيان", "Désignation", "Description"),
    "col_unit_price_ht": ("السعر دون الرسم", "P.U. HT", "Unit price excl. tax"),
    "col_remise_pct": ("الخصم %", "Remise %", "Discount %"),
    "col_tva_rate": ("الرسم %", "TVA %", "VAT %"),
    "col_ht": ("الجملة دون الرسم", "Total HT", "Total excl. tax"),
    "col_ttc": ("الجملة بالرسم", "Total TTC", "Total incl. tax"),
    "col_total_tva": ("مجموع الرسم", "Total TVA", "Total VAT"),
    "col_timbre": ("حقوق الطابع", "Droit de timbre", "Stamp duty"),
    "col_net_a_payer": ("الصافي المطلوب", "Net à payer", "Net payable"),
    "signature": ("التوقيع", "Signature", "Signature"),
    # Facturation payment methods (legacy `_payLabels`: cash/transfer/cheque).
    "label_transfer": ("تحويل بنكي", "Virement", "Transfer"),
    "label_cheque": ("شيك", "Chèque", "Cheque"),
    # ---- unit labels (client keys via `unitLabel`, strings.dart) ----
    # Printed as the price suffix on a label when unit != piece
    # (`100.00 DA / kg`).
    "unit_piece": ("قطعة", "Pièce", "Piece"),
    "unit_box": ("علبة", "Boîte", "Box"),
    "unit_carton": ("كرتون", "Carton", "Carton"),
    "unit_kg": ("كغ", "kg", "kg"),
    "unit_gram": ("غرام", "Gramme", "Gram"),
    "unit_liter": ("لتر", "Litre", "Liter"),
    "unit_milliliter": ("مل", "Millilitre", "Milliliter"),
    "unit_meter": ("متر", "Mètre", "Meter"),
    "unit_pack": ("حزمة", "Paquet", "Pack"),
}

# keys whose values are (ar, fr, en) tuples — index per locale
_LOCALE_INDEX = {"ar": 0, "fr": 1, "en": 2}


def label(key: str, locale: str) -> str:
    """Localized label for `key`; falls back to English, then to the key."""
    entry = LABELS.get(key)
    if entry is None:
        return key
    return entry[_LOCALE_INDEX.get(locale, 2)]


def is_rtl(locale: str) -> bool:
    return locale == "ar"
