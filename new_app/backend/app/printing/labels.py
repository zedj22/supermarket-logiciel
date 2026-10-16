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
    "report_loyalty": ("الولاء", "Fidélité", "Loyalty"),
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
    # ---- loyalty report (Loyalty Phase F — strings.dart wording) ----
    "loyalty_settlement_points": (
        "نقاط من تسديد الدين",
        "Points du règlement de dette",
        "Points from debt settlement",
    ),
    "loyalty_points_redeemed": (
        "النقاط المستردة",
        "Points utilisés",
        "Points redeemed",
    ),
    "loyalty_redemption_value": (
        "خصم المكافأة",
        "Remise récompense",
        "Reward discount",
    ),
    "loyalty_points_reversed": (
        "نقاط مقلوبة (مرتجعات/إلغاء)",
        "Points retirés (retours/annulations)",
        "Points reversed (returns/voids)",
    ),
    "loyalty_cashback_reversed": (
        "استرداد نقدي مقلوب (مرتجعات/إلغاء)",
        "Cashback retiré (retours/annulations)",
        "Cashback reversed (returns/voids)",
    ),
    "loyalty_points_restored": (
        "نقاط مستعادة",
        "Points restitués",
        "Points restored",
    ),
    "loyalty_restored_value": (
        "قيمة مكافأة مستعادة",
        "Valeur récompense restituée",
        "Restored reward value",
    ),
    "loyalty_shortfall_points": (
        "نقاط لم تُسترجع",
        "Points non récupérés",
        "Unrecovered points",
    ),
    "loyalty_shortfall_cashback": (
        "استرداد نقدي لم يُسترجع",
        "Cashback non récupéré",
        "Unrecovered cashback",
    ),
    "loyalty_outstanding_points": (
        "النقاط القائمة",
        "Points en circulation",
        "Outstanding points",
    ),
    "loyalty_outstanding_cashback": (
        "الاسترداد النقدي القائم",
        "Cashback en circulation",
        "Outstanding cashback",
    ),
    "loyalty_accounts_with_balance": (
        "عملاء لديهم رصيد",
        "Clients avec solde",
        "Customers with a balance",
    ),
    "loyalty_adjustment_points": (
        "تسويات (نقاط)",
        "Ajustements (points)",
        "Adjustments (points)",
    ),
    "loyalty_adjustment_cashback": (
        "تسويات (استرداد نقدي)",
        "Ajustements (cashback)",
        "Adjustments (cashback)",
    ),
    "loyalty_event_sale_earn": (
        "نقاط مكتسبة من البيع",
        "Points gagnés sur la vente",
        "Points earned on sale",
    ),
    "loyalty_event_debt_settlement_earn": (
        "نقاط مكتسبة من تسديد الدين",
        "Points gagnés au règlement de la dette",
        "Points earned on debt settlement",
    ),
    "loyalty_event_redeem": ("نقاط مستردة", "Points utilisés", "Points redeemed"),
    "loyalty_event_return_clawback": (
        "نقاط ملغاة (مرتجع)",
        "Points retirés (retour)",
        "Points revoked (return)",
    ),
    "loyalty_event_void_clawback": (
        "نقاط ملغاة (إلغاء)",
        "Points retirés (annulation)",
        "Points revoked (void)",
    ),
    "loyalty_event_adjustment": (
        "تسوية الرصيد",
        "Ajustement du solde",
        "Balance adjustment",
    ),
    "loyalty_event_expiry": (
        "انتهاء النقاط",
        "Expiration des points",
        "Points expiry",
    ),
    "col_event": ("الحدث", "Événement", "Event"),
    "col_points": ("النقاط", "Points", "Points"),
    "col_cashback": ("الاسترداد النقدي", "Cashback", "Cashback"),
    "col_points_balance": ("رصيد النقاط", "Solde de points", "Points balance"),
    "col_cashback_balance": (
        "رصيد الاسترداد النقدي",
        "Solde de cashback",
        "Cashback balance",
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
    # ---- loyalty (reward redesign — reward wording) ----
    "loyalty_redeemed": ("خصم المكافأة", "Remise récompense", "Reward discount"),
    "amount_due": ("المبلغ المستحق", "Montant dû", "Amount due"),
    "loyalty_points_earned": ("النقاط المكتسبة", "Points gagnés", "Points earned"),
    "loyalty_cashback_earned": (
        "الاسترداد النقدي المكتسب",
        "Cashback gagné",
        "Cashback earned",
    ),
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
    # ---- Zakat (Zakat al-Tijarah) report labels ----
    "notes": ("ملاحظات", "Notes", "Notes"),
    "zakat_report_title": ("تقرير الزكاة", "Rapport de Zakat", "Zakat Report"),
    "zakat_calculation_date": ("تاريخ الحساب", "Date du calcul", "Calculation date"),
    "zakat_reference": ("المرجع", "Référence", "Reference"),
    "zakat_hawl": ("الحول", "Hawl", "Hawl"),
    "zakat_hawl_start": ("بداية الحول", "Début du hawl", "Hawl start"),
    "zakat_hawl_completed": ("اكتمل الحول", "Hawl accompli", "Hawl completed"),
    "zakat_nisab": ("النصاب", "Nisab", "Nisab"),
    "zakat_nisab_source_gold_price": ("من سعر الذهب (85 غ)", "Prix de l'or (85 g)", "From gold price (85 g)"),
    "zakat_nisab_source_manual": ("يدوي", "Manuel", "Manual"),
    "zakat_nisab_source_none": ("غير محدد", "Indéfini", "Unknown"),
    "zakat_inventory_basis": ("أساس تخزين البضائع", "Base d'évaluation des marchandises", "Merchandise valuation basis"),
    "zakat_basis_market": ("سعر السوق", "Prix du marché", "Market price"),
    "zakat_basis_cost": ("التكلفة (متوسط)", "Coût (moyenne)", "Cost (average)"),
    "zakat_basis_override": ("إدخال يدوي", "Saisie manuelle", "Manual entry"),
    "zakat_debt_treatment": ("طريقة احتساب الديون", "Traitement des dettes", "Debt treatment"),
    "zakat_method_deduct_all": ("خصم كل الديون", "Déduction de toutes les dettes", "Deduct all debts"),
    "zakat_method_deduct_due_only": ("خصم الديون المستحقة فقط", "Déduction des dettes échues uniquement", "Deduct due debts only"),
    "zakat_method_no_deduction": ("بدون خصم", "Aucune déduction", "No deduction"),
    "zakat_col_item": ("البيان", "Désignation", "Item"),
    "zakat_col_amount": ("المبلغ", "Montant", "Amount"),
    "zakat_col_source": ("المصدر", "Source", "Source"),
    "zakat_col_due": ("مستحق", "Échu", "Due"),
    "zakat_col_note": ("ملاحظة", "Note", "Note"),
    "zakat_row_inventory": ("البضائع (مخزون)", "Marchandises (stock)", "Merchandise (stock)"),
    "zakat_row_cash": ("النقد", "Espèces", "Cash"),
    "zakat_row_collectible": ("الديون المتوقع تحصيلها", "Créances recouvrables", "Collectible receivables"),
    "zakat_row_other_receivables": ("ديون أخرى", "Autres créances", "Other receivables"),
    "zakat_row_no_liabilities": ("لا توجد ديون مدخلة", "Aucune dette saisie", "No liabilities entered"),
    "zakat_source_entered": ("إدخال المستخدم", "Saisi par l'opérateur", "Operator-entered"),
    "zakat_total_assets": ("مجموع الأموال", "Total des avoirs", "Total assets"),
    "zakat_total_deductions": ("مجموع الخصومات", "Total des déductions", "Total deductions"),
    "zakat_total_deducted": ("المبلغ المخصوم", "Montant déduit", "Amount deducted"),
    "zakat_net_zakatable": ("الصافي الزكوي", "Net imposable à la Zakat", "Zakatable net"),
    "zakat_status_final": ("نهائي", "Définitif", "Final"),
    "zakat_status_provisional": ("تقديري", "Provisoire", "Provisional"),
    "zakat_rate": ("نسبة الزكاة", "Taux de Zakat", "Zakat rate"),
    "zakat_rate_note": ("(المبلغ × 2.5) ÷ 100", "(Montant × 2,5) ÷ 100", "(Amount × 2.5) / 100"),
    "zakat_due_amount": ("الزكاة المستحقة", "Zakat due", "Zakat due"),
    "zakat_provisional_due": ("الزكاة التقديرية", "Zakat estimée", "Provisional zakat"),
    "zakat_yes": ("نعم", "Oui", "Yes"),
    "zakat_no": ("لا", "Non", "No"),
    "zakat_unknown": ("غير محدد", "Inconnu", "Unknown"),
    "zakat_due_yes": ("مستحق", "Échu", "Due"),
    "zakat_due_no": ("غير مستحق", "Non échu", "Not due"),
    "zakat_disclaimer": (
        "أداة مساعدة للحساب فقط — لا تعدّل بيانات المبيعات أو المخزون أو المحاسبة. "
        "راجع مرجع وزارة الشؤون الدينية والأوقاف (marw.gov.dz).",
        "Outil d'aide au calcul uniquement — ne modifie ni les ventes, ni le stock, "
        "ni la comptabilité. Voir la référence du Ministère (marw.gov.dz).",
        "Calculation aid only — does not modify sales, inventory or accounting. "
        "See the Ministry reference (marw.gov.dz).",
    ),
    # Zakat warnings (codes lowercased from app.domain.zakat)
    "zakat_warn_missing_nisab": (
        "النصاب غير محدد — أدخل سعر غرام الذهب أو نصابًا يدويًا.",
        "Nisab manquant — saisissez le prix du gramme d'or ou un nisab manuel.",
        "Nisab missing — enter the gold price per gram or a manual nisab.",
    ),
    "zakat_warn_missing_hawl_start": (
        "تاريخ بداية الحول غير محدد.",
        "Date de début du hawl manquante.",
        "Hawl start date missing.",
    ),
    "zakat_warn_hawl_start_after_date": (
        "بداية الحول بعد تاريخ الحساب.",
        "Le début du hawl est postérieur à la date de calcul.",
        "Hawl start is after the calculation date.",
    ),
    "zakat_warn_hawl_not_completed": (
        "الحول لم يكتمل بعد.",
        "Le hawl n'est pas encore accompli.",
        "Hawl not yet completed.",
    ),
    "zakat_warn_missing_inventory": (
        "قيمة البضائع غير محددة.",
        "Valeur des marchandises manquante.",
        "Merchandise value missing.",
    ),
    "zakat_warn_inventory_override_applied": (
        "تم استخدام قيمة بضائع مدخلة يدويًا.",
        "Valeur des marchandises saisie manuellement.",
        "Manual merchandise value applied.",
    ),
    "zakat_warn_inventory_override_no_reason": (
        "القيمة اليدوية بدون سبب مذكور.",
        "Valeur manuelle sans raison indiquée.",
        "Manual value without a stated reason.",
    ),
    "zakat_warn_inventory_excluded_lines": (
        "استُبعدت خطوط بضائع من الحساب.",
        "Des lignes de marchandises ont été exclues.",
        "Some merchandise lines were excluded.",
    ),
    "zakat_warn_negative_stock_lines": (
        "يوجد مخزون بكمية سالبة.",
        "Des quantités de stock sont négatives.",
        "Some stock quantities are negative.",
    ),
    "zakat_warn_missing_cash": (
        "مبلغ النقد غير محدد.",
        "Montant des espèces manquant.",
        "Cash amount missing.",
    ),
    "zakat_warn_cash_provided_empty": (
        "النقد مُفعّل لكن لا توجد مبالغ مدخلة.",
        "Espèces activées mais aucun montant saisi.",
        "Cash is enabled but no amounts were entered.",
    ),
    "zakat_warn_missing_receivables": (
        "الديون المتوقع تحصيلها غير محددة.",
        "Créances recouvrables manquantes.",
        "Collectible receivables missing.",
    ),
    "zakat_warn_doubtful_excluded": (
        "الديون المشكوك فيها غير مضمومة (تُحسب عند التحصيل فقط).",
        "Les créances douteuses sont exclues (imposées à recouvrement).",
        "Doubtful debts are excluded (taxed only when recovered).",
    ),
    "zakat_warn_receivables_exceed_ledger": (
        "الديون المدخلة تفوق رصيد دفتر العملاء.",
        "Les créances saisies dépassent le solde du grand livre clients.",
        "Entered receivables exceed the customer ledger balance.",
    ),
    "zakat_warn_debt_due_only_skipped": (
        "استُبعدت ديون غير مستحقة (طريقة الخصم الانتقائي).",
        "Dettes non échues exclues (déduction partielle).",
        "Non-due debts skipped (due-only method).",
    ),
    "zakat_warn_debt_no_deduction_applied": (
        "لم تُخصم أي دين (طريقة بدون خصم).",
        "Aucune dette déduite (méthode sans déduction).",
        "No debts deducted (no-deduction method).",
    ),
    "zakat_warn_duplicate_label": (
        "تسميات مكررة في المبالغ المدخلة.",
        "Libellés en double dans les montants saisis.",
        "Duplicate labels among entered amounts.",
    ),
    "zakat_warn_negative_net_clamped": (
        "الصافي سالب — عولج بصفر.",
        "Net négatif — ramené à zéro.",
        "Negative net — clamped to zero.",
    ),
    "zakat_warn_provisional_result": (
        "النتيجة تقديرية (مدخلات ناقصة).",
        "Résultat provisoire (entrées manquantes).",
        "Provisional result (inputs missing).",
    ),
    "zakat_warn_below_nisab": (
        "الصافي دون النصاب — لا زكاة واجبة.",
        "Net inférieur au nisab — aucune Zakat due.",
        "Net below the nisab — no zakat due.",
    ),
    "zakat_warn_gold_price_manual": (
        "سعر الذهب مُدخل يدويًا — تحقّق من السعر الرسمي.",
        "Prix de l'or saisi manuellement — vérifiez le prix officiel.",
        "Gold price entered manually — verify the official price.",
    ),
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
