# Supermarket Pro - MainWindow V18 - invoices linked to debt history
# gui/main_window.py
# Supermarket Pro - Modern UI
# يحافظ على واجهات Managers الموجودة في المشروع:
# ProductManager / SalesManager / CustomerManager / ReportsManager

import customtkinter as ctk
from tkinter import messagebox, filedialog
import tkinter as tk
import os
import sys
import tempfile
import json
import hashlib
import secrets
import threading
from datetime import datetime

try:
    import pymysql
except ImportError:
    pymysql = None

try:
    from PIL import Image
except ImportError:
    Image = None

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from modules.products import ProductManager
from modules.sales import SalesManager
from modules.customers import CustomerManager
from modules.reports import ReportsManager, DAY_NAME_TO_DOW
from modules.debts import DebtManager
from modules.inventory import InventoryManager
from modules.packs import PacksManager
from modules.favorites import FavoritesManager
from database.db_manager import (
    DatabaseManager,
    load_db_config,
    save_db_config as save_database_config,
    test_connection as test_database_connection,
    get_active_config,
    set_active_config,
)


class MainWindow(ctk.CTk):
    """الواجهة الرئيسية الحديثة لبرنامج Supermarket Pro."""

    def __init__(self):
        super().__init__()

        # يجب تعريف اللغة قبل أول استدعاء للدالة t()
        # سيتم استبدالها باللغة المحفوظة من الإعدادات لاحقاً.
        self.language = "ar"

        self.title(self.t("Supermarket Pro • إدارة المتجر"))
        self.geometry("1500x900")
        self.minsize(1180, 760)

        # الحالة
        self.current_page = "dashboard"
        self.selected_customer = None
        self.cart = []
        self.total = 0.0
        self.is_dark = True
        self.is_grey = False
        self.theme_mode = "dark"
        self.sidebar_collapsed = False
        self.search_after_id = None
        self.customer_search_after_id = None
        self.inventory_search_after_id = None
        self._image_cache = {}
        self.sale_processing = False
        self.held_sales = []
        self.pos_filter = "all"
        self.product_filter = "all"
        self.product_page = 1
        self.product_page_size = 40
        self.pos_list_page = 1
        self.pos_list_page_size = 40
        self.pos_sort_col = None
        self.pos_sort_dir = 1
        self.fav_display_cap = 15
        self.pos_products_cache = []
        self.current_user = None

        # حالة الشبكة/الاتصال — تُنشأ مبكرًا لأن شريط الأعلى يقرأها.
        self._conn_monitor_started = False
        self._discovery_started = False
        self._discovery_responder = None
        self._conn_state_box = {"up": None}
        self._conn_last_up = None
        self._reconnect_dialog = None

        # ألوان التصميم
        # Palette مصممة لتبدو كتطبيق SaaS/POS حديث بدل واجهة Tkinter تقليدية
        self.colors = {
            "primary": "#6366F1",
            "primary_hover": "#4F46E5",
            "secondary": "#22C55E",
            "secondary_hover": "#16A34A",
            "accent": "#F59E0B",
            "accent_hover": "#D97706",
            "danger": "#F43F5E",
            "danger_light": "#FDA4AF",
            "danger_hover": "#E11D48",
            "info": "#38BDF8",
            "purple": "#A78BFA",

            "light_bg": "#F7F8FC",
            "light_card": "#FFFFFF",
            "light_text": "#111827",
            "light_muted": "#64748B",
            "light_border": "#E7EAF0",

            "dark_bg": "#0F1117",
            "dark_card": "#171A21",
            "dark_text": "#F8FAFC",
            "dark_muted": "#94A3B8",
            "dark_border": "#272C36",

            "grey_bg": "#2F3136",
            "grey_card": "#3A3D42",
            "grey_text": "#F2F2F2",
            "grey_muted": "#C2C5CA",
            "grey_border": "#5A5E64",
        }

        ctk.set_default_color_theme("blue")
        ctk.set_appearance_mode("dark")
        ctk.set_widget_scaling(1.0)
        ctk.set_window_scaling(1.0)

        # خطوط Windows مستقرة وتدعم العربية بشكل أفضل من الخط الافتراضي
        self.ui_font_family = "Tahoma"
        self.ui_symbol_family = "Segoe UI Symbol"

        self.settings = self.load_app_settings()
        self.theme_mode = str(
            self.settings.get("theme_mode", self.settings.get("appearance", "dark"))
        ).lower()
        if self.theme_mode not in ("light", "dark", "grey"):
            self.theme_mode = "dark"
        self.is_dark = self.theme_mode == "dark"
        self.is_grey = self.theme_mode == "grey"
        self.language = str(self.settings.get("language", "ar")).lower()
        if self.language not in ("ar", "fr", "en"):
            self.language = "ar"

        # ظاهر التطبيق يُضبط حسب الثيم المحمّل (وليس افتراضي dark دائمًا).
        ctk.set_appearance_mode("light" if self.theme_mode == "light" else "dark")

        self.setup_ui()
        self.bind_shortcuts()
        self._apply_maximized()

        # تبقى طبقة البيانات (المدراء + الجداول + لوحة التحكم + مؤشر الاتصال)
        # غير مُنشأة حتى يحدّد المستخدم وضع الشبكة في معالج الإعداد الأول،
        # فلا يُحاول البرنامج الاتصال بقاعدة البيانات قبل ذلك.
        self._data_ready = False

        # إغلاق نظيف عبر زر إغلاق النافذة (X) — يمنع بقاء العملية معلّقة بعد
        # فشل الاتصال لأن الحلقة الرئيسية تبقى قابلة للمعالجة دائمًا.
        try:
            self.protocol("WM_DELETE_WINDOW", self._on_main_close)
        except Exception:
            pass

        self.store_linked = bool(get_active_config().get("store_linked", False))

        # معالج الإعداد الأول: اختيار وضع الشبكة ثم بناء البيانات وتسجيل الدخول.
        # ملاحظة: لا نُقلع مراقب الاتصال (مراقب الشفاء الذاتي) هنا حتى نصل إلى
        # _finalize_startup، لتفادي تصادم نوافذ الإعداد مع نوافذ إعادة الاتصال.
        self.after(400, self._startup_first_run_wizard)

    # =========================================================
    # Language / i18n
    # =========================================================

    _TRANSLATIONS = {'سوبرماركت برو': {'en': 'Supermarket Pro', 'fr': 'Supermarket Pro'},
 'مبلغ ثابت (دج)': {'en': 'Fixed Amount (DZD)', 'fr': 'Montant fixe (DA)'},
 'نسبة مئوية (%)': {'en': 'Percentage (%)', 'fr': 'Pourcentage (%)'},
'قيمة الخصم:': {'en': 'Discount Amount:', 'fr': 'Montant de la remise :'},
  'النسبة المئوية يجب أن تكون بين 0 و 100': {'en': 'Percentage must be between 0 and 100', 'fr': 'Le pourcentage doit être compris entre 0 et 100'},
  'اسم المنتج *': {'en': 'Product Name *', 'fr': 'Nom du produit *'},
  'مثال: حليب كانديا 1 لتر': {'en': 'Example: Candia milk 1L', 'fr': 'Ex. : lait Candia 1L'},
  'سعر البيع (د.ج) *': {'en': 'Selling Price (DZD) *', 'fr': 'Prix de vente (DA) *'},
  'مثال: 120.00': {'en': 'Example: 120.00', 'fr': 'Ex. : 120,00'},
  'سعر الشراء / التكلفة (د.ج)': {'en': 'Purchase Price / Cost (DZD)', 'fr': "Prix d'achat / coût (DA)"},
  'مثال: 95.00': {'en': 'Example: 95.00', 'fr': 'Ex. : 95,00'},
  'الكمية المتوفرة بالمخزون *': {'en': 'Available Stock Quantity *', 'fr': 'Quantité en stock *'},
  'مثال: 50 أو 1.5 للوزن': {'en': 'Example: 50 or 1.5 for weight', 'fr': 'Ex. : 50 ou 1,5 pour le poids'},
  'الباركود أو الرمز التعريفي (Barcode / SKU)': {'en': 'Barcode or SKU', 'fr': 'Code-barres ou SKU'},
  'امسح بالماسح أو اتركه فارغاً للتوليد التلقائي': {'en': 'Scan it or leave empty for auto-generation', 'fr': 'Scannez-le ou laissez vide pour génération auto'},
  'وحدة القياس': {'en': 'Unit of Measure', 'fr': 'Unité de mesure'},
  'تصنيف المنتج': {'en': 'Product Category', 'fr': 'Catégorie du produit'},
  'الاسم الكامل *': {'en': 'Full Name *', 'fr': 'Nom complet *'},
  'مثال: أحمد بن يوسف': {'en': 'Example: Ahmed Ben Yousef', 'fr': 'Ex. : Ahmed Ben Yousef'},
  'رقم الهاتف': {'en': 'Phone Number', 'fr': 'Numéro de téléphone'},
  'مثال: 0550123456': {'en': 'Example: 0550123456', 'fr': 'Ex. : 0550123456'},
  'العنوان أو المنطقة': {'en': 'Address or Area', 'fr': 'Adresse ou zone'},
  'مثال: وسط المدينة': {'en': 'Example: City center', 'fr': 'Ex. : Centre-ville'},
  'سقف الدين المسموح به (د.ج)': {'en': 'Allowed Debt Ceiling (DZD)', 'fr': 'Plafond de dette autorisé (DA)'},
  '0 يعني غير محدد': {'en': '0 means unlimited', 'fr': '0 signifie illimité'},
  'بيان أو عنوان المصروف *': {'en': 'Expense Title *', 'fr': 'Intitulé de la dépense *'},
  'مثال: فاتورة الكهرباء - شهر سبتمبر': {'en': 'Example: Electricity bill - September', 'fr': 'Ex. : Facture d\'électricité - septembre'},
  'فئة المصروف': {'en': 'Expense Category', 'fr': 'Catégorie de dépense'},
  'المبلغ المطلوب دفعه (د.ج) *': {'en': 'Amount to Pay (DZD) *', 'fr': 'Montant à payer (DA) *'},
  'مثال: 15000': {'en': 'Example: 15000', 'fr': 'Ex. : 15000'},
  'ملاحظات إضافية (اختياري)': {'en': 'Additional Notes (optional)', 'fr': 'Notes supplémentaires (optionnel)'},
  'أدخل أي تفاصيل إضافية هنا...': {'en': 'Enter any extra details here...', 'fr': 'Saisissez des détails supplémentaires ici...'},
  'المنتج المراد تزويده *': {'en': 'Product to Restock *', 'fr': 'Produit à réapprovisionner *'},
  'اكتب اسم المنتج أو الباركود...': {'en': 'Type product name or barcode...', 'fr': 'Saisissez le nom ou le code-barres...'},
  'الكمية المراد إضافتها إلى المخزون *': {'en': 'Quantity to Add to Stock *', 'fr': 'Quantité à ajouter au stock *'},
  'أدخل الكمية المضافة': {'en': 'Enter the added quantity', 'fr': 'Entrez la quantité ajoutée'},
  'سبب التزويد أو رقم وصل الشراء': {'en': 'Restock Reason or Purchase Receipt No.', 'fr': 'Motif de réappro. ou n° de facture'},
  'مثال: فاتورة المورد رقم 104': {'en': 'Example: Supplier invoice #104', 'fr': 'Ex. : Facture fournisseur n°104'},
 'اختصارات لوحة المفاتيح': {'en': 'Keyboard Shortcuts', 'fr': 'Raccourcis clavier'},
 'دليل اختصارات لوحة المفاتيح': {'en': 'Keyboard Shortcuts Guide', 'fr': 'Guide des raccourcis clavier'},
 'اضغط Escape للإغلاق': {'en': 'Press Escape to close', 'fr': 'Appuyez sur Échap pour fermer'},
 'إغلاق': {'en': 'Close', 'fr': 'Fermer'},
 'نظام إدارة المتجر': {'en': 'Store Management System', 'fr': 'Système de gestion du magasin'},
 'إدارة المتجر': {'en': 'Store Management', 'fr': 'Gestion du magasin'},
 'لوحة التحكم': {'en': 'Dashboard', 'fr': 'Tableau de bord'},
 'المنتجات': {'en': 'Products', 'fr': 'Produits'},
  'المخزون': {'en': 'Inventory', 'fr': 'Stock'},
  'الباقات': {'en': 'Packs', 'fr': 'Packs'},
  'باقة': {'en': 'Pack', 'fr': 'Pack'},
  'باقة جديدة': {'en': 'New Pack', 'fr': 'Nouveau pack'},
  'اسم الباقة': {'en': 'Pack name', 'fr': 'Nom du pack'},
  'سعر الباقة': {'en': 'Pack price', 'fr': 'Prix du pack'},
  'مكونات الباقة': {'en': 'Pack components', 'fr': 'Composants du pack'},
  'سعر المجموع': {'en': 'Sum of parts', 'fr': 'Somme des composants'},
  'الربح': {'en': 'Profit', 'fr': 'Profit'},
  'الربح عن البيع الفردي': {'en': 'Profit vs individual prices', 'fr': 'Profit vs prix individuels'},
  'يحتوي': {'en': 'Contains', 'fr': 'Contient'},
  'إضافة الباقة': {'en': 'Add Pack', 'fr': 'Ajouter le pack'},
  'حفظ الباقة': {'en': 'Save Pack', 'fr': 'Enregistrer le pack'},
  'حذف الباقة': {'en': 'Delete Pack', 'fr': 'Supprimer le pack'},
  'الباقيات': {'en': 'Packs', 'fr': 'Packs'},

  'المفضّلة': {'en': 'Favorites', 'fr': 'Favoris'},
  'إدارة المفضّلة': {'en': 'Manage favorites', 'fr': 'Gérer les favoris'},
  'لا توجد منتجات مفضّلة بعد': {'en': 'No favorites yet', 'fr': 'Aucun favori pour le moment'},
  'أضف نجمة ⭐ للمنتج ليظهر هنا': {'en': 'Star ⭐ a product to show it here', 'fr': 'Mettez une étoile ⭐ à un produit pour l\'afficher ici'},
  'أزِل من المفضّلة': {'en': 'Unfavorite', 'fr': 'Retirer des favoris'},
  'أضِف إلى المفضّلة': {'en': 'Favorite', 'fr': 'Ajouter aux favoris'},
  'الكل': {'en': 'All', 'fr': 'Tous'},
  'متوفر': {'en': 'Available', 'fr': 'Disponible'},
  'مخزون منخفض': {'en': 'Low stock', 'fr': 'Stock faible'},
  'نفد': {'en': 'Out of stock', 'fr': 'Rupture'},
  'السعر': {'en': 'Price', 'fr': 'Prix'},
  'الكمية': {'en': 'Quantity', 'fr': 'Quantité'},
  'الحالة': {'en': 'Status', 'fr': 'Statut'},


 'نقطة البيع': {'en': 'Point of Sale', 'fr': 'Point de vente'},
 'الزبائن': {'en': 'Customers', 'fr': 'Clients'},
 'الموردون': {'en': 'Suppliers', 'fr': 'Fournisseurs'},
 'التقارير': {'en': 'Reports', 'fr': 'Rapports'},
 'الإعدادات': {'en': 'Settings', 'fr': 'Paramètres'},
 'الموارد': {'en': 'Resources', 'fr': 'Ressources'},
 'خروج': {'en': 'Exit', 'fr': 'Quitter'},
 'النظام يعمل': {'en': 'System is running', 'fr': 'Le système fonctionne'},
 'جاهز لاستقبال المبيعات': {'en': 'Ready for sales', 'fr': 'Prêt à recevoir les ventes'},
 'التنبيهات': {'en': 'Notifications', 'fr': 'Notifications'},
 'لا توجد تنبيهات مهمة حاليًا': {'en': 'No important notifications', 'fr': 'Aucune notification importante'},
 'إرجاع منتج': {'en': 'Return Product', 'fr': 'Retour produit'},
 'أعد منتجًا بشكل مستقل دون إدخال رقم فاتورة.': {'en': 'Return a product without entering an invoice number.',
                                                 'fr': 'Retournez un produit sans saisir de numéro de facture.'},
 'البحث عن المنتج': {'en': 'Search product', 'fr': 'Rechercher un produit'},
 'ابحث باسم المنتج أو الباركود...': {'en': 'Search by product name or barcode...',
                                     'fr': 'Rechercher par nom du produit ou code-barres...'},
 'المنتج المحدد': {'en': 'Selected product', 'fr': 'Produit sélectionné'},
 'لم يتم اختيار منتج': {'en': 'No product selected', 'fr': 'Aucun produit sélectionné'},
 'طريقة الإرجاع': {'en': 'Return method', 'fr': 'Méthode de retour'},
 'الكمية / الوزن': {'en': 'Quantity / Weight', 'fr': 'Quantité / Poids'},
 'المبلغ': {'en': 'Amount', 'fr': 'Montant'},
 'الكمية / الوزن / المبلغ': {'en': 'Quantity / Weight / Amount', 'fr': 'Quantité / Poids / Montant'},
 'أدخل الكمية أو الوزن أو المبلغ': {'en': 'Enter quantity, weight or amount',
                                    'fr': 'Saisissez la quantité, le poids ou le montant'},
 'إلغاء': {'en': 'Cancel', 'fr': 'Annuler'},
 '✓ تأكيد الإرجاع': {'en': '✓ Confirm Return', 'fr': '✓ Confirmer le retour'},
 'رقم الفاتورة': {'en': 'Invoice number', 'fr': 'Numéro de facture'},
 'تحميل': {'en': 'Load', 'fr': 'Charger'},
 'الكمية المرتجعة': {'en': 'Returned quantity', 'fr': 'Quantité retournée'},
 '↩ تسجيل المرتجع': {'en': '↩ Register Return', 'fr': '↩ Enregistrer le retour'},
 'تفاصيل المبيعات والربح': {'en': 'Sales & Profit Details', 'fr': 'Détails des ventes et bénéfices'},
 'لا توجد مبيعات في الفترة المحددة': {'en': 'No sales in the selected period',
                                      'fr': 'Aucune vente pour la période sélectionnée'},
 'مرحبًا بك 👋': {'en': 'Welcome 👋', 'fr': 'Bienvenue 👋'},
 'فتح نقطة البيع  →': {'en': 'Open POS →', 'fr': 'Ouvrir le point de vente →'},
 'إجراءات سريعة': {'en': 'Quick Actions', 'fr': 'Actions rapides'},
 '📈 مبيعات آخر 7 أيام': {'en': '📈 Sales - Last 7 Days', 'fr': '📈 Ventes - 7 derniers jours'},
 'إجمالي المبيعات اليومية المسجلة فعليًا': {'en': 'Actual recorded daily sales',
                                            'fr': 'Ventes quotidiennes réellement enregistrées'},
 '⚠ يحتاج انتباهك': {'en': '⚠ Needs your attention', 'fr': '⚠ Nécessite votre attention'},
 '🏆 الأكثر مبيعًا': {'en': '🏆 Best Sellers', 'fr': '🏆 Meilleures ventes'},
 'لا توجد مبيعات مسجلة بعد': {'en': 'No sales recorded yet', 'fr': 'Aucune vente enregistrée'},
 '✓ كل شيء على ما يرام': {'en': '✓ Everything is fine', 'fr': '✓ Tout va bien'},
 'لا توجد مبيعات خلال آخر 7 أيام': {'en': 'No sales in the last 7 days',
                                    'fr': 'Aucune vente au cours des 7 derniers jours'},
 '📋 سجل الحركات': {'en': '📋 Movement Log', 'fr': '📋 Journal des mouvements'},
 '+ إدخال مخزون': {'en': '+ Stock Entry', 'fr': '+ Entrée de stock'},
 '⟳ تحديث': {'en': '⟳ Refresh', 'fr': '⟳ Actualiser'},
 '📋 جرد المخزون': {'en': '📋 Inventory Count', 'fr': '📋 Inventaire'},
 'سجل': {'en': 'Log', 'fr': 'Journal'},
 '+ إضافة': {'en': '+ Add', 'fr': '+ Ajouter'},
 '✓ حفظ الجرد': {'en': '✓ Save Count', 'fr': "✓ Enregistrer l'inventaire"},
 'كل عملية إدخال أو تعديل مسجلة مع التاريخ والسبب.': {'en': 'Every stock entry or adjustment is recorded with date and '
                                                            'reason.',
                                                      'fr': 'Chaque entrée ou modification est enregistrée avec la '
                                                            'date et le motif.'},
 'لا توجد حركات مسجلة حتى الآن.': {'en': 'No movements recorded yet.',
                                   'fr': 'Aucun mouvement enregistré pour le moment.'},
 'إغلاق': {'en': 'Close', 'fr': 'Fermer'},
 'إدخال مخزون': {'en': 'Stock Entry', 'fr': 'Entrée de stock'},
 'المنتج': {'en': 'Product', 'fr': 'Produit'},
 'اكتب اسم المنتج أو الباركود...': {'en': 'Enter product name or barcode...',
                                    'fr': 'Saisissez le nom du produit ou le code-barres...'},
 'لا توجد منتجات مطابقة': {'en': 'No matching products', 'fr': 'Aucun produit correspondant'},
 'اختيار': {'en': 'Select', 'fr': 'Sélectionner'},
 'الكمية المراد إدخالها': {'en': 'Quantity to add', 'fr': 'Quantité à ajouter'},
 'السبب (مثال: شراء من المورد)': {'en': 'Reason (e.g. supplier purchase)', 'fr': 'Motif (ex. achat fournisseur)'},
 'ابحث بالاسم أو الباركود...': {'en': 'Search by name or barcode...', 'fr': 'Rechercher par nom ou code-barres...'},
 'ابحث باسم المنتج، Barcode أو SKU…': {'en': 'Search product, barcode or SKU…',
                                       'fr': 'Rechercher produit, code-barres ou SKU…'},
 'السلة': {'en': 'Cart', 'fr': 'Panier'},
 'العميل': {'en': 'Customer', 'fr': 'Client'},
 'تغيير': {'en': 'Change', 'fr': 'Modifier'},
 'الخصم': {'en': 'Discount', 'fr': 'Remise'},
 'تعديل': {'en': 'Edit', 'fr': 'Modifier'},
 'الدفع  [F8]': {'en': 'Pay [F8]', 'fr': 'Payer [F8]'},
 'مسح السلة': {'en': 'Clear Cart', 'fr': 'Vider le panier'},
 'خصم الفاتورة': {'en': 'Invoice Discount', 'fr': 'Remise facture'},
 'زبون نقدي': {'en': 'Cash Customer', 'fr': 'Client comptant'},
 'غير متوفر': {'en': 'Unavailable', 'fr': 'Indisponible'},
 'اختيار العميل': {'en': 'Select Customer', 'fr': 'Sélectionner le client'},
 'ابحث بالاسم أو الهاتف…': {'en': 'Search by name or phone…', 'fr': 'Rechercher par nom ou téléphone…'},
 'أدخل الوزن / الكمية': {'en': 'Enter weight / quantity', 'fr': 'Saisissez le poids / la quantité'},
 'أدخل السعر': {'en': 'Enter price', 'fr': 'Saisissez le prix'},
 'الوزن / الكمية': {'en': 'Weight / Quantity', 'fr': 'Poids / Quantité'},
 'السعر الذي تريد شراءه (دج)': {'en': 'Price you want to buy (DZD)', 'fr': 'Prix souhaité (DZD)'},
 'إضافة إلى السلة': {'en': 'Add to Cart', 'fr': 'Ajouter au panier'},
 'السلة فارغة': {'en': 'Cart is empty', 'fr': 'Le panier est vide'},
 'إتمام البيع': {'en': 'Complete Sale', 'fr': 'Finaliser la vente'},
 'طريقة الدفع': {'en': 'Payment Method', 'fr': 'Mode de paiement'},
 'المبلغ المدفوع': {'en': 'Paid Amount', 'fr': 'Montant payé'},
 'تأكيد البيع': {'en': 'Confirm Sale', 'fr': 'Confirmer la vente'},
 '💰 تسديد ديون العملاء': {'en': '💰 Customer Debt Payments', 'fr': '💰 Paiement des dettes clients'},
 'تسديد دين': {'en': 'Pay Debt', 'fr': 'Payer la dette'},
 'إضافة عميل': {'en': 'Add Customer', 'fr': 'Ajouter un client'},
 'عليه دين': {'en': 'Has debt', 'fr': 'A une dette'},
 'تسديد الدين': {'en': 'Debt Payment', 'fr': 'Paiement de dette'},
 'تسديد': {'en': 'Pay', 'fr': 'Payer'},
 'عرض': {'en': 'View', 'fr': 'Voir'},
 'الرصيد المستحق': {'en': 'Outstanding Balance', 'fr': 'Solde dû'},
 'سجل الديون والمدفوعات': {'en': 'Debt & Payment History', 'fr': 'Historique des dettes et paiements'},
 'لا توجد عمليات مسجلة في سجل الديون بعد': {'en': 'No debt transactions recorded yet',
                                            'fr': 'Aucune opération de dette enregistrée'},
 '💰 تسديد المتبقي': {'en': '💰 Pay Remaining', 'fr': '💰 Payer le reste'},
 'تفاصيل الفاتورة': {'en': 'Invoice Details', 'fr': 'Détails de la facture'},
 '🧾 طباعة 80mm': {'en': '🧾 Print 80mm', 'fr': '🧾 Imprimer 80mm'},
 '📄 طباعة A4': {'en': '📄 Print A4', 'fr': '📄 Imprimer A4'},
 '💰 تسديد دين عميل': {'en': '💰 Pay Customer Debt', 'fr': '💰 Payer la dette client'},
 'اختر العميل الذي تريد تسجيل دفعة له': {'en': 'Select the customer to record a payment for',
                                         'fr': 'Sélectionnez le client pour enregistrer un paiement'},
 'لا يوجد عملاء عليهم ديون حاليًا': {'en': 'No customers currently have debts',
                                     'fr': "Aucun client n'a actuellement de dette"},
 'الدين الحالي': {'en': 'Current Debt', 'fr': 'Dette actuelle'},
 'مبلغ التسديد': {'en': 'Payment Amount', 'fr': 'Montant du paiement'},
 'تسديد كامل': {'en': 'Pay in Full', 'fr': 'Payer intégralement'},
 'تأكيد التسديد': {'en': 'Confirm Payment', 'fr': 'Confirmer le paiement'},
 '📈 تقرير الأرباح': {'en': '📈 Profit Report', 'fr': '📈 Rapport des bénéfices'},
 'لا توجد تنبيهات أو بيانات إضافية': {'en': 'No additional alerts or data',
                                      'fr': 'Aucune alerte ou donnée supplémentaire'},
 '🏪 معلومات المتجر': {'en': '🏪 Store Information', 'fr': '🏪 Informations du magasin'},
 'تظهر هذه المعلومات في الفواتير.': {'en': 'This information appears on invoices.',
                                     'fr': 'Ces informations apparaissent sur les factures.'},
 '🧾 الفواتير والطباعة': {'en': '🧾 Invoices & Printing', 'fr': '🧾 Factures & impression'},
 'حجم الفاتورة الافتراضي': {'en': 'Default invoice size', 'fr': 'Format de facture par défaut'},
 '💰 البيع والديون': {'en': '💰 Sales & Debts', 'fr': '💰 Ventes & dettes'},
 '📦 المخزون': {'en': '📦 Inventory', 'fr': '📦 Stock'},
 '🎨 المظهر': {'en': '🎨 Appearance', 'fr': '🎨 Apparence'},
 'اختر مظهر البرنامج': {'en': 'Choose application appearance', 'fr': "Choisissez l'apparence de l'application"},
 '💾 حفظ الإعدادات': {'en': '💾 Save Settings', 'fr': '💾 Enregistrer les paramètres'},
 '💾 نسخة احتياطية الآن': {'en': '💾 Backup Now', 'fr': '💾 Sauvegarder maintenant'},
 'معلومات الترخيص': {'en': 'License Information', 'fr': 'Informations de licence'},
 'طباعة الفاتورة بعد الدفع': {'en': 'Invoice printing after payment', 'fr': 'Impression de facture après paiement'},
 'طباعة الفاتورة تلقائياً': {'en': 'Print invoice automatically', 'fr': 'Imprimer automatiquement la facture'},
 'مظهر البرنامج': {'en': 'Application appearance', 'fr': "Apparence de l'application"},
 'فاتح': {'en': 'Light', 'fr': 'Clair'},
 'داكن': {'en': 'Dark', 'fr': 'Sombre'},
 'رمادي': {'en': 'Grey', 'fr': 'Gris'},
 '＋ إضافة مورد': {'en': '＋ Add Supplier', 'fr': '＋ Ajouter un fournisseur'},
 'ابحث باسم المورد أو الهاتف...': {'en': 'Search supplier by name or phone...',
                                   'fr': 'Rechercher un fournisseur par nom ou téléphone...'},
 'لا توجد نتائج.': {'en': 'No results.', 'fr': 'Aucun résultat.'},
 'ملاحظات': {'en': 'Notes', 'fr': 'Notes'},
 '✓ حفظ المورد': {'en': '✓ Save Supplier', 'fr': '✓ Enregistrer le fournisseur'},
 'اسم المتجر': {'en': 'Store Name', 'fr': 'Nom du magasin'},
 'رقم الهاتف': {'en': 'Phone Number', 'fr': 'Numéro de téléphone'},
 'العنوان': {'en': 'Address', 'fr': 'Adresse'},
 'رسالة أسفل الفاتورة': {'en': 'Invoice footer message', 'fr': 'Message en bas de facture'},
 'حد المخزون المنخفض': {'en': 'Low stock threshold', 'fr': 'Seuil de stock faible'},
 'السماح بتسجيل المبيعات بالدين': {'en': 'Allow sales on credit', 'fr': 'Autoriser les ventes à crédit'},
 'اسألني قبل طباعة الفاتورة': {'en': 'Ask before printing the invoice', 'fr': "Demander avant d'imprimer la facture"},
 'اللغة': {'en': 'Language', 'fr': 'Langue'},
 'اختر لغة البرنامج': {'en': 'Choose application language', 'fr': "Choisissez la langue de l'application"},
 'تحديث': {'en': 'Refresh', 'fr': 'Actualiser'},
 'حذف': {'en': 'Delete', 'fr': 'Supprimer'},
 'حفظ': {'en': 'Save', 'fr': 'Enregistrer'},
 'الإجراءات': {'en': 'Actions', 'fr': 'Actions'},
 'تأكيد الهوية': {'en': 'Identity Confirmation', 'fr': "Confirmation d'identité"},
 'رمز PIN': {'en': 'PIN code', 'fr': 'Code PIN'},
 'محاولات متبقية': {'en': 'Attempts left', 'fr': 'Tentatives restantes'},
 'تأكيد': {'en': 'Confirm', 'fr': 'Confirmer'},
 'رمز PIN غير صحيح': {'en': 'Incorrect PIN code', 'fr': 'Code PIN incorrect'},
 '👤 تسجيل الدخول': {'en': '👤 Login', 'fr': '👤 Connexion'},
 'تسجيل الدخول': {'en': 'Login', 'fr': 'Connexion'},
 'تبديل المستخدم': {'en': 'Switch User', 'fr': "Changer d'utilisateur"},
 'اختر المستخدم ثم أدخل رمز PIN': {'en': 'Select a user then enter the PIN', 'fr': "Sélectionnez un utilisateur puis saisissez le PIN"},
 'دخول': {'en': 'Login', 'fr': 'Connexion'},
 'تخطي': {'en': 'Skip', 'fr': 'Passer'},
 'تم تسجيل الدخول': {'en': 'Logged in', 'fr': 'Connecté'},
 'إعداد المدير': {'en': 'Admin Setup', 'fr': "Configuration de l'administrateur"},
 'أنشئ حساب المدير الأول لاستخدام حماية PIN.': {'en': 'Create the first admin account to use PIN protection.',
                                                  'fr': "Créez le premier compte administrateur pour utiliser la protection PIN."},
 'اسم المدير': {'en': 'Admin name', 'fr': "Nom de l'administrateur"},
 'رمز PIN (4-6 أرقام)': {'en': 'PIN code (4-6 digits)', 'fr': 'Code PIN (4 à 6 chiffres)'},
 'تأكيد رمز PIN': {'en': 'Confirm PIN code', 'fr': 'Confirmer le code PIN'},
 'الاسم مطلوب': {'en': 'Name is required', 'fr': 'Le nom est requis'},
 'الرمز يجب أن يكون أرقامًا من 4 إلى 6 خانات': {'en': 'PIN must be 4 to 6 digits',
                                                 'fr': 'Le PIN doit comporter 4 à 6 chiffres'},
 'الرمزان غير متطابقين': {'en': 'PIN codes do not match', 'fr': 'Les codes PIN ne correspondent pas'},
 'تعذر إنشاء الحساب': {'en': 'Could not create the account', 'fr': "Impossible de créer le compte"},
 'تم إنشاء حساب المدير': {'en': 'Admin account created', 'fr': 'Compte administrateur créé'},
 '✓ إنشاء الحساب': {'en': '✓ Create Account', 'fr': '✓ Créer le compte'},
 '📋 سجل النشاطات': {'en': '📋 Activity Log', 'fr': '📋 Journal des activités'},
 'كل العمليات الحساسة مسجلة باسم المستخدم والتاريخ.': {'en': 'Every sensitive action is recorded with user name and date.',
                                                        'fr': 'Chaque action sensible est enregistrée avec le nom et la date.'},
 'ابحث بالمستخدم أو نوع الإجراء...': {'en': 'Search by user or action type...', 'fr': "Rechercher par utilisateur ou type d'action..."},
 'من 2026-01-01': {'en': 'From 2026-01-01', 'fr': 'Du 2026-01-01'},
 'إلى 2026-12-31': {'en': 'To 2026-12-31', 'fr': 'Au 2026-12-31'},
 'التاريخ': {'en': 'Date', 'fr': 'Date'},
 'المستخدم': {'en': 'User', 'fr': 'Utilisateur'},
 'الإجراء': {'en': 'Action', 'fr': 'Action'},
 'النوع': {'en': 'Type', 'fr': 'Type'},
 'التفاصيل': {'en': 'Details', 'fr': 'Détails'},
 'تعذر تحميل السجل': {'en': 'Could not load the log', 'fr': 'Impossible de charger le journal'},
 'لا توجد عمليات مسجلة بعد.': {'en': 'No actions recorded yet.', 'fr': "Aucune action enregistrée pour le moment."},
 '🏷 التصنيفات': {'en': '🏷 Categories', 'fr': '🏷 Catégories'},
 '🏷 إدارة التصنيفات': {'en': '🏷 Category Management', 'fr': '🏷 Gestion des catégories'},
 "نظّم منتجاتك في أقسام، وحذف التصنيف ينقل منتجاته إلى 'بدون تصنيف'.":
     {'en': "Organize products into sections; deleting a category moves its products to 'Uncategorized'.",
      'fr': "Organisez vos produits par rayon ; supprimer une catégorie déplace ses produits vers « Sans catégorie »."},
 'اسم التصنيف الجديد': {'en': 'New category name', 'fr': 'Nom de la nouvelle catégorie'},
 'إضافة تصنيف': {'en': 'Add Category', 'fr': 'Ajouter une catégorie'},
 'اسم التصنيف مطلوب': {'en': 'Category name is required', 'fr': 'Le nom de la catégorie est requis'},
 'تمت إضافة التصنيف': {'en': 'Category added', 'fr': 'Catégorie ajoutée'},
 'هذا التصنيف موجود مسبقاً': {'en': 'This category already exists', 'fr': 'Cette catégorie existe déjà'},
 'تعديل التصنيف': {'en': 'Edit Category', 'fr': 'Modifier la catégorie'},
 'تم تحديث التصنيف': {'en': 'Category updated', 'fr': 'Catégorie mise à jour'},
 'هذا الاسم مستخدم مسبقاً': {'en': 'This name is already used', 'fr': 'Ce nom est déjà utilisé'},
 'حذف التصنيف': {'en': 'Delete Category', 'fr': 'Supprimer la catégorie'},
 'سيتم نقل منتجات هذا التصنيف إلى': {'en': 'Products in this category will be moved to',
                                      'fr': 'Les produits de cette catégorie seront déplacés vers'},
 'بدون تصنيف': {'en': 'Uncategorized', 'fr': 'Sans catégorie'},
 'هل تريد المتابعة؟': {'en': 'Do you want to continue?', 'fr': 'Voulez-vous continuer ?'},
 'منتج': {'en': 'product(s)', 'fr': 'produit(s)'},
 'هل تريد حذف هذا التصنيف؟': {'en': 'Delete this category?', 'fr': 'Supprimer cette catégorie ?'},
 'حذف تصنيف': {'en': 'Delete category', 'fr': 'Supprimer une catégorie'},
 'منتجات معاد تعيينها': {'en': 'products reassigned', 'fr': 'produits réaffectés'},
 'تم حذف التصنيف': {'en': 'Category deleted', 'fr': 'Catégorie supprimée'},
 'تعذر الحذف': {'en': 'Delete failed', 'fr': 'Échec de la suppression'},
 'لا توجد تصنيفات بعد': {'en': 'No categories yet', 'fr': 'Aucune catégorie pour le moment'},
 'كل التصنيفات': {'en': 'All categories', 'fr': 'Toutes les catégories'},
 'التصنيف': {'en': 'Category', 'fr': 'Catégorie'},
 '👥 المستخدمون': {'en': '👥 Users', 'fr': '👥 Utilisateurs'},
 '👥 إدارة المستخدمين': {'en': '👥 User Management', 'fr': '👥 Gestion des utilisateurs'},
 'إنشاء المستخدمين وتغيير الرموز والأدوار.': {'en': 'Create users, change PINs and roles.',
                                               'fr': 'Créez des utilisateurs, modifiez les PIN et les rôles.'},
 'الاسم': {'en': 'Name', 'fr': 'Nom'},
 'الدور': {'en': 'Role', 'fr': 'Rôle'},
 'مدير': {'en': 'Admin', 'fr': 'Administrateur'},
 'كاشير': {'en': 'Cashier', 'fr': 'Caissier'},
 '＋ إضافة مستخدم': {'en': '＋ Add User', 'fr': '＋ Ajouter un utilisateur'},
 'اسم المستخدم مطلوب': {'en': 'User name is required', 'fr': "Le nom de l'utilisateur est requis"},
 'يوجد مستخدم بنفس الاسم': {'en': 'A user with this name already exists', 'fr': 'Un utilisateur portant ce nom existe déjà'},
 'تمت إضافة المستخدم': {'en': 'User added', 'fr': 'Utilisateur ajouté'},
 'تغيير الرمز': {'en': 'Change PIN', 'fr': 'Changer le PIN'},
 'رمز جديد': {'en': 'New PIN', 'fr': 'Nouveau PIN'},
 'تم تغيير الرمز': {'en': 'PIN changed', 'fr': 'PIN modifié'},
 'تعذر تغيير الرمز': {'en': 'Could not change the PIN', 'fr': 'Impossible de changer le PIN'},
 'حذف المستخدم': {'en': 'Delete User', 'fr': "Supprimer l'utilisateur"},
 'هل تريد حذف هذا المستخدم؟': {'en': 'Delete this user?', 'fr': "Supprimer cet utilisateur ?"},
 'لا يمكن حذف آخر مدير': {'en': 'Cannot delete the last admin', 'fr': 'Impossible de supprimer le dernier administrateur'},
 'تم حذف المستخدم': {'en': 'User deleted', 'fr': 'Utilisateur supprimé'},
 'تعذر حذف المستخدم': {'en': 'Could not delete the user', 'fr': "Impossible de supprimer l'utilisateur"},
 'لا يوجد مستخدمون': {'en': 'No users', 'fr': 'Aucun utilisateur'},
 'إدارة المستخدمين': {'en': 'User management', 'fr': 'Gestion des utilisateurs'},
 'خصم على المنتج': {'en': 'Item Discount', 'fr': 'Remise sur article'},
 'المجموع قبل الخصم': {'en': 'Subtotal before discount', 'fr': 'Sous-total avant remise'},
 'أدخل قيمة الخصم بالدينار (0 لإلغاء الخصم).': {'en': 'Enter the discount amount in DZD (0 to cancel).',
                                                 'fr': 'Saisissez le montant de la remise en DA (0 pour annuler).'},
 'أدخل قيمة خصم صحيحة': {'en': 'Enter a valid discount amount', 'fr': 'Saisissez un montant de remise valide'},
 'الخصم لا يمكن أن يكون سالبًا': {'en': 'Discount cannot be negative', 'fr': 'La remise ne peut pas être négative'},
 'الخصم يتجاوز قيمة هذا المنتج': {'en': 'Discount exceeds this item total', 'fr': 'La remise dépasse le total de cet article'},
 'تم تطبيق خصم المنتج': {'en': 'Item discount applied', 'fr': 'Remise sur article appliquée'},
 'خصم المنتج': {'en': 'Item discount', 'fr': 'Remise sur article'},
 'مضمّن في الخصم أعلاه': {'en': 'included in the discount above', 'fr': 'inclus dans la remise ci-dessus'},
 'حد الخصم الذي يتطلب رمز PIN': {'en': 'Discount threshold requiring PIN', 'fr': 'Seuil de remise exigeant un PIN'},
 'الاتصال بخادم MySQL/MariaDB لمشاركة البيانات بين عدة أجهزة.':
     {'en': 'Connect to a MySQL/MariaDB server to share data across multiple PCs.',
      'fr': "Connexion à un serveur MySQL/MariaDB pour partager les données entre plusieurs PC."},
 'عنوان الخادم': {'en': 'Server address', 'fr': 'Adresse du serveur'},
 'المنفذ': {'en': 'Port', 'fr': 'Port'},
 'اسم المستخدم': {'en': 'Username', 'fr': "Nom d'utilisateur"},
 'كلمة المرور': {'en': 'Password', 'fr': 'Mot de passe'},
 'اسم قاعدة البيانات': {'en': 'Database name', 'fr': 'Nom de la base de données'},
 'عنوان IP لهذا الجهاز':
     {'en': 'This PC IP address', 'fr': 'Adresse IP de cet appareil'},
 'عرض كلمة المرور': {'en': 'Show password', 'fr': 'Afficher le mot de passe'},
 'لم يتم التحقق من الهوية. تبقى كلمة المرور مخفية.':
     {'en': 'Identity not verified. The password stays hidden.',
      'fr': "Identité non vérifiée. Le mot de passe reste masqué."},
 'اختبار وحفظ الاتصال': {'en': 'Test & Save Connection', 'fr': 'Tester et enregistrer la connexion'},
 'تعديل إعدادات قاعدة البيانات': {'en': 'Edit database settings', 'fr': 'Modifier les paramètres de la base de données'},
 'المنفذ يجب أن يكون رقمًا صحيحًا بين 1 و 65535':
     {'en': 'Port must be a number between 1 and 65535',
      'fr': 'Le port doit être un nombre entre 1 et 65535'},
 'فشل الاتصال بالخادم': {'en': 'Server connection failed', 'fr': 'Échec de connexion au serveur'},
 'تم حفظ إعدادات قاعدة البيانات. أعد تشغيل البرنامج لتطبيق التغييرات.':
     {'en': 'Database settings saved. Restart the app to apply changes.',
      'fr': "Paramètres de la base de données enregistrés. Redémarrez l'application pour les appliquer."},
 'تعذر حفظ ملف الإعدادات': {'en': 'Could not save the settings file', 'fr': "Impossible d'enregistrer le fichier de paramètres"},
 'إعداد الجهاز': {'en': 'Device Setup', 'fr': "Configuration de l'appareil"},
 'اختر دور هذا الجهاز — يمكنك تغييره لاحقًا من الإعدادات.':
     {'en': 'Choose this device role — you can change it later in Settings.',
      'fr': "Choisissez le rôle de cet appareil — modifiable plus tard dans les paramètres."},
 'هذا الجهاز الرئيسي': {'en': 'This is the Main Device', 'fr': 'Cet appareil est le principal'},
 'سيتم تخزين البيانات على هذا الجهاز ومشاركتها مع باقي الأجهزة.':
     {'en': 'Data will be stored on this device and shared with the other devices.',
      'fr': 'Les données seront stockées sur cet appareil et partagées avec les autres.'},
 'جهاز إضافي': {'en': 'Additional Device', 'fr': 'Appareil supplémentaire'},
 'سيتصل تلقائيًا بالجهاز الرئيسي لاستخدام نفس قاعدة البيانات.':
     {'en': 'It will connect automatically to the main device to use the same database.',
      'fr': 'Il se connectera automatiquement à l’appareil principal pour utiliser la même base de données.'},
 'سيتم البحث عن الجهاز الرئيسي تلقائيًا على الشبكة المحلية.':
     {'en': 'The main device will be searched automatically on the local network.',
      'fr': "L'appareil principal sera recherché automatiquement sur le réseau local."},
 'جاري البحث عن الجهاز الرئيسي': {'en': 'Searching for the main device', 'fr': "Recherche de l'appareil principal"},
 'تأكد من تشغيل الجهاز الرئيسي واتصال الجهازين بنفس الشبكة.':
     {'en': 'Make sure the main device is on and both devices are on the same network.',
      'fr': "Assurez-vous que l'appareil principal est allumé et que les deux sont sur le même réseau."},
 'إلغاء البحث': {'en': 'Cancel Search', 'fr': 'Annuler la recherche'},
 'لم يتم العثور على الجهاز الرئيسي تلقائيًا':
     {'en': 'Main device was not found automatically', 'fr': "Appareil principal introuvable automatiquement"},
 'تأكد من أن الجهازين على نفس شبكة WiFi/الشبكة، وأن الجهاز الرئيسي يعمل، وأنك سمحت للبرنامج في جدار الحماية.':
     {'en': 'Make sure both devices are on the same WiFi/network, the main device is running, and the app is allowed in the firewall.',
      'fr': "Vérifiez que les deux appareils sont sur le même WiFi/réseau, que l'appareil principal fonctionne et que l'application est autorisée dans le pare-feu."},
 'عنوان IP': {'en': 'IP address', 'fr': 'Adresse IP'},
 'اتصال يدوي': {'en': 'Manual Connect', 'fr': 'Connexion manuelle'},
 'إعادة المحاولة': {'en': 'Retry', 'fr': 'Réessayer'},
 'رجوع': {'en': 'Back', 'fr': 'Retour'},
 'جاري الاتصال ب': {'en': 'Connecting to', 'fr': 'Connexion à'},
 'تعذر الاتصال': {'en': 'Could not connect', 'fr': 'Impossible de se connecter'},
 'أدخل عنوان IP للجهاز الرئيسي': {'en': 'Enter the main device IP address', 'fr': "Saisissez l'adresse IP de l'appareil principal"},
 'تم ضبط هذا الجهاز كجهاز رئيسي': {'en': 'This device is now set as the main device', 'fr': 'Cet appareil est maintenant le principal'},
 'تم الاتصال بالجهاز الرئيسي': {'en': 'Connected to the main device', 'fr': "Connecté à l'appareil principal"},
 'لم يتم العثور على خادم MySQL/MariaDB محلي يعمل.':
     {'en': 'No running local MySQL/MariaDB server was found.', 'fr': 'Aucun serveur MySQL/MariaDB local en cours.'},
 'هل تريد حفظ الإعدادات والمتابعة على أي حال؟':
     {'en': 'Save settings and continue anyway?', 'fr': 'Enregistrer et continuer quand même ?'},
 'تغيير وضع الشبكة': {'en': 'Change Network Mode', 'fr': 'Changer le mode réseau'},
 'الوضع الحالي': {'en': 'Current mode', 'fr': 'Mode actuel'},
 'رئيسي': {'en': 'Main', 'fr': 'Principal'},
 'إضافي': {'en': 'Additional', 'fr': 'Supplémentaire'},
 'جهاز واحد': {'en': 'Single PC', 'fr': 'PC unique'},
 'غير محدد': {'en': 'Not set', 'fr': 'Non défini'},
 'متصل': {'en': 'Online', 'fr': 'Connecté'},
 'غير متصل بالخادم': {'en': 'Server offline', 'fr': 'Serveur hors ligne'},
 '⚠ انقطع الاتصال بالخادم': {'en': '⚠ Server connection lost', 'fr': '⚠ Connexion au serveur perdue'},
 '✓ تم استعادة الاتصال بالخادم': {'en': '✓ Server connection restored', 'fr': '✓ Connexion au serveur rétablie'},
 'السلات المعلقة': {'en': 'Held Carts', 'fr': 'Paniers en attente'},
 'استرجاع السلة': {'en': 'Restore Cart', 'fr': 'Restaurer le panier'},
 'حذف السلة المعلقة': {'en': 'Delete Held Cart', 'fr': 'Supprimer le panier'},
 'هل تريد استبدال السلة الحالية بالسلة المعلقة؟': {'en': 'Replace current cart with this held cart?', 'fr': 'Remplacer le panier actuel par ce panier en attente ?'},
 '📥 تصدير التقرير': {'en': '📥 Export Report', 'fr': '📥 Exporter le rapport'},
 'تصدير Excel (xlsx)': {'en': 'Export Excel (xlsx)', 'fr': 'Exporter Excel (xlsx)'},
 'تصدير CSV (UTF-8)': {'en': 'Export CSV (UTF-8)', 'fr': 'Exporter CSV (UTF-8)'},
 'طباعة تقرير نهاية الوردية': {'en': 'Print End-of-Shift Report', 'fr': 'Imprimer le rapport de fin de poste'},
 'تنسيق 80mm حراري؟ (لا = A4)': {'en': 'Thermal 80mm format? (No = A4)', 'fr': 'Format thermique 80mm ? (Non = A4)'},
 'تم تصدير التقرير بنجاح': {'en': 'Report exported successfully', 'fr': 'Rapport exporté avec succès'},
 'تعذر تصدير التقرير': {'en': 'Could not export report', 'fr': 'Impossible d\'exporter le rapport'},
 'تقرير_نهاية_الوردية': {'en': 'End_of_Shift_Report', 'fr': 'Rapport_Fin_Poste'},
 'تقرير_المبيعات_المفصل': {'en': 'Detailed_Sales_Report', 'fr': 'Rapport_Detaille_Ventes'},
 'إجمالي المبيعات': {'en': 'Gross Sales', 'fr': 'Ventes brutes'},
 'النقد المحصل': {'en': 'Cash Collected', 'fr': 'Espèces encaissées'},
 'مبيعات بالدين': {'en': 'Credit Sales', 'fr': 'Ventes à crédit'},
 'ديون محصلة': {'en': 'Debts Collected', 'fr': 'Dettes recouvrées'},
 'المرتجعات': {'en': 'Returns', 'fr': 'Retours'},
 'المصاريف': {'en': 'Expenses', 'fr': 'Dépenses'},
 'الصافي النقدي في الصندوق': {'en': 'Final Cash in Drawer', 'fr': 'Solde final en caisse'},
 'رقم الصندوق': {'en': 'Register', 'fr': 'Caisse'},
 'اسم الجهاز': {'en': 'Device', 'fr': 'Appareil'},
 'التاريخ والوقت': {'en': 'Date / Time', 'fr': 'Date / Heure'},
 'الإتجاه اليومي': {'en': 'Daily Trend', 'fr': 'Tendance quotidienne'},
 'الإيراد بالساعة': {'en': 'Hourly Revenue', 'fr': 'Revenus horaires'},
 'إجمالي الإيراد': {'en': 'Total Revenue', 'fr': 'Revenu total'},
 'صافي الربح': {'en': 'Net Profit', 'fr': 'Bénéfice net'},
 'الفواتير': {'en': 'Invoices', 'fr': 'Factures'},
 'لا توجد بيانات كافية للرسم': {'en': 'Not enough data to chart', 'fr': 'Pas assez de données pour le graphique'},
 'الأرباح التفصيلية': {'en': 'Profit Breakdown', 'fr': 'Répartition des bénéfices'},
 'الأرباح حسب الفئة': {'en': 'Profit by Category', 'fr': 'Bénéfices par catégorie'},
 'تحذيرات هامش الربح': {'en': 'Profit Margin Warnings', 'fr': 'Alertes de marge bénéficiaire'},
 'منتجات تُباع بخسارة': {'en': 'Products sold at a loss', 'fr': 'Produits vendus à perte'},
 'منتجات قريبة من التكلفة': {'en': 'Products near cost', 'fr': 'Produits proches du coût'},
 'الهامش': {'en': 'Margin', 'fr': 'Marge'},
 'المنتج': {'en': 'Product', 'fr': 'Produit'},
 'الكمية': {'en': 'Quantity', 'fr': 'Quantité'},
 'الإيراد': {'en': 'Revenue', 'fr': 'Revenu'},
 'التكلفة': {'en': 'Cost', 'fr': 'Coût'},
 'الفئة': {'en': 'Category', 'fr': 'Catégorie'},
 'غير مصنّف': {'en': 'Uncategorized', 'fr': 'Non classé'},
 'عنصر': {'en': 'items', 'fr': 'articles'},
 'نعم': {'en': 'Yes', 'fr': 'Oui'},
 'تفريغ البيانات المالية': {'en': 'Financial data', 'fr': 'Données financières'},
 'تسوية الصندوق النقدي': {'en': 'Cash Drawer Reconciliation', 'fr': 'Reconciliation de la caisse'},
 'أفضل المنتجات مبيعاً': {'en': 'Top-selling Products', 'fr': 'Produits les plus vendus'},
 'قائمة المصاريف': {'en': 'Expenses List', 'fr': 'Liste des dépenses'},
 'فواتير المرتجعات والإلغاء': {'en': 'Returns & Voided Invoices', 'fr': 'Retours et factures annulées'},
 'بيانات الفترة': {'en': 'Period data', 'fr': 'Données de la période'},
 'الديون المحصلة في التقرير': {'en': 'Debts collected in report', 'fr': 'Dettes recouvrées dans le rapport'},
 'الملف محفوظ عند': {'en': 'File saved at', 'fr': 'Fichier enregistré à'},
 'يحتاج تثبيت المكتبة': {'en': 'Library required', 'fr': 'Bibliothèque requise'},
 'ثبّت openpyxl في نفس Python المستخدم لتشغيل البرنامج': {'en': 'Install openpyxl in the same Python used to run the program', 'fr': 'Installez openpyxl dans le même Python utilisé pour exécuter le programme'},
 'متوسط الفاتورة': {'en': 'Average Invoice', 'fr': 'Facture moyenne'},
 'عدد الفواتير': {'en': 'Invoice Count', 'fr': 'Nombre de factures'},
 'صافي الربح بعد المصاريف': {'en': 'Net Profit after Expenses', 'fr': 'Bénéfice net après dépenses'},
 'العدد': {'en': 'Count', 'fr': 'Nombre'},
 'المبلغ': {'en': 'Amount', 'fr': 'Montant'},
 'الدفع': {'en': 'Payment', 'fr': 'Paiement'},
 'الجهاز': {'en': 'Device', 'fr': 'Appareil'},
 'التاريخ': {'en': 'Date', 'fr': 'Date'},
 'ملاحظة': {'en': 'Note', 'fr': 'Note'},
 'رقم الفاتورة': {'en': 'Invoice No.', 'fr': 'N° facture'},
 'حالة': {'en': 'Status', 'fr': 'Statut'},
 'نوع الآلة': {'en': 'Type', 'fr': 'Type'},
 'قيمة': {'en': 'Value', 'fr': 'Valeur'},
 'إجماليات الفترة': {'en': 'Period Totals', 'fr': 'Totaux de la période'},
 'حفظ تقرير CSV': {'en': 'Save CSV Report', 'fr': 'Enregistrer le rapport CSV'},
 'حفظ تقرير Excel': {'en': 'Save Excel Report', 'fr': 'Enregistrer le rapport Excel'},
 'حفظ تقرير PDF': {'en': 'Save PDF Report', 'fr': 'Enregistrer le rapport PDF'},
 'اختر تنسيق التصدير': {'en': 'Choose export format', 'fr': 'Choisir le format d\'export'},
 'لا توجد منتجات بهامش منخفض': {'en': 'No products with low margin', 'fr': 'Aucun produit à marge faible'},
 'الفواتير الملغاة': {'en': 'Voided Invoices', 'fr': 'Factures annulées'},
 'الخصومات': {'en': 'Discounts', 'fr': 'Remises'},
 'مرّر المؤشر فوق النقاط لعرض التفاصيل': {'en': 'Hover over the points for details', 'fr': 'Survolez les points pour les détails'},
 'المؤشر': {'en': 'Metric', 'fr': 'Indicateur'},
 'القيمة': {'en': 'Value', 'fr': 'Valeur'},
 'نقدًا': {'en': 'Cash', 'fr': 'Espèces'},
 'خارجي': {'en': 'External', 'fr': 'Externe'},
 'تفريغ البيانات المالية': {'en': 'Financial Data', 'fr': 'Données financières'},
 'الفئات المربحة': {'en': 'Profitable categories', 'fr': 'Catégories rentables'},
 'خسارة': {'en': 'loss', 'fr': 'perte'},
 'منتج قريب الانتهاء': {'en': 'products expiring soon', 'fr': 'produits bientôt périmés'},
 'منتج منخفض': {'en': 'products low', 'fr': 'produits bas'},
 'منتج نافد': {'en': 'products out of stock', 'fr': 'produits en rupture'},
 'لديهم ديون': {'en': 'with debts', 'fr': 'avec dettes'},
 ' عملية بيع': {'en': ' sales', 'fr': ' ventes'},
 ' فاتورة': {'en': ' invoice', 'fr': ' facture'},
 'فاتورة ': {'en': 'Invoice ', 'fr': 'Facture '},
 'فاتورة_': {'en': 'Invoice_', 'fr': 'Facture_'},
 'متوفر ': {'en': 'In stock ', 'fr': 'En stock '},
 ' زبون': {'en': ' customers', 'fr': ' clients'},
 'اليوم': {'en': 'Today', 'fr': "Aujourd'hui"},
 'البارحة': {'en': 'Yesterday', 'fr': 'Hier'},
 'آخر_7_أيام': {'en': 'Last_7_days', 'fr': 'Sept_derniers_jours'},
 'هذا_الشهر': {'en': 'This_month', 'fr': 'Ce_mois'},
 'مبيعات اليوم': {'en': "Today's Sales", 'fr': 'Ventes du jour'},
 'متوسط مبيعات اليوم': {'en': "Today's Avg. Sales", 'fr': 'Ventes moyennes du jour'},
 'إجمالي الديون': {'en': 'Total Debt', 'fr': 'Dettes totales'},
 'قيمة المخزون': {'en': 'Stock Value', 'fr': 'Valeur du stock'},
 '＋ منتج جديد': {'en': '＋ New Product', 'fr': '＋ Nouveau produit'},
 '＋ زبون جديد': {'en': '＋ New Customer', 'fr': '＋ Nouveau client'},
 '📦 فتح المخزون': {'en': '📦 Open Stock', 'fr': '📦 Ouvrir le stock'},
 '⟳ تحديث البيانات': {'en': '⟳ Refresh Data', 'fr': '⟳ Actualiser'},
 '📦 المنتجات': {'en': '📦 Products', 'fr': '📦 Produits'},
 '🔴 نافد': {'en': '🔴 Out of stock', 'fr': '🔴 Rupture'},
 '🟠 منخفض': {'en': '🟠 Low', 'fr': '🟠 Faible'},
 '🟡 قريب الانتهاء': {'en': '🟡 Expiring soon', 'fr': '🟡 Expiration proche'},
 'تكلفة البضاعة': {'en': 'Cost of Goods', 'fr': 'Coût des marchandises'},
 'إجمالي الديون المسجلة': {'en': 'Total Recorded Debt', 'fr': 'Total des dettes enregistrées'},
 'إجمالي المدفوعات المسجلة': {'en': 'Total Recorded Payments', 'fr': 'Total des paiements enregistrés'},
 'الإجمالي قبل الخصم': {'en': 'Total Before Discount', 'fr': 'Total avant remise'},
 'المدفوع': {'en': 'Paid', 'fr': 'Payé'},
 'الباقي/المتبقي': {'en': 'Remaining', 'fr': 'Restant'},
 'سعر الوحدة': {'en': 'Unit Price', 'fr': 'Prix unitaire'},
 'الإجمالي': {'en': 'Total', 'fr': 'Total'},
 'الباقي': {'en': 'Remaining', 'fr': 'Reste'},
 'دين هذه الفاتورة': {'en': "This Invoice's Debt", 'fr': 'Dette de cette facture'},
 'رصيد العميل بعد العملية': {'en': 'Customer Balance After Sale', 'fr': 'Solde du client après la vente'},
 'إجمالي المصاريف': {'en': 'Total Expenses', 'fr': 'Total des dépenses'},
 'من الصندوق (نقد)': {'en': 'From Drawer (Cash)', 'fr': 'Du tiroir (espèces)'},
 'عدد المصروفات': {'en': 'Expense Count', 'fr': 'Nombre de dépenses'},
 'نقدي بالصندوق': {'en': 'Cash in Drawer', 'fr': 'Espèces en caisse'},
 'مبيعات بالدين': {'en': 'Debt Sales', 'fr': 'Ventes à crédit'},
 'ديون محصلة': {'en': 'Collected Debts', 'fr': 'Dettes recouvrées'},
 'مرتجعات نقدية': {'en': 'Cash Returns', 'fr': 'Retours en espèces'},
 'مصاريف من الصندوق': {'en': 'Drawer Expenses', 'fr': 'Dépenses du tiroir'},
 'إجراءات': {'en': 'Actions', 'fr': 'Actions'},
 'الإجراءات': {'en': 'Actions', 'fr': 'Actions'},
 '#': {'en': '#', 'fr': '#'},
 'الإيراد': {'en': 'Revenue', 'fr': 'Revenus'},
 'التكلفة': {'en': 'Cost', 'fr': 'Coût'},
 'الهاتف': {'en': 'Phone', 'fr': 'Téléphone'},
 'الرصيد': {'en': 'Balance', 'fr': 'Solde'},
 'الوحدة': {'en': 'Unit', 'fr': 'Unité'},
 'المخزون الحالي': {'en': 'Current Stock', 'fr': 'Stock actuel'},
 'الكمية المباعة': {'en': 'Sold Quantity', 'fr': 'Quantité vendue'},
 'الجهاز': {'en': 'Device', 'fr': 'Appareil'},
 'عدد الوصلات': {'en': 'Receipts', 'fr': 'Reçus'},
 'إجمالي الإيراد': {'en': 'Total Revenue', 'fr': 'Revenu total'},
 'المرتجعات': {'en': 'Returns', 'fr': 'Retours'},
 'العنوان': {'en': 'Address', 'fr': 'Adresse'},
 'الفئة': {'en': 'Category', 'fr': 'Catégorie'},
 'المبلغ': {'en': 'Amount', 'fr': 'Montant'},
 'الدفع': {'en': 'Payment', 'fr': 'Paiement'},
 'ملاحظة': {'en': 'Note', 'fr': 'Note'},
 'نفد المخزون': {'en': 'Out of stock', 'fr': 'Rupture de stock'},
 'منخفض': {'en': 'Low', 'fr': 'Faible'},
 'المسؤول': {'en': 'Contact Person', 'fr': 'Responsable'},
 'البريد': {'en': 'Email', 'fr': 'Email'},
 'إضافة مورد': {'en': 'Add Supplier', 'fr': 'Ajouter un fournisseur'},
 'تعديل المورد': {'en': 'Edit Supplier', 'fr': 'Modifier le fournisseur'},
 'معلومات الترخيص غير متوفرة': {'en': 'License information unavailable', 'fr': 'Informations de licence indisponibles'},
 'نقدًا من الصندوق': {'en': 'Paid from drawer (cash)', 'fr': 'Payé du tiroir (espèces)'},
 'سُدد خارجيًا': {'en': 'Paid externally', 'fr': "Payé à l'extérieur"},
 'أدخل رقم الفاتورة': {'en': 'Enter invoice number', 'fr': 'Entrez le numéro de facture'},
 'الفاتورة غير موجودة': {'en': 'Invoice not found', 'fr': 'Facture introuvable'},
 'حمّل فاتورة أولاً': {'en': 'Load an invoice first', 'fr': "Chargez d'abord une facture"},
 'لا توجد كميات قابلة للإرجاع في هذه الفاتورة': {'en': 'No quantities available to return in this invoice', 'fr': 'Aucune quantité à retourner dans cette facture'},
 'اسم الزبون مطلوب': {'en': 'Customer name is required', 'fr': 'Le nom du client est requis'},
 '✓ تمت إضافة الزبون': {'en': '✓ Customer added', 'fr': '✓ Client ajouté'},
 '✓ تم تحديث المنتج': {'en': '✓ Product updated', 'fr': '✓ Produit mis à jour'},
 '✓ تمت إضافة المنتج': {'en': '✓ Product added', 'fr': '✓ Produit ajouté'},
 'قريب الانتهاء': {'en': 'Expiring soon', 'fr': 'Expiration proche'},
 'بدون هاتف': {'en': 'No phone', 'fr': 'Sans téléphone'},
 'عميل نقدي': {'en': 'Cash customer', 'fr': 'Client au comptant'},
 'العملية': {'en': 'Operation', 'fr': 'Opération'},
 'البيان': {'en': 'Details', 'fr': 'Détails'},
 'المرجع': {'en': 'Reference', 'fr': 'Référence'},
 '🏆 أفضل المنتجات': {'en': '🏆 Top Products', 'fr': '🏆 Meilleurs produits'},
 '🕒 أوقات الذروة وتوقع الازدحام': {'en': '🕒 Peak Hours & Crowd Forecast', 'fr': '🕒 Heures de pointe et prévision d\'affluence'},
 '📦 المنتجات الراكدة': {'en': '📦 Slow-Moving Products', 'fr': '📦 Produits à rotation lente'},
 '🖥️ توزيع الأجهزة': {'en': '🖥️ Device Breakdown', 'fr': '🖥️ Répartition des appareils'},
 '↩️ المرتجعات والإلغاء': {'en': '↩️ Returns & Cancellations', 'fr': '↩️ Retours et annulations'},
 '💸 المصاريف والفواتير': {'en': '💸 Expenses & Invoices', 'fr': '💸 Dépenses et factures'},
 '📊 الأرباح التفصيلية': {'en': '📊 Detailed Profits', 'fr': '📊 Bénéfices détaillés'},
 'منتج محذوف': {'en': 'Deleted product', 'fr': 'Produit supprimé'},
 '(منتج محذوف)': {'en': '(Deleted product)', 'fr': '(Produit supprimé)'},
 'مخصص': {'en': 'Custom', 'fr': 'Personnalisée'},
 '✓ البرنامج مفعل — ': {'en': '✓ License active — ', 'fr': '✓ Licence active — '},
 'تم إنشاء النسخة الاحتياطية بنجاح': {'en': 'Backup created successfully', 'fr': 'Sauvegarde créée avec succès'},
 'فشل إنشاء النسخة الاحتياطية:': {'en': 'Failed to create backup:', 'fr': 'Échec de la création de la sauvegarde :'},
 'حد المخزون يجب أن يكون رقماً صحيحاً موجباً أو صفراً.': {'en': 'Low stock limit must be a non-negative integer.', 'fr': 'Le seuil de stock bas doit être un entier positif ou nul.'},
 'حد الخصم الذي يتطلب PIN يجب أن يكون رقماً صحيحاً موجباً أو صفراً.': {'en': 'The PIN discount limit must be a non-negative integer.', 'fr': 'La limite de remise PIN doit être un entier positif ou nul.'},
 'تم حفظ الإعدادات بنجاح.': {'en': 'Settings saved successfully.', 'fr': 'Paramètres enregistrés avec succès.'},
 'أدخل رقم الفاتورة أولاً': {'en': 'Enter the invoice number first', 'fr': "Saisissez d'abord le numéro de facture"},
 'تعطيل': {'en': 'Disable', 'fr': 'Désactiver'},
 'تفعيل': {'en': 'Enable', 'fr': 'Activer'},
 'سعر المنتج': {'en': 'Product price', 'fr': 'Prix du produit'},
 'متغيرات المنتج (المقاس / اللون)': {'en': 'Product variants (size / color)', 'fr': 'Variantes du produit (taille / couleur)'},
 'مثال: 0.075': {'en': 'Example: 0.075', 'fr': 'Exemple : 0,075'},
 '75 غرام إذا كانت الوحدة كغ': {'en': '75 grams if the unit is kg', 'fr': "75 grammes si l'unité est le kg"},
 'أدخل الكمية المطلوبة بوحدة': {'en': 'Enter the required quantity in', 'fr': 'Saisissez la quantité requise en'},
 'طباعة الفاتورة': {'en': 'Print invoice', 'fr': 'Imprimer la facture'},
 'تمت عملية البيع بنجاح.': {'en': 'The sale completed successfully.', 'fr': "La vente a été effectuée avec succès."},
 'هل تريد طباعة الفاتورة الآن؟': {'en': 'Do you want to print the invoice now?', 'fr': 'Voulez-vous imprimer la facture maintenant ?'},
 'رقم الفاتورة:': {'en': 'Invoice number:', 'fr': 'Numéro de facture :'},
 'يمكن تسجيل دفعة مباشرة من هنا.': {'en': 'A payment can be recorded directly from here.', 'fr': "Un paiement peut être enregistré directement d'ici."},
 'لا يوجد دين حالي على هذا العميل.': {'en': 'This customer currently has no debt.', 'fr': "Ce client n'a actuellement aucune dette."},
 'لإنشاء PDF عربي صحيح ثبّت: python -m pip install reportlab arabic-reshaper python-bidi': {'en': 'For correct Arabic PDFs install: python -m pip install reportlab arabic-reshaper python-bidi', 'fr': 'Pour un PDF arabe correct installez : python -m pip install reportlab arabic-reshaper python-bidi'},
 'تأكيد إلغاء الوصل': {'en': 'Confirm invoice void', 'fr': "Confirmer l'annulation de la facture"},
 'هل تريد إلغاء الوصل': {'en': 'Do you want to void invoice', 'fr': "Voulez-vous annuler la facture"},
 ' نهائيًا؟': {'en': ' permanently?', 'fr': ' définitivement ?'},
 'سيتم استرجاع المنتجات إلى المخزون ولا يمكن التراجع عن هذه العملية.': {'en': 'Products will be returned to stock and this action cannot be undone.', 'fr': 'Les produits seront remis en stock et cette action est irréversible.'},
 'المتبقي بعد التسديد:': {'en': 'Remaining after payment:', 'fr': 'Reste après paiement :'},

 'للوزن: اختر كغ أو غرام. مثال: 0.075 كغ = 75 غرام. السعر يكون حسب الوحدة المختارة.': {'en': 'For weight: choose kg or grams. Example: 0.075 kg = 75 grams. Price depends on the selected unit.', 'fr': "Pour le poids : choisissez kg ou grammes. Exemple : 0,075 kg = 75 grammes. Le prix dépend de l'unité choisie."},
 'الرصيد الحالي محفوظ في حساب العميل. العمليات الجديدة ستظهر هنا تلقائيًا.': {'en': 'The current balance is saved in the customer account. New operations will appear here automatically.', 'fr': 'Le solde actuel est enregistré sur le compte client. Les nouvelles opérations apparaîtront ici automatiquement.'},
 'لتفعيل طباعة الفواتير ثبّت ReportLab: python -m pip install reportlab': {'en': 'To enable invoice printing install ReportLab: python -m pip install reportlab', 'fr': "Pour activer l'impression des factures installez ReportLab : python -m pip install reportlab"},
 'بانتظار موافقة الجهاز الرئيسي (PC1) على اتصال هذا الجهاز...': {'en': 'Waiting for the main device (PC1) to approve this device connection...', 'fr': "En attente de l'approbation du périphérique principal (PC1) pour cette connexion..."},
 'مثال: أدخل 100 دج ليحسب البرنامج الكمية المقابلة تلقائيًا': {'en': 'Example: enter 100 DZD and the program will calculate the corresponding quantity automatically', 'fr': 'Exemple : saisissez 100 DA et le programme calculera automatiquement la quantité correspondante'},
 'يرجى التأكد من تشغيل الجهاز الرئيسي واتصاله بنفس الشبكة.': {'en': 'Make sure the main device is on and connected to the same network.', 'fr': 'Assurez-vous que le périphérique principal est allumé et connecté au même réseau.'},
 'أدخل قيمة الخصم بالدينار أو نسبة مئوية (0 لإلغاء الخصم).': {'en': 'Enter the discount amount in Dinar or a percentage (0 to cancel the discount).', 'fr': 'Saisissez le montant de la remise en dinars ou un pourcentage (0 pour annuler la remise).'},
 'يرجى تحديد كمية المنتج الكلية أولاً قبل إضافة المتغيرات': {'en': 'Please set the total product quantity first before adding variants', 'fr': "Veuillez d'abord définir la quantité totale du produit avant d'ajouter des variantes"},
 'تأكيد واستلام المبلغ وإنهاء عملية البيع وطباعة الفاتورة': {'en': 'Confirm and receive the amount, finalize the sale and print the invoice', 'fr': 'Confirmer et encaisser le montant, finaliser la vente et imprimer la facture'},
 'نقل المؤشر مباشرة لخانة البحث لمسح الباركود في أي شاشة': {'en': 'Move the cursor to the search box to scan a barcode on any screen', 'fr': "Placer le curseur dans la zone de recherche pour scanner un code-barres sur n'importe quel écran"},
 'لا توجد باقات بعد. اضغط «+ باقة جديدة» لإنشاء الأولى': {'en': 'No packs yet. Click «+ New Pack» to create the first one', 'fr': 'Aucun pack pour le moment. Cliquez sur «+ Nouveau pack» pour créer le premier'},
 'أدخل الكمية الفعلية وسيحسب البرنامج الفرق تلقائيًا.': {'en': 'Enter the actual quantity and the program will calculate the difference automatically.', 'fr': 'Saisissez la quantité réelle, le programme calculera la différence automatiquement.'},
 'فتح قائمة المنتجات لتعديل الأسعار أو مراجعة المخزون': {'en': 'Open the product list to edit prices or review stock', 'fr': 'Ouvrir la liste des produits pour modifier les prix ou vérifier le stock'},
 'استخدم دفعًا جزئيًا إذا كان المبلغ أقل من الإجمالي': {'en': 'Use partial payment if the amount is less than the total', 'fr': 'Utilisez le paiement partiel si le montant est inférieur au total'},
 'تحديد زبون نقدي أو اختيار عميل لتسجيل البيع بالدين': {'en': 'Set as cash customer or choose a customer to record a credit sale', 'fr': 'Choisir un client au comptant ou sélectionner un client pour une vente à crédit'},
 'أدخل رقم الفاتورة واختر المنتج والكمية المرتجعة.': {'en': 'Enter the invoice number and choose the product and returned quantity.', 'fr': 'Saisissez le numéro de facture et choisissez le produit et la quantité retournée.'},
 'المنتجات التي بيعت 2 قطعة أو أقل خلال 30 يومًا (': {'en': 'Products sold 2 pcs or fewer in the last 30 days (', 'fr': 'Produits vendus à 2 pièces ou moins sur 30 jours ('},
 'الانتقال الفوري إلى شاشة البيع والكاشير الرئيسية': {'en': 'Jump straight to the POS and main cashier screen', 'fr': "Aller directement à l'écran de vente et de caisse"},
 'استعراض قائمة السلات المؤجلة لاسترجاعها أو حذفها': {'en': 'Browse the held carts list to restore or delete them', 'fr': 'Parcourir la liste des paniers suspendus pour les restaurer ou les supprimer'},
 'جاري البحث عن الجهاز الرئيسي وإعادة الاتصال...': {'en': 'Searching for the main device and reconnecting...', 'fr': 'Recherche du périphérique principal et reconnexion...'},
 'إغلاق أي نافذة منبثقة مفتوحة أو مسح خانة البحث': {'en': 'Close any open popup window or clear the search box', 'fr': 'Fermer toute fenêtre contextuelle ouverte ou vider la zone de recherche'},
 'تطبيق تخفيض بمبلغ ثابت (دج) أو نسبة مئوية (%)': {'en': 'Apply a fixed amount (DZD) or percentage (%) discount', 'fr': "Appliquer une remise d'un montant fixe (DA) ou d'un pourcentage (%)"},
 'يرجى الانتظار أو التحقق من الاتصال بالخادم.': {'en': 'Please wait or check the server connection.', 'fr': 'Veuillez patienter ou vérifier la connexion au serveur.'},
 'وصلت للكمية القصوى المتوفرة من هذا المقاس (': {'en': 'Reached the maximum available quantity for this size (', 'fr': 'Quantité maximale disponible atteinte pour cette taille ('},
 'إعادة تحميل وتحديث الصفحة والبيانات الحالية': {'en': 'Reload and refresh the current page and data', 'fr': 'Recharger et actualiser la page et les données actuelles'},
 'حفظ سلة الزبون مؤقتاً لخدمة زبون آخر سريعاً': {'en': "Temporarily save the customer's cart to serve another customer quickly", 'fr': 'Enregistrer temporairement le panier du client pour servir rapidement un autre client'},
 'إلغاء وإفراغ جميع محتويات السلة بعد التأكيد': {'en': 'Cancel and empty all cart contents after confirmation', 'fr': 'Annuler et vider tout le contenu du panier après confirmation'},
 'منتج القطعة يجب أن تكون كميته عددًا صحيحًا': {'en': 'Per-piece product quantity must be a whole number', 'fr': "La quantité d'un produit à l'unité doit être un nombre entier"},
 'تأكد من إدخال الأرقام بشكل صحيح، مثل 0.075': {'en': 'Make sure numbers are entered correctly, e.g. 0.075', 'fr': 'Assurez-vous de saisir correctement les nombres, ex. 0,075'},
 'ابدأ بمسح Barcode أو اختر منتجاً من الشبكة': {'en': 'Start by scanning a barcode or choose a product from the grid', 'fr': 'Commencez par scanner un code-barres ou choisissez un produit dans la grille'},
 'نقل المؤشر إلى خانة البحث في الصفحة النشطة': {'en': 'Move the cursor to the search box on the active page', 'fr': 'Placer le curseur dans la zone de recherche de la page active'},
 'يريد جهاز جديد الاتصال بالخادم الرئيسي:\n': {'en': 'A new device wants to connect to the main server:\n', 'fr': 'Un nouveau périphérique souhaite se connecter au serveur principal :\n'},
 'أدخل كمية إيجابية لمتغير واحد على الأقل.': {'en': 'Enter a positive quantity for at least one variant.', 'fr': 'Saisissez une quantité positive pour au moins une variante.'},
 'الكمية المطلوبة أكبر من المخزون المتاح (': {'en': 'Required quantity exceeds available stock (', 'fr': 'La quantité demandée dépasse le stock disponible ('},
 'الكمية الإجمالية في السلة تتجاوز المخزون': {'en': 'Total cart quantity exceeds stock', 'fr': 'La quantité totale du panier dépasse le stock'},
 'تم فتح الفاتورة. اختر طباعة من عارض PDF.': {'en': 'Invoice opened. Choose print from the PDF viewer.', 'fr': "Facture ouverte. Choisissez l'impression depuis la visionneuse PDF."},
 'لا توجد بيانات كافية لتحديد ساعات الذروة': {'en': 'Not enough data to determine peak hours', 'fr': 'Données insuffisantes pour déterminer les heures de pointe'},
 'سيعاد الاتصال تلقائيًا عند توفر الخادم.': {'en': 'Connection will restore automatically when the server is available.', 'fr': 'La connexion sera rétablie automatiquement dès que le serveur sera disponible.'},
 'المنتج يباع بالقطعة، أدخل عددًا صحيحًا.': {'en': 'This product is sold per piece, enter a whole number.', 'fr': "Ce produit se vend à l'unité, saisissez un nombre entier."},
 ' فاتورة   •   صافي المبيعات بعد الخصم: ': {'en': ' invoices   •   Net sales after discount: ', 'fr': ' factures   •   Ventes nettes après remise : '},
 'اختياري — يُترك فارغًا للتوليد التلقائي': {'en': 'Optional — leave empty for auto-generation', 'fr': 'Facultatif — laisser vide pour génération automatique'},
 'السعر يجب أن يكون رقمًا أو يُترك فارغًا': {'en': 'Price must be a number or left empty', 'fr': 'Le prix doit être un nombre ou rester vide'},
 '✓ تمت إضافة المتغير (سيُحفظ مع المنتج)': {'en': '✓ Variant added (will be saved with the product)', 'fr': '✓ Variante ajoutée (sera enregistrée avec le produit)'},
 'تحليل شامل للمبيعات والأرباح والمصاريف': {'en': 'Comprehensive analysis of sales, profits and expenses', 'fr': 'Analyse complète des ventes, profits et dépenses'},
 '🔥 أكثر الساعات ازدحاماً في هذا اليوم: ': {'en': '🔥 Busiest hours of this day: ', 'fr': '🔥 Heures les plus chargées de cette journée : '},
 'تم العثور على الخادم الرئيسي للمتجر: ': {'en': 'Main store server found: ', 'fr': 'Serveur principal du magasin trouvé : '},
 'تم إدخال المخزون وتسجيل الحركة بنجاح.': {'en': 'Stock added and movement recorded successfully.', 'fr': 'Stock ajouté et mouvement enregistré avec succès.'},
 'أدخل معلومات المورد في الحقول التالية': {'en': 'Enter the supplier information in the following fields', 'fr': 'Saisissez les informations du fournisseur dans les champs suivants'},
 'كمية المتغير يجب أن تكون أكبر من صفر': {'en': 'Variant quantity must be greater than zero', 'fr': 'La quantité de la variante doit être supérieure à zéro'},
 'إدارة كمية المنتجات وتنبيهات النفاد': {'en': 'Manage product quantities and stock-out alerts', 'fr': 'Gérer les quantités de produits et les alertes de rupture'},
 'تم حفظ الجرد وتسجيل الفروقات بنجاح.': {'en': 'Stocktake saved and differences recorded successfully.', 'fr': 'Inventaire enregistré et différences notées avec succès.'},
 'أدخل رقمًا صحيحًا، مثل 0.075 أو 100': {'en': 'Enter a whole number, e.g. 0.075 or 100', 'fr': 'Saisissez un nombre entier, ex. 0,075 ou 100'},
 'هل تريد مسح جميع المنتجات من السلة؟': {'en': 'Do you want to clear all products from the cart?', 'fr': 'Voulez-vous vider tous les produits du panier ?'},
 'لا توجد حركة زبائن مسجلة لهذا اليوم': {'en': 'No customer traffic recorded for this day', 'fr': 'Aucun flux client enregistré pour cette journée'},
 'تم استعادة الاتصال بالجهاز الرئيسي': {'en': 'Reconnected to the main device', 'fr': 'Reconnexion au périphérique principal rétablie'},
 'لا يمكن إدخال كمية سالبة للمتغير: ': {'en': 'Cannot enter a negative quantity for the variant: ', 'fr': 'Quantité négative interdite pour la variante : '},
 'أضف منتجًا واحدًا على الأقل للباقة': {'en': 'Add at least one product to the pack', 'fr': 'Ajoutez au moins un produit au pack'},
 'بيع سريع • مخزون مباشر • سلة واحدة': {'en': 'Fast POS • live stock • single cart', 'fr': 'Vente rapide • stock direct • panier unique'},
 'الخصم لا يمكن أن يتجاوز قيمة السلة': {'en': 'Discount cannot exceed the cart value', 'fr': 'La remise ne peut pas dépasser la valeur du panier'},
 'سعر المنتج يجب أن يكون أكبر من صفر': {'en': 'Product price must be greater than zero', 'fr': 'Le prix du produit doit être supérieur à zéro'},
 'تم البيع، لكن تعذر حفظ سجل الدين: ': {'en': 'Sale completed, but the credit record could not be saved: ', 'fr': "Vente effectuée, mais l'historique du crédit n'a pas pu être enregistré : "},
 'فتح نافذة تسجيل صنف جديد في المتجر': {'en': 'Open the window to register a new item in the store', 'fr': "Ouvrir la fenêtre d'enregistrement d'un nouvel article"},
 'تمت الموافقة على اتصال هذا الجهاز': {'en': 'This device connection was approved', 'fr': 'La connexion de ce périphérique a été approuvée'},
 'نظرة سريعة وواضحة على أداء المتجر': {'en': 'Quick, clear store performance overview', 'fr': 'Aperçu rapide et clair des performances du magasin'},
 'المقاس/اللون غير متوفر في المخزون': {'en': 'Size/color not available in stock', 'fr': 'Taille/couleur indisponible en stock'},
 'لا توجد بيانات مبيعات لهذه الفترة': {'en': 'No sales data for this period', 'fr': 'Aucune donnée de vente pour cette période'},
 'تم السماح للجهاز الجديد بالاتصال': {'en': 'New device connection allowed', 'fr': 'Connexion du nouveau périphérique autorisée'},
 'لا توجد منتجات لإدخال مخزون لها.': {'en': 'No products to add stock to.', 'fr': 'Aucun produit pour ajouter du stock.'},
 'اختر منتجًا من الاقتراحات أولًا.': {'en': 'Choose a product from the suggestions first.', 'fr': "Choisissez d'abord un produit dans les suggestions."},
 'الكمية المطلوبة أكبر من المتاح (': {'en': 'Required quantity exceeds available (', 'fr': 'La quantité demandée dépasse le disponible ('},
 'تم حفظ الفاتورة لكن تعذر فتحها: ': {'en': 'Invoice saved but could not be opened: ', 'fr': "Facture enregistrée mais impossible de l'ouvrir : "},
 "استخدم زر '⟳ تحديث' داخل النافذة": {'en': "Use the '⟳ Refresh' button inside the window", 'fr': 'Utilisez le bouton « ⟳ Actualiser » dans la fenêtre'},
 'هذا العميل لا يملك دينًا مستحقًا': {'en': 'This customer has no outstanding debt', 'fr': "Ce client n'a aucune dette impayée"},
 'تم التسديد، لكن تعذر حفظ السجل: ': {'en': 'Payment recorded, but the log could not be saved: ', 'fr': "Règlement enregistré, mais l'historique n'a pas pu être enregistré : "},
 'تم تصدير التقرير الاحترافي إلى:\n': {'en': 'Professional report exported to:\n', 'fr': 'Rapport professionnel exporté vers :\n'},
 'تسجيل ومتابعة المصاريف التشغيلية': {'en': 'Record and track operating expenses', 'fr': "Enregistrer et suivre les dépenses d'exploitation"},
 'لا توجد بيانات أجهزة لهذه الفترة': {'en': 'No device data for this period', 'fr': 'Aucune donnée de périphérique pour cette période'},
 'لا توجد مصاريف مسجلة لهذه الفترة': {'en': 'No expenses recorded for this period', 'fr': 'Aucune dépense enregistrée pour cette période'},
 'تحليل الربح الحقيقي من المبيعات': {'en': 'Real profit analysis from sales', 'fr': 'Analyse du profit réel des ventes'},
 'وصلت للكمية المتوفرة في المخزون': {'en': 'Reached the available stock quantity', 'fr': 'Quantité disponible en stock atteinte'},
 'اختر طريقة الدفع ثم أكد العملية': {'en': 'Choose a payment method then confirm', 'fr': 'Choisissez un mode de paiement puis confirmez'},
 'للدفع الكامل اختر نقدي أو بطاقة': {'en': 'For full payment choose cash or card', 'fr': 'Pour un paiement complet, choisissez espèces ou carte'},
 'الكمية يجب أن تكون أكبر من صفر': {'en': 'Quantity must be greater than zero', 'fr': 'La quantité doit être supérieure à zéro'},
 'هل تريد حذف هذه السلة المعلقة؟': {'en': 'Do you want to delete this held cart?', 'fr': 'Voulez-vous supprimer ce panier suspendu ?'},
 'لا توجد كمية إضافية في المخزون': {'en': 'No additional quantity in stock', 'fr': 'Aucune quantité supplémentaire en stock'},
 'اكتب اسم العميل أو رقم الهاتف:': {'en': 'Enter the customer name or phone number:', 'fr': 'Saisissez le nom du client ou son numéro de téléphone :'},
 'الدين الكامل يتطلب اختيار عميل': {'en': 'Full credit requires selecting a customer', 'fr': 'Le crédit total nécessite de sélectionner un client'},
 'المنتج موجود بالفعل في الباقة': {'en': 'Product already exists in the pack', 'fr': 'Le produit existe déjà dans le pack'},
 'مثال: مقاس 42 أسود / Taille L': {'en': 'Example: size 42 black / Taille L', 'fr': 'Exemple : taille 42 noir / Taille L'},
 'المبلغ لا يمكن أن يكون سالبًا': {'en': 'Amount cannot be negative', 'fr': 'Le montant ne peut pas être négatif'},
 'تسجيل الدين معطل من الإعدادات': {'en': 'Recording credit is disabled in settings', 'fr': "L'enregistrement du crédit est désactivé dans les paramètres"},
 'ابحث باسم العميل أو الهاتف...': {'en': 'Search by customer name or phone...', 'fr': 'Rechercher par nom de client ou téléphone...'},
 'تم إرسال الفاتورة إلى الطابعة': {'en': 'Invoice sent to the printer', 'fr': "Facture envoyée à l'imprimante"},
 'تسجيل وعرض المصاريف التشغيلية': {'en': 'Record and view operating expenses', 'fr': "Enregistrer et consulter les dépenses d'exploitation"},
 'لا توجد منتجات بطيئة الحركة 🎉': {'en': 'No slow-moving products 🎉', 'fr': 'Aucun produit à rotation lente 🎉'},
 'لا توجد منتجات لإجراء الجرد.': {'en': 'No products for stocktaking.', 'fr': "Aucun produit pour l'inventaire."},
 'لا توجد فروقات ليتم تسجيلها.': {'en': 'No differences to record.', 'fr': 'Aucune différence à enregistrer.'},
 'أدخل كمية صحيحة أكبر من صفر.': {'en': 'Enter a valid quantity greater than zero.', 'fr': 'Saisissez une quantité valide supérieure à zéro.'},
 'السعر لا يمكن أن يكون سالبًا': {'en': 'Price cannot be negative', 'fr': 'Le prix ne peut pas être négatif'},
 'اختر سلة لاسترجاعها أو حذفها': {'en': 'Choose a cart to restore or delete', 'fr': 'Choisissez un panier à restaurer ou à supprimer'},
 'يجب اختيار عميل لتسجيل الدين': {'en': 'A customer must be selected to record credit', 'fr': 'Un client doit être sélectionné pour enregistrer le crédit'},
 'تم إنشاء تقرير PDF احترافي:\n': {'en': 'Professional PDF report created:\n', 'fr': 'Rapport PDF professionnel créé :\n'},
 'تعذر تحديث قائمة المنتجات: ': {'en': 'Failed to refresh product list: ', 'fr': "Échec de l'actualisation de la liste des produits : "},
 'اختر المقاس / اللون المناسب': {'en': 'Choose the appropriate size / color', 'fr': 'Choisissez la taille / la couleur appropriée'},
 'المنتج غير متوفر في المخزون': {'en': 'Product not available in stock', 'fr': 'Produit indisponible en stock'},
 ' د.ج  •  العملاء المدينون: ': {'en': ' DZD  •  Debtor customers: ', 'fr': ' DA  •  Clients débiteurs : '},
 'أدخل تاريخ البداية والنهاية': {'en': 'Enter the start and end dates', 'fr': 'Saisissez les dates de début et de fin'},
 'اختصار بديل لإضافة صنف جديد': {'en': 'Alternative shortcut to add a new item', 'fr': 'Raccourci alternatif pour ajouter un nouvel article'},
 'مثال: مؤسسة التوزيع الحديثة': {'en': 'Example: Modern Distribution Co.', 'fr': 'Exemple : Société moderne de distribution'},
 '✓ نعم، الاتصال بهذا المتجر': {'en': '✓ Yes, connect to this store', 'fr': '✓ Oui, se connecter à ce magasin'},
 'نظرة سريعة على أداء المتجر': {'en': 'Quick store performance overview', 'fr': 'Aperçu rapide des performances du magasin'},
 'أضف منتجات إلى السلة أولاً': {'en': 'Add products to the cart first', 'fr': "Ajoutez d'abord des produits au panier"},
 'تعذر قراءة بيانات العميل: ': {'en': 'Failed to read customer data: ', 'fr': 'Échec de la lecture des données du client : '},
 'أدخل مبلغ صحيح أكبر من صفر': {'en': 'Enter a valid amount greater than zero', 'fr': 'Saisissez un montant valide supérieur à zéro'},
 ' تسوية. هل تريد المتابعة؟': {'en': ' adjustment(s). Do you want to continue?', 'fr': ' ajustement(s). Voulez-vous continuer ?'},
 'تعذر تطبيق بعض التسويات:\n': {'en': 'Some adjustments could not be applied:\n', 'fr': "Certains ajustements n'ont pas pu être appliqués :\n"},
 'أدخل كمية صحيحة للمتغير: ': {'en': 'Enter a valid quantity for the variant: ', 'fr': 'Saisissez une quantité valide pour la variante : '},
 'غير متصل بقاعدة البيانات': {'en': 'Disconnected from database', 'fr': 'Déconnecté de la base de données'},
 'تعذر تحميل سجل المخزون:\n': {'en': 'Failed to load stock log:\n', 'fr': "Échec du chargement de l'historique du stock :\n"},
 'حذف هذا المتغير نهائيًا؟': {'en': 'Delete this variant permanently?', 'fr': 'Supprimer définitivement cette variante ?'},
 'إجمالي الديون المستحقة: ': {'en': 'Total outstanding debt: ', 'fr': 'Dette totale impayée : '},
 'تعذر طباعة فاتورة 80mm: ': {'en': 'Failed to print 80mm invoice: ', 'fr': "Échec de l'impression de la facture 80 mm : "},
 '🧾 سجل الفواتير والوصولات': {'en': '🧾 Invoices & receipts log', 'fr': '🧾 Journal des factures et reçus'},
 'يُدفع من الصندوق (نقدًا)': {'en': 'Paid from the drawer (cash)', 'fr': 'Payé depuis le tiroir-caisse (espèces)'},
 'هل تريد حذف المصروف رقم ': {'en': 'Do you want to delete expense number ', 'fr': 'Voulez-vous supprimer la dépense numéro '},
 'إحصائيات المبيعات والربح': {'en': 'Sales and profit statistics', 'fr': 'Statistiques des ventes et des profits'},
 '   •   المتاح للإرجاع: ': {'en': '   •   Available for return: ', 'fr': '   •   Disponible au retour : '},
 'خطأ في تحميل المنتجات: ': {'en': 'Error loading products: ', 'fr': 'Erreur lors du chargement des produits : '},
 'لا يمكن إدخال قيم سالبة': {'en': 'Negative values not allowed', 'fr': 'Valeurs négatives interdites'},
 'تعذر تحميل سجل الديون: ': {'en': 'Failed to load debt log: ', 'fr': "Échec du chargement de l'historique des dettes : "},
 'اختر وصلًا لعرض تفاصيله': {'en': 'Select a receipt to view its details', 'fr': 'Sélectionnez un reçu pour afficher ses détails'},
 'لا توجد بنود لهذا الوصل': {'en': 'No items for this receipt', 'fr': 'Aucune ligne pour ce reçu'},
 'أدخل مبلغًا أكبر من صفر': {'en': 'Enter an amount greater than zero', 'fr': 'Saisissez un montant supérieur à zéro'},
 'متوسط الفواتير لكل ساعة': {'en': 'Average invoices per hour', 'fr': 'Factures moyennes par heure'},
 'هل تريد حذف هذا المورد؟': {'en': 'Do you want to delete this supplier?', 'fr': 'Voulez-vous supprimer ce fournisseur ?'},
 'الكمية يجب ألا تتجاوز ': {'en': 'Quantity must not exceed ', 'fr': 'La quantité ne doit pas dépasser '},
 'بحث بالاسم أو الباركود': {'en': 'Search by name or barcode', 'fr': 'Rechercher par nom ou code-barres'},
 'بيع سريع • مخزون مباشر': {'en': 'Fast POS • live stock', 'fr': 'Vente rapide • stock direct'},
 'أدخل رقمًا أكبر من صفر': {'en': 'Enter a number greater than zero', 'fr': 'Saisissez un nombre supérieur à zéro'},
 'تعذر طباعة فاتورة A4: ': {'en': 'Failed to print A4 invoice: ', 'fr': "Échec de l'impression de la facture A4 : "},
 'سجل الفواتير والوصولات': {'en': 'Invoices & receipts log', 'fr': 'Journal des factures et reçus'},
 'مكتبة Excel غير موجودة': {'en': 'Excel library not found', 'fr': 'Bibliothèque Excel introuvable'},
 'تعذر إنشاء ملف Excel:\n': {'en': 'Failed to create Excel file:\n', 'fr': 'Échec de la création du fichier Excel :\n'},
 'تم تسجيل المصروف بنجاح': {'en': 'Expense recorded successfully', 'fr': 'Dépense enregistrée avec succès'},
 'خطأ في تحميل التقرير: ': {'en': 'Error loading report: ', 'fr': 'Erreur lors du chargement du rapport : '},
 'لا توجد فواتير ملغاة 🎉': {'en': 'No voided invoices 🎉', 'fr': 'Aucune facture annulée 🎉'},
 'إعادة الاتصال بالخادم': {'en': 'Reconnect to server', 'fr': 'Reconnexion au serveur'},
 'تأكيد الاتصال بالمتجر': {'en': 'Confirm store connection', 'fr': 'Confirmer la connexion au magasin'},
 'بانتظار موافقة المدير': {'en': 'Waiting for admin approval', 'fr': "En attente de l'approbation de l'administrateur"},
 'قيمة المرتجع: 0.00 دج': {'en': 'Return value: 0.00 DZD', 'fr': 'Valeur du retour : 0,00 DA'},
 '   •   قيمة المرتجع: ': {'en': '   •   Return value: ', 'fr': '   •   Valeur du retour : '},
 'تعذر تحميل المنتجات:\n': {'en': 'Failed to load products:\n', 'fr': 'Échec du chargement des produits :\n'},
 'سعر المجموع: 0.00 د.ج': {'en': 'Total price: 0.00 DZD', 'fr': 'Prix total : 0,00 DA'},
 'تم تحديث خصم الفاتورة': {'en': 'Invoice discount updated', 'fr': 'Remise de facture mise à jour'},
 'تعذر تحميل المنتجات: ': {'en': 'Failed to load products: ', 'fr': 'Échec du chargement des produits : '},
 'تعذر تحديث المفضّلة: ': {'en': 'Failed to update favorites: ', 'fr': 'Échec de la mise à jour des favoris : '},
 'تمت عملية البيع بنجاح': {'en': 'Sale completed successfully', 'fr': 'Vente effectuée avec succès'},
 'إدارة العملاء والديون': {'en': 'Manage customers and debts', 'fr': 'Gérer les clients et les dettes'},
 'تعذر تحميل الفاتورة: ': {'en': 'Failed to load invoice: ', 'fr': 'Échec du chargement de la facture : '},
 'لا توجد فواتير مطابقة': {'en': 'No matching invoices', 'fr': 'Aucune facture correspondante'},
 'إلغاء / إغلاق النوافذ': {'en': 'Cancel / close windows', 'fr': 'Annuler / fermer les fenêtres'},
 'إدارة بيانات الموردين': {'en': 'Manage supplier data', 'fr': 'Gérer les données des fournisseurs'},
 'طلب اقتران جهاز جديد': {'en': 'New device pairing request', 'fr': "Demande de jumelage d'un nouveau périphérique"},
 'إدارة باقات المنتجات': {'en': 'Manage product packs', 'fr': 'Gérer les packs de produits'},
 'تم تحديث حالة الباقة': {'en': 'Pack status updated', 'fr': 'Statut du pack mis à jour'},
 'هل تريد حذف الباقة «': {'en': 'Do you want to delete the pack «', 'fr': 'Voulez-vous supprimer le pack «'},
 'لا توجد متغيرات بعد.': {'en': 'No variants yet.', 'fr': 'Aucune variante pour le moment.'},
 'لا توجد مبيعات معلقة': {'en': 'No held sales', 'fr': 'Aucune vente suspendue'},
 'تم حذف السلة المعلقة': {'en': 'Held cart deleted', 'fr': 'Panier suspendu supprimé'},
 'فشل إنشاء الفاتورة: ': {'en': 'Failed to create invoice: ', 'fr': 'Échec de la création de la facture : '},
 'اختيار في نقطة البيع': {'en': 'Select at the POS', 'fr': 'Sélectionner au point de vente'},
 'تعذر تحميل العملاء: ': {'en': 'Failed to load customers: ', 'fr': 'Échec du chargement des clients : '},
 'المبلغ أكبر من الدين': {'en': 'Amount exceeds debt', 'fr': 'Montant supérieur à la dette'},
 'مكتبة PDF غير موجودة': {'en': 'PDF library not found', 'fr': 'Bibliothèque PDF introuvable'},
 'لا توجد مصاريف مسجلة': {'en': 'No expenses recorded', 'fr': 'Aucune dépense enregistrée'},
 'التقارير والإحصائيات': {'en': 'Reports & statistics', 'fr': 'Rapports et statistiques'},
 'تعذر حفظ الإعدادات: ': {'en': 'Failed to save settings: ', 'fr': "Échec de l'enregistrement des paramètres : "},
 'فشل تسجيل المرتجع: ': {'en': 'Failed to record return: ', 'fr': "Échec de l'enregistrement du retour : "},
 'سعر الباقة غير صحيح': {'en': 'Pack price is invalid', 'fr': 'Le prix du pack est invalide'},
 'فشل إضافة المتغير: ': {'en': 'Failed to add variant: ', 'fr': "Échec de l'ajout de la variante : "},
 '✓ تمت إضافة المتغير': {'en': '✓ Variant added', 'fr': '✓ Variante ajoutée'},
 'اختر المقاس / اللون': {'en': 'Choose size / color', 'fr': 'Choisir la taille / la couleur'},
 'فشل تسجيل التسديد: ': {'en': 'Failed to record payment: ', 'fr': "Échec de l'enregistrement du règlement : "},
 'تكلفة السلع المباعة': {'en': 'Cost of goods sold', 'fr': 'Coût des marchandises vendues'},
 'تعليق السلة الحالية': {'en': 'Hold the current cart', 'fr': 'Suspendre le panier actuel'},
 'جاري إعادة الاتصال': {'en': 'Reconnecting', 'fr': 'Reconnexion...'},
 'اختر المنتج أولاً.': {'en': 'Select the product first.', 'fr': "Sélectionnez d'abord le produit."},
 'تم المرتجع وإضافة ': {'en': 'Return recorded and added ', 'fr': 'Retour enregistré et ajouté de '},
 'إضافة منتج للباقة:': {'en': 'Add product to pack:', 'fr': 'Ajouter un produit au pack :'},
 'اختيار صورة المنتج': {'en': 'Choose product image', 'fr': "Choisir l'image du produit"},
 'تحديد كمية المتغير': {'en': 'Set variant quantity', 'fr': 'Définir la quantité de la variante'},
 'أدخل مبلغًا صحيحًا': {'en': 'Enter a valid amount', 'fr': 'Saisissez un montant valide'},
 'فشلت عملية البيع: ': {'en': 'Sale failed: ', 'fr': 'Échec de la vente : '},
 'ابحث برقم الوصل...': {'en': 'Search by receipt number...', 'fr': 'Rechercher par numéro de reçu...'},
 ' واسترجاع المنتجات': {'en': ' and products returned to stock', 'fr': ' et produits retournés au stock'},
 'المصاريف والفواتير': {'en': 'Expenses & invoices', 'fr': 'Dépenses et factures'},
 '＋ تسجيل مصروف جديد': {'en': '＋ Register new expense', 'fr': '＋ Enregistrer une nouvelle dépense'},
 '💸 تسجيل مصروف جديد': {'en': '💸 Register new expense', 'fr': '💸 Enregistrer une nouvelle dépense'},
 'أدخل عنوان المصروف': {'en': 'Enter an expense title', 'fr': 'Saisissez un intitulé de dépense'},
 '🕒 التوقيت الحالي: ': {'en': '🕒 Current time: ', 'fr': '🕒 Heure actuelle : '},
 'يُنصح بكاشير إضافي': {'en': 'An extra cashier is recommended', 'fr': 'Un caissier supplémentaire est recommandé'},
 '   (متوسط إجمالي: ': {'en': '   (overall average: ', 'fr': '   (moyenne globale : '},
 'ضبط النظام والشبكة': {'en': 'System and network settings', 'fr': 'Paramètres système et réseau'},
 'الدفع وإتمام البيع': {'en': 'Payment and completing the sale', 'fr': 'Paiement et finalisation de la vente'},
 '✓ السماح بالاتصال': {'en': '✓ Allow connection', 'fr': '✓ Autoriser la connexion'},
 ' وإضافتها للمخزون': {'en': ' and added back to stock', 'fr': ' et ajoutée au stock'},
 '✓ تم تحديث الباقة': {'en': '✓ Pack updated', 'fr': '✓ Pack mis à jour'},
 '✓ تم إنشاء الباقة': {'en': '✓ Pack created', 'fr': '✓ Pack créé'},
 'اسم المتغير مطلوب': {'en': 'Variant name is required', 'fr': 'Le nom de la variante est requis'},
 'تم تعليق البيع • ': {'en': 'Sale held • ', 'fr': 'Vente suspendue • '},
 'المتغير غير موجود': {'en': 'Variant not found', 'fr': 'Variante introuvable'},
 'أدخل رقمًا صحيحًا': {'en': 'Enter a whole number', 'fr': 'Saisissez un nombre entier'},
 'تحديد كمية المنتج': {'en': 'Set product quantity', 'fr': 'Définir la quantité du produit'},
 'تعذر تحميل الباقة': {'en': 'Failed to load pack', 'fr': 'Échec du chargement du pack'},
 'تم حفظ الفاتورة:\n': {'en': 'Invoice saved:\n', 'fr': 'Facture enregistrée :\n'},
 'تقرير المبيعات - ': {'en': 'Sales report - ', 'fr': 'Rapport des ventes - '},
 ' دج • هامش الربح ': {'en': ' DZD • profit margin ', 'fr': ' DA • marge de profit '},
 '💰 الإيراد المتوقع': {'en': '💰 Expected revenue', 'fr': '💰 Revenu attendu'},
 'حفظ نسخة احتياطية': {'en': 'Save a backup', 'fr': 'Enregistrer une sauvegarde'},
 'التركيز على البحث': {'en': 'Focus on search', 'fr': 'Focus sur la recherche'},
 'اسم المورد مطلوب.': {'en': 'Supplier name is required.', 'fr': 'Le nom du fournisseur est requis.'},
 'تعذر حفظ المورد:\n': {'en': 'Failed to save supplier:\n', 'fr': "Échec de l'enregistrement du fournisseur :\n"},
 'بانتظار الموافقة': {'en': 'Waiting for approval', 'fr': "En attente d'approbation"},
 '؟\nقيمة المرتجع: ': {'en': '?\nReturn value: ', 'fr': ' ?\nValeur du retour : '},
 'تحقق من الكمية: ': {'en': 'Check the quantity: ', 'fr': 'Vérifiez la quantité : '},
 'سجل حركة المخزون': {'en': 'Stock movement log', 'fr': 'Historique des mouvements de stock'},
 'اسم الباقة مطلوب': {'en': 'Pack name is required', 'fr': 'Le nom du pack est requis'},
 '✓ تم حذف المتغير': {'en': '✓ Variant deleted', 'fr': '✓ Variante supprimée'},
 'اسم المنتج مطلوب': {'en': 'Product name is required', 'fr': 'Le nom du produit est requis'},
 'المنتج غير موجود': {'en': 'Product not found', 'fr': 'Produit introuvable'},
 'تم استرجاع السلة': {'en': 'Cart restored', 'fr': 'Panier restauré'},
 'العميل غير موجود': {'en': 'Customer not found', 'fr': 'Client introuvable'},
 'تعذر إنشاء CSV:\n': {'en': 'Failed to create CSV:\n', 'fr': 'Échec de la création du CSV :\n'},
 'تسجيل مصروف جديد': {'en': 'Register new expense', 'fr': 'Enregistrer une nouvelle dépense'},
 'تعذر حفظ المصروف': {'en': 'Failed to save expense', 'fr': "Échec de l'enregistrement de la dépense"},
 'مستوى الإشغال: —': {'en': 'Occupancy level: —', 'fr': "Niveau d'occupation : —"},
 '🔌 قاعدة البيانات': {'en': '🔌 Database', 'fr': '🔌 Base de données'},
 'تفريغ ومسح السلة': {'en': 'Empty and clear the cart', 'fr': 'Vider et effacer le panier'},
 'أدخل كمية صحيحة': {'en': 'Enter a valid quantity', 'fr': 'Saisissez une quantité valide'},
 'إجمالي المنتجات': {'en': 'Total products', 'fr': 'Total des produits'},
 'السعر (اختياري)': {'en': 'Price (optional)', 'fr': 'Prix (optionnel)'},
 'فشل حذف المتغير': {'en': 'Failed to delete variant', 'fr': 'Échec de la suppression de la variante'},
 '✓ تم حذف المنتج': {'en': '✓ Product deleted', 'fr': '✓ Produit supprimé'},
 'خصم فاتورة كبير': {'en': 'Large invoice discount', 'fr': 'Remise importante sur facture'},
 'إجمالي الفاتورة': {'en': 'Invoice total', 'fr': 'Total de la facture'},
 '🧾 إعادة الطباعة': {'en': '🧾 Reprint', 'fr': '🧾 Réimprimer'},
 'تم إلغاء الوصل ': {'en': 'Receipt voided ', 'fr': 'Reçu annulé '},
 'فشل إلغاء الوصل': {'en': 'Failed to void receipt', 'fr': "Échec de l'annulation du reçu"},
 'المبلغ غير صالح': {'en': 'Invalid amount', 'fr': 'Montant invalide'},
 'حفظ التقرير CSV': {'en': 'Save CSV report', 'fr': 'Enregistrer le rapport CSV'},
 'تقرير_المبيعات_': {'en': 'Sales_report_', 'fr': 'Rapport_ventes_'},
 '📊 ملخص المصاريف': {'en': '📊 Expense summary', 'fr': '📊 Résumé des dépenses'},
 'كاشير واحد كافي': {'en': 'One cashier is enough', 'fr': 'Un seul caissier suffit'},
 'كاشيران مطلوبان': {'en': 'Two cashiers needed', 'fr': 'Deux caissiers nécessaires'},
 'مستوى الإشغال: ': {'en': 'Occupancy level: ', 'fr': "Niveau d'occupation : "},
 'لا توجد مرتجعات': {'en': 'No returns', 'fr': 'Aucun retour'},
 'إضافة منتج جديد': {'en': 'Add new product', 'fr': 'Ajouter un nouveau produit'},
 'خطأ في الإرجاع': {'en': 'Return error', 'fr': 'Erreur de retour'},
 '» داخل الباقة:': {'en': '" in the pack:', 'fr': '» dans le pack :'},
 'إدارة المنتجات': {'en': 'Manage products', 'fr': 'Gérer les produits'},
 'صورة غير صالحة': {'en': 'Invalid image', 'fr': 'Image invalide'},
 '🧾 سجل الوصولات': {'en': '🧾 Receipts log', 'fr': '🧾 Journal des reçus'},
 'المجموع الفرعي': {'en': 'Subtotal', 'fr': 'Sous-total'},
 'خطأ في البحث: ': {'en': 'Search error: ', 'fr': 'Erreur de recherche : '},
 'شكرًا لزيارتكم': {'en': 'Thank you for visiting', 'fr': 'Merci de votre visite'},
 'تسديد دين عميل': {'en': 'Settle customer debt', 'fr': "Régler la dette d'un client"},
 'خطأ في التصدير': {'en': 'Export error', 'fr': "Erreur d'exportation"},
 'تم تصدير CSV:\n': {'en': 'CSV exported:\n', 'fr': 'CSV exporté :\n'},
 'تم الحذف بنجاح': {'en': 'Deleted successfully', 'fr': 'Supprimé avec succès'},
 'تحذيرات الهامش': {'en': 'Margin warnings', 'fr': 'Alertes de marge'},
 '🕒 الوقت الحالي': {'en': '🕒 Current time', 'fr': '🕒 Heure actuelle'},
 '📊 حركة الزبائن': {'en': '📊 Customer traffic', 'fr': '📊 Flux clients'},
 'تحديث البيانات': {'en': 'Refresh data', 'fr': 'Actualiser les données'},
 'منتج جديد سريع': {'en': 'Quick new product', 'fr': 'Nouveau produit rapide'},
 ' على العنوان ': {'en': ' at address ', 'fr': " à l'adresse "},
 'تأكيد الإرجاع': {'en': 'Confirm return', 'fr': 'Confirmer le retour'},
 'تأكيد المرتجع': {'en': 'Confirm return', 'fr': 'Confirmer le retour'},
 '+ إضافة متغير': {'en': '+ Add variant', 'fr': '+ Ajouter une variante'},
 'تفاصيل العميل': {'en': 'Customer details', 'fr': 'Détails du client'},
 '✕ إلغاء الوصل': {'en': '✕ Void receipt', 'fr': '✕ Annuler le reçu'},
 '💾 حفظ المصروف': {'en': '💾 Save expense', 'fr': '💾 Enregistrer la dépense'},
 'صافي المداخيل': {'en': 'Net income', 'fr': 'Revenu net'},
 'توقع الازدحام': {'en': 'Predict crowding', 'fr': "Prévoir l'affluence"},
 ' إلى المخزون': {'en': ' to stock', 'fr': ' au stock'},
 'هامش الربح: ': {'en': 'Profit margin: ', 'fr': 'Marge de profit : '},
 'عرض المزيد (': {'en': 'Show more (', 'fr': 'Voir plus ('},
 'إضافة مستخدم': {'en': 'Add user', 'fr': 'Ajouter un utilisateur'},
 'كمية الإدخال': {'en': 'Input quantity', 'fr': 'Quantité saisie'},
 'تعذر التحديث': {'en': 'Update failed', 'fr': 'Échec de la mise à jour'},
 'تعديل الباقة': {'en': 'Edit pack', 'fr': 'Modifier le pack'},
 'لا توجد صورة': {'en': 'No image', 'fr': 'Aucune image'},
 ' عملية معلقة': {'en': ' held sale(s)', 'fr': ' vente(s) en attente'},
 ' د.ج / بـاقة': {'en': ' DZD / pack', 'fr': ' DA / pack'},
 'تم مسح السلة': {'en': 'Cart cleared', 'fr': 'Panier vidé'},
 'حفظ الفاتورة': {'en': 'Save invoice', 'fr': 'Enregistrer la facture'},
 'ملخص التقرير': {'en': 'Report summary', 'fr': 'Résumé du rapport'},
 'اسم المورد *': {'en': 'Supplier name *', 'fr': 'Nom du fournisseur *'},
 '↩ مرتجع بيع': {'en': '↩ Sale return', 'fr': '↩ Retour de vente'},
 'اختر المنتج': {'en': 'Select product', 'fr': 'Sélectionner le produit'},
 'جرد المخزون': {'en': 'Stock inventory', 'fr': 'Inventaire du stock'},
 'تأكيد الجرد': {'en': 'Confirm stocktake', 'fr': "Confirmer l'inventaire"},
 'سيتم تطبيق ': {'en': 'Will apply ', 'fr': 'Application de '},
 '+ منتج جديد': {'en': '+ New product', 'fr': '+ Nouveau produit'},
 'صورة المنتج': {'en': 'Product image', 'fr': 'Image du produit'},
 'اختيار صورة': {'en': 'Choose image', 'fr': 'Choisir une image'},
 'اسم المتغير': {'en': 'Variant name', 'fr': 'Nom de la variante'},
 'فشل الحفظ: ': {'en': 'Save failed: ', 'fr': "Échec de l'enregistrement : "},
 'فشل الحذف: ': {'en': 'Delete failed: ', 'fr': 'Échec de la suppression : '},
 '||  المعلّق': {'en': '||  Held', 'fr': '||  En attente'},
 ' • المتاح: ': {'en': ' • Available: ', 'fr': ' • Disponible : '},
 'أعلى فاتورة': {'en': 'Highest invoice', 'fr': 'Facture la plus haute'},
 'حركة متوسطة': {'en': 'Medium traffic', 'fr': 'Affluence moyenne'},
 ' فاتورة/يوم': {'en': ' invoices/day', 'fr': ' factures/jour'},
 'البحث العام': {'en': 'Global search', 'fr': 'Recherche globale'},
 ': 0.00 د.ج': {'en': ': 0.00 DZD', 'fr': ' : 0,00 DA'},
 'سعر الشراء': {'en': 'Purchase price', 'fr': "Prix d'achat"},
 'حذف الصورة': {'en': 'Remove image', 'fr': "Supprimer l'image"},
 '＋ بيع جديد': {'en': '＋ New sale', 'fr': '＋ Nouvelle vente'},
 'عليهم ديون': {'en': 'With debts', 'fr': 'Avec dettes'},
 'كل الأجهزة': {'en': 'All devices', 'fr': 'Tous les périphériques'},
 'مثال: 5000': {'en': 'Example: 5000', 'fr': 'Exemple : 5000'},
 'أقل فاتورة': {'en': 'Lowest invoice', 'fr': 'Facture la plus basse'},
 'خطأ في PDF': {'en': 'PDF error', 'fr': 'Erreur PDF'},
 'آخر 7 أيام': {'en': 'Last 7 days', 'fr': '7 derniers jours'},
 'ترتيب حسب:': {'en': 'Sort by:', 'fr': 'Trier par :'},
 'حذف المورد': {'en': 'Delete supplier', 'fr': 'Supprimer le fournisseur'},
 'تم إرجاع ': {'en': 'Returned ', 'fr': 'Retour de '},
 '📈 الأرباح': {'en': '📈 Profits', 'fr': '📈 Bénéfices'},
 'حذف متغير': {'en': 'Delete variant', 'fr': 'Supprimer la variante'},
 'دين / بيع': {'en': 'Debt / sale', 'fr': 'Dette / vente'},
 'الفاتورة ': {'en': 'Invoice ', 'fr': 'Facture '},
 'رقم الوصل': {'en': 'Receipt no.', 'fr': 'N° de reçu'},
 'حذف مصروف': {'en': 'Delete expense', 'fr': 'Supprimer la dépense'},
 'هذا الشهر': {'en': 'This month', 'fr': 'Ce mois-ci'},
 'ساعة ذروة': {'en': 'Peak hour', 'fr': 'Heure de pointe'},
 'الباركود': {'en': 'Barcode', 'fr': 'Code-barres'},
 'الصلاحية': {'en': 'Expiry', 'fr': 'Expiration'},
 'باركود: ': {'en': 'Barcode: ', 'fr': 'Code-barres : '},
 ' مكون • ': {'en': ' components • ', 'fr': ' composants • '},
 '0.00 د.ج': {'en': '0.00 DZD', 'fr': '0,00 DA'},
 '|| تعليق': {'en': '|| Hold', 'fr': '|| Suspendre'},
 'كيلوغرام': {'en': 'kilogram', 'fr': 'kilogramme'},
 'دفع جزئي': {'en': 'Partial payment', 'fr': 'Paiement partiel'},
 'دين كامل': {'en': 'Full credit', 'fr': 'Crédit total'},
 'غير مسجل': {'en': 'Not registered', 'fr': 'Non enregistré'},
 'هدوء تام': {'en': 'Very quiet', 'fr': 'Très calme'},
 'حذف مورد': {'en': 'Delete supplier', 'fr': 'Supprimer le fournisseur'},
 ' بقيمة ': {'en': ' worth ', 'fr': " d'une valeur de "},
 'مبيعات ': {'en': 'Sales ', 'fr': 'Ventes '},
 'المتغير': {'en': 'Variant', 'fr': 'Variante'},
 '✗ مغلقة': {'en': '✗ Closed', 'fr': '✗ Fermé'},
 'استرجاع': {'en': 'Restore', 'fr': 'Restaurer'},
 ' د.ج / ': {'en': ' DZD / ', 'fr': ' DA / '},
 'العملاء': {'en': 'Customers', 'fr': 'Clients'},
 'المجموع': {'en': 'Total', 'fr': 'Total'},
 'الساعة:': {'en': 'Hour:', 'fr': 'Heure :'},
 ' دج | ': {'en': ' DZD | ', 'fr': ' DA | '},
 ' دج / ': {'en': ' DZD / ', 'fr': ' DA / '},
 'إرجاع ': {'en': 'Return ', 'fr': 'Retour de '},
 '30 يوم': {'en': '30 days', 'fr': '30 jours'},
 '7 أيام': {'en': '7 days', 'fr': '7 jours'},
 '90 يوم': {'en': '90 days', 'fr': '90 jours'},
 'الحركة': {'en': 'Movement', 'fr': 'Mouvement'},
 'الفعلي': {'en': 'Actual', 'fr': 'Réel'},
 'النظام': {'en': 'System', 'fr': 'Système'},
 'كمية «': {'en': 'Quantity of «', 'fr': 'Quantité de «'},
 'الزبون': {'en': 'Customer', 'fr': 'Client'},
 'خصومات': {'en': 'Discounts', 'fr': 'Remises'},
 ' دج • ': {'en': ' DZD • ', 'fr': ' DA • '},
 'المورد': {'en': 'Supplier', 'fr': 'Fournisseur'},
 'البحث': {'en': 'Search', 'fr': 'Recherche'},
 'تعليق': {'en': 'Hold', 'fr': 'Suspendre'},
 'موافق': {'en': 'OK', 'fr': 'OK'},
 '✕ رفض': {'en': '✕ Reject', 'fr': '✕ Refuser'},
 ' وحدة': {'en': ' units', 'fr': ' unités'},
 'الجرد': {'en': 'Stocktake', 'fr': 'Inventaire'},
 'الفرق': {'en': 'Difference', 'fr': 'Différence'},
 'السبب': {'en': 'Reason', 'fr': 'Motif'},
 'إضافة': {'en': 'Add', 'fr': 'Ajouter'},
 'بطاقة': {'en': 'Card', 'fr': 'Carte'},
 ' دج (': {'en': ' DZD (', 'fr': ' DA ('},
 ' د.ج)': {'en': ' DZD)', 'fr': ' DA)'},
 'وصل: ': {'en': 'Receipt: ', 'fr': 'Reçu : '},
 'بـاقة': {'en': 'pack', 'fr': 'pack'},
 'دجاجة': {'en': 'دجاجة', 'fr': 'دجاجة'},
 'دجاجي': {'en': 'دجاجي', 'fr': 'دجاجي'},
 ' من ': {'en': ' of ', 'fr': ' de '},
 ' دج؟': {'en': ' DZD?', 'fr': ' DA ?'},
 'ربح ': {'en': 'Profit ', 'fr': 'Profit '},
 ' د.ج': {'en': ' DZD', 'fr': ' DA'},
 'بدون': {'en': 'None', 'fr': 'Aucun'},
 'قطعة': {'en': 'pc', 'fr': 'pièce'},
 'نقدي': {'en': 'Cash', 'fr': 'Espèces'},
 'مسدد': {'en': 'Settled', 'fr': 'Réglé'},
 'إلى:': {'en': 'To:', 'fr': 'À :'},
 ' دج\n': {'en': ' DZD\n', 'fr': ' DA\n'},
 'غرام': {'en': 'g', 'fr': 'g'},
 'دجاج': {'en': 'دجاج', 'fr': 'دجاج'},
 ' ث)': {'en': ' s)', 'fr': ' s)'},
 'سنة': {'en': 'Year', 'fr': 'Année'},
 'فتح': {'en': 'Open', 'fr': 'Ouvrir'},
 'خطأ': {'en': 'Error', 'fr': 'Erreur'},
 'د.ج': {'en': 'DZD', 'fr': 'DA'},
 'دج': {'en': 'DZD', 'fr': 'DA'},
 ' دج': {'en': ' DZD', 'fr': ' DA'},
 'من:': {'en': 'From:', 'fr': 'De :'},
 'لتر': {'en': 'L', 'fr': 'L'},
 'متر': {'en': 'm', 'fr': 'm'},
 'تم': {'en': 'Done', 'fr': 'Terminé'},
 '»؟': {'en': '"?', 'fr': '» ?'},
 'كغ': {'en': 'kg', 'fr': 'kg'},

 'ثبّت openpyxl في نفس Python المستخدم لتشغيل البرنامج:\n\npython -m pip install openpyxl': {'en': 'Install openpyxl in the same Python used to run the program:\n\npython -m pip install openpyxl', 'fr': 'Installez openpyxl dans le même Python utilisé pour exécuter le programme :\n\npython -m pip install openpyxl'},
 'ويُفضّل تثبيت الحزم الثلاث للحصول على العربية المتصلة والاتجاه الصحيح في PDF.': {'en': 'It is recommended to install all three packages to get connected Arabic text and correct RTL direction in the PDF.', 'fr': "Il est recommandé d'installer les trois paquets pour obtenir un texte arabe connecté et une direction RTL correcte dans le PDF."},
 'تعريف مجموعات من المنتجات تُباع بسعر ثابت مع خصم تلقائي من مخزون كل مكون': {'en': "Define groups of products sold at a fixed price with automatic deduction from each component's stock", 'fr': 'Définissez des groupes de produits vendus à prix fixe avec déduction automatique du stock de chaque composant'},
 'تمت عملية البيع بنجاح.\nهل تريد طباعة الفاتورة الآن؟\n\nرقم الفاتورة: ': {'en': 'The sale completed successfully.\nDo you want to print the invoice now?\n\nInvoice number: ', 'fr': "La vente s'est déroulée avec succès.\nVoulez-vous imprimer la facture maintenant ?\n\nNuméro de facture : "},
 'هل أنت متأكد من حذف هذا المنتج؟\nلا يمكن التراجع عن العملية.': {'en': 'Are you sure you want to delete this product?\nThis action cannot be undone.', 'fr': 'Êtes-vous sûr de vouloir supprimer ce produit ?\nCette action ne peut pas être annulée.'},
 'ثبّت ReportLab في نفس Python المستخدم لتشغيل البرنامج:\n\n': {'en': 'Install ReportLab in the same Python used to run the program:\n\n', 'fr': 'Installez ReportLab dans le même Python utilisé pour exécuter le programme :\n\n'},
 'متابعة الكميات والتنبيهات وحركات دخول وخروج المخزون': {'en': 'Track quantities, alerts, and stock in/out movements', 'fr': "Suivez les quantités, les alertes et les mouvements d'entrée/sortie du stock"},
 'إعدادات المتجر والفواتير والبيع وحماية البيانات': {'en': 'Store, invoice, sales, and data protection settings', 'fr': 'Paramètres du magasin, factures, ventes et protection des données'},
 'جرّب كلمة بحث أخرى أو غيّر حالة المخزون': {'en': 'Try another search term or change the stock status', 'fr': "Essayez un autre terme ou changez l'état du stock"},
 'لا يمكن الحفظ: مجموع كميات المتغيرات (': {'en': 'Cannot save: the sum of variant quantities (', 'fr': "Impossible d'enregistrer : la somme des quantités de variantes ("},
 'إدارة بيانات الموردين ومعلومات التواصل': {'en': 'Manage supplier data and contact information', 'fr': 'Gérez les données des fournisseurs et les coordonnées'},
 'جرّب تغيير البحث أو أضف عميلًا جديدًا': {'en': 'Try changing the search or add a new customer', 'fr': 'Essayez de modifier la recherche ou ajoutez un nouveau client'},
 'لا يمكن تسديد أكثر من الدين الحالي (': {'en': 'Cannot pay more than the current debt (', 'fr': 'Impossible de payer plus que la dette actuelle ('},
 'لا يمكن إضافة المتغير: الإجمالي (': {'en': 'Cannot add the variant: the total (', 'fr': "Impossible d'ajouter la variante : le total ("},
 'تم إنشاء النسخة الاحتياطية بنجاح\n': {'en': 'Backup created successfully\n', 'fr': 'Sauvegarde créée avec succès\n'},
 'طباعة الفاتورة تلقائياً بعد الدفع': {'en': 'Automatically print the invoice after payment', 'fr': 'Imprimer automatiquement la facture après le paiement'},
 ' اختر منتجًا من الاقتراحات أولًا.': {'en': ' Choose a product from the suggestions first.', 'fr': " Choisissez d'abord un produit dans les suggestions."},
 'إدارة العملاء والديون والمدفوعات': {'en': 'Manage customers, debts, and payments', 'fr': 'Gérez les clients, les dettes et les paiements'},
 'هل أنت متأكد من إغلاق البرنامج؟': {'en': 'Are you sure you want to close the program?', 'fr': 'Êtes-vous sûr de vouloir fermer le programme ?'},
 'تم إلغاء الوصل واسترجاع المخزون': {'en': ' — receipt voided and stock restored', 'fr': ' — reçu annulé et stock restauré'},
 ') يتجاوز كمية المنتج الكلية (': {'en': ") exceeds the product's total quantity (", 'fr': ') dépasse la quantité totale du produit ('},
 'فشل إنشاء النسخة الاحتياطية:\n': {'en': 'Failed to create the backup:\n', 'fr': 'Échec de la création de la sauvegarde :\n'},
 'البحث والتعديل وإدارة المخزون': {'en': 'Search, edit, and manage stock', 'fr': 'Rechercher, modifier et gérer le stock'},
 'لا توجد منتجات في هذا التصنيف': {'en': 'No products in this category', 'fr': 'Aucun produit dans cette catégorie'},
 ' لا توجد تنبيهات مهمة حاليًا': {'en': ' No important alerts right now', 'fr': ' Aucune alerte importante pour le moment'},
 'افتح المخزون لمعرفة المنتجات': {'en': 'Open Inventory to see the products', 'fr': "Ouvrez l'Inventaire pour voir les produits"},
 'جرّب تغيير الفلتر أو البحث': {'en': 'Try changing the filter or search', 'fr': 'Essayez de changer le filtre ou la recherche'},
 ' تعذر تطبيق بعض التسويات:\n': {'en': ' Some adjustments could not be applied:\n', 'fr': " Certains ajustements n'ont pas pu être appliqués :\n"},
 'منتج مكوّن لم يعد موجودًا': {'en': 'A component product no longer exists', 'fr': "Un produit composant n'existe plus"},
 ' تعذر تحميل سجل المخزون:\n': {'en': ' Failed to load stock log:\n', 'fr': " Échec du chargement de l'historique du stock :\n"},
 'تم البيع. الدين المسجل: ': {'en': 'Sale completed. Recorded debt: ', 'fr': 'Vente effectuée. Dette enregistrée : '},
 'مكتبة PDF غير موجودة.\n\n': {'en': 'PDF library is not installed.\n\n', 'fr': "La bibliothèque PDF n'est pas installée.\n\n"},
 ' تعذر تحميل المنتجات:\n': {'en': ' Failed to load products:\n', 'fr': ' Échec du chargement des produits :\n'},
 'تعذر إنشاء ملف PDF:\n': {'en': 'Failed to create the PDF file:\n', 'fr': 'Échec de la création du fichier PDF :\n'},
 'يُنصح بإعادة التزويد': {'en': 'Restocking is recommended', 'fr': 'Un réapprovisionnement est recommandé'},
 'راجع تواريخ الصلاحية': {'en': 'Check the expiration dates', 'fr': "Vérifiez les dates d'expiration"},
 'مخزون غير كافٍ لـ «': {'en': 'Insufficient stock for «', 'fr': 'Stock insuffisant pour «'},
 '). المتاح المتبقي: ': {'en': '). Remaining available: ', 'fr': '). Restant disponible : '},
 ' منتج قريب الانتهاء': {'en': ' product(s) expiring soon', 'fr': ' produit(s) expirant bientôt'},
 'تم البيع. الباقي: ': {'en': 'Sale completed. Change: ', 'fr': 'Vente effectuée. Monnaie : '},
 'تعذر تحميل العملاء': {'en': 'Failed to load customers', 'fr': 'Échec du chargement des clients'},
 '+ إضافة زبون جديد': {'en': '+ Add New Customer', 'fr': '+ Ajouter un nouveau client'},
 ' زبون لديهم ديون': {'en': ' customer(s) with debts', 'fr': ' client(s) ayant des dettes'},
 ' إدارة المنتجات': {'en': ' Products Management', 'fr': ' Gestion des produits'},
 'زبون لديهم ديون': {'en': 'Customers with debts', 'fr': 'Clients ayant des dettes'},
 'إجمالي الديون ': {'en': 'Total debts ', 'fr': 'Total des dettes '},
 'حفظ الإعدادات': {'en': 'Save Settings', 'fr': 'Enregistrer les paramètres'},
 'اختيار المنتج': {'en': 'Select Product', 'fr': 'Choisir le produit'},
 'تم تسديد دين ': {'en': 'Paid off the debt of ', 'fr': 'Dette de '},
 'المخزون الذكي': {'en': 'Smart Inventory', 'fr': 'Inventaire intelligent'},
 'لا توجد نتائج': {'en': 'No results found', 'fr': 'Aucun résultat trouvé'},
 'لا يوجد عملاء': {'en': 'No customers', 'fr': 'Aucun client'},
 'تعديل المنتج': {'en': 'Edit Product', 'fr': 'Modifier le produit'},
 'تأكيد الخروج': {'en': 'Confirm Exit', 'fr': 'Confirmer la sortie'},
 'المتوفر من (': {'en': 'the available of (', 'fr': 'le disponible de ('},
 'تأكيد الحذف': {'en': 'Confirm Deletion', 'fr': 'Confirmer la suppression'},
 ' — المتبقي ': {'en': ' — remaining ', 'fr': ' — reste '},
 ' منتج منخفض': {'en': ' product(s) low', 'fr': ' produit(s) en quantité faible'},
 ' منتج نافد': {'en': ' product(s) out of stock', 'fr': ' produit(s) en rupture de stock'},
 '»: مطلوب ': {'en': '»: required ', 'fr': '» : requis '},
 'تسوية جرد': {'en': 'Stock adjustment', 'fr': 'Ajustement de stock'},
 'تم تسديد ': {'en': 'Paid ', 'fr': 'Payé '},
 'الإجمالي ': {'en': 'Total ', 'fr': 'Total '},
 '، متوفر ': {'en': ', available ', 'fr': ', disponible '},
 'حذف منتج': {'en': 'Delete Product', 'fr': 'Supprimer le produit'},
 ' بالكامل': {'en': ' in full', 'fr': ' entièrement réglée'},
 ' الباقات': {'en': ' Packs', 'fr': ' Forfaits'},
 'الحجم: ': {'en': 'Size: ', 'fr': 'Taille : '},
 '■ رمادي': {'en': '■ Grey', 'fr': '■ Gris'},
 ') هو (': {'en': ') is (', 'fr': ') est ('},
 '☀ فاتح': {'en': '☀ Light', 'fr': '☀ Clair'},
 '● داكن': {'en': '● Dark', 'fr': '● Sombre'},
 ') فقط': {'en': ') only', 'fr': ') seulement'},
 'ملغى': {'en': 'voided', 'fr': 'annulé'},
 '؟': {'en': '?', 'fr': ' ?'},

 ' — المتاح ': {'en': ' — available ', 'fr': ' — disponible '},
 ' — ': {'en': ' — ', 'fr': ' — '},

 'لا يمكن إضافة المزيد: المتوفر من (': {'en': 'Cannot add more: the available of (', 'fr': "Impossible d'en ajouter plus : le disponible de ("},



 'كهرباء/ماء': {'en': 'Electricity/Water', 'fr': 'Électricité/Eau'},
 'مستلزمات': {'en': 'Supplies', 'fr': 'Fournitures'},
 'الثلاثاء': {'en': 'Tuesday', 'fr': 'Mardi'},
 'الأربعاء': {'en': 'Wednesday', 'fr': 'Mercredi'},
 'الاثنين': {'en': 'Monday', 'fr': 'Lundi'},
 'الخميس': {'en': 'Thursday', 'fr': 'Jeudi'},
 'الجمعة': {'en': 'Friday', 'fr': 'Vendredi'},
 'إيجار': {'en': 'Rent', 'fr': 'Loyer'},
 'رواتب': {'en': 'Salaries', 'fr': 'Salaires'},
 'صيانة': {'en': 'Maintenance', 'fr': 'Maintenance'},
 'الأحد': {'en': 'Sunday', 'fr': 'Dimanche'},
 'السبت': {'en': 'Saturday', 'fr': 'Samedi'},
 'أخرى': {'en': 'Other', 'fr': 'Autre'},

 # ===== المشتريات / فواتير الشراء (Purchases) =====
 'المشتريات': {'en': 'Purchases', 'fr': 'Achats'},
 'فواتير الشراء من الموردين': {'en': 'Purchase invoices from suppliers', 'fr': 'Factures d\'achat des fournisseurs'},
 'إدارة فواتير الشراء من الموردين': {'en': 'Manage purchase invoices from suppliers', 'fr': 'Gérer les factures d\'achat des fournisseurs'},
 'فاتورة شراء جديدة': {'en': 'New purchase invoice', 'fr': 'Nouvelle facture d\'achat'},
 'فواتير الشراء': {'en': 'Purchase invoices', 'fr': 'Factures d\'achat'},
 'ملخص المشتريات': {'en': 'Purchases summary', 'fr': 'Résumé des achats'},
 'إجمالي المشتريات': {'en': 'Total purchases', 'fr': 'Total des achats'},
 'عدد الفواتير': {'en': 'Number of invoices', 'fr': 'Nombre de factures'},
 'رصيد الموردين': {'en': 'Suppliers balance', 'fr': 'Solde des fournisseurs'},
 'حساب المورد': {'en': 'Supplier account', 'fr': 'Compte fournisseur'},
 'المورد': {'en': 'Supplier', 'fr': 'Fournisseur'},
 'اختر المورد': {'en': 'Select supplier', 'fr': 'Choisir le fournisseur'},
 'منتجات الفاتورة': {'en': 'Invoice items', 'fr': 'Articles de la facture'},
 'اختر موردًا أولًا': {'en': 'Select a supplier first', 'fr': 'Choisissez d\'abord un fournisseur'},
 'المورد مطلوب': {'en': 'Supplier is required', 'fr': 'Fournisseur requis'},
 'إضافة مورد جديد': {'en': 'Add new supplier', 'fr': 'Ajouter un fournisseur'},
 'تمت إضافة المورد بنجاح': {'en': 'Supplier added successfully', 'fr': 'Fournisseur ajouté avec succès'},
 'البحث في المنتجات': {'en': 'Search products', 'fr': 'Rechercher des produits'},
 'ابحث بالاسم أو الباركود...': {'en': 'Search by name or barcode...', 'fr': 'Rechercher par nom ou code-barres...'},
 'إضافة إلى الفاتورة': {'en': 'Add to invoice', 'fr': 'Ajouter à la facture'},
 'المجموع الفرعي': {'en': 'Subtotal', 'fr': 'Sous-total'},
 'المتبقي': {'en': 'Remaining', 'fr': 'Restant'},
 'الدفع': {'en': 'Payment', 'fr': 'Paiement'},
 'على الحساب': {'en': 'On credit', 'fr': 'À crédit'},
 'دفعة جزئية': {'en': 'Partial payment', 'fr': 'Paiement partiel'},
 'حفظ فاتورة الشراء': {'en': 'Save purchase invoice', 'fr': 'Enregistrer la facture d\'achat'},
 'تم تسجيل فاتورة الشراء بنجاح': {'en': 'Purchase invoice saved successfully', 'fr': 'Facture d\'achat enregistrée avec succès'},
 'تعذر حفظ فاتورة الشراء': {'en': 'Could not save purchase invoice', 'fr': 'Impossible d\'enregistrer la facture d\'achat'},
 'لا توجد منتجات في الفاتورة': {'en': 'No products in the invoice', 'fr': 'Aucun produit dans la facture'},
 'كمية المنتج يجب أن تكون أكبر من صفر': {'en': 'Product quantity must be greater than zero', 'fr': 'La quantité doit être supérieure à zéro'},
 'سعر الشراء لا يمكن أن يكون سالبًا': {'en': 'Purchase price cannot be negative', 'fr': 'Le prix d\'achat ne peut pas être négatif'},
 'أدخل كمية وسعر شراء صحيحين': {'en': 'Enter valid quantity and purchase price', 'fr': 'Saisissez une quantité et un prix valides'},
 'الكمية المطلوبة': {'en': 'Quantity', 'fr': 'Quantité'},
 'سعر الشراء (د.ج)': {'en': 'Purchase price (DZD)', 'fr': 'Prix d\'achat (DA)'},
 'سعر الشراء السابق': {'en': 'Previous purchase price', 'fr': 'Prix d\'achat précédent'},
 'المنتجات المختارة': {'en': 'Selected products', 'fr': 'Produits sélectionnés'},
 'الملخص والدفع': {'en': 'Summary & payment', 'fr': 'Résumé et paiement'},
 'رصيد المورد:': {'en': 'Supplier balance:', 'fr': 'Solde fournisseur :'},
 'طريقة الدفع': {'en': 'Payment method', 'fr': 'Mode de paiement'},
 'المبلغ المدفوع (د.ج)': {'en': 'Paid amount (DZD)', 'fr': 'Montant payé (DA)'},
 'الخصم (د.ج)': {'en': 'Discount (DZD)', 'fr': 'Remise (DA)'},
 '💾 حفظ الفاتورة': {'en': 'Save invoice', 'fr': 'Enregistrer la facture'},
 'اختر متغير المنتج': {'en': 'Choose product variant', 'fr': 'Choisissez la variante du produit'},
 'المتاح:': {'en': 'Available:', 'fr': 'Disponible :'},
 'متغير': {'en': 'Variant', 'fr': 'Variante'},
 'اختر المتغير ثم اضغط إضافة لتعبئة رصيده': {'en': 'Choose the variant, then press Add to restock it', 'fr': 'Choisissez la variante puis cliquez sur Ajouter pour la réapprovisionner'},
 'منتج غير موجود في الفاتورة': {'en': 'Product does not exist in the invoice', 'fr': 'Produit inexistant dans la facture'},
 'متغير المنتج غير صالح': {'en': 'Invalid product variant', 'fr': 'Variante de produit invalide'},
 'تلميح: انقر على المنتج لإضافته فورًا، ثم عدّل الكمية والسعر في قائمة البنود.': {'en': 'Tip: click a product to add it instantly, then edit quantity and price in the items list.', 'fr': 'Astuce : cliquez sur un produit pour l\'ajouter instantanément, puis modifiez la quantité et le prix dans la liste.'},
 'بحث': {'en': 'Search', 'fr': 'Rechercher'},
 'لا توجد نتائج': {'en': 'No results', 'fr': 'Aucun résultat'},
 'تفاصيل فاتورة الشراء': {'en': 'Purchase invoice details', 'fr': 'Détails de la facture d\'achat'},
 'تسديد رصيد مورد': {'en': 'Pay supplier balance', 'fr': 'Régler le solde fournisseur'},
 'المبلغ المطلوب تسديده': {'en': 'Amount to pay', 'fr': 'Montant à régler'},
 'تم تسجيل التسديد بنجاح': {'en': 'Payment recorded successfully', 'fr': 'Paiement enregistré avec succès'},
 'المبلغ يجب أن يكون أكبر من صفر': {'en': 'Amount must be greater than zero', 'fr': 'Le montant doit être supérieur à zéro'},
 'المبلغ أكبر من رصيد المورد': {'en': 'Amount exceeds supplier balance', 'fr': 'Le montant dépasse le solde du fournisseur'},
 'المبلغ أكبر من المتبقي': {'en': 'Amount exceeds remaining balance', 'fr': 'Le montant dépasse le reste'},
 'فواتير الشراء لهذا المورد': {'en': 'Purchase invoices for this supplier', 'fr': 'Factures d\'achat de ce fournisseur'},
 'منتجات أخرى لهذا المورد': {'en': 'Other products from this supplier', 'fr': 'Autres produits de ce fournisseur'},
 'هل أنت متأكد من حذف فاتورة الشراء؟': {'en': 'Are you sure you want to delete this purchase invoice?', 'fr': 'Voulez-vous vraiment supprimer cette facture d\'achat ?'},
 'لا يمكن حذف الفاتورة': {'en': 'Could not delete invoice', 'fr': 'Impossible de supprimer la facture'},
 'هل أنت متأكد من حذف فاتورة الشراء؟': {'en': 'Are you sure you want to delete this purchase invoice?', 'fr': 'Voulez-vous vraiment supprimer cette facture d\'achat ?'},
 'تم حذف فاتورة الشراء': {'en': 'Purchase invoice deleted', 'fr': 'Facture d\'achat supprimée'},
 'شراء من مورد - ': {'en': 'Purchase from supplier - ', 'fr': 'Achat fournisseur - '},
 'حذف فاتورة شراء': {'en': 'Delete purchase invoice', 'fr': 'Supprimer la facture d\'achat'},
 'ابحث برقم الفاتورة أو اسم المورد...': {'en': 'Search by invoice number or supplier name...', 'fr': 'Rechercher par numéro de facture ou nom du fournisseur...'},
 'لم يتم العثور على نتائج': {'en': 'No results found', 'fr': 'Aucun résultat trouvé'},
 'فاتورة الشراء غير موجودة': {'en': 'Purchase invoice not found', 'fr': 'Facture d\'achat introuvable'},
 'المورد غير موجود': {'en': 'Supplier not found', 'fr': 'Fournisseur introuvable'},
 'منتج غير صالح في الفاتورة': {'en': 'Invalid product in invoice', 'fr': 'Produit invalide dans la facture'},
 'كمية صحيحة أكبر من صفر': {'en': 'Valid quantity greater than zero', 'fr': 'Quantité valide supérieure à zéro'},
 'الفواتير': {'en': 'Invoices', 'fr': 'Factures'},
 'التاريخ': {'en': 'Date', 'fr': 'Date'},
 'المقبوضات': {'en': 'Payments', 'fr': 'Paiements'},
 'المسحوبات': {'en': 'Withdrawals', 'fr': 'Retraits'},
 'عمليات المتجر': {'en': 'Store operations', 'fr': 'Opérations du magasin'},
 'العمليات الأخيرة': {'en': 'Recent operations', 'fr': 'Opérations récentes'},
 'فاتورة الشراء رقم': {'en': 'Purchase invoice no.', 'fr': 'Facture d\'achat n°'},
 'الباركود غير موجود': {'en': 'Barcode not found', 'fr': 'Code-barres introuvable'},
 'اسم المورد مطلوب': {'en': 'Supplier name is required', 'fr': 'Le nom du fournisseur est requis'},
 'تلميح: يمكن مسح الباركود مباشرة ثم إدخال الكمية والسعر': {'en': 'Tip: you can scan the barcode directly, then set quantity and price', 'fr': 'Astuce : scannez le code-barres directement, puis définissez quantité et prix'},
 'لا يوجد موردون بعد — استعمل زر ＋ للإضافة': {'en': 'No suppliers yet — use the ＋ button to add one', 'fr': 'Aucun fournisseur encore — utilisez le bouton ＋ pour en ajouter'},
 'تسجيل مشتريات من المورد مع تحديث المخزون والرصيد': {'en': 'Record supplier purchases while updating stock and balance', 'fr': 'Enregistrer les achats fournisseur en mettant à jour le stock et le solde'},
 'تشمل التوصيل...': {'en': 'Includes delivery...', 'fr': 'Inclut la livraison...'},
 'أدخل المبلغ...': {'en': 'Enter the amount...', 'fr': 'Entrez le montant...'},
 'قبل الخصم': {'en': 'before discount', 'fr': 'avant remise'},
 'صافي الفاتورة': {'en': 'Invoice net', 'fr': 'Net de la facture'},
 'لا توجد أرصدة مستحقة للموردين': {'en': 'No outstanding supplier balances', 'fr': 'Aucun solde fournisseur impayé'},
 'تسديد حساب مورد': {'en': 'Settle supplier account', 'fr': 'Régler le compte fournisseur'},
 'الرصيد': {'en': 'Balance', 'fr': 'Solde'},
 'المدفوعة': {'en': 'Paid', 'fr': 'Payée'},
 'مصروف تشغيلي': {'en': 'Operating expense', 'fr': 'Dépense d\'exploitation'},
 'B2B': {'en': 'B2B', 'fr': 'B2B'},
 'عملاء B2B': {'en': 'B2B Customers', 'fr': 'Clients B2B'},
 'إدارة عملاء B2B': {'en': 'B2B Customer Management', 'fr': 'Gestion des clients B2B'},
 'إدارة ملفات العملاء التجارية (NIF, NIS, RC, سقف الائتمان)': {'en': 'Manage corporate customer profiles (NIF, NIS, RC, credit limit)', 'fr': 'Gérer les profils clients professionnels (NIF, NIS, RC, plafond de crédit)'},
 'بحث عن عميل B2B (الاسم أو NIF)...': {'en': 'Search B2B customer (name or NIF)...', 'fr': 'Rechercher un client B2B (nom ou NIF)...'},
 'إضافة عميل B2B': {'en': 'Add B2B Customer', 'fr': 'Ajouter un client B2B'},
 'ملفات B2B': {'en': 'B2B Profiles', 'fr': 'Profils B2B'},
 'ملفات نشطة': {'en': 'Active Profiles', 'fr': 'Profils actifs'},
 'إجمالي سقف الائتمان': {'en': 'Total Credit Limit', 'fr': 'Plafond de crédit total'},
 'الشريحة': {'en': 'Tier', 'fr': 'Segment'},
 'شريحة العميل': {'en': 'Customer Tier', 'fr': 'Segment client'},
 'سقف الائتمان': {'en': 'Credit Limit', 'fr': 'Plafond de crédit'},
 'سقف الائتمان (د.ج)': {'en': 'Credit Limit (DZD)', 'fr': 'Plafond de crédit (DA)'},
 'أجل السداد (أيام)': {'en': 'Payment Terms (days)', 'fr': 'Délai de paiement (jours)'},
 '0 يعني الدفع الفوري': {'en': '0 means immediate payment', 'fr': '0 = paiement immédiat'},
 'معلومات الشركة': {'en': 'Company Information', 'fr': 'Informations de l\'entreprise'},
 'معلومات الاتصال': {'en': 'Contact Information', 'fr': 'Coordonnées'},
 'الشروط التجارية': {'en': 'Commercial Terms', 'fr': 'Conditions commerciales'},
 'اسم الشركة': {'en': 'Company Name', 'fr': 'Nom de l\'entreprise'},
 'NIF': {'en': 'NIF', 'fr': 'NIF'},
 'NIS': {'en': 'NIS', 'fr': 'NIS'},
 'RC': {'en': 'RC', 'fr': 'RC'},
 'AI': {'en': 'AI', 'fr': 'AI'},
 'البريد الإلكتروني': {'en': 'Email', 'fr': 'E-mail'},
 'الشخص المسؤول': {'en': 'Contact Person', 'fr': 'Personne responsable'},
 'قطاعي': {'en': 'Retail', 'fr': 'Détail'},
 'شبه جملة': {'en': 'Semi-Wholesale', 'fr': 'Demi-gros'},
 'جملة': {'en': 'Wholesale', 'fr': 'Gros'},
 'نشط': {'en': 'Active', 'fr': 'Actif'},
 'موقف': {'en': 'Inactive', 'fr': 'Inactif'},
 'إيقاف': {'en': 'Deactivate', 'fr': 'Désactiver'},
 'اختر زبونًا من قائمة الزبائن': {'en': 'Pick a customer from the customer list', 'fr': 'Choisissez un client dans la liste des clients'},
 'ابحث عن زبون (الاسم أو الهاتف)...': {'en': 'Search customer (name or phone)...', 'fr': 'Rechercher un client (nom ou téléphone)...'},
 '✓ تم الاختيار': {'en': '✓ Selected', 'fr': '✓ Sélectionné'},
 'لا يوجد زبون متاح': {'en': 'No customer available', 'fr': 'Aucun client disponible'},
 'هذا الزبون لديه ملف B2B بالفعل': {'en': 'This customer already has a B2B profile', 'fr': 'Ce client a déjà un profil B2B'},
 'الزبون غير موجود': {'en': 'Customer not found', 'fr': 'Client introuvable'},
 'اسم العميل مطلوب': {'en': 'Customer name is required', 'fr': 'Le nom du client est requis'},
 'اسم العميل قصير جدًا': {'en': 'Customer name is too short', 'fr': 'Le nom du client est trop court'},
 'بيانات غير مكتملة': {'en': 'Incomplete data', 'fr': 'Données incomplètes'},
 'تم إنشاء ملف B2B بنجاح': {'en': 'B2B profile created successfully', 'fr': 'Profil B2B créé avec succès'},
 'تم تحديث ملف B2B بنجاح': {'en': 'B2B profile updated successfully', 'fr': 'Profil B2B mis à jour avec succès'},
 'تم تفعيل ملف B2B': {'en': 'B2B profile activated', 'fr': 'Profil B2B activé'},
 'تم إيقاف ملف B2B': {'en': 'B2B profile deactivated', 'fr': 'Profil B2B désactivé'},
 'ملف B2B غير موجود': {'en': 'B2B profile not found', 'fr': 'Profil B2B introuvable'},
 'فشل إنشاء ملف B2B:': {'en': 'Failed to create B2B profile:', 'fr': 'Échec de la création du profil B2B :'},
 'فشل تحديث ملف B2B:': {'en': 'Failed to update B2B profile:', 'fr': 'Échec de la mise à jour du profil B2B :'},
 'فشل تحديث الحالة:': {'en': 'Failed to update status:', 'fr': 'Échec de la mise à jour du statut :'},
 'تعذر تحميل عملاء B2B': {'en': 'Could not load B2B customers', 'fr': 'Impossible de charger les clients B2B'},
 'تعذر فتح صفحة B2B': {'en': 'Could not open B2B page', 'fr': 'Impossible d\'ouvrir la page B2B'},
 'لا يوجد عملاء B2B': {'en': 'No B2B customers yet', 'fr': 'Aucun client B2B'},
 'أضف أول ملف B2B لزبون قائم': {'en': 'Add the first B2B profile for an existing customer', 'fr': 'Ajoutez le premier profil B2B pour un client existant'},
 'تعديل ملف B2B': {'en': 'Edit B2B Profile', 'fr': 'Modifier le profil B2B'},
 'عرض ملف B2B': {'en': 'View B2B Profile', 'fr': 'Afficher le profil B2B'},
 ' يجب أن يكون رقمًا صالحًا': {'en': ' must be a valid number', 'fr': ' doit être un nombre valide'},
 ' لا يمكن أن يكون سالبًا': {'en': ' cannot be negative', 'fr': ' ne peut pas être négatif'},
 ' أكبر من الحد المسموح': {'en': ' exceeds the allowed limit', 'fr': ' dépasse la limite autorisée'},
 ' يجب أن يحتوي أرقامًا فقط (10-20 خانة)': {'en': ' must contain digits only (10-20 digits)', 'fr': ' doit contenir uniquement des chiffres (10-20 chiffres)'},
 ' يجب أن يكون 5-30 حرفًا (أرقام وحروف)': {'en': ' must be 5-30 characters (digits and letters)', 'fr': ' doit contenir 5-30 caractères (chiffres et lettres)'},
 'البريد الإلكتروني غير صالح': {'en': 'Invalid email address', 'fr': 'Adresse e-mail invalide'},
 'رقم الهاتف غير صالح': {'en': 'Invalid phone number', 'fr': 'Numéro de téléphone invalide'},
 'أجل السداد يجب أن يكون بين 0 و 365 يومًا': {'en': 'Payment terms must be between 0 and 365 days', 'fr': 'Le délai de paiement doit être compris entre 0 et 365 jours'},
 'مستندات B2B': {'en': 'B2B Documents', 'fr': 'Documents B2B'},
 'المستندات': {'en': 'Documents', 'fr': 'Documents'},
 'وثائق تجارية': {'en': 'Commercial documents', 'fr': 'Documents commerciaux'},
 'فاتورة': {'en': 'Invoice', 'fr': 'Facture'},
 'فواتير': {'en': 'Invoices', 'fr': 'Factures'},
 'بروفورما': {'en': 'Proforma', 'fr': 'Proforma'},
 'سند تسليم': {'en': 'Delivery note', 'fr': 'Bon de livraison'},
 'أفوار': {'en': 'Credit note', 'fr': 'Avoir'},
 'استرداد': {'en': 'Refund', 'fr': 'Remboursement'},
 'مسودة': {'en': 'Draft', 'fr': 'Brouillon'},
 'مسودات': {'en': 'Drafts', 'fr': 'Brouillons'},
 'صادرة': {'en': 'Issued', 'fr': 'Émise'},
 'ملغاة': {'en': 'Cancelled', 'fr': 'Annulée'},
 'مسددة': {'en': 'Paid', 'fr': 'Payée'},
 'مسدد جزئيًا': {'en': 'Partially paid', 'fr': 'Partiellement payée'},
 'محولة': {'en': 'Converted', 'fr': 'Convertie'},
 'مصدر الوثيقة': {'en': 'Source document', 'fr': 'Document source'},
 'تحويل إلى فاتورة': {'en': 'Convert to invoice', 'fr': 'Convertir en facture'},
 'تحويل إلى سند تسليم': {'en': 'Convert to delivery note', 'fr': 'Convertir en bon de livraison'},
 'إنشاء أفوار': {'en': 'Create credit note', 'fr': 'Créer un avoir'},
 'إنشاء مسودة الأفوار': {'en': 'Create credit note draft', 'fr': 'Créer le brouillon d\'avoir'},
 'سبب الأفوار': {'en': 'Credit note reason', 'fr': 'Motif de l\'avoir'},
 'تأكيد التحويل': {'en': 'Confirm conversion', 'fr': 'Confirmer la conversion'},
 'تحويل هذه البروفورما إلى فاتورة؟': {'en': 'Convert this proforma to an invoice?', 'fr': 'Convertir cette proforma en facture ?'},
 'تحويل هذه البروفورما إلى سند تسليم؟': {'en': 'Convert this proforma to a delivery note?', 'fr': 'Convertir cette proforma en bon de livraison ?'},
 'يمكن إنشاء فاتورة واحدة فقط من نفس البروفورما': {'en': 'Only one invoice can be created from the same proforma.', 'fr': 'Une seule facture peut être créée à partir de la même proforma.'},
 'تم إنشاء مسودة الفاتورة': {'en': 'Invoice draft created', 'fr': 'Brouillon de facture créé'},
 'تم إنشاء مسودة سند التسليم': {'en': 'Delivery note draft created', 'fr': 'Brouillon de bon de livraison créé'},
 'تم إنشاء مسودة الأفوار': {'en': 'Credit note draft created', 'fr': 'Brouillon d\'avoir créé'},
 'الكمية القصوى': {'en': 'Max quantity', 'fr': 'Quantité maximale'},
 'تجاوز الكمية في الأفوار': {'en': 'Quantity exceeded in credit note', 'fr': 'Quantité dépassée dans l\'avoir'},
 'يمكن إنشاء الأفوار من فاتورة فقط': {'en': 'Credit notes can only be created from an invoice', 'fr': 'Les avoirs ne peuvent être créés qu\'à partir d\'une facture'},
 'توجد فاتورة مشتقة بالفعل من هذه البروفورما': {'en': 'An invoice already exists for this proforma', 'fr': 'Une facture existe déjà pour cette proforma'},
 'يمكن التحويل من مستند صادر فقط': {'en': 'Can only convert from an issued document', 'fr': 'Conversion possible uniquement depuis un document émis'},
 'يمكن إنشاء أفوار من فاتورة صادرة فقط': {'en': 'Credit notes can only be created from an issued invoice', 'fr': 'Les avoirs ne peuvent être créés qu\'à partir d\'une facture émise'},
 'فشل تحويل البروفورما إلى فاتورة: ': {'en': 'Failed to convert proforma to invoice: ', 'fr': 'Échec de la conversion proforma en facture : '},
 'فشل تحويل البروفورما إلى سند تسليم: ': {'en': 'Failed to convert proforma to delivery note: ', 'fr': 'Échec de la conversion proforma en bon de livraison : '},
 'فشل إنشاء الأفوار: ': {'en': 'Failed to create credit note: ', 'fr': 'Échec de la création de l\'avoir : '},
 'مستند جديد': {'en': 'New document', 'fr': 'Nouveau document'},
 'تعديل المستند': {'en': 'Edit document', 'fr': 'Modifier le document'},
 'عرض المستند': {'en': 'View document', 'fr': 'Afficher le document'},
 'رقم المستند': {'en': 'Document number', 'fr': 'N° de document'},
 'نوع المستند': {'en': 'Document type', 'fr': 'Type de document'},
 'تاريخ الإصدار': {'en': 'Issue date', 'fr': 'Date d\'émission'},
 'تاريخ الاستحقاق': {'en': 'Due date', 'fr': 'Date d\'échéance'},
 'إصدار': {'en': 'Issue', 'fr': 'Émettre'},
 'إصدار المستند': {'en': 'Issue document', 'fr': 'Émettre le document'},
 'حفظ مسودة': {'en': 'Save draft', 'fr': 'Enregistrer le brouillon'},
 'إضافة منتج': {'en': 'Add product', 'fr': 'Ajouter un produit'},
 'إضافة سطر': {'en': 'Add line', 'fr': 'Ajouter une ligne'},
 'الأصناف': {'en': 'Items', 'fr': 'Articles'},
 'اسم المنتج': {'en': 'Product name', 'fr': 'Nom du produit'},
 'الملاحظات': {'en': 'Notes', 'fr': 'Notes'},
 'التخفيض': {'en': 'Discount', 'fr': 'Remise'},
 'نسبة التخفيض': {'en': 'Discount rate', 'fr': 'Taux de remise'},
 'إجمالي قبل الضريبة': {'en': 'Total before tax (HT)', 'fr': 'Total hors taxes (HT)'},
 'الضريبة على القيمة المضافة': {'en': 'Value Added Tax (VAT)', 'fr': 'Taxe sur la valeur ajoutée (TVA)'},
 'معدل الضريبة': {'en': 'Tax rate', 'fr': 'Taux de taxe'},
 'الطابع الجبائي': {'en': 'Tax stamp', 'fr': 'Timbre fiscal'},
 'الإجمالي الكلي': {'en': 'Grand total (TTC)', 'fr': 'Total général (TTC)'},
 'المجموع الكلي': {'en': 'Grand total', 'fr': 'Total général'},
 'إجمالي الصادر': {'en': 'Total issued', 'fr': 'Total émis'},
 'المبلغ كتابيًا': {'en': 'Amount in words', 'fr': 'Montant en lettres'},
 'دينار جزائري': {'en': 'Algerian dinar', 'fr': 'Dinar algérien'},
 'تحويل بنكي': {'en': 'Bank transfer', 'fr': 'Virement bancaire'},
 'دفع إلكتروني': {'en': 'Electronic payment', 'fr': 'Paiement électronique'},
 'كل الأنواع': {'en': 'All types', 'fr': 'Tous les types'},
 'كافة الحالات': {'en': 'All statuses', 'fr': 'Tous les statuts'},
 'سبب الإلغاء': {'en': 'Cancellation reason', 'fr': 'Motif d\'annulation'},
 'إلغاء المستند': {'en': 'Cancel document', 'fr': 'Annuler le document'},
 'حذف المسودة': {'en': 'Delete draft', 'fr': 'Supprimer le brouillon'},
 'تأكيد الإصدار': {'en': 'Confirm issue', 'fr': 'Confirmer l\'émission'},
 'تأكيد الإلغاء': {'en': 'Confirm cancellation', 'fr': 'Confirmer l\'annulation'},
 'هل تريد إصدار هذا المستند؟': {'en': 'Do you want to issue this document?', 'fr': 'Voulez-vous émettre ce document ?'},
 'سيتم ترقيم المستند برقم قانوني ولا يمكن تعديله بعد الإصدار': {'en': 'The document will receive a legal sequential number and cannot be modified after issue.', 'fr': 'Le document recevra un numéro légal séquentiel et ne pourra plus être modifié après l\'émission.'},
 'هل تريد حذف هذه المسودة؟': {'en': 'Delete this draft?', 'fr': 'Supprimer ce brouillon ?'},
 'هل تريد إلغاء هذا المستند؟': {'en': 'Cancel this document?', 'fr': 'Annuler ce document ?'},
 'تم إصدار المستند': {'en': 'Document issued', 'fr': 'Document émis'},
 'تم حفظ المسودة': {'en': 'Draft saved', 'fr': 'Brouillon enregistré'},
 'تم تحديث المسودة': {'en': 'Draft updated', 'fr': 'Brouillon mis à jour'},
 'تم حذف المسودة': {'en': 'Draft deleted', 'fr': 'Brouillon supprimé'},
 'تم إلغاء المستند': {'en': 'Document cancelled', 'fr': 'Document annulé'},
 'تعذر تحميل المستندات': {'en': 'Could not load documents', 'fr': 'Impossible de charger les documents'},
 'لا يوجد مستندات': {'en': 'No documents yet', 'fr': 'Aucun document'},
 'لا توجد مسودات': {'en': 'No drafts yet', 'fr': 'Aucun brouillon'},
 'أنشئ مستندًا جديدًا من الزر أعلاه': {'en': 'Create a new document from the button above', 'fr': 'Créez un nouveau document à partir du bouton ci-dessus'},
 'العميل مطلوب': {'en': 'Customer is required', 'fr': 'Le client est obligatoire'},
 'يجب اختيار عميل': {'en': 'Select a customer', 'fr': 'Sélectionnez un client'},
 'العميل يجب أن يملك ملف B2B': {'en': 'Customer must have a B2B profile', 'fr': 'Le client doit avoir un profil B2B'},
 'يجب إضافة سطر واحد على الأقل قبل الإصدار': {'en': 'Add at least one line before issuing', 'fr': 'Ajoutez au moins une ligne avant l\'émission'},
 'يمكن إصدار المسودة فقط': {'en': 'Only drafts can be issued', 'fr': 'Seuls les brouillons peuvent être émis'},
 'المستند غير موجود': {'en': 'Document not found', 'fr': 'Document introuvable'},
 'لا يمكن تعديل مستند غير مسودة': {'en': 'Only drafts can be modified', 'fr': 'Seuls les brouillons peuvent être modifiés'},
 'لا يمكن إلغاء سوى مستند صادر': {'en': 'Only issued documents can be cancelled', 'fr': 'Seuls les documents émis peuvent être annulés'},
 'فشل حفظ المسودة: ': {'en': 'Failed to save draft: ', 'fr': 'Échec de l\'enregistrement du brouillon : '},
 'فشل تحديث المسودة: ': {'en': 'Failed to update draft: ', 'fr': 'Échec de la mise à jour du brouillon : '},
 'فشل حذف المسودة: ': {'en': 'Failed to delete draft: ', 'fr': 'Échec de la suppression du brouillon : '},
 'فشل إصدار المستند: ': {'en': 'Failed to issue document: ', 'fr': 'Échec de l\'émission du document : '},
 'فشل إلغاء المستند: ': {'en': 'Failed to cancel document: ', 'fr': 'Échec de l\'annulation du document : '},
 'تعذر الإصدار — تعارض في رقم المستند: ': {'en': 'Could not issue — document number conflict: ', 'fr': 'Émission impossible — conflit de numéro de document : '},
 'نوع المستند غير صالح': {'en': 'Invalid document type', 'fr': 'Type de document invalide'},
 'طريقة الدفع غير صالحة': {'en': 'Invalid payment method', 'fr': 'Méthode de paiement invalide'},
 'حالة المستند غير صالحة': {'en': 'Invalid document status', 'fr': 'Statut de document invalide'},
 'الكمية يجب أن تكون أكبر من الصفر': {'en': 'Quantity must be greater than zero', 'fr': 'La quantité doit être supérieure à zéro'},
 'معدل الضريبة غير مدعوم': {'en': 'Unsupported tax rate', 'fr': 'Taux de taxe non pris en charge'},
 'ابحث عن منتج (الاسم أو الباركود)...': {'en': 'Search product (name or barcode)...', 'fr': 'Rechercher un produit (nom ou code-barres)...'},
 'ابحث عن مستند (الرقم أو العميل)...': {'en': 'Search documents (number or customer)...', 'fr': 'Rechercher des documents (n° ou client)...'},
 'ابحث عن عميل B2B (الاسم أو NIF)...': {'en': 'Search B2B customer (name or NIF)...', 'fr': 'Rechercher un client B2B (nom ou NIF)...'},
 'لا يوجد منتج مطابق': {'en': 'No matching product', 'fr': 'Aucun produit correspondant'},
 'لا يوجد عميل B2B': {'en': 'No B2B customer', 'fr': 'Aucun client B2B'},
 'لا توجد أصناف بعد — أضف منتجًا من الأسفل': {'en': 'No items yet — add a product below', 'fr': 'Aucun article pour l\'instant — ajoutez un produit ci-dessous'},
 'اختيار القالب': {'en': 'Choose Template', 'fr': 'Choisir un modèle'},
 'اختر قالبًا للوثائق': {'en': 'Choose a document template', 'fr': 'Choisissez un modèle de document'},
 'كل القوالب تفاعلية وتُظهر نفس المحتوى بشكل مختلف.': {'en': 'All templates are interactive and render the same content differently.', 'fr': 'Tous les modèles sont interactifs et présentent le même contenu différemment.'},
 'القالب': {'en': 'Template', 'fr': 'Modèle'},
 'عدد الأصناف': {'en': 'Number of items', 'fr': 'Nombre d\'articles'},
 'تصدير PDF': {'en': 'Export PDF', 'fr': 'Exporter PDF'},
 'تصدير DOCX': {'en': 'Export DOCX', 'fr': 'Exporter DOCX'},
 'طباعة': {'en': 'Print', 'fr': 'Imprimer'},
 'الشركة': {'en': 'Company', 'fr': 'Société'},
 'نوع الوثيقة': {'en': 'Document type', 'fr': 'Type de document'},
 'رقم الوثيقة': {'en': 'Document number', 'fr': 'Numéro de document'},
 'المبلغ بالحروف': {'en': 'Amount in words', 'fr': 'Montant en lettres'},
 'معاينة': {'en': 'Preview', 'fr': 'Aperçu'},
 # يوم 5 — دفعات وديون وإعدادات B2B
 'تسجيل دفعة': {'en': 'Record Payment', 'fr': 'Enregistrer un paiement'},
 'المدفوع': {'en': 'Paid', 'fr': 'Payé'},
 'المبلغ غير صالح': {'en': 'Invalid amount', 'fr': 'Montant invalide'},
 'ملاحظة': {'en': 'Note', 'fr': 'Note'},
 'اختياري': {'en': 'Optional', 'fr': 'Optionnel'},
 'تسجيل الدفعة': {'en': 'Save Payment', 'fr': 'Enregistrer le paiement'},
 'ديون B2B': {'en': 'B2B Debts', 'fr': 'Dettes B2B'},
 'إجمالي المستحق': {'en': 'Total Receivable', 'fr': 'Total créances'},
 'عدد الفواتير': {'en': 'Invoice count', 'fr': 'Nombre de factures'},
 'متأخرات': {'en': 'Overdue', 'fr': 'En retard'},
 'عدد المتأخرات': {'en': 'Overdue count', 'fr': 'Nombre en retard'},
 'تسجيل الدفعة': {'en': 'Save Payment', 'fr': 'Enregistrer le paiement'},
 'ديون B2B': {'en': 'B2B Debts', 'fr': 'Dettes B2B'},
 'إجمالي المستحق': {'en': 'Total Receivable', 'fr': 'Total créances'},
 'عدد الفواتير': {'en': 'Invoice count', 'fr': 'Nombre de factures'},
 'متأخرات': {'en': 'Overdue', 'fr': 'En retard'},
 'عدد المتأخرات': {'en': 'Overdue count', 'fr': 'Nombre en retard'},
 'بيانات الشركة البائعة': {'en': 'Seller company data', 'fr': "Données de la société vendeuse"},
 'الرقم التجاري RC': {'en': 'Trade register number RC', 'fr': "N° registre du commerce RC"},
 'رقم الأصل AI': {'en': 'AI origin number', 'fr': "N° d'origine AI"},
 'إعدادات B2B': {'en': 'B2B Settings', 'fr': 'Paramètres B2B'},
 'الطابع الجبائي و TVA': {'en': 'Fiscal stamp and TVA', 'fr': 'Timbre fiscal et TVA'},
 'نسبة الطابع (نقدًا) %': {'en': 'Cash stamp rate %', 'fr': "Taux timbre (espèces) %"},
 'نسبة الطابع (غير نقدًا) %': {'en': 'Non-cash stamp rate %', 'fr': "Taux timbre (non-espèces) %"},
 'معدلات TVA المدعومة': {'en': 'Supported TVA rates', 'fr': 'Taux TVA supportés'},
 'إعدادات المستندات الافتراضية': {'en': 'Default document settings', 'fr': 'Paramètres par défaut'},
 'القالب الافتراضي': {'en': 'Default template', 'fr': 'Modèle par défaut'},
 'لغة المستندات': {'en': 'Document language', 'fr': 'Langue des documents'},
 'شعار الشركة': {'en': 'Company logo', 'fr': 'Logo de la société'},
 'لم يُحدد': {'en': 'Not set', 'fr': 'Non défini'},
 'اختيار ملف': {'en': 'Choose file', 'fr': 'Choisir un fichier'},
 'إزالة': {'en': 'Remove', 'fr': 'Supprimer'},
 'تذييل المستندات وإشعار DGI': {'en': 'Document footer and DGI notice', 'fr': 'Pied de page et avis DGI'},
 'نص يظهر أسفل كل مستند B2B (مثال: رقم الحساب الجبائي أو إشعار DGI)': {
   'en': 'Text shown below each B2B document (e.g. tax account number or DGI notice)',
   'fr': "Texte affiché sous chaque document B2B (ex: n° compte fiscal ou avis DGI)"},
'دفعة': {'en': 'Payment', 'fr': 'Paiement'},
 'العربية': {'en': 'Arabic', 'fr': 'Arabe'},
 'لا توجد مستحقات': {'en': 'No receivables', 'fr': 'Aucune créance'},
 # يوم 6 — تحليلات وتصدير ودفعات جماعية
 'تحليلات B2B': {'en': 'B2B Analytics', 'fr': 'Analytique B2B'},
 'المؤشرات والتقارير': {'en': 'Indicators and reports', 'fr': 'Indicateurs et rapports'},
 'المستحق': {'en': 'Receivable', 'fr': 'Créances'},
 'الوثائق حسب النوع': {'en': 'Documents by type', 'fr': 'Documents par type'},
 'الدفعات المسجلة حسب الطريقة': {'en': 'Recorded payments by method', 'fr': 'Paiements par méthode'},
 'الزبائن الأكثر مديونية': {'en': 'Top receivables customers', 'fr': 'Clients les plus endettés'},
 'المستندات الصادرة شهريًا': {'en': 'Monthly issued documents', 'fr': 'Documents émis par mois'},
 'تصدير': {'en': 'Export', 'fr': 'Exporter'},
 'تصدير CSV': {'en': 'Export CSV', 'fr': 'Exporter CSV'},
 'الدفعة الجماعية': {'en': 'Batch payment', 'fr': 'Paiement groupé'},
 'المبلغ الموزع': {'en': 'Allocated amount', 'fr': 'Montant alloué'},
 'المبلغ المتبقي': {'en': 'Remaining amount', 'fr': 'Montant restant'},
 'تعذر فتح تحليلات B2B': {'en': 'Could not open B2B analytics', 'fr': 'Impossible d\'ouvrir l\'analytique B2B'},
 'تعذر تحميل التحليلات': {'en': 'Could not load analytics', 'fr': 'Impossible de charger l\'analytique'},
 'ملفات العملاء': {'en': 'Customer profiles', 'fr': 'Profils clients'},
 'الوثائق': {'en': 'Documents', 'fr': 'Documents'},
 'الدفعات': {'en': 'Payments', 'fr': 'Paiements'},
 'تم تصدير CSV': {'en': 'CSV exported', 'fr': 'CSV exporté'},
 'اختر المكان لحفظ الملف': {'en': 'Choose a location to save the file', 'fr': 'Choisissez un emplacement'},
 'ملف CSV': {'en': 'CSV file', 'fr': 'Fichier CSV'},
 'اسم الملف': {'en': 'File name', 'fr': 'Nom du fichier'},
 'تعذر إنشاء CSV': {'en': 'Could not create CSV', 'fr': 'Impossible de créer le CSV'},
 'أدخل مبلغ الدفعة الجماعية': {'en': 'Enter the batch payment amount', 'fr': 'Entrez le montant du paiement groupé'},
 'تم تسجيل الدفعة الجماعية': {'en': 'Batch payment recorded', 'fr': 'Paiement groupé enregistré'},
 'موزع على': {'en': 'Allocated across', 'fr': 'Alloué sur'},
 'مستندات': {'en': 'documents', 'fr': 'documents'},
 'المستندات المصدرة': {'en': 'Exported documents', 'fr': 'Documents exportés'},
 'الدفعات المصدرة': {'en': 'Exported payments', 'fr': 'Paiements exportés'},
 'المستحقات المصدرة': {'en': 'Exported receivables', 'fr': 'Créances exportées'},
 'الملفات المصدرة': {'en': 'Exported profiles', 'fr': 'Profils exportés'},
 }

    _TRANSLATION_ORDER = sorted(_TRANSLATIONS.items(), key=lambda kv: -len(kv[0]))
    _NOISE_ATOMS = ("دجاج", "دجاجة", "دجاجي")

    def t(self, value):
        """Translate UI text. Dynamic strings are supported through phrase replacement."""
        if value is None or self.language == "ar":
            return value
        text = str(value)
        exact = self._TRANSLATIONS.get(text)
        if exact:
            return exact.get(self.language, text)
        guards = {}
        for atom in sorted(self._NOISE_ATOMS, key=len, reverse=True):
            if atom in text:
                token = "\uE000" + str(len(guards)) + "\uE001"
                text = text.replace(atom, token)
                guards[token] = atom
        # Translate known Arabic fragments inside dynamic f-strings. Longest phrases
        # first, so shorter keys (e.g. 'فاتورة') never corrupt longer compounds.
        for ar, langs in self._TRANSLATION_ORDER:
            if ar and ar in text and self.language in langs:
                text = text.replace(ar, langs[self.language])
        for token, atom in guards.items():
            text = text.replace(token, atom)
        return text

    def _to_ar(self, value):
        """Reverse-map a (possibly translated) dropdown value back to canonical Arabic.

        Combos/OptionMenus carry data (unit, category, day, expense category) whose
        display is translated but whose stored/comparison form must stay Arabic.
        Canonical unit atoms win first (e.g. 'kg' -> كغ, not كيلوغرام); otherwise
        the longest Arabic key wins (so 'Uncategorized' -> بدون تصنيف, not غير مصنّف).
        """
        if value is None or self.language == "ar":
            return value
        text = str(value)
        reverse = getattr(self, "_REVERSE_MAP", None)
        if reverse is None:
            reverse = {}
            for ar in ("قطعة", "كغ", "غرام", "لتر", "متر", "مل"):
                for ln, tv in self._TRANSLATIONS.get(ar, {}).items():
                    if tv and tv not in reverse:
                        reverse[tv] = ar
            for ar, langs in self._TRANSLATION_ORDER:
                for ln, tv in langs.items():
                    if tv and tv not in reverse:
                        reverse[tv] = ar
            self._REVERSE_MAP = reverse
        return reverse.get(text, text)

    def _translate_visible_widgets(self, parent=None):
        """Translate all currently visible widget text, including hard-coded Arabic labels."""
        if parent is None:
            parent = self
        try:
            children = parent.winfo_children()
        except Exception:
            return
        try:
            win_title = parent.title()
            if isinstance(win_title, str) and win_title:
                translated = self.t(win_title)
                if translated != win_title:
                    parent.title(translated)
        except Exception:
            pass
        for widget in children:
            try:
                # Labels, buttons, radio/check buttons and other CTk widgets with text.
                if hasattr(widget, "cget") and hasattr(widget, "configure"):
                    try:
                        value = widget.cget("text")
                        if isinstance(value, str) and value:
                            translated = self.t(value)
                            if translated != value:
                                widget.configure(text=translated)
                    except Exception:
                        pass
                    # Entry / textbox placeholder text.
                    try:
                        value = widget.cget("placeholder_text")
                        if isinstance(value, str) and value:
                            translated = self.t(value)
                            if translated != value:
                                widget.configure(placeholder_text=translated)
                    except Exception:
                        pass
                    # OptionMenu / ComboBox values.
                    for option_key in ("values",):
                        try:
                            values = widget.cget(option_key)
                            if isinstance(values, (tuple, list)):
                                translated_values = [self.t(v) if isinstance(v, str) else v for v in values]
                                if list(values) != translated_values:
                                    widget.configure(values=translated_values)
                        except Exception:
                            pass
            except Exception:
                pass
            self._translate_visible_widgets(widget)

    def _set_language(self, language, save=True):
        """Change language and rebuild the complete UI immediately."""
        language = str(language).lower().strip()
        if language not in ("ar", "fr", "en"):
            language = "ar"
        current_page = getattr(self, "current_page", "dashboard")
        self.language = language
        if save and hasattr(self, "settings"):
            self.settings["language"] = language
            self.save_app_settings()
        try:
            if hasattr(self, "main_container") and self.main_container.winfo_exists():
                self.main_container.destroy()
        except Exception:
            pass
        self.title(self.t("Supermarket Pro • إدارة المتجر"))
        self.setup_ui()
        self.current_page = current_page
        self.refresh_current_page()
        self._translate_visible_widgets()
        try:
            if current_page == "pos" and hasattr(self, "pos_search"):
                self.pos_search.focus_set()
        except Exception:
            pass

    def refresh_current_page(self):
        page = getattr(self, "current_page", "dashboard")
        pages = {
            "dashboard": self.show_dashboard,
            "products": self.show_products,
            "inventory": self.show_inventory,
            "packs": self.show_packs,
            "pos": self.show_pos,
            "customers": self.show_customers,
            "b2b": self.show_b2b,
            "b2b_documents": self.show_b2b_documents,
            "b2b_debts": self.show_b2b_debts,
            "b2b_analytics": self.show_b2b_analytics,
            "b2b_settings": self.show_b2b_settings,
            "suppliers": self.show_suppliers,
            "purchases": self.show_purchases,
            "reports": self.show_reports,
            "expenses": self.show_expenses,
            "settings": self.show_settings,
        }
        fn = pages.get(page, self.show_dashboard)
        fn()

    def language_name(self, code):
        return {"ar": "العربية", "fr": "Français", "en": "English"}.get(code, code)

    # =========================================================
    # Theme / Colors
    # =========================================================

    def bg(self):
        if getattr(self, "is_grey", False):
            return self.colors["grey_bg"]
        return self.colors["dark_bg"] if self.is_dark else self.colors["light_bg"]

    def card(self):
        if getattr(self, "is_grey", False):
            return self.colors["grey_card"]
        return self.colors["dark_card"] if self.is_dark else self.colors["light_card"]

    def text(self):
        if getattr(self, "is_grey", False):
            return self.colors["grey_text"]
        return self.colors["dark_text"] if self.is_dark else self.colors["light_text"]

    def muted(self):
        if getattr(self, "is_grey", False):
            return self.colors["grey_muted"]
        return self.colors["dark_muted"] if self.is_dark else self.colors["light_muted"]

    def border(self):
        if getattr(self, "is_grey", False):
            return self.colors["grey_border"]
        return self.colors["dark_border"] if self.is_dark else self.colors["light_border"]

    def setup_ui(self):
        self.main_container = ctk.CTkFrame(self, fg_color=self.bg(), corner_radius=0)
        self.main_container.pack(fill="both", expand=True)

        self.create_top_bar()

        body = ctk.CTkFrame(
            self.main_container,
            fg_color="transparent",
            corner_radius=0
        )
        body.pack(fill="both", expand=True, padx=18, pady=(8, 18))

        self.create_sidebar(body)

        self.content_area = ctk.CTkFrame(
            body,
            fg_color="transparent",
            corner_radius=0
        )
        self.content_area.pack(
            side="right",
            fill="both",
            expand=True,
            padx=(14, 0)
        )

    def _apply_maximized(self):
        """فتح النافذة الرئيسية بحجم أقصى (يملأ الشاشة مع شريط عنوان قابل
        للتصغير والتحريك) — لا وضع ملء الشاشة/كشك. يحترم minsize عند فك
        التكبير. يُعاد تطبيقه بعد أي إعادة إنشاء للنافذة عند بدء التشغيل."""
        try:
            self.state("zoomed")
        except Exception:
            try:
                self.attributes("-zoomed", True)
            except Exception:
                pass

    def refresh_theme(self):
        """تحديث الألوان دون تغيير منطق البرنامج."""
        self.main_container.configure(fg_color=self.bg())

        if hasattr(self, "top_bar"):
            self.top_bar.configure(fg_color=self.bg())

        if hasattr(self, "sidebar"):
            self.sidebar.configure(fg_color=self.card())

        if hasattr(self, "sidebar_toggle"):
            self.sidebar_toggle.configure(
                fg_color=self.card(),
                hover_color=self.border(),
                text_color=self.text()
            )

        if hasattr(self, "theme_button"):
            self.theme_button.configure(
                fg_color=self.card(),
                hover_color=self.border(),
                text_color=self.text()
            )

        if hasattr(self, "user_button"):
            self.user_button.configure(
                fg_color=self.card(),
                hover_color=self.border(),
                text_color=self.text()
            )

        if hasattr(self, "conn_status_label"):
            up = getattr(self, "_conn_last_up", None)
            color = (
                (self.colors["secondary"] if up else self.colors["danger"])
                if up is not None else self.muted()
            )
            try:
                self.conn_status_label.configure(text_color=color)
            except Exception:
                pass

        if hasattr(self, "time_label"):
            self.time_label.configure(text_color=self.text())

        if hasattr(self, "date_label"):
            self.date_label.configure(text_color=self.muted())

        # إعادة رسم الصفحة الحالية لتوحيد الألوان
        page = self.current_page
        if page == "dashboard":
            self.show_dashboard()
        elif page == "products":
            self.show_products()
        elif page == "pos":
            self.show_pos(preserve_cart=True)
        elif page == "customers":
            self.show_customers()
        elif page == "reports":
            self.show_reports()
        elif page == "profit":
            self.show_profit_report()
        elif page == "settings":
            self.show_settings()

    def _set_theme_mode(self, mode, save=True):
        mode = str(mode).lower().strip()
        if mode not in ("light", "dark", "grey"):
            mode = "dark"

        self.theme_mode = mode
        self.is_dark = mode == "dark"
        self.is_grey = mode == "grey"

        # CTk has only light/dark. Grey is our neutral dark-grey palette.
        ctk.set_appearance_mode("light" if mode == "light" else "dark")

        if save and hasattr(self, "settings"):
            self.settings["theme_mode"] = mode
            self.settings["appearance"] = mode
            self.save_app_settings()

        self.refresh_theme()

    def toggle_theme(self):
        if self.theme_mode == "dark":
            self._set_theme_mode("light")
        elif self.theme_mode == "light":
            self._set_theme_mode("grey")
        else:
            self._set_theme_mode("dark")

    def set_dark_theme(self):
        self._set_theme_mode("dark")

    def set_light_theme(self):
        self._set_theme_mode("light")

    def set_grey_theme(self):
        self._set_theme_mode("grey")

    # =========================================================
    # Top Bar
    # =========================================================
    # Top Bar
    # =========================================================

    def create_top_bar(self):
        self.top_bar = ctk.CTkFrame(
            self.main_container,
            height=68,
            fg_color=self.bg(),
            corner_radius=0
        )
        self.top_bar.pack(fill="x", padx=22, pady=(12, 0))
        self.top_bar.pack_propagate(False)

        left = ctk.CTkFrame(self.top_bar, fg_color="transparent")
        left.pack(side="left", fill="y")

        self.sidebar_toggle = ctk.CTkButton(
            left,
            text="☰",
            width=42,
            height=40,
            corner_radius=10,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=18, weight="bold"),
            command=self.toggle_sidebar
        )
        self.sidebar_toggle.pack(side="left", padx=(0, 10), pady=12)

        ctk.CTkLabel(
            left,
            text="◈",
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family,size=26, weight="bold")
        ).pack(side="left")

        brand = ctk.CTkFrame(left, fg_color="transparent")
        brand.pack(side="left", padx=8)

        ctk.CTkLabel(
            brand,
            text=self.t("سوبرماركت برو"),
            font=ctk.CTkFont(family=self.ui_font_family,size=20, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w")

        ctk.CTkLabel(
            brand,
            text=self.t("نظام إدارة المتجر"),
            font=ctk.CTkFont(family=self.ui_font_family,size=11),
            text_color=self.muted()
        ).pack(anchor="w")

        right = ctk.CTkFrame(self.top_bar, fg_color="transparent")
        right.pack(side="right", fill="y")

        self.notification_button = ctk.CTkButton(
            right,
            text="●",
            width=40,
            height=40,
            corner_radius=10,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=17),
            command=self.show_notifications
        )
        self.notification_button.pack(side="right", padx=4, pady=12)

        self.theme_button = ctk.CTkButton(
            right,
            text="☼" if self.is_dark else "☾",
            width=40,
            height=40,
            corner_radius=10,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=17),
            command=self.toggle_theme
        )
        self.theme_button.pack(side="right", padx=4, pady=12)

        # زر المستخدم الحالي / تسجيل الدخول وتبديل الورديات.
        current = getattr(self, "current_user", None)
        self.user_button = ctk.CTkButton(
            right,
            text=(f"👤 {str(current.get('name') or '')}" if current else self.t("👤 تسجيل الدخول")),
            width=125,
            height=40,
            corner_radius=10,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            anchor="center",
            font=ctk.CTkFont(family=self.ui_font_family,size=11),
            command=self._open_user_session_menu
        )
        self.user_button.pack(side="right", padx=4, pady=12)

        clock = ctk.CTkFrame(right, fg_color="transparent")
        clock.pack(side="right", padx=14)

        self.time_label = ctk.CTkLabel(
            clock,
            text=datetime.now().strftime("%H:%M"),
            font=ctk.CTkFont(family=self.ui_font_family,size=17, weight="bold"),
            text_color=self.text()
        )
        self.time_label.pack(anchor="e")

        self.date_label = ctk.CTkLabel(
            clock,
            text=datetime.now().strftime("%d/%m/%Y"),
            font=ctk.CTkFont(family=self.ui_font_family,size=11),
            text_color=self.muted()
        )
        self.date_label.pack(anchor="e")

        # مؤشر حالة الاتصال بقاعدة البيانات/الخادم.
        up = self._conn_state_box.get("up")
        status_text = "● " + (self.t("متصل") if up else self.t("غير متصل بالخادم"))
        status_color = (
            (self.colors["secondary"] if up else self.colors["danger"])
            if up is not None else self.muted()
        )
        self.conn_status_label = ctk.CTkLabel(
            right,
            text=status_text,
            text_color=status_color,
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        )
        self.conn_status_label.pack(side="right", padx=(2, 10), pady=12)

    # =========================================================
    # Sidebar
    # =========================================================

    def create_sidebar(self, parent):
        self.sidebar = ctk.CTkFrame(
            parent, width=205, fg_color=self.card(), corner_radius=16,
            border_width=1, border_color=self.border()
        )
        self.sidebar.pack(side="left", fill="y")
        self.sidebar.pack_propagate(False)

        header = ctk.CTkFrame(self.sidebar, fg_color="transparent", height=64)
        header.pack(fill="x", padx=12, pady=(12, 4))
        header.pack_propagate(False)
        ctk.CTkLabel(header, text="◈", font=ctk.CTkFont(family=self.ui_font_family,size=25, weight="bold"),
                     text_color=self.colors["primary"]).pack(side="left", padx=(4,8))
        brand = ctk.CTkFrame(header, fg_color="transparent")
        brand.pack(side="left")
        ctk.CTkLabel(brand, text=self.t("Supermarket Pro"), font=ctk.CTkFont(family=self.ui_font_family,size=13, weight="bold"),
                     text_color=self.text()).pack(anchor="w")
        ctk.CTkLabel(brand, text=self.t("إدارة المتجر"), font=ctk.CTkFont(family=self.ui_font_family,size=10),
                     text_color=self.muted()).pack(anchor="w")

        self.nav_buttons=[]
        items=[
            ("⌂",self.t("لوحة التحكم"),"dashboard",self.show_dashboard),
            ("▣",self.t("المنتجات"),"products",self.show_products),
            ("📦",self.t("المخزون"),"inventory",self.show_inventory),
            ("🎁",self.t("الباقات"),"packs",self.show_packs),
            ("▤",self.t("نقطة البيع"),"pos",self.show_pos),
            ("♙",self.t("الزبائن"),"customers",self.show_customers),
            ("🚚",self.t("الموردون"),"suppliers",self.show_suppliers),
            ("🛒",self.t("المشتريات"),"purchases",self.show_purchases),
            ("🏢",self.t("B2B"),"b2b",self.show_b2b),
            ("🧾",self.t("مستندات B2B"),"b2b_documents",self.show_b2b_documents),
            ("💰",self.t("ديون B2B"),"b2b_debts",self.show_b2b_debts),
            ("📊",self.t("تحليلات B2B"),"b2b_analytics",self.show_b2b_analytics),
            ("🛠",self.t("إعدادات B2B"),"b2b_settings",self.show_b2b_settings),
            ("◫",self.t("التقارير"),"reports",self.show_reports),
            ("💸",self.t("المصاريف والفواتير"),"expenses",self.show_expenses),
            ("⚙",self.t("الإعدادات"),"settings",self.show_settings),
        ]
        for icon,title,page_key,command in items:
            button=ctk.CTkButton(
                self.sidebar, text=f"{icon}   {title}", command=command,
                height=47, corner_radius=10, fg_color="transparent",
                hover_color=self.border(), text_color=self.muted(), anchor="w",
                font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
            )
            button.pack(fill="x", padx=9, pady=3)
            self.nav_buttons.append((button,icon,title,page_key))

        ctk.CTkFrame(self.sidebar,height=1,fg_color=self.border()).pack(fill="x",padx=14,pady=14)

        shortcuts_text = (
            f"F1  {self.t('نقطة البيع')}\n"
            f"F4  {self.t('البحث')}\n"
            f"F6  {self.t('العميل')}\n"
            f"F8  {self.t('الدفع')}\n"
            f"F9  {self.t('تعليق')}\n"
            f"F12 {self.t('مسح السلة')}"
        )
        self.sidebar_shortcuts = ctk.CTkLabel(
            self.sidebar,
            text=shortcuts_text,
            justify="left", anchor="w", font=ctk.CTkFont(family=self.ui_font_family,size=10), text_color=self.muted()
        )
        self.sidebar_shortcuts.pack(fill="x",padx=16)

        spacer=ctk.CTkFrame(self.sidebar,fg_color="transparent")
        spacer.pack(fill="both",expand=True)

        self.sidebar_status=ctk.CTkFrame(self.sidebar,fg_color=self.bg(),corner_radius=10)
        self.sidebar_status.pack(fill="x", padx=10, pady=(6,8))
        ctk.CTkLabel(self.sidebar_status,text=self.t("● النظام يعمل"),font=ctk.CTkFont(family=self.ui_font_family,size=10,weight="bold"),
                     text_color=self.colors["secondary"]).pack(anchor="w",padx=10,pady=(8,1))
        ctk.CTkLabel(self.sidebar_status,text=self.t("جاهز لاستقبال المبيعات"),font=ctk.CTkFont(family=self.ui_font_family,size=9),
                     text_color=self.muted()).pack(anchor="w",padx=10,pady=(0,8))

        ctk.CTkButton(
            self.sidebar,text=self.t("→  خروج"),command=self.quit_app,height=40,corner_radius=10,
            fg_color="transparent",hover_color=self.border(),text_color=self.colors["danger"],
            anchor="w",font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold")
        ).pack(fill="x",padx=9,pady=(2,10))


    def toggle_sidebar(self):
        self.sidebar_collapsed = not self.sidebar_collapsed

        if self.sidebar_collapsed:
            self.sidebar.configure(width=76)
            for button, icon, title, page_key in self.nav_buttons:
                button.configure(text=icon, anchor="center")
        else:
            self.sidebar.configure(width=205)
            for button, icon, title, page_key in self.nav_buttons:
                button.configure(text=f"{icon}   {title}", anchor="w")

    def highlight_nav(self, target_key=None):
        """تمييز زر الصفحة الحالية حسب مفتاح ثابت (لا يعتمد على النص المترجم)."""
        page = str(target_key or getattr(self, "current_page", "")).strip().lower()
        # شاشات فرعية قديمة لا تملك زرًا في الشريط الجانبي: نتعدى لصفحتها الأم.
        fallback = {"profit": "dashboard"}
        page = fallback.get(page, page)
        for item in getattr(self, "nav_buttons", []):
            btn = item[0]
            btn_key = str(item[3]).strip().lower() if len(item) >= 4 else ""
            if btn_key == page:
                btn.configure(
                    fg_color=self.colors["primary"],
                    hover_color=self.colors["primary_hover"],
                    text_color="white"
                )
            else:
                btn.configure(
                    fg_color="transparent",
                    hover_color=self.border(),
                    text_color=self.muted()
                )

    # =========================================================
    # Helpers
    # =========================================================

    def clear_content(self):
        for widget in self.content_area.winfo_children():
            widget.destroy()

    def page_header(self, title, subtitle=""):
        title = self.t(title)
        subtitle = self.t(subtitle)
        frame = ctk.CTkFrame(
            self.content_area,
            fg_color="transparent"
        )
        frame.pack(fill="x", pady=(0, 15))

        ctk.CTkLabel(
            frame,
            text=title,
            font=ctk.CTkFont(family="Segoe UI", size=28, weight="bold"),
            text_color=self.text()
        ).pack(side="left")

        if subtitle:
            ctk.CTkLabel(
                frame,
                text=subtitle,
                font=ctk.CTkFont(family=self.ui_font_family,size=12),
                text_color=self.muted()
            ).pack(side="right", pady=8)

        return frame

    def make_card(self, parent, **kwargs):
        options = {
            "fg_color": self.card(),
            "corner_radius": 18,
            "border_width": 1,
            "border_color": self.border()
        }
        options.update(kwargs)
        return ctk.CTkFrame(parent, **options)

    def toast(self, message, kind="success"):
        """إشعار صغير غير مزعج."""
        message = self.t(message)
        colors = {
            "success": self.colors["secondary"],
            "danger": self.colors["danger"],
            "warning": self.colors["accent"],
            "info": self.colors["info"],
        }
        toast = ctk.CTkFrame(
            self,
            fg_color=colors.get(kind, self.colors["info"]),
            corner_radius=10
        )

        ctk.CTkLabel(
            toast,
            text=message,
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
        ).pack(padx=18, pady=11)

        toast.place(relx=0.5, rely=0.93, anchor="center")
        self.after(2400, toast.destroy)

    def confirm(self, title, message):
        return messagebox.askyesno(self.t(title), self.t(message), parent=self)

    def show_message(self, title, message, kind="info"):
        """نافذة رسالة مشروطة (عنوان + نص) بلون حسب النوع — الواجهة الموحّدة
        لرسائل «تم / خطأ / تحذير / نجاح» عبر الأقسام (المخزون، الجرد، التصدير…).
        شبيهة بـ toast لكنها نافذة حقيقية مزعجة بعنوان، ولا تختفي تلقائيًا."""
        title = self.t(title)
        message = self.t(message)
        colors = {
            "success": self.colors["secondary"],
            "danger": self.colors["danger"],
            "warning": self.colors["accent"],
            "info": self.colors["info"],
        }
        accent = colors.get(kind if kind != "error" else "danger", self.colors["info"])
        win = ctk.CTkToplevel(self)
        win.title(title)
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 460, 250)

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=16, pady=16)

        ctk.CTkFrame(card, fg_color=accent, height=5, corner_radius=0).pack(fill="x")

        ctk.CTkLabel(
            card, text=title, text_color=accent, anchor="center",
            font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold")
        ).pack(pady=(16, 2))

        ctk.CTkLabel(
            card, text=message, text_color=self.text(), anchor="center",
            justify="center", wraplength=400,
            font=ctk.CTkFont(family=self.ui_font_family, size=12)
        ).pack(pady=(4, 14), padx=16)

        ctk.CTkButton(
            card, text=self.t("موافق"), command=win.destroy, height=38, corner_radius=9,
            fg_color=accent, hover_color=accent, text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(pady=(0, 16))

    @property
    def _db_ready(self):
        """هل اكتمل بناء طبقة البيانات (المدراء + اتصال)؟
        تُنشأ المدراء فقط بعد اختيار وضع الشبكة وتحقيق اتصال يعمل، لذلك قبل
        ذلك يجب ألا تلمس أي شاشة المدراء/الـ db — تُعرض حالة «غير متصل» بدلًا
        من رمي AttributeError أو تعليق الخيط الرئيسي بمحاولات اتصال."""
        return bool(getattr(self, "_data_ready", False)) and hasattr(self, "db")

    def _render_offline(self, title, subtitle, page_key):
        """شاشة هادئة آمنة تُعرض عندما تكون طبقة البيانات غير جاهزة/غير متصلة
        (بدون أي لمس لقاعدة البيانات) — فلا تجمّد الواجهة ولا تُسقطها."""
        try:
            self.clear_content()
            self.current_page = page_key
            self.highlight_nav()
            self.page_header(self.t(title), self.t(subtitle))
            card = self.make_card(self.content_area, width=560)
            card.pack(pady=40)
            ctk.CTkLabel(
                card, text="🔌 " + self.t("غير متصل بقاعدة البيانات"),
                font=ctk.CTkFont(family=self.ui_font_family, size=19, weight="bold"),
                text_color=self.colors["danger"]
            ).pack(pady=(26, 6))
            ctk.CTkLabel(
                card,
                text=self.t("يرجى الانتظار أو التحقق من الاتصال بالخادم."),
                font=ctk.CTkFont(family=self.ui_font_family, size=12),
                text_color=self.muted()
            ).pack(pady=(0, 6), padx=30)
            ctk.CTkLabel(
                card,
                text=self.t("سيعاد الاتصال تلقائيًا عند توفر الخادم."),
                font=ctk.CTkFont(family=self.ui_font_family, size=10),
                text_color=self.text()
            ).pack(pady=(0, 20), padx=30)
        except Exception:
            pass

    def _guard_db_nav(self, title, subtitle, page_key):
        """حارس موحّد لصفحات التنقل التي تعتمد على قاعدة البيانات.
        يعيد True إن كانت البيانات جاهزة (فيُتابع بناء الصفحة)، أو يعرض
        شاشة «غير متصل» ويعيد False دون لمس أي مُدرِج/db (لا AttributeError
        ولا تعليق خيط الواجهة بمحاولات اتصال)."""
        if not self._db_ready:
            self._render_offline(title, subtitle, page_key)
            return False
        return True

    def update_clock(self):
        now = datetime.now()
        try:
            self.time_label.configure(text=now.strftime("%H:%M"))
            self.date_label.configure(text=now.strftime("%d/%m/%Y"))
        except Exception:
            pass
        self.after(30000, self.update_clock)

    def bind_shortcuts(self):
        # Main Nav & Focus
        self.bind("<F1>", lambda e: self.show_pos())
        self.bind("<F2>", lambda e: self.show_products())
        self.bind("<F3>", lambda e: self.show_add_product_form())
        self.bind("<F5>", lambda e: self.refresh_current_page())

        # POS Workflow Actions
        self.bind("<F6>", lambda e: self.open_customer_select() if self.current_page == "pos" else None)
        self.bind("<F7>", lambda e: self._open_discount_modal() if self.current_page == "pos" else None)
        self.bind("<F8>", lambda e: self.complete_sale() if self.current_page == "pos" else None)
        self.bind("<F9>", lambda e: self.hold_current_sale() if self.current_page == "pos" else None)
        self.bind("<F10>", lambda e: self.show_held_carts_modal() if self.current_page == "pos" else None)
        self.bind("<F12>", lambda e: self.clear_cart() if self.current_page == "pos" else None)

        # Dialogs & Navigation
        self.bind_all("<Escape>", lambda e: self.close_top_window())
        self.bind_all("<F4>", lambda e: self.focus_current_search())
        self.bind("<Control-n>", lambda e: self.show_add_product_form())
        self.bind("<Control-f>", lambda e: self.focus_current_search())

    def open_customer_select(self):
        return self.select_customer()

    def _open_discount_modal(self):
        return self.edit_sale_discount()

    def show_held_carts_modal(self):
        return self.restore_held_sale()

    def _focus_if_alive(self, widget, force=False, icursor=None):
        """منح التركيز لاحقًا عبر after() دون رمي TclError إذا كان الويدجت
        قد أُتلف قبل انتهاء المهلة (bad window path name)."""
        try:
            if widget is None or not widget.winfo_exists():
                return
            if force:
                widget.focus_force()
            else:
                widget.focus_set()
            if icursor:
                widget.icursor(icursor)
        except Exception:
            pass

    def focus_current_search(self):
        try:
            page = self.current_page
            if page == "pos" and hasattr(self, "pos_search") and self.pos_search.winfo_exists():
                self.pos_search.focus_set()
                self.pos_search.select_range(0, "end")
            elif page == "products" and hasattr(self, "search_entry") and self.search_entry.winfo_exists():
                self.search_entry.focus_set()
                self.search_entry.select_range(0, "end")
            elif page == "inventory" and hasattr(self, "inventory_search") and self.inventory_search.winfo_exists():
                self.inventory_search.focus_set()
                self.inventory_search.select_range(0, "end")
            elif page == "customers" and hasattr(self, "customer_search") and self.customer_search.winfo_exists():
                self.customer_search.focus_set()
                self.customer_search.select_range(0, "end")
        except Exception:
            pass
        return "break"

    def close_top_window(self):
        try:
            windows = [
                w for w in self.winfo_children()
                if isinstance(w, (ctk.CTkToplevel, tk.Toplevel)) and w.winfo_exists()
            ]
            if windows:
                windows[-1].destroy()
                return "break"
            if self.current_page == "pos" and hasattr(self, "pos_search") and self.focus_get() == self.pos_search:
                self.pos_search.delete(0, "end")
                self.focus_set()
                return "break"
        except Exception:
            pass

    def check_notifications(self):
        try:
            if self._db_ready:
                low_stock = self.reports_manager.get_low_stock_products(5)
                text = f"● {len(low_stock)}" if low_stock else "●"
            else:
                text = "●"
            self.notification_button.configure(text=text)
        except Exception:
            try:
                self.notification_button.configure(text="●")
            except Exception:
                return
        try:
            self.after(300000, self.check_notifications)
        except Exception:
            pass

    def show_notifications(self):
        try:
            low_stock = self.reports_manager.get_low_stock_products(10)
        except Exception:
            low_stock = []

        win = ctk.CTkToplevel(self)
        win.title(self.t("● التنبيهات"))
        win.geometry("430x420")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=15, pady=15)

        ctk.CTkLabel(
            container,
            text=self.t("● التنبيهات"),
            font=ctk.CTkFont(family=self.ui_font_family,size=21, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", pady=(5, 15))

        if not low_stock:
            ctk.CTkLabel(
                container,
                text=self.t("✓ لا توجد تنبيهات مهمة حاليًا"),
                font=ctk.CTkFont(family=self.ui_font_family,size=14, weight="bold"),
                text_color=self.colors["secondary"]
            ).pack(pady=40)
            return

        scroll = ctk.CTkScrollableFrame(
            container,
            fg_color="transparent"
        )
        scroll.pack(fill="both", expand=True)

        for p in low_stock:
            row = self.make_card(scroll)
            row.pack(fill="x", pady=4)

            name = p[1] if len(p) > 1 else self.t("منتج")
            qty = p[2] if len(p) > 2 else 0
            unit = p[3] if len(p) > 3 else "قطعة"

            ctk.CTkLabel(
                row,
                text=f"!  {name}",
                font=ctk.CTkFont(family=self.ui_font_family,size=13, weight="bold"),
                text_color=self.text()
            ).pack(side="left", padx=12, pady=10)

            ctk.CTkLabel(
                row,
                text=f"{self._format_quantity(qty, unit)} {unit}",
                font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold"),
                text_color=self.colors["danger"]
            ).pack(side="right", padx=12)

    def _ensure_returns_schema(self):
        """تهيئة جداول المرتجعات مع دعم device_name."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("""CREATE TABLE IF NOT EXISTS returns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                invoice_number TEXT NOT NULL,
                sale_id INTEGER,
                customer_id INTEGER,
                total_amount REAL NOT NULL DEFAULT 0,
                device_name VARCHAR(100) DEFAULT 'Main',
                return_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                note TEXT DEFAULT ''
            )""")
            conn.execute("""CREATE TABLE IF NOT EXISTS return_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                return_id INTEGER NOT NULL,
                product_id INTEGER NOT NULL,
                quantity REAL NOT NULL DEFAULT 0,
                price REAL NOT NULL DEFAULT 0,
                total REAL NOT NULL DEFAULT 0
            )""")
            cols = [r[1] for r in conn.execute("PRAGMA table_info(returns)").fetchall()]
            if cols and "device_name" not in cols:
                conn.execute("ALTER TABLE returns ADD COLUMN device_name VARCHAR(100) DEFAULT 'Main'")
            conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    # =========================================================
    # Audit Log / Categories / Users & PIN — schema + helpers
    # =========================================================

    def _ensure_audit_schema(self):
        """تهيئة جدول سجل النشاطات."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("""CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                username TEXT DEFAULT 'system',
                action TEXT NOT NULL,
                entity_type TEXT DEFAULT '',
                entity_id INTEGER,
                details TEXT DEFAULT '',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
            conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    def _ensure_categories_schema(self):
        """تهيئة جدول التصنيفات وعمود category_id في المنتجات."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("""CREATE TABLE IF NOT EXISTS categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
            cols = [r[1] for r in conn.execute("PRAGMA table_info(products)").fetchall()]
            if cols and "category_id" not in cols:
                conn.execute("ALTER TABLE products ADD COLUMN category_id INTEGER")
            row = conn.execute("SELECT COUNT(*) FROM categories").fetchone()
            if not row or int(row[0] or 0) == 0:
                conn.execute("INSERT OR IGNORE INTO categories (name) VALUES (?)", ("عام",))
            conn.commit()
        except Exception:
            try:
                if conn: conn.rollback()
            except Exception:
                pass
        finally:
            if conn: conn.close()

    def _ensure_users_schema(self):
        """تهيئة جدول المستخدمين لحماية الإجراءات الحساسة برمز PIN."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("""CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                pin_hash TEXT NOT NULL,
                salt TEXT DEFAULT '',
                role TEXT DEFAULT 'cashier' CHECK (role IN ('admin','cashier')),
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
            conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    def _ensure_item_discount_schema(self):
        """تهيئة عمود خصم المنتج في عناصر الفاتورة."""
        conn = None
        try:
            conn = self.db.get_connection()
            cols = [r[1] for r in conn.execute("PRAGMA table_info(sale_items)").fetchall()]
            if cols and "item_discount" not in cols:
                conn.execute("ALTER TABLE sale_items ADD COLUMN item_discount REAL DEFAULT 0")
                conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    def _ensure_packs_schema(self):
        """تهيئة جداول الباقات (المجموعات) وعمود pack_id في عناصر الفاتورة."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("""CREATE TABLE IF NOT EXISTS packs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                price REAL NOT NULL DEFAULT 0,
                image_path TEXT NULL,
                is_active BOOLEAN NOT NULL DEFAULT 1,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
            conn.execute("""CREATE TABLE IF NOT EXISTS pack_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pack_id INTEGER NOT NULL,
                product_id INTEGER NOT NULL,
                quantity REAL NOT NULL DEFAULT 1
            )""")
            cols = []
            try:
                cols = [r[1] for r in conn.execute("PRAGMA table_info(sale_items)").fetchall()]
            except Exception:
                pass
            if cols and "pack_id" not in cols:
                conn.execute("ALTER TABLE sale_items ADD COLUMN pack_id INTEGER")
            conn.commit()
        except Exception:
            try:
                if conn: conn.rollback()
            except Exception:
                pass
        finally:
            if conn: conn.close()

    def _ensure_favorites_schema(self):
        """تهيئة جداول المفضّلة وتحديث المفضّلة التلقائية (الأكثر مبيعًا)
        مرة واحدة عند بدء الجلسة — المفضّلة اليدوية لا تتأثر أبدًا."""
        try:
            fm = self.favorites_manager
            fm.ensure_table()
            if not getattr(self, "_auto_favorites_primed", False):
                fm.refresh_auto_favorites()
                self._auto_favorites_primed = True
        except Exception:
            pass

    def log_action(self, action, entity_type=None, entity_id=None, details=""):
        """تسجيل عملية في سجل النشاطات؛ لا يُفشل العملية الأصلية أبداً."""
        conn = None
        try:
            user = getattr(self, "current_user", None) or {}
            username = str(user.get("name") or "system") if isinstance(user, dict) else "system"
            user_id = user.get("id") if isinstance(user, dict) else None
            conn = self.db.get_connection()
            conn.execute(
                """INSERT INTO audit_log (user_id, username, action, entity_type, entity_id, details)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (user_id, username, str(action or ""), str(entity_type or ""), entity_id, str(details or ""))
            )
            conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    @staticmethod
    def _hash_pin(pin, salt):
        """تشفير رمز PIN باستخدام SHA-256 مع ملح عشوائي لكل مستخدم."""
        digest = hashlib.sha256(f"{salt}:{pin}".encode("utf-8")).hexdigest()
        return f"{salt}${digest}"

    def _verify_pin_hash(self, pin_hash, pin):
        try:
            salt = str(pin_hash).split("$", 1)[0]
            return secrets.compare_digest(self._hash_pin(pin, salt), str(pin_hash))
        except Exception:
            return False

    def _get_users(self):
        conn = None
        try:
            conn = self.db.get_connection()
            return conn.execute(
                "SELECT id, name, pin_hash, role FROM users ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, name"
            ).fetchall()
        except Exception:
            return []
        finally:
            if conn: conn.close()

    def _create_user(self, name, pin, role):
        salt = secrets.token_hex(16)
        pin_hash = self._hash_pin(pin, salt)
        conn = None
        try:
            conn = self.db.get_connection()
            cur = conn.execute(
                "INSERT INTO users (name, pin_hash, salt, role) VALUES (?, ?, ?, ?)",
                (name, pin_hash, salt, role)
            )
            conn.commit()
            return True, cur.lastrowid
        except Exception:
            return False, None
        finally:
            if conn: conn.close()

    def _check_pin_credentials(self, pin, required_role="admin"):
        pin = str(pin or "").strip()
        if not pin:
            return False
        users = self._get_users()
        if required_role == "admin":
            candidates = [u for u in users if u[3] == "admin"]
        else:
            candidates = list(users)
        for _uid, _name, pin_hash, _role in candidates:
            if self._verify_pin_hash(pin_hash, pin):
                return True
        return False

    def require_pin(self, action_label, required_role="admin"):
        """طلب رمز PIN لتأكيد إجراء حساس؛ يعيد True عند النجاح فقط."""
        action_label = self.t(action_label)
        result = {"ok": False}

        win = ctk.CTkToplevel(self)
        win.title(self.t("تأكيد الهوية"))
        win.geometry("380x330")
        win.resizable(False, False)
        win.transient(self)
        self.center_window(win, 380, 330)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=20, pady=20)

        ctk.CTkLabel(container, text="🔒",
                     font=ctk.CTkFont(family=self.ui_font_family, size=32)).pack(pady=(2, 4))
        ctk.CTkLabel(container, text=self.t("تأكيد الهوية"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=19, weight="bold")).pack()
        ctk.CTkLabel(container, text=str(action_label or ""), text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10),
                     wraplength=320).pack(pady=(3, 12))

        entry = ctk.CTkEntry(container, show="*", placeholder_text=self.t("رمز PIN"),
                             height=44, justify="center",
                             fg_color=self.card(), border_color=self.border(),
                             text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"))
        entry.pack(fill="x")

        hint = ctk.CTkLabel(container, text="", text_color=self.colors["danger"],
                            font=ctk.CTkFont(family=self.ui_font_family, size=9))
        hint.pack(anchor="w", pady=(6, 0))

        attempts = {"left": 3}

        def verify(event=None):
            pin = entry.get().strip()
            if self._check_pin_credentials(pin, required_role):
                result["ok"] = True
                self.log_action("pin_verified", "security", None, str(action_label or ""))
                win.destroy()
                return
            attempts["left"] -= 1
            self.log_action("pin_denied", "security", None, str(action_label or ""))
            self.toast(self.t("رمز PIN غير صحيح"), "danger")
            entry.delete(0, "end")
            if attempts["left"] <= 0:
                win.destroy()
            else:
                hint.configure(text=f"{self.t('محاولات متبقية')}: {attempts['left']}")

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", pady=(14, 0))

        ctk.CTkButton(buttons, text=self.t("تأكيد"), command=verify, height=38, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
                      ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(buttons, text=self.t("إلغاء"), command=win.destroy, height=38, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=11)
                      ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        entry.bind("<Return>", verify)
        entry.focus_set()
        win.grab_set()
        win.wait_window()
        return result["ok"]

    def _startup_user_flow(self):
        """إنشاء حساب المدير الأول عند أول تشغيل، أو تسجيل الدخول اختياريًا."""
        try:
            users = self._get_users()
            if not users:
                self._show_first_user_setup()
            else:
                self._open_login_window(allow_skip=True)
        except Exception:
            pass

    def _set_current_user(self, user):
        self.current_user = user
        self._update_user_button_label()

    def _update_user_button_label(self):
        if not hasattr(self, "user_button"):
            return
        try:
            user = getattr(self, "current_user", None)
            if user:
                self.user_button.configure(text=f"👤 {str(user.get('name') or '')}")
            else:
                self.user_button.configure(text=self.t("👤 تسجيل الدخول"))
        except Exception:
            pass

    def _open_user_session_menu(self):
        user = getattr(self, "current_user", None)
        self._open_login_window(allow_skip=(user is None))

    def _show_first_user_setup(self):
        """نافذة إعداد إجبارية لإنشاء أول حساب مدير (لا يمكن إغلاقها قبل الإنشاء)."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("إعداد المدير"))
        win.geometry("430x450")
        win.resizable(False, False)
        win.transient(self)
        try:
            self.center_window(win, 430, 450)
        except Exception:
            pass

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(container, text=self.t("🔐 إعداد المدير"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold")).pack(anchor="w")
        ctk.CTkLabel(container, text=self.t("أنشئ حساب المدير الأول لاستخدام حماية PIN."),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(2, 14))

        name = ctk.CTkEntry(container, placeholder_text=self.t("اسم المدير"),
                            height=42, fg_color=self.card(), border_color=self.border(),
                            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=12))
        name.pack(fill="x", pady=(0, 8))

        pin = ctk.CTkEntry(container, show="*", placeholder_text=self.t("رمز PIN (4-6 أرقام)"),
                           height=42, fg_color=self.card(), border_color=self.border(),
                           text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=12))
        pin.pack(fill="x", pady=(0, 8))

        pin2 = ctk.CTkEntry(container, show="*", placeholder_text=self.t("تأكيد رمز PIN"),
                            height=42, fg_color=self.card(), border_color=self.border(),
                            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=12))
        pin2.pack(fill="x")

        error = ctk.CTkLabel(container, text="", text_color=self.colors["danger"],
                             font=ctk.CTkFont(family=self.ui_font_family, size=9), wraplength=360)
        error.pack(anchor="w", pady=(6, 0))

        def save(event=None):
            uname = name.get().strip()
            p1 = pin.get().strip()
            p2 = pin2.get().strip()
            if not uname:
                error.configure(text=self.t("الاسم مطلوب")); return
            if not (p1.isdigit() and 4 <= len(p1) <= 6):
                error.configure(text=self.t("الرمز يجب أن يكون أرقامًا من 4 إلى 6 خانات")); return
            if p1 != p2:
                error.configure(text=self.t("الرمزان غير متطابقين")); return
            ok, uid = self._create_user(uname, p1, "admin")
            if not ok:
                error.configure(text=self.t("تعذر إنشاء الحساب")); return
            self._set_current_user({"id": uid, "name": uname, "role": "admin"})
            self.log_action("user_created", "user", uid, f"{uname} • admin")
            self.log_action("login", "session", uid, uname)
            self.toast(f"✓ {self.t('تم إنشاء حساب المدير')}: {uname}")
            win.destroy()

        ctk.CTkButton(container, text=self.t("✓ إنشاء الحساب"), command=save,
                      height=46, corner_radius=10,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
                      ).pack(fill="x", side="bottom")

        name.bind("<Return>", lambda e: pin.focus_set())
        pin.bind("<Return>", lambda e: pin2.focus_set())
        pin2.bind("<Return>", save)

        # إنشاء المدير إلزامي قبل استخدام البرنامج.
        win.protocol("WM_DELETE_WINDOW", lambda: None)
        win.grab_set()
        name.focus_set()
        win.wait_window()

    def _open_login_window(self, title="تسجيل الدخول", allow_skip=False):
        """اختيار مستخدم وإدخال رمز PIN لتسجيل الدخول أو تبديل المستخدم."""
        title = self.t(title)
        users = self._get_users()
        if not users:
            self._show_first_user_setup()
            return

        win = ctk.CTkToplevel(self)
        win.title(title)
        win.geometry("400x360")
        win.resizable(False, False)
        win.transient(self)
        self.center_window(win, 400, 360)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(container, text=f"👤 {title}", text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")).pack(anchor="w")
        ctk.CTkLabel(container, text=self.t("اختر المستخدم ثم أدخل رمز PIN"),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(2, 12))

        combo = ctk.CTkComboBox(container, values=[u[1] for u in users],
                                height=40, corner_radius=9,
                                fg_color=self.card(), border_color=self.border(),
                                button_color=self.colors["primary"], text_color=self.text(),
                                font=ctk.CTkFont(family=self.ui_font_family, size=12))
        combo.set(users[0][1])
        combo.pack(fill="x", pady=(0, 8))

        entry = ctk.CTkEntry(container, show="*", placeholder_text=self.t("رمز PIN"),
                             height=42, fg_color=self.card(), border_color=self.border(),
                             text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=13))
        entry.pack(fill="x")

        error = ctk.CTkLabel(container, text="", text_color=self.colors["danger"],
                             font=ctk.CTkFont(family=self.ui_font_family, size=9))
        error.pack(anchor="w", pady=(6, 0))

        def do_login(event=None):
            sel = combo.get().strip()
            match = next((u for u in users if str(u[1]) == sel), None)
            pin = entry.get().strip()
            if not match or not self._verify_pin_hash(match[2], pin):
                self.log_action("login_failed", "session", None, sel)
                error.configure(text=self.t("رمز PIN غير صحيح"))
                entry.delete(0, "end")
                return
            self._set_current_user({"id": match[0], "name": match[1], "role": match[3]})
            self.log_action("login", "session", match[0], match[1])
            self.toast(f"✓ {self.t('تم تسجيل الدخول')}: {match[1]}")
            win.destroy()

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(side="bottom", fill="x")

        ctk.CTkButton(buttons, text=self.t("دخول"), command=do_login,
                      height=42, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
                      ).pack(side="right", fill="x", expand=True, padx=((6, 0) if allow_skip else 0))

        if allow_skip:
            ctk.CTkButton(buttons, text=self.t("تخطي"), command=win.destroy,
                          height=42, corner_radius=9,
                          fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                          font=ctk.CTkFont(family=self.ui_font_family, size=11)
                          ).pack(side="left", fill="x", expand=True, padx=(0, 6))

        entry.bind("<Return>", do_login)
        entry.focus_set()
        win.grab_set()
        win.wait_window()

    # =========================================================
    # وضع الشبكة — Server/Client setup + UDP discovery (Phase 2)
    # =========================================================

    def _current_store_name(self):
        try:
            return str(self.settings.get("store_name") or "Supermarket Pro")
        except Exception:
            return "Supermarket Pro"

    def _get_device_name(self):
        """اسم الجهاز الحالي الذي يُستخدم كـ device_name في جدول المرتجعات.

        الجهاز الرئيسي (server) يُسمّى دائماً 'PC1'.
        الأجهزة الإضافية (client) تستخدم اسم hostname نظام التشغيل.
        في وضع local يُعتبر كـ 'PC1'.
        """
        try:
            import socket as _socket
            mode = str(get_active_config().get("network_mode") or "").strip().lower()
            if mode == "server":
                return "PC1"
            hostname = str(_socket.gethostname() or "").strip()
            if not hostname:
                return "PC1"
            return hostname[:100]
        except Exception:
            return "PC1"

    @staticmethod
    def _network_mode_label(mode):
        return {
            "server": "رئيسي",
            "client": "إضافي",
            "local": "جهاز واحد",
        }.get(str(mode), "غير محدد")

    def _show_reconnect_modal(self):
        """إنشاء نافذة إعادة الاتصال (modal) لعرض حالة الشفاء الذاتي.

        يضمن مثيلًا واحدًا فقط: إذا وُجدت النافذة مفتوحة نرفعها ونُعيدها دون
        إنشاء أخرى، لمنع تكدّس النوافذ عند تشغيل دورات شفاء متعددة.
        يُنشئها على خيط الواجهة الرئيسي ويُعيدها دون حظر (الشفاء يعمل في خيط
        خلفي ويغلق النافذة عبر self.after(0, ...)). تُرجع (dialog, state)
        حيث state["close_fn"]() تُغلق النافذة بأمان.
        """
        state = {"active": True, "close_fn": None}

        def close(dlg=None):
            if not state.get("active"):
                return
            state["active"] = False
            if self._reconnect_dialog is dlg:
                self._reconnect_dialog = None
            try:
                dlg.destroy()
            except Exception:
                pass

        # إن كانت النافذة موجودة نرفعها فقط (لا نصنع نسخة ثانية).
        existing = self._reconnect_dialog
        if existing is not None:
            try:
                if existing.winfo_exists():
                    existing.lift()
                    existing.focus_force()
                    return existing, state
            except Exception:
                pass
            self._reconnect_dialog = None

        dialog = ctk.CTkToplevel(self)
        self._reconnect_dialog = dialog
        state["close_fn"] = lambda: close(dialog)
        dialog.title(self.t("إعادة الاتصال بالخادم"))
        dialog.geometry("440x260")
        dialog.resizable(False, False)
        dialog.configure(fg_color=self.card())
        try:
            self.center_window(dialog, 440, 260)
        except Exception:
            pass
        dialog.transient(self)
        dialog.protocol("WM_DELETE_WINDOW", lambda: self._reconnect_modal_manual(dialog, state))

        card = ctk.CTkFrame(dialog, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=20, pady=20)

        status_label = ctk.CTkLabel(
            card,
            text="⟳ " + self.t("جاري البحث عن الجهاز الرئيسي وإعادة الاتصال..."),
            text_color=self.colors["accent"],
            font=ctk.CTkFont(family=self.ui_font_family, size=15, weight="bold"),
        )
        status_label.pack(pady=(26, 8))

        ctk.CTkLabel(
            card,
            text=self.t("يرجى التأكد من تشغيل الجهاز الرئيسي واتصاله بنفس الشبكة."),
            text_color=self.muted(),
            justify="right",
            wraplength=380,
            font=ctk.CTkFont(family=self.ui_font_family, size=11),
        ).pack(pady=(0, 20))

        ctk.CTkButton(
            card,
            text=self.t("إلغاء"),
            width=130,
            height=38,
            corner_radius=9,
            fg_color=self.card(),
            border_width=1,
            border_color=self.border(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=12),
            command=lambda: self._reconnect_modal_manual(dialog, state),
        ).pack(pady=(0, 8))

        dialog.lift()
        try:
            dialog.grab_set()
        except Exception:
            pass
        return dialog, state

    def _reconnect_modal_manual(self, dialog, state):
        """زر إلغاء / إغلاق نافذة إعادة الاتصال: نغلقها ونفتح الإعداد اليدوي."""
        try:
            if state.get("active"):
                state["active"] = False
                if self._reconnect_dialog is dialog:
                    self._reconnect_dialog = None
                dialog.destroy()
        except Exception:
            pass
        try:
            dialog.grab_release()
        except Exception:
            pass
        # افتح معالج الشبكة كملاذٍ يدوي.
        try:
            self._open_network_setup_window(mandatory=False,
                                            on_done=self._finalize_startup,
                                            start_action="reconnect")
        except Exception:
            pass

    def _spawn_reconnect_modal(self, holder):
        """يُنشئ نافذة إعادة الاتصال على خيط الواجهة الرئيسي ويخزّنها.

        نظرًا لأن _try_auto_heal قد يُستدعى من خيط غير رئيسي، نُنشئ النافذة
        عبر self.after(0, ...) ثم نربطها في *holder* ليغلقها عمال الخلفية.
        إن انتهى الشفاء قبل وصول هذا الاستدعاء (حالة سباق) نتخطّى الإنشاء
        حتى لا تبقى نافذة عالقة.
        """
        if not getattr(self, "_heal_in_progress", False):
            holder["dialog"] = None
            holder["state"] = {"active": False, "close_fn": lambda: None}
            return
        try:
            dialog, state = self._show_reconnect_modal()
            holder["dialog"] = dialog
            holder["state"] = state
        except Exception:
            holder["dialog"] = None
            holder["state"] = {"active": False, "close_fn": lambda: None}

    def _startup_first_run_wizard(self):
        """أول تشغيل — الترتيب الصارم:
        (أ) ضمان وجود اتصال مُؤكَّد يعمل بقاعدة البيانات (معالج الشبكة أولًا)،
        (ب) عندها فقط إنشاء/فحص حساب المدير الأول،
        (ج) ثم بناء المدراء وعرض لوحة التحكم بحجم أقصى."""
        try:
            cfg = get_active_config()
            mode = str(cfg.get("network_mode") or "").strip().lower()
            # (2) إن لم يُضبط وضع الشبكة (أو كان وضعًا غير صالح) نعرض اختيار
            # دور الجهاز فورًا؛ وكذلك عند كون هذا العميل غير مربوطٍ بمتجر بعد.
            if mode not in ("server", "client", "local"):
                self._open_network_setup_window(mandatory=True, on_done=self._finalize_startup)
                return
            if mode == "client" and not self.store_linked:
                self._open_network_setup_window(mandatory=True, on_done=self._finalize_startup)
                return

            # الوضع محدّد مسبقًا: تأكد أن الاتصال يعمل فعلًا قبل المتابعة.
            # إن لم يعمل (مثل تغيّر عنوان IP للجهاز الرئيسي) نجرّب الشفاء
            # الذاتي التلقائي أولًا، ولا نعرض أي معالج أو نمرّ لإنشاء المدير
            # إلا عند فشل ذلك — أي فقط عندما يتعذر إيجاد اتصال حقيقي.
            ok, _msg = test_database_connection(cfg, create_database=False)
            if ok:
                self._finalize_startup()
            else:
                self._startup_self_heal_or_wizard()
        except Exception:

            try:
                self._startup_user_flow()
            except Exception:
                pass

    def _startup_self_heal_or_wizard(self):
        """عند تشغيل جهاز واتصاله لا يعمل (مثل تغيّر IP الجهاز الرئيسي):
        نجرّب الاكتشاف الذاتي عبر UDP مع نافذة إعادة اتصال مرئية (modal)
        تعرض حالة الشفاء. عند النجاح تُغلق النافذة تلقائيًا مع إشعار أخضر،
        وعند فشل الاكتشاف المتكرر نُظهر معالج الشبكة كملاذ أخير."""
        # إذا كان هذا العميل قد سبق ربطه بخادم، نجري الاكتشاف مع عرض نافذة مرئية.
        show_confirmation = not self.store_linked
        healing = self._conn_state_box.get("healing", False)
        self._conn_state_box["healing"] = True
        if not healing:
            try:
                self._apply_conn_status(False, reconnecting=True)
            except Exception:
                pass

        # نافذة إعادة الاتصال المرئية (لا يحجب الخيط؛ الشفاء يعمل خلفيًا).
        try:
            _dialog, _modal_state = self._show_reconnect_modal()
        except Exception:
            _dialog = None
            _modal_state = {"active": False, "close_fn": lambda: None}

        def worker():
            import time
            from utils.network_discovery import discover_server
            from database.db_manager import set_active_config, test_connection as test_database_connection, get_active_config
            healed = False
            found_candidate = None

            # مسح سريع أحادي الممر: جولة واحدة قصيرة جدًا (الـ TCP sweep يجد
            # الخادم خلال ~0.5 ث)، بدل حلقة متكررة تمتد 45 ثانية تجمّد التطبيق.
            try:
                found = discover_server(timeout=3.0)
                if found:
                    found_candidate = found
                    host = str(found.get("host") or "")
                    # إذا كان العميل مربوطًا بمتجر نطبّق الفور ونُنهي فورًا.
                    if self.store_linked:
                        candidate = {
                            **dict(get_active_config()),
                            "host": host,
                            "port": int(found.get("port") or 3306),
                            "user": get_active_config().get("user") or "root",
                            "password": get_active_config().get("password") or "Islem2002@",
                            "database": get_active_config().get("database") or "supermarket_pro",
                            "network_mode": "client",
                            "store_linked": True,
                        }
                        ok, _m = test_database_connection(candidate, create_database=False)
                        if ok:
                            set_active_config(candidate)
                            healed = True
            except Exception:
                healed = False

            # After the (fast) healing pass:
            if healed:
                # Already-linked client: reconnection succeeded visually.
                try:
                    self._conn_state_box["healing"] = False
                except Exception:
                    pass
                self._apply_conn_status(True, reconnecting=False)

                def on_healed():
                    # أغلق نافذة إعادة الاتصال بصورة نظيفة.
                    try:
                        dl = getattr(self, "_reconnect_dialog", None)
                        if dl is not None:
                            try:
                                if dl.winfo_exists():
                                    dl.destroy()
                            except Exception:
                                pass
                            self._reconnect_dialog = None
                    except Exception:
                        pass
                    try:
                        self.toast("✓ " + self.t("تم استعادة الاتصال بالجهاز الرئيسي"))
                    except Exception:
                        pass
                    # التأكد من إعادة تهيئة/التحقق من اتصال قاعدة البيانات ثم المتابعة.
                    try:
                        self.db.ensure_server_and_database()
                        self.db.create_tables()
                    except Exception:
                        pass
                    # Proceed to finalize startup
                    self._finalize_startup()
                try:
                    self.after(0, on_healed)
                except Exception:
                    self._finalize_startup()
                return

            # If we have a candidate from the pass and this is a new client,
            # show the confirmation dialog and proceed to startup
            if found_candidate and not self.store_linked:
                try:
                    _modal_state["active"] = False
                    if _dialog is not None:
                        _dialog.destroy()
                        if self._reconnect_dialog is _dialog:
                            self._reconnect_dialog = None
                except Exception:
                    pass
                try:
                    self._fetch_real_store_name(found_candidate)
                except Exception:
                    pass
                self._show_store_confirmation_dialog(found_candidate)
                return

            # No valid connection found within the healing pass
            def apply():
                # أغلق نافذة إعادة الاتصال المرئية إن كانت لا تزال مرتفعة.
                try:
                    _modal_state["active"] = False
                    if _dialog is not None:
                        _dialog.destroy()
                        if self._reconnect_dialog is _dialog:
                            self._reconnect_dialog = None
                except Exception:
                    pass
                try:
                    self._conn_state_box["healing"] = False
                except Exception:
                    pass
                if healed:
                    try:
                        self._conn_state_box["up"] = True
                        self._apply_conn_status(True)
                    except Exception:
                        pass
                    self._finalize_startup()
                else:
                    # Only fall back to manual network setup if no candidate was found
                    # and user has not confirmed a store
                    if not found_candidate:
                        self._open_network_setup_window(
                            mandatory=True,
                            on_done=self._finalize_startup,
                            start_action="reconnect",
                        )
                    elif self.store_linked:
                        self._finalize_startup()
            self.after(0, apply)

        threading.Thread(target=worker, daemon=True).start()

    def _fetch_real_store_name(self, candidate):
        """استعلام خفيف (مهلة قصيرة) لجلب اسم المتجر الحقيقي من الخادم.

        ي查询 مباشرة من قاعدة البيانات البعيدة باستخدام بيانات الاتصال
        الخاصة بالمرشَّح (candidate) — لا يعتمد على الإعدادات النشطة
        لأن العميل قد لا يزال في مرحلة الإعداد ولا يملك config صالحًا.
        """
        if not candidate or not candidate.get("host"):
            return candidate
        real = candidate.get("store_name") or "Supermarket Pro"
        if pymysql is not None:
            try:
                conn = pymysql.connect(
                    host=candidate["host"],
                    port=int(candidate.get("port") or 3306),
                    user=candidate.get("user") or "root",
                    password=candidate.get("password") or "Islem2002@",
                    database=candidate.get("database") or "supermarket_pro",
                    connect_timeout=1.5,
                )
                try:
                    with conn.cursor() as cur:
                        for query in (
                            "SELECT setting_value FROM app_settings "
                            "WHERE setting_key = 'store_name' LIMIT 1",
                            "SELECT value FROM settings "
                            "WHERE `key` = 'store_name' LIMIT 1",
                            "SELECT value FROM settings "
                            "WHERE key_name = 'store_name' LIMIT 1",
                            "SELECT store_name FROM store_info LIMIT 1",
                        ):
                            try:
                                cur.execute(query)
                                r = cur.fetchone()
                                if r and r[0]:
                                    real = str(r[0]).strip()
                                    break
                            except Exception:
                                pass
                finally:
                    try:
                        conn.close()
                    except Exception:
                        pass
            except Exception:
                pass
        if not real or real in ("Supermarket Pro", "None", "null"):
            try:
                import os as _os
                _path = _os.path.join(
                    _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))),
                    "config", "app_settings.json",
                )
                if _os.path.exists(_path):
                    with open(_path, "r", encoding="utf-8-sig") as f:
                        import json as _json
                        data = _json.load(f)
                    name = data.get("store_name") if isinstance(data, dict) else None
                    if name:
                        real = str(name).strip()
            except Exception:
                pass
        candidate["store_name"] = real
        return candidate

    def _show_store_confirmation_dialog(self, candidate):
        """Dialog first-time store confirmation.

        يظهر بعد اكتشاف الخادم لأول مرة، ويطلب من المستخدم تأكيد الاتصال
        بالخادم المكتشف. يحتوي على عنوان الخادم واسم المتجر، وأزرار
        تأكيد وإلغاء conforming to the project's visual conventions.

        - عنوان: "تأكيد الاتصال بالمتجر"
        - رسالة: "تم العثور على الخادم الرئيسي للمتجر: {store_name} على
          العنوان {host}:{port}. هل تريد الاتصال بهذا المتجر واستخدامه؟"
        - زرون: "✓ نعم، الاتصال بهذا المتجر" (اللون الثانوي) و
          "✕ إلغاء" (محايد).
        - على تأكيد: يصرح config عبر set_active_config()، يضبط
          store_linked إلى true، وينتقل إلى _finalize_startup().
        - على إلغاء: يسقط config المحفوظ ويعيد عرض معالج الإعداد اليدوي.
        """
        import customtkinter as ctk
        from tkinter import messagebox

        store_name = candidate.get("store_name", "") or "Supermarket Pro"
        host = candidate.get("host", "") or "127.0.0.1"
        port = candidate.get("port", 3306)

        # Build the dialog window as a CTkToplevel following project conventions
        dialog = ctk.CTkToplevel(self)
        dialog.title(self.t("تأكيد الاتصال بالمتجر"))
        # Center the dialog over the main window
        try:
            self.center_window(dialog, 480, 280)
        except Exception:
            dialog.geometry("480x280")
        dialog.transient(self)
        dialog.grab_set()

        # --- Card container ---
        card = ctk.CTkFrame(dialog, fg_color=self.colors["dark_card"], corner_radius=12)
        card.pack(fill="both", expand=True, padx=20, pady=20)

        # --- Info row ---
        info_frame = ctk.CTkFrame(card, fg_color="transparent")
        info_frame.pack(fill="x", padx=20, pady=(20, 10))

        # RTL label for the store name and address
        ctk.CTkLabel(
            info_frame,
            text=self.t(f"تم العثور على الخادم الرئيسي للمتجر: {store_name} على العنوان {host}:{port}"),
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
            anchor="e",
        ).pack(side="right", fill="x", expand=True)

        # --- Buttons row ---
        btn_frame = ctk.CTkFrame(card, fg_color="transparent")
        btn_frame.pack(fill="x", padx=20, pady=(0, 20))

        # Cancel button (neutral)
        cancel_btn = ctk.CTkButton(
            btn_frame,
            text=self.t("✕ إلغاء"),
            width=100,
            height=36,
            corner_radius=8,
            fg_color=self.colors["grey_border"],
            hover_color=self.colors["grey_muted"],
            text_color=self.colors["grey_text"],
            font=ctk.CTkFont(family=self.ui_font_family, size=12),
            command=lambda: [dialog.destroy(), self._on_store_confirm_cancel()],
        )
        cancel_btn.pack(side="left", padx=(0, 10))

        # Confirm button (primary/secondary color)
        confirm_btn = ctk.CTkButton(
            btn_frame,
            text=self.t("✓ نعم، الاتصال بهذا المتجر"),
            width=140,
            height=36,
            corner_radius=8,
            fg_color=self.colors["secondary"],
            hover_color="#16A34A",
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
            command=lambda: [dialog.destroy(), self._on_store_confirm_confirm(candidate)],
        )
        confirm_btn.pack(side="right", padx=(10, 0))

        # Ensure the dialog stays on top and captures input
        dialog.update_idletasks()
    def _on_store_confirm_confirm(self, candidate):
        """Handle user clicking 'Yes, connect to this store'."""
        # Merge the discovered candidate on top of the current full config so
        # we preserve the DB credentials, database name and network mode that
        # the candidate dict (host/port/store_name only) does not carry.
        real_store = str(candidate.get("store_name") or "")
        cfg = {**dict(get_active_config()),
               "host": str(candidate.get("host") or ""),
               "port": int(candidate.get("port") or 3306),
               "user": get_active_config().get("user") or "root",
               "password": get_active_config().get("password") or "Islem2002@",
               "database": get_active_config().get("database") or "supermarket_pro",
               "network_mode": "client",
               "store_name": real_store
                            or get_active_config().get("store_name")
                            or "Supermarket Pro",
               "store_linked": True}
        # Persist the complete merged config and mark this client as linked.
        set_active_config(cfg)
        self.store_linked = True
        # حدّث اسم المتجر في الإعدادات المحلية ليعكس الاسم الحقيقي
        # المجلوب من الخادم البعيد (يؤثر على sidebar و Dashboard والفواتير).
        if real_store and real_store != "Supermarket Pro":
            self.settings["store_name"] = real_store
            self.save_app_settings()
        # سجّل هذا الجهاز (PC2) كطلب اقتران على الخادم ليوافق عليه المدير
        # على جهاز PC1، ثم انتظر الموافقة قبل الدخول للتطبيق.
        self._register_paired_device()
        self._wait_for_pairing_approval()

    def _wait_for_pairing_approval(self):
        """PC2: انتظار موافقة مدير PC1 قبل الدخول للتطبيق.

        يعرض نافذة "بانتظار موافقة المدير" ويستقصي جدول authorized_devices
        بانتظار status = approved. عند الموافقة يدخل التطبيق؛ وعند الإلغاء أو
        انتهاء المهلة يعود إلى معالج الإعداد بدلًا من الدخول مباشرة.
        """
        my_ip = self._resolved_local_ip() or ""
        if not my_ip:
            self._finalize_startup()
            return
        import customtkinter as ctk
        import time as _time

        dialog = ctk.CTkToplevel(self)
        dialog.title(self.t("بانتظار موافقة المدير"))
        try:
            self.center_window(dialog, 460, 220)
        except Exception:
            dialog.geometry("460x220")
        dialog.transient(self)
        dialog.grab_set()
        self._pairing_wait_dialog = dialog

        card = ctk.CTkFrame(dialog, fg_color=self.colors["dark_card"], corner_radius=12)
        card.pack(fill="both", expand=True, padx=20, pady=20)

        msg = ctk.CTkLabel(
            card,
            text=self.t("بانتظار موافقة الجهاز الرئيسي (PC1) على اتصال هذا الجهاز..."),
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
            wraplength=380, justify="right", anchor="e",
        )
        msg.pack(fill="x", padx=20, pady=(20, 6))

        status_lbl = ctk.CTkLabel(
            card,
            text="",
            text_color=self.colors["accent"],
            font=ctk.CTkFont(family=self.ui_font_family, size=11),
        )
        status_lbl.pack(fill="x", padx=20, pady=(0, 10))

        state = {"approved": False, "cancelled": False}

        def cancel():
            state["cancelled"] = True
            try:
                dialog.grab_release()
                dialog.destroy()
            except Exception:
                pass
            if self._pairing_wait_dialog is dialog:
                self._pairing_wait_dialog = None
            self._open_network_setup_window(mandatory=True, on_done=self._finalize_startup)

        cancel_btn = ctk.CTkButton(
            card,
            text=self.t("✕ إلغاء"),
            width=110,
            height=36,
            corner_radius=8,
            fg_color=self.colors["grey_border"],
            hover_color=self.colors["grey_muted"],
            text_color=self.colors["grey_text"],
            font=ctk.CTkFont(family=self.ui_font_family, size=12),
            command=cancel,
        )
        cancel_btn.pack(side="bottom", pady=(0, 10))

        deadline = _time.time() + 60.0
        started = _time.time()

        def poll():
            try:
                from database.db_manager import DatabaseManager as _DBManager
                # نسخة مستقلة لاستقصاء الموافقة (self.db لا يُبنى قبل finalize).
                poll_db = _DBManager()
            except Exception:
                poll_db = None
            while not state["approved"] and not state["cancelled"]:
                if _time.time() >= deadline:
                    try:
                        self.after(0, cancel)
                    except Exception:
                        pass
                    return
                elapsed = _time.time() - started
                try:
                    if my_ip and poll_db is not None:
                        if poll_db.is_device_authorized(my_ip):
                            state["approved"] = True
                            try:
                                self.after(0, on_approved)
                            except Exception:
                                pass
                            return
                except Exception:
                    pass
                dots = "." * (int(elapsed) % 4)
                try:
                    self.after(
                        0,
                        lambda d=dots: status_lbl.configure(
                            text=self.t(f"بانتظار الموافقة{d} ({int(deadline - _time.time())} ث)")
                        ),
                    )
                except Exception:
                    pass
                _time.sleep(1.0)

        def on_approved():
            try:
                if self._pairing_wait_dialog is dialog:
                    dialog.grab_release()
                    dialog.destroy()
                    self._pairing_wait_dialog = None
            except Exception:
                pass
            try:
                self.toast("✓ " + self.t("تمت الموافقة على اتصال هذا الجهاز"))
            except Exception:
                pass
            self._finalize_startup()

        try:
            dialog.protocol("WM_DELETE_WINDOW", cancel)
        except Exception:
            pass
        threading.Thread(target=poll, daemon=True).start()

    def _register_paired_device(self):
        """تسجيل الطلب الحالي (PC2) كجهاز معلَّق على جهاز الخادم (PC1).

        يعمل على خيط منفصل كي لا يؤخّر واجهة المستخدم.
        """
        my_ip_pc = self._resolved_local_ip() or ""
        if not my_ip_pc:
            return
        cfg = dict(get_active_config())
        if str(cfg.get("network_mode")).lower() != "client":
            return
        host = str(cfg.get("host") or "")
        if not host:
            return

        def _do():
            try:
                import socket as _socket
                device_name = str(_socket.gethostname() or "جهاز إضافي")[:100]
                from database.db_manager import DatabaseManager as _DBManager
                # نسخة مستقلة: self.db لا يُبنى بعد في هذه اللحظة (قبل finalize).
                db = _DBManager()
                if db is None:
                    return
                db.register_device_request(device_name, my_ip_pc)
            except Exception:
                pass

        try:
            threading.Thread(target=_do, daemon=True).start()
        except Exception:
            pass

    def _on_store_confirm_cancel(self):
        """Handle user clicking 'Cancel' — fall back to manual network wizard."""
        dialog = None  # suppress unused variable warning
        # Fall back to the existing manual network setup wizard
        # by opening the network setup window so the user can choose a different path
        try:
            self._open_network_setup_window(mandatory=True, on_done=self._finalize_startup)
        except Exception:
            pass

    def _finalize_startup(self):
        """بعد تحديد وضع الشبكة: بناء طبقة البيانات ثم متابعة تسجيل الدخول.

        تُستدعى من معالج الإعداد الأول (عندما يختار المستخدم الدور) من مسار
        التشغيل عندما يكون الوضع محددًا مسبقًا. البناء يحدث مرة واحدة فقط.
        """
        if getattr(self, "_data_ready", False):
            self._startup_user_flow()
            return
        self._data_ready = True

        # بناء المدراء — أول اتصال بقاعدة البيانات يحدث هنا فقط،
        # أي بعد أن يختار المستخدم وضع الشبكة.
        self.product_manager = ProductManager()
        self.sales_manager = SalesManager()
        self.customer_manager = CustomerManager()
        self.reports_manager = ReportsManager()
        self.debt_manager = DebtManager()
        self.inventory_manager = InventoryManager()
        self.packs_manager = PacksManager()
        self.db = DatabaseManager()
        self.favorites_manager = FavoritesManager()

        # المخططات الإضافية — كلها محمية فلا تُسقط بدء التشغيل.
        for name in ("_ensure_profit_schema", "_ensure_returns_schema",
                     "_ensure_audit_schema", "_ensure_categories_schema",
                     "_ensure_users_schema", "_ensure_item_discount_schema",
                     "_ensure_packs_schema", "_ensure_favorites_schema"):
            try:
                getattr(self, name)()
            except Exception:
                pass

        self._start_discovery_responder_if_needed()

        try:
            self._start_pairing_poller()
        except Exception:
            pass

        try:
            self._start_conn_monitor()
        except Exception:
            pass

        try:
            self.show_dashboard()
        except Exception:
            pass
        self._apply_maximized()
        self._translate_visible_widgets()
        self.update_clock()
        try:
            self.check_notifications()
        except Exception:
            pass

        # متابعة إنشاء المدير الأول / تسجيل الدخول
        self._startup_user_flow()

    def _resolved_local_ip(self):
        """عنوان IP لهذا الجهاز: القيمة المخصصة من الإعدادات إن وُجدت،
        وإلا نكتشفه تلقائيًا عبر get_local_ip()."""
        try:
            manual = str(
                (get_active_config() or {}).get("local_ip") or ""
            ).strip()
            if manual:
                return manual
        except Exception:
            pass
        try:
            from utils.network_discovery import get_local_ip
            return get_local_ip()
        except Exception:
            return ""

    def _start_discovery_responder_if_needed(self):
        """تشغيل مستجيب الاكتشاف على الجهاز الرئيسي فقط (مرة واحدة)."""
        if getattr(self, "_discovery_started", False):
            return
        try:
            cfg = get_active_config()
            if str(cfg.get("network_mode")).lower() != "server":
                return
            from utils.network_discovery import DiscoveryResponder, build_reply

            try:
                port = int(cfg.get("port") or 3306)
            except Exception:
                port = 3306

            def payload_provider():
                return build_reply(self._resolved_local_ip(), port, self._current_store_name())

            responder = DiscoveryResponder(payload_provider)
            started = responder.start()
            self._discovery_responder = responder
            self._discovery_started = started
        except Exception:
            pass

    # -----------------------------------------------------
    # اقتران الأجهزة (موافقة المدير على طلبات الأجهزة الجديدة PC2)
    # -----------------------------------------------------

    def _start_pairing_poller(self):
        """على الجهاز الرئيسي (PC1) فقط: مراقبة طلبات الاقتران المعلّقة.

        يفحص دوريًا جدول authorized_devices، وإذا وُجد طلب جديد pending
        يعرض نافذة موافقة على الخادم ليوافق المدير أو يرفض.
        """
        if getattr(self, "_pairing_poller_started", False):
            return
        try:
            cfg = get_active_config()
            if str(cfg.get("network_mode")).lower() != "server":
                return
        except Exception:
            return
        self._pairing_poller_started = True
        self._pairing_handled = {}

        import time

        def _poll():
            while not getattr(self, "_closing", False):
                try:
                    reqs = self.db.get_pending_device_requests()
                    for req in reqs:
                        rid = req.get("id")
                        if rid in self._pairing_handled:
                            continue
                        self._pairing_handled[rid] = True
                        try:
                            self.after(0, lambda r=req: self._show_pairing_approval_modal(r))
                        except Exception:
                            pass
                except Exception:
                    pass
                time.sleep(3.0)

        try:
            threading.Thread(target=_poll, daemon=True).start()
        except Exception:
            pass

    def _show_pairing_approval_modal(self, request):
        """نافذة موافقة على طلب اقتران جهاز جديد يظهر على الخادم (PC1)."""
        if getattr(self, "_closing", False):
            return
        # لا نكدّس نوافذ: إن كانت نافذة اقتران مفتوحة نركّزها فقط.
        existing = getattr(self, "_pairing_dialog", None)
        if existing is not None:
            try:
                if existing.winfo_exists():
                    existing.lift()
                    return
            except Exception:
                existing = None
        import customtkinter as ctk
        rid = request.get("id")
        device_name = str(request.get("device_name") or "جهاز غير معروف")
        ip_addr = str(request.get("ip_address") or "?")

        dialog = ctk.CTkToplevel(self)
        dialog.title(self.t("طلب اقتران جهاز جديد"))
        try:
            self.center_window(dialog, 520, 300)
        except Exception:
            dialog.geometry("520x300")
        dialog.transient(self)
        dialog.grab_set()
        self._pairing_dialog = dialog

        card = ctk.CTkFrame(dialog, fg_color=self.colors["dark_card"], corner_radius=12)
        card.pack(fill="both", expand=True, padx=20, pady=20)

        info_frame = ctk.CTkFrame(card, fg_color="transparent")
        info_frame.pack(fill="x", padx=20, pady=(20, 10))

        ctk.CTkLabel(
            info_frame,
            text=self.t(f"يريد جهاز جديد الاتصال بالخادم الرئيسي:\n{device_name}\nالعنوان: {ip_addr}"),
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
            anchor="e", justify="right",
        ).pack(side="right", fill="x", expand=True)

        btn_frame = ctk.CTkFrame(card, fg_color="transparent")
        btn_frame.pack(fill="x", padx=20, pady=(0, 20))

        deny_btn = ctk.CTkButton(
            btn_frame,
            text=self.t("✕ رفض"),
            width=110,
            height=36,
            corner_radius=8,
            fg_color=self.colors["grey_border"],
            hover_color=self.colors["grey_muted"],
            text_color=self.colors["grey_text"],
            font=ctk.CTkFont(family=self.ui_font_family, size=12),
            command=lambda: [dialog.destroy(), self._resolve_pairing(rid, "denied")],
        )
        deny_btn.pack(side="left", padx=(0, 10))

        approve_btn = ctk.CTkButton(
            btn_frame,
            text=self.t("✓ السماح بالاتصال"),
            width=150,
            height=36,
            corner_radius=8,
            fg_color=self.colors["secondary"],
            hover_color="#16A34A",
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
            command=lambda: [dialog.destroy(), self._resolve_pairing(rid, "approved")],
        )
        approve_btn.pack(side="right", padx=(10, 0))

        try:
            dialog.protocol("WM_DELETE_WINDOW",
                            lambda: [dialog.destroy(), self._resolve_pairing(rid, "denied")])
        except Exception:
            pass

        def _clear():
            if self._pairing_dialog is dialog:
                self._pairing_dialog = None
        dialog.bind("<Destroy>", lambda e: _clear())
        dialog.update_idletasks()

    def _resolve_pairing(self, request_id, status):
        """تطبيق قرار المدير (approve/deny) على طلب الاقتران."""
        try:
            self.db.set_device_request_status(int(request_id), status)
        except Exception:
            pass
        if status == "approved":
            try:
                self.toast("✓ " + self.t("تم السماح للجهاز الجديد بالاتصال"))
            except Exception:
                pass
        try:
            self._pairing_dialog = None
        except Exception:
            pass


    # نافذة معالج الإعداد (اختيار الدور / بحث / إدخال يدوي)
    # -----------------------------------------------------

    def _open_network_setup_window(self, mandatory=True, on_done=None, start_action=None):
        from utils.network_discovery import discover_server, get_local_ip

        win = ctk.CTkToplevel(self)
        win.title(self.t("إعداد الجهاز"))
        win.geometry("680x540")
        win.resizable(False, False)
        win.transient(self)
        try:
            self.center_window(win, 680, 540)
        except Exception:
            pass
        win.configure(fg_color=self.bg())

        body = ctk.CTkFrame(win, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=24, pady=24)

        title_label = ctk.CTkLabel(body, text="🚀 " + self.t("إعداد الجهاز"),
                                   text_color=self.text(),
                                   font=ctk.CTkFont(family=self.ui_font_family, size=22, weight="bold"))
        title_label.pack(anchor="e")
        subtitle_label = ctk.CTkLabel(body, text="", text_color=self.muted(),
                                      font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                      justify="right", wraplength=600)
        subtitle_label.pack(anchor="e", pady=(3, 14))

        page = ctk.CTkFrame(body, fg_color="transparent")
        page.pack(fill="both", expand=True)

        dots = {"n": 0}
        anim_job = {"id": None}

        def clear_page():
            if anim_job["id"]:
                try:
                    win.after_cancel(anim_job["id"])
                except Exception:
                    pass
                anim_job["id"] = None
            for w in page.winfo_children():
                w.destroy()

        def animate_dots(base_text, label):
            if not win.winfo_exists():
                return
            dots["n"] = (dots["n"] + 1) % 4
            label.configure(text=base_text + "." * dots["n"])
            anim_job["id"] = win.after(400, lambda: animate_dots(base_text, label))

        # ---------- صفحة اختيار الدور ----------
        def render_choose():
            clear_page()
            subtitle_label.configure(text=self.t("اختر دور هذا الجهاز — يمكنك تغييره لاحقًا من الإعدادات."))

            cards_row = ctk.CTkFrame(page, fg_color="transparent")
            cards_row.pack(expand=True, fill="both", pady=(30, 0))
            cards_row.grid_columnconfigure((0, 1), weight=1, uniform="roles")

            def role_card(col, icon, title, desc, color, command):
                card = ctk.CTkFrame(cards_row, fg_color=self.card(), corner_radius=18,
                                    border_width=2, border_color=color)
                card.grid(row=0, column=col, sticky="nsew", padx=8)
                ctk.CTkLabel(card, text=icon,
                             font=ctk.CTkFont(family=self.ui_font_family, size=42)).pack(pady=(34, 6))
                ctk.CTkLabel(card, text=self.t(title), text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold")).pack()
                ctk.CTkLabel(card, text=self.t(desc), text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=10),
                             justify="center", wraplength=260).pack(pady=(6, 36), padx=16)
                for widget in (card, *card.winfo_children()):
                    widget.bind("<Button-1>", lambda e: command())

            role_card(0, "🖥️", "هذا الجهاز الرئيسي",
                      "سيتم تخزين البيانات على هذا الجهاز ومشاركتها مع باقي الأجهزة.",
                      self.colors["primary"], choose_main)
            role_card(1, "📱", "جهاز إضافي",
                      "سيتصل تلقائيًا بالجهاز الرئيسي لاستخدام نفس قاعدة البيانات.",
                      self.colors["secondary"], choose_additional)

        # ---------- تطبيق وضع الجهاز الرئيسي ----------
        def choose_main():
            base = dict(get_active_config())
            candidate = {**base, "host": "localhost", "network_mode": "server"}
            ok, message = test_database_connection(candidate, create_database=True)
            if not ok:
                if mandatory:
                    # في أول تشغيل إلزامي: يجب أن يتحقق اتصال يعمل قبل المتابعة،
                    # فلا نُنشئ حساب مدير أو نعرض لوحة تحكم بدون قاعدة بيانات.
                    messagebox.showerror(
                        self.t("إعداد الجهاز"),
                        self.t("لم يتم العثور على خادم MySQL/MariaDB محلي يعمل.")
                        + f"\n({message})",
                        parent=win,
                    )
                    return
                proceed = messagebox.askyesno(
                    self.t("إعداد الجهاز"),
                    self.t("لم يتم العثور على خادم MySQL/MariaDB محلي يعمل.")
                    + f"\n({message})\n\n"
                    + self.t("هل تريد حفظ الإعدادات والمتابعة على أي حال؟"),
                    parent=win,
                )
                if not proceed:
                    return
            set_active_config(candidate)
            self.log_action("network_mode_set", "settings", None, "server • localhost")
            self.toast("✓ " + self.t("تم ضبط هذا الجهاز كجهاز رئيسي"))
            finish_setup(win)

        # ---------- تطبيق وضع الجهاز الإضافي / البحث ----------
        def choose_additional():
            render_searching()

        def render_searching():
            clear_page()
            subtitle_label.configure(text=self.t("سيتم البحث عن الجهاز الرئيسي تلقائيًا على الشبكة المحلية."))
            box = ctk.CTkFrame(page, fg_color="transparent")
            box.pack(expand=True)
            search_label = ctk.CTkLabel(box, text="🔍 " + self.t("جاري البحث عن الجهاز الرئيسي"),
                                        text_color=self.text(),
                                        font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold"))
            search_label.pack(pady=(70, 8))
            animate_dots(self.t("جاري البحث عن الجهاز الرئيسي"), search_label)
            ctk.CTkLabel(box, text=self.t("تأكد من تشغيل الجهاز الرئيسي واتصال الجهازين بنفس الشبكة."),
                         text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack()

            def worker():
                found = discover_server(5.0)
                print(f"[DISCOVERY-DEBUG] Search worker finished. Raw discovered payload: {found}")

                def apply():
                    if not win.winfo_exists():
                        return
                    if found:
                        try:
                            port = int(found.get("port") or 3306)
                        except Exception:
                            port = 3306
                        apply_client(str(found.get("host") or ""), port)
                    else:
                        render_manual()

                self.after(0, apply)

            threading.Thread(target=worker, daemon=True).start()

            ctk.CTkButton(box, text=self.t("إلغاء البحث"), width=140, height=38,
                          corner_radius=9, fg_color=self.card(), hover_color=self.border(),
                          text_color=self.text(),
                          command=lambda: (clear_page(), render_choose())
                          ).pack(side="bottom", pady=(20, 0))

        # ---------- صفحة الفشل / الإدخال اليدوي ----------
        def render_manual(last_error=""):
            clear_page()
            subtitle_label.configure(text="")
            box = ctk.CTkFrame(page, fg_color="transparent")
            box.pack(fill="both", expand=True)

            ctk.CTkLabel(box, text="⚠ " + self.t("لم يتم العثور على الجهاز الرئيسي تلقائيًا"),
                         text_color=self.colors["accent"],
                         font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold")).pack(anchor="w")
            ctk.CTkLabel(box,
                         text=self.t("تأكد من أن الجهازين على نفس شبكة WiFi/الشبكة، وأن الجهاز الرئيسي يعمل، وأنك سمحت للبرنامج في جدار الحماية."),
                         text_color=self.muted(), justify="right", wraplength=580,
                         font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(4, 12))
            if last_error:
                ctk.CTkLabel(box, text=f"{self.t('تعذر الاتصال')}: {last_error}",
                             text_color=self.colors["danger"],
                             font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(0, 8))

            ip_row = ctk.CTkFrame(box, fg_color="transparent")
            ip_row.pack(fill="x", pady=4)
            ctk.CTkLabel(ip_row, text=self.t("عنوان IP"), width=120, anchor="e",
                         text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(side="right", padx=(10, 0))
            ip_entry = ctk.CTkEntry(ip_row, height=42, justify="center",
                                    fg_color=self.card(), border_color=self.border(),
                                    text_color=self.text(),
                                    font=ctk.CTkFont(family=self.ui_font_family, size=13))
            ip_entry.insert(0, str(get_local_ip().rsplit(".", 1)[0] + "."))
            ip_entry.pack(side="right", fill="x", expand=True)

            port_row = ctk.CTkFrame(box, fg_color="transparent")
            port_row.pack(fill="x", pady=4)
            ctk.CTkLabel(port_row, text=self.t("المنفذ"), width=120, anchor="e",
                         text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(side="right", padx=(10, 0))
            port_entry = ctk.CTkEntry(port_row, height=42, width=140, justify="center",
                                      fg_color=self.card(), border_color=self.border(),
                                      text_color=self.text(),
                                      font=ctk.CTkFont(family=self.ui_font_family, size=13))
            try:
                port_entry.insert(0, str(int(get_active_config().get("port") or 3306)))
            except Exception:
                port_entry.insert(0, "3306")
            port_entry.pack(side="right", anchor="e")

            user_row = ctk.CTkFrame(box, fg_color="transparent")
            user_row.pack(fill="x", pady=4)
            ctk.CTkLabel(user_row, text=self.t("اسم المستخدم"), width=120, anchor="e",
                         text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(side="right", padx=(10, 0))
            user_entry = ctk.CTkEntry(user_row, height=42, justify="center",
                                      fg_color=self.card(), border_color=self.border(),
                                      text_color=self.text(),
                                      font=ctk.CTkFont(family=self.ui_font_family, size=13))
            try:
                user_entry.insert(0, str(get_active_config().get("user") or "root"))
            except Exception:
                user_entry.insert(0, "root")
            user_entry.pack(side="right", fill="x", expand=True)

            password_row = ctk.CTkFrame(box, fg_color="transparent")
            password_row.pack(fill="x", pady=4)
            ctk.CTkLabel(password_row, text=self.t("كلمة المرور"), width=120, anchor="e",
                         text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(side="right", padx=(10, 0))
            password_entry = ctk.CTkEntry(password_row, height=42, justify="center",
                                          fg_color=self.card(), border_color=self.border(),
                                          text_color=self.text(),
                                          font=ctk.CTkFont(family=self.ui_font_family, size=13),
                                          show="*")
            try:
                password_entry.insert(0, str(get_active_config().get("password") or ""))
            except Exception:
                pass
            password_entry.pack(side="right", fill="x", expand=True)

            def confirm_manual():
                host = str(ip_entry.get()).strip()
                try:
                    port = int(str(port_entry.get()).strip() or 3306)
                except Exception:
                    port = 0
                user = str(user_entry.get()).strip() or "root"
                password = str(password_entry.get())
                if not host:
                    self.toast(self.t("أدخل عنوان IP للجهاز الرئيسي"), "danger")
                    return
                if not (0 < port < 65536):
                    self.toast(self.t("المنفذ يجب أن يكون رقمًا صحيحًا بين 1 و 65535"), "danger")
                    return
                render_searching_manual(host, port, user, password)

            btns = ctk.CTkFrame(box, fg_color="transparent")
            btns.pack(fill="x", pady=(18, 0))

            ctk.CTkButton(btns, text=self.t("اتصال يدوي"), command=confirm_manual,
                          height=46, corner_radius=10,
                          fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                          font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
                          ).pack(side="right", fill="x", expand=True, padx=(8, 0))

            ctk.CTkButton(btns, text=self.t("إعادة المحاولة"),
                          command=lambda: render_searching(),
                          height=46, corner_radius=10,
                          fg_color=self.card(), hover_color=self.border(), text_color=self.text()
                          ).pack(side="right", fill="x", expand=True, padx=(8, 0))

            ctk.CTkButton(btns, text=self.t("رجوع"), command=lambda: (clear_page(), render_choose()),
                          height=46, corner_radius=10,
                          fg_color=self.card(), hover_color=self.border(), text_color=self.text()
                          ).pack(side="left", fill="x", expand=True)

            ip_entry.focus_set()

        def render_searching_manual(host, port, user="root", password=""):
            clear_page()
            subtitle_label.configure(text="")
            box = ctk.CTkFrame(page, fg_color="transparent")
            box.pack(expand=True)
            lbl = ctk.CTkLabel(box, text=f"🔍 {self.t('جاري الاتصال ب')} {host}:{port}",
                               text_color=self.text(),
                               font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"))
            lbl.pack(pady=90)
            animate_dots(f"{self.t('جاري الاتصال ب')} {host}:{port}", lbl)

            def worker():
                candidate = {**dict(get_active_config()),
                             "host": host, "port": int(port),
                             "user": user, "password": password,
                             "network_mode": "client"}
                ok, message = test_database_connection(candidate, create_database=True)

                def apply():
                    if not win.winfo_exists():
                        return
                    if ok:
                        try:
                            self._fetch_real_store_name(candidate)
                        except Exception:
                            pass
                        # اعرض نافذة تأكيد المتجر ثم خطوة موافقة PC1.
                        win.destroy()
                        try:
                            self._show_store_confirmation_dialog(candidate)
                        except Exception:
                            apply_client_config(candidate, host, port)
                    else:
                        render_manual(message)

                self.after(0, apply)

            threading.Thread(target=worker, daemon=True).start()

        def apply_client(host, port):
            candidate = {
                **dict(get_active_config()),
                "host": host,
                "port": int(port),
                "user": get_active_config().get("user") or "root",
                "password": get_active_config().get("password") or "Islem2002@",
                "database": get_active_config().get("database") or "supermarket_pro",
                "network_mode": "client",
            }
            try:
                self._fetch_real_store_name(candidate)
            except Exception:
                pass
            print(f"[DISCOVERY-DEBUG] Testing DB connection to {host}:{port} with config: {candidate}")
            ok, message = test_database_connection(candidate, create_database=False)
            if ok:
                print(f"[DISCOVERY-DEBUG] DB test SUCCEEDED for {host}")
                # لا نتصل مباشرة بل نُظهر نافذة تأكيد المتجر (مثل اكتشاف الخادم)
                # ليعتمد المستخدم الاقتران ويُفتح خطوة موافقة PC1.
                def _confirm():
                    try:
                        win.destroy()
                    except Exception:
                        pass
                    try:
                        self._show_store_confirmation_dialog(candidate)
                    except Exception:
                        apply_client_config(candidate, host, port)
                if win.winfo_exists():
                    self.after(0, _confirm)
                else:
                    try:
                        self._show_store_confirmation_dialog(candidate)
                    except Exception:
                        apply_client_config(candidate, host, port)
            else:
                print(f"[DISCOVERY-DEBUG] DB test FAILED for {host}. Exact error message: {message}")
                render_manual(message)

        def apply_client_config(candidate, host, port):
            set_active_config(candidate)
            self.log_action("network_mode_set", "settings", None, f"client • {host}:{port}")
            self.toast(f"✓ {self.t('تم الاتصال بالجهاز الرئيسي')} ({host})")
            self._register_paired_device()
            finish_setup(win)

        def finish_setup(target_win):
            target_win.destroy()
            self._after_network_mode_applied()
            if callable(on_done):
                try:
                    on_done()
                except Exception:
                    pass

        # في الإعداد الإلزامي (أول تشغيل / تعذّر الاتصال) لا يمكن إغلاق
        # المعالج قبل التحقق من اتصال يعمل؛ أما من الإعدادات فهو اختياري
        # ويُستأنف التشغيل بالإعداد الحالي عند الإغلاق.
        if mandatory:
            win.protocol("WM_DELETE_WINDOW", lambda: None)
        else:
            win.protocol("WM_DELETE_WINDOW", lambda: finish_setup(win))

        # وضع إعادة الاتصال: على جهاز إضافي مُهيّأ مسبقًا نبدأ بالبحث الذاتي.
        try:
            current_mode = str(get_active_config().get("network_mode") or "").strip().lower()
        except Exception:
            current_mode = ""
        if start_action == "reconnect" and current_mode == "client":
            render_searching()
        else:
            render_choose()
        win.grab_set()
        win.wait_window()

    def _after_network_mode_applied(self):
        """بعد تطبيق وضع الشبكة: تشغيل المستجيب/التأكد من المخطط/تحديث المؤشر."""
        try:
            self._start_discovery_responder_if_needed()
            self.db.ensure_server_and_database()
            self.db.create_tables()
        except Exception:
            pass
        try:
            threading.Thread(target=self._conn_check_once, daemon=True).start()
        except Exception:
            pass

    def _toggle_network_mode_from_settings(self):
        if not self.require_pin(self.t("تغيير وضع الشبكة"), "admin"):
            return
        self._open_network_setup_window(mandatory=False, on_done=None)

    # -----------------------------------------------------
    # مؤشر حالة الاتصال بالخادم
    # -----------------------------------------------------

    def _start_conn_monitor(self):
        if getattr(self, "_conn_monitor_started", False):
            return
        self._conn_monitor_started = True
        threading.Thread(target=self._conn_worker_loop, name="ConnMonitor", daemon=True).start()
        self.after(700, self._poll_conn_state)

    def _conn_check_once(self):
        """فحص واحد لقابلية الوصول إلى قاعدة البيانات.
        على جهاز إضافي (client) عند فشل الاتصال بالخادم المخزّن (مثل تغيّر
        عنوان IP الخاص به) نُطلق تلقائيًا دورة شفاء ذاتي عبر اكتشاف UDP،
        دون أي تدخل أو طلب إدخال عنوان من المستخدم."""
        try:
            conn = self.db.get_connection()
            cur = conn.cursor()
            cur.execute("SELECT 1")
            conn.close()
            self._conn_state_box["up"] = True
            return True
        except Exception:
            self._conn_state_box["up"] = False
            try:
                mode = str(get_active_config().get("network_mode") or "").strip().lower()
            except Exception:
                mode = ""
            if mode == "client":
                self._try_auto_heal()
            return False

    def _conn_worker_loop(self):
        import time
        while True:
            self._conn_check_once()
            time.sleep(18)

    def _try_auto_heal(self):
        """شفاء ذاتي: اكتشاف الجهاز الرئيسي عبر UDP وتحديث المضيف بصمت.

        أثناء التشغيل العادي (self._data_ready = True) لا نُظهر أي نافذة
        modal — نكتفي بتحديث مؤشر شريط الحالة العلوي (⟳ جاري إعادة الاتصال/
        ● غير متصل بالخادم). تُعرض النافذة المرئية فقط في طور الإقلاع
        (_startup_self_heal_or_wizard) عندما يتعذّر بدء التطبيق بلا قاعدة
        بيانات. عند إيجاد خادم مطابق هويةً وقابل للوصول يُحدَّث
        config/db_config.json ثم تُعاد الاتصال، وإن فشل الشفاء نُحدِّث الحالة."""
        if getattr(self, "_heal_in_progress", False):
            return
        self._heal_in_progress = True
        # نُشير فقط في القاموس المشترك بحالة "جاري إعادة الاتصال"، ويدير
        # مؤشر الواجهة (على خيط الواجهة الرئيسي) عرضَ التغييرات عبر _poll_conn_state
        self._conn_state_box["healing"] = True
        self._apply_conn_status(False, reconnecting=True)

        # نافذة modal فقط في طور الإقلاع (قبل اكتمال data_ready)، وليس أثناء
        # الفحوصات الخلفية الدورية حتى لا تتكدّس النوافذ.
        _modal_holder = {"dialog": None, "state": None}
        if not getattr(self, "_data_ready", False):
            # منشئ النافذة (المُستدعى من أي خيط). يُنشئ النافذة عبر after(0) على
            # خيط الواجهة الرئيسية ويُعيد حاملًا نربط به close_fn لاحقًا.
            try:
                self.after(0, lambda: self._spawn_reconnect_modal(_modal_holder))
            except Exception:
                pass

        def worker():
            try:
                from utils.network_discovery import discover_server
                import time
                # [DIAG] مؤقت — يُسجَّل بداية دورة الشفاء الذاتي عبر المراقب.
                
                # مسار سريع: نفحص عنوان الخادم المخزَّن حاليًا أولًا (لو ما زال
                # متاحًا) قبل بثّ UDP — يوفّر الثواني ويعمل حتى لو تغيّرت الشبكة.
                cur_cfg = dict(get_active_config())
                cached_host = str(cur_cfg.get("host") or "").strip()
                try:
                    cached_port = int(cur_cfg.get("port") or 3306)
                except Exception:
                    cached_port = 3306
                # عدة محاولات خلال المدة المعقولة (شفاء ذاتي مستمر)
                deadline = time.time() + 6.0
                healed = False
                while time.time() < deadline and not healed:
                    if cached_host and not str(cached_host).lower() in ("localhost", "127.0.0.1"):
                        found = discover_server(2.0, cached_host=cached_host, cached_port=cached_port)
                    else:
                        found = discover_server(3.0)
                    
                    if found:
                        try:
                            port = int(found.get("port") or 3306)
                        except Exception:
                            port = 3306
                        host = str(found.get("host") or "")
                        # جلب اسم المتجر الحقيقي من الخادم البعيد (لا يعتمد
                        # على القيمة الافتراضية "Supermarket Pro" من TCP sweep).
                        try:
                            self._fetch_real_store_name(found)
                        except Exception:
                            pass
                        store = str(found.get("store_name") or "").strip()
                        current_store = self._current_store_name().strip()
                        # تطابق هوية التطبيق/المتجر: لا نتصل بخادم MySQL غريب.
                        # نتجنّب الرفض إذا كان store الافتراضي (لم يُجلب اسم حقيقي).
                        if (store and current_store
                                and store != "Supermarket Pro"
                                and store != current_store):
                            found = None
                            time.sleep(1.0)
                            continue
                        candidate = {**dict(get_active_config()),
                                     "host": host, "port": port,
                                     "network_mode": "client"}
                        ok, _msg = test_database_connection(candidate, create_database=True)
                        if ok:
                            set_active_config(candidate)
                            healed = True
                            break
                    time.sleep(1.0)
            except Exception:
                healed = False
            finally:
                self._heal_in_progress = False
                self._conn_state_box["healing"] = False
                self._conn_state_box["up"] = bool(healed)

                def finish_heal():
                    st = _modal_holder.get("state")
                    if st is not None and st.get("active"):
                        try:
                            st["active"] = False
                            dlg = _modal_holder.get("dialog")
                            if dlg is not None:
                                dlg.destroy()
                            if self._reconnect_dialog is dlg:
                                self._reconnect_dialog = None
                        except Exception:
                            pass
                    if healed:
                        try:
                            self.toast("✓ " + self.t("تم استعادة الاتصال بالجهاز الرئيسي"))
                        except Exception:
                            pass
                        self._apply_conn_status(True, reconnecting=False)
                    else:
                        if getattr(self, "_data_ready", False):
                            # أثناء التشغيل العادي لا نفتح معالجًا ولا نافذة؛
                            # نكتفي بتحديث مؤشر شريط الحالة.
                            self._apply_conn_status(False)
                        else:
                            # طور الإقلاع فقط: انتهت مهلة الشفاء دون نجاح، افتح
                            # المعالج اليدوي كملاذ أخير.
                            try:
                                self._open_network_setup_window(
                                    mandatory=True,
                                    on_done=self._finalize_startup,
                                    start_action="reconnect",
                                )
                            except Exception:
                                pass
                    # نُحدّث واجهة المستخدم على خيط الواجهة الرئيسي
                    self._poll_conn_state()
                try:
                    self.after(0, finish_heal)
                except Exception:
                    pass

        threading.Thread(target=worker, daemon=True).start()

    def _poll_conn_state(self):
        try:
            healing = self._conn_state_box.get("healing", False)
            prev_healing = getattr(self, "_conn_last_healing", False)
            self._conn_last_healing = healing
            up = self._conn_state_box.get("up")
            prev = getattr(self, "_conn_last_up", None)
            if healing and up is not True:
                # أثناء إعادة الاتصال: مؤشر أصفر "جاري إعادة الاتصال"
                self._apply_conn_status(False, reconnecting=True)
            elif prev_healing and not healing and up is False:
                # انتهت محاولة الشفاء دون نجاح: نُظهر "غير متصل بالخادم"
                self._apply_conn_status(False)
            elif up is not None and up != prev:
                self._apply_conn_status(up)
                if prev is True and up is False:
                    self.toast(self.t("⚠ انقطع الاتصال بالخادم"), "danger")
                elif prev is False and up is True:
                    self.toast(self.t("✓ تم استعادة الاتصال بالخادم"))
                self._conn_last_up = up
        except Exception:
            pass
        finally:
            try:
                self.after(2000, self._poll_conn_state)
            except Exception:
                pass

    def _apply_conn_status(self, up, reconnecting=False):
        self._conn_last_up = up
        if hasattr(self, "conn_status_label"):
            try:
                if reconnecting:
                    self.conn_status_label.configure(
                        text="⟳ " + self.t("جاري إعادة الاتصال"),
                        text_color=self.colors["accent"]
                    )
                elif up:
                    self.conn_status_label.configure(
                        text="● " + self.t("متصل"),
                        text_color=self.colors["secondary"]
                    )
                else:
                    self.conn_status_label.configure(
                        text="● " + self.t("غير متصل بالخادم"),
                        text_color=self.colors["danger"]
                    )
            except Exception:
                pass

    def _get_returned_quantity(self, invoice_number, product_id):
        conn = None
        try:
            conn = self.db.get_connection()
            row = conn.execute("""SELECT COALESCE(SUM(ri.quantity),0)
                FROM return_items ri JOIN returns r ON r.id=ri.return_id
                WHERE r.invoice_number=? AND ri.product_id=?""", (invoice_number, product_id)).fetchone()
            return float(row[0] or 0)
        except Exception:
            return 0.0
        finally:
            if conn: conn.close()


    def show_independent_return_dialog(self):
        """إرجاع منتج مستقل بدون فاتورة، مع Footer ثابت للأزرار."""
        import tkinter as tk
        from tkinter import messagebox

        win=ctk.CTkToplevel(self)
        win.title(self.t("↩ إرجاع منتج"))
        win.geometry("980x760")
        win.minsize(900,680)
        win.transient(self)
        win.grab_set()
        try: self.center_window(win,980,760)
        except Exception: pass

        win.grid_rowconfigure(0,weight=1)
        win.grid_rowconfigure(1,weight=0)
        win.grid_columnconfigure(0,weight=1)

        body=ctk.CTkFrame(win,fg_color=self.card(),corner_radius=14,border_width=1,border_color=self.border())
        body.grid(row=0,column=0,sticky="nsew",padx=18,pady=(18,8))
        body.grid_columnconfigure(0,weight=1)

        footer=ctk.CTkFrame(win,fg_color=self.card(),corner_radius=14,border_width=1,border_color=self.border(),height=82)
        footer.grid(row=1,column=0,sticky="ew",padx=18,pady=(0,18))
        footer.grid_propagate(False)
        footer.grid_columnconfigure(0,weight=1)
        footer.grid_columnconfigure(1,weight=1)

        ctk.CTkLabel(body,text=self.t("↩ إرجاع منتج"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=24,weight="bold")).pack(fill="x",padx=22,pady=(18,2))
        ctk.CTkLabel(body,text=self.t("أعد منتجًا بشكل مستقل دون إدخال رقم فاتورة."),anchor="e",text_color=self.muted(),font=ctk.CTkFont(family=self.ui_font_family,size=11)).pack(fill="x",padx=22,pady=(0,12))

        search_var=tk.StringVar()
        ctk.CTkLabel(body,text=self.t("البحث عن المنتج"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold")).pack(fill="x",padx=22,pady=(0,4))
        search=ctk.CTkEntry(body,textvariable=search_var,height=48,placeholder_text=self.t("ابحث باسم المنتج أو الباركود..."),font=ctk.CTkFont(family=self.ui_font_family,size=14))
        search.pack(fill="x",padx=22,pady=(0,8))

        results=ctk.CTkScrollableFrame(body,height=125)
        results.pack(fill="x",padx=22,pady=(0,8))
        selected={"row":None}

        ctk.CTkLabel(body,text=self.t("المنتج المحدد"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold")).pack(fill="x",padx=22,pady=(2,2))
        product_label=ctk.CTkLabel(body,text=self.t("لم يتم اختيار منتج"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=16,weight="bold"))
        product_label.pack(fill="x",padx=22)
        details_label=ctk.CTkLabel(body,text="",anchor="e",text_color=self.muted(),font=ctk.CTkFont(family=self.ui_font_family,size=11))
        details_label.pack(fill="x",padx=22,pady=(0,5))

        ctk.CTkLabel(body,text=self.t("طريقة الإرجاع"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold")).pack(fill="x",padx=22,pady=(3,2))
        mode_row=ctk.CTkFrame(body,fg_color="transparent")
        mode_row.pack(fill="x",padx=22,pady=2)
        mode=tk.StringVar(value="quantity")
        ctk.CTkRadioButton(mode_row,text=self.t("الكمية / الوزن"),variable=mode,value="quantity").pack(side="right",padx=10)
        ctk.CTkRadioButton(mode_row,text=self.t("المبلغ"),variable=mode,value="amount").pack(side="right",padx=10)

        ctk.CTkLabel(body,text=self.t("الكمية / الوزن / المبلغ"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold")).pack(fill="x",padx=22,pady=(5,3))
        value_entry=ctk.CTkEntry(body,height=48,placeholder_text=self.t("أدخل الكمية أو الوزن أو المبلغ"),font=ctk.CTkFont(family=self.ui_font_family,size=15,weight="bold"))
        value_entry.insert(0,"1")
        value_entry.pack(fill="x",padx=22,pady=3)
        result_label=ctk.CTkLabel(body,text=self.t("قيمة المرتجع: 0.00 دج"),anchor="e",text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold"))
        result_label.pack(fill="x",padx=22,pady=3)

        def clear_results():
            for w in results.winfo_children(): w.destroy()

        def load_products(*_):
            clear_results(); term=search_var.get().strip()
            if not term: return
            conn=None
            try:
                conn=self.db.get_connection()
                rows=conn.execute("""SELECT id,barcode,name,price,quantity,unit FROM products WHERE name LIKE ? OR barcode LIKE ? ORDER BY name LIMIT 20""",(f"%{term}%",f"%{term}%")).fetchall()
            except Exception: rows=[]
            finally:
                if conn: conn.close()
            for row in rows:
                def choose(r=row):
                    selected["row"]=r
                    product_label.configure(text=self.t(f"المنتج: {r[2]}"))
                    details_label.configure(text=self.t(f"السعر: {float(r[3] or 0):,.2f} دج / {r[5] or 'قطعة'}  •  المخزون الحالي: {float(r[4] or 0):g}"))
                    value_entry.delete(0,"end"); value_entry.insert(0,"1")
                    result_label.configure(text=self.t("قيمة المرتجع: 0.00 دج"))
                    clear_results(); value_entry.focus_set()
                ctk.CTkButton(results,text=self.t(f"{row[2]}  | {float(row[3] or 0):,.2f} دج | {row[5] or 'قطعة'}"),anchor="e",height=38,command=choose).pack(fill="x",padx=5,pady=3)

        def calculate(*_):
            row=selected["row"]
            if not row: return
            try:
                v=float(value_entry.get().replace(",",".").strip())
                if v<=0: raise ValueError
                price=float(row[3] or 0)
                if mode.get()=="amount":
                    if price<=0: raise ValueError
                    qty,amount=v/price,v
                else: qty,amount=v,v*price
                result_label.configure(text=self.t(f"الكمية: {qty:g} {row[5] or 'قطعة'}   •   قيمة المرتجع: {amount:,.2f} دج"))
            except Exception: result_label.configure(text=self.t("قيمة المرتجع: 0.00 دج"))

        def confirm():
            row=selected["row"]
            if not row:
                messagebox.showwarning(self.t("إرجاع منتج"),self.t("اختر المنتج أولاً."),parent=win); return
            try:
                v=float(value_entry.get().replace(",",".").strip())
                if v<=0: raise ValueError
                pid,barcode,name,price,stock,unit=row; price=float(price or 0); unit=str(unit or "قطعة")
                if mode.get()=="amount":
                    if price<=0: raise ValueError
                    qty,amount=v/price,v
                else: qty,amount=v,v*price
                if unit.lower() in {"قطعة","piece","pieces","unit","units"} and abs(qty-round(qty))>1e-9:
                    messagebox.showwarning(self.t("إرجاع منتج"),self.t("المنتج يباع بالقطعة، أدخل عددًا صحيحًا."),parent=win); return
                if not messagebox.askyesno(self.t("تأكيد الإرجاع"),self.t(f"إرجاع {qty:g} {unit} من {name}؟\nقيمة المرتجع: {amount:,.2f} دج"),parent=win): return
                conn=None
                try:
                    conn=self.db.get_connection(); conn.execute("BEGIN")
                    ref="DIRECT-RETURN-"+datetime.now().strftime("%Y%m%d%H%M%S%f")
                    cur=conn.execute("""INSERT INTO returns (invoice_number,sale_id,customer_id,total_amount,device_name,note) VALUES (?,NULL,NULL,?,?,?)""",(ref,amount,self._get_device_name(),"مرتجع منتج مستقل"))
                    return_id=cur.lastrowid
                    conn.execute("""INSERT INTO return_items (return_id,product_id,quantity,price,total) VALUES (?,?,?,?,?)""",(return_id,pid,qty,price,amount))
                    conn.execute("UPDATE products SET quantity=COALESCE(quantity,0)+? WHERE id=?",(qty,pid)); conn.commit()
                except Exception:
                    if conn: conn.rollback()
                    raise
                finally:
                    if conn: conn.close()
                self.log_action("return_registered", "product", pid,
                                f"{name} × {qty:g} • {amount:,.2f} دج")
                self.toast(f"تم إرجاع {qty:g} {unit} من {name} وإضافتها للمخزون","success"); win.destroy()
                try:
                    if getattr(self,"current_page","")=="inventory": self.show_inventory()
                    elif getattr(self,"current_page","")=="pos": self.show_pos()
                except Exception: pass
            except Exception as exc: messagebox.showerror(self.t("خطأ في الإرجاع"),str(exc),parent=win)

        search_var.trace_add("write",load_products)
        value_entry.bind("<KeyRelease>",calculate); mode.trace_add("write",calculate)

        # Footer مستقل عن المحتوى، لذلك الأزرار لا تختفي أبداً.
        cancel_btn=ctk.CTkButton(footer,text=self.t("إلغاء"),height=54,corner_radius=12,fg_color=self.border(),hover_color=self.colors.get("border_light",self.border()),text_color=self.text(),command=win.destroy,font=ctk.CTkFont(family=self.ui_font_family,size=13,weight="bold"))
        cancel_btn.grid(row=0,column=0,sticky="ew",padx=(14,7),pady=14)
        confirm_btn=ctk.CTkButton(footer,text=self.t("✓ تأكيد الإرجاع"),height=54,corner_radius=12,fg_color=self.colors.get("success",self.colors.get("secondary","#22C55E")),hover_color=self.colors.get("success_hover",self.colors.get("secondary_hover","#16A34A")),text_color="white",command=confirm,font=ctk.CTkFont(family=self.ui_font_family,size=13,weight="bold"))
        confirm_btn.grid(row=0,column=1,sticky="ew",padx=(7,14),pady=14)
        win.after(250, lambda: self._focus_if_alive(search, force=True, icursor="end"))

    def show_return_dialog(self):
        """تسجيل مرتجع من فاتورة وإضافة الكمية إلى المخزون."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("↩ مرتجع بيع"))
        win.geometry("760x590")
        win.minsize(680, 540)
        win.transient(self); win.grab_set(); self.center_window(win,760,590)
        frame=self.make_card(win); frame.pack(fill="both",expand=True,padx=18,pady=18)
        ctk.CTkLabel(frame,text=self.t("إرجاع منتج"),text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=20,weight="bold")).pack(anchor="e",padx=18,pady=(16,3))
        ctk.CTkLabel(frame,text=self.t("أدخل رقم الفاتورة واختر المنتج والكمية المرتجعة."),text_color=self.muted(),font=ctk.CTkFont(family=self.ui_font_family,size=10)).pack(anchor="e",padx=18,pady=(0,12))
        row=ctk.CTkFrame(frame,fg_color="transparent"); row.pack(fill="x",padx=18,pady=5)
        invoice_var=tk.StringVar(); entry=ctk.CTkEntry(row,textvariable=invoice_var,height=38,placeholder_text=self.t("رقم الفاتورة")); entry.pack(side="right",fill="x",expand=True,padx=(8,0))
        load_btn=ctk.CTkButton(row,text=self.t("تحميل"),width=90,height=38); load_btn.pack(side="right")
        item_box=ctk.CTkComboBox(frame,values=[self.t("أدخل رقم الفاتورة أولاً")],state="readonly",height=38); item_box.pack(fill="x",padx=18,pady=8)
        qty_var=tk.StringVar(value="1")
        qrow=ctk.CTkFrame(frame,fg_color="transparent"); qrow.pack(fill="x",padx=18,pady=8)
        ctk.CTkLabel(qrow,text=self.t("الكمية المرتجعة"),text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=11,weight="bold")).pack(side="right",padx=(10,0))
        qty=ctk.CTkEntry(qrow,textvariable=qty_var,width=180,height=38); qty.pack(side="right")
        info=ctk.CTkLabel(frame,text="",text_color=self.muted(),font=ctk.CTkFont(family=self.ui_font_family,size=10)); info.pack(anchor="e",padx=18,pady=8)
        data={"sale":None,"items":[]}
        def load_invoice():
            number=invoice_var.get().strip()
            if not number: self.toast("أدخل رقم الفاتورة","warning"); return
            conn=None
            try:
                conn=self.db.get_connection()
                sale=conn.execute("SELECT id,invoice_number,customer_id,total,discount,paid_amount FROM sales WHERE invoice_number=?",(number,)).fetchone()
                if not sale: self.toast("الفاتورة غير موجودة","danger"); return
                rows=conn.execute("""SELECT si.product_id,COALESCE(p.name,'منتج محذوف'),si.quantity,si.price,si.total,COALESCE(p.unit,'قطعة')
                    FROM sale_items si LEFT JOIN products p ON p.id=si.product_id WHERE si.sale_id=? AND si.product_id IS NOT NULL ORDER BY si.id""",(sale[0],)).fetchall()
            except Exception as exc: self.toast(f"تعذر تحميل الفاتورة: {exc}","danger"); return
            finally:
                if conn: conn.close()
            available=[]
            for r in rows:
                rem=float(r[2] or 0)-self._get_returned_quantity(number,r[0])
                if rem>0.000001: available.append((r,rem))
            if not available: self.toast("لا توجد كميات قابلة للإرجاع في هذه الفاتورة","warning"); return
            data["sale"]=sale; data["items"]=available
            labels=[self.t(f"{r[1]} — المتاح {rem:g} {r[5]} — {float(r[3] or 0):,.2f} دج") for r,rem in available]
            item_box.configure(values=labels); item_box.set(labels[0]); update_info()
        def update_info(*_):
            if not data["items"]: return
            sel=item_box.get(); i=next((i for i,(r,rem) in enumerate(data["items"]) if sel.startswith(str(r[1])+" —")),0)
            r,rem=data["items"][i]; qty_var.set(str(min(1.0,rem)).rstrip('0').rstrip('.') if rem!=1 else '1')
            info.configure(text=self.t(f"السعر: {float(r[3] or 0):,.2f} دج / {r[5]}   •   المتاح للإرجاع: {rem:g} {r[5]}"))
        item_box.configure(command=update_info)
        def do_return():
            if not data["sale"] or not data["items"]: self.toast("حمّل فاتورة أولاً","warning"); return
            sel=item_box.get(); i=next((i for i,(r,rem) in enumerate(data["items"]) if sel.startswith(str(r[1])+" —")),None)
            if i is None: self.toast("اختر المنتج","warning"); return
            r,max_qty=data["items"][i]
            try: q=float(qty_var.get().replace(',','.'))
            except Exception: self.toast("أدخل كمية صحيحة","danger"); return
            if q<=0 or q>max_qty+1e-9: self.toast(f"الكمية يجب ألا تتجاوز {max_qty:g} {r[5]}","warning"); return
            amount=q*float(r[3] or 0)
            if not messagebox.askyesno(self.t("تأكيد المرتجع"),self.t(f"إرجاع {q:g} {r[5]} من {r[1]} بقيمة {amount:,.2f} دج؟")): return
            conn=None
            try:
                conn=self.db.get_connection(); conn.execute("BEGIN")
                cur=conn.execute("INSERT INTO returns(invoice_number,sale_id,customer_id,total_amount,device_name,note) VALUES(?,?,?,?,?,?)",(data["sale"][1],data["sale"][0],data["sale"][2],amount,self._get_device_name(),"مرتجع بيع"))
                conn.execute("INSERT INTO return_items(return_id,product_id,quantity,price,total) VALUES(?,?,?,?,?)",(cur.lastrowid,r[0],q,float(r[3] or 0),amount))
                conn.execute("UPDATE products SET quantity=quantity+? WHERE id=?",(q,r[0]))
                customer_id=int(data["sale"][2] or 0); due=max(0.0,float(data["sale"][3] or 0)-float(data["sale"][5] or 0))
                if customer_id>0 and due>0: conn.execute("UPDATE customers SET balance=GREATEST(0,COALESCE(balance,0)-?) WHERE id=?",(min(amount,due),customer_id))
                conn.commit()
            except Exception as exc:
                if conn: conn.rollback()
                self.toast(f"فشل تسجيل المرتجع: {exc}","danger"); return
            finally:
                if conn: conn.close()
            self.log_action("return_registered", "invoice", data["sale"][0],
                            f"{data['sale'][1]} • {r[1]} × {q:g} • {amount:,.2f} دج")
            self.toast(f"تم المرتجع وإضافة {q:g} {r[5]} إلى المخزون","success"); win.destroy()
            if self.current_page=="inventory": self.show_inventory()
            if self.current_page=="reports": self.load_report(getattr(self,"active_report_period","اليوم"))
        load_btn.configure(command=load_invoice)
        buttons=ctk.CTkFrame(frame,fg_color="transparent"); buttons.pack(fill="x",padx=18,pady=(20,18))
        ctk.CTkButton(buttons,text=self.t("إلغاء"),width=110,height=40,command=win.destroy,fg_color=self.card(),hover_color=self.border(),text_color=self.text()).pack(side="left")
        ctk.CTkButton(buttons,text=self.t("↩ تسجيل المرتجع"),width=160,height=40,command=do_return,fg_color=self.colors["danger"],hover_color=self.colors.get("danger_hover",self.colors["danger"])).pack(side="right")
        entry.focus_set()

    def _ensure_profit_schema(self):
        """تهيئة تكلفة البيع حتى يمكن حساب الربح بدقة للمبيعات الجديدة."""
        conn = None
        try:
            conn = self.db.get_connection()
            cols = [r[1] for r in conn.execute("PRAGMA table_info(sale_items)").fetchall()]
            if "cost" not in cols:
                conn.execute("ALTER TABLE sale_items ADD COLUMN cost REAL DEFAULT 0")
                conn.commit()
        except Exception:
            pass
        finally:
            if conn:
                conn.close()

    def _capture_sale_costs(self, invoice_number):
        """يحفظ تكلفة المنتج وقت البيع في sale_items دون تغيير منطق SalesManager."""
        conn = None
        try:
            conn = self.db.get_connection()
            rows = conn.execute("""
                SELECT si.id, si.product_id, COALESCE(p.cost, 0)
                FROM sale_items si
                LEFT JOIN products p ON p.id = si.product_id
                JOIN sales s ON s.id = si.sale_id
                WHERE s.invoice_number = ?
            """, (invoice_number,)).fetchall()
            for row in rows:
                conn.execute("UPDATE sale_items SET cost = ? WHERE id = ?", (float(row[2] or 0), row[0]))
            conn.commit()
        except Exception:
            pass
        finally:
            if conn:
                conn.close()

    def _get_profit_data(self, days=30, device_name=None):
        """يعيد المبيعات والتكلفة والربح للفترة. الخصم محسوب قبل الربح.

        device_name: إن حُدد، تُحتسب المرتجعات من هذا الجهاز فقط
        (يُستخدم لتقارير الجهاز في وضع العميل). إن كان None تُحتسب كل المرتجعات.
        """
        conn = None
        try:
            conn = self.db.get_connection()
            rows = conn.execute("""
                SELECT s.sale_date, s.invoice_number, s.total, s.discount,
                       COALESCE(SUM(si.quantity * COALESCE(si.cost, p.cost, 0)), 0) AS cost_total
                FROM sales s
                LEFT JOIN sale_items si ON si.sale_id = s.id
                LEFT JOIN products p ON p.id = si.product_id
                WHERE DATE(s.sale_date) >= CURDATE() - INTERVAL ? DAY
                GROUP BY s.id
                ORDER BY s.sale_date DESC
            """, (int(days)-1,)).fetchall()
            sales = 0.0
            discounts = 0.0
            costs = 0.0
            for r in rows:
                sales += float(r[2] or 0)
                discounts += float(r[3] or 0)
                costs += float(r[4] or 0)
            return_total = 0.0
            try:
                if device_name:
                    rr = conn.execute("SELECT COALESCE(SUM(total_amount),0) FROM returns WHERE DATE(return_date) >= CURDATE() - INTERVAL ? DAY AND device_name = ?",(int(days)-1, device_name)).fetchone()
                else:
                    rr = conn.execute("SELECT COALESCE(SUM(total_amount),0) FROM returns WHERE DATE(return_date) >= CURDATE() - INTERVAL ? DAY",(int(days)-1,)).fetchone()
                return_total = float(rr[0] or 0)
            except Exception: pass
            net_sales = sales - discounts - return_total
            return {
                "sales": sales, "discounts": discounts, "returns": return_total, "net_sales": net_sales,
                "costs": costs, "profit": net_sales - costs, "count": len(rows),
                "rows": rows
            }
        except Exception:
            return {"sales":0,"discounts":0,"net_sales":0,"costs":0,"profit":0,"count":0,"rows":[]}
        finally:
            if conn:
                conn.close()

    def show_profit_report(self, days=30):
        self.clear_content()
        self.current_page = "profit"
        self.highlight_nav()
        self.page_header("📈 الأرباح", "تحليل الربح الحقيقي من المبيعات")

        controls = ctk.CTkFrame(self.content_area, fg_color="transparent")
        controls.pack(fill="x", pady=(0, 10))
        for label, value in [(self.t("اليوم"),1),(self.t("7 أيام"),7),(self.t("30 يوم"),30),(self.t("90 يوم"),90),(self.t("سنة"),365)]:
            ctk.CTkButton(controls, text=label, command=lambda d=value:self.show_profit_report(d),
                          height=34, width=90, corner_radius=8, fg_color=self.card(),
                          hover_color=self.border(), text_color=self.text(),
                          font=ctk.CTkFont(family=self.ui_font_family,size=10,weight="bold")
            ).pack(side="left", padx=3)

        _is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"
        _device = None if _is_server else self._get_device_name()
        data=self._get_profit_data(days, device_name=_device)
        cards=ctk.CTkFrame(self.content_area, fg_color="transparent")
        cards.pack(fill="x", pady=5)
        vals=[(self.t("إجمالي المبيعات"),data["sales"],self.colors["info"]),
              (self.t("الخصومات"),data["discounts"],self.colors["accent"]),
              (self.t("تكلفة البضاعة"),data["costs"],self.colors["danger"]),
              (self.t("صافي الربح"),data["profit"],self.colors["secondary"])]
        for i,(label,val,color) in enumerate(vals):
            cards.grid_columnconfigure(i,weight=1)
            c=self.make_card(cards); c.grid(row=0,column=i,sticky="ew",padx=4)
            ctk.CTkLabel(c,text=self.t(f"{val:,.2f} د.ج"),font=ctk.CTkFont(family=self.ui_font_family,size=18,weight="bold"),text_color=color).pack(anchor="w",padx=14,pady=(13,2))
            ctk.CTkLabel(c,text=label,font=ctk.CTkFont(family=self.ui_font_family,size=10,weight="bold"),text_color=self.text()).pack(anchor="w",padx=14,pady=(0,12))

        margin=(data["profit"]/data["net_sales"]*100) if data["net_sales"] else 0
        summary=self.make_card(self.content_area); summary.pack(fill="x",pady=8)
        ctk.CTkLabel(summary,text=self.t(f"هامش الربح: {margin:.1f}%   •   {data['count']} فاتورة   •   صافي المبيعات بعد الخصم: {data['net_sales']:,.2f} د.ج"),
                     font=ctk.CTkFont(family=self.ui_font_family,size=12,weight="bold"),text_color=self.text()).pack(anchor="w",padx=15,pady=14)

        table=self.make_card(self.content_area); table.pack(fill="both",expand=True,pady=5)
        ctk.CTkLabel(table,text=self.t("تفاصيل المبيعات والربح"),font=ctk.CTkFont(family=self.ui_font_family,size=14,weight="bold"),text_color=self.text()).pack(anchor="w",padx=15,pady=12)
        scroll=ctk.CTkScrollableFrame(table,fg_color="transparent"); scroll.pack(fill="both",expand=True,padx=8,pady=(0,8))
        if not data["rows"]:
            ctk.CTkLabel(scroll,text=self.t("لا توجد مبيعات في الفترة المحددة"),text_color=self.muted()).pack(pady=30)
        else:
            for r in data["rows"]:
                sale=float(r[2] or 0); disc=float(r[3] or 0); cost=float(r[4] or 0); profit=sale-disc-cost
                row=ctk.CTkFrame(scroll,fg_color=self.bg(),corner_radius=8); row.pack(fill="x",pady=2)
                ctk.CTkLabel(row,text=str(r[0])[:16],text_color=self.muted(),font=ctk.CTkFont(family=self.ui_font_family,size=9)).pack(side="left",padx=8,pady=9)
                ctk.CTkLabel(row,text=str(r[1]),text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=9,weight="bold")).pack(side="left",fill="x",expand=True,padx=8)
                ctk.CTkLabel(row,text=self.t(f"مبيعات {sale-disc:,.0f}"),text_color=self.text(),font=ctk.CTkFont(family=self.ui_font_family,size=9)).pack(side="right",padx=8)
                ctk.CTkLabel(row,text=self.t(f"ربح {profit:,.0f} د.ج"),text_color=self.colors["secondary"] if profit>=0 else self.colors["danger"],font=ctk.CTkFont(family=self.ui_font_family,size=9,weight="bold")).pack(side="right",padx=8)

    # =========================================================
    # Dashboard
    # =========================================================

    def show_dashboard(self):
        """V24 — لوحة تحكم احترافية تعتمد على البيانات الحقيقية الموجودة في النظام."""
        if not self._guard_db_nav("لوحة التحكم", "نظرة سريعة على أداء المتجر", "dashboard"):
            return
        self.clear_content()
        self.current_page = "dashboard"
        self.highlight_nav()

        # نجلب البيانات من الـManagers الحالية فقط، حتى لا نكسر أي جزء من النظام.
        try:
            stats = self.reports_manager.get_dashboard_stats()
        except Exception:
            stats = {
                "total_products": 0, "total_stock_value": 0, "today_sales": 0,
                "today_sales_count": 0, "total_customers": 0,
                "low_stock_count": 0, "debt_customers_count": 0
            }

        try:
            inv_stats = self.inventory_manager.get_stats()
        except Exception:
            inv_stats = {"total": 0, "out": 0, "low": 0, "expiring": 0}

        try:
            today_summary = self.reports_manager.get_sales_summary("today")
        except Exception:
            today_summary = {"total": 0, "count": 0, "average": 0, "max": 0, "min": 0}

        try:
            top_products = self.reports_manager.get_top_products(5)
        except Exception:
            top_products = []

        self.page_header("لوحة التحكم", "نظرة سريعة وواضحة على أداء المتجر")

        # =====================================================
        # شريط الترحيب + الإجراءات السريعة
        # =====================================================
        top = ctk.CTkFrame(self.content_area, fg_color="transparent")
        top.pack(fill="x", pady=(0, 10))

        welcome = self.make_card(top)
        welcome.pack(side="left", fill="both", expand=True, padx=(0, 6))

        ctk.CTkLabel(
            welcome, text=self.t("مرحبًا بك 👋"),
            font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", padx=18, pady=(16, 2))

        ctk.CTkLabel(
            welcome,
            text=self.t(f"اليوم: {datetime.now().strftime('%Y-%m-%d')}  •  {today_summary.get('count', 0)} عملية بيع"),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(anchor="w", padx=18)

        ctk.CTkButton(
            welcome, text=self.t("فتح نقطة البيع  →"), command=self.show_pos,
            height=36, width=145, corner_radius=9,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(anchor="w", padx=18, pady=12)

        quick = self.make_card(top, width=230)
        quick.pack(side="right", fill="y", padx=(6, 0))
        quick.pack_propagate(False)
        ctk.CTkLabel(
            quick, text=self.t("إجراءات سريعة"),
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", padx=14, pady=(13, 6))

        for txt, cmd in [
            (self.t("＋ منتج جديد"), self.show_add_product_form),
            (self.t("＋ زبون جديد"), self.show_add_customer_form),
            (self.t("📦 فتح المخزون"), self.show_inventory),
            (self.t("⟳ تحديث البيانات"), self.show_dashboard),
        ]:
            ctk.CTkButton(
                quick, text=txt, command=cmd, height=30, corner_radius=8,
                fg_color=self.bg(), hover_color=self.border(),
                text_color=self.text(), anchor="w",
                font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
            ).pack(fill="x", padx=10, pady=3)

        # =====================================================
        # بطاقات KPI
        # =====================================================
        stats_frame = ctk.CTkFrame(self.content_area, fg_color="transparent")
        stats_frame.pack(fill="x", pady=5)

        debt_total = 0.0
        try:
            debt_customers = self.reports_manager.get_customers_with_debt()
            debt_total = sum(float(c[3] or 0) for c in debt_customers)
        except Exception:
            pass

        cards = [
            (self.t("مبيعات اليوم"), self.t(f"{float(today_summary.get('total', stats.get('today_sales', 0)) or 0):,.0f} د.ج"),
             self.t(f"{today_summary.get('count', 0)} فاتورة"), self.colors["secondary"]),
            (self.t("متوسط الفاتورة"), self.t(f"{float(today_summary.get('average', 0) or 0):,.0f} د.ج"),
             self.t("متوسط مبيعات اليوم"), self.colors["info"]),
            (self.t("إجمالي الديون"), self.t(f"{debt_total:,.0f} د.ج"),
             self.t(f"{len(debt_customers) if 'debt_customers' in locals() else 0} زبون"), self.colors["danger"]),
            (self.t("قيمة المخزون"), self.t(f"{float(stats.get('total_stock_value', 0) or 0):,.0f} د.ج"),
             self.t(f"{stats.get('total_products', 0)} منتج"), self.colors["primary"]),
        ]

        for i, (label, value, sub, color) in enumerate(cards):
            stats_frame.grid_columnconfigure(i, weight=1)
            card = self.make_card(stats_frame)
            card.grid(row=0, column=i, sticky="nsew", padx=4)
            ctk.CTkLabel(
                card, text=value,
                font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold"),
                text_color=color
            ).pack(anchor="w", padx=15, pady=(14, 1))
            ctk.CTkLabel(
                card, text=label,
                font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                text_color=self.text()
            ).pack(anchor="w", padx=15)
            ctk.CTkLabel(
                card, text=sub,
                font=ctk.CTkFont(family=self.ui_font_family, size=9),
                text_color=self.muted()
            ).pack(anchor="w", padx=15, pady=(2, 12))

        # =====================================================
        # الحالة السريعة للمخزون
        # =====================================================
        inventory_strip = ctk.CTkFrame(self.content_area, fg_color="transparent")
        inventory_strip.pack(fill="x", pady=(4, 6))
        inv_cards = [
            (self.t("📦 المنتجات"), inv_stats.get("total", stats.get("total_products", 0)), self.colors["info"]),
            (self.t("🔴 نافد"), inv_stats.get("out", 0), self.colors["danger"]),
            (self.t("🟠 منخفض"), inv_stats.get("low", stats.get("low_stock_count", 0)), self.colors["accent"]),
            (self.t("🟡 قريب الانتهاء"), inv_stats.get("expiring", 0), self.colors["accent"]),
        ]
        for i, (label, value, color) in enumerate(inv_cards):
            inventory_strip.grid_columnconfigure(i, weight=1)
            box = ctk.CTkFrame(inventory_strip, fg_color=self.card(), corner_radius=10,
                               border_width=1, border_color=self.border())
            box.grid(row=0, column=i, sticky="ew", padx=4)
            ctk.CTkLabel(box, text=str(value),
                         font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"),
                         text_color=color).pack(side="left", padx=12, pady=8)
            ctk.CTkLabel(box, text=label,
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                         text_color=self.text()).pack(side="right", padx=12)

        # =====================================================
        # الجزء السفلي: المبيعات + التنبيهات + الأكثر مبيعًا
        # =====================================================
        lower = ctk.CTkFrame(self.content_area, fg_color="transparent")
        lower.pack(fill="both", expand=True, pady=8)

        chart = self.make_card(lower)
        chart.pack(side="left", fill="both", expand=True, padx=(0, 6))
        ctk.CTkLabel(
            chart, text=self.t("📈 مبيعات آخر 7 أيام"),
            font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", padx=15, pady=(13, 0))
        ctk.CTkLabel(
            chart, text=self.t("إجمالي المبيعات اليومية المسجلة فعليًا"),
            font=ctk.CTkFont(family=self.ui_font_family, size=9),
            text_color=self.muted()
        ).pack(anchor="w", padx=15)
        self.draw_weekly_sales_chart(chart)

        side = self.make_card(lower, width=340)
        side.pack(side="right", fill="both", padx=(6, 0))
        side.pack_propagate(False)

        ctk.CTkLabel(
            side, text=self.t("⚠ يحتاج انتباهك"),
            font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", padx=15, pady=(13, 7))

        alerts_count = 0
        if int(inv_stats.get("out", 0) or 0):
            alerts_count += 1
            self.dashboard_alert_row(side, f"{inv_stats.get('out')} منتج نافد",
                                     "افتح المخزون لمعرفة المنتجات", self.colors["danger"], self.show_inventory)
        if int(inv_stats.get("low", stats.get("low_stock_count", 0)) or 0):
            alerts_count += 1
            self.dashboard_alert_row(side, f"{inv_stats.get('low', stats.get('low_stock_count', 0))} منتج منخفض",
                                     "يُنصح بإعادة التزويد", self.colors["accent"], self.show_inventory)
        if int(inv_stats.get("expiring", 0) or 0):
            alerts_count += 1
            self.dashboard_alert_row(side, f"{inv_stats.get('expiring')} منتج قريب الانتهاء",
                                     "راجع تواريخ الصلاحية", self.colors["accent"], self.show_inventory)
        if debt_total > 0:
            alerts_count += 1
            self.dashboard_alert_row(side, f"{len(debt_customers)} زبون لديهم ديون",
                                     f"إجمالي الديون {debt_total:,.0f} د.ج", self.colors["danger"], self.show_customers)

        ctk.CTkLabel(
            side, text=self.t("🏆 الأكثر مبيعًا"),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            text_color=self.muted()
        ).pack(anchor="w", padx=15, pady=(10, 4))

        if top_products:
            for rank, product in enumerate(top_products, 1):
                row = ctk.CTkFrame(side, fg_color=self.bg(), corner_radius=8)
                row.pack(fill="x", padx=12, pady=2)
                name = str(product[0]) if len(product) > 0 else self.t("منتج")
                qty = product[1] if len(product) > 1 else 0
                ctk.CTkLabel(row, text=f"{rank}. {name}", anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                             text_color=self.text()).pack(side="left", padx=8, pady=7)
                ctk.CTkLabel(row, text=self.t(f"{qty} وحدة"),
                             font=ctk.CTkFont(family=self.ui_font_family, size=8),
                             text_color=self.muted()).pack(side="right", padx=8)
        else:
            ctk.CTkLabel(side, text=self.t("لا توجد مبيعات مسجلة بعد"),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9),
                         text_color=self.muted()).pack(pady=12)

        if alerts_count == 0:
            ctk.CTkLabel(side, text=self.t("✓ كل شيء على ما يرام"),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                         text_color=self.colors["secondary"]).pack(pady=10)

    def draw_weekly_sales_chart(self, parent):
        """رسم آخر 7 أيام اعتمادًا على سجل المبيعات الفعلي، دون بيانات وهمية."""
        canvas = tk.Canvas(parent, bg=self.card(), highlightthickness=0, bd=0, height=220)
        canvas.pack(fill="both", expand=True, padx=12, pady=10)

        from datetime import timedelta
        today = datetime.now().date()
        days = [today - timedelta(days=i) for i in range(6, -1, -1)]
        values = {d: 0.0 for d in days}

        try:
            sales = self.reports_manager.get_sales_by_period("week")
            for sale in sales:
                if len(sale) <= 7:
                    continue
                raw_date = sale[7]
                if not raw_date:
                    continue
                try:
                    if isinstance(raw_date, datetime):
                        d = raw_date.date()
                    else:
                        d = datetime.fromisoformat(str(raw_date).replace("Z", "")).date()
                    if d in values:
                        values[d] += float(sale[3] or 0)
                except Exception:
                    continue
        except Exception:
            pass

        vals = [values[d] for d in days]

        def draw(_event=None):
            canvas.delete("all")
            w = max(canvas.winfo_width(), 520)
            h = max(canvas.winfo_height(), 190)
            left, right, top, bottom = 42, 20, 22, 40
            max_value = max(vals) if vals else 0
            scale = max_value if max_value > 0 else 1

            for ratio in (0, .5, 1):
                y = h - bottom - ratio * (h - top - bottom)
                canvas.create_line(left, y, w-right, y, fill=self.border(), width=1)

            slot = (w-left-right) / 7
            points = []
            for i, value in enumerate(vals):
                x = left + slot * (i + .5)
                y = h - bottom - (value / scale) * (h-top-bottom)
                points.append((x, y))

            if len(points) > 1:
                for a, b in zip(points, points[1:]):
                    canvas.create_line(a[0], a[1], b[0], b[1],
                                       fill=self.colors["primary"], width=3, smooth=True)

            for i, (x, y) in enumerate(points):
                canvas.create_oval(x-5, y-5, x+5, y+5,
                                   fill=self.colors["primary"], outline=self.card(), width=2)
                canvas.create_text(x, y-14, text=f"{vals[i]:,.0f}",
                                   fill=self.text(), font=("Segoe UI", 8, "bold"))
                label = days[i].strftime("%d/%m")
                canvas.create_text(x, h-18, text=label,
                                   fill=self.muted(), font=("Segoe UI", 8))

            if max_value <= 0:
                canvas.create_text(w/2, h/2, text=self.t("لا توجد مبيعات خلال آخر 7 أيام"),
                                   fill=self.muted(), font=("Segoe UI", 10, "bold"))

        canvas.bind("<Configure>", draw)
        parent.after(80, draw)

    def dashboard_alert_row(self, parent, title, subtitle, color, command=None):
        title = self.t(title)
        subtitle = self.t(subtitle)
        row = ctk.CTkFrame(parent, fg_color=self.bg(), corner_radius=10)
        row.pack(fill="x", padx=12, pady=4)

        body = ctk.CTkFrame(row, fg_color="transparent")
        body.pack(fill="x", padx=12, pady=8)

        ctk.CTkLabel(
            body,text=title,
            font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold"),
            text_color=color
        ).pack(anchor="w")

        ctk.CTkLabel(
            body,text=subtitle,
            font=ctk.CTkFont(family=self.ui_font_family,size=8),
            text_color=self.muted()
        ).pack(anchor="w", pady=(2,0))

        if command:
            ctk.CTkButton(
                body,text=self.t("فتح"),command=command,
                width=42,height=25,corner_radius=7,
                fg_color=self.card(),hover_color=self.border(),
                text_color=color,border_width=1,border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family,size=8,weight="bold")
            ).pack(side="right",anchor="e",pady=0)

    def quick_button(self, parent, text, command):
        ctk.CTkButton(
            parent,
            text=text,
            command=command,
            height=40,
            corner_radius=9,
            fg_color=self.bg(),
            hover_color=self.border(),
            text_color=self.text(),
            anchor="w",
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
        ).pack(fill="x", padx=12, pady=4)

    # =========================================================
    # Smart Inventory
    # =========================================================

    def show_inventory(self):
        """V20 — لوحة المخزون مع البحث والتنبيهات وسجل الحركات."""
        if not self._guard_db_nav("المخزون", "إدارة كمية المنتجات وتنبيهات النفاد", "inventory"):
            return
        self.clear_content()
        self.current_page = "inventory"
        self.highlight_nav()

        self.page_header(
            "المخزون الذكي",
            "متابعة الكميات والتنبيهات وحركات دخول وخروج المخزون"
        )

        try:
            stats = self.inventory_manager.get_stats()
        except Exception:
            stats = {"total": 0, "out": 0, "low": 0, "expiring": 0}

        summary = ctk.CTkFrame(self.content_area, fg_color="transparent")
        summary.pack(fill="x", pady=(0, 12))
        cards = [
            (self.t("إجمالي المنتجات"), stats.get("total", 0), self.colors["primary"]),
            (self.t("نفد المخزون"), stats.get("out", 0), self.colors["danger"]),
            (self.t("مخزون منخفض"), stats.get("low", 0), self.colors["accent"]),
            (self.t("قريب الانتهاء"), stats.get("expiring", 0), self.colors["info"]),
        ]
        for i, (label, value, color) in enumerate(cards):
            card = self.make_card(summary)
            card.grid(row=0, column=i, sticky="nsew", padx=(0 if i == 0 else 6, 0))
            summary.grid_columnconfigure(i, weight=1)
            ctk.CTkLabel(card, text=label, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack(anchor="w", padx=14, pady=(10, 2))
            ctk.CTkLabel(card, text=str(value), text_color=color,
                         font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold")).pack(anchor="w", padx=14, pady=(0, 10))

        toolbar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        toolbar.pack(fill="x", pady=(0, 10))
        search = ctk.CTkEntry(toolbar, placeholder_text=self.t("ابحث باسم المنتج أو الباركود..."), height=40)
        search.pack(side="left", fill="x", expand=True, padx=(0, 8))
        self.inventory_search = search

        ctk.CTkButton(toolbar, text=self.t("📋 سجل الحركات"), command=self.open_inventory_history,
                      height=40, width=125, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border()).pack(side="right", padx=4)
        ctk.CTkButton(toolbar, text=self.t("+ إدخال مخزون"), command=self.open_stock_entry,
                      height=40, width=125, corner_radius=9,
                      fg_color=self.colors["secondary"], hover_color=self.colors["secondary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")).pack(side="right", padx=4)
        ctk.CTkButton(toolbar, text=self.t("⟳ تحديث"), command=self.show_inventory,
                      height=40, width=90, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()).pack(side="right")
        ctk.CTkButton(toolbar, text=self.t("📋 جرد المخزون"), command=self.open_inventory_count,
                      height=40, width=125, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")).pack(side="right", padx=4)

        table = ctk.CTkScrollableFrame(self.content_area, fg_color=self.card(), corner_radius=12)
        table.pack(fill="both", expand=True)

        header = ctk.CTkFrame(table, fg_color=self.bg(), corner_radius=8)
        header.pack(fill="x", padx=6, pady=6)
        for text in [self.t("المنتج"), self.t("الباركود"), self.t("السعر"), self.t("الكمية"), self.t("الوحدة"), self.t("الصلاحية"), self.t("الحالة"), self.t("الحركة")]:
            ctk.CTkLabel(header, text=text, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                         anchor="e").pack(side="left", fill="x", expand=True, padx=4, pady=9)

        try:
            products = self.inventory_manager.get_products()
        except Exception:
            products = []

        render_state = {"show": 50}

        def build_rows(matched):
            limited = matched[:render_state["show"]]
            for product in limited:
                # id, barcode, name, price, quantity, unit, cost, expiry_date
                pid, barcode, name, price, quantity, unit, cost, expiry = product

                row = ctk.CTkFrame(table, fg_color="transparent", height=48)
                row.pack(fill="x", padx=6, pady=2)
                row.pack_propagate(False)

                values = [
                    name or "—",
                    barcode or "—",
                    f"{float(price or 0):,.2f}",
                    f"{float(quantity or 0):g}",
                    unit or "—",
                    str(expiry or "—")[:10]
                ]
                for value in values:
                    ctk.CTkLabel(row, text=str(value), text_color=self.text(), anchor="e",
                                 font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack(
                                     side="left", fill="x", expand=True, padx=4)

                qty = float(quantity or 0)
                if qty <= 0:
                    status, color = self.t("نفد"), self.colors["danger"]
                elif qty <= self.inventory_manager.low_threshold:
                    status, color = self.t("منخفض"), self.colors["accent"]
                else:
                    status, color = self.t("متوفر"), self.colors["secondary"]

                ctk.CTkLabel(row, text=status, text_color=color,
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                             anchor="e").pack(side="left", fill="x", expand=True, padx=4)

                ctk.CTkButton(
                    row, text=self.t("سجل"), width=58, height=30, corner_radius=7,
                    fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                    border_width=1, border_color=self.border(),
                    command=lambda product_id=pid, product_name=name: self.open_inventory_history(product_id, product_name)
                ).pack(side="left", padx=3)
                ctk.CTkButton(
                    row, text=self.t("+ إضافة"), width=72, height=30, corner_radius=7,
                    fg_color=self.colors["secondary"], hover_color=self.colors["secondary_hover"],
                    text_color="white",
                    font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold"),
                    command=lambda p=product: self.open_stock_entry(p)
                ).pack(side="left", padx=3)

            if len(matched) > render_state["show"]:
                remaining = len(matched) - render_state["show"]
                ctk.CTkButton(
                    table, text=self.t(f"عرض المزيد ({remaining} منتج)"),
                    height=36, corner_radius=8,
                    fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                    command=lambda: (
                        render_state.__setitem__("show", render_state["show"] + 50),
                        render(items)
                    )
                ).pack(fill="x", padx=6, pady=8)

        def render(items):
            children = table.winfo_children()
            for w in children[1:]:
                w.destroy()
            q = search.get().strip().lower()
            matched = [
                p for p in items
                if not q
                or q in str(p[1] or "").lower()
                or q in str(p[2] or "").lower()
            ]
            build_rows(matched)

        def debounced_render(_event=None):
            if getattr(self, "inventory_search_after_id", None):
                try:
                    self.after_cancel(self.inventory_search_after_id)
                except Exception:
                    pass
            self.inventory_search_after_id = self.after(250, lambda: render(products))

        search.bind("<KeyRelease>", debounced_render)
        render(products)

    def open_inventory_count(self):
        """جرد فعلي للمخزون وحساب الفروقات وتسجيل التسويات."""
        try:
            products = self.product_manager.get_all_products()
        except Exception as e:
            self.show_message("الجرد", f"تعذر تحميل المنتجات:\n{e}", "error")
            return
        if not products:
            self.show_message("الجرد", "لا توجد منتجات لإجراء الجرد.", "info")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("جرد المخزون"))
        win.geometry("1050x700")
        win.minsize(850, 560)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 1050, 700)

        root = ctk.CTkFrame(win, fg_color=self.bg())
        root.pack(fill="both", expand=True, padx=18, pady=18)
        ctk.CTkLabel(root, text=self.t("📋 جرد المخزون"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold")).pack(anchor="e")
        ctk.CTkLabel(root, text=self.t("أدخل الكمية الفعلية وسيحسب البرنامج الفرق تلقائيًا."),
                     text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="e", pady=(3,10))

        search_var = tk.StringVar()
        search = ctk.CTkEntry(root, textvariable=search_var,
                              placeholder_text=self.t("ابحث باسم المنتج أو الباركود..."), height=40)
        search.pack(fill="x", pady=(0,8))
        table = ctk.CTkScrollableFrame(root, fg_color=self.card(), corner_radius=10)
        table.pack(fill="both", expand=True)

        footer = ctk.CTkFrame(root, fg_color="transparent")
        footer.pack(fill="x", pady=(10,0))
        status = ctk.CTkLabel(footer, text=self.t("0 منتج"), text_color=self.muted())
        status.pack(side="left")
        records=[]

        def refresh_rows(*_):
            for w in table.winfo_children(): w.destroy()
            records.clear()
            term=search_var.get().strip().casefold()
            visible=[p for p in products if not term or term in str(p[2] or '').casefold() or term in str(p[1] or '').casefold()]
            hdr=ctk.CTkFrame(table,fg_color=self.bg(),corner_radius=7); hdr.pack(fill='x',padx=5,pady=5)
            for text,width in [(self.t('المنتج'),340),(self.t('النظام'),130),(self.t('الفعلي'),150),(self.t('الفرق'),120)]:
                ctk.CTkLabel(hdr,text=text,width=width,text_color=self.muted(),anchor='e',font=ctk.CTkFont(family=self.ui_font_family,size=9,weight='bold')).pack(side='left',padx=5,pady=8)
            for p in visible:
                current=float(p[4] or 0); row=ctk.CTkFrame(table,fg_color='transparent',height=50); row.pack(fill='x',padx=5,pady=2); row.pack_propagate(False)
                ctk.CTkLabel(row,text=str(p[2]),width=340,text_color=self.text(),anchor='e',font=ctk.CTkFont(family=self.ui_font_family,size=10,weight='bold')).pack(side='left',padx=5)
                ctk.CTkLabel(row,text=f'{current:g} {p[5] or ""}',width=130,text_color=self.muted(),anchor='e').pack(side='left',padx=5)
                ent=ctk.CTkEntry(row,width=140,height=34,justify='right'); ent.insert(0,f'{current:g}'); ent.pack(side='left',padx=5)
                diff=ctk.CTkLabel(row,text=self.t('0'),width=110,text_color=self.muted(),anchor='e'); diff.pack(side='left',padx=5)
                rec={'p':p,'current':current,'entry':ent,'diff':diff}; records.append(rec)
                def update(event=None,r=rec):
                    try:
                        d=float(r['entry'].get().strip().replace(',','.'))-r['current']
                        r['diff'].configure(text=f"{'+' if d>0 else ''}{d:g}",text_color=self.colors['secondary'] if d>=0 else self.colors['danger'])
                    except Exception: r['diff'].configure(text='—',text_color=self.colors['danger'])
                ent.bind('<KeyRelease>',update)
            status.configure(text=self.t(f'{len(visible)} منتج'))

        def save():
            changes=[]; invalid=[]
            for r in records:
                try:
                    actual=float(r['entry'].get().strip().replace(',','.'))
                    if actual<0: raise ValueError
                    d=actual-r['current']
                    if abs(d)>1e-9: changes.append((r['p'],d))
                except Exception: invalid.append(r['p'][2])
            if invalid:
                self.show_message('الجرد','تحقق من الكمية: '+', '.join(invalid[:8]),'error'); return
            if not changes:
                self.show_message('الجرد','لا توجد فروقات ليتم تسجيلها.','info'); return
            if not messagebox.askyesno(self.t('تأكيد الجرد'),self.t(f'سيتم تطبيق {len(changes)} تسوية. هل تريد المتابعة؟'),parent=win): return
            failed=[]
            for p,d in changes:
                ok,msg=self.inventory_manager.change_stock(p[0],d,'تسوية جرد')
                if not ok: failed.append(f'{p[2]}: {msg}')
                else: self.log_action("stock_adjust", "product", p[0], f"{p[2]} • {'+' if d>0 else ''}{d:g}")
            if failed:
                self.show_message('الجرد','تعذر تطبيق بعض التسويات:\n'+'\n'.join(failed[:8]),'warning')
            else:
                self.log_action("inventory_count", "inventory", None, f"{len(changes)} تسوية")
                self.show_message('الجرد','تم حفظ الجرد وتسجيل الفروقات بنجاح.','success'); win.destroy(); self.show_inventory()

        ctk.CTkButton(footer,text=self.t('إلغاء'),width=100,height=38,fg_color=self.card(),hover_color=self.border(),text_color=self.text(),border_width=1,border_color=self.border(),command=win.destroy).pack(side='right',padx=4)
        ctk.CTkButton(footer,text=self.t('✓ حفظ الجرد'),width=130,height=38,fg_color=self.colors['primary'],hover_color=self.colors['primary_hover'],font=ctk.CTkFont(family=self.ui_font_family,size=10,weight='bold'),command=save).pack(side='right',padx=4)
        search.bind('<KeyRelease>',refresh_rows)
        refresh_rows()

    def open_inventory_history(self, product_id=None, product_name=None):
        """عرض سجل حركات المخزون لكل المنتجات أو لمنتج محدد."""
        try:
            movements = self.inventory_manager.get_movements(product_id=product_id, limit=300)
        except Exception as e:
            self.show_message("خطأ", f"تعذر تحميل سجل المخزون:\n{e}", "error")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("سجل حركة المخزون"))
        win.geometry("900x620")
        win.minsize(750, 500)
        win.transient(self)
        win.grab_set()

        frame = ctk.CTkFrame(win, fg_color=self.bg(), corner_radius=0)
        frame.pack(fill="both", expand=True, padx=18, pady=18)

        title = self.t(f"سجل المخزون — {product_name}") if product_name else self.t("سجل حركة المخزون")
        ctk.CTkLabel(frame, text=title, text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")).pack(anchor="e", pady=(2, 4))
        ctk.CTkLabel(frame,
                     text=self.t("كل عملية إدخال أو تعديل مسجلة مع التاريخ والسبب."),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="e", pady=(0, 12))

        table = ctk.CTkScrollableFrame(frame, fg_color=self.card(), corner_radius=10)
        table.pack(fill="both", expand=True)

        header = ctk.CTkFrame(table, fg_color=self.bg(), corner_radius=7)
        header.pack(fill="x", padx=6, pady=6)
        headers = [self.t("التاريخ"), self.t("المنتج"), self.t("الحركة"), self.t("السبب")]
        for h in headers:
            ctk.CTkLabel(header, text=h, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                         anchor="e").pack(side="left", fill="x", expand=True, padx=6, pady=8)

        if not movements:
            ctk.CTkLabel(table, text=self.t("لا توجد حركات مسجلة حتى الآن."), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(pady=80)
        else:
            for movement in movements:
                # id, product_name, quantity_change, reason, movement_date
                _, name, change, reason, movement_date = movement
                row = ctk.CTkFrame(table, fg_color="transparent", height=44)
                row.pack(fill="x", padx=6, pady=2)
                row.pack_propagate(False)
                vals = [str(movement_date or "—"), str(name or "—"),
                        f"{'+' if float(change or 0) > 0 else ''}{float(change or 0):g}",
                        str(reason or "—")]
                for i, value in enumerate(vals):
                    color = self.colors["secondary"] if i == 2 and float(change or 0) > 0 else self.colors["danger"] if i == 2 else self.text()
                    ctk.CTkLabel(row, text=value, text_color=color, anchor="e",
                                 font=ctk.CTkFont(family=self.ui_font_family, size=9,
                                                 weight="bold" if i == 2 else "normal")).pack(
                                                     side="left", fill="x", expand=True, padx=6)

        ctk.CTkButton(frame, text=self.t("إغلاق"), command=win.destroy, height=40,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border()).pack(fill="x", pady=(10, 0))

    # =========================================================
    # سجل النشاطات — Activity Log viewer
    # =========================================================

    def open_audit_log(self):
        """عرض آخر 500 عملية مسجلة مع بحث وفلترة بالتاريخ."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("📋 سجل النشاطات"))
        win.geometry("980x660")
        win.minsize(820, 560)
        win.transient(self)
        win.grab_set()
        try:
            self.center_window(win, 980, 660)
        except Exception:
            pass

        frame = ctk.CTkFrame(win, fg_color=self.bg(), corner_radius=0)
        frame.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(frame, text=self.t("📋 سجل النشاطات"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")).pack(anchor="e", pady=(2, 2))
        ctk.CTkLabel(frame,
                     text=self.t("كل العمليات الحساسة مسجلة باسم المستخدم والتاريخ."),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="e", pady=(0, 10))

        controls = ctk.CTkFrame(frame, fg_color="transparent")
        controls.pack(fill="x", pady=(0, 8))

        search_var = tk.StringVar()
        search = ctk.CTkEntry(controls, textvariable=search_var,
                              placeholder_text=self.t("ابحث بالمستخدم أو نوع الإجراء..."),
                              height=38, fg_color=self.card(),
                              border_color=self.border(), text_color=self.text())
        search.pack(side="left", fill="x", expand=True, padx=(0, 8))

        date_from = ctk.CTkEntry(controls, placeholder_text=self.t("من 2026-01-01"),
                                 width=120, height=38, fg_color=self.card(),
                                 border_color=self.border(), text_color=self.text())
        date_from.pack(side="right", padx=(8, 0))
        date_to = ctk.CTkEntry(controls, placeholder_text=self.t("إلى 2026-12-31"),
                               width=120, height=38, fg_color=self.card(),
                               border_color=self.border(), text_color=self.text())
        date_to.pack(side="right", padx=(8, 0))

        table = ctk.CTkScrollableFrame(frame, fg_color=self.card(), corner_radius=10)
        table.pack(fill="both", expand=True)

        def re_match_date(value):
            value = str(value or "").strip()
            return (len(value) == 10 and value[4] == "-" and value[7] == "-"
                    and value[:4].isdigit() and value[5:7].isdigit() and value[8:].isdigit())

        def load():
            for w in table.winfo_children():
                w.destroy()

            header = ctk.CTkFrame(table, fg_color=self.bg(), corner_radius=7)
            header.pack(fill="x", padx=6, pady=6)
            for h in (self.t("التاريخ"), self.t("المستخدم"), self.t("الإجراء"), self.t("النوع"), self.t("التفاصيل")):
                ctk.CTkLabel(header, text=h, text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                             anchor="e").pack(side="left", fill="x", expand=True, padx=6, pady=8)

            conn = None
            rows = []
            try:
                conn = self.db.get_connection()
                query = "SELECT username, action, entity_type, IFNULL(details,''), created_at FROM audit_log"
                conds, params = [], []
                term = search_var.get().strip()
                if term:
                    conds.append("(username LIKE ? OR action LIKE ?)")
                    like = f"%{term}%"
                    params.extend([like, like])
                d1 = str(date_from.get().strip())
                d2 = str(date_to.get().strip())
                if re_match_date(d1):
                    conds.append("DATE(created_at) >= ?")
                    params.append(d1)
                if re_match_date(d2):
                    conds.append("DATE(created_at) <= ?")
                    params.append(d2)
                if conds:
                    query += " WHERE " + " AND ".join(conds)
                query += " ORDER BY id DESC LIMIT 500"
                rows = conn.execute(query, tuple(params)).fetchall()
            except Exception as exc:
                rows = []
                self.toast(f"{self.t('تعذر تحميل السجل')}: {exc}", "danger")
            finally:
                if conn: conn.close()

            if not rows:
                ctk.CTkLabel(table, text=self.t("لا توجد عمليات مسجلة بعد."),
                             text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(pady=70)
                return

            for username, action, entity_type, details, created in rows:
                row = ctk.CTkFrame(table, fg_color="transparent", height=42)
                row.pack(fill="x", padx=6, pady=2)
                row.pack_propagate(False)
                vals = [
                    str(created or "—")[:19],
                    str(username or "system"),
                    str(action or "—"),
                    str(entity_type or "—"),
                    str(details or ""),
                ]
                for value in vals:
                    ctk.CTkLabel(row, text=value, text_color=self.text(), anchor="e",
                                 font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack(
                                     side="left", fill="x", expand=True, padx=6)

        search.bind("<KeyRelease>", lambda e: load())
        date_from.bind("<KeyRelease>", lambda e: load())
        date_to.bind("<KeyRelease>", lambda e: load())

        ctk.CTkButton(frame, text="⟳ " + self.t("تحديث"), command=load, height=38,
                      width=100, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()
                      ).pack(anchor="w", pady=(8, 0))
        load()

    # =========================================================
    # التصنيفات — Categories management
    # =========================================================

    def _load_categories(self):
        """قائمة التصنيفات (id, name)."""
        conn = None
        try:
            conn = self.db.get_connection()
            return conn.execute(
                "SELECT id, name FROM categories ORDER BY name COLLATE NOCASE"
            ).fetchall()
        except Exception:
            return []
        finally:
            if conn: conn.close()

    def _category_filter_options(self):
        cats = self._load_categories()
        values = [self.t("كل التصنيفات"), self.t("بدون تصنيف")] + [str(c[1]) for c in cats]
        return cats, values

    def _match_category_filter(self, product, selection, categories):
        """دمج فلتر التصنيف مع باقي الفلاتر (AND)."""
        selection = self._to_ar(str(selection or "").strip())
        if not selection or selection == "كل التصنيفات":
            return True
        cat_id = product[6] if len(product) > 6 else None
        if selection == "بدون تصنيف":
            return cat_id is None
        for cid, cname in categories:
            if str(cname) == selection:
                return cat_id == cid
        return True

    def _get_product_category_id(self, product_id):
        conn = None
        try:
            conn = self.db.get_connection()
            row = conn.execute("SELECT category_id FROM products WHERE id=?", (product_id,)).fetchone()
            return row[0] if row else None
        except Exception:
            return None
        finally:
            if conn: conn.close()

    def _save_product_category(self, product_id, category_id):
        """حفظ تصنيف المنتج بعد الإضافة/التعديل (بنفس أسلوب حفظ الصورة)."""
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("UPDATE products SET category_id=? WHERE id=?", (category_id, product_id))
            conn.commit()
            return True
        except Exception:
            return False
        finally:
            if conn: conn.close()

    def _lookup_product_id(self, barcode, name):
        """إيجاد معرف المنتج المضاف حديثًا لأن add_product لا يعيد المعرف."""
        conn = None
        try:
            conn = self.db.get_connection()
            row = None
            if barcode:
                row = conn.execute(
                    "SELECT id FROM products WHERE barcode=? ORDER BY id DESC LIMIT 1",
                    (barcode,)
                ).fetchone()
            if not row:
                row = conn.execute(
                    "SELECT id FROM products WHERE name=? ORDER BY id DESC LIMIT 1",
                    (name,)
                ).fetchone()
            return row[0] if row else None
        except Exception:
            return None
        finally:
            if conn: conn.close()

    def open_categories_manager(self):
        """إدارة تصنيفات المنتجات: إضافة/تعديل/حذف مع إعادة تعيين منتجاتها."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("🏷 التصنيفات"))
        win.geometry("680x600")
        win.minsize(580, 520)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 680, 600)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(container, text=self.t("🏷 إدارة التصنيفات"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold")).pack(anchor="w")
        ctk.CTkLabel(container, text=self.t("نظّم منتجاتك في أقسام، وحذف التصنيف ينقل منتجاته إلى 'بدون تصنيف'."),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(2, 12))

        add_row = ctk.CTkFrame(container, fg_color="transparent")
        add_row.pack(fill="x", pady=(0, 10))
        name_entry = ctk.CTkEntry(add_row, placeholder_text=self.t("اسم التصنيف الجديد"),
                                  height=42, fg_color=self.card(),
                                  border_color=self.border(), text_color=self.text())
        name_entry.pack(side="left", fill="x", expand=True, padx=(0, 8))

        list_frame = ctk.CTkScrollableFrame(container, fg_color="transparent")
        list_frame.pack(fill="both", expand=True)

        def do_add():
            name = name_entry.get().strip()
            if not name:
                self.toast(self.t("اسم التصنيف مطلوب"), "danger")
                return
            conn = None
            try:
                conn = self.db.get_connection()
                cur = conn.execute("INSERT INTO categories (name) VALUES (?)", (name,))
                conn.commit()
                self.log_action("category_created", "category", cur.lastrowid, name)
                self.toast(f"✓ {self.t('تمت إضافة التصنيف')}")
                name_entry.delete(0, "end")
                refresh()
            except Exception:
                self.toast(self.t("هذا التصنيف موجود مسبقاً"), "danger")
            finally:
                if conn: conn.close()

        ctk.CTkButton(add_row, text="＋ " + self.t("إضافة تصنيف"), command=do_add,
                      height=42, width=130, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
                      ).pack(side="right")
        name_entry.bind("<Return>", lambda e: do_add())

        def rename_dialog(cat):
            rwin = ctk.CTkToplevel(win)
            rwin.title(self.t("تعديل التصنيف"))
            rwin.geometry("380x210")
            rwin.resizable(False, False)
            rwin.transient(win)
            rwin.grab_set()
            self.center_window(rwin, 380, 210)

            rc = ctk.CTkFrame(rwin, fg_color=self.bg())
            rc.pack(fill="both", expand=True, padx=18, pady=18)
            ctk.CTkLabel(rc, text=self.t("تعديل التصنيف"), text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold")).pack(anchor="w")
            entry = ctk.CTkEntry(rc, height=40, fg_color=self.card(),
                                 border_color=self.border(), text_color=self.text())
            entry.insert(0, str(cat[1]))
            entry.pack(fill="x", pady=12)

            def save():
                new_name = entry.get().strip()
                if not new_name:
                    self.toast(self.t("اسم التصنيف مطلوب"), "danger")
                    return
                conn = None
                try:
                    conn = self.db.get_connection()
                    conn.execute("UPDATE categories SET name=? WHERE id=?", (new_name, cat[0]))
                    conn.commit()
                    self.log_action("category_renamed", "category", cat[0], f"{cat[1]} → {new_name}")
                    self.toast(f"✓ {self.t('تم تحديث التصنيف')}")
                    rwin.destroy()
                    refresh()
                except Exception:
                    self.toast(self.t("هذا الاسم مستخدم مسبقاً"), "danger")
                finally:
                    if conn: conn.close()

            brow = ctk.CTkFrame(rc, fg_color="transparent")
            brow.pack(fill="x")
            ctk.CTkButton(brow, text=self.t("حفظ"), command=save, height=36, corner_radius=9,
                          fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]
                          ).pack(side="left", fill="x", expand=True, padx=(0, 4))
            ctk.CTkButton(brow, text=self.t("إلغاء"), command=rwin.destroy, height=36, corner_radius=9,
                          fg_color=self.card(), hover_color=self.border(), text_color=self.text()
                          ).pack(side="right", fill="x", expand=True, padx=(4, 0))
            entry.focus_set()
            entry.select_range(0, "end")

        def delete_cat(cat):
            count = 0
            conn = None
            try:
                conn = self.db.get_connection()
                row = conn.execute("SELECT COUNT(*) FROM products WHERE category_id=?", (cat[0],)).fetchone()
                count = int(row[0] or 0)
            except Exception:
                count = 0
            finally:
                if conn: conn.close()

            if count > 0:
                msg = (f"{self.t('سيتم نقل منتجات هذا التصنيف إلى')} "
                       f"'{self.t('بدون تصنيف')}'. {self.t('هل تريد المتابعة؟')}\n"
                       f"({count} {self.t('منتج')})")
            else:
                msg = self.t("هل تريد حذف هذا التصنيف؟")
            if not messagebox.askyesno(self.t("حذف التصنيف"), msg, parent=win):
                return
            if not self.require_pin(self.t("حذف تصنيف"), "admin"):
                return
            conn = None
            try:
                conn = self.db.get_connection()
                conn.execute("UPDATE products SET category_id=NULL WHERE category_id=?", (cat[0],))
                conn.execute("DELETE FROM categories WHERE id=?", (cat[0],))
                conn.commit()
                self.log_action("category_deleted", "category", cat[0],
                                f"{cat[1]} • {self.t('منتجات معاد تعيينها')}: {count}")
                self.toast(f"✓ {self.t('تم حذف التصنيف')}")
                refresh()
            except Exception as exc:
                self.toast(f"{self.t('تعذر الحذف')}: {exc}", "danger")
            finally:
                if conn: conn.close()

        def refresh():
            for w in list_frame.winfo_children():
                w.destroy()
            cats = self._load_categories()
            counts = {}
            conn = None
            try:
                conn = self.db.get_connection()
                for cid, cnt in conn.execute(
                        "SELECT category_id, COUNT(*) FROM products WHERE category_id IS NOT NULL GROUP BY category_id"):
                    counts[cid] = int(cnt or 0)
            except Exception:
                pass
            finally:
                if conn: conn.close()

            if not cats:
                ctk.CTkLabel(list_frame, text=self.t("لا توجد تصنيفات بعد"),
                             text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=13)).pack(pady=50)
                return

            for cat in cats:
                row = self.make_card(list_frame, corner_radius=12)
                row.pack(fill="x", pady=3)
                info = (
                    f"🏷 {cat[1]}    •    {counts.get(cat[0], 0)} {self.t('منتج')}"
                )
                ctk.CTkLabel(row, text=info, anchor="e", text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=12)
                             ).pack(side="right", fill="x", expand=True, padx=14, pady=12)
                ctk.CTkButton(row, text=self.t("تعديل"), width=75, height=32, corner_radius=8,
                              fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                              border_width=1, border_color=self.border(),
                              command=lambda c=cat: rename_dialog(c)
                              ).pack(side="left", padx=4, pady=8)
                ctk.CTkButton(row, text=self.t("حذف"), width=75, height=32, corner_radius=8,
                              fg_color="transparent", hover_color=self.colors["danger"],
                              text_color=self.colors["danger"],
                              command=lambda c=cat: delete_cat(c)
                              ).pack(side="left", padx=4, pady=8)

        refresh()

    # =========================================================
    # المستخدمون — Users & PIN management
    # =========================================================

    def open_users_manager(self):
        """إدارة المستخدمين والأدوار والرموز (للمدير فقط)."""
        if not self.require_pin(self.t("إدارة المستخدمين"), "admin"):
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("👥 المستخدمون"))
        win.geometry("720x650")
        win.minsize(620, 540)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 720, 650)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(container, text=self.t("👥 إدارة المستخدمين"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold")).pack(anchor="w")
        ctk.CTkLabel(container, text=self.t("إنشاء المستخدمين وتغيير الرموز والأدوار."),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(2, 12))

        add_card = self.make_card(container)
        add_card.pack(fill="x", pady=(0, 10))

        fields = ctk.CTkFrame(add_card, fg_color="transparent")
        fields.pack(fill="x", padx=12, pady=12)

        uname = ctk.CTkEntry(fields, placeholder_text=self.t("الاسم"),
                             height=40, fg_color=self.bg(), border_color=self.border(),
                             text_color=self.text())
        uname.pack(side="right", fill="x", expand=True, padx=4)
        upin = ctk.CTkEntry(fields, show="*", placeholder_text=self.t("رمز PIN (4-6 أرقام)"),
                            height=40, fg_color=self.bg(), border_color=self.border(),
                            text_color=self.text())
        upin.pack(side="right", fill="x", expand=True, padx=4)
        urole = ctk.CTkComboBox(fields, values=[self.t("مدير"), self.t("كاشير")],
                                height=40, width=110, corner_radius=9,
                                fg_color=self.bg(), border_color=self.border(),
                                button_color=self.colors["primary"], text_color=self.text())
        urole.set(self.t("كاشير"))
        urole.pack(side="right", padx=4)

        list_frame = ctk.CTkScrollableFrame(container, fg_color="transparent")
        list_frame.pack(fill="both", expand=True)

        def role_value():
            return "admin" if urole.get() == self.t("مدير") else "cashier"

        def add_user():
            name = uname.get().strip()
            pin = upin.get().strip()
            role = role_value()
            if not name:
                self.toast(self.t("اسم المستخدم مطلوب"), "danger")
                return
            if not (pin.isdigit() and 4 <= len(pin) <= 6):
                self.toast(self.t("الرمز يجب أن يكون أرقامًا من 4 إلى 6 خانات"), "danger")
                return
            users = self._get_users()
            if any(str(u[1]).lower() == name.lower() for u in users):
                self.toast(self.t("يوجد مستخدم بنفس الاسم"), "danger")
                return
            ok, uid = self._create_user(name, pin, role)
            if not ok:
                self.toast(self.t("تعذر إنشاء الحساب"), "danger")
                return
            self.log_action("user_created", "user", uid, f"{name} • {role}")
            self.toast(f"✓ {self.t('تمت إضافة المستخدم')}: {name}")
            uname.delete(0, "end")
            upin.delete(0, "end")
            refresh()

        ctk.CTkButton(add_card, text="＋ " + self.t("إضافة مستخدم"), command=add_user,
                      height=38, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
                      ).pack(fill="x", padx=12, pady=(0, 12))

        def change_pin(user):
            pwin = ctk.CTkToplevel(win)
            pwin.title(self.t("تغيير الرمز"))
            pwin.geometry("380x200")
            pwin.resizable(False, False)
            pwin.transient(win)
            pwin.grab_set()
            self.center_window(pwin, 380, 200)

            pc = ctk.CTkFrame(pwin, fg_color=self.bg())
            pc.pack(fill="both", expand=True, padx=18, pady=18)
            ctk.CTkLabel(pc, text=f"{self.t('رمز جديد')} — {user[1]}", text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold")).pack(anchor="w")
            entry = ctk.CTkEntry(pc, show="*", placeholder_text=self.t("رمز PIN (4-6 أرقام)"),
                                 height=40, justify="center", fg_color=self.card(),
                                 border_color=self.border(), text_color=self.text())
            entry.pack(fill="x", pady=12)

            def save():
                pin = entry.get().strip()
                if not (pin.isdigit() and 4 <= len(pin) <= 6):
                    self.toast(self.t("الرمز يجب أن يكون أرقامًا من 4 إلى 6 خانات"), "danger")
                    return
                salt = secrets.token_hex(16)
                conn = None
                try:
                    conn = self.db.get_connection()
                    conn.execute("UPDATE users SET pin_hash=?, salt=? WHERE id=?",
                                 (self._hash_pin(pin, salt), salt, user[0]))
                    conn.commit()
                    self.log_action("pin_changed", "user", user[0], str(user[1]))
                    self.toast(f"✓ {self.t('تم تغيير الرمز')}")
                    pwin.destroy()
                except Exception:
                    self.toast(self.t("تعذر تغيير الرمز"), "danger")
                finally:
                    if conn: conn.close()

            ctk.CTkButton(pc, text=self.t("حفظ"), command=save, height=36, corner_radius=9,
                          fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]
                          ).pack(fill="x")
            entry.focus_set()
            entry.bind("<Return>", lambda e: save())

        def delete_user(user):
            users = self._get_users()
            admins = [u for u in users if u[3] == "admin"]
            if user[3] == "admin" and len(admins) <= 1:
                self.toast(self.t("لا يمكن حذف آخر مدير"), "danger")
                return
            if not messagebox.askyesno(
                    self.t("حذف المستخدم"),
                    self.t("هل تريد حذف هذا المستخدم؟"),
                    parent=win):
                return
            conn = None
            try:
                conn = self.db.get_connection()
                conn.execute("DELETE FROM users WHERE id=?", (user[0],))
                conn.commit()
                self.log_action("user_deleted", "user", user[0], str(user[1]))
                if getattr(self, "current_user", None) and self.current_user.get("id") == user[0]:
                    self._set_current_user(None)
                self.toast(f"✓ {self.t('تم حذف المستخدم')}")
                refresh()
            except Exception:
                self.toast(self.t("تعذر حذف المستخدم"), "danger")
            finally:
                if conn: conn.close()

        def refresh():
            for w in list_frame.winfo_children():
                w.destroy()
            users = self._get_users()
            if not users:
                ctk.CTkLabel(list_frame, text=self.t("لا يوجد مستخدمون"),
                             text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=13)).pack(pady=40)
                return
            header = ctk.CTkFrame(list_frame, fg_color=self.card(), corner_radius=8)
            header.pack(fill="x", pady=(0, 4))
            for label in (self.t("الاسم"), self.t("الدور"), self.t("الإجراءات")):
                ctk.CTkLabel(header, text=label, text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
                             ).pack(side="left", fill="x", expand=True, padx=8, pady=8)
            for user in users:
                row = self.make_card(list_frame, corner_radius=10)
                row.pack(fill="x", pady=3)
                ctk.CTkLabel(row, text=str(user[1]), text_color=self.text(), anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
                             ).pack(side="left", fill="x", expand=True, padx=12, pady=10)
                role_color = self.colors["primary"] if user[3] == "admin" else self.colors["info"]
                ctk.CTkLabel(row, text=(self.t("مدير") if user[3] == "admin" else self.t("كاشير")),
                             fg_color=role_color, corner_radius=7, text_color="white",
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
                             ).pack(side="left", padx=6, ipadx=7, ipady=3)
                actions_box = ctk.CTkFrame(row, fg_color="transparent")
                actions_box.pack(side="right", fill="y", padx=8, pady=6)
                ctk.CTkButton(actions_box, text=self.t("تغيير الرمز"), width=95, height=30, corner_radius=7,
                              fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                              border_width=1, border_color=self.border(),
                              font=ctk.CTkFont(family=self.ui_font_family, size=9),
                              command=lambda u=user: change_pin(u)
                              ).pack(side="right", padx=2)
                ctk.CTkButton(actions_box, text=self.t("حذف"), width=60, height=30, corner_radius=7,
                              fg_color="transparent", hover_color=self.colors["danger"],
                              text_color=self.colors["danger"],
                              font=ctk.CTkFont(family=self.ui_font_family, size=9),
                              command=lambda u=user: delete_user(u)
                              ).pack(side="right", padx=2)

        refresh()

    # =========================================================
    # خصم على المنتج داخل السلة — Per-item discount dialog
    # =========================================================

    def _open_item_discount_dialog(self, index):
        """خصم ثابت على سطر محدد في السلة (نفس أسلوب خصم الفاتورة)."""
        if index < 0 or index >= len(self.cart):
            return
        item = self.cart[index]
        price = float(item.get("price", 0) or 0)
        quantity = float(item.get("quantity", 0) or 0)
        subtotal = price * quantity
        current = float(item.get("item_discount", 0.0) or 0.0)

        win = ctk.CTkToplevel(self)
        win.title(self.t("خصم على المنتج"))
        win.geometry("420x320")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 420, 320)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(container, text=self.t("خصم على المنتج"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=19, weight="bold")).pack(anchor="w", pady=(2, 2))
        ctk.CTkLabel(container, text=str(item.get("name", "")), text_color=self.colors["primary"],
                     font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")).pack(anchor="w")
        ctk.CTkLabel(container, text=self.t(f"{self.t('المجموع قبل الخصم')}: {subtotal:,.2f} د.ج"),
                     text_color=self.muted(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=(2, 8))

        toggle = ctk.CTkSegmentedButton(
            container, values=[self.t("مبلغ ثابت (دج)"), self.t("نسبة مئوية (%)")],
            command=lambda _v: update_preview(),
            height=32, corner_radius=8,
            fg_color=self.card(), selected_color=self.colors["primary"],
            selected_hover_color=self.colors["primary_hover"],
            unselected_color=self.card(), unselected_hover_color=self.border(),
            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        )
        toggle.pack(fill="x", pady=(0, 8))
        toggle.set(self.t("مبلغ ثابت (دج)"))

        def current_mode():
            return "percent" if toggle.get() == self.t("نسبة مئوية (%)") else "fixed"

        entry = ctk.CTkEntry(container, height=40, corner_radius=9,
                             fg_color=self.card(), border_color=self.border(),
                             text_color=self.text(), justify="center",
                             font=ctk.CTkFont(family=self.ui_font_family, size=13))
        entry.insert(0, f"{current:g}")
        entry.pack(fill="x", pady=(0, 6))

        preview = ctk.CTkLabel(container, text="", text_color=self.colors["secondary"],
                               font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                               anchor="e")
        preview.pack(fill="x", pady=(2, 4))

        hint = ctk.CTkLabel(container,
                            text=self.t("أدخل قيمة الخصم بالدينار أو نسبة مئوية (0 لإلغاء الخصم)."),
                            text_color=self.muted(),
                            font=ctk.CTkFont(family=self.ui_font_family, size=9))
        hint.pack(anchor="w", pady=(0, 4))

        def update_preview():
            mode = current_mode()
            try:
                raw = float(entry.get() or 0)
            except ValueError:
                preview.configure(text="")
                return
            if not raw or raw < 0:
                preview.configure(text="")
                return
            if mode == "percent":
                val = subtotal * (raw / 100.0)
                preview.configure(
                    text=f"{self.t('قيمة الخصم:')} {val:,.2f} {self.t('د.ج')} ({raw:g}%)"
                )
            else:
                pct = (raw / subtotal * 100.0) if subtotal > 0 else 0.0
                preview.configure(
                    text=f"{self.t('قيمة الخصم:')} {raw:,.2f} {self.t('د.ج')} ({pct:.1f}%)"
                )

        def save(event=None):
            try:
                value = float(entry.get() or 0)
            except ValueError:
                self.toast(self.t("أدخل قيمة خصم صحيحة"), "danger")
                return
            if value < 0:
                self.toast(self.t("الخصم لا يمكن أن يكون سالبًا"), "danger")
                return
            mode = current_mode()
            if mode == "percent":
                if value > 100:
                    self.toast(self.t("النسبة المئوية يجب أن تكون بين 0 و 100"), "danger")
                    return
                final_amount = subtotal * (value / 100.0)
            else:
                if value > subtotal:
                    self.toast(self.t("الخصم يتجاوز قيمة هذا المنتج"), "danger")
                    return
                final_amount = value
            threshold = float(self.settings.get("pin_discount_threshold", 500) or 0)
            if final_amount > threshold:
                if not self.require_pin(self.t("خصم على المنتج"), "any"):
                    return
            item["item_discount"] = round(final_amount, 2)
            item["total"] = max(0.0, subtotal - final_amount)
            self.log_action("item_discount", "product", item.get("id"),
                            f"{item.get('name', '')} • {final_amount:,.2f} دج")
            win.destroy()
            self.update_cart_display()
            self.toast(f"✓ {self.t('تم تطبيق خصم المنتج')}")

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(side="bottom", fill="x")

        ctk.CTkButton(buttons, text=self.t("حفظ"), command=save, height=38, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
                      ).pack(side="left", fill="x", expand=True, padx=(0, 4))
        ctk.CTkButton(buttons, text=self.t("إلغاء"), command=win.destroy, height=38, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=11)
                      ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        entry.bind("<Return>", save)
        entry.bind("<KeyRelease>", lambda _e: update_preview())
        entry.focus_set()
        entry.select_range(0, "end")
        update_preview()

    def _persist_item_discounts(self, invoice_number, cart):
        """يحفظ خصم كل منتج في sale_items بعد إنشاء الفاتورة (مثل حفظ التكلفة)."""
        conn = None
        try:
            conn = self.db.get_connection()
            seen = set()
            for it in cart:
                disc = float(it.get("item_discount", 0.0) or 0.0)
                pid = it.get("id")
                if disc <= 0 or pid is None or pid in seen:
                    continue
                seen.add(pid)
                conn.execute(
                    """UPDATE sale_items SET item_discount = ?
                       WHERE sale_id = (SELECT id FROM sales WHERE invoice_number = ?)
                         AND product_id = ?""",
                    (disc, invoice_number, pid)
                )
            conn.commit()
        except Exception:
            pass
        finally:
            if conn: conn.close()

    def open_stock_entry(self, preselected_product=None):
        """تسجيل إدخال مخزون جديد مع بحث واقتراحات فورية للمنتجات."""
        products = self.product_manager.get_all_products()
        if not products:
            self.show_message("المخزون", "لا توجد منتجات لإدخال مخزون لها.", "info")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("إدخال مخزون"))
        win.geometry("540x600")
        win.minsize(500, 560)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 540, 600)

        frame = ctk.CTkFrame(win, fg_color=self.bg())
        frame.pack(fill="both", expand=True, padx=20, pady=20)

        ctk.CTkLabel(
            frame,
            text=self.t("إدخال مخزون"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(anchor="e", pady=(5, 14))

        # البحث الذكي عن المنتج + اقتراحات فورية
        ctk.CTkLabel(
            frame, text=self.t("المنتج المراد تزويده *"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(anchor=self.align(), pady=(0, 5))

        product_search = ctk.CTkEntry(
            frame, placeholder_text=self.t("اكتب اسم المنتج أو الباركود..."),
            height=42, corner_radius=9, fg_color=self.card(),
            border_color=self.border(), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11)
        )
        product_search.pack(fill="x", pady=(0, 4))

        # إطار عادي بدل CTkScrollableFrame: أكثر ثباتًا مع تحديث الاقتراحات.
        suggestions = ctk.CTkFrame(
            frame, fg_color=self.card(), corner_radius=9,
            border_width=1, border_color=self.border(), height=0
        )
        suggestions.pack(fill="x", pady=(0, 10))
        suggestions.pack_propagate(False)

        selected_product = {"value": None}

        def clear_suggestions():
            for widget in suggestions.winfo_children():
                widget.destroy()
            suggestions.configure(height=0)

        def select_product(product):
            selected_product["value"] = product
            product_search.delete(0, "end")
            product_search.insert(0, str(product[2]))
            product_search.configure(border_color=self.colors["secondary"])
            clear_suggestions()
            render_variant_entries(product)
            if variants_state["items"]:
                variants_state["items"][0][3].focus_set()
            else:
                qty.focus_set()

        def find_matches():
            term = product_search.get().strip().casefold()
            if not term:
                return []
            exact, starts, contains = [], [], []
            for product in products:
                name = str(product[2] or "")
                barcode = str(product[1] or "")
                n, b = name.casefold(), barcode.casefold()
                if term == n or term == b:
                    exact.append(product)
                elif n.startswith(term) or b.startswith(term):
                    starts.append(product)
                elif term in n or term in b:
                    contains.append(product)
            result = exact + starts + contains
            # إزالة التكرار مع الحفاظ على الترتيب
            seen = set()
            unique = []
            for item in result:
                if item[0] not in seen:
                    seen.add(item[0])
                    unique.append(item)
            return unique[:8]

        def render_suggestions(event=None):
            selected_product["value"] = None
            product_search.configure(border_color=self.border())
            clear_suggestions()
            reset_variant_area()

            matches = find_matches()
            if not product_search.get().strip():
                return

            if not matches:
                suggestions.configure(height=38)
                ctk.CTkLabel(
                    suggestions, text=self.t("لا توجد منتجات مطابقة"),
                    text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=9)
                ).pack(fill="both", expand=True, padx=10)
                return

            row_h = 48
            suggestions.configure(height=min(8, len(matches)) * row_h + 4)

            for product in matches:
                row = ctk.CTkFrame(suggestions, fg_color="transparent", height=row_h)
                row.pack(fill="x", padx=4, pady=1)
                row.pack_propagate(False)

                info = ctk.CTkFrame(row, fg_color="transparent")
                info.pack(side="left", fill="both", expand=True, padx=8)
                ctk.CTkLabel(
                    info, text=str(product[2]), text_color=self.text(),
                    anchor="w", font=ctk.CTkFont(
                        family=self.ui_font_family, size=10, weight="bold"
                    )
                ).pack(anchor="w", pady=(4, 0))
                ctk.CTkLabel(
                    info,
                    text=self.t(f"باركود: {product[1] or 'بدون'}  •  المخزون: {product[4]} {product[5] or ''}"),
                    text_color=self.muted(), anchor="w",
                    font=ctk.CTkFont(family=self.ui_font_family, size=8)
                ).pack(anchor="w")

                ctk.CTkButton(
                    row, text=self.t("اختيار"), width=70, height=30, corner_radius=7,
                    fg_color=self.colors["primary"],
                    hover_color=self.colors["primary_hover"],
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=8, weight="bold"
                    ),
                    command=lambda p=product: select_product(p)
                ).pack(side="right", padx=5)

                row.bind("<Button-1>", lambda e, p=product: select_product(p))
                info.bind("<Button-1>", lambda e, p=product: select_product(p))

        product_search.bind("<KeyRelease>", render_suggestions)

        def choose_first(event=None):
            matches = find_matches()
            if matches:
                select_product(matches[0])
            return "break"

        product_search.bind("<Return>", choose_first)

        ctk.CTkLabel(
            frame, text=self.t("الكمية المراد إضافتها إلى المخزون *"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(anchor=self.align(), pady=(0, 5))
        qty = ctk.CTkEntry(
            frame,
            placeholder_text=self.t("أدخل الكمية المضافة"),
            height=40,
            fg_color=self.card(),
            border_color=self.border(),
            text_color=self.text()
        )
        qty.pack(fill="x", pady=6)

        # جدول إدخال كمية المتغيرات (يظهر فقط للمنتجات ذات المتغيرات).
        variants_state = {"items": []}
        variant_area = ctk.CTkFrame(frame, fg_color="transparent")

        def reset_variant_area():
            for widget in variant_area.winfo_children():
                widget.destroy()
            variants_state["items"] = []
            variant_area.pack_forget()
            qty.pack(fill="x", pady=6)

        def render_variant_entries(product):
            """عرض جدول مدخلات كمية المتغيرات إذا كان للمنتج متغيرات."""
            reset_variant_area()
            try:
                var_rows = self.db.get_product_variants(product[0])
            except Exception:
                var_rows = []
            if not var_rows:
                return
            # منتج ذو متغيرات: يُستبدل حقل الكمية الواحد بجدول المتغيرات.
            qty.pack_forget()
            variant_area.pack(fill="x", pady=(4, 0))

            header = ctk.CTkFrame(variant_area, fg_color="transparent")
            header.pack(fill="x", pady=(0, 2))
            ctk.CTkLabel(header, text=self.t("المتغير"), text_color=self.muted(), anchor="w",
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
                         ).pack(side="left", fill="x", expand=True)
            ctk.CTkLabel(header, text=self.t("المخزون الحالي"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                         width=88).pack(side="left", padx=6)
            ctk.CTkLabel(header, text=self.t("كمية الإدخال"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                         width=100).pack(side="left")

            for var_row in var_rows:
                vid, vname, _vbarcode, vstock, _vprice = var_row
                try:
                    vstock = float(vstock or 0)
                except Exception:
                    vstock = 0.0
                r = ctk.CTkFrame(variant_area, fg_color="transparent")
                r.pack(fill="x", pady=2)
                ctk.CTkLabel(r, text=str(vname), text_color=self.text(), anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=10)
                             ).pack(side="left", fill="x", expand=True)
                ctk.CTkLabel(r, text=self._format_quantity(vstock), text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=10), width=88
                             ).pack(side="left", padx=6)
                ventry = ctk.CTkEntry(r, width=100, height=32, corner_radius=8,
                                      fg_color=self.card(), border_color=self.border(),
                                      text_color=self.text(),
                                      font=ctk.CTkFont(family=self.ui_font_family, size=11))
                ventry.insert(0, "0")
                ventry.pack(side="left")
                variants_state["items"].append((vid, str(vname), vstock, ventry))

            # توسعة النافذة عموديًا إذا كان عدد المتغيرات كبيرًا.
            extra = max(0, len(var_rows) - 3) * 52
            if extra:
                win.geometry(f"540x{600 + extra}")

        ctk.CTkLabel(
            frame, text=self.t("سبب التزويد أو رقم وصل الشراء"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(anchor=self.align(), pady=(0, 5))
        reason = ctk.CTkEntry(
            frame,
            placeholder_text=self.t("مثال: فاتورة المورد رقم 104"),
            height=40,
            fg_color=self.card(),
            border_color=self.border(),
            text_color=self.text()
        )
        reason.pack(fill="x", pady=6)

        # إذا فتحنا النافذة من زر "إضافة" بجانب منتج، يتم اختياره تلقائيًا.
        if preselected_product:
            selected_product["value"] = preselected_product
            product_search.insert(0, str(preselected_product[2]))
            product_search.configure(border_color=self.colors["secondary"])
            render_variant_entries(preselected_product)
            if variants_state["items"]:
                variants_state["items"][0][3].focus_set()
            else:
                qty.focus_set()

        def save():
            try:
                product = selected_product["value"]
                if not product:
                    # إذا كان النص مطابقًا أو بدأ باسم منتج، اختر أول نتيجة تلقائيًا.
                    term = product_search.get().strip().lower()
                    for candidate in products:
                        name = str(candidate[2] or "")
                        barcode = str(candidate[1] or "")
                        if term and (term == name.lower() or term == barcode.lower()):
                            product = candidate
                            break

                if not product:
                    self.show_message("اختيار المنتج", "اختر منتجًا من الاقتراحات أولًا.", "warning")
                    product_search.focus_set()
                    return

                product_id = product[0]
                base_reason = reason.get().strip() or "إدخال مخزون"

                if variants_state["items"]:
                    # منتج ذو متغيرات: تُقرأ الكميات من جدول المتغيرات مباشرة.
                    additions = []
                    total_added = 0.0
                    for vid, vname, _vstock, ventry in variants_state["items"]:
                        raw = ventry.get().strip()
                        try:
                            add = float(raw.replace(",", ".") if raw else 0)
                        except ValueError:
                            self.show_message("خطأ", f"أدخل كمية صحيحة للمتغير: {vname}", "error")
                            return
                        if add < 0:
                            self.show_message("خطأ", f"لا يمكن إدخال كمية سالبة للمتغير: {vname}", "error")
                            return
                        if add > 0:
                            additions.append((vid, add))
                            total_added += add
                    if total_added <= 0:
                        self.show_message("خطأ", "أدخل كمية إيجابية لمتغير واحد على الأقل.", "error")
                        return
                    for vid, add in additions:
                        self.db.update_variant_stock(vid, add)
                    ok, msg = self.inventory_manager.add_stock(product_id, total_added, base_reason)
                    if not ok:
                        self.show_message("خطأ", msg, "error")
                        return
                    self.log_action(
                        "stock_entry", "product", product_id,
                        f"+{total_added:g} (عبر {len(additions)} متغير) • {base_reason}")
                else:
                    amount = float(qty.get().strip())
                    if amount <= 0:
                        raise ValueError

                    ok, msg = self.inventory_manager.add_stock(product_id, amount, base_reason)
                    if not ok:
                        self.show_message("خطأ", msg, "error")
                        return

                    self.log_action("stock_entry", "product", product_id,
                                    f"+{amount:g} • {base_reason}")

                win.destroy()
                self.show_inventory()
                self.show_message("تم", "تم إدخال المخزون وتسجيل الحركة بنجاح.", "success")

            except ValueError:
                self.show_message("خطأ", "أدخل كمية صحيحة أكبر من صفر.", "error")
            except Exception as e:
                self.show_message("خطأ", str(e), "error")

        buttons = ctk.CTkFrame(frame, fg_color="transparent")
        buttons.pack(fill="x", pady=(18, 6))

        ctk.CTkButton(
            buttons,
            text=self.t("✓ حفظ"),
            command=save,
            height=44,
            fg_color=self.colors["secondary"],
            hover_color=self.colors["secondary_hover"]
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            buttons,
            text=self.t("إلغاء"),
            command=win.destroy,
            height=44,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border()
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        product_search.focus_set()

    # =========================================================
    # Packs (Bundles)
    # =========================================================

    def show_packs(self):
        """صفحة الباقات: بطاقات بها الاسم والسعر وعدد المكونات وحالة التفعيل."""
        if not self._guard_db_nav("الباقات", "إدارة باقات المنتجات", "packs"):
            return
        self.clear_content()
        self.current_page = "packs"
        self.highlight_nav()

        self.page_header(
            " الباقات",
            "تعريف مجموعات من المنتجات تُباع بسعر ثابت مع خصم تلقائي من مخزون كل مكون"
        )

        top = ctk.CTkFrame(self.content_area, fg_color="transparent")
        top.pack(fill="x", pady=(0, 12))
        ctk.CTkButton(
            top, text=self.t("+  باقة جديدة"), command=lambda: self._open_pack_form(),
            height=42, corner_radius=10,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side="right")

        scroll = ctk.CTkScrollableFrame(self.content_area, fg_color="transparent")
        scroll.pack(fill="both", expand=True)

        try:
            packs = self.packs_manager.get_all_packs()
        except Exception:
            packs = []

        if not packs:
            ctk.CTkLabel(
                scroll, text=self.t("لا توجد باقات بعد. اضغط «+ باقة جديدة» لإنشاء الأولى"),
                font=ctk.CTkFont(family=self.ui_font_family, size=13),
                text_color=self.muted()
            ).pack(pady=40)
            return

        for pack in packs:
            try:
                pack_id, name, price, is_active, cnt = int(pack[0]), str(pack[1]), float(pack[2] or 0), int(pack[3] or 0), int(pack[4] or 0)
            except Exception:
                continue
            row = self.make_card(scroll)
            row.pack(fill="x", pady=5)

            info = ctk.CTkFrame(row, fg_color="transparent")
            info.pack(side="left", fill="x", expand=True, padx=14, pady=12)
            ctk.CTkLabel(
                info, text=self.t(f"{name}   {'✓' if is_active else '✗ مغلقة'}"),
                font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
                text_color=self.colors["secondary"] if is_active else self.muted()
            ).pack(anchor="w")
            ctk.CTkLabel(
                info, text=self.t(f"{cnt} مكون • {price:,.2f} د.ج"),
                font=ctk.CTkFont(family=self.ui_font_family, size=11),
                text_color=self.muted()
            ).pack(anchor="w", pady=(2, 0))

            actions = ctk.CTkFrame(row, fg_color="transparent")
            actions.pack(side="right", padx=10)

            toggle_text = self.t("تعطيل") if is_active else self.t("تفعيل")
            ctk.CTkButton(
                actions, text=toggle_text,
                command=lambda pid=pack_id, act=is_active: self._toggle_pack(pid, act),
                width=72, height=34, corner_radius=8,
                fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                border_width=1, border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(side="right", padx=(6, 0))
            ctk.CTkButton(
                actions, text=self.t("تعديل"),
                command=lambda pid=pack_id: self._edit_pack(pid),
                width=72, height=34, corner_radius=8,
                fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                border_width=1, border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(side="right", padx=(6, 0))
            ctk.CTkButton(
                actions, text=self.t("حذف"),
                command=lambda pid=pack_id, nm=name: self._delete_pack(pid, nm),
                width=72, height=34, corner_radius=8,
                fg_color=self.colors.get("danger", "#b91c1c"),
                hover_color=self.colors.get("danger_hover", "#991b1b"),
                text_color="white",
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(side="right")

    def _toggle_pack(self, pack_id, is_active):
        ok = self.packs_manager.set_active(pack_id, not bool(is_active))
        if ok:
            self.toast("تم تحديث حالة الباقة")
            self.show_packs()
        else:
            self.toast(self.packs_manager.last_error or "تعذر التحديث", "danger")

    def _delete_pack(self, pack_id, name):
        if not self.confirm("حذف الباقة", f"هل تريد حذف الباقة «{name}»؟"):
            return
        ok, msg = self.packs_manager.delete_pack(pack_id)
        self.toast(msg, "success" if ok else "danger")
        if ok:
            self.log_action("pack_delete", "pack", pack_id, name)
            self.show_packs()

    def _edit_pack(self, pack_id):
        pack = self.packs_manager.get_pack(pack_id)
        if pack:
            self._open_pack_form(pack=pack)

    def _open_pack_form(self, pack=None):
        """نافذة إنشاء/تعديل باقة: الاسم، السعر، واختيار المنتجات المكونة مع قيمها."""
        is_edit = pack is not None
        pack_id = pack[0] if is_edit else None

        win = ctk.CTkToplevel(self)
        win.title(self.t("تعديل باقة") if is_edit else self.t("باقة جديدة"))
        win.geometry("680x720")
        win.transient(self)
        win.grab_set()
        self.center_window(win, 680, 720)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)
        ctk.CTkLabel(container, text=self.t("تعديل الباقة") if is_edit else self.t("باقة جديدة"),
                     text_color=self.text(), anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")).pack(fill="x", pady=(4, 6))

        body = ctk.CTkScrollableFrame(container, fg_color="transparent")
        body.pack(fill="both", expand=True)

        name_entry = ctk.CTkEntry(body, height=38, corner_radius=9, fg_color=self.card(),
                                  border_color=self.border(), text_color=self.text(),
                                  font=ctk.CTkFont(family=self.ui_font_family, size=12),
                                  placeholder_text=self.t("اسم الباقة"))
        name_entry.pack(fill="x", pady=5)
        if is_edit:
            name_entry.insert(0, str(pack[1]))

        price_row = ctk.CTkFrame(body, fg_color="transparent")
        price_row.pack(fill="x", pady=5)
        price_entry = ctk.CTkEntry(price_row, height=38, corner_radius=9, fg_color=self.card(),
                                   border_color=self.border(), text_color=self.text(),
                                   font=ctk.CTkFont(family=self.ui_font_family, size=12),
                                   placeholder_text=self.t("سعر الباقة"))
        price_entry.pack(side="left", fill="x", expand=True)
        sum_label = ctk.CTkLabel(price_row, text=self.t("سعر المجموع: 0.00 د.ج"),
                                 text_color=self.muted(),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=10))
        sum_label.pack(side="right", padx=(10, 0))

        profit_label = ctk.CTkLabel(
            body,
            text=self.t(f"{self.t('الربح عن البيع الفردي')}: 0.00 د.ج"),
            text_color=self.colors.get("success", self.colors["secondary"]),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
        )
        profit_label.pack(fill="x", pady=(0, 4))
        if is_edit:
            price_entry.insert(0, str(pack[2]))

        # ===== اختيار المنتج =====
        pick = ctk.CTkFrame(body, fg_color="transparent")
        pick.pack(fill="x", pady=(10, 5))
        ctk.CTkLabel(pick, text=self.t("إضافة منتج للباقة:"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")).pack(anchor="w", pady=(0, 5))

        search_entry = ctk.CTkEntry(pick, height=34, corner_radius=8, fg_color=self.card(),
                                    border_color=self.border(), text_color=self.text(),
                                    font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                    placeholder_text=self.t("بحث بالاسم أو الباركود"))
        search_entry.pack(fill="x", pady=3)

        # إطار عادي بدل CTkScrollableFrame كما في open_stock_entry: أكثر ثباتًا
        # مع تحديث الاقتراحات ولا يتأثر بوجود داخله داخل ScrollableFrame خارجي.
        suggestions = ctk.CTkFrame(pick, fg_color=self.card(), corner_radius=8,
                                   border_width=1, border_color=self.border(), height=0)
        suggestions.pack(fill="x", pady=3)
        suggestions.pack_propagate(False)

        # ===== قائمة المكونات =====
        ctk.CTkLabel(body, text=self.t("مكونات الباقة:"), text_color=self.text(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")).pack(anchor="w", pady=(6, 5))
        comp_list = ctk.CTkFrame(body, fg_color="transparent")
        comp_list.pack(fill="both", expand=True)

        # حالة النافذة
        all_products = []
        try:
            all_products = list(self.product_manager.get_all_products())
        except Exception:
            all_products = []

        if is_edit:
            comp_items = self.packs_manager.get_pack_items(pack_id)
            # comp_rows: قائمة dict {product_id, name, qty, price}
            comp_rows = [
                {"product_id": int(c[0]), "name": str(c[1]), "qty": float(c[2]), "price": float(c[3] or 0)}
                for c in comp_items
            ]
        else:
            comp_rows = []

        def refresh_profit():
            try:
                pack_price = float(price_entry.get().replace(",", "").strip() or 0)
            except ValueError:
                pack_price = 0.0
            parts_total = sum(float(r["qty"] or 0) * float(r["price"] or 0) for r in comp_rows)
            profit = pack_price - parts_total
            if profit > 0:
                color = self.colors.get("success", self.colors["secondary"])
            else:
                color = self.colors.get("danger", "#F43F5E")
            profit_label.configure(
                text=self.t(f"{self.t('الربح عن البيع الفردي')}: {profit:+,.2f} د.ج"),
                text_color=color,
            )

        def refresh_parts_sum():
            total = sum(float(r["qty"] or 0) * float(r["price"] or 0) for r in comp_rows)
            sum_label.configure(text=self.t(f"سعر المجموع: {total:,.2f} د.ج"))
            refresh_profit()

        def render_comps():
            for w in comp_list.winfo_children():
                w.destroy()
            for idx, r in enumerate(comp_rows):
                rw = ctk.CTkFrame(comp_list, fg_color="transparent")
                rw.pack(fill="x", pady=2)
                ctk.CTkLabel(rw, text=self.t(f"{r['name']} × {self._format_quantity(r['qty'], 'قطعة')}"),
                             text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(side="left", padx=4)
                ctk.CTkLabel(rw, text=self.t(f"= {float(r['qty'] or 0) * float(r['price'] or 0):,.2f} د.ج"),
                             text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(side="right")
                ctk.CTkButton(rw, text="✕", width=28, height=26,
                              command=lambda i=idx: (comp_rows.pop(i), render_comps(), refresh_parts_sum()),
                              fg_color=self.colors.get("danger", "#b91c1c"),
                              hover_color=self.colors.get("danger_hover", "#991b1b"),
                              text_color="white",
                              font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(side="right", padx=4)
            refresh_parts_sum()

        def clear_suggestions():
            for w in suggestions.winfo_children():
                w.destroy()
            suggestions.configure(height=0)

        def update_suggestions(*_):
            clear_suggestions()
            term = search_entry.get().strip().lower()
            if not term:
                return
            added_ids = {int(r["product_id"]) for r in comp_rows}
            matches = []
            for p in all_products:
                pname = str(p[2] or "")
                pbarcode = str(p[1] or "")
                if term not in pname.lower() and term not in pbarcode.lower():
                    continue
                if int(p[0]) in added_ids:
                    continue
                matches.append(p)
                if len(matches) >= 6:
                    break
            if not matches:
                suggestions.configure(height=38)
                ctk.CTkLabel(
                    suggestions, text=self.t("لا توجد منتجات مطابقة"),
                    text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=10)
                ).pack(fill="both", expand=True, padx=10)
                return
            row_h = 32
            suggestions.configure(height=len(matches) * (row_h + 2) + 4)
            for p in matches:
                pname = str(p[2] or "")
                b = ctk.CTkButton(
                    suggestions, text=self.t(f"{pname} — {float(p[3] or 0):,.2f} د.ج"),
                    anchor="w", height=row_h, corner_radius=6,
                    fg_color="transparent",
                    hover_color=self.border(), text_color=self.text(),
                    command=lambda row=p: add_component_by_id(int(row[0]), str(row[2]), float(row[3] or 0)),
                )
                b.pack(fill="x", padx=2, pady=1)

        def add_component_by_id(pid, pname, pprice):
            # تجنب التكرار
            if any(r["product_id"] == pid for r in comp_rows):
                self.toast("المنتج موجود بالفعل في الباقة", "warning")
                return
            qty_row = ctk.CTkToplevel(win)
            qty_row.title(self.t("الكمية"))
            qty_row.geometry("320x160")
            qty_row.transient(win)
            qty_row.grab_set()
            self.center_window(qty_row, 320, 160)
            ctk.CTkLabel(qty_row, text=self.t(f"كمية «{pname}» داخل الباقة:"),
                         text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(padx=14, pady=(12, 6))
            qty_box = ctk.CTkEntry(qty_row, font=ctk.CTkFont(family=self.ui_font_family, size=12))
            qty_box.insert(0, "1")
            qty_box.pack(fill="x", padx=14, pady=4)

            def add_qty():
                try:
                    q = float(qty_box.get())
                except ValueError:
                    self.toast("أدخل كمية صحيحة", "danger")
                    return
                if q <= 0:
                    self.toast("الكمية يجب أن تكون أكبر من صفر", "danger")
                    return
                comp_rows.append({"product_id": pid, "name": pname, "qty": q, "price": pprice})
                qty_row.destroy()
                render_comps()
                update_suggestions()

            ctk.CTkButton(qty_row, text=self.t("إضافة"), command=add_qty,
                          height=34, corner_radius=8,
                          fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                          font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(padx=14, pady=6, fill="x")

        search_entry.bind("<KeyRelease>", update_suggestions)
        price_entry.bind("<KeyRelease>", lambda _e: refresh_profit())

        bottom = ctk.CTkFrame(container, fg_color="transparent")
        bottom.pack(fill="x", pady=(10, 0))

        def save():
            name = name_entry.get().strip()
            if not name:
                self.toast("اسم الباقة مطلوب", "danger")
                return
            try:
                price = float(price_entry.get())
            except ValueError:
                self.toast("سعر الباقة غير صحيح", "danger")
                return
            if price < 0:
                self.toast("السعر لا يمكن أن يكون سالبًا", "danger")
                return
            if not comp_rows:
                self.toast("أضف منتجًا واحدًا على الأقل للباقة", "danger")
                return
            items = [(r["product_id"], r["qty"]) for r in comp_rows]
            if is_edit:
                ok, res = self.packs_manager.update_pack(pack_id, name, price, items, None, is_active=pack[4])
                if ok:
                    self.log_action("pack_update", "pack", pack_id, f"{name} • {price:,.2f} دج")
                    win.destroy()
                    self.toast("✓ تم تحديث الباقة")
                    self.show_packs()
                else:
                    self.toast(res, "danger")
            else:
                ok, res = self.packs_manager.add_pack(name, price, items, None)
                if ok:
                    self.log_action("pack_create", "pack", res, f"{name} • {price:,.2f} دج")
                    win.destroy()
                    self.toast("✓ تم إنشاء الباقة")
                    self.show_packs()
                else:
                    self.toast(res, "danger")

        ctk.CTkButton(bottom, text=self.t("حفظ"), command=save, height=42, corner_radius=9,
                      fg_color=self.colors["secondary"], hover_color=self.colors["secondary_hover"],
                      font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
                      ).pack(side="left", fill="x", expand=True, padx=(0, 4))
        ctk.CTkButton(bottom, text=self.t("إلغاء"), command=win.destroy, height=42, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=10)
                      ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        if is_edit:
            render_comps()
        else:
            render_comps()
        update_suggestions()

    # -------------------------------------------------
    # POS helpers for packs
    # -------------------------------------------------
    def _pack_cart_line(self, pack_id, quantity):
        """يبني عنصر سلة لباقة مع مكوناتها للتحقق من المخزون وعرضها مجمعة."""
        pack = self.packs_manager.get_pack(pack_id)
        if not pack:
            return None
        items = self.packs_manager.get_pack_items(pack_id)
        if not items:
            return None
        components = [
            {"product_id": int(i[0]), "name": str(i[1]), "unit_qty": float(i[2]), "unit_price": float(i[3] or 0)}
            for i in items
        ]
        return {
            "is_pack": True,
            "pack_id": int(pack_id),
            "id": -int(pack_id),
            "name": str(pack[1]),
            "price": float(pack[2] or 0),
            "quantity": float(quantity),
            "unit": "باقة",
            "total": float(pack[2] or 0) * float(quantity),
            "components": components,
        }

    def _validate_pack_in_cart(self, components, total_qty):
        """يتحقق من توفر مخزون كل مكون (الكمية المطلوبة = unit_qty × عدد الباقات).

        يعيد (ok, error_message).
        """
        conn = None
        try:
            conn = self.db.get_connection()
            for comp in components:
                row = conn.execute(
                    "SELECT name, quantity FROM products WHERE id = ?", (int(comp["product_id"]),)
                ).fetchone()
                if not row:
                    return False, "منتج مكوّن لم يعد موجودًا"
                available = float(row[1] or 0)
                needed = float(comp["unit_qty"]) * float(total_qty)
                if available < needed - 1e-9:
                    return False, (
                        f"مخزون غير كافٍ لـ «{row[0]}»: مطلوب {needed:g}، "
                        f"متوفر {available:g}"
                    )
            return True, ""
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    # =========================================================
    # Products
    # =========================================================

    def show_products(self):
        if not self._guard_db_nav("المنتجات", "إدارة المنتجات", "products"):
            return
        self.clear_content()
        self.current_page = "products"
        self.highlight_nav()

        self.page_header(
            " إدارة المنتجات",
            "البحث والتعديل وإدارة المخزون"
        )

        toolbar = ctk.CTkFrame(
            self.content_area,
            fg_color="transparent"
        )
        toolbar.pack(fill="x", pady=(0, 10))

        search_box = self.make_card(toolbar)
        search_box.pack(side="left", fill="x", expand=True, padx=(0, 8))

        ctk.CTkLabel(
            search_box,
            text="⌕",
            font=ctk.CTkFont(family=self.ui_font_family,size=16)
        ).pack(side="left", padx=(12, 4))

        self.search_entry = ctk.CTkEntry(
            search_box,
            placeholder_text=self.t("ابحث بالاسم أو الباركود..."),
            height=40,
            fg_color="transparent",
            border_width=0,
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=13)
        )
        self.search_entry.pack(side="left", fill="x", expand=True, padx=4)
        self.search_entry.bind("<KeyRelease>", self.filter_products)

        ctk.CTkButton(
            toolbar,
            text=self.t("+ منتج جديد"),
            command=self.show_add_product_form,
            height=40,
            width=125,
            corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
        ).pack(side="right", padx=4)

        ctk.CTkButton(
            toolbar,
            text=self.t("⟳ تحديث"),
            command=self.show_products,
            height=40,
            width=90,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=12)
        ).pack(side="right")

        filters = ctk.CTkFrame(self.content_area, fg_color="transparent", height=38)
        filters.pack(fill="x", pady=(0, 8))
        filters.pack_propagate(False)
        self.product_filter_buttons = []

        for key, label in (
            ("all", self.t("الكل")),
            ("available", self.t("متوفر")),
            ("low", self.t("منخفض")),
            ("out", self.t("نفد"))
        ):
            btn = ctk.CTkButton(
                filters,text=label,
                command=lambda k=key: self.set_product_filter(k),
                width=78,height=30,corner_radius=8,
                fg_color=self.colors["primary"] if self.product_filter == key else self.bg(),
                hover_color=self.colors["primary_hover"] if self.product_filter == key else self.border(),
                text_color="white" if self.product_filter == key else self.muted(),
                border_width=0 if self.product_filter == key else 1,
                border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family,size=9,weight="bold")
            )
            btn.pack(side="left", padx=(0,5))
            self.product_filter_buttons.append((key,btn))

        # فلتر التصنيفات — يُدمج مع فلتر الحالة والبحث (AND).
        _cats, _cat_values = self._category_filter_options()
        self.product_category_combo = ctk.CTkComboBox(
            filters,
            values=_cat_values,
            width=150,
            height=30,
            corner_radius=8,
            fg_color=self.card(),
            border_color=self.border(),
            button_color=self.colors["primary"],
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9),
            command=lambda _v: self.render_products(
                self.search_entry.get().strip() if hasattr(self, "search_entry") else ""
            )
        )
        self.product_category_combo.set(self.t("كل التصنيفات"))
        self.product_category_combo.pack(side="right", padx=(0, 5))

        self.products_container = ctk.CTkScrollableFrame(
            self.content_area,
            fg_color="transparent"
        )
        self.products_container.pack(fill="both", expand=True)

        self.render_products()

        self.after(100, lambda: self._focus_if_alive(self.search_entry))

    def set_product_filter(self, key):
        self.product_filter = key
        for k, btn in getattr(self, "product_filter_buttons", []):
            active = k == key
            btn.configure(
                fg_color=self.colors["primary"] if active else self.bg(),
                hover_color=self.colors["primary_hover"] if active else self.border(),
                text_color="white" if active else self.muted(),
                border_width=0 if active else 1
            )
        term = self.search_entry.get().strip() if hasattr(self, "search_entry") else ""
        self.product_page = 1
        self.render_products(term)

    def filter_products(self, event=None):
        if self.search_after_id:
            self.after_cancel(self.search_after_id)

        self.product_page = 1
        self.search_after_id = self.after(
            250,
            lambda: self.render_products(
                self.search_entry.get().strip()
            )
        )

    def render_products(self, search_term=""):
        if not hasattr(self, "products_container"):
            return

        for widget in self.products_container.winfo_children():
            widget.destroy()

        try:
            if search_term:
                products = self.product_manager.search_product(search_term)
            else:
                products = self.product_manager.get_all_products()
        except Exception as exc:
            self.toast(f"خطأ في تحميل المنتجات: {exc}", "danger")
            return

        # فلتر التصنيف (AND مع الحالة والبحث).
        cat_selection = None
        if hasattr(self, "product_category_combo"):
            try:
                cat_selection = str(self.product_category_combo.get() or "").strip()
            except Exception:
                cat_selection = None
        if cat_selection and self._to_ar(cat_selection) != "كل التصنيفات":
            categories = self._load_categories()
            products = [p for p in products if self._match_category_filter(p, cat_selection, categories)]

        filtered = []
        for product in products:
            try:
                qty = float(product[4] or 0)
            except Exception:
                qty = 0

            if self.product_filter == "available" and qty <= 5:
                continue
            if self.product_filter == "low" and not (0 < qty <= 5):
                continue
            if self.product_filter == "out" and qty > 0:
                continue
            filtered.append(product)

        products = filtered

        if not products:
            self.empty_state(
                self.products_container,
                "",
                "لا توجد منتجات في هذا التصنيف",
                "جرّب تغيير الفلتر أو البحث",
                self.show_add_product_form
            )
            return

        # الترحيل (pagination): نعرض صفحة محدودة فقط لتجنّب بناء آلاف الويدجت دفعة واحدة.
        page_size = getattr(self, "product_page_size", 40)
        total = len(products)
        max_page = max(1, -(-total // page_size))
        if not getattr(self, "product_page", None):
            self.product_page = 1
        self.product_page = min(max(self.product_page, 1), max_page)
        page_products = products[(self.product_page - 1) * page_size:self.product_page * page_size]

        # Header
        header = ctk.CTkFrame(
            self.products_container,
            fg_color=self.card(),
            corner_radius=14
        )
        header.pack(fill="x", pady=(0, 5))

        columns = [
            (self.t("المنتج"), 0),
            (self.t("السعر"), 1),
            (self.t("الكمية"), 2),
            (self.t("الحالة"), 3),
            (self.t("إجراءات"), 4),
        ]

        for label, _ in columns:
            ctk.CTkLabel(
                header,
                text=label,
                font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold"),
                text_color=self.muted()
            ).pack(side="left", fill="x", expand=True, padx=10, pady=9)

        # Rows
        for product in page_products:
            self.product_row(product)

        # شريط الترحيل أسفل الجدول.
        self._render_products_pager(total, page_size, max_page)

    def _render_products_pager(self, total, page_size, max_page):
        if max_page <= 1:
            return
        pager = ctk.CTkFrame(
            self.products_container, fg_color="transparent"
        )
        pager.pack(fill="x", pady=(8, 4))
        info = self.t(f"{self.product_page} / {max_page} • {total} منتج")
        ctk.CTkLabel(
            pager, text=info, text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="left", padx=4)
        nav = ctk.CTkFrame(pager, fg_color="transparent")
        nav.pack(side="right")
        for label, delta in (("‹", -1), ("›", 1)):
            enabled = 1 <= self.product_page + delta <= max_page
            ctk.CTkButton(
                nav, text=label, width=32, height=28, corner_radius=7,
                fg_color=self.card(), hover_color=self.border(),
                text_color=self.text(),
                state="normal" if enabled else "disabled",
                font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
                command=(lambda d=delta: self._products_go_page(self.product_page + d) if enabled else None)
            ).pack(side="left", padx=2)

    def _products_go_page(self, pg):
        self.product_page = pg
        term = self.search_entry.get().strip() if hasattr(self, "search_entry") else ""
        # scroll back to top so the first row of the page is visible
        try:
            self.products_container._parent_canvas.yview_moveto(0)
        except Exception:
            pass
        self.render_products(term)

    def product_row(self, p):
        row = ctk.CTkFrame(
            self.products_container,
            fg_color=self.card(),
            corner_radius=14
        )
        row.pack(fill="x", pady=3)

        name_box = ctk.CTkFrame(row, fg_color="transparent")
        name_box.pack(side="left", fill="x", expand=True, padx=10, pady=7)

        ctk.CTkLabel(
            name_box,
            text=str(p[2]),
            font=ctk.CTkFont(family=self.ui_font_family,size=13, weight="bold"),
            text_color=self.text(),
            anchor="w"
        ).pack(anchor="w")

        if p[1]:
            ctk.CTkLabel(
                name_box,
                text=f"#{p[1]}",
                font=ctk.CTkFont(family=self.ui_font_family,size=10),
                text_color=self.muted(),
                anchor="w"
            ).pack(anchor="w")

        # اسم التصنيف كعنوان صغير تحت اسم المنتج.
        if len(p) > 7 and p[7]:
            ctk.CTkLabel(
                name_box,
                text=f"🏷 {p[7]}",
                font=ctk.CTkFont(family=self.ui_font_family,size=9),
                text_color=self.muted(),
                anchor="w"
            ).pack(anchor="w")

        price_box = ctk.CTkFrame(row, fg_color="transparent", width=130)
        price_box.pack(side="left", fill="y", padx=5)
        price_box.pack_propagate(False)

        ctk.CTkLabel(
            price_box,
            text=self.t(f"{float(p[3]):,.2f} د.ج"),
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold"),
            text_color=self.colors["secondary"]
        ).pack(anchor="w", pady=11)

        qty = float(p[4] or 0)
        qty_box = ctk.CTkFrame(row, fg_color="transparent", width=120)
        qty_box.pack(side="left", fill="y", padx=5)
        qty_box.pack_propagate(False)

        qty_color = (
            self.colors["danger"] if qty <= 0
            else self.colors["accent"] if qty <= 5
            else self.colors["secondary"]
        )

        ctk.CTkLabel(
            qty_box,
            text=self.t(f"{qty} {p[5] or 'قطعة'}"),
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold"),
            text_color=qty_color
        ).pack(anchor="w", pady=11)

        status_box = ctk.CTkFrame(row, fg_color="transparent", width=120)
        status_box.pack(side="left", fill="y", padx=5)
        status_box.pack_propagate(False)

        if qty <= 0:
            status, color = self.t("نفد المخزون"), self.colors["danger"]
        elif qty <= 5:
            status, color = self.t("مخزون منخفض"), self.colors["accent"]
        else:
            status, color = self.t("متوفر"), self.colors["secondary"]

        badge = ctk.CTkLabel(
            status_box,
            text=status,
            fg_color=color,
            corner_radius=8,
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        )
        badge.pack(anchor="w", pady=10, ipadx=7, ipady=3)

        actions = ctk.CTkFrame(
            row,
            fg_color="transparent",
            width=100
        )
        actions.pack(side="right", fill="y", padx=8)
        actions.pack_propagate(False)

        ctk.CTkButton(
            actions,
            text="✏",
            width=35,
            height=31,
            corner_radius=8,
            fg_color="transparent",
            hover_color=self.border(),
            text_color=self.text(),
            command=lambda pid=p[0]: self.edit_product(pid)
        ).pack(side="left", padx=2, pady=7)

        ctk.CTkButton(
            actions,
            text=self.t("حذف"),
            width=35,
            height=31,
            corner_radius=8,
            fg_color="transparent",
            hover_color=self.colors["danger"],
            text_color=self.colors["danger"],
            command=lambda pid=p[0]: self.delete_product(pid)
        ).pack(side="left", padx=2, pady=7)

    def empty_state(self, parent, icon, title, subtitle, command=None):
        title = self.t(title)
        subtitle = self.t(subtitle)
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.pack(fill="both", expand=True, pady=70)

        ctk.CTkLabel(
            frame,
            text=icon,
            font=ctk.CTkFont(family=self.ui_font_family,size=48)
        ).pack(pady=(10, 8))

        ctk.CTkLabel(
            frame,
            text=title,
            font=ctk.CTkFont(family=self.ui_font_family,size=18, weight="bold"),
            text_color=self.text()
        ).pack()

        ctk.CTkLabel(
            frame,
            text=subtitle,
            font=ctk.CTkFont(family=self.ui_font_family,size=12),
            text_color=self.muted()
        ).pack(pady=(5, 15))

        if command:
            ctk.CTkButton(
                frame,
                text=self.t("+ إضافة"),
                command=command,
                width=120,
                height=38,
                corner_radius=9,
                fg_color=self.colors["primary"],
                hover_color=self.colors["primary_hover"]
            ).pack()

    def _load_thumbnail(self, image_path, max_width, max_height):
        """تحميل صورة + تصغيرها مرة واحدة ثم الاحتفاظ بـ CTkImage جاهز.

        يُخزَّن في self._image_cache بمفتاح (المسار، الأبعاد) حتى لا نعيد
        فتح/تصغير PIL في كل مرة يُعاد فيها رسم بطاقة أو صف.
        """
        if not image_path or Image is None:
            return None
        try:
            path = str(image_path)
            if not os.path.isabs(path):
                project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                path = os.path.join(project_root, path)
            if not os.path.isfile(path):
                return None
        except Exception:
            return None

        key = (path, max_width, max_height)
        cached = self._image_cache.get(key)
        if cached is not None:
            return cached

        try:
            img = Image.open(path).convert("RGB")
            img.thumbnail((max_width, max_height), Image.Resampling.LANCZOS)
            photo = ctk.CTkImage(
                light_image=img, dark_image=img,
                size=(img.width, img.height)
            )
        except Exception:
            return None
        self._image_cache[key] = photo

        # كبح حجم الذاكرة: لا نخزن أكثر من ~96 صورة مصغّرة.
        if len(self._image_cache) > 96:
            try:
                oldest = next(iter(self._image_cache))
                self._image_cache.pop(oldest, None)
            except Exception:
                pass
        return photo

    def _get_images_map(self, ids):
        """Batch-load {product_id: image_path} for many ids in a single query.

        Avoids the per-card N SELECTs that _product_image_path would otherwise
        issue when rendering the POS grid (large catalog => N+1 queries).
        """
        ids = [int(i) for i in ids if i is not None]
        if not ids:
            return {}
        result = {}
        conn = None
        try:
            conn = self.db.get_connection()
            cur = conn.cursor()
            ph = ",".join("?" for _ in ids)
            cur.execute(
                "SELECT id, image_path FROM products WHERE id IN (%s)" % ph,
                ids,
            )
            for row in cur.fetchall():
                result[row[0]] = row[1]
            conn.close()
        except Exception:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            return {}
        return result

    def _product_image_path(self, product_id):
        """Return the stored product image path independently of ProductManager column order."""
        conn = None
        try:
            conn = self.db.get_connection()
            cur = conn.cursor()
            cur.execute("SELECT image_path FROM products WHERE id = ?", (product_id,))
            row = cur.fetchone()
            conn.close()
            return row[0] if row and row[0] else None
        except Exception:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            return None

    def _save_product_image_path(self, product_id, image_path):
        conn = None
        try:
            conn = self.db.get_connection()
            cur = conn.cursor()
            cur.execute("UPDATE products SET image_path = ? WHERE id = ?", (image_path, product_id))
            conn.commit()
            conn.close()
            try:
                p = str(image_path)
                if not os.path.isabs(p):
                    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    p = os.path.join(project_root, p)
                for key in [k for k in self._image_cache if k[0] == p]:
                    self._image_cache.pop(key, None)
            except Exception:
                pass
            return True
        except Exception:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            return False

    def _open_product_form(self, title, product=None):
        is_edit = product is not None
        win = ctk.CTkToplevel(self)
        win.title(title)
        win.geometry("620x700")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 620, 700)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)
        ctk.CTkLabel(container, text=title, text_color=self.text(), anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=21, weight="bold")).pack(fill="x", pady=(4, 12))

        body = ctk.CTkScrollableFrame(container, fg_color="transparent")
        body.pack(fill="both", expand=True)
        entries = {}
        values = {
            "الاسم": str(product[2]) if is_edit else "",
            "السعر": str(product[3]) if is_edit else "",
            "سعر الشراء": str(product[4] or 0) if is_edit else "0",
            "الكمية": str(product[5]) if is_edit else "",
            "الباركود": str(product[1] or "") if is_edit else "",
        }

        field_specs = [
            ("الاسم", self.t("اسم المنتج *"), self.t("مثال: حليب كانديا 1 لتر")),
            ("السعر", self.t("سعر البيع (د.ج) *"), self.t("مثال: 120.00")),
            ("سعر الشراء", self.t("سعر الشراء / التكلفة (د.ج)"), self.t("مثال: 95.00")),
            ("الكمية", self.t("الكمية المتوفرة بالمخزون *"), self.t("مثال: 50 أو 1.5 للوزن")),
            ("الباركود", self.t("الباركود أو الرمز التعريفي (Barcode / SKU)"), self.t("امسح بالماسح أو اتركه فارغاً للتوليد التلقائي")),
        ]

        def add_entry(key, label, value, placeholder=""):
            ctk.CTkLabel(
                body, text=label, anchor=self.align(),
                font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                text_color=self.muted()
            ).pack(fill="x", pady=(8, 3))
            entry = ctk.CTkEntry(body, height=38, corner_radius=9, fg_color=self.card(),
                                 border_color=self.border(), text_color=self.text(),
                                 placeholder_text=self.t(placeholder),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=12))
            entry.pack(fill="x", pady=(0, 4))
            if value:
                entry.insert(0, value)
            entries[key] = entry

        for key, label, placeholder in field_specs:
            add_entry(key, label, values[key], placeholder)

        # الوحدة — وحدة القياس.
        ctk.CTkLabel(
            body, text=self.t("وحدة القياس"), anchor=self.align(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            text_color=self.muted()
        ).pack(fill="x", pady=(8, 3))
        units = [self.t(u) for u in ["قطعة", "كغ", "غرام", "لتر", "مل", "متر"]]
        unit_box = ctk.CTkComboBox(body, values=units, height=38, corner_radius=9,
                                   fg_color=self.card(), border_color=self.border(),
                                   button_color=self.colors["primary"], text_color=self.text())
        unit_box.pack(fill="x", pady=(0, 4))
        unit_box.set(self.t(str(product[6] or "قطعة")) if is_edit else self.t("قطعة"))

        # اختيار تصنيف المنتج (اختياري).
        categories = self._load_categories()
        cat_values = [self.t("بدون تصنيف")] + [str(c[1]) for c in categories]
        ctk.CTkLabel(
            body, text=self.t("تصنيف المنتج"), anchor=self.align(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            text_color=self.muted()
        ).pack(fill="x", pady=(8, 3))
        category_box = ctk.CTkComboBox(body, values=cat_values, height=38, corner_radius=9,
                                       fg_color=self.card(), border_color=self.border(),
                                       button_color=self.colors["primary"], text_color=self.text())
        category_box.pack(fill="x", pady=(0, 4))
        current_cat_id = self._get_product_category_id(product[0]) if is_edit else None
        current_cat_name = next((str(c[1]) for c in categories if c[0] == current_cat_id), self.t("بدون تصنيف"))
        category_box.set(current_cat_name if current_cat_name in cat_values else self.t("بدون تصنيف"))

        image_row = ctk.CTkFrame(body, fg_color="transparent")
        image_row.pack(fill="x", pady=(10, 5))
        ctk.CTkLabel(image_row, text=self.t("صورة المنتج"), width=115, anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
                     text_color=self.muted()).pack(side="left", anchor="n", pady=8)
        preview = ctk.CTkFrame(image_row, width=125, height=105, fg_color=self.card(),
                               corner_radius=10, border_width=1, border_color=self.border())
        preview.pack(side="left")
        preview.pack_propagate(False)
        image_label = ctk.CTkLabel(preview, text=self.t("لا توجد صورة"), text_color=self.muted())
        image_label.place(relx=0.5, rely=0.5, anchor="center")
        selected = {"path": self._product_image_path(product[0]) if is_edit else None}

        def show_image(path):
            if not path or Image is None or not os.path.isfile(str(path)):
                image_label.configure(image=None, text=self.t("لا توجد صورة"))
                image_label.image = None
                return
            try:
                photo = self._load_thumbnail(path, 105, 90)
                if photo is not None:
                    image_label.configure(image=photo, text="")
                    image_label.image = photo
                else:
                    image_label.configure(image=None, text=self.t("صورة غير صالحة"))
                    image_label.image = None
            except Exception:
                image_label.configure(image=None, text=self.t("صورة غير صالحة"))
                image_label.image = None

        def choose_image():
            path = filedialog.askopenfilename(title=self.t("اختيار صورة المنتج"),
                filetypes=[("Images", "*.png *.jpg *.jpeg *.webp *.bmp"), ("All files", "*.*")])
            if path:
                selected["path"] = path
                show_image(path)

        def clear_image():
            selected["path"] = None
            show_image(None)

        buttons = ctk.CTkFrame(image_row, fg_color="transparent")
        buttons.pack(side="left", fill="x", expand=True, padx=(10, 0))
        ctk.CTkButton(buttons, text=self.t("اختيار صورة"), height=36, command=choose_image,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]).pack(fill="x", pady=(2, 5))
        ctk.CTkButton(buttons, text=self.t("حذف الصورة"), height=32, command=clear_image,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()).pack(fill="x")
        show_image(selected["path"])

        # --- قسم متغيرات المنتج (المقاس / اللون) ---
        variants_section = ctk.CTkFrame(body, fg_color="transparent")
        variants_section.pack(fill="x", pady=(10, 4))
        var_state = {"open": False, "pid": product[0] if is_edit else None}
        var_toggle_btn = ctk.CTkButton(
            variants_section, text=self.t("▸ متغيرات المنتج (المقاس / اللون)"), anchor="w",
            height=34, corner_radius=8, fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            command=lambda: toggle_variants()
        )
        var_toggle_btn.pack(fill="x")

        var_panel = ctk.CTkFrame(variants_section, fg_color="transparent")

        # متغيرات المنتج الجديد تُجمّع محليًا إلى حين الحفظ،
        # وتُحمّل من قاعدة البيانات عند تعديل منتج قائم.
        staged_variants = []
        staged_counter = {"n": 0}

        variants_list = ctk.CTkScrollableFrame(var_panel, fg_color=self.bg(), height=140, corner_radius=8)
        variants_list.pack(fill="x", pady=(0, 6))

        add_row1 = ctk.CTkFrame(var_panel, fg_color="transparent")
        add_row1.pack(fill="x", pady=3)
        ctk.CTkLabel(add_row1, text=self.t("اسم المتغير"), width=95, anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                     text_color=self.muted()).pack(side="left")
        v_name_entry = ctk.CTkEntry(add_row1, height=34, fg_color=self.card(),
                                    border_color=self.border(), text_color=self.text(),
                                    font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                    placeholder_text=self.t("مثال: مقاس 42 أسود / Taille L"))
        v_name_entry.pack(side="left", fill="x", expand=True)

        add_row2 = ctk.CTkFrame(var_panel, fg_color="transparent")
        add_row2.pack(fill="x", pady=3)
        ctk.CTkLabel(add_row2, text=self.t("الباركود"), width=95, anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                     text_color=self.muted()).pack(side="left")
        v_barcode_entry = ctk.CTkEntry(add_row2, height=34, fg_color=self.card(),
                                       border_color=self.border(), text_color=self.text(),
                                       font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                       placeholder_text=self.t("اختياري — يُترك فارغًا للتوليد التلقائي"))
        v_barcode_entry.pack(side="left", fill="x", expand=True)

        add_row3 = ctk.CTkFrame(var_panel, fg_color="transparent")
        add_row3.pack(fill="x", pady=3)
        ctk.CTkLabel(add_row3, text=self.t("الكمية"), width=95, anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                     text_color=self.muted()).pack(side="left")
        v_qty_entry = ctk.CTkEntry(add_row3, height=34, width=150, fg_color=self.card(),
                                   border_color=self.border(), text_color=self.text(),
                                   font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                   placeholder_text="0")
        v_qty_entry.pack(side="left", padx=(0, 14))
        ctk.CTkLabel(add_row3, text=self.t("السعر (اختياري)"), width=110, anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                     text_color=self.muted()).pack(side="left")
        v_price_entry = ctk.CTkEntry(add_row3, height=34, width=140, fg_color=self.card(),
                                     border_color=self.border(), text_color=self.text(),
                                     font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                     placeholder_text=self.t("سعر المنتج"))
        v_price_entry.pack(side="left", fill="x", expand=True)

        def _current_variant_rows():
            """صفوف (id, name, barcode, quantity, price) من المصدر الحالي."""
            if var_state["pid"] is not None:
                try:
                    return self.db.get_product_variants(var_state["pid"])
                except Exception:
                    return []
            return staged_variants

        def get_current_variants_total():
            """إجمالي كميات المتغيرات الحالية (المحفوظة أو المحضّرة)."""
            if var_state["pid"] is not None:
                try:
                    rows = self.db.get_product_variants(var_state["pid"])
                    return sum(float(r[3] or 0) for r in rows)
                except Exception:
                    return 0.0
            return sum(float(v[3] or 0) for v in staged_variants)

        def refresh_variants():
            for w in variants_list.winfo_children():
                w.destroy()
            rows = _current_variant_rows()
            if not rows:
                ctk.CTkLabel(variants_list, text=self.t("لا توجد متغيرات بعد."),
                             text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(anchor="w", pady=8)
            else:
                for v in rows:
                    vid, vname, vbarcode, vqty, vprice = v
                    vrow = ctk.CTkFrame(variants_list, fg_color=self.card(), corner_radius=6)
                    vrow.pack(fill="x", pady=1)
                    price_txt = f"{float(vprice):,.2f}" if vprice not in (None, "") else self.t("سعر المنتج")
                    ctk.CTkLabel(vrow, text=f"{vname}  •  {vbarcode or '—'}  •  {float(vqty or 0):g}  •  {price_txt}",
                                 text_color=self.text(), anchor="w",
                                 font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(side="left", fill="x", expand=True, padx=8, pady=4)
                    ctk.CTkButton(vrow, text="✕", width=26, height=24, corner_radius=6,
                                  fg_color=self.colors.get("danger", "#b91c1c"),
                                  hover_color=self.colors.get("danger_hover", "#991b1b"),
                                  text_color="white", font=ctk.CTkFont(size=10),
                                  command=lambda vid=vid: delete_variant(vid)).pack(side="left", padx=4)

        def add_variant():
            vname = v_name_entry.get().strip()
            if not vname:
                self.toast("اسم المتغير مطلوب", "danger")
                return
            try:
                vqty = float(v_qty_entry.get().replace(",", ".") or 0)
            except Exception:
                vqty = 0.0
            # سقف الكمية: يُحدد إجمالي المنتج أولاً ثم تُوزَّع المتغيرات ضمنه.
            try:
                parent_ceiling = float(entries["الكمية"].get().replace(",", ".").strip() or 0)
            except Exception:
                parent_ceiling = 0.0
            if parent_ceiling <= 0:
                self.toast("يرجى تحديد كمية المنتج الكلية أولاً قبل إضافة المتغيرات", "warning")
                return
            used_stock = get_current_variants_total()
            available_quota = max(0.0, parent_ceiling - used_stock)
            if vqty <= 0:
                self.toast("كمية المتغير يجب أن تكون أكبر من صفر", "danger")
                return
            if used_stock + vqty > parent_ceiling:
                self.toast(
                    f"لا يمكن إضافة المتغير: الإجمالي ({used_stock + vqty:g}) يتجاوز كمية المنتج الكلية ({parent_ceiling:g}). المتاح المتبقي: {available_quota:g}",
                    "danger"
                )
                return
            vprice_raw = v_price_entry.get().strip()
            vprice = None
            if vprice_raw:
                try:
                    vprice = float(vprice_raw.replace(",", "."))
                except Exception:
                    self.toast("السعر يجب أن يكون رقمًا أو يُترك فارغًا", "danger")
                    return
            vbarcode = v_barcode_entry.get().strip()
            if var_state["pid"] is not None:
                if not vbarcode:
                    vbarcode = f"VAR-{var_state['pid']}-{datetime.now().strftime('%Y%m%d%H%M%S%f')}"
                ok, result = self.db.add_product_variant(var_state["pid"], vname, vbarcode, vqty, vprice)
                if not ok:
                    self.toast(f"فشل إضافة المتغير: {result}", "danger")
                    return
                self.toast("✓ تمت إضافة المتغير")
            else:
                staged_counter["n"] += 1
                staged_variants.append((staged_counter["n"], vname, vbarcode, vqty, vprice))
                self.toast("✓ تمت إضافة المتغير (سيُحفظ مع المنتج)")
            v_name_entry.delete(0, "end")
            v_barcode_entry.delete(0, "end")
            v_qty_entry.delete(0, "end")
            v_price_entry.delete(0, "end")
            refresh_variants()

        def delete_variant(vid):
            if var_state["pid"] is not None:
                if not messagebox.askyesno(self.t("حذف متغير"), self.t("حذف هذا المتغير نهائيًا؟"), parent=win):
                    return
                if not self.db.delete_product_variant(vid):
                    self.toast("فشل حذف المتغير", "danger")
                    return
                self.toast("✓ تم حذف المتغير")
            else:
                for i, v in enumerate(staged_variants):
                    if v[0] == vid:
                        staged_variants.pop(i)
                        break
                self.toast("✓ تم حذف المتغير")
            refresh_variants()

        ctk.CTkButton(var_panel, text=self.t("+ إضافة متغير"), height=34, corner_radius=8,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                      command=add_variant).pack(fill="x", pady=(2, 6))

        def toggle_variants():
            var_state["open"] = not var_state["open"]
            var_toggle_btn.configure(text=("▾ " if var_state["open"] else "▸ ") + self.t("متغيرات المنتج (المقاس / اللون)"))
            if var_state["open"]:
                var_panel.pack(fill="x", pady=(6, 0))
                refresh_variants()
            else:
                var_panel.pack_forget()

        ctk.CTkLabel(body,
                     text=self.t("للوزن: اختر كغ أو غرام. مثال: 0.075 كغ = 75 غرام. السعر يكون حسب الوحدة المختارة."),
                     text_color=self.muted(), anchor="w", justify="left", wraplength=540,
                     font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack(fill="x", pady=(5, 8))

        bottom = ctk.CTkFrame(container, fg_color="transparent")
        bottom.pack(fill="x", pady=(10, 0))

        def save():
            try:
                name = entries["الاسم"].get().strip()
                price = float(entries["السعر"].get())
                cost = float(entries["سعر الشراء"].get() or 0)
                quantity = float(entries["الكمية"].get())
                barcode = entries["الباركود"].get().strip()
                unit = self._to_ar(unit_box.get().strip()) or "قطعة"
                if not name:
                    self.toast("اسم المنتج مطلوب", "danger")
                    return
                if price < 0 or cost < 0 or quantity < 0:
                    self.toast("لا يمكن إدخال قيم سالبة", "danger")
                    return
                if unit == "قطعة" and not quantity.is_integer():
                    self.toast("منتج القطعة يجب أن تكون كميته عددًا صحيحًا", "danger")
                    return
                # سقف الكمية: لا يُحفظ منتج تكون متغيراته متجاوزة الكمية الكلية المحددة.
                saved_variants_sum = get_current_variants_total()
                if saved_variants_sum > quantity:
                    self.toast(
                        f"لا يمكن الحفظ: مجموع كميات المتغيرات ({saved_variants_sum:g}) يتجاوز "
                        f"كمية المنتج الكلية ({quantity:g}).",
                        "danger"
                    )
                    return
                selected_cat_name = self._to_ar(category_box.get().strip())
                selected_cat_id = next((c[0] for c in categories if str(c[1]) == selected_cat_name), None)
                audit_details = f"{name} • {price:,.2f} دج • الكمية {quantity:g}"
                if is_edit:
                    self.product_manager.update_product(product[0], barcode, name, price, cost, quantity, unit, None)
                    self._save_product_image_path(product[0], selected["path"])
                    self._save_product_category(product[0], selected_cat_id)
                    self.log_action("product_update", "product", product[0], audit_details)
                    win.destroy()
                    self.render_products(self.search_entry.get().strip() if hasattr(self, "search_entry") else "")
                    self.toast("✓ تم تحديث المنتج")
                else:
                    success, msg = self.product_manager.add_product(barcode, name, price, cost, quantity, unit, None, selected["path"])
                    if success:
                        new_pid = self._lookup_product_id(barcode, name)
                        self._save_product_category(new_pid, selected_cat_id)
                        # حفظ المتغيرات الموسّعة (المنتج الجديد) — الكمية الكلية تبقى كما أدخلها المستخدم.
                        if staged_variants:
                            for v in staged_variants:
                                vname, vbarcode, vqty, vprice = v[1], v[2], v[3], v[4]
                                if not vbarcode:
                                    vbarcode = f"VAR-{new_pid}-{datetime.now().strftime('%Y%m%d%H%M%S%f')}"
                                self.db.add_product_variant(new_pid, vname, vbarcode, vqty, vprice)
                        self.log_action("product_create", "product", new_pid, audit_details)
                        win.destroy()
                        self.show_products()
                        self.toast("✓ تمت إضافة المنتج")
                    else:
                        self.toast(str(msg), "danger")
            except ValueError:
                self.toast("تأكد من إدخال الأرقام بشكل صحيح، مثل 0.075", "danger")
            except Exception as exc:
                self.toast(f"فشل الحفظ: {exc}", "danger")

        ctk.CTkButton(bottom, text=self.t("حفظ"), command=save, height=42,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]).pack(side="right", fill="x", expand=True, padx=4)
        ctk.CTkButton(bottom, text=self.t("إلغاء"), command=win.destroy, height=42,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()).pack(side="right", fill="x", expand=True, padx=4)

    def edit_product(self, product_id):
        try:
            product = self.product_manager.get_product_by_id(product_id)
        except Exception as exc:
            self.toast(str(exc), "danger")
            return
        if not product:
            self.toast("المنتج غير موجود", "danger")
            return
        self._open_product_form(self.t("تعديل المنتج"), product)

    def show_add_product_form(self):
        self._open_product_form(self.t("إضافة منتج جديد"))

    def form_window(self, title, width, height, fields):
        title = self.t(title)
        win = ctk.CTkToplevel(self)
        win.title(title)
        win.geometry(f"{width}x{height}")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()

        self.center_window(win, width, height)

        container = ctk.CTkFrame(
            win,
            fg_color=self.bg(),
            corner_radius=0
        )
        container.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(
            container,
            text=title,
            font=ctk.CTkFont(family=self.ui_font_family,size=21, weight="bold"),
            text_color=self.text()
        ).pack(anchor="w", pady=(5, 18))

        entries = {}

        for field in fields:
            label, value = field[0], field[1]
            placeholder = field[2] if len(field) > 2 else ""
            disp_label = self.t(label)
            ctk.CTkLabel(
                container,
                text=disp_label,
                anchor=self.align(),
                font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                text_color=self.muted()
            ).pack(fill="x", pady=(8, 3))

            entry = ctk.CTkEntry(
                container,
                height=38,
                corner_radius=9,
                fg_color=self.card(),
                border_color=self.border(),
                text_color=self.text(),
                placeholder_text=placeholder,
                font=ctk.CTkFont(family=self.ui_font_family, size=12)
            )
            entry.pack(fill="x", pady=(0, 4))

            if value:
                entry.insert(0, value)

            entries[label] = entry

        return win, entries

    def form_buttons(self, win, save_command):
        bottom = ctk.CTkFrame(win, fg_color="transparent")
        bottom.pack(fill="x", padx=30, pady=(0, 20))

        ctk.CTkButton(
            bottom,
            text=self.t("حفظ"),
            command=save_command,
            height=40,
            corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
        ).pack(side="right", fill="x", expand=True, padx=4)

        ctk.CTkButton(
            bottom,
            text=self.t("إلغاء"),
            command=win.destroy,
            height=40,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=12)
        ).pack(side="right", fill="x", expand=True, padx=4)

    def center_window(self, win, width, height):
        win.update_idletasks()
        x = (win.winfo_screenwidth() - width) // 2
        y = (win.winfo_screenheight() - height) // 2
        win.geometry(f"{width}x{height}+{x}+{y}")
        try:
            win.bind("<Escape>", lambda e: win.destroy())
        except Exception:
            pass

    def delete_product(self, product_id):
        if not self.require_pin("حذف منتج", "admin"):
            return

        if not self.confirm(
            "تأكيد الحذف",
            "هل أنت متأكد من حذف هذا المنتج؟\nلا يمكن التراجع عن العملية."
        ):
            return

        try:
            success, message = self.product_manager.delete_product(product_id)

            if success:
                self.log_action("product_delete", "product", product_id)
                self.render_products(
                    self.search_entry.get().strip()
                    if hasattr(self, "search_entry") else ""
                )
                self.toast("✓ تم حذف المنتج")
            else:
                self.toast(str(message), "danger")

        except Exception as exc:
            self.toast(f"فشل الحذف: {exc}", "danger")

    # =========================================================
    # POS V4 — modern cashier workspace
    # =========================================================


    def clear_pos_product_search(self):
        """Clear POS search and immediately restore the complete catalogue."""
        try:
            # Cancel any delayed search callback first. This was the reason
            # the old searched product could reappear after clearing.
            if getattr(self, "search_after_id", None):
                try:
                    self.after_cancel(self.search_after_id)
                except Exception:
                    pass
                self.search_after_id = None

            if hasattr(self, "pos_search"):
                self.pos_search.delete(0, "end")

            # Always render with an EMPTY query, using the POS renderer.
            # Do not call the products-page renderer here.
            self.render_pos_products("")

            if hasattr(self, "pos_search"):
                self.pos_search.focus_set()

        except Exception as exc:
            self.toast(f"تعذر تحديث قائمة المنتجات: {exc}", "danger")


    def show_pos(self, preserve_cart=False):
        if not self._guard_db_nav("نقطة البيع", "بيع سريع • مخزون مباشر", "pos"):
            return
        old_cart = [dict(x) for x in self.cart] if preserve_cart else []
        old_customer = self.selected_customer if preserve_cart else None
        old_discount = getattr(self, "sale_discount", 0.0) if preserve_cart else 0.0

        self.clear_content()
        self.current_page = "pos"
        self.highlight_nav()
        self.sale_discount = old_discount

        if preserve_cart:
            self.cart = old_cart
            self.selected_customer = old_customer
        else:
            self.cart = []
            self.total = 0.0
            self.selected_customer = None
            # فتح نقطة البيع من جديد: إعادة ضبط الفرز والترحيل إلى الافتراضي.
            self.pos_list_page = 1
            self.pos_sort_col = None
            self.pos_sort_dir = 1

        # Header مخصوص بالـ POS — أقل ارتفاعاً وأكثر تركيزاً على البيع.
        header = ctk.CTkFrame(self.content_area, fg_color="transparent", height=54)
        header.pack(fill="x", pady=(0, 10))
        header.pack_propagate(False)

        title_box = ctk.CTkFrame(header, fg_color="transparent")
        title_box.pack(side="left", fill="y")
        ctk.CTkLabel(
            title_box, text=self.t("نقطة البيع"), text_color=self.text(),
            font=ctk.CTkFont(family="Segoe UI", size=25, weight="bold")
        ).pack(anchor="w")
        ctk.CTkLabel(
            title_box, text=self.t("بيع سريع • مخزون مباشر • سلة واحدة"),
            text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family,size=10)
        ).pack(anchor="w", pady=(0, 2))

        actions = ctk.CTkFrame(header, fg_color="transparent")
        actions.pack(side="right", fill="y")
        ctk.CTkButton(
            actions, text=self.t("🧾 سجل الوصولات"), command=self.show_invoices_history_dialog,
            width=125, height=36, corner_radius=10,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            border_width=1, border_color=self.border(), font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="right", padx=(6, 0), pady=7)
        ctk.CTkButton(
            actions, text=self.t("||  المعلّق"), command=self.restore_held_sale,
            width=100, height=36, corner_radius=10,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            border_width=1, border_color=self.border(), font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="right", padx=(6, 0), pady=7)
        ctk.CTkButton(
            actions, text=self.t("＋ بيع جديد"), command=lambda: self.show_pos(False),
            width=105, height=36, corner_radius=10,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="right", padx=(6, 0), pady=7)
        ctk.CTkButton(
            actions, text=self.t("↩ إرجاع منتج"), command=self.show_independent_return_dialog,
            width=230, height=52, corner_radius=12,
            fg_color=self.colors.get("danger", "#b91c1c"),
            hover_color=self.colors.get("danger_hover", "#991b1b"),
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold")
        ).pack(side="right", padx=(6, 0), pady=2)

        workspace = ctk.CTkFrame(self.content_area, fg_color="transparent")
        workspace.pack(fill="both", expand=True)

        # =========================
        # Product browser
        # =========================
        browser = self.make_card(workspace, corner_radius=16)
        browser.pack(side="left", fill="both", expand=True, padx=(0, 7))

        search_row = ctk.CTkFrame(browser, fg_color="transparent", height=52)
        search_row.pack(fill="x", padx=14, pady=(14, 8))
        search_row.pack_propagate(False)

        search_wrap = ctk.CTkFrame(
            search_row, fg_color=self.bg(), corner_radius=11,
            border_width=1, border_color=self.border()
        )
        search_wrap.pack(side="left", fill="both", expand=True)
        ctk.CTkLabel(
            search_wrap, text="⌕", text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family,size=20, weight="bold")
        ).pack(side="left", padx=(12, 4))
        self.pos_search = ctk.CTkEntry(
            search_wrap,
            placeholder_text=self.t("ابحث باسم المنتج، Barcode أو SKU…"),
            height=48, fg_color="transparent", border_width=0,
            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family,size=12)
        )
        self.pos_search.pack(side="left", fill="both", expand=True, padx=(0, 8))
        self.pos_search.bind("<Return>", self.add_to_cart)
        self.pos_search.bind("<KeyRelease>", self.pos_search_preview)

        ctk.CTkButton(
            search_row, text=self.t("Enter  ↵"), command=self.add_to_cart,
            width=82, height=44, corner_radius=10,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="right", padx=(8, 0), pady=4)

        # Status filters — لا ندعي وجود Categories غير موجودة في قاعدة البيانات.
        filter_row = ctk.CTkFrame(browser, fg_color="transparent", height=36)
        filter_row.pack(fill="x", padx=14, pady=(0, 8))
        filter_row.pack_propagate(False)
        self.pos_filter_buttons = []
        filters = [
            ("all", self.t("الكل")),
            ("available", self.t("متوفر")),
            ("low", self.t("مخزون منخفض")),
            ("out", self.t("نفد"))
        ]
        for key, label in filters:
            b = ctk.CTkButton(
                filter_row, text=label, command=lambda k=key: self.set_pos_filter(k),
                height=30, width=105 if key == "low" else 78, corner_radius=8,
                fg_color=self.colors["primary"] if self.pos_filter == key else self.bg(),
                hover_color=self.colors["primary_hover"] if self.pos_filter == key else self.border(),
                text_color="white" if self.pos_filter == key else self.muted(),
                border_width=1 if self.pos_filter != key else 0,
                border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family,size=9, weight="bold")
            )
            b.pack(side="left", padx=(0, 5))
            self.pos_filter_buttons.append((key, b))

        # فلتر التصنيفات في نقطة البيع — يُدمج مع الحالة والبحث (AND).
        _pos_cats, _pos_cat_values = self._category_filter_options()
        self.pos_category_combo = ctk.CTkComboBox(
            filter_row,
            values=_pos_cat_values,
            width=145,
            height=30,
            corner_radius=8,
            fg_color=self.card(),
            border_color=self.border(),
            button_color=self.colors["primary"],
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9),
            command=lambda _v: self.render_pos_products(
                self.pos_search.get().strip() if hasattr(self, "pos_search") else ""
            )
        )
        self.pos_category_combo.set(self.t("كل التصنيفات"))
        self.pos_category_combo.pack(side="left", padx=(5, 0))

        self.pos_result_label = ctk.CTkLabel(
            filter_row, text="", text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9)
        )
        self.pos_result_label.pack(side="right", padx=5)

        # ============================
        # قسم المفضّلة — ثابت دائمًا أعلى قائمة البيع، لا يختفي عند البحث.
        # ============================
        self.pos_fav_container = ctk.CTkFrame(browser, fg_color="transparent")
        self.pos_fav_container.pack(fill="x", padx=9, pady=(0, 4))
        fav_head = ctk.CTkFrame(self.pos_fav_container, fg_color="transparent")
        fav_head.pack(fill="x", padx=2, pady=(0, 2))
        ctk.CTkLabel(
            fav_head, text=self.t("المفضّلة"), text_color=self.colors["primary"],
            anchor="w", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side="left")
        self.pos_fav_row = ctk.CTkScrollableFrame(
            self.pos_fav_container, fg_color="transparent",
            orientation="horizontal", height=150
        )
        self.pos_fav_row.pack(fill="x")

        self.pos_product_list = ctk.CTkScrollableFrame(
            browser, fg_color="transparent", corner_radius=0
        )
        self.pos_product_list.pack(fill="both", expand=True, padx=9, pady=(0, 10))
        self._render_pos_favorites()
        self.render_pos_products()

        # =========================
        # Cart / checkout
        # =========================
        cart_panel = self.make_card(workspace, width=390, corner_radius=16)
        cart_panel.pack(side="right", fill="both", padx=(7, 0))
        cart_panel.pack_propagate(False)

        cart_head = ctk.CTkFrame(cart_panel, fg_color="transparent", height=50)
        cart_head.pack(fill="x", padx=14, pady=(12, 2))
        cart_head.pack_propagate(False)
        ctk.CTkLabel(
            cart_head, text=self.t("السلة"), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=18, weight="bold")
        ).pack(side="left")
        self.cart_count = ctk.CTkLabel(
            cart_head, text=self.t("0 عنصر"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9, weight="bold")
        )
        self.cart_count.pack(side="right", pady=5)

        customer = ctk.CTkFrame(
            cart_panel, fg_color=self.bg(), corner_radius=10,
            border_width=1, border_color=self.border()
        )
        customer.pack(fill="x", padx=14, pady=(0, 8))
        ctk.CTkLabel(
            customer, text=self.t("العميل"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold")
        ).pack(side="left", padx=(10, 4), pady=9)
        self.customer_label = ctk.CTkLabel(
            customer,
            text=self.selected_customer[1] if self.selected_customer else self.t("زبون نقدي"),
            text_color=self.text(), anchor="w",
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        )
        self.customer_label.pack(side="left", fill="x", expand=True, pady=9)
        ctk.CTkButton(
            customer, text=self.t("تغيير"), command=self.select_customer,
            width=55, height=27, corner_radius=7,
            fg_color=self.card(), hover_color=self.border(), text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold")
        ).pack(side="right", padx=6)

        self.cart_container = ctk.CTkScrollableFrame(
            cart_panel, fg_color="transparent", corner_radius=0
        )
        self.cart_container.pack(fill="both", expand=True, padx=10, pady=(0, 5))
        self._cart_cards = []
        self._cart_sigs = []

        # Summary — نعرض الخصم بشكل واضح، ويمكن استعماله لاحقاً مع الـ SalesManager.
        summary = ctk.CTkFrame(
            cart_panel, fg_color=self.bg(), corner_radius=12,
            border_width=1, border_color=self.border()
        )
        summary.pack(fill="x", padx=14, pady=(5, 8))

        self.subtotal_label = self._summary_row(summary, "المجموع الفرعي", "0.00 د.ج")
        discount_row = ctk.CTkFrame(summary, fg_color="transparent")
        discount_row.pack(fill="x", padx=12, pady=(6, 0))

        ctk.CTkLabel(
            discount_row, text=self.t("الخصم"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9)
        ).pack(side="left")

        self.discount_label = ctk.CTkLabel(
            discount_row, text=self.t("0.00 د.ج"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        )
        self.discount_label.pack(side="left", padx=8)

        ctk.CTkButton(
            discount_row, text=self.t("تعديل"),
            width=54, height=25, corner_radius=7,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.colors["primary"],
            border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold"),
            command=self.edit_sale_discount
        ).pack(side="right")

        self.pos_total_label = self._summary_row(
            summary, "الإجمالي", "0.00 د.ج", big=True, accent=True
        )

        actions = ctk.CTkFrame(cart_panel, fg_color="transparent")
        actions.pack(fill="x", padx=14, pady=(0, 12))
        ctk.CTkButton(
            actions, text=self.t("الدفع  [F8]"), command=self.complete_sale,
            height=48, corner_radius=11,
            fg_color=self.colors["secondary"], hover_color=self.colors["secondary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=12, weight="bold")
        ).pack(fill="x", pady=(0, 6))

        bottom = ctk.CTkFrame(actions, fg_color="transparent")
        bottom.pack(fill="x")
        ctk.CTkButton(
            bottom, text=self.t("|| تعليق"), command=self.hold_current_sale,
            height=34, corner_radius=9, width=92,
            fg_color=self.colors["accent"], hover_color="#D97706",
            font=ctk.CTkFont(family=self.ui_font_family,size=9, weight="bold")
        ).pack(side="left", padx=(0, 4))
        ctk.CTkButton(
            bottom, text=self.t("مسح السلة"), command=self.clear_cart,
            height=34, corner_radius=9, width=92,
            fg_color="transparent", hover_color=self.colors["danger"],
            text_color=self.colors["danger"], border_width=1,
            border_color=self.border(), font=ctk.CTkFont(family=self.ui_font_family,size=9, weight="bold")
        ).pack(side="right", padx=(4, 0))

        self.update_cart_display()
        self.after(100, lambda: self._focus_if_alive(self.pos_search))

    def _summary_row(self, parent, label, value, big=False, accent=False):
        label = self.t(label)
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=12, pady=(8 if not big else 10, 4 if not big else 10))
        ctk.CTkLabel(
            row, text=label, text_color=self.muted() if not big else self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=9 if not big else 11, weight="bold" if big else "normal")
        ).pack(side="left")
        label_widget = ctk.CTkLabel(
            row, text=value,
            text_color=self.colors["secondary"] if accent else self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=20 if big else 10, weight="bold")
        )
        label_widget.pack(side="right")
        return label_widget

    def edit_sale_discount(self):
        """تعديل خصم الفاتورة — مبلغ ثابت (دج) أو نسبة مئوية (%) — مع معاينة حية."""
        subtotal = sum(float(item["total"]) for item in self.cart)
        if subtotal <= 0:
            self.toast("أضف منتجات إلى السلة أولاً", "warning")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("خصم الفاتورة"))
        win.geometry("420x320")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 420, 320)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        ctk.CTkLabel(
            container, text=self.t("خصم الفاتورة"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=20, weight="bold")
        ).pack(anchor="w", pady=(4, 3))

        ctk.CTkLabel(
            container, text=self.t(f"المجموع قبل الخصم: {subtotal:,.2f} د.ج"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=10)
        ).pack(anchor="w", pady=(0, 10))

        toggle = ctk.CTkSegmentedButton(
            container, values=[self.t("مبلغ ثابت (دج)"), self.t("نسبة مئوية (%)")],
            command=lambda _v: update_preview(),
            height=34, corner_radius=8,
            fg_color=self.card(), selected_color=self.colors["primary"],
            selected_hover_color=self.colors["primary_hover"],
            unselected_color=self.card(), unselected_hover_color=self.border(),
            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        )
        toggle.pack(fill="x", pady=(0, 10))
        toggle.set(self.t("مبلغ ثابت (دج)"))

        def current_mode():
            return "percent" if toggle.get() == self.t("نسبة مئوية (%)") else "fixed"

        entry = ctk.CTkEntry(
            container, height=40, corner_radius=9,
            fg_color=self.card(), border_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=13)
        )
        entry.pack(fill="x", pady=(0, 6))
        entry.insert(0, str(float(getattr(self, "sale_discount", 0.0) or 0.0)))

        preview = ctk.CTkLabel(
            container, text="", text_color=self.colors["secondary"],
            font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold"),
            anchor="e"
        )
        preview.pack(fill="x", pady=(0, 12))

        def update_preview():
            mode = current_mode()
            try:
                raw = float(entry.get() or 0)
            except ValueError:
                preview.configure(text="")
                return
            if not raw or raw < 0:
                preview.configure(text="")
                return
            if mode == "percent":
                val = subtotal * (raw / 100.0)
                preview.configure(
                    text=f"{self.t('قيمة الخصم:')} {val:,.2f} {self.t('د.ج')} ({raw:g}%)"
                )
            else:
                pct = (raw / subtotal * 100.0) if subtotal > 0 else 0.0
                preview.configure(
                    text=f"{self.t('قيمة الخصم:')} {raw:,.2f} {self.t('د.ج')} ({pct:.1f}%)"
                )

        def save():
            try:
                value = float(entry.get() or 0)
            except ValueError:
                self.toast("أدخل قيمة خصم صحيحة", "danger")
                return
            if value < 0:
                self.toast("الخصم لا يمكن أن يكون سالبًا", "danger")
                return
            mode = current_mode()
            if mode == "percent":
                if value > 100:
                    self.toast(self.t("النسبة المئوية يجب أن تكون بين 0 و 100"), "danger")
                    return
                final_amount = subtotal * (value / 100.0)
            else:
                if value > subtotal:
                    self.toast("الخصم لا يمكن أن يتجاوز قيمة السلة", "danger")
                    return
                final_amount = value

            # حماية برمز PIN عند تجاوز الخصم الحد المسموح من الإعدادات.
            threshold = float(self.settings.get("pin_discount_threshold", 500) or 0)
            if final_amount > threshold:
                if not self.require_pin("خصم فاتورة كبير", "any"):
                    return

            self.sale_discount = final_amount
            self.log_action("invoice_discount", "sale", None, f"{final_amount:,.2f} دج")
            win.destroy()
            self.update_cart_display()
            self.toast("تم تحديث خصم الفاتورة")

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", pady=(6, 0))

        ctk.CTkButton(
            buttons, text=self.t("حفظ"), command=save,
            height=38, corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            buttons, text=self.t("إلغاء"), command=win.destroy,
            height=38, corner_radius=9,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=10)
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        entry.focus_set()
        entry.bind("<KeyRelease>", lambda _e: update_preview())
        entry.bind("<Return>", lambda _e: save())
        update_preview()

    def set_pos_filter(self, key):
        self.pos_filter = key
        if hasattr(self, "pos_filter_buttons"):
            for k, b in self.pos_filter_buttons:
                active = k == key
                b.configure(
                    fg_color=self.colors["primary"] if active else self.bg(),
                    hover_color=self.colors["primary_hover"] if active else self.border(),
                    text_color="white" if active else self.muted(),
                    border_width=0 if active else 1
                )
        self.render_pos_products(self.pos_search.get().strip() if hasattr(self, "pos_search") else "")

    def hold_current_sale(self):
        if not self.cart:
            self.toast("السلة فارغة", "warning")
            return
        self.held_sales.append({
            "cart": [dict(x) for x in self.cart],
            "customer": self.selected_customer,
            "discount": getattr(self, "sale_discount", 0.0),
            "time": datetime.now().strftime("%H:%M")
        })
        self.cart = []
        self.total = 0.0
        self.selected_customer = None
        self.sale_discount = 0.0
        self.update_cart_display()
        if hasattr(self, "customer_label"):
            self.customer_label.configure(text=self.t("زبون نقدي"))
        self.toast(f"تم تعليق البيع • {len(self.held_sales)} عملية معلقة", "info")

    def restore_held_sale(self):
        """فتح نافذة السلات المعلقة التفاعلية لاسترجاع أو حذف سلة محددة."""
        if not self.held_sales:
            self.toast(self.t("لا توجد مبيعات معلقة"), "warning")
            return
        self._show_held_sales_dialog()

    def _show_held_sales_dialog(self):
        """نافذة تفاعلية لعرض جميع السلات المعلقة مع إجراءات الاسترجاع/الحذف."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("السلات المعلقة"))
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 600, 480)

        header = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=12)
        header.pack(fill="x", padx=14, pady=(14, 6))
        ctk.CTkLabel(
            header, text="🧺 " + self.t("السلات المعلقة"),
            font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"),
            text_color=self.text()
        ).pack(anchor="e", padx=16, pady=(10, 2))
        ctk.CTkLabel(
            header,
            text=self.t("اختر سلة لاسترجاعها أو حذفها"),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(anchor="e", padx=16, pady=(0, 10))

        scroll = ctk.CTkScrollableFrame(win, fg_color="transparent")
        scroll.pack(fill="both", expand=True, padx=10, pady=(0, 10))

        def _restore_at(index):
            sale = self.held_sales[index]
            if self.cart and not messagebox.askyesno(
                self.t("استرجاع السلة"),
                self.t("هل تريد استبدال السلة الحالية بالسلة المعلقة؟"),
                parent=win
            ):
                return
            self.cart = sale.get("cart") or []
            self.selected_customer = sale.get("customer")
            self.sale_discount = float(sale.get("discount", 0.0) or 0.0)
            try:
                self.held_sales.pop(index)
            except Exception:
                pass
            try:
                win.destroy()
            except Exception:
                pass
            if self.current_page != "pos":
                self.show_pos(preserve_cart=True)
            else:
                self.update_cart_display()
                if hasattr(self, "customer_label"):
                    self.customer_label.configure(
                        text=self.selected_customer[1] if self.selected_customer else self.t("زبون نقدي")
                    )
            self.toast(self.t("تم استرجاع السلة"), "success")

        def _delete_at(index):
            if not messagebox.askyesno(
                self.t("حذف السلة المعلقة"),
                self.t("هل تريد حذف هذه السلة المعلقة؟"),
                parent=win
            ):
                return
            try:
                self.held_sales.pop(index)
            except Exception:
                pass
            self.toast(self.t("تم حذف السلة المعلقة"), "info")
            _rebuild()

        def _rebuild():
            for w in scroll.winfo_children():
                w.destroy()
            if not self.held_sales:
                empty = ctk.CTkFrame(scroll, fg_color="transparent")
                empty.pack(pady=40)
                ctk.CTkLabel(empty, text="✓", font=ctk.CTkFont(size=40), text_color=self.colors["secondary"]).pack()
                ctk.CTkLabel(
                    empty, text=self.t("لا توجد مبيعات معلقة"),
                    font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
                    text_color=self.text()
                ).pack(pady=(4, 0))
                ctk.CTkButton(
                    empty, text=self.t("موافق"), command=win.destroy,
                    height=32, width=90, corner_radius=8,
                    fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                    text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10)
                ).pack(pady=(12, 0))
                return

            for index, cart_data in enumerate(self.held_sales):
                card = ctk.CTkFrame(scroll, fg_color=self.card(), corner_radius=12, border_width=1, border_color=self.border())
                card.pack(fill="x", pady=4)

                top = ctk.CTkFrame(card, fg_color="transparent")
                top.pack(fill="x", padx=12, pady=(10, 2))
                ctk.CTkLabel(
                    top, text=f"#{index + 1}",
                    font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
                    text_color=self.colors["primary"]
                ).pack(side="right")

                t = cart_data.get("time")
                if t:
                    ctk.CTkLabel(
                        top, text=f"🕒 {t}",
                        font=ctk.CTkFont(family=self.ui_font_family, size=10),
                        text_color=self.muted()
                    ).pack(side="left", padx=(8, 0))

                cust = cart_data.get("customer")
                cust_name = cust[1] if cust else self.t("زبون نقدي")
                items_list = cart_data.get("cart") or []
                total_amt = sum(float(x.get("total", 0) or 0) for x in items_list)

                body = ctk.CTkFrame(card, fg_color="transparent")
                body.pack(fill="x", padx=12, pady=2)
                ctk.CTkLabel(
                    body, text=f"👤 {cust_name}",
                    font=ctk.CTkFont(family=self.ui_font_family, size=10),
                    text_color=self.text()
                ).pack(anchor="e")
                ctk.CTkLabel(
                    body, text=f"{len(items_list)} {self.t('عنصر')}",
                    font=ctk.CTkFont(family=self.ui_font_family, size=10),
                    text_color=self.muted()
                ).pack(anchor="e", pady=(1, 0))
                ctk.CTkLabel(
                    body, text=f"{total_amt:,.2f} {self.t('د.ج')}",
                    font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
                    text_color=self.colors["secondary"]
                ).pack(anchor="e", pady=(2, 0))

                actions = ctk.CTkFrame(card, fg_color="transparent")
                actions.pack(fill="x", padx=12, pady=(4, 10))
                ctk.CTkButton(
                    actions, text="↩ " + self.t("استرجاع"), command=lambda i=index: _restore_at(i),
                    height=32, width=110, corner_radius=8,
                    fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                    text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
                ).pack(side="left", padx=(0, 6))
                ctk.CTkButton(
                    actions, text="🗑 " + self.t("حذف"), command=lambda i=index: _delete_at(i),
                    height=32, width=95, corner_radius=8,
                    fg_color="transparent", hover_color=self.colors["danger"], text_color=self.colors["danger"],
                    border_width=1, border_color=self.colors["danger"],
                    font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
                ).pack(side="left")

        _rebuild()

    def pos_search_preview(self, event=None):
        """بحث فوري في نقطة البيع مع حماية من تكرار المؤقتات."""
        if getattr(self, "search_after_id", None):
            try:
                self.after_cancel(self.search_after_id)
            except Exception:
                pass

        term = self.pos_search.get().strip()

        # Enter adds the best matching product immediately.
        if event is not None and getattr(event, "keysym", "") in ("Return", "KP_Enter"):
            self.add_to_cart()
            return "break"

        self.search_after_id = self.after(
            250,
            lambda q=term: self.render_pos_products(q)
        )

    def _pos_sort_key(self, col):
        """مفتاح الفرز للقائمة الحالية (المنتجات فقط) — لا استعلام إضافي."""
        if col == "price":
            return lambda p: float(p[3] or 0)
        if col == "stock":
            return lambda p: float(p[4] or 0)
        return lambda p: str(p[2])

    def _pos_toggle_sort(self, col):
        """النقر على رأس عمود: أول نقرة تصاعدي، نفس العمود مرة أخرى تنازلي،
        عمود مختلف يُصف عليه تصاعديًا ويُصفّح إلى الصفحة الأولى."""
        if self.pos_sort_col == col:
            self.pos_sort_dir *= -1
        else:
            self.pos_sort_col = col
            self.pos_sort_dir = 1
        self.pos_list_page = 1
        term = self.pos_search.get().strip() if hasattr(self, "pos_search") else ""
        try:
            self.pos_product_list._parent_canvas.yview_moveto(0)
        except Exception:
            pass
        self.render_pos_products(term)

    def _pos_col_button(self, container, label, col):
        """زر رأس عمود قابل للنقر — يُظهر مؤشر ▲/▼ على العمود النشط."""
        label = self.t(label)
        if self.pos_sort_col == col:
            arrow = " ▲" if self.pos_sort_dir == 1 else " ▼"
            fg = self.colors["primary"]
            text_color = "white"
            bold = True
        else:
            arrow = " ⇅"
            fg = "transparent"
            text_color = self.muted()
            bold = False
        return ctk.CTkButton(
            container, text=label + arrow, corner_radius=7, width=104,
            fg_color=fg, hover_color=self.colors["primary_hover"],
            text_color=text_color,
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold" if bold else "normal"),
            height=26, command=lambda c=col: self._pos_toggle_sort(c)
        )

    def _pos_grid_cols(self):
        """الأعمدة المشتركة بين رأس القائمة وصفوفها في نقطة البيع.
        الرأس والصفوف يستخدمان نفس الشبكة حتى لا ينزاح المخزون/السعر
        عن عموديهما الصحيحين."""
        return {"star": 0, "name": 1, "stock": 2, "price": 3, "add": 4}

    def _pos_take_row(self):
        """يعيد رقم الصف التالي في الشبكة الموحّدة ثم يزيد العداد."""
        r = getattr(self, "_pos_body_row", 0)
        self._pos_body_row = r + 1
        return r

    def _pos_apply_grid(self, frame):
        """أعمدة الشبكة الموحّدة: أعمدة ثابتة (نجمة/مخزون/سعر/إضافة)
        وعمود الاسم وحده يتمدد بالوزن المرن."""
        cols = self._pos_grid_cols()
        for ci in range(5):
            frame.grid_columnconfigure(ci, weight=0, minsize=0)
        frame.grid_columnconfigure(cols["name"], weight=1)
        frame.grid_columnconfigure(cols["star"], minsize=44)
        frame.grid_columnconfigure(cols["stock"], minsize=150)
        frame.grid_columnconfigure(cols["price"], minsize=110)
        frame.grid_columnconfigure(cols["add"], minsize=44)

    def _pos_list_header(self):
        """رأس الأعمدة القابل للفرز فوق قائمة المنتجات: المنتج / المخزون / السعر.
        يُبنى داخل الشبكة الموحّدة نفسها التي تُبنى فيها الصفوف."""
        body = self._pos_body
        row = self._pos_take_row()
        cols = self._pos_grid_cols()
        self._pos_col_button(body, self.t("المنتج"), "name").grid(
            row=row, column=cols["name"], sticky="w", padx=(2, 6), pady=2)
        self._pos_col_button(body, self.t("المخزون"), "stock").grid(
            row=row, column=cols["stock"], sticky="w", padx=4, pady=2)
        self._pos_col_button(body, self.t("السعر"), "price").grid(
            row=row, column=cols["price"], sticky="e", padx=4, pady=2)

    def render_pos_products(self, search_term=""):
        if not hasattr(self, "pos_product_list"):
            return
        for widget in self.pos_product_list.winfo_children():
            widget.destroy()

        try:
            products = (
                self.product_manager.search_product(search_term)
                if search_term else self.product_manager.get_all_products()
            )
        except Exception as exc:
            self.toast(f"تعذر تحميل المنتجات: {exc}", "danger")
            products = []

        # فلتر التصنيف (AND مع الحالة والبحث).
        cat_selection = None
        if hasattr(self, "pos_category_combo"):
            try:
                cat_selection = str(self.pos_category_combo.get() or "").strip()
            except Exception:
                cat_selection = None
        if cat_selection and self._to_ar(cat_selection) != "كل التصنيفات":
            categories = self._load_categories()
            products = [p for p in products if self._match_category_filter(p, cat_selection, categories)]

        filtered = []
        for p in products:
            try:
                qty = float(p[4] or 0)
            except Exception:
                qty = 0
            if self.pos_filter == "available" and qty <= 5:
                continue
            if self.pos_filter == "low" and not (0 < qty <= 5):
                continue
            if self.pos_filter == "out" and qty > 0:
                continue
            filtered.append(p)

        # الفرز: يُطبَّق دائمًا بعد البحث/الفلترة وقبل تقسيم الترحيل، على
        # القائمة المُحمّلة بالفعل في الذاكرة (لا استعلام إضافي).
        if getattr(self, "pos_sort_col", None):
            key = self._pos_sort_key(self.pos_sort_col)
            filtered.sort(key=key, reverse=(self.pos_sort_dir == -1))

        # الباقات النشطة تُعرض كصفوف مميّزة أعلى قائمة المنتجات.
        try:
            packs = self.packs_manager.get_all_packs(include_inactive=False)
        except Exception:
            packs = []

        total_products = len(filtered)
        if hasattr(self, "pos_result_label"):
            self.pos_result_label.configure(
                text=self.t(f"{total_products} منتج • {len(packs)} باقة")
            )

        # الترحيل: نعرض صفحة محدودة فقط لتجنّب بناء مئات الصفوف دفعة واحدة.
        page_size = getattr(self, "pos_list_page_size", 40)
        if not getattr(self, "pos_list_page", None):
            self.pos_list_page = 1
        max_page = max(1, -(-total_products // page_size)) if products else 1
        self.pos_list_page = min(max(self.pos_list_page, 1), max_page)
        page_products = filtered[
            (self.pos_list_page - 1) * page_size:self.pos_list_page * page_size
        ]

        has_pack_rows = bool(packs)
        if not page_products and not packs:
            self.empty_state(
                self.pos_product_list, "⌕", "لا توجد نتائج",
                "جرّب كلمة بحث أخرى أو غيّر حالة المخزون"
            )
            return

        # جسم موحّد: الرأس والصفوف في شبكة واحدة مشتركة، فتتطابق أعمدة
        # المنتج/المخزون/السعر بين الرأس وجميع الصفوف حتمًا.
        body = ctk.CTkFrame(self.pos_product_list, fg_color="transparent")
        body.pack(fill="x")
        self._pos_apply_grid(body)
        self._pos_body = body
        self._pos_body_row = 0

        # رأس الأعمدة القابل للفرز فوق قائمة المنتجات (لا يمسّ المفضّلة).
        if page_products:
            self._pos_list_header()

        # صفاف الباقات (🎁) — قابلة للبيع مثلها مثل أي منتج.
        for pk in packs:
            try:
                pk_id, pk_name, pk_price = int(pk[0]), str(pk[1]), float(pk[2] or 0)
            except Exception:
                continue
            self._pos_list_row(kind="pack", id=pk_id, name=pk_name,
                               price=pk_price, stock=None, unit="باقة")

        # فاصل لطيف بين الباقات وقائمة المنتجات (إن وُجدت باقات).
        if has_pack_rows and page_products:
            sep = ctk.CTkFrame(body, fg_color="transparent", height=2)
            sep.grid(row=self._pos_take_row(), column=0, columnspan=5,
                     sticky="ew", pady=2)

        # صفاف المنتجات (صفحة واحدة فقط) — خفيفة وسريعة المسح.
        try:
            pinned_set = self.favorites_manager.pinned_ids()
        except Exception:
            pinned_set = None
        for p in page_products:
            self._pos_list_row(kind="product", product=p, pinned_set=pinned_set)

        # شريط الترحيل للمنتجات.
        if max_page > 1:
            self._pos_list_pager(total_products, page_size, max_page)

    def _product_card_v4(self, p, row=0, col=0, container=None,
                         mode="grid", fav_pinned=False, on_toggle=None):
        """بطاقة منتج. mode="grid" → شبكة البيع القديمة؛ mode="fav" →
        بطاقة أفقية في شريط المفضّلة مع نجمة للإزالة اليدوية."""
        container = container or self.pos_product_list
        try:
            qty = float(p[4] or 0)
        except Exception:
            qty = 0
        disabled = qty <= 0
        price = float(p[3] or 0)
        unit = str(p[5] or "قطعة")

        status = self.t("نفد") if disabled else (self.t("منخفض") if qty <= 5 else self.t("متوفر"))
        status_color = (
            self.colors["danger"] if disabled else
            self.colors["accent"] if qty <= 5 else
            self.colors["secondary"]
        )

        card = ctk.CTkFrame(
            container,
            fg_color=self.card(), corner_radius=14,
            border_width=1, border_color=self.border()
        )
        if mode == "fav":
            card.configure(width=170, height=210)
            card.pack_propagate(False)
            card.pack(side="left", padx=5, pady=3)
        else:
            card.grid(row=row, column=col, sticky="nsew", padx=5, pady=5)

        # صورة المنتج إن وجدت؛ وإلا نعرض اسم المنتج بشكل واضح داخل المساحة.
        visual = ctk.CTkFrame(
            card, height=105, fg_color=self.bg(), corner_radius=11
        )
        visual.pack(fill="x", padx=8, pady=8)
        visual.pack_propagate(False)

        image_path = p[-1] if len(p) > 8 else self._product_image_path(p[0])

        shown_image = False
        if Image is not None and image_path:
            try:
                photo = self._load_thumbnail(image_path, 220, 92)
                if photo is not None:
                    image_label = ctk.CTkLabel(visual, image=photo, text="")
                    image_label.image = photo
                    image_label.place(relx=0.5, rely=0.5, anchor="center")
                    shown_image = True
            except Exception:
                shown_image = False

        if not shown_image:
            image_label = ctk.CTkLabel(
                visual,
                text=str(p[2]),
                text_color=self.muted() if disabled else self.text(),
                font=ctk.CTkFont(
                    family=self.ui_font_family, size=14, weight="bold"
                ),
                wraplength=220,
                justify="center",
                anchor="center"
            )
            image_label.place(relx=0.5, rely=0.5, anchor="center")

        ctk.CTkLabel(
            visual, text=status, fg_color=status_color, text_color="white",
            corner_radius=7, font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold")
        ).place(relx=0.96, rely=0.08, anchor="ne")

        # نجمة المفضّلة اليدوية (في شريط المفضّلة: لإزالة المفضّلة).
        if mode == "fav":
            star = "★" if fav_pinned else "☆"
            ctk.CTkButton(
                visual, text=star, width=26, height=26, corner_radius=6,
                fg_color=self.card(), hover_color=self.border(),
                text_color=self.colors["accent"] if fav_pinned else self.muted(),
                font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
                command=lambda product=p: on_toggle(product[0]) if on_toggle else None
            ).place(relx=0.04, rely=0.08, anchor="nw")

        name = str(p[2])
        name_lbl = ctk.CTkLabel(
            card, text=name, text_color=self.muted() if disabled else self.text(),
            anchor="w", justify="left", wraplength=180,
            font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold")
        )
        name_lbl.pack(fill="x", padx=11, pady=(1, 1))

        # التصنيف كعنوان صغير تحت اسم المنتج إن وجد.
        cat_lbl = None
        if len(p) > 7 and p[7]:
            cat_lbl = ctk.CTkLabel(
                card, text=f"🏷 {p[7]}", text_color=self.muted(),
                anchor="w", font=ctk.CTkFont(family=self.ui_font_family,size=8)
            )
            cat_lbl.pack(fill="x", padx=11, pady=(0, 1))

        meta = ctk.CTkFrame(card, fg_color="transparent")
        meta.pack(fill="x", padx=11, pady=(0, 5))
        qty_lbl = ctk.CTkLabel(
            meta, text=f"{self._format_quantity(qty, unit)} {unit}", text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family,size=8)
        )
        qty_lbl.pack(side="left")
        price_lbl = ctk.CTkLabel(
            meta, text=self.t(f"{price:,.0f} د.ج"),
            text_color=self.muted() if disabled else self.colors["secondary"],
            font=ctk.CTkFont(family=self.ui_font_family,size=13, weight="bold")
        )
        price_lbl.pack(side="right")

        button = ctk.CTkButton(
            card,
            text=self.t("غير متوفر") if disabled else self.t("إضافة إلى السلة  ＋"),
            state="disabled" if disabled else "normal",
            command=None if disabled else lambda product=p: self.add_product_to_cart(product),
            height=33, corner_radius=8,
            fg_color=self.border() if disabled else self.colors["primary"],
            hover_color=self.border() if disabled else self.colors["primary_hover"],
            text_color=self.muted() if disabled else "white",
            font=ctk.CTkFont(family=self.ui_font_family,size=9, weight="bold")
        )
        button.pack(fill="x", padx=9, pady=(0, 9))

        # النقر في أي مكان على البطاقة يضيف المنتج (الصورة/الاسم/الخلفية…).
        # نربط الـ handler بكل عنصر لأن CTk يرسم كل عنصر على Canvas خاص به،
        # فعند النقر على اسم مثلًا تُصله النقرة عبر Canvas ذلك العنصر وليس
        # Canvas البطاقة الأم. (زر «إضافة» له command خاص به ولا نحتاج ربطه.)
        if not disabled:
            clickable = [card, visual, image_label, name_lbl, meta, qty_lbl, price_lbl]
            if cat_lbl is not None:
                clickable.append(cat_lbl)
            for widget in clickable:
                widget.bind(
                    "<Button-1>",
                    lambda e, product=p: self.add_product_to_cart(product)
                )

    def _pos_list_row(self, kind="product", product=None, id=None, name="",
                      price=0, stock=None, unit="قطعة", pinned_set=None):
        """صفّ مضغوط في قائمة نقطة البيع — kind="product" أو kind="pack"."""
        if kind == "pack":
            self._pos_list_pack_row(id, name, price)
            return
        p = product
        try:
            qty = float(p[4] or 0)
        except Exception:
            qty = 0
        disabled = qty <= 0
        pid = p[0]
        pname = str(p[2])
        pprice = float(p[3] or 0)
        punit = str(p[5] or "قطعة")
        if pinned_set is not None:
            pinned = pid in pinned_set
        else:
            pinned = bool(self.favorites_manager.is_pinned(pid))

        body = self._pos_body
        row = self._pos_take_row()
        cols = self._pos_grid_cols()

        # خلفية البطاقة (تعبر كل أعمدة الشبكة) + عناصر الصف فوقها — في نفس
        # الشبكة الموحّدة التي فيها الرأس، فتتطابق أعمدة المخزون/السعر.
        back = ctk.CTkFrame(
            body, fg_color=self.card(), corner_radius=12,
            border_width=1, border_color=self.border(), height=48
        )
        back.grid(row=row, column=0, columnspan=5, sticky="ew", padx=6, pady=2)
        back.grid_propagate(False)

        # عمود النجمة (المفضّلة اليدوية).
        ctk.CTkButton(
            body, text="★" if pinned else "☆", width=30, height=30, corner_radius=7,
            fg_color="transparent", hover_color=self.border(),
            text_color=self.colors["accent"] if pinned else self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
            command=lambda pid=pid: self.toggle_favorite(pid)
        ).grid(row=row, column=cols["star"], sticky="w", padx=(8, 0), pady=9)

        name_lbl = ctk.CTkLabel(
            body, text=pname, text_color=self.muted() if disabled else self.text(),
            anchor="w", justify="left",
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
        )
        name_lbl.grid(row=row, column=cols["name"], sticky="w", padx=(4, 6), pady=9)
        if not disabled:
            name_lbl.bind("<Button-1>", lambda e, p=p: self.add_product_to_cart(p))

        # عمود المخزون: الكمية والوحدة بجانب الحالة (لون الحالة محفوظ).
        status = self.t("نفد") if disabled else (self.t("منخفض") if qty <= 5 else self.t("متوفر"))
        status_color = (
            self.colors["danger"] if disabled else
            self.colors["accent"] if qty <= 5 else
            self.colors["secondary"]
        )
        stock_box = ctk.CTkFrame(body, fg_color="transparent")
        stock_box.grid(row=row, column=cols["stock"], sticky="w", padx=4, pady=9)
        stock_qty_lbl = ctk.CTkLabel(
            stock_box, text=f"{self._format_quantity(qty, punit)} {punit} • ",
            text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=9)
        )
        stock_qty_lbl.pack(side="left")
        stock_status_lbl = ctk.CTkLabel(
            stock_box, text=status, text_color=status_color,
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        )
        stock_status_lbl.pack(side="left")

        # عمود السعر + زر الإضافة.
        price_row_lbl = ctk.CTkLabel(
            body, text=self.t(f"{pprice:,.0f} د.ج"),
            text_color=self.muted() if disabled else self.colors["secondary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")
        )
        price_row_lbl.grid(row=row, column=cols["price"], sticky="e", padx=(4, 6), pady=9)
        ctk.CTkButton(
            body, text="＋", width=30, height=30, corner_radius=8,
            state="disabled" if disabled else "normal",
            command=None if disabled else lambda p=p: self.add_product_to_cart(p),
            fg_color=self.border() if disabled else self.colors["primary"],
            hover_color=self.border() if disabled else self.colors["primary_hover"],
            text_color=self.muted() if disabled else "white",
            font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold")
        ).grid(row=row, column=cols["add"], sticky="e", padx=(8, 8), pady=9)

        if not disabled:
            # النقر في أي مكان بالصف (الخلفية/الاسم/المخزون/السعر) يضيف المنتج؛
            # نربط كل عنصر لأن CTk يرسم كل عنصر على Canvas خاص به، والنقر على
            # عنصر يصل إلى Canvas ذلك العنصر وليس Canvas الخلفية الأم.
            for widget in (back, name_lbl, stock_box, stock_qty_lbl,
                           stock_status_lbl, price_row_lbl):
                widget.bind("<Button-1>", lambda e, p=p: self.add_product_to_cart(p))

    def _pos_list_pack_row(self, pack_id, name, price):
        body = self._pos_body
        row = self._pos_take_row()
        cols = self._pos_grid_cols()

        back = ctk.CTkFrame(
            body, fg_color=self.colors.get("pack_bg", self.card()),
            corner_radius=12, border_width=2, border_color=self.colors["primary"],
            height=48
        )
        back.grid(row=row, column=0, columnspan=5, sticky="ew", padx=6, pady=2)
        back.grid_propagate(False)

        left = ctk.CTkFrame(body, fg_color="transparent")
        left.grid(row=row, column=cols["name"], sticky="w", padx=(4, 6), pady=9)
        pack_name_lbl = ctk.CTkLabel(
            left, text="🎁  " + name, text_color=self.colors["primary"], anchor="w",
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
        )
        pack_name_lbl.pack(anchor="w")
        pack_tag_lbl = ctk.CTkLabel(
            left, text=self.t("باقة"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        )
        pack_tag_lbl.pack(anchor="w")

        right = ctk.CTkFrame(body, fg_color="transparent")
        right.grid(row=row, column=cols["price"], sticky="e", padx=(4, 6), pady=9)
        pack_price_lbl = ctk.CTkLabel(
            right, text=self.t(f"{price:,.0f} د.ج"), text_color=self.colors["secondary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")
        )
        pack_price_lbl.pack(side="left", padx=(4, 10))
        ctk.CTkButton(
            body, text="＋", width=30, height=30, corner_radius=8,
            command=lambda pid=pack_id: self.add_pack_to_cart(pid),
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold")
        ).grid(row=row, column=cols["add"], sticky="e", padx=(8, 8), pady=9)
        # النقر على أي مكان في صف الباقة يضيفها؛ نربط كل عنصر كما في صفوف المنتجات.
        for widget in (back, left, pack_name_lbl, pack_tag_lbl,
                       right, pack_price_lbl):
            widget.bind("<Button-1>", lambda e, pid=pack_id: self.add_pack_to_cart(pid))

    def _pos_list_pager(self, total, page_size, max_page):
        if max_page <= 1:
            return
        body = self._pos_body
        row = self._pos_take_row()
        pager = ctk.CTkFrame(body, fg_color="transparent")
        pager.grid(row=row, column=0, columnspan=5, sticky="ew", pady=(8, 4))
        ctk.CTkLabel(
            pager, text=self.t(f"{self.pos_list_page} / {max_page} • {total} منتج"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="left", padx=4)
        nav = ctk.CTkFrame(pager, fg_color="transparent")
        nav.pack(side="right")
        for label, delta in (("‹", -1), ("›", 1)):
            enabled = 1 <= self.pos_list_page + delta <= max_page
            ctk.CTkButton(
                nav, text=label, width=32, height=28, corner_radius=7,
                fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                state="normal" if enabled else "disabled",
                font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"),
                command=(lambda d=delta: self._pos_list_go_page(self.pos_list_page + d) if enabled else None)
            ).pack(side="left", padx=2)

    def _pos_list_go_page(self, pg):
        self.pos_list_page = max(1, pg)
        term = self.pos_search.get().strip() if hasattr(self, "pos_search") else ""
        try:
            self.pos_product_list._parent_canvas.yview_moveto(0)
        except Exception:
            pass
        self.render_pos_products(term)

    def _render_pos_favorites(self):
        """يرسم شريط المفضّلة الثابت أعلى قائمة البيع. يُستدعى مرة واحدة عند
        فتح نقطة البيع وبعد أي تبديل نجمة — لا يُعاد رسمه عند كل بحث."""
        if not self._db_ready:
            return
        if not hasattr(self, "pos_fav_row"):
            return
        for w in self.pos_fav_row.winfo_children():
            w.destroy()

        fm = self.favorites_manager
        # المفضّلة اليدوية أولًا، ثم التلقائية حسب ترتيب المبيعات، ضمن السقف.
        pinned = []
        auto = []
        try:
            for row in fm.get_all_favorites():
                (pinned if int(row[2]) else auto).append(int(row[1]))
        except Exception:
            pass

        # ترتيب التلقائية حسب الأكثر مبيعًا (وليس حسب تاريخ الإدراج فقط).
        try:
            rank = {pid: i for i, pid in enumerate(
                fm.top_product_ids_by_sales(limit=self.fav_display_cap))}
        except Exception:
            rank = {}
        auto.sort(key=lambda pid: rank.get(pid, len(rank)))

        cap = getattr(self, "fav_display_cap", 15)
        pinned = pinned[:cap]
        slot_left = max(0, cap - len(pinned))
        auto_ids = [pid for pid in auto if pid not in set(pinned)][:slot_left]
        fav_ids = pinned + auto_ids

        if not fav_ids:
            hint = ctk.CTkFrame(self.pos_fav_row, fg_color="transparent", height=24)
            hint.pack(side="left", padx=4)
            ctk.CTkLabel(
                hint, text=self.t("أضف نجمة ⭐ للمنتج ليظهر هنا"),
                text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack()
            return

        # جلب بيانات المنتجات دفعة واحدة + الصور دفعة واحدة (لا N+1).
        try:
            all_prods = self.product_manager.get_all_products()
        except Exception:
            all_prods = []
        by_id = {p[0]: p for p in all_prods}
        img_map = self._get_images_map(fav_ids)
        pinned_set = set(pinned)
        for pid in fav_ids:
            p = by_id.get(pid)
            if p is None:
                continue
            # عرض فقط المنتجات المتوفّرة: نخفي غير المتوفّرة (qty<=0) من
            # الشريط دون المساس بحالة المفضّلة في قاعدة البيانات — تعود تلقائيًا
            # عند إعادة التخزين لأن إعادة الرسم تقرأ المخزون الحالي.
            try:
                qty = float(p[4])
            except Exception:
                qty = 0.0
            if qty <= 0:
                continue
            enriched = tuple(p) + (img_map.get(pid),)
            self._product_card_v4(
                enriched, container=self.pos_fav_row, mode="fav",
                fav_pinned=pid in pinned_set,
                on_toggle=lambda _pid=pid: self.toggle_favorite(_pid)
            )

    def toggle_favorite(self, product_id):
        """تبديل المفضّلة اليدوية لمنتج ثم إعادة رسم شريط المفضّلة."""
        try:
            # قد يُمرَّر معرّف صحيح أو صفّ منتج (tuple من بطاقة المفضّلة)؛
            # نثبّت المعرّف الصحيح قبل التعامل مع قاعدة البيانات.
            if isinstance(product_id, bool):
                pid = int(product_id)
            elif isinstance(product_id, int):
                pid = int(product_id)
            else:
                pid = int(product_id[0])
            fm = self.favorites_manager
            fm.set_manual(pid, not fm.is_pinned(pid))
            self._render_pos_favorites()
        except Exception as exc:
            self.toast(f"تعذر تحديث المفضّلة: {exc}", "danger")

    def select_customer(self):
        win = ctk.CTkToplevel(self)
        win.title(self.t("اختيار العميل"))
        win.geometry("540x580")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 540, 580)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        top = ctk.CTkFrame(container, fg_color="transparent")
        top.pack(fill="x", pady=(2, 12))
        ctk.CTkLabel(
            top, text=self.t("اختيار العميل"), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=20, weight="bold")
        ).pack(side="left")
        ctk.CTkButton(
            top, text=self.t("زبون نقدي"), width=95, height=32, corner_radius=8,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            command=lambda: choose(None)
        ).pack(side="right")

        search = ctk.CTkEntry(
            container, placeholder_text=self.t("ابحث بالاسم أو الهاتف…"), height=42,
            corner_radius=9, fg_color=self.card(), border_color=self.border(),
            text_color=self.text()
        )
        search.pack(fill="x", pady=(0, 10))

        results = ctk.CTkScrollableFrame(container, fg_color="transparent")
        results.pack(fill="both", expand=True)

        def choose(customer):
            self.selected_customer = customer
            self.customer_label.configure(
                text=customer[1] if customer else self.t("زبون نقدي")
            )
            win.destroy()

        def render():
            for w in results.winfo_children():
                w.destroy()
            term = search.get().strip()
            try:
                customers = (
                    self.customer_manager.search_customer(term)
                    if term else self.customer_manager.get_all_customers()
                )
            except Exception:
                customers = []
            for customer in customers[:100]:
                row = ctk.CTkFrame(
                    results, fg_color=self.card(), corner_radius=10,
                    border_width=1, border_color=self.border()
                )
                row.pack(fill="x", pady=3)
                ctk.CTkLabel(
                    row, text=str(customer[1]), text_color=self.text(),
                    anchor="w", font=ctk.CTkFont(family=self.ui_font_family,size=11, weight="bold")
                ).pack(side="left", padx=12, pady=10)
                ctk.CTkLabel(
                    row, text=str(customer[2] or self.t("بدون هاتف")), text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family,size=9)
                ).pack(side="left")
                ctk.CTkButton(
                    row, text=self.t("اختيار"), width=65, height=28, corner_radius=7,
                    fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                    font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold"),
                    command=lambda c=customer: choose(c)
                ).pack(side="right", padx=7)

        search.bind("<KeyRelease>", lambda e: render())
        render()
        search.focus_set()

    def add_to_cart(self, event=None):
        search = self.pos_search.get().strip()
        if not search:
            return
        # باركود متغير (مقاس/لون) يُضاف مباشرة مع المتغير الصحيح.
        try:
            variant = self.db.get_variant_by_barcode(search)
        except Exception:
            variant = None
        if variant:
            self._add_variant_to_cart(variant)
            self.clear_pos_product_search()
            return
        try:
            products = self.product_manager.search_product(search)
        except Exception as exc:
            self.toast(f"خطأ في البحث: {exc}", "danger")
            return
        if not products:
            self.toast("المنتج غير موجود", "danger")
            return

        # Prefer an exact barcode match, then an exact product-name match,
        # otherwise use the first search result.
        exact = None
        search_lower = search.casefold()
        for p in products:
            barcode = str(p[1] or "").casefold()
            name = str(p[2] or "").casefold()
            if barcode == search_lower or name == search_lower:
                exact = p
                break

        target = exact or products[0]
        # منتج له متغيرات: يُجبر اختيار المقاس/اللون ولا يُضاف المنتج مباشرة.
        try:
            product_variants = self.db.get_product_variants(target[0])
        except Exception:
            product_variants = []
        if product_variants:
            self._show_variant_picker(target, product_variants)
            self.clear_pos_product_search()
            return
        self.add_product_to_cart(target)
        self.clear_pos_product_search()

    def add_to_cart_from_list(self, product):
        self.add_product_to_cart(product)

    def _add_variant_to_cart(self, variant):
        """إضافة متغير (مقاس/لون) إلى السلة مباشرة.
        variant: (variant_id, variant_name, barcode, qty, price, pid, pname, pprice, unit)
        """
        (variant_id, variant_name, _barcode, _v_qty, v_price,
         pid, pname, pprice, p_unit) = variant
        # استعلام مباشر عن مخزون المتغير (وليس المنتج الأب) لضمان حد صارم.
        cur_variant = None
        try:
            conn = self.db.get_connection()
            try:
                cur_variant = conn.execute(
                    "SELECT quantity, variant_name FROM product_variants WHERE id = ?", (variant_id,)
                ).fetchone()
            finally:
                conn.close()
        except Exception:
            cur_variant = None
        if not cur_variant:
            self.toast("المتغير غير موجود", "danger")
            return
        try:
            actual_v_stock = float(cur_variant[0] or 0)
        except Exception:
            actual_v_stock = 0.0
        unit = str(p_unit or "قطعة")
        try:
            price = float(v_price) if v_price not in (None, "") else float(pprice or 0)
        except Exception:
            price = float(pprice or 0)
        name = f"{pname} ({variant_name})"

        if self._is_weighted_unit(unit):
            self._show_variant_qty_dialog(variant, actual_v_stock, unit, price)
            return

        for item in self.cart:
            if item.get("variant_id") == variant_id:
                current_cart_qty = float(item["quantity"])
                if current_cart_qty + 1.0 > actual_v_stock + 1e-9:
                    self.toast(
                        f"لا يمكن إضافة المزيد: المتوفر من ({variant_name}) هو ({actual_v_stock:g}) فقط",
                        "warning"
                    )
                    return
                item["quantity"] = current_cart_qty + 1.0
                item["unit"] = unit
                item["total"] = max(0.0, float(item["price"]) * item["quantity"] - float(item.get("item_discount", 0.0) or 0.0))
                self.update_cart_display()
                if hasattr(self, "pos_search"):
                    self.pos_search.delete(0, "end")
                    self.pos_search.focus_set()
                return
        if actual_v_stock < 1.0:
            self.toast("المقاس/اللون غير متوفر في المخزون", "danger")
            return
        self.cart.append({"id": pid, "variant_id": variant_id, "name": name,
                          "price": price, "quantity": 1.0, "total": price,
                          "unit": unit, "item_discount": 0.0})
        self.update_cart_display()
        if hasattr(self, "pos_search"):
            self.pos_search.delete(0, "end")
            self.pos_search.focus_set()
        self.clear_pos_product_search()

    def _show_variant_picker(self, product, variants):
        """نافذة اختيار المقاس/اللون لمنتج ذي متغيرات."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("اختر المقاس / اللون"))
        win.geometry("560x540")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 560, 540)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(
            container, text=str(product[2]), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(anchor="w")
        ctk.CTkLabel(
            container, text=self.t("اختر المقاس / اللون المناسب"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        ).pack(anchor="w", pady=(3, 15))

        grid = ctk.CTkScrollableFrame(container, fg_color="transparent")
        grid.pack(fill="both", expand=True)

        def select_variant(v):
            """إضافة المتغير المختار وإغلاق النافذة فورًا."""
            v_id, v_name, v_barcode, v_qty, v_price = v[:5]
            full = (v_id, v_name, v_barcode, v_qty, v_price,
                    product[0], str(product[2] or ""), float(product[3] or 0),
                    str(product[5] or "قطعة") if len(product) > 5 else "قطعة")
            win.destroy()
            self._add_variant_to_cart(full)

        # Flat layout: buttons in left column, stock + price in right column.
        for variant in variants:
            variant_id, variant_name, _barcode, v_qty, v_price = variant[:5]
            try:
                v_qty = float(v_qty or 0)
            except Exception:
                v_qty = 0.0
            try:
                display_price = float(v_price) if v_price not in (None, "") else float(product[3] or 0)
            except Exception:
                display_price = float(product[3] or 0)
            out = v_qty <= 0
            row = ctk.CTkFrame(grid, fg_color=self.card(), corner_radius=9)
            row.pack(fill="x", pady=4, padx=2)
            row.grid_columnconfigure(0, weight=1)

            price_text = self.t(f"{display_price:,.2f} د.ج")
            if out:
                price_text += "  •  " + self.t("نفد المخزون")
            info = ctk.CTkLabel(
                row, text=f"{variant_name}  •  {self._format_quantity(v_qty)}  •  {price_text}",
                text_color=(self.muted() if out else self.text()),
                anchor="w",
                font=ctk.CTkFont(family=self.ui_font_family, size=12)
            )
            info.grid(row=0, column=0, padx=12, pady=10, sticky="w")

            if out:
                ctk.CTkButton(
                    row, text=self.t("نفد"), width=90, height=32,
                    fg_color=self.border(), hover_color=self.border(),
                    text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=11),
                    state="disabled"
                ).grid(row=0, column=1, padx=10, pady=10)
            else:
                ctk.CTkButton(
                    row, text=self.t("إضافة"), width=90, height=32,
                    fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                    font=ctk.CTkFont(family=self.ui_font_family, size=11),
                    command=lambda v=variant: select_variant(v)
                ).grid(row=0, column=1, padx=10, pady=10)

        ctk.CTkButton(
            container, text=self.t("إلغاء"), command=win.destroy, height=42,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=12)
        ).pack(fill="x", pady=(14, 0))

    def _show_variant_qty_dialog(self, variant, stock, unit, price):
        """طلب كمية وافرة لمتغير بوحدة قياس (كغ/لتر...) ثم إضافته إلى السلة."""
        (variant_id, variant_name, _barcode, _v_qty, _v_price,
         pid, pname, _pprice, _p_unit) = variant
        win = ctk.CTkToplevel(self)
        win.title(self.t("تحديد كمية المتغير"))
        win.geometry("460x320")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 460, 320)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(
            container, text=f"{pname} ({variant_name})", text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold")
        ).pack(anchor="w")
        ctk.CTkLabel(
            container,
            text=self.t(f"السعر: {price:,.2f} د.ج / {unit} • المتاح: {self._format_quantity(stock, unit)} {unit}"),
            text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=10)
        ).pack(anchor="w", pady=(3, 14))

        ctk.CTkLabel(container, text=self.t(f"الكمية ({unit})"), text_color=self.text(), anchor="w",
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")).pack(fill="x", pady=(0, 5))
        qty_entry = ctk.CTkEntry(container, height=44, corner_radius=9,
                                 fg_color=self.card(), border_color=self.border(), text_color=self.text(),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=15))
        qty_entry.pack(fill="x")
        qty_entry.insert(0, self._format_quantity(1.0, unit))
        qty_entry.focus_set()

        def confirm():
            try:
                qty = float(qty_entry.get().replace(",", ".").strip())
            except ValueError:
                self.toast("أدخل رقمًا صحيحًا", "danger")
                return
            if qty <= 0:
                self.toast("أدخل رقمًا أكبر من صفر", "danger")
                return
            if qty > float(stock) + 1e-9:
                self.toast(f"الكمية المطلوبة أكبر من المتاح ({self._format_quantity(stock, unit)} {unit})", "danger")
                return
            qty = round(qty, 6)
            existing = next((i for i in self.cart if i.get("variant_id") == variant_id), None)
            if existing:
                existing_qty = float(existing["quantity"])
                if existing_qty + qty > float(stock) + 1e-9:
                    self.toast(
                        f"وصلت للكمية القصوى المتوفرة من هذا المقاس "
                        f"({self._format_quantity(stock, unit)} {unit})",
                        "warning"
                    )
                    return
                existing["quantity"] = round(existing_qty + qty, 6)
                existing["total"] = round(float(existing["price"]) * existing["quantity"], 2)
            else:
                self.cart.append({"id": pid, "variant_id": variant_id,
                                  "name": f"{pname} ({variant_name})", "price": price,
                                  "quantity": qty, "total": round(price * qty, 2),
                                  "unit": unit, "item_discount": 0.0})
            win.destroy()
            self.update_cart_display()
            self.clear_pos_product_search()

        qty_entry.bind("<Return>", lambda e: confirm())
        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", pady=(14, 0))
        ctk.CTkButton(buttons, text=self.t("إضافة إلى السلة"), command=confirm, height=42,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]).pack(side="right", fill="x", expand=True, padx=4)
        ctk.CTkButton(buttons, text=self.t("إلغاء"), command=win.destroy, height=42,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()).pack(side="right", fill="x", expand=True, padx=4)

    def _quantity_step(self, unit):
        unit = str(unit or "قطعة").strip().lower()
        if unit in ("كغ", "kg", "كيلوغرام"):
            return 0.001
        if unit in ("غرام", "g", "غ"):
            return 1.0
        if unit in ("لتر", "l"):
            return 0.001
        if unit in ("مل", "ml"):
            return 1.0
        if unit in ("متر", "m"):
            return 0.01
        return 1.0

    def _format_quantity(self, value, unit=None):
        try:
            value = float(value)
        except Exception:
            return str(value)
        if abs(value - round(value)) < 1e-9:
            return str(int(round(value)))
        return f"{value:.3f}".rstrip("0").rstrip(".")

    def _is_weighted_unit(self, unit):
        unit = str(unit or "").strip().lower()
        return unit in ("كغ", "kg", "كيلوغرام", "غرام", "g", "غ", "لتر", "l", "مل", "ml", "متر", "m")

    def _add_weighted_product_dialog(self, product, stock, unit):
        """Ask for either weight/quantity or target price, then add the calculated amount."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("تحديد كمية المنتج"))
        win.geometry("460x430")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 460, 430)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(
            container, text=str(product[2]), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(anchor="w")
        ctk.CTkLabel(
            container, text=self.t(f"السعر: {float(product[3]):,.2f} د.ج / {unit} • المخزون: {self._format_quantity(stock, unit)} {unit}"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        ).pack(anchor="w", pady=(3, 15))

        mode = ctk.StringVar(value="weight")
        mode_row = ctk.CTkFrame(container, fg_color="transparent")
        mode_row.pack(fill="x", pady=(0, 12))
        ctk.CTkRadioButton(
            mode_row, text=self.t("أدخل الوزن / الكمية"), variable=mode, value="weight",
            font=ctk.CTkFont(family=self.ui_font_family, size=11)
        ).pack(side="left", padx=(0, 20))
        ctk.CTkRadioButton(
            mode_row, text=self.t("أدخل السعر"), variable=mode, value="price",
            font=ctk.CTkFont(family=self.ui_font_family, size=11)
        ).pack(side="left")

        input_label = ctk.CTkLabel(container, text=self.t("الوزن / الكمية"), text_color=self.text(), anchor="w",
                                   font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"))
        input_label.pack(fill="x", pady=(0, 5))
        value_entry = ctk.CTkEntry(container, height=44, corner_radius=9,
                                   fg_color=self.card(), border_color=self.border(), text_color=self.text(),
                                   font=ctk.CTkFont(family=self.ui_font_family, size=15))
        value_entry.pack(fill="x")

        hint = ctk.CTkLabel(container, text="", text_color=self.muted(), anchor="w",
                            font=ctk.CTkFont(family=self.ui_font_family, size=9))
        hint.pack(fill="x", pady=(5, 14))

        result_card = self.make_card(container)
        result_card.pack(fill="x", pady=(0, 16))
        result_label = ctk.CTkLabel(result_card, text="", text_color=self.colors["secondary"],
                                    font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"))
        result_label.pack(pady=12)

        def refresh_mode(*_):
            if mode.get() == "weight":
                input_label.configure(text=self.t(f"الوزن / الكمية ({unit})"))
                hint.configure(text=(self.t(f"مثال: 0.075 {unit} = 75 غرام إذا كانت الوحدة كغ") if unit in ("كغ", "kg", "كيلوغرام") else
                                     self.t(f"أدخل الكمية المطلوبة بوحدة {unit}")))
            else:
                input_label.configure(text=self.t("السعر الذي تريد شراءه (دج)"))
                hint.configure(text=self.t("مثال: أدخل 100 دج ليحسب البرنامج الكمية المقابلة تلقائيًا"))
            result_label.configure(text="")
            value_entry.focus_set()

        mode.trace_add("write", refresh_mode)
        refresh_mode()

        def confirm():
            try:
                value = float(value_entry.get().replace(",", ".").strip())
                if value <= 0:
                    raise ValueError
                price_per_unit = float(product[3] or 0)
                if price_per_unit <= 0:
                    self.toast("سعر المنتج يجب أن يكون أكبر من صفر", "danger")
                    return

                if mode.get() == "weight":
                    qty = value
                    amount = qty * price_per_unit
                else:
                    amount = value
                    qty = amount / price_per_unit

                if qty > float(stock) + 1e-9:
                    self.toast(f"الكمية المطلوبة أكبر من المخزون المتاح ({self._format_quantity(stock, unit)} {unit})", "danger")
                    return

                qty = round(qty, 6)
                amount = round(amount, 2)
                existing = next((item for item in self.cart if item["id"] == product[0]), None)
                existing_qty = float(existing["quantity"]) if existing else 0.0
                if existing_qty + qty > float(stock) + 1e-9:
                    self.toast("الكمية الإجمالية في السلة تتجاوز المخزون", "danger")
                    return

                if existing:
                    existing["quantity"] = round(existing_qty + qty, 6)
                    existing["unit"] = unit
                    existing["total"] = max(
                        0.0,
                        existing["price"] * existing["quantity"]
                        - float(existing.get("item_discount", 0.0) or 0.0)
                    )
                else:
                    self.cart.append({
                        "id": product[0], "name": product[2], "price": price_per_unit,
                        "quantity": qty, "total": amount, "unit": unit,
                        "item_discount": 0.0
                    })
                win.destroy()
                self.update_cart_display()
                self.clear_pos_product_search()
            except ValueError:
                self.toast("أدخل رقمًا صحيحًا، مثل 0.075 أو 100", "danger")

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x")
        ctk.CTkButton(buttons, text=self.t("إضافة إلى السلة"), command=confirm, height=42,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"]).pack(side="right", fill="x", expand=True, padx=4)
        ctk.CTkButton(buttons, text=self.t("إلغاء"), command=win.destroy, height=42,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text()).pack(side="right", fill="x", expand=True, padx=4)
        value_entry.bind("<Return>", lambda e: confirm())

    def add_product_to_cart(self, product):
        # منتج له متغيرات: يُجبر اختيار المقاس/اللون بدلاً من الإضافة المباشرة،
        # حتى لو كان المخزون الأب صفرًا أو المنتج بوحدة قياس.
        try:
            variants = self.db.get_product_variants(product[0])
        except Exception:
            variants = []
        if variants:
            self._show_variant_picker(product, variants)
            return

        try:
            stock = float(product[4] or 0)
        except Exception:
            stock = 0.0
        if stock <= 0:
            self.toast("المنتج غير متوفر في المخزون", "danger")
            return
        unit = str(product[5] or "قطعة")

        # Weighted/measured products require the cashier to specify either
        # the desired weight/quantity or the amount of money.
        if self._is_weighted_unit(unit):
            self._add_weighted_product_dialog(product, stock, unit)
            return

        # Piece-based products keep the fast one-click POS behavior.
        for item in self.cart:
            if item["id"] == product[0]:
                new_qty = float(item["quantity"]) + 1.0
                if new_qty > stock + 1e-9:
                    self.toast("وصلت للكمية المتوفرة في المخزون", "warning")
                    return
                item["quantity"] = new_qty
                item["unit"] = unit
                item["total"] = max(0.0, float(item["price"]) * new_qty - float(item.get("item_discount", 0.0) or 0.0))
                self.update_cart_display()
                if hasattr(self, "pos_search"):
                    self.pos_search.delete(0, "end")
                    self.pos_search.focus_set()
                return
        self.cart.append({"id": product[0], "name": product[2], "price": float(product[3]),
                          "quantity": 1.0, "total": float(product[3]), "unit": unit,
                          "item_discount": 0.0})
        self.update_cart_display()
        if hasattr(self, "pos_search"):
            self.pos_search.delete(0, "end")
            self.pos_search.focus_set()
        self.clear_pos_product_search()

    def add_pack_to_cart(self, pack_id):
        line = self._pack_cart_line(pack_id, 1.0)
        if line is None:
            self.toast("تعذر تحميل الباقة", "danger")
            return
        components = line["components"]
        # إذا كانت الباقة موجودة مسبقًا نحاول زيادتها أولًا.
        for it in self.cart:
            if it.get("is_pack") and it.get("pack_id") == int(pack_id):
                new_qty = float(it["quantity"]) + 1.0
                ok, msg = self._validate_pack_in_cart(components, new_qty)
                if not ok:
                    self.toast(msg, "danger")
                    return
                it["quantity"] = new_qty
                it["total"] = float(it["price"]) * new_qty
                self.update_cart_display()
                return
        ok, msg = self._validate_pack_in_cart(components, 1.0)
        if not ok:
            self.toast(msg, "danger")
            return
        self.cart.append(line)
        self.update_cart_display()

    def _cart_sig(self, item):
        return (
            item.get("id"), item.get("is_pack"), item.get("name"),
            item.get("quantity"), item.get("total"),
            float(item.get("item_discount", 0.0) or 0.0), item.get("price"),
        )

    def update_cart_display(self):
        if not hasattr(self, "cart_container"):
            return
        if not hasattr(self, "_cart_cards"):
            self._cart_cards = []
            self._cart_sigs = []
            self._cart_empty_widget = None

        subtotal = sum(float(item["total"]) for item in self.cart)
        discount = min(float(getattr(self, "sale_discount", 0.0) or 0.0), subtotal)
        self.total = max(0.0, subtotal - discount)

        new_sigs = [self._cart_sig(it) for it in self.cart]

        if not self.cart:
            # clear cached cards once (they own the child widgets)
            if self._cart_cards:
                for c in self._cart_cards:
                    if c is not None:
                        try:
                            c.destroy()
                        except Exception:
                            pass
                self._cart_cards = []
                self._cart_sigs = []
            else:
                for w in self.cart_container.winfo_children():
                    w.destroy()
            self._cart_empty_widget = None
            empty = ctk.CTkFrame(self.cart_container, fg_color="transparent")
            empty.pack(fill="both", expand=True, pady=40)
            ctk.CTkLabel(
                empty, text=self.t("السلة فارغة"), text_color=self.text(),
                font=ctk.CTkFont(family=self.ui_font_family,size=16, weight="bold")
            ).pack(pady=(60, 4))
            ctk.CTkLabel(
                empty, text=self.t("ابدأ بمسح Barcode أو اختر منتجاً من الشبكة"),
                text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family,size=9)
            ).pack()
            self._cart_empty_widget = empty
        else:
            # السلة لم تعد فارغة: إزالة عنصر الحالة الفارغة إن وُجد (الانتقال 0 → 1+).
            if self._cart_empty_widget is not None:
                try:
                    self._cart_empty_widget.destroy()
                except Exception:
                    pass
                self._cart_empty_widget = None
            n = len(self.cart)
            old_len = len(self._cart_cards)
            # shrink cache if cart shrank (rows removed at the end / trailing)
            if old_len > n:
                for c in self._cart_cards[n:]:
                    if c is not None:
                        try:
                            c.destroy()
                        except Exception:
                            pass
                self._cart_cards = self._cart_cards[:n]
                self._cart_sigs = self._cart_sigs[:n]
            elif old_len < n:
                self._cart_cards += [None] * (n - old_len)
                self._cart_sigs += [None] * (n - old_len)

            # rebuild only the rows whose content changed (or that are new).
            for index, item in enumerate(self.cart):
                sig = new_sigs[index]
                if self._cart_sigs[index] == sig and self._cart_cards[index] is not None:
                    continue
                if self._cart_cards[index] is not None:
                    try:
                        self._cart_cards[index].destroy()
                    except Exception:
                        pass
                self._cart_cards[index] = self.cart_item_row(index, item)
                self._cart_sigs[index] = sig

        if hasattr(self, "subtotal_label"):
            self.subtotal_label.configure(text=self.t(f"{subtotal:,.2f} د.ج"))
        if hasattr(self, "discount_label"):
            self.discount_label.configure(text=self.t(f"{discount:,.2f} د.ج"))
        if hasattr(self, "pos_total_label"):
            self.pos_total_label.configure(text=self.t(f"{self.total:,.2f} د.ج"))
        if hasattr(self, "cart_count"):
            count = sum(float(x["quantity"]) for x in self.cart)
            self.cart_count.configure(text=self.t(f"{self._format_quantity(count)} • {len(self.cart)} منتج"))

    def cart_item_row(self, index, item):
        if item.get("is_pack"):
            return self._cart_pack_row(index, item)
        card = ctk.CTkFrame(
            self.cart_container, fg_color=self.bg(), corner_radius=10,
            border_width=1, border_color=self.border()
        )
        card.pack(fill="x", pady=3)

        top = ctk.CTkFrame(card, fg_color="transparent")
        top.pack(fill="x", padx=10, pady=(8, 3))
        ctk.CTkLabel(
            top, text=item["name"], text_color=self.text(), anchor="w",
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="left", fill="x", expand=True)
        ctk.CTkButton(
            top, text="×", width=24, height=24, corner_radius=6,
            fg_color="transparent", hover_color=self.colors["danger"],
            text_color=self.colors["danger"],
            command=lambda i=index: self.remove_from_cart(i)
        ).pack(side="right")

        # زر خصم على هذا المنتج تحديدًا.
        ctk.CTkButton(
            top, text="🏷", width=24, height=24, corner_radius=6,
            fg_color="transparent", hover_color=self.border(),
            text_color=self.colors["accent"],
            font=ctk.CTkFont(family=self.ui_font_family,size=11),
            command=lambda i=index: self._open_item_discount_dialog(i)
        ).pack(side="right", padx=(0, 2))

        bottom = ctk.CTkFrame(card, fg_color="transparent")
        bottom.pack(fill="x", padx=10, pady=(0, 8))
        qty = ctk.CTkFrame(bottom, fg_color="transparent")
        qty.pack(side="left")
        ctk.CTkButton(
            qty, text="−", width=25, height=25, corner_radius=6,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            command=lambda i=index: self.update_cart_quantity(i, -1)
        ).pack(side="left", padx=1)
        ctk.CTkLabel(
            qty, text=self._format_quantity(item["quantity"], item.get("unit")), width=48, text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="left")
        ctk.CTkButton(
            qty, text="+", width=25, height=25, corner_radius=6,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            command=lambda i=index: self.update_cart_quantity(i, 1)
        ).pack(side="left", padx=1)
        ctk.CTkLabel(
            bottom, text=self.t(self.t(f"{item['price']:,.2f} / {item.get('unit', 'قطعة')} × {self._format_quantity(item['quantity'], item.get('unit'))}")),
            text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family,size=8)
        ).pack(side="left", padx=8)
        # عرض الخصم على مستوى المنتج إن وُجد: السعر الأصلي مشطوبًا + قيمة الخصم.
        item_disc = float(item.get("item_discount", 0.0) or 0.0)
        total_box = ctk.CTkFrame(bottom, fg_color="transparent")
        total_box.pack(side="right")
        if item_disc > 0:
            original_total = float(item["price"]) * float(item["quantity"])
            ctk.CTkLabel(
                total_box, text=f"-{item_disc:,.0f}",
                text_color=self.colors["accent"],
                font=ctk.CTkFont(family=self.ui_font_family,size=8, weight="bold")
            ).pack(side="right", padx=(0, 3))
            ctk.CTkLabel(
                total_box, text=f"{original_total:,.0f}",
                text_color=self.muted(),
                font=ctk.CTkFont(family=self.ui_font_family,size=8, overstrike=True)
            ).pack(side="right", padx=(0, 3))
        ctk.CTkLabel(
            total_box, text=self.t(f"{item['total']:,.0f} د.ج"),
            text_color=self.colors["secondary"], font=ctk.CTkFont(family=self.ui_font_family,size=10, weight="bold")
        ).pack(side="right")
        return card

    def _cart_pack_row(self, index, item):
        card = ctk.CTkFrame(
            self.cart_container, fg_color=self.colors.get("pack_bg", self.bg()),
            corner_radius=10, border_width=1, border_color=self.colors["primary"]
        )
        card.pack(fill="x", pady=3)

        top = ctk.CTkFrame(card, fg_color="transparent")
        top.pack(fill="x", padx=10, pady=(8, 3))
        ctk.CTkLabel(
            top, text=f"🎁 {item['name']}", text_color=self.colors["primary"], anchor="w",
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="left", fill="x", expand=True)
        ctk.CTkButton(
            top, text="×", width=24, height=24, corner_radius=6,
            fg_color="transparent", hover_color=self.colors["danger"],
            text_color=self.colors["danger"],
            command=lambda i=index: self.remove_from_cart(i)
        ).pack(side="right")

        comps = item.get("components") or []
        if comps:
            sub = ", ".join(
                f"{c.get('name')} × {self._format_quantity(c.get('unit_qty', 0), 'قطعة')}"
                for c in comps
            )
            ctk.CTkLabel(
                card, text=self.t(f"يحتوي: {sub}"), text_color=self.muted(), anchor="w",
                font=ctk.CTkFont(family=self.ui_font_family, size=8)
            ).pack(fill="x", padx=10, pady=(0, 2))

        bottom = ctk.CTkFrame(card, fg_color="transparent")
        bottom.pack(fill="x", padx=10, pady=(0, 8))
        qty = ctk.CTkFrame(bottom, fg_color="transparent")
        qty.pack(side="left")
        ctk.CTkButton(
            qty, text="−", width=25, height=25, corner_radius=6,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            command=lambda i=index: self.update_cart_quantity(i, -1)
        ).pack(side="left", padx=1)
        ctk.CTkLabel(
            qty, text=self.t(f"×{self._format_quantity(item['quantity'], 'باقة')}"), width=52,
            text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="left")
        ctk.CTkButton(
            qty, text="+", width=25, height=25, corner_radius=6,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            command=lambda i=index: self.update_cart_quantity(i, 1)
        ).pack(side="left", padx=1)
        ctk.CTkLabel(
            bottom, text=self.t(f"{item['price']:,.2f} د.ج / بـاقة"),
            text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=8)
        ).pack(side="left", padx=8)
        ctk.CTkLabel(
            bottom, text=self.t(f"{item['total']:,.0f} د.ج"),
            text_color=self.colors["primary"], font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="right")
        return card

    def _update_pack_quantity(self, index, change):
        """زيادة/إنقاص عدد الباقات في السلة مع إعادة التحقق من مخزون كل مكون."""
        item = self.cart[index]
        step = 1.0
        new_qty = round(float(item["quantity"]) + step * change, 6)
        if new_qty <= 0:
            self.remove_from_cart(index)
            return
        if change > 0:
            ok, msg = self._validate_pack_in_cart(item.get("components") or [], new_qty)
            if not ok:
                self.toast(msg, "danger")
                return
        item["quantity"] = new_qty
        item["total"] = float(item["price"]) * new_qty
        self.update_cart_display()

    def update_cart_quantity(self, index, change):
        if index < 0 or index >= len(self.cart):
            return
        item = self.cart[index]
        if item.get("is_pack"):
            self._update_pack_quantity(index, change)
            return
        try:
            product = self.product_manager.get_product_by_id(item["id"])
            max_qty = float(product[5]) if product else None
            unit = str(product[6] or item.get("unit", self.t("قطعة"))) if product else item.get("unit", self.t("قطعة"))
        except Exception:
            max_qty = None
            unit = item.get("unit", self.t("قطعة"))
        step = self._quantity_step(unit)
        new_qty = round(float(item["quantity"]) + step * change, 6)
        if new_qty <= 0:
            self.remove_from_cart(index)
            return
        if item.get("variant_id"):
            # متغير مقاس/لون: السقف من مخزون المتغير مباشرة وليس مخزون المنتج الأب.
            cur_variant = None
            try:
                conn = self.db.get_connection()
                try:
                    cur_variant = conn.execute(
                        "SELECT quantity FROM product_variants WHERE id = ?", (item["variant_id"],)
                    ).fetchone()
                finally:
                    conn.close()
            except Exception:
                cur_variant = None
            if cur_variant is not None:
                try:
                    variant_stock = float(cur_variant[0] or 0)
                except Exception:
                    variant_stock = 0.0
                if new_qty > variant_stock + 1e-9:
                    self.toast(f"وصلت للكمية القصوى المتوفرة من هذا المقاس ({variant_stock:g})", "warning")
                    return
            elif max_qty is not None and new_qty > max_qty + 1e-9:
                self.toast("لا توجد كمية إضافية في المخزون", "warning")
                return
        elif max_qty is not None and new_qty > max_qty + 1e-9:
            self.toast("لا توجد كمية إضافية في المخزون", "warning")
            return
        item["quantity"] = new_qty
        item["unit"] = unit
        item["total"] = max(0.0, float(item["price"]) * new_qty - float(item.get("item_discount", 0.0) or 0.0))
        self.update_cart_display()

    def remove_from_cart(self, index):
        if 0 <= index < len(self.cart):
            self.cart.pop(index)
            self.update_cart_display()

    def clear_cart(self):
        if not self.cart:
            return
        if self.confirm("مسح السلة", "هل تريد مسح جميع المنتجات من السلة؟"):
            self.cart.clear()
            self.sale_discount = 0.0
            self.update_cart_display()
            self.toast("تم مسح السلة")

    def complete_sale(self):
        """شاشة دفع متقدمة: نقدي، بطاقة، دفع جزئي، ودين كامل."""
        if not self.cart:
            self.toast("السلة فارغة", "danger")
            return

        pay_window = ctk.CTkToplevel(self)
        pay_window.title(self.t("إتمام البيع"))
        pay_window.geometry("560x650")
        pay_window.minsize(520, 600)
        pay_window.resizable(False, False)
        pay_window.transient(self)
        pay_window.grab_set()
        self.center_window(pay_window, 560, 650)

        container = ctk.CTkFrame(pay_window, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=22, pady=22)

        ctk.CTkLabel(
            container, text=self.t("إتمام البيع"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=22, weight="bold")
        ).pack(anchor="w")

        ctk.CTkLabel(
            container, text=self.t("اختر طريقة الدفع ثم أكد العملية"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", pady=(2, 14))

        total_card = self.make_card(container)
        total_card.pack(fill="x", pady=(0, 12))

        ctk.CTkLabel(
            total_card, text=self.t("إجمالي الفاتورة"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", padx=15, pady=(12, 1))

        ctk.CTkLabel(
            total_card, text=self.t(f"{self.total:,.2f} د.ج"),
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=25, weight="bold")
        ).pack(anchor="w", padx=15, pady=(0, 12))

        method_frame = ctk.CTkFrame(container, fg_color="transparent")
        method_frame.pack(fill="x", pady=(0, 10))

        ctk.CTkLabel(
            method_frame, text=self.t("طريقة الدفع"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(anchor="w", pady=(0, 7))

        selected_method = {"value": "cash"}

        methods = [
            ("cash", self.t("نقدي")),
            ("card", self.t("بطاقة")),
            ("partial", self.t("دفع جزئي")),
            ("credit", self.t("دين كامل")),
        ]

        method_buttons = {}

        buttons_row = ctk.CTkFrame(method_frame, fg_color="transparent")
        buttons_row.pack(fill="x")

        for key, label in methods:
            btn = ctk.CTkButton(
                buttons_row, text=label, height=38, corner_radius=8,
                fg_color=self.colors["primary"] if key == "cash" else self.card(),
                hover_color=self.colors["primary_hover"] if key == "cash" else self.border(),
                text_color="white" if key == "cash" else self.text(),
                border_width=0 if key == "cash" else 1,
                border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            )
            btn.pack(side="left", fill="x", expand=True, padx=2)
            method_buttons[key] = btn

        paid_card = self.make_card(container)
        paid_card.pack(fill="x", pady=(0, 10))

        ctk.CTkLabel(
            paid_card, text=self.t("المبلغ المدفوع"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", padx=13, pady=(10, 3))

        paid_entry = ctk.CTkEntry(
            paid_card, height=42, corner_radius=9,
            fg_color=self.bg(), border_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")
        )
        paid_entry.pack(fill="x", padx=13, pady=(0, 10))

        customer_card = self.make_card(container)
        customer_card.pack(fill="x", pady=(0, 10))

        customer_title = ctk.CTkFrame(customer_card, fg_color="transparent")
        customer_title.pack(fill="x", padx=13, pady=(10, 6))

        ctk.CTkLabel(
            customer_title, text=self.t("العميل"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(side="left")

        customer_name_var = ctk.StringVar(
            value=(str(self.selected_customer[1]) if self.selected_customer else self.t("عميل نقدي"))
        )

        customer_label = ctk.CTkLabel(
            customer_title, textvariable=customer_name_var,
            text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        )
        customer_label.pack(side="right")

        def choose_customer():
            dialog = ctk.CTkInputDialog(
                text=self.t("اكتب اسم العميل أو رقم الهاتف:"),
                title=self.t("اختيار العميل")
            )
            query = dialog.get_input()
            if not query:
                return

            try:
                customers = self.customer_manager.search_customer(query)
            except Exception:
                customers = []

            if not customers:
                self.toast("العميل غير موجود", "danger")
                return

            self.selected_customer = customers[0]
            customer_name_var.set(str(customers[0][1]))
            update_summary()

        ctk.CTkButton(
            customer_card, text=self.t("اختيار / تغيير العميل"),
            command=choose_customer, height=34, corner_radius=8,
            fg_color=self.bg(), hover_color=self.border(),
            text_color=self.text(), border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(fill="x", padx=13, pady=(0, 10))

        summary = self.make_card(container)
        summary.pack(fill="x", pady=(0, 12))

        summary_vars = {
            "change": ctk.StringVar(value=self.t("0.00 د.ج")),
            "debt": ctk.StringVar(value=self.t("0.00 د.ج")),
            "new_balance": ctk.StringVar(value=self.t("0.00 د.ج")),
        }

        for label, key in [
            (self.t("الباقي"), "change"),
            (self.t("دين هذه الفاتورة"), "debt"),
            (self.t("رصيد العميل بعد العملية"), "new_balance"),
        ]:
            row = ctk.CTkFrame(summary, fg_color="transparent")
            row.pack(fill="x", padx=13, pady=3)
            ctk.CTkLabel(
                row, text=label, text_color=self.muted(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(side="left")
            ctk.CTkLabel(
                row, textvariable=summary_vars[key],
                text_color=self.text(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            ).pack(side="right")

        def current_paid():
            key = selected_method["value"]
            if key == "credit":
                return 0.0
            try:
                return float(paid_entry.get() or 0)
            except ValueError:
                return None

        def update_summary(*_):
            key = selected_method["value"]

            if key == "cash" or key == "card":
                if not paid_entry.get().strip():
                    paid_entry.delete(0, "end")
                    paid_entry.insert(0, f"{self.total:.2f}")

            if key == "credit":
                paid_entry.delete(0, "end")
                paid_entry.insert(0, "0")
                paid_entry.configure(state="disabled")
            else:
                paid_entry.configure(state="normal")

            paid = current_paid()
            if paid is None:
                summary_vars["change"].set("—")
                summary_vars["debt"].set("—")
                summary_vars["new_balance"].set("—")
                return

            debt = max(0.0, self.total - paid)
            change = max(0.0, paid - self.total)

            existing = 0.0
            if self.selected_customer:
                try:
                    existing = float(self.selected_customer[3] or 0)
                except Exception:
                    existing = 0.0

            summary_vars["change"].set(self.t(f"{change:,.2f} د.ج"))
            summary_vars["debt"].set(self.t(f"{debt:,.2f} د.ج"))
            summary_vars["new_balance"].set(
                self.t(f"{existing + debt:,.2f} د.ج")
                if self.selected_customer else "—"
            )

        def set_method(key):
            selected_method["value"] = key

            for method_key, btn in method_buttons.items():
                active = method_key == key
                btn.configure(
                    fg_color=self.colors["primary"] if active else self.card(),
                    hover_color=self.colors["primary_hover"] if active else self.border(),
                    text_color="white" if active else self.text(),
                    border_width=0 if active else 1
                )

            if key == "cash" or key == "card":
                paid_entry.configure(state="normal")
                paid_entry.delete(0, "end")
                paid_entry.insert(0, f"{self.total:.2f}")
            elif key == "partial":
                paid_entry.configure(state="normal")
                paid_entry.delete(0, "end")
                paid_entry.focus_set()
            else:
                paid_entry.configure(state="normal")
                paid_entry.delete(0, "end")
                paid_entry.insert(0, "0")
                paid_entry.configure(state="disabled")

            update_summary()

        for key, btn in method_buttons.items():
            btn.configure(command=lambda k=key: set_method(k))

        paid_entry.bind("<KeyRelease>", update_summary)

        def confirm_payment():
            key = selected_method["value"]

            if key == "credit" and not self.selected_customer:
                self.toast("الدين الكامل يتطلب اختيار عميل", "danger")
                return

            paid = current_paid()
            if paid is None:
                self.toast("أدخل مبلغًا صحيحًا", "danger")
                return

            if paid < 0:
                self.toast("المبلغ لا يمكن أن يكون سالبًا", "danger")
                return

            if key in ("cash", "card") and paid < self.total:
                self.toast("استخدم دفعًا جزئيًا إذا كان المبلغ أقل من الإجمالي", "danger")
                return

            if key == "partial" and paid >= self.total:
                self.toast("للدفع الكامل اختر نقدي أو بطاقة", "danger")
                return

            if key == "credit":
                paid = 0.0

            debt = max(0.0, self.total - paid)
            change = max(0.0, paid - self.total)

            if debt > 0 and not self.settings.get("allow_debt", True):
                self.toast("تسجيل الدين معطل من الإعدادات", "danger")
                return

            if debt > 0 and not self.selected_customer:
                self.toast("يجب اختيار عميل لتسجيل الدين", "danger")
                return

            customer_id = self.selected_customer[0] if self.selected_customer else 0

            # التحقق المسبق من مخزون كل مكوّن باقات السلة قبل إنشاء الفاتورة.
            for it in self.cart:
                if it.get("is_pack"):
                    ok, msg = self._validate_pack_in_cart(it.get("components") or [], float(it["quantity"]))
                    if not ok:
                        self.toast(msg, "danger")
                        return

            items = []
            for item in self.cart:
                base = {
                    "product_id": item["id"],
                    "quantity": item["quantity"],
                    "price": item["price"]
                }
                if item.get("variant_id"):
                    base["variant_id"] = item["variant_id"]
                if item.get("is_pack"):
                    base["is_pack"] = True
                    base["pack_id"] = item.get("pack_id")
                    base["components"] = item.get("components") or []
                items.append(base)

            # الخصم الكلي = خصم الفاتورة + مجموع خصومات المنتجات،
            # بحيث تعكس الفاتورة المسجلة المبلغ المحصّل فعليًا.
            items_discount_total = sum(
                float(it.get("item_discount", 0.0) or 0.0) for it in self.cart
            )
            invoice_discount = float(getattr(self, "sale_discount", 0.0) or 0.0) + items_discount_total

            try:
                # create_invoice موجود أصلًا ويستقبل customer_id/items/discount/paid/device_name.
                success, invoice, total, backend_change = self.sales_manager.create_invoice(
                    customer_id, items, invoice_discount, paid, device_name=self._get_device_name()
                )
            except Exception as exc:
                self.toast(f"فشل إنشاء الفاتورة: {exc}", "danger")
                return

            if not success:
                # رسالة قصيرة قابلة للتنفيذ للكاشير + تسجيل التفاصيل التقنية
                # الكاملة في سجل النشاطات للتدقيق (دون عرض تتبع إنجليزي خام).
                reason = getattr(self.sales_manager, "last_error", "") or ""
                tech = getattr(self.sales_manager, "last_error_raw", "") or ""
                if tech:
                    self.log_action(
                        "sale_failed", "invoice", None,
                        f"{invoice if invoice else 'وضع المبيعات'} • {tech}"
                    )
                self.toast(f"فشلت عملية البيع: {reason}", "danger")
                return

            # حفظ تكلفة المنتجات وقت البيع لحساب الربح بدقة لاحقًا.
            self._capture_sale_costs(invoice)

            # حفظ خصم كل منتج في sale_items حتى لا يُفقد بعد إنشاء الفاتورة.
            self._persist_item_discounts(invoice, self.cart)

            # تسجيل عملية البيع في سجل النشاطات.
            self.log_action(
                "sale_completed", "invoice", None,
                f"{invoice} • الإجمالي {float(total or 0):,.2f} دج"
            )

            # حفظ العملية في سجل الديون إذا كان جزء من الفاتورة بقي دينًا.
            if customer_id > 0 and debt > 0:
                history_ok, history_msg = self.debt_manager.record_debt(
                    customer_id, debt, note="بيع بالدين", reference=invoice
                )
                if not history_ok:
                    self.toast(f"تم البيع، لكن تعذر حفظ سجل الدين: {history_msg}", "warning")

            pay_window.destroy()
            self.cart = []
            self.selected_customer = None
            self.update_cart_display()
            self.show_pos()

            # الطباعة بعد البيع حسب الإعدادات.
            if self.settings.get("ask_before_print", True):
                try:
                    should_print = messagebox.askyesno(
                        self.t("طباعة الفاتورة"),
                        self.t(f"تمت عملية البيع بنجاح.\nهل تريد طباعة الفاتورة الآن؟\n\nرقم الفاتورة: {invoice}"),
                        parent=self
                    )
                except Exception:
                    should_print = False
            else:
                should_print = True

            if should_print:
                paper = self.settings.get("default_paper", "80mm")
                if paper == "A4":
                    if self.get_auto_print_invoice():
                        self.print_invoice_a4(invoice, direct=True)
                else:
                    if self.get_auto_print_invoice():
                        self.print_invoice_80mm(invoice, direct=True)

            if debt > 0:
                self.toast(
                    f"تم البيع. الدين المسجل: {debt:,.2f} د.ج",
                    "warning"
                )
            elif change > 0:
                self.toast(
                    f"تم البيع. الباقي: {change:,.2f} د.ج"
                )
            else:
                self.toast("تمت عملية البيع بنجاح")

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", side="bottom")

        ctk.CTkButton(
            buttons, text=self.t("تأكيد البيع"),
            command=confirm_payment,
            height=44, corner_radius=9,
            fg_color=self.colors["secondary"],
            hover_color=self.colors["secondary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            buttons, text=self.t("إلغاء"), command=pay_window.destroy,
            height=44, corner_radius=9,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(), border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        set_method("cash")
        paid_entry.focus_set()

    def show_b2b(self):
        """صفحة B2B — عملاء الشركات. تُدار بالكامل من gui/b2b/ (منطقتان منفصلتان)."""
        if not self._guard_db_nav("B2B", "إدارة عملاء B2B", "b2b"):
            return
        self.clear_content()
        self.current_page = "b2b"
        self.highlight_nav()
        try:
            from gui.b2b.b2b_page import B2BCustomersPage
            self.b2b_page = B2BCustomersPage(self)
            self.b2b_page.render(self.content_area)
        except Exception as exc:
            self.empty_state(
                self.content_area, "⚠", "تعذر فتح صفحة B2B", str(exc), self.show_b2b
            )

    def show_b2b_documents(self):
        """صفحة مستندات B2B — بروفورما / فواتير متسلسلة الأرقام.

        تُدار بالكامل من gui/b2b/document_list.py؛ الحد الأدنى هنا
        (حارس + تنظيف + تركيب) تمامًا مثل show_b2b.
        """
        if not self._guard_db_nav("مستندات B2B", "وثائق تجارية", "b2b_documents"):
            return
        self.clear_content()
        self.current_page = "b2b_documents"
        self.highlight_nav()
        try:
            from gui.b2b.document_list import B2BDocumentsPage
            self.b2b_documents_page = B2BDocumentsPage(self)
            self.b2b_documents_page.render(self.content_area)
        except Exception as exc:
            self.empty_state(
                self.content_area, "⚠", "تعذر تحميل المستندات", str(exc), self.show_b2b_documents
            )

# يوم 5 — صفحة الديون المستحقة على B2B
    def show_b2b_debts(self):
        """صفحة ديون/مستحقات B2B — فواتير قيد السداد والمتأخرات."""
        if not self._guard_db_nav("ديون B2B", "المستحقات والمتأخرات", "b2b_debts"):
            return
        self.clear_content()
        self.current_page = "b2b_debts"
        self.highlight_nav()
        try:
            from gui.b2b.debt_view import B2BDebtsPage
            self.b2b_debts_page = B2BDebtsPage(self)
            self.b2b_debts_page.render(self.content_area)
        except Exception as exc:
            self.empty_state(
                self.content_area, "⚠", "تعذر تحميل صفحة الديون", str(exc), self.show_b2b_debts
            )

    # يوم 6 — صفحة تحليلات B2B
    def show_b2b_analytics(self):
        """صفحة مؤشرات/تحليلات B2B — إحصاءات المستندات والدفعات والديون."""
        if not self._guard_db_nav("تحليلات B2B", "المؤشرات والتقارير", "b2b_analytics"):
            return
        self.clear_content()
        self.current_page = "b2b_analytics"
        self.highlight_nav()
        try:
            from gui.b2b.analytics_page import B2BAnalyticsPage
            self.b2b_analytics_page = B2BAnalyticsPage(self)
            self.b2b_analytics_page.render(self.content_area)
        except Exception as exc:
            self.empty_state(
                self.content_area, "⚠", "تعذر فتح تحليلات B2B", str(exc), self.show_b2b_analytics
            )

    # يوم 5 — صفحة إعدادات B2B
    def show_b2b_settings(self):
        """صفحة إعدادات B2B — بيانات الشركة، الطابع، TVA، القوالب، الشعار."""
        if not self._guard_db_nav("إعدادات B2B", "إعدادات المستندات والشركة", "b2b_settings"):
            return
        self.clear_content()
        self.current_page = "b2b_settings"
        self.highlight_nav()
        try:
            from gui.b2b.b2b_settings_page import B2BSettingsPage
            self.b2b_settings_page = B2BSettingsPage(self)
            self.b2b_settings_page.render(self.content_area)
        except Exception as exc:
            self.empty_state(
                self.content_area, "⚠", "تعذر فتح إعدادات B2B", str(exc), self.show_b2b_settings
            )

    def show_customers(self):
        """صفحة العملاء: بحث سريع، ملخص الديون، وبطاقات العملاء."""
        if not self._guard_db_nav("العملاء", "إدارة العملاء والديون", "customers"):
            return
        self.clear_content()
        self.current_page = "customers"
        self.highlight_nav()

        self.page_header(
            "العملاء",
            "إدارة العملاء والديون والمدفوعات"
        )

        try:
            all_customers = self.customer_manager.get_all_customers()
        except Exception:
            all_customers = []

        total_customers = len(all_customers)
        customers_with_debt = 0
        total_debt = 0.0

        for customer in all_customers:
            try:
                balance = float(customer[3] or 0)
            except Exception:
                balance = 0.0
            if balance > 0:
                customers_with_debt += 1
                total_debt += balance

        summary = ctk.CTkFrame(self.content_area, fg_color="transparent")
        summary.pack(fill="x", pady=(0, 12))

        summary_items = [
            (self.t("العملاء"), f"{total_customers}", self.colors["primary"]),
            (self.t("عليهم ديون"), f"{customers_with_debt}", self.colors["danger"]),
            (self.t("إجمالي الديون"), self.t(f"{total_debt:,.2f} د.ج"), self.colors["accent"]),
        ]

        for i, (label, value, color) in enumerate(summary_items):
            card = self.make_card(summary)
            card.grid(row=0, column=i, sticky="nsew", padx=(0 if i == 0 else 6, 0))
            summary.grid_columnconfigure(i, weight=1)

            ctk.CTkLabel(
                card, text=label, text_color=self.muted(),
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(anchor="w", padx=14, pady=(10, 2))

            ctk.CTkLabel(
                card, text=value, text_color=color,
                font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold")
            ).pack(anchor="w", padx=14, pady=(0, 10))

        # =========================================================
        # زر تسديد الدين الرئيسي — واضح دائمًا في صفحة العملاء
        # =========================================================
        debt_action = ctk.CTkFrame(
            self.content_area,
            fg_color=self.card(),
            corner_radius=12,
            border_width=1,
            border_color=self.colors["accent"]
        )
        debt_action.pack(fill="x", pady=(0, 10))

        debt_info = ctk.CTkFrame(debt_action, fg_color="transparent")
        debt_info.pack(side="left", fill="x", expand=True, padx=16, pady=10)

        ctk.CTkLabel(
            debt_info,
            text=self.t("💰 تسديد ديون العملاء"),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
        ).pack(anchor="w")

        ctk.CTkLabel(
            debt_info,
            text=self.t(f"إجمالي الديون المستحقة: {total_debt:,.2f} د.ج  •  العملاء المدينون: {customers_with_debt}"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", pady=(3, 0))

        ctk.CTkButton(
            debt_action,
            text=self.t("تسديد دين  ←"),
            command=self.open_debt_payment_selector,
            height=42,
            width=150,
            corner_radius=9,
            fg_color=self.colors["accent"],
            hover_color=self.colors["accent_hover"],
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="right", padx=14, pady=10)

        toolbar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        toolbar.pack(fill="x", pady=(0, 10))

        search_box = self.make_card(toolbar)
        search_box.pack(side="left", fill="x", expand=True, padx=(0, 8))

        ctk.CTkLabel(
            search_box, text="⌕", text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold")
        ).pack(side="left", padx=(12, 5))

        self.customer_search = ctk.CTkEntry(
            search_box, placeholder_text=self.t("ابحث باسم العميل أو الهاتف..."),
            height=40, fg_color="transparent", border_width=0,
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        )
        self.customer_search.pack(side="left", fill="x", expand=True, padx=4)
        self.customer_search.bind("<KeyRelease>", self.filter_customers)

        ctk.CTkButton(
            toolbar, text=self.t("إضافة عميل"),
            command=self.show_add_customer_form,
            height=40, width=120, corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        ).pack(side="right", padx=4)

        ctk.CTkButton(
            toolbar, text=self.t("تحديث"), command=self.show_customers,
            height=40, width=85, corner_radius=9,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(), border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(side="right")

        ctk.CTkButton(
            toolbar, text=self.t("تسديد دين"),
            command=self.open_debt_payment_selector,
            height=40, width=120, corner_radius=9,
            fg_color=self.colors["accent"],
            hover_color=self.colors["accent_hover"],
            text_color="white",
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10, weight="bold"
            )
        ).pack(side="right", padx=4)

        self.customers_container = ctk.CTkScrollableFrame(
            self.content_area,
            fg_color="transparent",
            corner_radius=0
        )
        self.customers_container.pack(fill="both", expand=True, pady=(2, 0))

        # نؤجل الرسم إلى دورة Tk التالية حتى تكون أبعاد الحاوية
        # قد حُسبت بالكامل، خصوصًا مع CTkScrollableFrame.
        self.after(20, self.render_customers)

    def render_customers(self, search_term=""):
        if not hasattr(self, "customers_container") or not self.customers_container.winfo_exists():
            return

        for widget in self.customers_container.winfo_children():
            widget.destroy()

        try:
            customers = self.customer_manager.get_all_customers()
        except Exception as exc:
            self.empty_state(
                self.customers_container, "", "تعذر تحميل العملاء",
                str(exc), self.show_customers
            )
            return

        term = search_term.strip().lower()
        if term:
            customers = [
                c for c in customers
                if term in str(c[1]).lower()
                or term in str(c[2] or "").lower()
            ]

        if not customers:
            self.empty_state(
                self.customers_container, "", "لا يوجد عملاء",
                "جرّب تغيير البحث أو أضف عميلًا جديدًا",
                self.show_add_customer_form
            )
            return

        header = ctk.CTkFrame(
            self.customers_container, fg_color=self.card(),
            corner_radius=10, border_width=1, border_color=self.border()
        )
        header.pack(fill="x", pady=(0, 5))

        for label in (self.t("العميل"), self.t("الهاتف"), self.t("الرصيد"), self.t("الحالة"), self.t("الإجراءات")):
            ctk.CTkLabel(
                header, text=label, text_color=self.muted(),
                font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
            ).pack(side="left", fill="x", expand=True, padx=8, pady=9)

        for customer in customers:
            try:
                balance = float(customer[3] or 0)
            except Exception:
                balance = 0.0

            row = ctk.CTkFrame(
                self.customers_container, fg_color=self.card(),
                corner_radius=10, border_width=1, border_color=self.border()
            )
            row.pack(fill="x", pady=3)

            identity = ctk.CTkFrame(row, fg_color="transparent")
            identity.pack(side="left", fill="x", expand=True, padx=8, pady=8)

            initials = "".join(
                part[0] for part in str(customer[1]).split() if part
            )[:2].upper() or "C"

            avatar = ctk.CTkFrame(
                identity, width=34, height=34, corner_radius=10,
                fg_color=self.colors["primary"]
            )
            avatar.pack(side="left", padx=(0, 8))
            avatar.pack_propagate(False)

            ctk.CTkLabel(
                avatar, text=initials, text_color="white",
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            ).place(relx=0.5, rely=0.5, anchor="center")

            ctk.CTkLabel(
                identity, text=str(customer[1]), text_color=self.text(),
                anchor="w",
                font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
            ).pack(side="left", fill="x", expand=True)

            ctk.CTkLabel(
                row, text=str(customer[2] or "—"), text_color=self.muted(),
                width=120,
                font=ctk.CTkFont(family=self.ui_font_family, size=9)
            ).pack(side="left", padx=8)

            debt_color = self.colors["danger"] if balance > 0 else self.colors["secondary"]
            debt_text = self.t(f"{balance:,.2f} د.ج") if balance > 0 else self.t("0.00 د.ج")

            ctk.CTkLabel(
                row, text=debt_text, text_color=debt_color, width=120,
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            ).pack(side="left", padx=8)

            ctk.CTkLabel(
                row, text=self.t("عليه دين") if balance > 0 else self.t("مسدد"),
                text_color=debt_color, width=80,
                font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
            ).pack(side="left", padx=4)

            # زر التسديد مباشرة داخل صف العميل.
            # لا نضعه داخل إطار فرعي حتى لا يختفي بسبب أحجام/اتجاه RTL.
            ctk.CTkButton(
                row, text=self.t("تسديد الدين"),
                command=lambda cid=customer[0]: self.pay_debt(cid),
                width=105, height=32, corner_radius=8,
                fg_color=self.colors["accent"],
                hover_color=self.colors["accent_hover"],
                text_color="white",
                font=ctk.CTkFont(
                    family=self.ui_font_family, size=9, weight="bold"
                )
            ).pack(side="right", padx=8, pady=7)

            if balance > 0:
                ctk.CTkButton(
                    row, text=self.t("تسديد"), command=lambda c=customer: self.pay_debt(c),
                    height=30, width=75, corner_radius=7,
                    fg_color=self.colors["accent"],
                    hover_color=self.colors["accent_hover"],
                    text_color="white",
                    font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
                ).pack(side="right", padx=3)

            ctk.CTkButton(
                row, text=self.t("عرض"),
                command=lambda c=customer: self.show_customer_details(c),
                width=58, height=32, corner_radius=8,
                fg_color=self.bg(), hover_color=self.border(),
                text_color=self.text(),
                border_width=1, border_color=self.border(),
                font=ctk.CTkFont(
                    family=self.ui_font_family, size=9, weight="bold"
                )
            ).pack(side="right", padx=(0, 4), pady=7)

    def filter_customers(self, event=None):
        if hasattr(self, "customer_search_after_id") and self.customer_search_after_id:
            try:
                self.after_cancel(self.customer_search_after_id)
            except Exception:
                pass

        term = self.customer_search.get().strip()

        def run():
            self.customer_search_after_id = None
            self.render_customers(term)

        self.customer_search_after_id = self.after(120, run)

    def show_customer_details(self, customer):
        """تفاصيل العميل مع الرصيد الحالي وإجراء سريع للتسديد."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("تفاصيل العميل"))
        win.geometry("500x430")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 500, 430)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        identity = ctk.CTkFrame(container, fg_color="transparent")
        identity.pack(fill="x", pady=(2, 15))

        initials = "".join(
            part[0] for part in str(customer[1]).split() if part
        )[:2].upper() or "C"

        avatar = ctk.CTkFrame(
            identity, width=56, height=56, corner_radius=16,
            fg_color=self.colors["primary"]
        )
        avatar.pack(side="left", padx=(0, 12))
        avatar.pack_propagate(False)

        ctk.CTkLabel(
            avatar, text=initials, text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold")
        ).place(relx=0.5, rely=0.5, anchor="center")

        info = ctk.CTkFrame(identity, fg_color="transparent")
        info.pack(side="left", fill="x", expand=True)

        ctk.CTkLabel(
            info, text=str(customer[1]), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold")
        ).pack(anchor="w")

        ctk.CTkLabel(
            info, text=self.t(f"الهاتف: {customer[2] or 'غير مسجل'}"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", pady=(3, 0))

        try:
            balance = float(customer[3] or 0)
        except Exception:
            balance = 0.0

        balance_card = self.make_card(container)
        balance_card.pack(fill="x", pady=5)

        ctk.CTkLabel(
            balance_card, text=self.t("الرصيد المستحق"), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", padx=14, pady=(12, 2))

        ctk.CTkLabel(
            balance_card, text=self.t(f"{balance:,.2f} د.ج"),
            text_color=self.colors["danger"] if balance > 0 else self.colors["secondary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=24, weight="bold")
        ).pack(anchor="w", padx=14, pady=(0, 12))

        ctk.CTkLabel(
            container,
            text=(self.t("يمكن تسجيل دفعة مباشرة من هنا.")
                  if balance > 0 else self.t("لا يوجد دين حالي على هذا العميل.")),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(anchor="w", pady=(12, 10))

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", pady=(12, 0))

        # زر التسديد يكون ظاهرًا دائمًا داخل تفاصيل العميل.
        ctk.CTkButton(
            buttons, text=self.t("تسديد الدين"),
            command=lambda cid=customer[0]: (win.destroy(), self.pay_debt(cid)),
            height=42, corner_radius=9,
            fg_color=self.colors["accent"] if balance > 0 else self.card(),
            hover_color=self.colors["accent_hover"] if balance > 0 else self.border(),
            text_color="white" if balance > 0 else self.muted(),
            border_width=0 if balance > 0 else 1,
            border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10, weight="bold"
            )
        ).pack(fill="x", pady=(0, 8))

        ctk.CTkButton(
            buttons, text=self.t("سجل الديون والمدفوعات"),
            command=lambda cid=customer[0]: self.show_debt_history(cid),
            height=38, corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        ).pack(fill="x", pady=(0, 8))

        lower_buttons = ctk.CTkFrame(buttons, fg_color="transparent")
        lower_buttons.pack(fill="x")

        ctk.CTkButton(
            lower_buttons, text=self.t("اختيار في نقطة البيع"),
            command=lambda: self._select_customer_from_details(customer, win),
            height=38, corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(
                family=self.ui_font_family, size=9, weight="bold"
            )
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            lower_buttons, text=self.t("إغلاق"), command=win.destroy,
            height=38, corner_radius=9,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(), border_width=1, border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=9
            )
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

    def show_debt_history(self, customer_id):
        """عرض سجل الديون والمدفوعات مع إمكانية فتح الفاتورة المرتبطة."""
        try:
            customer = self.customer_manager.get_customer_by_id(customer_id)
            history = self.debt_manager.get_customer_history(customer_id)
            total_debt, total_paid = self.debt_manager.get_customer_totals(customer_id)
        except Exception as exc:
            self.toast(f"تعذر تحميل سجل الديون: {exc}", "danger")
            return

        if not customer:
            self.toast("العميل غير موجود", "danger")
            return

        try:
            current_balance = float(customer[4] or 0)
        except (TypeError, ValueError):
            current_balance = 0.0

        win = ctk.CTkToplevel(self)
        win.title(self.t("سجل الديون والمدفوعات"))
        win.geometry("850x650")
        win.minsize(760, 560)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 850, 650)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        header = ctk.CTkFrame(container, fg_color="transparent")
        header.pack(fill="x", pady=(0, 12))
        ctk.CTkLabel(
            header, text=self.t("سجل الديون والمدفوعات"), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(side="left")
        ctk.CTkLabel(
            header, text=str(customer[1]), text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side="right", pady=5)

        stats = ctk.CTkFrame(container, fg_color="transparent")
        stats.pack(fill="x", pady=(0, 10))
        cards = [
            (self.t("إجمالي الديون المسجلة"), total_debt, self.colors["danger"]),
            (self.t("إجمالي المدفوعات المسجلة"), total_paid, self.colors["secondary"]),
            (self.t("الدين الحالي"), current_balance,
             self.colors["accent"] if current_balance > 0 else self.colors["secondary"]),
        ]
        for i, (label, value, color) in enumerate(cards):
            card = self.make_card(stats)
            card.grid(row=0, column=i, sticky="nsew", padx=(0 if i == 0 else 6, 0))
            stats.grid_columnconfigure(i, weight=1)
            ctk.CTkLabel(card, text=label, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=8)).pack(anchor="w", padx=12, pady=(10, 2))
            ctk.CTkLabel(card, text=self.t(f"{value:,.2f} د.ج"), text_color=color,
                         font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold")).pack(anchor="w", padx=12, pady=(0, 10))

        if not history:
            empty = self.make_card(container)
            empty.pack(fill="both", expand=True, pady=5)
            ctk.CTkLabel(empty, text=self.t("لا توجد عمليات مسجلة في سجل الديون بعد"), text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")).pack(pady=(55, 6))
            ctk.CTkLabel(empty, text=self.t("الرصيد الحالي محفوظ في حساب العميل. العمليات الجديدة ستظهر هنا تلقائيًا."),
                         text_color=self.muted(), font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack()
        else:
            list_frame = ctk.CTkScrollableFrame(container, fg_color="transparent")
            list_frame.pack(fill="both", expand=True, pady=5)

            header_row = self.make_card(list_frame)
            header_row.pack(fill="x", pady=(0, 5))
            for label in (self.t("التاريخ"), self.t("العملية"), self.t("المبلغ"), self.t("البيان"), self.t("المرجع")):
                ctk.CTkLabel(
                    header_row, text=label, text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
                ).pack(side="left", fill="x", expand=True, padx=7, pady=8)

            for tx in history:
                tx_type = tx[1]
                amount = float(tx[2] or 0)
                note = tx[3] or "—"
                reference = tx[4] or ""
                date_text = tx[5] or "—"
                is_payment = tx_type == "payment"

                row = self.make_card(list_frame)
                row.pack(fill="x", pady=2)

                ctk.CTkLabel(
                    row, text=date_text, text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=8)
                ).pack(side="left", fill="x", expand=True, padx=7, pady=9)

                ctk.CTkLabel(
                    row,
                    text=self.t("تسديد") if is_payment else self.t("دين / بيع"),
                    text_color=self.colors["secondary"] if is_payment else self.colors["danger"],
                    font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
                ).pack(side="left", fill="x", expand=True, padx=7, pady=9)

                ctk.CTkLabel(
                    row, text=self.t(f"{amount:,.2f} د.ج"),
                    text_color=self.colors["secondary"] if is_payment else self.colors["danger"],
                    font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
                ).pack(side="left", fill="x", expand=True, padx=7, pady=9)

                ctk.CTkLabel(
                    row, text=note, text_color=self.text(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=8)
                ).pack(side="left", fill="x", expand=True, padx=7, pady=9)

                # إذا كان المرجع رقم فاتورة، نجعله زرًا لفتح تفاصيل الفاتورة.
                if reference and str(reference).startswith("INV-"):
                    ctk.CTkButton(
                        row,
                        text=str(reference),
                        width=105,
                        height=28,
                        corner_radius=7,
                        fg_color=self.bg(),
                        hover_color=self.border(),
                        text_color=self.colors["primary"],
                        border_width=1,
                        border_color=self.border(),
                        command=lambda ref=str(reference): self.show_invoice_details(ref),
                        font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")
                    ).pack(side="left", fill="x", expand=True, padx=7, pady=6)
                else:
                    ctk.CTkLabel(
                        row, text=reference or "—", text_color=self.muted(),
                        font=ctk.CTkFont(family=self.ui_font_family, size=8)
                    ).pack(side="left", fill="x", expand=True, padx=7, pady=9)

        buttons = ctk.CTkFrame(container, fg_color="transparent")
        buttons.pack(fill="x", pady=(10, 0))

        if current_balance > 0:
            ctk.CTkButton(
                buttons,
                text=self.t("💰 تسديد المتبقي"),
                command=lambda cid=customer_id: (win.destroy(), self.pay_debt(cid)),
                height=40,
                corner_radius=8,
                fg_color=self.colors["accent"],
                hover_color=self.colors["accent_hover"],
                text_color="white",
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            ).pack(side="left", fill="x", expand=True, padx=(0, 5))

        ctk.CTkButton(
            buttons, text=self.t("إغلاق"), command=win.destroy, height=40, corner_radius=8,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(side="right", fill="x", expand=True, padx=(5, 0) if current_balance > 0 else (0, 0))

    def _invoice_pdf_font(self):
        """إرجاع خط مناسب للفاتورة، وسيتم تحسين دعم العربية بالكامل في مرحلة RTL لاحقًا."""
        import os
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont

        candidates = [
            ("InvoiceFont", "C:/Windows/Fonts/tahoma.ttf"),
            ("InvoiceFont", "C:/Windows/Fonts/arial.ttf"),
            ("InvoiceFont", "C:/Windows/Fonts/Arial.ttf"),
            ("InvoiceFont", "C:/Windows/Fonts/segoeui.ttf"),
            ("InvoiceFont", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        ]
        for name, path in candidates:
            if os.path.exists(path):
                try:
                    if name not in pdfmetrics.getRegisteredFontNames():
                        pdfmetrics.registerFont(TTFont(name, path))
                    return name
                except Exception:
                    pass
        return "Helvetica"

    def _create_invoice_pdf(self, invoice_number, paper="A4", auto_print=False, direct=False):
        """إنشاء فاتورة PDF بحجم A4 أو 80mm ثم فتحها/طباعتها على Windows."""
        import os
        from reportlab.lib import colors
        from reportlab.lib.enums import TA_RIGHT, TA_CENTER
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import mm
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, HRFlowable

        conn = self.db.get_connection()
        try:
            sale = conn.execute(
                """
                SELECT s.invoice_number, s.customer_id, s.total, s.discount,
                       s.paid_amount, s.change_amount, s.sale_date,
                       c.name
                FROM sales s
                LEFT JOIN customers c ON c.id = s.customer_id
                WHERE s.invoice_number = ?
                """,
                (invoice_number,)
            ).fetchone()

            if not sale:
                self.toast("الفاتورة غير موجودة", "danger")
                return None

            # نقرأ عمود خصم المنتج إن كان موجودًا (توافق مع قواعد بيانات قديمة)،
            # مع أعمدة الباقة (product_id, pack_id) لعرض الباقات بشكل مجمّع.
            try:
                items = conn.execute(
                    """
                    SELECT COALESCE(pk.name, p.name, 'منتج محذوف'), si.quantity, si.price, si.total,
                           COALESCE(si.item_discount, 0), si.product_id, si.pack_id
                    FROM sale_items si
                    LEFT JOIN products p ON p.id = si.product_id
                    LEFT JOIN packs pk ON pk.id = si.pack_id
                    WHERE si.sale_id = (
                        SELECT id FROM sales WHERE invoice_number = ?
                    )
                    ORDER BY si.id
                    """,
                    (invoice_number,)
                ).fetchall()
            except Exception:
                items = conn.execute(
                    """
                    SELECT COALESCE(pk.name, p.name, 'منتج محذوف'), si.quantity, si.price, si.total, 0,
                           si.product_id, si.pack_id
                    FROM sale_items si
                    LEFT JOIN products p ON p.id = si.product_id
                    LEFT JOIN packs pk ON pk.id = si.pack_id
                    WHERE si.sale_id = (
                        SELECT id FROM sales WHERE invoice_number = ?
                    )
                    ORDER BY si.id
                    """,
                    (invoice_number,)
                ).fetchall()
        finally:
            conn.close()

        # في الطباعة المباشرة لا نطلب من المستخدم اختيار مكان الحفظ.
        # ننشئ نسخة مؤقتة ثم نرسلها مباشرة إلى الطابعة الافتراضية في Windows.
        default_name = self.t(f"فاتورة_{invoice_number}_{'80mm' if paper == '80mm' else 'A4'}")
        if direct:
            temp_dir = os.path.join(tempfile.gettempdir(), "SupermarketPro")
            os.makedirs(temp_dir, exist_ok=True)
            path = os.path.join(temp_dir, default_name + ".pdf")
        else:
            path = filedialog.asksaveasfilename(
                title=self.t("حفظ الفاتورة"),
                defaultextension=".pdf",
                initialfile=default_name + ".pdf",
                filetypes=[("PDF", "*.pdf")]
            )
            if not path:
                return None

        font_name = self._invoice_pdf_font()

        def rtl(value):
            """Shape Arabic and apply bidi ordering for ReportLab."""
            value = "" if value is None else str(value)
            try:
                import arabic_reshaper
                from bidi.algorithm import get_display
            except ImportError as exc:
                raise ImportError(
                    self.t("لإنشاء PDF عربي صحيح ثبّت: python -m pip install reportlab arabic-reshaper python-bidi")
                ) from exc
            return get_display(arabic_reshaper.reshape(value))

        def money(value):
            return rtl(f"{float(value or 0):,.2f} دج")

        total = float(sale[2] or 0)
        discount = float(sale[3] or 0)
        paid = float(sale[4] or 0)
        change = float(sale[5] or 0)
        net = max(0.0, total - discount)
        remaining = max(0.0, net - paid)
        customer = sale[7] or self.t("عميل نقدي")
        store_name = self.settings.get("store_name", "Supermarket Pro") or "Supermarket Pro"
        store_phone = self.settings.get("store_phone", "")
        store_address = self.settings.get("store_address", "")
        invoice_footer = self.settings.get("invoice_footer", self.t("شكرًا لزيارتكم")) or self.t("شكرًا لزيارتكم")

        if paper == "80mm":
            # Typical thermal receipt width; height is allowed to grow.
            page_width = 80 * mm
            page_height = max(160 * mm, (125 + len(items) * 18) * mm)
            pagesize = (page_width, page_height)
            margins = (4 * mm, 4 * mm, 5 * mm, 5 * mm)
            content_width = page_width - margins[0] - margins[1]
            font_size = 9.0
            title_size = 15
        else:
            pagesize = A4
            margins = (13 * mm, 13 * mm, 12 * mm, 12 * mm)
            content_width = A4[0] - margins[0] - margins[1]
            font_size = 10.5
            title_size = 19

        doc = SimpleDocTemplate(
            path,
            pagesize=pagesize,
            rightMargin=margins[0],
            leftMargin=margins[1],
            topMargin=margins[2],
            bottomMargin=margins[3],
            title=self.t(f"فاتورة {invoice_number}"),
            author=store_name
        )

        styles = getSampleStyleSheet()
        title_style = ParagraphStyle(
            "InvoiceTitle", parent=styles["Title"],
            fontName=font_name, fontSize=title_size,
            leading=title_size + 3, alignment=TA_CENTER,
            textColor=colors.HexColor("#0F172A"), spaceAfter=3 * mm
        )
        meta_style = ParagraphStyle(
            "InvoiceMeta", parent=styles["Normal"],
            fontName=font_name, fontSize=font_size,
            leading=font_size + 4, alignment=TA_RIGHT,
            textColor=colors.HexColor("#475569")
        )
        cell_style = ParagraphStyle(
            "InvoiceCell", parent=styles["Normal"],
            fontName=font_name, fontSize=font_size,
            leading=font_size + 3, alignment=TA_RIGHT
        )
        center_style = ParagraphStyle(
            "InvoiceCenter", parent=cell_style, alignment=TA_CENTER
        )
        total_style = ParagraphStyle(
            "InvoiceTotal", parent=cell_style, fontSize=font_size,
            leading=font_size + 3
        )

        story = [
            Paragraph(rtl(store_name), title_style),
            Paragraph(rtl("فاتورة بيع"), ParagraphStyle(
                "InvoiceSub", parent=title_style, fontSize=font_size + 1,
                leading=font_size + 3, spaceAfter=1.5 * mm
            )),
            Paragraph(rtl(f"رقم الفاتورة: {invoice_number}"), meta_style),
            Paragraph(rtl(f"التاريخ: {sale[6] or '—'}"), meta_style),
            Paragraph(rtl(f"العميل: {customer}"), meta_style),
            *([Paragraph(rtl(f"الهاتف: {store_phone}"), meta_style)] if store_phone else []),
            *([Paragraph(rtl(f"العنوان: {store_address}"), meta_style)] if store_address else []),
            Spacer(1, 2 * mm),
            HRFlowable(width="100%", thickness=0.8, color=colors.HexColor("#CBD5E1")),
            Spacer(1, 3 * mm)
        ]

        # RTL visual order: product is on the right, numeric columns on the left.
        items_discount_sum = 0.0
        table_data = [[
            Paragraph(rtl("المجموع"), center_style),
            Paragraph(rtl("السعر"), center_style),
            Paragraph(rtl("الكمية"), center_style),
            Paragraph(rtl("المنتج"), center_style),
        ]]

        for name, qty, price, item_total, *rest in items:
            item_disc_note = float(rest[0]) if rest else 0.0
            product_id = rest[1] if len(rest) > 1 else None
            pack_id = rest[2] if len(rest) > 2 else None
            if item_disc_note > 0:
                items_discount_sum += item_disc_note

            # مكوّن باقة: سطر فرعي مسنود (بدون قيم سعرية مستقلة).
            if pack_id is not None and product_id is not None:
                table_data.append([
                    Paragraph("", center_style),
                    Paragraph("", center_style),
                    Paragraph(f"{float(qty or 0):g}", center_style),
                    Paragraph(rtl(f"    ↳ {name}"), cell_style),
                ])
                continue

            # سطر الباقة الرئيسي أو منتج عادي.
            if pack_id is not None and product_id is None:
                name = "🎁 " + str(name)
            table_data.append([
                Paragraph(money(item_total), center_style),
                Paragraph(money(price), center_style),
                Paragraph(f"{float(qty or 0):g}", center_style),
                Paragraph(rtl(name), cell_style),
            ])

        if paper == "80mm":
            widths = [content_width * 0.27, content_width * 0.23,
                      content_width * 0.15, content_width * 0.35]
        else:
            widths = [content_width * 0.24, content_width * 0.20,
                      content_width * 0.14, content_width * 0.42]

        item_table = Table(table_data, colWidths=widths, repeatRows=1)
        item_table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0F3D5E")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#CBD5E1")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1),
             [colors.white, colors.HexColor("#F8FAFC")]),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 3),
            ("RIGHTPADDING", (0, 0), (-1, -1), 3),
            ("TOPPADDING", (0, 0), (-1, -1), 3.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
        ]))
        story.append(item_table)
        story.append(Spacer(1, 2.5 * mm))

        # ملاحظة صغيرة بقيمة خصم المنتجات إن وُجدت (مضمّنة في صف الخصم أعلاه).
        if items_discount_sum > 0:
            story.append(Paragraph(
                rtl(f"{self.t('خصم المنتج')}: {items_discount_sum:,.2f} دج ({self.t('مضمّن في الخصم أعلاه')})"),
                ParagraphStyle("ItemDiscountNote", parent=meta_style,
                               fontSize=font_size - 1.5,
                               textColor=colors.HexColor("#B45309"))
            ))
            story.append(Spacer(1, 1.5 * mm))

        summary_data = [
            [Paragraph(money(total), total_style), Paragraph(rtl("الإجمالي"), meta_style)],
            [Paragraph(money(discount), total_style), Paragraph(rtl("الخصم"), meta_style)],
            [Paragraph(money(net), total_style), Paragraph(rtl("الصافي"), meta_style)],
            [Paragraph(money(paid), total_style), Paragraph(rtl("المدفوع"), meta_style)],
            [Paragraph(money(change), total_style), Paragraph(rtl("الباقي"), meta_style)],
            [Paragraph(money(remaining), total_style), Paragraph(rtl("الدين المتبقي"), meta_style)],
        ]
        summary_table = Table(
            summary_data,
            colWidths=[content_width * 0.48, content_width * 0.52]
        )
        summary_table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F8FAFC")),
            ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#CBD5E1")),
            ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#E2E8F0")),
            ("ALIGN", (0, 0), (0, -1), "LEFT"),
            ("ALIGN", (1, 0), (1, -1), "RIGHT"),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 2.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
        ]))
        story.append(summary_table)
        story.append(Spacer(1, 3 * mm))
        story.append(Paragraph(rtl(invoice_footer), ParagraphStyle(
            "Thanks", parent=meta_style, alignment=TA_CENTER,
            fontSize=font_size, textColor=colors.HexColor("#0F3D5E")
        )))

        def footer(canvas_obj, doc_obj):
            canvas_obj.saveState()
            canvas_obj.setFont(font_name, 7.5)
            canvas_obj.setFillColor(colors.HexColor("#64748B"))
            if paper == "A4":
                canvas_obj.drawCentredString(
                    pagesize[0] / 2, 8 * mm,
                    f"Supermarket Pro  •  {doc_obj.page}"
                )
            canvas_obj.restoreState()

        doc.build(story, onFirstPage=footer, onLaterPages=footer)

        # Optional direct printing on Windows. If Windows cannot print the PDF,
        # simply open it so the user can print manually.
        if auto_print:
            try:
                os.startfile(os.path.abspath(path), "print")
                self.toast("تم إرسال الفاتورة إلى الطابعة", "success")
            except Exception:
                try:
                    os.startfile(os.path.abspath(path))
                    self.toast("تم فتح الفاتورة. اختر طباعة من عارض PDF.", "warning")
                except Exception as exc:
                    self.toast(f"تم حفظ الفاتورة لكن تعذر فتحها: {exc}", "warning")
        else:
            try:
                os.startfile(os.path.abspath(path))
            except Exception:
                pass
            self.toast(f"تم حفظ الفاتورة:\n{path}", "success")

        return path

    def print_invoice_80mm(self, invoice_number, direct=False):
        """إنشاء فاتورة حرارية 80mm وإرسالها للطباعة."""
        try:
            return self._create_invoice_pdf(
                invoice_number, paper="80mm", auto_print=True, direct=direct
            )
        except ImportError:
            self.toast("لتفعيل طباعة الفواتير ثبّت ReportLab: python -m pip install reportlab", "danger")
        except Exception as exc:
            self.toast(f"تعذر طباعة فاتورة 80mm: {exc}", "danger")
        return None

    def print_invoice_a4(self, invoice_number, direct=False):
        """إنشاء فاتورة A4 وإرسالها للطباعة."""
        try:
            return self._create_invoice_pdf(
                invoice_number, paper="A4", auto_print=True, direct=direct
            )
        except ImportError:
            self.toast("لتفعيل طباعة الفواتير ثبّت ReportLab: python -m pip install reportlab", "danger")
        except Exception as exc:
            self.toast(f"تعذر طباعة فاتورة A4: {exc}", "danger")
        return None

    def show_invoice_details(self, invoice_number):
        """عرض تفاصيل فاتورة محفوظة في جدول sales مع منتجاتها."""
        conn = self.db.get_connection()
        try:
            sale = conn.execute(
                """
                SELECT invoice_number, customer_id, total, discount,
                       paid_amount, change_amount, sale_date
                FROM sales
                WHERE invoice_number = ?
                """,
                (invoice_number,)
            ).fetchone()

            if not sale:
                self.toast("الفاتورة غير موجودة", "danger")
                return

            # نقرأ عمود خصم المنتج إن كان موجودًا في قاعدة البيانات القديمة،
            # مع أعمدة الباقة (product_id, pack_id) لاختيار العرض المجمّع.
            try:
                items = conn.execute(
                    """
                    SELECT COALESCE(pk.name, p.name), si.quantity, si.price, si.total,
                           COALESCE(si.item_discount, 0), si.product_id, si.pack_id
                    FROM sale_items si
                    LEFT JOIN products p ON p.id = si.product_id
                    LEFT JOIN packs pk ON pk.id = si.pack_id
                    WHERE si.sale_id = (
                        SELECT id FROM sales WHERE invoice_number = ?
                    )
                    ORDER BY si.id
                    """,
                    (invoice_number,)
                ).fetchall()
            except Exception:
                items = conn.execute(
                    """
                    SELECT COALESCE(pk.name, p.name), si.quantity, si.price, si.total, 0,
                           si.product_id, si.pack_id
                    FROM sale_items si
                    LEFT JOIN products p ON p.id = si.product_id
                    LEFT JOIN packs pk ON pk.id = si.pack_id
                    WHERE si.sale_id = (
                        SELECT id FROM sales WHERE invoice_number = ?
                    )
                    ORDER BY si.id
                    """,
                    (invoice_number,)
                ).fetchall()
        except Exception as exc:
            self.toast(f"تعذر تحميل الفاتورة: {exc}", "danger")
            return
        finally:
            conn.close()

        total = float(sale[2] or 0)
        discount = float(sale[3] or 0)
        paid = float(sale[4] or 0)
        change = float(sale[5] or 0)
        remaining = max(0.0, total - discount - paid)

        win = ctk.CTkToplevel(self)
        win.title(self.t(f"الفاتورة {invoice_number}"))
        win.geometry("980x760")
        win.minsize(720, 560)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 980, 760)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=18, pady=18)

        header = ctk.CTkFrame(container, fg_color="transparent")
        header.pack(fill="x", pady=(0, 12))
        ctk.CTkLabel(
            header, text=self.t("تفاصيل الفاتورة"), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(side="left")
        ctk.CTkLabel(
            header, text=invoice_number, text_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side="right")

        info = self.make_card(container)
        info.pack(fill="x", pady=(0, 10))
        info_rows = [
            (self.t("التاريخ"), sale[6] or "—"),
            (self.t("الإجمالي قبل الخصم"), self.t(f"{total:,.2f} د.ج")),
            (self.t("الخصم"), self.t(f"{discount:,.2f} د.ج")),
            (self.t("المدفوع"), self.t(f"{paid:,.2f} د.ج")),
            (self.t("الباقي/المتبقي"), self.t(f"{remaining:,.2f} د.ج")),
        ]
        for label, value in info_rows:
            r = ctk.CTkFrame(info, fg_color="transparent")
            r.pack(fill="x", padx=12, pady=3)
            ctk.CTkLabel(r, text=label, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9)).pack(side="left")
            ctk.CTkLabel(r, text=value, text_color=self.text(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")).pack(side="right")

        list_frame = ctk.CTkScrollableFrame(container, fg_color="transparent")
        list_frame.pack(fill="both", expand=True, pady=5)

        table = self.make_card(list_frame)
        table.pack(fill="x", pady=(0, 5))
        for label in (self.t("المنتج"), self.t("الكمية"), self.t("سعر الوحدة"), self.t("الإجمالي")):
            ctk.CTkLabel(table, text=label, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=8, weight="bold")).pack(
                             side="left", fill="x", expand=True, padx=7, pady=8)

        for item in items:
            name = item[0]
            if name is None:
                name = self.t("منتج محذوف")
            qty = float(item[1] or 0)
            price = float(item[2] or 0)
            item_total = float(item[3] or 0)
            item_discount = float(item[4] or 0) if len(item) > 4 else 0.0
            product_id = item[5] if len(item) > 5 else None
            pack_id = item[6] if len(item) > 6 else None

            # مكوّن باقة: سطر فرعي مسنود تحت سطر الباقة الرئيسي.
            if pack_id is not None and product_id is not None:
                row = self.make_card(list_frame)
                row.pack(fill="x", pady=1)
                name_cell = ctk.CTkFrame(row, fg_color="transparent")
                name_cell.pack(side="left", fill="x", expand=True, padx=10, pady=3)
                ctk.CTkLabel(
                    name_cell, text=self.t(f"   ⊳ {name} × {self._format_quantity(qty, 'قطعة')}"),
                    text_color=self.muted(), anchor="w",
                    font=ctk.CTkFont(family=self.ui_font_family, size=8)
                ).pack(anchor="w")
                ctk.CTkLabel(
                    row, text=self.t(f"{item_total:,.2f} د.ج"), text_color=self.muted(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=8)
                ).pack(side="left", fill="x", expand=True, padx=7, pady=3)
                continue

            # سطر الباقة الرئيسي (الملخص) أو منتج عادي.
            is_pack_line = pack_id is not None and product_id is None
            row = self.make_card(list_frame)
            row.pack(fill="x", pady=2)

            # اسم المنتج + ملاحظة صغيرة بقيمة الخصم على المنتج إن وُجد.
            name_cell = ctk.CTkFrame(row, fg_color="transparent")
            name_cell.pack(side="left", fill="x", expand=True, padx=7,
                           pady=(9, 9) if item_discount <= 0 else (5, 5))
            if is_pack_line:
                ctk.CTkLabel(name_cell, text="🎁 " + str(name), text_color=self.colors["primary"],
                             anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=8)).pack(anchor="w")
            else:
                ctk.CTkLabel(name_cell, text=str(name), text_color=self.text(),
                             anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=8)).pack(anchor="w")
            if item_discount > 0:
                ctk.CTkLabel(name_cell,
                             text=self.t(f"{self.t('خصم المنتج')}: {item_discount:,.2f} د.ج"),
                             text_color=self.colors["accent"], anchor="w",
                             font=ctk.CTkFont(family=self.ui_font_family, size=7)).pack(anchor="w")

            for value in (f"{qty:g}", self.t(f"{price:,.2f} د.ج"), self.t(f"{item_total:,.2f} د.ج")):
                ctk.CTkLabel(row, text=str(value), text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=8)).pack(
                                 side="left", fill="x", expand=True, padx=7, pady=9)

        actions = ctk.CTkFrame(container, fg_color="transparent")
        actions.pack(fill="x", pady=(10, 0))

        # Print buttons are available for every saved invoice.
        ctk.CTkButton(
            actions,
            text=self.t("🧾 طباعة 80mm"),
            command=lambda ref=invoice_number: self.print_invoice_80mm(ref),
            height=42,
            corner_radius=8,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            text_color="white",
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            actions,
            text=self.t("📄 طباعة A4"),
            command=lambda ref=invoice_number: self.print_invoice_a4(ref),
            height=42,
            corner_radius=8,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
        ).pack(side="left", fill="x", expand=True, padx=4)

        if remaining > 0:
            ctk.CTkButton(
                actions,
                text=self.t(f"💰 تسديد المتبقي ({remaining:,.2f} د.ج)"),
                command=lambda cid=sale[1]: (win.destroy(), self.pay_debt(cid)),
                height=42,
                corner_radius=8,
                fg_color=self.colors["accent"],
                hover_color=self.colors["accent_hover"],
                text_color="white",
                font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold")
            ).pack(side="left", fill="x", expand=True, padx=4)

        ctk.CTkButton(
            actions,
            text=self.t("إغلاق"),
            command=win.destroy,
            height=42,
            corner_radius=8,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

    def show_invoices_history_dialog(self):
        """سجل الفواتير والوصولات: عرض كل الوصلات مع الجهاز الذي أصدرها.

        - أجهزة العميل (PC2/PC3) ترى وصلات جهازها فقط.
        - السيرفر (PC1) يرى كل الوصلات مع فلتر أجهزة.
        - النقر على وصل يعرض بنوده + إعادة الطباعة + إلغاء الوصل.
        """
        win = ctk.CTkToplevel(self)
        win.title(self.t("🧾 سجل الفواتير والوصولات"))
        win.geometry("1150x760")
        win.minsize(920, 600)
        win.transient(self)
        win.grab_set()
        try:
            self.center_window(win, 1150, 760)
        except Exception:
            pass

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=16, pady=16)

        header = ctk.CTkFrame(container, fg_color="transparent")
        header.pack(fill="x", pady=(0, 10))
        ctk.CTkLabel(
            header, text=self.t("سجل الفواتير والوصولات"), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=20, weight="bold")
        ).pack(side="right")
        ctk.CTkButton(
            header, text=self.t("⟳ تحديث"), height=32, width=90, corner_radius=8,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=lambda: self._reload_invoices_history()
        ).pack(side="left")

        controls = ctk.CTkFrame(container, fg_color="transparent")
        controls.pack(fill="x", pady=(0, 10))

        search_var = tk.StringVar()
        search_entry = ctk.CTkEntry(
            controls, textvariable=search_var, height=36, width=230,
            placeholder_text=self.t("ابحث برقم الوصل..."), fg_color=self.card(),
            border_color=self.border(), text_color=self.text()
        )
        search_entry.pack(side="right", padx=(8, 0))

        is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"
        device_var = tk.StringVar()
        device_combo = None
        if is_server:
            devices = self.db.get_all_sales_devices()
            device_var.set(self.t("كل الأجهزة"))
            ctk.CTkLabel(controls, text=self.t("الجهاز:"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(side="right", padx=(0, 6))
            device_combo = ctk.CTkOptionMenu(
                controls, variable=device_var, values=[self.t("كل الأجهزة")] + devices,
                width=130, height=36, fg_color=self.card(), button_color=self.card(),
                button_hover_color=self.border(), text_color=self.text(),
                dropdown_fg_color=self.card(), dropdown_hover_color=self.border(),
            )
            device_combo.pack(side="right")
        else:
            device_var.set(self._get_device_name())

        # صندوق البحث + جدول الوصلات
        table_card = self.make_card(container)
        table_card.pack(fill="none", expand=False, pady=(0, 2))
        list_frame = ctk.CTkScrollableFrame(table_card, fg_color="transparent", height=210)
        list_frame.pack(fill="x", padx=10, pady=8)

        # لوحة التفاصيل
        details_card = self.make_card(container)
        details_card.pack(fill="both", expand=True)
        details_body = ctk.CTkFrame(details_card, fg_color="transparent")
        details_body.pack(fill="both", expand=True, padx=10, pady=10)

        state = {"selected_id": None, "selected_invoice": None}

        def _do_refresh():
            self._reload_invoices_history_grid(list_frame, win, device_var, search_var,
                                               details_body, state)

        win._hik_refresh = _do_refresh
        def _apply_search(_=None):
            _do_refresh()

        search_var.trace_add("write", _apply_search)
        if device_combo:
            device_combo.configure(command=lambda _: _do_refresh())
        win.after(50, _do_refresh)

    def _reload_invoices_history(self):
        """إعادة تحميل سجل الوصلات في كل نافذة سجل مفتوحة."""
        refreshed = False
        for child in self.winfo_children():
            if isinstance(child, ctk.CTkToplevel) and (self.t("سجل الفواتير") in (child.title() or "") or "سجل الفواتير" in (child.title() or "")):
                cb = getattr(child, "_hik_refresh", None)
                if cb:
                    try:
                        cb()
                        refreshed = True
                    except Exception:
                        pass
        if not refreshed:
            self.toast("استخدم زر '⟳ تحديث' داخل النافذة", "info")

    def _reload_invoices_history_grid(self, container, win, device_var, search_var,
                                      details_body, state):
        """إعادة بناء جدول الوصلات في container + تفريغ لوحة التفاصيل."""
        for w in container.winfo_children():
            w.destroy()
        for w in details_body.winfo_children():
            w.destroy()
        state["selected_id"] = None
        state["selected_invoice"] = None

        device = device_var.get()
        is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"
        dev_filter = None if is_server and device in ("", self.t("كل الأجهزة")) else (
            device if device and device != self.t("كل الأجهزة") else None)
        search = search_var.get().strip() or None
        try:
            rows = self.db.get_invoices_history(device_name=dev_filter, search_term=search, limit=200)
        except Exception:
            rows = []

        if not rows:
            ctk.CTkLabel(container, text=self.t("لا توجد فواتير مطابقة"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=12)).pack(pady=18)
            ctk.CTkLabel(details_body, text=self.t("اختر وصلًا لعرض تفاصيله"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(pady=30)
            return

        hdr = ctk.CTkFrame(container, fg_color=self.card(), corner_radius=7)
        hdr.pack(fill="x", pady=(0, 3))
        cols = [self.t("رقم الوصل"), self.t("الجهاز"), self.t("الزبون"), self.t("المبلغ"), self.t("التاريخ")]
        weights = [24, 12, 24, 12, 28]
        for ci, txt in enumerate(cols):
            hdr.grid_columnconfigure(ci, weight=weights[ci])
            ctk.CTkLabel(hdr, text=txt, text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                         anchor="w").grid(row=0, column=ci, sticky="ew", padx=8, pady=7)

        def _show_details(rid, rinv):
            self._render_invoice_detail(details_body, state, rid, rinv, win, container,
                                        device_var, search_var)

        for ri, row in enumerate(rows):
            rid, invoice_number, total, _discount, _paid, _chg, sale_date, customer_name, rdev = row
            rw = ctk.CTkFrame(container, fg_color=self.bg() if ri % 2 == 0 else self.card(),
                              corner_radius=7, cursor="hand2")
            rw.pack(fill="x", pady=1)
            for ci in range(len(cols)):
                rw.grid_columnconfigure(ci, weight=weights[ci])
            vals = (str(invoice_number or ""), str(rdev or "PC1"),
                    str(customer_name or ""), self.t(f"{float(total or 0):,.2f} د.ج"),
                    str(sale_date or "")[:16])
            for ci, val in enumerate(vals):
                ctk.CTkLabel(rw, text=val, text_color=self.text(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=10),
                             anchor="w").grid(row=0, column=ci, sticky="ew", padx=8, pady=7)
            rw.bind("<Button-1>", lambda e, r=rid, inv=invoice_number: _show_details(r, inv))
            for lbl in rw.winfo_children():
                lbl.bind("<Button-1>", lambda e, r=rid, inv=invoice_number: _show_details(r, inv))

    def _render_invoice_detail(self, details_body, state, sale_id, invoice_number,
                               win, table_container, device_var, search_var):
        """عرض بنود وصل محدد مع أزرار إعادة الطباعة والإلغاء."""
        for w in details_body.winfo_children():
            w.destroy()
        state["selected_id"] = sale_id
        state["selected_invoice"] = invoice_number

        try:
            items = self.db.get_invoice_items(sale_id)
        except Exception:
            items = []

        head = ctk.CTkFrame(details_body, fg_color="transparent")
        head.pack(fill="x", pady=(0, 8))
        ctk.CTkLabel(head, text=self.t(f"وصل: {invoice_number}"), text_color=self.colors["primary"],
                     font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")).pack(side="right")

        if not items:
            ctk.CTkLabel(details_body, text=self.t("لا توجد بنود لهذا الوصل"), text_color=self.muted(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(pady=25)
        else:
            items_frame = ctk.CTkScrollableFrame(details_body, fg_color="transparent")
            items_frame.pack(fill="both", expand=True)
            ihdr = ctk.CTkFrame(items_frame, fg_color=self.card(), corner_radius=7)
            ihdr.pack(fill="x", pady=(0, 3))
            icols = [self.t("المنتج"), self.t("الكمية"), self.t("السعر"), self.t("المجموع")]
            iweights = [46, 18, 18, 18]
            for ci, txt in enumerate(icols):
                ihdr.grid_columnconfigure(ci, weight=iweights[ci])
                ctk.CTkLabel(ihdr, text=txt, text_color=self.muted(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                             anchor="w").grid(row=0, column=ci, sticky="ew", padx=7, pady=6)
            total_sum = 0.0
            for ri, it in enumerate(items):
                _sid, name, qty, price, total, unit, pid = (list(it) + [None]*7)[:7]
                try:
                    qty = float(qty or 0); price = float(price or 0); total = float(total or 0)
                except Exception:
                    qty = 0.0; price = 0.0; total = 0.0
                total_sum += total
                row = ctk.CTkFrame(items_frame, fg_color=self.bg() if ri % 2 == 0 else self.card(),
                                   corner_radius=6)
                row.pack(fill="x", pady=1)
                for ci in range(len(icols)):
                    row.grid_columnconfigure(ci, weight=iweights[ci])
                unit_label = f" {unit}" if unit else ""
                vals = (str(name or self.t("(منتج محذوف)")), f"{qty:g}{unit_label}",
                        f"{price:,.2f}", self.t(f"{total:,.2f} د.ج"))
                for ci, val in enumerate(vals):
                    ctk.CTkLabel(row, text=val, text_color=self.text(),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=9),
                                 anchor="w").grid(row=0, column=ci, sticky="ew", padx=7, pady=6)
            ctk.CTkLabel(items_frame, text=self.t(f"الإجمالي: {total_sum:,.2f} د.ج"),
                         text_color=self.colors["secondary"],
                         font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                         anchor="w").pack(fill="x", padx=7, pady=(8, 4))

        actions = ctk.CTkFrame(details_body, fg_color="transparent")
        actions.pack(fill="x", pady=(10, 0))
        ctk.CTkButton(
            actions, text=self.t("🧾 إعادة الطباعة"), height=38, corner_radius=8,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=lambda inv=invoice_number: self.print_invoice_80mm(inv)
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))
        ctk.CTkButton(
            actions, text=self.t("📄 طباعة A4"), height=38, corner_radius=8,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            border_width=1, border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=lambda inv=invoice_number: self.print_invoice_a4(inv)
        ).pack(side="left", fill="x", expand=True, padx=4)
        ctk.CTkButton(
            actions, text=self.t("✕ إلغاء الوصل"), height=38, corner_radius=8,
            fg_color=self.colors.get("danger", "#b91c1c"),
            hover_color=self.colors.get("danger_hover", "#991b1b"),
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=lambda rid=sale_id, inv=invoice_number: self._confirm_void_invoice(rid, inv, win)
        ).pack(side="left", fill="x", expand=True, padx=(4, 0))

    def _confirm_void_invoice(self, sale_id, invoice_number, win):
        """تأكيد إلغاء الوصل ثم إلغاؤه واستعادة المخزون وتحديث الجدول."""
        if not messagebox.askyesno(
            self.t("تأكيد إلغاء الوصل"),
            self.t(f"هل تريد إلغاء الوصل {invoice_number} نهائيًا؟\n"
                   "سيتم استرجاع المنتجات إلى المخزون ولا يمكن التراجع عن هذه العملية."),
            parent=win
        ):
            return
        ok = self.db.void_invoice(sale_id)
        if ok:
            self.log_action("invoice_voided", "invoice", sale_id,
                            f"{invoice_number} • تم إلغاء الوصل واسترجاع المخزون")
            self.toast(f"تم إلغاء الوصل {invoice_number} واسترجاع المنتجات", "success")
            self._reload_invoices_history()
            if self.current_page in ("inventory", "pos", "reports"):
                try:
                    if self.current_page == "inventory":
                        self.show_inventory()
                    elif self.current_page == "pos":
                        self.show_pos()
                    elif self.current_page == "reports":
                        self.load_report(getattr(self, "active_report_period", "اليوم"))
                except Exception:
                    pass
        else:
            self.toast("فشل إلغاء الوصل", "danger")

    def _select_customer_from_details(self, customer, window=None):
        self.selected_customer = customer
        if window is not None:
            window.destroy()
        self.show_pos(preserve_cart=True)

    def show_add_customer_form(self):
        win, entries = self.form_window(
            "+ إضافة زبون جديد",
            500,
            480,
            [
                ("الاسم الكامل *", "", self.t("مثال: أحمد بن يوسف")),
                ("رقم الهاتف", "", self.t("مثال: 0550123456")),
                ("العنوان أو المنطقة", "", self.t("مثال: وسط المدينة")),
                ("سقف الدين المسموح به (د.ج)", "", self.t("0 يعني غير محدد")),
            ]
        )

        def save():
            name = entries["الاسم الكامل *"].get().strip()
            phone = entries["رقم الهاتف"].get().strip()
            address = entries["العنوان أو المنطقة"].get().strip()
            ceiling = entries["سقف الدين المسموح به (د.ج)"].get().strip()

            if not name:
                self.toast("اسم الزبون مطلوب", "danger")
                return

            try:
                success, msg = self.customer_manager.add_customer(
                    name, phone, address, ceiling
                )

                if success:
                    win.destroy()
                    self.show_customers()
                    self.toast("✓ تمت إضافة الزبون")
                else:
                    self.toast(str(msg), "danger")
            except Exception as exc:
                self.toast(f"فشل الحفظ: {exc}", "danger")

        self.form_buttons(win, save)

    def open_debt_payment_selector(self):
        """اختيار العميل الذي عليه دين قبل فتح شاشة التسديد."""
        try:
            customers = self.customer_manager.get_all_customers()
        except Exception as exc:
            self.toast(f"تعذر تحميل العملاء: {exc}", "danger")
            return

        debtors = []
        for customer in customers:
            try:
                balance = float(customer[3] or 0)
            except (TypeError, ValueError):
                balance = 0.0
            if balance > 0:
                debtors.append(customer)

        win = ctk.CTkToplevel(self)
        win.title(self.t("تسديد دين"))
        win.geometry("620x560")
        win.minsize(520, 480)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 620, 560)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=20, pady=20)

        ctk.CTkLabel(
            container,
            text=self.t("💰 تسديد دين عميل"),
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=21, weight="bold"
            )
        ).pack(anchor="w")

        ctk.CTkLabel(
            container,
            text=self.t("اختر العميل الذي تريد تسجيل دفعة له"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        ).pack(anchor="w", pady=(2, 14))

        search = ctk.CTkEntry(
            container,
            placeholder_text=self.t("ابحث باسم العميل أو الهاتف..."),
            height=42,
            corner_radius=9,
            fg_color=self.card(),
            border_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        )
        search.pack(fill="x", pady=(0, 10))

        list_frame = ctk.CTkScrollableFrame(
            container, fg_color="transparent"
        )
        list_frame.pack(fill="both", expand=True)

        def select_customer(customer_id):
            win.destroy()
            self.pay_debt(customer_id)

        def render(items):
            for widget in list_frame.winfo_children():
                widget.destroy()

            if not items:
                ctk.CTkLabel(
                    list_frame,
                    text=self.t("لا يوجد عملاء عليهم ديون حاليًا"),
                    text_color=self.muted(),
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=11
                    )
                ).pack(pady=70)
                return

            for customer in items:
                try:
                    balance = float(customer[3] or 0)
                except (TypeError, ValueError):
                    balance = 0.0

                row = ctk.CTkFrame(
                    list_frame,
                    fg_color=self.card(),
                    corner_radius=10,
                    border_width=1,
                    border_color=self.border()
                )
                row.pack(fill="x", pady=4)

                info = ctk.CTkFrame(row, fg_color="transparent")
                info.pack(side="left", fill="x", expand=True, padx=12, pady=10)

                ctk.CTkLabel(
                    info,
                    text=str(customer[1]),
                    text_color=self.text(),
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=11, weight="bold"
                    )
                ).pack(anchor="w")

                ctk.CTkLabel(
                    info,
                    text=self.t(f"الهاتف: {customer[2] or '—'}"),
                    text_color=self.muted(),
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=9
                    )
                ).pack(anchor="w", pady=(2, 0))

                ctk.CTkLabel(
                    row,
                    text=self.t(f"{balance:,.2f} د.ج"),
                    text_color=self.colors["danger"],
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=11, weight="bold"
                    )
                ).pack(side="right", padx=10)

                ctk.CTkButton(
                    row,
                    text=self.t("اختيار"),
                    command=lambda cid=customer[0]: select_customer(cid),
                    width=80,
                    height=34,
                    corner_radius=8,
                    fg_color=self.colors["accent"],
                    hover_color=self.colors["accent_hover"],
                    text_color="white",
                    font=ctk.CTkFont(
                        family=self.ui_font_family, size=9, weight="bold"
                    )
                ).pack(side="right", padx=5)

        def filter_debtors(_event=None):
            term = search.get().strip().lower()
            if not term:
                render(debtors)
                return

            filtered = [
                c for c in debtors
                if term in str(c[1] or "").lower()
                or term in str(c[2] or "").lower()
            ]
            render(filtered)

        search.bind("<KeyRelease>", filter_debtors)
        render(debtors)

        ctk.CTkButton(
            container,
            text=self.t("إلغاء"),
            command=win.destroy,
            height=38,
            corner_radius=8,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=9)
        ).pack(fill="x", pady=(10, 0))

    def pay_debt(self, customer_id):
        """تسجيل تسديد كلي أو جزئي لدين العميل."""
        try:
            customer = self.customer_manager.get_customer_by_id(customer_id)
        except Exception as exc:
            self.toast(f"تعذر قراءة بيانات العميل: {exc}", "danger")
            return

        if not customer:
            self.toast("العميل غير موجود", "danger")
            return

        # get_customer_by_id:
        # id, name, phone, address, balance
        customer_name = str(customer[1])
        try:
            balance = float(customer[4] or 0)
        except (TypeError, ValueError):
            balance = 0.0

        if balance <= 0:
            self.toast("هذا العميل لا يملك دينًا مستحقًا")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("تسديد الدين"))
        win.geometry("460x420")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 460, 420)

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=20, pady=20)

        ctk.CTkLabel(
            container,
            text=self.t("تسديد الدين"),
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=20, weight="bold"
            )
        ).pack(anchor="w")

        ctk.CTkLabel(
            container,
            text=customer_name,
            text_color=self.muted(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10
            )
        ).pack(anchor="w", pady=(2, 12))

        debt_card = self.make_card(container)
        debt_card.pack(fill="x", pady=(0, 14))

        ctk.CTkLabel(
            debt_card,
            text=self.t("الدين الحالي"),
            text_color=self.muted(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=9
            )
        ).pack(anchor="w", padx=14, pady=(11, 2))

        ctk.CTkLabel(
            debt_card,
            text=self.t(f"{balance:,.2f} د.ج"),
            text_color=self.colors["danger"],
            font=ctk.CTkFont(
                family=self.ui_font_family, size=24, weight="bold"
            )
        ).pack(anchor="w", padx=14, pady=(0, 11))

        ctk.CTkLabel(
            container,
            text=self.t("مبلغ التسديد"),
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10, weight="bold"
            )
        ).pack(anchor="w", pady=(0, 5))

        amount_entry = ctk.CTkEntry(
            container,
            placeholder_text=self.t("مثال: 5000"),
            height=42,
            corner_radius=9,
            fg_color=self.card(),
            border_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=11
            )
        )
        amount_entry.pack(fill="x")

        presets = ctk.CTkFrame(container, fg_color="transparent")
        presets.pack(fill="x", pady=9)

        preset_values = []
        for value in (500, 1000, 2000, 5000):
            if value < balance:
                preset_values.append(value)
        preset_values.append(balance)

        for value in list(dict.fromkeys(preset_values)):
            ctk.CTkButton(
                presets,
                text=self.t("تسديد كامل") if value == balance else f"{value:,.0f}",
                command=lambda v=value: (
                    amount_entry.delete(0, "end"),
                    amount_entry.insert(0, f"{v:g}")
                ),
                height=30,
                corner_radius=7,
                fg_color=self.card(),
                hover_color=self.border(),
                text_color=self.text(),
                border_width=1,
                border_color=self.border(),
                font=ctk.CTkFont(
                    family=self.ui_font_family, size=8
                )
            ).pack(side="left", fill="x", expand=True, padx=2)

        result_card = self.make_card(container)
        result_card.pack(fill="x", pady=(0, 12))

        remaining_var = ctk.StringVar(
            value=self.t(f"المتبقي بعد التسديد: {balance:,.2f} د.ج")
        )

        ctk.CTkLabel(
            result_card,
            textvariable=remaining_var,
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10, weight="bold"
            )
        ).pack(anchor="w", padx=13, pady=10)

        def update_remaining(event=None):
            try:
                amount = float(amount_entry.get() or 0)
            except ValueError:
                remaining_var.set(self.t("المتبقي بعد التسديد: —"))
                return

            remaining = balance - amount
            if amount < 0:
                remaining_var.set(self.t("المبلغ غير صالح"))
            elif remaining < 0:
                remaining_var.set(self.t("المبلغ أكبر من الدين"))
            else:
                remaining_var.set(
                    self.t(f"المتبقي بعد التسديد: {remaining:,.2f} د.ج")
                )

        amount_entry.bind("<KeyRelease>", update_remaining)

        def confirm():
            # تسديد الديون عملية عالية الخطورة: يتطلب رمز PIN صالح لأي مستخدم.
            if not self.require_pin("تسديد دين عميل", "any"):
                return

            try:
                amount = float(amount_entry.get())
            except ValueError:
                self.toast("أدخل مبلغًا صحيحًا", "danger")
                return

            if amount <= 0:
                self.toast("أدخل مبلغًا أكبر من صفر", "danger")
                return

            if amount > balance:
                self.toast(
                    f"لا يمكن تسديد أكثر من الدين الحالي ({balance:,.2f} د.ج)",
                    "danger"
                )
                return

            try:
                success, message = self.customer_manager.update_balance(
                    customer_id, -amount
                )
            except Exception as exc:
                self.toast(f"فشل تسجيل التسديد: {exc}", "danger")
                return

            if not success:
                self.toast(str(message), "danger")
                return

            self.log_action("debt_payment", "customer", customer_id,
                            f"{customer_name} • {amount:,.2f} دج")

            history_ok, history_msg = self.debt_manager.record_payment(
                customer_id, amount, note="تسديد دين"
            )
            if not history_ok:
                self.toast(f"تم التسديد، لكن تعذر حفظ السجل: {history_msg}", "warning")

            remaining = balance - amount
            win.destroy()

            # Refresh the customer screen so the new balance appears immediately.
            self.show_customers()

            if remaining <= 0.00001:
                self.toast(
                    f"تم تسديد دين {customer_name} بالكامل"
                )
            else:
                self.toast(
                    f"تم تسديد {amount:,.2f} د.ج — المتبقي {remaining:,.2f} د.ج"
                )

        actions = ctk.CTkFrame(container, fg_color="transparent")
        actions.pack(fill="x")

        ctk.CTkButton(
            actions,
            text=self.t("تأكيد التسديد"),
            command=confirm,
            height=42,
            corner_radius=9,
            fg_color=self.colors["secondary"],
            hover_color=self.colors["secondary_hover"],
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10, weight="bold"
            )
        ).pack(side="left", fill="x", expand=True, padx=(0, 4))

        ctk.CTkButton(
            actions,
            text=self.t("إلغاء"),
            command=win.destroy,
            height=42,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10
            )
        ).pack(side="right", fill="x", expand=True, padx=(4, 0))

        amount_entry.focus_set()

    # =========================================================
    # Reports

    # =========================================================


    # =========================================================
    # V26 — تصدير التقارير
    # =========================================================

    def _get_returns_total_for_period(self, key="today", device_name=None):
        """إجمالي المرتجعات لفترة زمنية محددة.

        device_name: إن حُدد، تُحتسب مرتجعات هذا الجهاز فقط.
        """
        conn=None
        try:
            conn=self.db.get_connection()
            where={"today":"DATE(return_date)=CURDATE()","week":"DATE(return_date)>=CURDATE()-INTERVAL 7 DAY","month":"DATE(return_date)>=CURDATE()-INTERVAL 30 DAY","year":"DATE(return_date)>=CURDATE()-INTERVAL 365 DAY"}.get(key,"DATE(return_date)=CURDATE()")
            if device_name:
                row=conn.execute(f"SELECT COALESCE(SUM(total_amount),0) FROM returns WHERE {where} AND device_name = %s",(device_name,)).fetchone()
            else:
                row=conn.execute(f"SELECT COALESCE(SUM(total_amount),0) FROM returns WHERE {where}").fetchone()
            return float(row[0] or 0)
        except Exception: return 0.0
        finally:
            if conn: conn.close()

    def _report_period_data(self, period):
        """إرجاع بيانات التقرير الحالية بصيغة مناسبة للتصدير."""
        period_map = {
            "اليوم": "today",
            "هذا الأسبوع": "week",
            "هذا الشهر": "month",
            "هذا العام": "year",
        }
        key = period_map.get(period, "today")
        summary = self.reports_manager.get_sales_summary(key)
        sales = self.reports_manager.get_sales_by_period(key)
        return_total = self._get_returns_total_for_period(key)
        summary["total"] = max(0.0, float(summary.get("total",0)) - return_total)
        if sales:
            summary["average"] = summary["total"] / len(sales)
        top = self.reports_manager.get_top_products(10)
        low = self.reports_manager.get_low_stock_products(20)
        return summary, sales, top, low

    def _ask_export_path(self, kind, default_name):
        if kind == "xlsx":
            return filedialog.asksaveasfilename(
                title=self.t("حفظ تقرير Excel"),
                defaultextension=".xlsx",
                initialfile=default_name + ".xlsx",
                filetypes=[("Excel", "*.xlsx")]
            )
        if kind == "pdf":
            return filedialog.asksaveasfilename(
                title=self.t("حفظ تقرير PDF"),
                defaultextension=".pdf",
                initialfile=default_name + ".pdf",
                filetypes=[("PDF", "*.pdf")]
            )
        return filedialog.asksaveasfilename(
            title=self.t("حفظ التقرير CSV"),
            defaultextension=".csv",
            initialfile=default_name + ".csv",
            filetypes=[("CSV", "*.csv")]
        )

    def export_report_excel(self, period="اليوم"):
        try:
            from openpyxl import Workbook
            path = self._ask_export_path("xlsx", self.t(f"تقرير_المبيعات_{period}"))
            if not path:
                return
            summary, sales, top, low = self._report_period_data(period)
            wb = Workbook()
            ws = wb.active
            ws.title = self.t("ملخص التقرير")
            ws.sheet_view.rightToLeft = True
            ws.append(["تقرير Supermarket Pro", period])
            ws.append([])
            for label, value in [(self.t("إجمالي المبيعات"), summary["total"]), (self.t("عدد الفواتير"), summary["count"]), (self.t("متوسط الفاتورة"), summary["average"]), (self.t("أعلى فاتورة"), summary["max"]), (self.t("أقل فاتورة"), summary["min"] )]:
                ws.append([label, value])
            ws.append([])
            ws.append(["تم إنشاء التقرير", datetime.now().strftime("%Y-%m-%d %H:%M")])

            ws2 = wb.create_sheet("الفواتير"); ws2.sheet_view.rightToLeft = True
            ws2.append(["ID", "رقم الفاتورة", "العميل", "الإجمالي", "الخصم", "المدفوع", "الباقي", "التاريخ"])
            for row in sales: ws2.append(list(row))
            ws3 = wb.create_sheet("الأكثر مبيعاً"); ws3.sheet_view.rightToLeft = True
            ws3.append(["المنتج", "الكمية", "الإيراد"])
            for row in top: ws3.append(list(row))
            ws4 = wb.create_sheet("مخزون منخفض"); ws4.sheet_view.rightToLeft = True
            ws4.append(["ID", "المنتج", "الكمية", "الوحدة"])
            for row in low: ws4.append(list(row))

            # Style without importing openpyxl.styles (avoids Pylance's openpyxl.styles warning in some environments).
            header_fill = "1F6AA5"; header_font = "FFFFFF"; title_fill = "163A5F"
            for sheet in wb.worksheets:
                sheet.freeze_panes = "A2"
                sheet.auto_filter.ref = sheet.dimensions
                for cell in sheet[1]:
                    cell.font = cell.font.copy(bold=True, color=header_font, size=11)
                    cell.fill = cell.fill.copy(fill_type="solid", fgColor=header_fill)
                    cell.alignment = cell.alignment.copy(horizontal="center", vertical="center")
                for row in sheet.iter_rows():
                    for cell in row:
                        cell.alignment = cell.alignment.copy(vertical="center")
                for col in range(1, sheet.max_column + 1):
                    # Local Excel column-letter conversion; avoids openpyxl.utils import warnings.
                    n = col
                    letter = ""
                    while n:
                        n, rem = divmod(n - 1, 26)
                        letter = chr(65 + rem) + letter
                    max_len = max([len(str(sheet.cell(r, col).value or "")) for r in range(1, min(sheet.max_row, 200)+1)] + [10])
                    sheet.column_dimensions[letter].width = min(max(max_len + 3, 12), 32)
                sheet.row_dimensions[1].height = 24
            ws.merge_cells("A1:B1")
            ws["A1"].font = ws["A1"].font.copy(bold=True, color=header_font, size=14)
            ws["A1"].fill = ws["A1"].fill.copy(fill_type="solid", fgColor=title_fill)
            ws["A1"].alignment = ws["A1"].alignment.copy(horizontal="center")
            wb.save(path)
            self.toast(f"تم تصدير التقرير الاحترافي إلى:\n{path}", "success")
        except ImportError:
            self.show_message("مكتبة Excel غير موجودة", "ثبّت openpyxl في نفس Python المستخدم لتشغيل البرنامج:\n\npython -m pip install openpyxl", "error")
        except Exception as exc:
            self.show_message("خطأ في التصدير", f"تعذر إنشاء ملف Excel:\n{exc}", "error")

    def export_report_csv(self, period="اليوم"):
        try:
            import csv
            path = self._ask_export_path("csv", self.t(f"تقرير_المبيعات_{period}"))
            if not path:
                return
            summary, sales, top, low = self._report_period_data(period)
            with open(path, "w", newline="", encoding="utf-8-sig") as f:
                writer = csv.writer(f)
                writer.writerow(["تقرير المبيعات", period])
                writer.writerow([])
                writer.writerow(["إجمالي المبيعات", summary["total"]])
                writer.writerow(["عدد الفواتير", summary["count"]])
                writer.writerow(["متوسط الفاتورة", summary["average"]])
                writer.writerow([])
                writer.writerow(["الفواتير"])
                writer.writerow(["ID", "Invoice", "Customer ID", "Total", "Discount", "Paid", "Change", "Date"])
                for row in sales:
                    writer.writerow(list(row))
            self.toast(f"تم تصدير CSV:\n{path}", "success")
        except Exception as exc:
            self.show_message("خطأ في التصدير", f"تعذر إنشاء CSV:\n{exc}", "error")

    def export_report_pdf(self, period="اليوم"):
        """إنشاء تقرير PDF احترافي متعدد الأقسام باستخدام ReportLab Platypus."""
        try:
            import os
            from reportlab.lib import colors
            from reportlab.lib.enums import TA_RIGHT, TA_CENTER
            from reportlab.lib.pagesizes import A4
            from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
            from reportlab.lib.units import mm
            from reportlab.pdfbase import pdfmetrics
            from reportlab.pdfbase.ttfonts import TTFont
            from reportlab.platypus import (
                SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
                PageBreak, KeepTogether, HRFlowable
            )

            path = self._ask_export_path("pdf", self.t(f"تقرير_المبيعات_{period}"))
            if not path:
                return

            summary, sales, top, low = self._report_period_data(period)

            # Find a Unicode font that can display Arabic.
            font_candidates = [
                ("ReportArabic", "C:/Windows/Fonts/tahoma.ttf"),
                ("ReportArabic", "C:/Windows/Fonts/arial.ttf"),
                ("ReportArabic", "C:/Windows/Fonts/Arial.ttf"),
                ("ReportArabic", "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"),
                ("ReportArabic", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
            ]
            font_name = "Helvetica"
            for candidate_name, candidate_path in font_candidates:
                if os.path.exists(candidate_path):
                    try:
                        if "ReportArabic" not in pdfmetrics.getRegisteredFontNames():
                            pdfmetrics.registerFont(TTFont(candidate_name, candidate_path))
                        font_name = candidate_name
                        break
                    except Exception:
                        pass

            # Optional Arabic shaping if installed; PDF still works without it.
            def rtl(value):
                """Shape Arabic and apply bidi ordering for ReportLab."""
                value = "" if value is None else str(value)
                try:
                    import arabic_reshaper
                    from bidi.algorithm import get_display
                except ImportError as exc:
                    raise ImportError(
                        self.t("لإنشاء PDF عربي صحيح ثبّت: python -m pip install reportlab arabic-reshaper python-bidi")
                    ) from exc
                return get_display(arabic_reshaper.reshape(value))

            def money(value):
                try:
                    return rtl(f"{float(value or 0):,.2f} دج")
                except Exception:
                    return rtl(value)

            doc = SimpleDocTemplate(
                path,
                pagesize=A4,
                rightMargin=15 * mm,
                leftMargin=15 * mm,
                topMargin=16 * mm,
                bottomMargin=16 * mm,
                title=self.t(f"تقرير المبيعات - {period}"),
                author="Supermarket Pro",
            )

            styles = getSampleStyleSheet()
            title_style = ParagraphStyle(
                "ReportTitle",
                parent=styles["Title"],
                fontName=font_name,
                fontSize=21,
                leading=27,
                alignment=TA_RIGHT,
                wordWrap="RTL",
                spaceAfter=5 * mm,
            )
            subtitle_style = ParagraphStyle(
                "ReportSubtitle",
                parent=styles["Normal"],
                fontName=font_name,
                fontSize=12,
                leading=18,
                alignment=TA_RIGHT,
                wordWrap="RTL",
                textColor=colors.HexColor("#64748B"),
                spaceAfter=4 * mm,
            )
            section_style = ParagraphStyle(
                "ReportSection",
                parent=styles["Heading2"],
                fontName=font_name,
                fontSize=13.5,
                leading=19,
                alignment=TA_RIGHT,
                wordWrap="RTL",
                spaceBefore=4 * mm,
                spaceAfter=3 * mm,
            )
            body_style = ParagraphStyle(
                "ReportBody",
                parent=styles["BodyText"],
                fontName=font_name,
                fontSize=11.5,
                leading=17,
                alignment=TA_RIGHT,
                wordWrap="RTL",
            )
            small_style = ParagraphStyle(
                "ReportSmall",
                parent=body_style,
                fontSize=9.5,
                leading=14,
                textColor=colors.HexColor("#64748B"),
            )
            center_style = ParagraphStyle(
                "ReportCenter",
                parent=body_style,
                alignment=TA_CENTER,
                wordWrap="RTL",
            )

            story = []

            # Header
            story.append(Paragraph(rtl(self.settings.get("store_name", "Supermarket Pro")), title_style))
            story.append(Paragraph(rtl("تقرير المبيعات والأداء"), section_style))
            story.append(Paragraph(rtl(f"الفترة: {period}  •  تاريخ الإنشاء: {datetime.now().strftime('%Y-%m-%d %H:%M')}"), subtitle_style))
            story.append(HRFlowable(
                width="100%", thickness=1.2,
                color=colors.HexColor("#CBD5E1"),
                spaceBefore=1 * mm, spaceAfter=5 * mm
            ))

            # KPI cards represented as a clean 2-column table.
            kpis = [
                (rtl("إجمالي المبيعات"), money(summary["total"])),
                (rtl("عدد الفواتير"), f'{int(summary["count"] or 0):,}'),
                (rtl("متوسط الفاتورة"), money(summary["average"])),
                (rtl("أعلى فاتورة"), money(summary["max"])),
                (rtl("أقل فاتورة"), money(summary["min"])),
                (rtl("الفترة"), period),
            ]
            kpi_cells = []
            for label, value in kpis:
                kpi_cells.append([
                    Paragraph(f"<b>{value}</b>", ParagraphStyle(
                        "KpiValue", parent=body_style, fontSize=14, leading=18,
                        alignment=TA_RIGHT, textColor=colors.HexColor("#0F172A")
                    )),
                    Paragraph(label, small_style)
                ])

            kpi_rows = [kpi_cells[i:i+2] for i in range(0, len(kpi_cells), 2)]
            # Flatten each row into 4 columns: value/label, value/label
            flat_rows = []
            for row in kpi_rows:
                flat = []
                for cell in row:
                    flat.extend(cell)
                while len(flat) < 4:
                    flat.extend(["", ""])
                flat_rows.append(flat)

            kpi_table = Table(flat_rows, colWidths=[38*mm, 50*mm, 38*mm, 50*mm], rowHeights=16*mm)
            kpi_table.setStyle(TableStyle([
                ("BACKGROUND", (0,0), (-1,-1), colors.HexColor("#F8FAFC")),
                ("BOX", (0,0), (-1,-1), 0.7, colors.HexColor("#CBD5E1")),
                ("INNERGRID", (0,0), (-1,-1), 0.5, colors.HexColor("#E2E8F0")),
                ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
                ("LEFTPADDING", (0,0), (-1,-1), 6),
                ("RIGHTPADDING", (0,0), (-1,-1), 6),
                ("TOPPADDING", (0,0), (-1,-1), 5),
                ("BOTTOMPADDING", (0,0), (-1,-1), 5),
            ]))
            story.append(kpi_table)
            story.append(Spacer(1, 5 * mm))

            # Top products section.
            story.append(Paragraph(rtl("المنتجات الأكثر مبيعًا"), section_style))
            top_data = [[
                Paragraph(rtl("المنتج"), center_style),
                Paragraph(rtl("الكمية"), center_style),
                Paragraph(rtl("الإيراد"), center_style),
            ]]
            for row in top[:10]:
                name = row[0] if row else ""
                qty = row[1] if len(row) > 1 else 0
                revenue = row[2] if len(row) > 2 else 0
                top_data.append([
                    Paragraph(rtl(name), body_style),
                    Paragraph(f"{float(qty or 0):,.0f}", center_style),
                    Paragraph(money(revenue), center_style),
                ])

            if len(top_data) == 1:
                top_data.append([
                    Paragraph(rtl("لا توجد بيانات للفترة المحددة"), small_style), "", ""
                ])

            top_table = Table(top_data, colWidths=[90*mm, 30*mm, 56*mm], repeatRows=1)
            top_table.setStyle(TableStyle([
                ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#0F3D5E")),
                ("TEXTCOLOR", (0,0), (-1,0), colors.white),
                ("BOX", (0,0), (-1,-1), 0.6, colors.HexColor("#CBD5E1")),
                ("INNERGRID", (0,1), (-1,-1), 0.4, colors.HexColor("#E2E8F0")),
                ("ROWBACKGROUNDS", (0,1), (-1,-1), [
                    colors.white, colors.HexColor("#F8FAFC")
                ]),
                ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
                ("LEFTPADDING", (0,0), (-1,-1), 6),
                ("RIGHTPADDING", (0,0), (-1,-1), 6),
                ("TOPPADDING", (0,0), (-1,-1), 5),
                ("BOTTOMPADDING", (0,0), (-1,-1), 5),
            ]))
            story.append(top_table)

            # Low stock section.
            story.append(Paragraph(rtl("المخزون الذي يحتاج إلى انتباه"), section_style))
            low_data = [[
                Paragraph(rtl("المنتج"), center_style),
                Paragraph(rtl("الكمية"), center_style),
                Paragraph(rtl("الوحدة"), center_style),
            ]]
            for row in low[:15]:
                low_data.append([
                    Paragraph(rtl(row[1] if len(row) > 1 else ""), body_style),
                    Paragraph(f"{float(row[2] or 0):,.2f}", center_style),
                    Paragraph(rtl(row[3] if len(row) > 3 else ""), center_style),
                ])
            if len(low_data) == 1:
                low_data.append([
                    Paragraph(rtl("لا توجد منتجات منخفضة المخزون"), small_style), "", ""
                ])

            low_table = Table(low_data, colWidths=[90*mm, 35*mm, 51*mm], repeatRows=1)
            low_table.setStyle(TableStyle([
                ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#7C2D12")),
                ("TEXTCOLOR", (0,0), (-1,0), colors.white),
                ("BOX", (0,0), (-1,-1), 0.6, colors.HexColor("#FED7AA")),
                ("INNERGRID", (0,1), (-1,-1), 0.4, colors.HexColor("#F1F5F9")),
                ("ROWBACKGROUNDS", (0,1), (-1,-1), [
                    colors.white, colors.HexColor("#FFF7ED")
                ]),
                ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
                ("LEFTPADDING", (0,0), (-1,-1), 6),
                ("RIGHTPADDING", (0,0), (-1,-1), 6),
                ("TOPPADDING", (0,0), (-1,-1), 5),
                ("BOTTOMPADDING", (0,0), (-1,-1), 5),
            ]))
            story.append(low_table)

            # Invoice appendix on a new page.
            story.append(PageBreak())
            story.append(Paragraph(rtl("سجل الفواتير"), section_style))
            invoice_data = [[
                Paragraph(rtl("الفاتورة"), center_style),
                Paragraph(rtl("الإجمالي"), center_style),
                Paragraph(rtl("الخصم"), center_style),
                Paragraph(rtl("المدفوع"), center_style),
                Paragraph(rtl("التاريخ"), center_style),
            ]]

            for row in sales[:40]:
                invoice_no = row[1] if len(row) > 1 else ""
                total = row[3] if len(row) > 3 else 0
                discount = row[4] if len(row) > 4 else 0
                paid = row[5] if len(row) > 5 else 0
                date_value = row[6] if len(row) > 6 else ""
                invoice_data.append([
                    Paragraph(rtl(invoice_no), small_style),
                    Paragraph(money(total), center_style),
                    Paragraph(money(discount), center_style),
                    Paragraph(money(paid), center_style),
                    Paragraph(rtl(date_value), small_style),
                ])

            if len(invoice_data) == 1:
                invoice_data.append([
                    Paragraph(rtl("لا توجد فواتير للفترة المحددة"), small_style), "", "", "", ""
                ])

            invoice_table = Table(
                invoice_data,
                colWidths=[45*mm, 32*mm, 30*mm, 32*mm, 37*mm],
                repeatRows=1
            )
            invoice_table.setStyle(TableStyle([
                ("BACKGROUND", (0,0), (-1,0), colors.HexColor("#334155")),
                ("TEXTCOLOR", (0,0), (-1,0), colors.white),
                ("BOX", (0,0), (-1,-1), 0.6, colors.HexColor("#CBD5E1")),
                ("INNERGRID", (0,1), (-1,-1), 0.35, colors.HexColor("#E2E8F0")),
                ("ROWBACKGROUNDS", (0,1), (-1,-1), [
                    colors.white, colors.HexColor("#F8FAFC")
                ]),
                ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
                ("LEFTPADDING", (0,0), (-1,-1), 4),
                ("RIGHTPADDING", (0,0), (-1,-1), 4),
                ("TOPPADDING", (0,0), (-1,-1), 4),
                ("BOTTOMPADDING", (0,0), (-1,-1), 4),
            ]))
            story.append(invoice_table)

            def footer(canvas_obj, doc_obj):
                canvas_obj.saveState()
                canvas_obj.setFont(font_name, 8)
                canvas_obj.setFillColor(colors.HexColor("#64748B"))
                canvas_obj.drawString(15*mm, 9*mm, "Supermarket Pro")
                canvas_obj.drawRightString(
                    A4[0] - 15*mm, 9*mm,
                    f"{doc_obj.page}"
                )
                canvas_obj.restoreState()

            doc.build(story, onFirstPage=footer, onLaterPages=footer)
            self.toast(f"تم إنشاء تقرير PDF احترافي:\n{path}", "success")

        except ImportError:
            message = (
                "مكتبة PDF غير موجودة.\n\n"
                "ثبّت ReportLab في نفس Python المستخدم لتشغيل البرنامج:\n\n"
                "python -m pip install reportlab arabic-reshaper python-bidi"

                "ويُفضّل تثبيت الحزم الثلاث للحصول على العربية المتصلة والاتجاه الصحيح في PDF."
            )
            try:
                self.toast(message, "error")
            except Exception:
                from tkinter import messagebox
                messagebox.showerror(self.t("مكتبة PDF غير موجودة"), self.t(message))
        except Exception as exc:
            message = f"تعذر إنشاء ملف PDF:\n{exc}"
            try:
                self.toast(message, "error")
            except Exception:
                from tkinter import messagebox
                messagebox.showerror(self.t("خطأ في PDF"), self.t(message))

    # =========================================================
    # Expenses Management Page
    # =========================================================

    def show_expenses(self):
        if not self._guard_db_nav("المصاريف والفواتير", "تسجيل وعرض المصاريف التشغيلية", "expenses"):
            return
        self.clear_content()
        self.current_page = "expenses"
        self.highlight_nav()

        self.page_header("💸 المصاريف والفواتير", "تسجيل ومتابعة المصاريف التشغيلية")

        action_bar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        action_bar.pack(fill="x", pady=(0, 10))
        ctk.CTkButton(
            action_bar, text=self.t("＋ تسجيل مصروف جديد"), command=self._add_expense_dialog,
            height=38, width=180, corner_radius=9,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side="right")

        scroll = ctk.CTkScrollableFrame(self.content_area, fg_color="transparent")
        scroll.pack(fill="both", expand=True)

        is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"
        dev = None if is_server else self._get_device_name()
        try:
            expenses = self.db.get_expenses(start_date=None, end_date=None, device_name=dev)
        except Exception:
            expenses = []

        total_all = sum(float(e[3] or 0) for e in expenses)
        total_drawer = sum(float(e[3] or 0) for e in expenses if e[4] == 1)
        total_external = total_all - total_drawer

        summary_card = self.make_card(scroll)
        summary_card.pack(fill="x", pady=(0, 10))
        sum_hdr = ctk.CTkFrame(summary_card, fg_color="transparent")
        sum_hdr.pack(fill="x", padx=16, pady=(14, 8))
        ctk.CTkLabel(sum_hdr, text=self.t("📊 ملخص المصاريف"), font=ctk.CTkFont(family=self.ui_font_family, size=15, weight="bold"), text_color=self.text()).pack(side="right")
        sum_bar = ctk.CTkFrame(summary_card, fg_color=self.bg(), corner_radius=10)
        sum_bar.pack(fill="x", padx=14, pady=(0, 14))
        sum_metrics = [
            (self.t("إجمالي المصاريف"), f"{total_all:,.0f} دج"),
            (self.t("من الصندوق (نقد)"), f"{total_drawer:,.0f} دج"),
            (self.t("سُدد خارجيًا"), f"{total_external:,.0f} دج"),
            (self.t("عدد المصروفات"), f"{len(expenses)}"),
        ]
        for i, (lbl, val) in enumerate(sum_metrics):
            sum_bar.grid_columnconfigure(i, weight=1)
            cell = ctk.CTkFrame(sum_bar, fg_color="transparent")
            cell.grid(row=0, column=i, sticky="nsew", padx=8, pady=12)
            ctk.CTkLabel(cell, text=lbl, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(anchor="e")
            ctk.CTkLabel(cell, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"), text_color=self.text()).pack(anchor="e", pady=(3, 0))

        table_card = self.make_card(scroll)
        table_card.pack(fill="x", pady=(0, 10))

        hdr = ctk.CTkFrame(table_card, fg_color=self.card(), corner_radius=8)
        hdr.pack(fill="x", padx=14, pady=(14, 3))
        cols = ["#", self.t("العنوان"), self.t("الفئة"), self.t("المبلغ"), self.t("الدفع"), self.t("الجهاز"), self.t("التاريخ"), self.t("ملاحظة"), self.t("حذف")]
        weights = [0, 3, 2, 2, 1, 1, 2, 2, 1]
        for ci, txt in enumerate(cols):
            hdr.grid_columnconfigure(ci, weight=weights[ci])
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=6, pady=7)

        def _refresh():
            for w in table_card.winfo_children()[1:]:
                w.destroy()
            dev2 = None if is_server else self._get_device_name()
            try:
                exps = self.db.get_expenses(start_date=None, end_date=None, device_name=dev2)
            except Exception:
                exps = []
            if not exps:
                ctk.CTkLabel(table_card, text=self.t("لا توجد مصاريف مسجلة"), font=ctk.CTkFont(family=self.ui_font_family, size=12), text_color=self.muted()).pack(pady=25)
                return
            for ri, exp in enumerate(exps):
                eid, title, cat, amt, drawer, devn, edate, note = exp
                rw = ctk.CTkFrame(table_card, fg_color=self.bg() if ri % 2 == 0 else self.card(), corner_radius=7)
                rw.pack(fill="x", padx=14, pady=1)
                vals = [str(eid), str(title or "")[:30], str(cat or ""), f"{float(amt or 0):,.0f}", self.t("نقدًا من الصندوق") if drawer == 1 else self.t("سُدد خارجيًا"), str(devn or ""), str(edate or "")[:16], str(note or "")[:25]]
                for ci, val in enumerate(vals):
                    rw.grid_columnconfigure(ci, weight=weights[ci])
                    ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.text(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=6, pady=6)
                del_btn = ctk.CTkButton(rw, text="🗑", width=30, height=28, corner_radius=6, fg_color="transparent", hover_color=self.colors["danger"], text_color=self.colors["danger"], font=ctk.CTkFont(size=13), command=lambda eid2=eid: self._delete_expense_and_refresh(eid2, _refresh))
                del_btn.grid(row=0, column=len(vals), padx=4, pady=4)

        _refresh()

    def _add_expense_dialog(self):
        win = ctk.CTkToplevel(self)
        win.title(self.t("تسجيل مصروف جديد"))
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 480, 520)

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=16, pady=16)

        ctk.CTkFrame(card, fg_color=self.colors["primary"], height=5, corner_radius=0).pack(fill="x")
        ctk.CTkLabel(card, text=self.t("💸 تسجيل مصروف جديد"), font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold"), text_color=self.colors["primary"]).pack(pady=(16, 4))

        fields_frame = ctk.CTkFrame(card, fg_color="transparent")
        fields_frame.pack(fill="x", padx=20, pady=(10, 0))

        ctk.CTkLabel(fields_frame, text=self.t("بيان أو عنوان المصروف *"), anchor=self.align(), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.muted()).pack(anchor=self.align(), fill="x")
        title_entry = ctk.CTkEntry(fields_frame, height=36, placeholder_text=self.t("مثال: فاتورة الكهرباء - شهر سبتمبر"), font=ctk.CTkFont(family=self.ui_font_family, size=11))
        title_entry.pack(fill="x", pady=(2, 8))

        ctk.CTkLabel(fields_frame, text=self.t("فئة المصروف"), anchor=self.align(), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.muted()).pack(anchor=self.align(), fill="x")
        _exp_cats = [self.t("كهرباء/ماء"), self.t("إيجار"), self.t("رواتب"), self.t("مستلزمات"), self.t("صيانة"), self.t("أخرى")]
        category_var = tk.StringVar(value=_exp_cats[0])
        ctk.CTkOptionMenu(fields_frame, variable=category_var, values=_exp_cats, height=34).pack(fill="x", pady=(2, 8))

        ctk.CTkLabel(fields_frame, text=self.t("المبلغ المطلوب دفعه (د.ج) *"), anchor=self.align(), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.muted()).pack(anchor=self.align(), fill="x")
        amount_entry = ctk.CTkEntry(fields_frame, height=36, placeholder_text=self.t("مثال: 15000"), font=ctk.CTkFont(family=self.ui_font_family, size=11))
        amount_entry.pack(fill="x", pady=(2, 8))

        drawer_var = tk.BooleanVar(value=True)
        ctk.CTkCheckBox(fields_frame, text=self.t("يُدفع من الصندوق (نقدًا)"), variable=drawer_var, font=ctk.CTkFont(family=self.ui_font_family, size=11), text_color=self.text()).pack(anchor=self.align(), pady=(2, 8))

        ctk.CTkLabel(fields_frame, text=self.t("ملاحظات إضافية (اختياري)"), anchor=self.align(), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.muted()).pack(anchor=self.align(), fill="x")
        note_entry = ctk.CTkEntry(fields_frame, height=36, placeholder_text=self.t("أدخل أي تفاصيل إضافية هنا..."), font=ctk.CTkFont(family=self.ui_font_family, size=11))
        note_entry.pack(fill="x", pady=(2, 8))

        def _save():
            t = title_entry.get().strip()
            amt_s = amount_entry.get().strip()
            if not t:
                self.toast("أدخل عنوان المصروف", "warning")
                return
            try:
                amt = float(amt_s)
                if amt <= 0:
                    raise ValueError
            except Exception:
                self.toast("أدخل مبلغ صحيح أكبر من صفر", "warning")
                return
            cat = self._to_ar(category_var.get())
            note = note_entry.get().strip()
            paid = 1 if drawer_var.get() else 0
            result = self.db.add_expense(title=t, category=cat, amount=amt, paid_from_drawer=paid, device_name=self._get_device_name(), note=note)
            if isinstance(result, tuple):
                ok = result[0]
            else:
                ok = bool(result)
            if ok:
                self.toast("تم تسجيل المصروف بنجاح", "success")
                win.destroy()
                self.show_expenses()
            else:
                self.toast("تعذر حفظ المصروف", "danger")

        ctk.CTkButton(card, text=self.t("💾 حفظ المصروف"), command=_save, height=40, corner_radius=9, fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"], text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")).pack(pady=(12, 10), fill="x", padx=20)

    def _delete_expense_and_refresh(self, expense_id, refresh_fn):
        if not self.confirm("حذف مصروف", f"هل تريد حذف المصروف رقم {expense_id}؟"):
            return
        if self.db.delete_expense(expense_id):
            self.toast("تم الحذف بنجاح", "success")
            refresh_fn()
        else:
            self.toast("تعذر الحذف", "danger")

    # =========================================================
    # Reports Dashboard (Comprehensive)
    # =========================================================

    def show_reports(self):
        if not self._guard_db_nav("التقارير", "إحصائيات المبيعات والربح", "reports"):
            return
        self.clear_content()
        self.current_page = "reports"
        self.highlight_nav()

        self.page_header("التقارير والإحصائيات", "تحليل شامل للمبيعات والأرباح والمصاريف")

        ctrl_bar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        ctrl_bar.pack(fill="x", pady=(0, 10))

        self._report_period_var = tk.StringVar(value="today")
        self._report_custom_start = tk.StringVar(value="")
        self._report_custom_end = tk.StringVar(value="")
        self.active_report_period = "today"

        periods_frame = ctk.CTkFrame(ctrl_bar, fg_color="transparent")
        periods_frame.pack(side="right")
        self.report_period_buttons = {}
        periods = [
            ("today", self.t("اليوم")),
            ("yesterday", self.t("البارحة")),
            ("week", self.t("آخر 7 أيام")),
            ("month", self.t("هذا الشهر")),
            ("custom", self.t("مخصص")),
        ]
        for period_key, text in periods:
            is_active = period_key == self.active_report_period
            btn = ctk.CTkButton(
                periods_frame, text=text, height=34, width=90, corner_radius=8,
                font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                fg_color=self.colors["primary"] if is_active else self.card(),
                hover_color=self.colors["primary_hover"] if is_active else self.border(),
                text_color="white" if is_active else self.text(),
                command=lambda p=period_key: self._on_report_period_click(p)
            )
            btn.pack(side="right", padx=2)
            self.report_period_buttons[period_key] = btn

        self._report_custom_frame = ctk.CTkFrame(ctrl_bar, fg_color="transparent")
        self._report_custom_frame.pack(side="right", padx=(10, 0))
        self._report_custom_start.set("")
        self._report_custom_end.set("")
        ctk.CTkLabel(self._report_custom_frame, text=self.t("من:"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(side="right", padx=(0, 3))
        self._report_start_entry = ctk.CTkEntry(self._report_custom_frame, width=110, height=30, placeholder_text="YYYY-MM-DD", font=ctk.CTkFont(family=self.ui_font_family, size=10))
        self._report_start_entry.pack(side="right", padx=(0, 6))
        ctk.CTkLabel(self._report_custom_frame, text=self.t("إلى:"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(side="right", padx=(0, 3))
        self._report_end_entry = ctk.CTkEntry(self._report_custom_frame, width=110, height=30, placeholder_text="YYYY-MM-DD", font=ctk.CTkFont(family=self.ui_font_family, size=10))
        self._report_end_entry.pack(side="right", padx=(0, 6))
        self._report_custom_frame.pack_forget()

        is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"
        self._report_dev_var = tk.StringVar(value="all")
        if is_server:
            try:
                dev_names = self.db.get_all_sales_devices()
            except Exception:
                dev_names = []
            opts = [self.t("كل الأجهزة")] + dev_names
            ctk.CTkLabel(ctrl_bar, text=self.t("الجهاز:"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(side="left", padx=(0, 5))
            ctk.CTkOptionMenu(ctrl_bar, values=opts, variable=self._report_dev_var, width=140, font=ctk.CTkFont(family=self.ui_font_family, size=10)).pack(side="left")
        else:
            dev_locked = self._get_device_name()
            self._report_dev_var.set(dev_locked)
            ctk.CTkLabel(ctrl_bar, text=f"🔒 {dev_locked}", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted()).pack(side="left", padx=(0, 5))

        ctk.CTkButton(
            ctrl_bar, text=self.t("⟳ تحديث البيانات"), height=34, width=120, corner_radius=8,
            fg_color=self.colors["secondary"], hover_color=self.colors["secondary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=lambda: self._on_report_period_click(self._report_period_var.get())
        ).pack(side="left", padx=5)

        self._export_report_btn = ctk.CTkButton(
            ctrl_bar, text=self.t("📥 تصدير التقرير"), height=34, width=140, corner_radius=8,
            fg_color="transparent", hover_color=self.colors["primary_hover"],
            text_color=self.colors["primary"], border_width=1, border_color=self.colors["primary"],
            font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
            command=self._show_export_dropdown
        )
        self._export_report_btn.pack(side="left", padx=(2, 5))

        self.report_container = ctk.CTkScrollableFrame(self.content_area, fg_color="transparent")
        self.report_container.pack(fill="both", expand=True)

        self._on_report_period_click("today")

    def _on_report_period_click(self, period_key):
        self._report_period_var.set(period_key)
        self.active_report_period = period_key
        for p_key, btn in getattr(self, "report_period_buttons", {}).items():
            is_active = p_key == period_key
            btn.configure(
                fg_color=self.colors["primary"] if is_active else self.card(),
                hover_color=self.colors["primary_hover"] if is_active else self.border(),
                text_color="white" if is_active else self.text(),
                border_width=0 if is_active else 1,
                border_color=self.colors["primary"] if is_active else self.border()
            )
        if period_key == "custom":
            self._report_custom_frame.pack(side="right", padx=(10, 0))
        else:
            self._report_custom_frame.pack_forget()
        self._refresh_reports_dashboard()

    def _refresh_reports_dashboard(self):
        for widget in self.report_container.winfo_children():
            widget.destroy()

        period = self._report_period_var.get()
        if period == "custom":
            s = self._report_start_entry.get().strip()
            e = self._report_end_entry.get().strip()
            if not s or not e:
                ctk.CTkLabel(self.report_container, text=self.t("أدخل تاريخ البداية والنهاية"), font=ctk.CTkFont(family=self.ui_font_family, size=13), text_color=self.muted()).pack(pady=40)
                return
            dates = (s, e)
        else:
            dates = period

        dev_val = self._report_dev_var.get()
        dev = None if dev_val in ("all", self.t("كل الأجهزة"), "") else dev_val

        try:
            report = self.reports_manager.get_full_report(period_or_dates=dates, device_name=dev)
        except Exception as exc:
            self.toast(f"خطأ في تحميل التقرير: {exc}", "danger")
            return
        self._last_report_snapshot = report
        self._last_report_dates = dates
        self._last_report_device = dev

        fin = report.get("financial", {})
        container = self.report_container

        # --- 4 KPI Cards ---
        kpi = ctk.CTkFrame(container, fg_color="transparent")
        kpi.pack(fill="x", pady=(0, 10))

        gross = float(fin.get("gross_sales", 0))
        net = float(fin.get("net_sales", 0))
        cogs_val = float(fin.get("cogs", 0))
        net_profit = float(fin.get("net_profit", 0))
        margin = float(fin.get("profit_margin_pct", 0))
        inv_count = int(fin.get("invoice_count", 0))
        expenses_total = float(fin.get("expenses_total", 0))

        kpi_cards = [
            ("💰", self.t("إجمالي المبيعات"), self.t(f"{gross:,.0f} دج"), self.colors["primary"]),
            ("🧾", self.t("صافي المداخيل"), self.t(f"{net:,.0f} دج\n{inv_count} فاتورة"), self.colors["secondary"]),
            ("📦", self.t("تكلفة السلع المباعة"), self.t(f"{cogs_val:,.0f} دج"), self.colors["accent"]),
            ("🏆", self.t("صافي الربح"), self.t(f"{net_profit:,.0f} دج"), self.colors["primary"]),
        ]
        for i, (icon, label, value, accent) in enumerate(kpi_cards):
            kpi.grid_columnconfigure(i, weight=1)
            card = self.make_card(kpi)
            card.grid(row=0, column=i, sticky="nsew", padx=5)
            ctk.CTkFrame(card, height=4, fg_color=accent, corner_radius=2).pack(fill="x", padx=12, pady=(0, 6))
            ctk.CTkLabel(card, text=icon, font=ctk.CTkFont(family=self.ui_font_family, size=22)).pack(anchor="e", padx=14)
            ctk.CTkLabel(card, text=value, font=ctk.CTkFont(family=self.ui_font_family, size=15, weight="bold"), text_color=self.text()).pack(anchor="e", padx=14, pady=(2, 0))
            ctk.CTkLabel(card, text=label, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(anchor="e", padx=14, pady=(2, 8))

        if kpi_cards:
            last_card_kids = kpi.grid_slaves(row=0, column=3)
            if last_card_kids:
                sub = ctk.CTkLabel(
                    last_card_kids[0],
                    text=self.t(f"المصاريف: {expenses_total:,.0f} دج • هامش الربح {margin:.1f}%"),
                    font=ctk.CTkFont(family=self.ui_font_family, size=9), text_color=self.muted()
                )
                sub.pack(anchor="e", padx=14, pady=(0, 8))

        # --- Daily / Hourly Trend Interactive Line Chart ---
        self._render_trend_panel(container, report)

        # --- Cash Drawer Reconciliation Strip ---
        drawer_card = self.make_card(container)
        drawer_card.pack(fill="x", pady=(0, 10))
        ctk.CTkLabel(drawer_card, text=self.t("💵 تسوية الصندوق النقدي"), font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"), text_color=self.text()).pack(anchor="e", padx=16, pady=(12, 6))

        debt_coll = float(report.get("debt_collected", 0) or 0)
        paid_cash = float(fin.get("paid_cash", 0))
        outstanding = float(fin.get("outstanding_debt", 0))
        returns_t = float(fin.get("returns_total", 0))
        exp_drawer = float(fin.get("expenses_drawer", 0))

        strip = ctk.CTkFrame(drawer_card, fg_color=self.bg(), corner_radius=10)
        strip.pack(fill="x", padx=14, pady=(0, 14))
        strip_items = [
            (self.t("نقدي بالصندوق"), self.t(f"{paid_cash:,.0f} دج")),
            (self.t("مبيعات بالدين"), self.t(f"{outstanding:,.0f} دج")),
            (self.t("ديون محصلة"), self.t(f"{debt_coll:,.0f} دج")),
            (self.t("مرتجعات نقدية"), self.t(f"{returns_t:,.0f} دج")),
            (self.t("مصاريف من الصندوق"), self.t(f"{exp_drawer:,.0f} دج")),
        ]
        for i, (lbl, val) in enumerate(strip_items):
            strip.grid_columnconfigure(i, weight=1)
            cell = ctk.CTkFrame(strip, fg_color="transparent")
            cell.grid(row=0, column=i, sticky="nsew", padx=8, pady=10)
            ctk.CTkLabel(cell, text=lbl, font=ctk.CTkFont(family=self.ui_font_family, size=9), text_color=self.muted()).pack(anchor="e")
            ctk.CTkLabel(cell, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"), text_color=self.text()).pack(anchor="e", pady=(2, 0))

        # --- Interactive Tabview ---
        tabs = ctk.CTkTabview(
            container,
            height=500,
            fg_color=self.card(),
            corner_radius=16,
            border_width=1,
            border_color=self.border(),
            segmented_button_fg_color=self.bg(),
            segmented_button_selected_color=self.colors["primary"],
            segmented_button_selected_hover_color=self.colors["primary_hover"],
            text_color=self.text()
        )
        try:
            tabs._segmented_button.configure(font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"))
        except Exception:
            pass
        tabs.pack(fill="both", expand=True, padx=4, pady=(10, 20))

        # Tab 1: Top Products
        tab1 = tabs.add(self.t("🏆 أفضل المنتجات"))
        self._render_top_products_tab(tab1, report)

        # Tab 2: Peak Hours & Crowd Prediction
        tab2 = tabs.add(self.t("🕒 أوقات الذروة وتوقع الازدحام"))
        self._render_peak_hours_tab(tab2)

        # Tab 3: Slow Moving Products
        tab3 = tabs.add(self.t("📦 المنتجات الراكدة"))
        self._render_slow_moving_tab(tab3, report)

        # Tab 4: Device Breakdown
        tab4 = tabs.add(self.t("🖥️ توزيع الأجهزة"))
        self._render_device_breakdown_tab(tab4, report)

        # Tab 5: Returns & Voids
        tab5 = tabs.add(self.t("↩️ المرتجعات والإلغاء"))
        self._render_returns_voids_tab(tab5, report)

        # Tab 6: Expenses
        tab6 = tabs.add(self.t("💸 المصاريف والفواتير"))
        self._render_expenses_tab(tab6, report)

        # Tab 7: Profit Breakdown (deep-dive analytics)
        tab7 = tabs.add(self.t("📊 الأرباح التفصيلية"))
        self._render_profit_tab(tab7, report)

    # ---------------------------------------------------------
    # Export Feature (Excel / CSV / Z-Report Shift PDF)
    # ---------------------------------------------------------

    def _show_export_dropdown(self, *_a):
        """القائمة المنسدلة لتصدير التقرير النشط."""
        menu = tk.Menu(self, tearoff=0)
        menu.add_command(label=self.t("تصدير Excel (xlsx)"), command=self._export_active_report_excel)
        menu.add_command(label=self.t("تصدير CSV (UTF-8)"), command=self._export_active_report_csv)
        menu.add_separator()
        menu.add_command(label=self.t("طباعة تقرير نهاية الوردية"), command=self._export_shift_report_pdf)
        try:
            x = self.winfo_rootx() + 40
            y = self.winfo_rooty() + 60
            if hasattr(self, "_export_report_btn"):
                x = self._export_report_btn.winfo_rootx()
                y = self._export_report_btn.winfo_rooty() + self._export_report_btn.winfo_height()
            menu.tk_popup(x, y)
        finally:
            try:
                menu.grab_release()
            except Exception:
                pass

    def _active_report_dates(self):
        """تاريخا التقرير النشط حسب الفترة المختارة."""
        var = getattr(self, "_report_period_var", None)
        if var is not None:
            val = var.get()
            if val == "custom":
                try:
                    s = self._report_start_entry.get().strip()
                    e = self._report_end_entry.get().strip()
                    if s and e:
                        return (s, e)
                except Exception:
                    pass
            else:
                return val
        return "today"

    def _report_period_save_name(self):
        var = getattr(self, "_report_period_var", None)
        val = var.get() if var is not None else "today"
        names = {
            "today": self.t("اليوم"),
            "yesterday": self.t("البارحة"),
            "week": self.t("آخر_7_أيام"),
            "month": self.t("هذا_الشهر"),
            "custom": self.t("مخصص"),
        }
        return names.get(val, "اليوم")

    def _build_active_report(self):
        """بناء تقرير شامل من فترة + جهاز التقرير النشط حاليًا."""
        try:
            dates = self._active_report_dates()
        except Exception:
            dates = "today"
        dev = None
        dvar = getattr(self, "_report_dev_var", None)
        if dvar is not None:
            try:
                dv = dvar.get()
                if dv not in ("all", self.t("كل الأجهزة"), ""):
                    dev = dv
            except Exception:
                pass
        return self.reports_manager.get_full_report(period_or_dates=dates, device_name=dev)

    def _export_active_report_csv(self):
        """تصدير التقرير النشط كـ CSV بترميز UTF-8-BOM لعرض عربي سليم في Excel."""
        try:
            report = self._build_active_report()
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")
            return

        default_name = f"{self.t('تقرير_المبيعات_المفصل')}_{self._report_period_save_name()}"
        path = filedialog.asksaveasfilename(
            title=self.t("حفظ تقرير CSV"),
            defaultextension=".csv",
            initialfile=default_name + ".csv",
            filetypes=[("CSV files", "*.csv"), ("All files", "*.*")]
        )
        if not path:
            return

        try:
            import csv
            fin = report.get("financial", {}) or {}

            def money(v):
                return f"{float(v or 0):,.2f}"

            paid_cash = float(fin.get("paid_cash", 0))
            outstanding = float(fin.get("outstanding_debt", 0))
            returns_t = float(fin.get("returns_total", 0))
            exp_drawer = float(fin.get("expenses_drawer", 0))
            debt_coll = float(report.get("debt_collected", 0) or 0)
            final_drawer = paid_cash - exp_drawer - returns_t

            with open(path, "w", newline="", encoding="utf-8-sig") as f:
                w = csv.writer(f)
                w.writerow([self.t("تفريغ البيانات المالية"), self._report_period_save_name()])
                w.writerow([])
                w.writerow([self.t("إجمالي المبيعات"), money(fin.get("gross_sales"))])
                w.writerow([self.t("خصومات"), money(fin.get("discounts"))])
                w.writerow([self.t("المرتجعات"), money(returns_t)])
                w.writerow([self.t("صافي المداخيل"), money(fin.get("net_sales"))])
                w.writerow([self.t("تكلفة السلع المباعة"), money(fin.get("cogs"))])
                w.writerow([self.t("صافي الربح"), money(fin.get("net_profit"))])
                w.writerow([self.t("الهامش"), f"{float(fin.get('profit_margin_pct', 0) or 0):.2f}%"])
                w.writerow([self.t("عدد الفواتير"), fin.get("invoice_count", 0)])
                w.writerow([self.t("العدد"), fin.get("items_sold", 0)])
                w.writerow([self.t("المصاريف"), money(fin.get("expenses_total"))])
                w.writerow([])

                w.writerow([self.t("تسوية الصندوق النقدي")])
                w.writerow([self.t("النقد المحصل"), money(paid_cash)])
                w.writerow([self.t("مبيعات بالدين"), money(outstanding)])
                w.writerow([self.t("ديون محصلة"), money(debt_coll)])
                w.writerow([self.t("المرتجعات"), money(returns_t)])
                w.writerow([self.t("المصاريف"), money(exp_drawer)])
                w.writerow([self.t("الصافي النقدي في الصندوق"), money(final_drawer)])
                w.writerow([])

                top = report.get("top_products", []) or []
                w.writerow([self.t("أفضل المنتجات مبيعاً")])
                w.writerow([self.t("المنتج"), self.t("الكمية"), self.t("الإيراد"), self.t("التكلفة"), self.t("صافي الربح")])
                for row in top[:100]:
                    w.writerow([row[1], f"{float(row[2] or 0):,.2f}", f"{float(row[3] or 0):,.2f}",
                                f"{float(row[4] or 0):,.2f}", f"{float(row[5] or 0):,.2f}"])
                w.writerow([])

                exps = report.get("expenses", []) or []
                w.writerow([self.t("قائمة المصاريف")])
                w.writerow([self.t("العنوان"), self.t("الفئة"), self.t("المبلغ"), self.t("الدفع"),
                            self.t("الجهاز"), self.t("التاريخ"), self.t("ملاحظة")])
                for e in exps:
                    w.writerow([e[1], e[2], money(e[3]), "نقدًا" if e[4] == 1 else "خارجي",
                                e[5], str(e[6] or "")[:16], e[7]])
                w.writerow([])

                w.writerow([self.t("فواتير المرتجعات والإلغاء")])
                rets = report.get("returns", []) or []
                if rets:
                    w.writerow([self.t("المرتجعات")])
                    w.writerow([self.t("رقم الفاتورة"), self.t("المبلغ"), self.t("الجهاز"), self.t("التاريخ")])
                    for r in rets[:200]:
                        w.writerow([r[1], money(r[4]), r[5], str(r[6] or "")[:16]])
                voided = report.get("voided", []) or []
                if voided:
                    w.writerow([self.t("الفواتير الملغاة")])
                    w.writerow([self.t("رقم الفاتورة"), self.t("الجهاز"), self.t("التاريخ")])
                    for v in voided[:100]:
                        w.writerow([v[1], v[3], str(v[2] or "")[:16]])

            self.toast(f"{self.t('تم تصدير التقرير بنجاح')}\n{path}", "success")
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")

    def _export_active_report_excel(self):
        """تصدير التقرير النشط كملف Excel متعدد الأقسام."""
        try:
            from openpyxl import Workbook
            from openpyxl.styles import Font, Alignment, PatternFill
        except ImportError:
            self.toast(self.t("يحتاج تثبيت المكتبة") + ": openpyxl", "danger")
            return

        try:
            report = self._build_active_report()
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")
            return

        default_name = f"{self.t('تقرير_المبيعات_المفصل')}_{self._report_period_save_name()}"
        path = filedialog.asksaveasfilename(
            title=self.t("حفظ تقرير Excel"),
            defaultextension=".xlsx",
            initialfile=default_name + ".xlsx",
            filetypes=[("Excel", "*.xlsx")]
        )
        if not path:
            return

        fin = report.get("financial", {}) or {}
        bold = Font(bold=True)
        head_fill = PatternFill("solid", fgColor="6366F1")
        head_font = Font(bold=True, color="FFFFFF")

        def money(v):
            return float(v or 0)

        try:
            wb = Workbook()

            def write_table(ws, title, headers, rows):
                ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=max(len(headers), 3))
                ws.cell(row=1, column=1, value=title).font = Font(bold=True, size=13, color="6366F1")
                for ci, h in enumerate(headers, start=1):
                    c = ws.cell(row=2, column=ci, value=h)
                    c.fill = head_fill
                    c.font = head_font
                    c.alignment = Alignment(horizontal="center")
                for ri, row in enumerate(rows, start=3):
                    for ci, val in enumerate(row, start=1):
                        ws.cell(row=ri, column=ci, value=val)

            # -- Sheet 1: Financial summary + drawer reconciliation
            ws1 = wb.active
            ws1.title = self.t("تفريغ البيانات المالية")
            paid_cash = money(fin.get("paid_cash"))
            outstanding = money(fin.get("outstanding_debt"))
            returns_t = money(fin.get("returns_total"))
            exp_drawer = money(fin.get("expenses_drawer"))
            debt_coll = money(report.get("debt_collected"))
            final_drawer = paid_cash - exp_drawer - returns_t
            fin_rows = [
                [self.t("إجمالي المبيعات"), money(fin.get("gross_sales"))],
                [self.t("خصومات"), money(fin.get("discounts"))],
                [self.t("المرتجعات"), returns_t],
                [self.t("صافي المداخيل"), money(fin.get("net_sales"))],
                [self.t("تكلفة السلع المباعة"), money(fin.get("cogs"))],
                [self.t("صافي الربح"), money(fin.get("net_profit"))],
                [self.t("الهامش"), f"{float(fin.get('profit_margin_pct', 0) or 0):.2f}%"],
                [self.t("عدد الفواتير"), fin.get("invoice_count", 0)],
                [self.t("العدد"), fin.get("items_sold", 0)],
                [self.t("المصاريف"), money(fin.get("expenses_total"))],
            ]
            write_table(ws1, self.t("تفريغ البيانات المالية"), [self.t("المؤشر"), self.t("القيمة")], fin_rows)

            ws1.merge_cells(start_row=14, start_column=1, end_row=14, end_column=3)
            ws1.cell(row=14, column=1, value=self.t("تسوية الصندوق النقدي")).font = Font(bold=True, size=13, color="22C55E")
            drawer_rows = [
                [self.t("النقد المحصل"), paid_cash],
                [self.t("مبيعات بالدين"), outstanding],
                [self.t("ديون محصلة"), debt_coll],
                [self.t("المرتجعات"), returns_t],
                [self.t("المصاريف"), exp_drawer],
                [self.t("الصافي النقدي في الصندوق"), final_drawer],
            ]
            for ri, row in enumerate(drawer_rows, start=15):
                ws1.cell(row=ri, column=1, value=row[0]).font = bold
                ws1.cell(row=ri, column=2, value=row[1])

            # -- Sheet 2: Top products
            ws2 = wb.create_sheet(self.t("أفضل المنتجات مبيعاً"))
            top = report.get("top_products", []) or []
            write_table(ws2, self.t("أفضل المنتجات مبيعاً"),
                        [self.t("المنتج"), self.t("الكمية"), self.t("الإيراد"), self.t("التكلفة"), self.t("صافي الربح")],
                        [[r[1], r[2], r[3], r[4], r[5]] for r in top[:200]])

            # -- Sheet 3: Expenses
            ws3 = wb.create_sheet(self.t("قائمة المصاريف"))
            exps = report.get("expenses", []) or []
            write_table(ws3, self.t("قائمة المصاريف"),
                        [self.t("العنوان"), self.t("الفئة"), self.t("المبلغ"), self.t("الدفع"),
                         self.t("الجهاز"), self.t("التاريخ"), self.t("ملاحظة")],
                        [[e[1], e[2], e[3], "نقدًا" if e[4] == 1 else "خارجي",
                          e[5], str(e[6] or "")[:16], e[7]] for e in exps])

            # -- Sheet 4: Returns & Voided
            ws4 = wb.create_sheet(self.t("فواتير المرتجعات والإلغاء"))
            rets = report.get("returns", []) or []
            voided = report.get("voided", []) or []
            ret_rows = [[self.t("المرتجعات")]] + \
                [[r[1], r[4], r[5], str(r[6] or "")[:16]] for r in rets[:200]]
            void_rows = [[self.t("الفواتير الملغاة")]] + \
                [[v[1], v[3], str(v[2] or "")[:16]] for v in voided[:100]]
            ws4.merge_cells("A1:D1")
            ws4.cell(row=1, column=1, value=self.t("فواتير المرتجعات والإلغاء")).font = Font(bold=True, size=13, color="F43F5E")
            write_table(ws4, self.t("المرتجعات"),
                        [self.t("رقم الفاتورة"), self.t("المبلغ"), self.t("الجهاز"), self.t("التاريخ")],
                        ret_rows[1:])
            base = 3 + len(ret_rows[1:]) + 2
            ws4.merge_cells(start_row=base, start_column=1, end_row=base, end_column=3)
            ws4.cell(row=base, column=1, value=self.t("الفواتير الملغاة")).font = Font(bold=True, size=12, color="F43F5E")
            for ri, row in enumerate(void_rows[1:], start=base + 1):
                ws4.cell(row=ri, column=1, value=row[0]).font = bold
                ws4.cell(row=ri, column=2, value=row[1])
                ws4.cell(row=ri, column=3, value=row[2])

            wb.save(path)
            self.toast(f"{self.t('تم تصدير التقرير بنجاح')}\n{path}", "success")
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")

    def _export_shift_report_pdf(self):
        """طباعة تقرير نهاية الوردية (Z-Report) بصيغة PDF حراري 80mm أو A4."""
        try:
            thermal = messagebox.askyesno(
                self.t("طباعة تقرير نهاية الوردية"),
                self.t("تنسيق 80mm حراري؟ (لا = A4)"),
                parent=self,
            )
        except Exception:
            thermal = True

        try:
            report = self._build_active_report()
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")
            return

        now = datetime.now()
        now_str = now.strftime("%Y-%m-%d %H:%M")
        path = self._ask_export_path(
            "pdf", f"{self.t('تقرير_نهاية_الوردية')}_{self._report_period_save_name()}_{now_str[:10]}"
        )
        if not path:
            return

        try:
            import os
            from reportlab.lib import colors
            from reportlab.lib.enums import TA_RIGHT, TA_CENTER
            from reportlab.lib.pagesizes import A4
            from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
            from reportlab.lib.units import mm
            from reportlab.pdfbase import pdfmetrics
            from reportlab.pdfbase.ttfonts import TTFont
            from reportlab.platypus import (
                SimpleDocTemplate, Paragraph, Spacer, HRFlowable
            )

            font_candidates = [
                ("ShiftArabic", "C:/Windows/Fonts/tahoma.ttf"),
                ("ShiftArabic", "C:/Windows/Fonts/arial.ttf"),
                ("ShiftArabic", "C:/Windows/Fonts/Arial.ttf"),
                ("ShiftArabic", "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"),
            ]
            font_name = "Helvetica"
            for candidate_name, candidate_path in font_candidates:
                if os.path.exists(candidate_path):
                    try:
                        if "ShiftArabic" not in pdfmetrics.getRegisteredFontNames():
                            pdfmetrics.registerFont(TTFont(candidate_name, candidate_path))
                        font_name = candidate_name
                        break
                    except Exception:
                        pass

            def rtl(value):
                value = "" if value is None else str(value)
                import arabic_reshaper
                from bidi.algorithm import get_display
                return get_display(arabic_reshaper.reshape(value))

            def money(value):
                try:
                    return rtl(f"{float(value or 0):,.2f} دج")
                except Exception:
                    return rtl(value)

            fin = report.get("financial", {}) or {}
            gross = float(fin.get("gross_sales", 0))
            paid_cash = float(fin.get("paid_cash", 0))
            outstanding = float(fin.get("outstanding_debt", 0))
            returns_t = float(fin.get("returns_total", 0))
            expenses = float(fin.get("expenses_total", 0))
            exp_drawer = float(fin.get("expenses_drawer", 0))
            final_drawer = paid_cash - exp_drawer - returns_t

            if thermal:
                page_w = 80 * mm
                page_h = 400 * mm
                ml = mr = mt = mb = 4 * mm
            else:
                page_w, page_h = A4
                ml = mr = mt = mb = 15 * mm

            doc = SimpleDocTemplate(
                path,
                pagesize=(page_w, page_h),
                rightMargin=mr,
                leftMargin=ml,
                topMargin=mt,
                bottomMargin=mb,
                title=self.t("طباعة تقرير نهاية الوردية"),
                author=self._current_store_name(),
            )

            styles = getSampleStyleSheet()
            title_style = ParagraphStyle(
                "ShiftTitle", parent=styles["Title"], fontName=font_name,
                fontSize=16, leading=21, alignment=TA_RIGHT, wordWrap="RTL",
            )
            sub_style = ParagraphStyle(
                "ShiftSub", parent=styles["Normal"], fontName=font_name,
                fontSize=9.5, leading=13, alignment=TA_RIGHT, wordWrap="RTL",
                textColor=colors.HexColor("#64748B"),
            )
            body_style = ParagraphStyle(
                "ShiftBody", parent=styles["BodyText"], fontName=font_name,
                fontSize=10.5, leading=17, alignment=TA_RIGHT, wordWrap="RTL",
            )
            total_style = ParagraphStyle(
                "ShiftTotal", parent=body_style, fontName=font_name,
                fontSize=12, leading=19, textColor=colors.HexColor("#16A34A"),
            )
            center_style = ParagraphStyle(
                "ShiftCenter", parent=body_style, fontName=font_name,
                alignment=TA_CENTER, wordWrap="RTL", fontSize=8.5,
            )

            story = []
            story.append(Paragraph(rtl(self._current_store_name()), title_style))
            story.append(Paragraph(rtl("تقرير نهاية الوردية — Z-Report"), sub_style))
            story.append(Spacer(1, 3 * mm))
            story.append(Paragraph(
                rtl(f"{self.t('اسم الجهاز')}: {self._get_device_name()}") + "&nbsp;&nbsp;&nbsp;" +
                rtl(f"{self.t('التاريخ والوقت')}: {now_str}"),
                sub_style
            ))
            story.append(HRFlowable(width="100%", thickness=1.2, color=colors.HexColor("#272C36")))

            row_items = [
                (self.t("إجمالي المبيعات"), money(gross)),
                (self.t("النقد المحصل"), money(paid_cash)),
                (self.t("مبيعات بالدين"), money(outstanding)),
            ]
            for label, value in row_items:
                story.append(Paragraph(rtl(f"{label}: {value}"), body_style))

            story.append(HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#64748B")))
            story.append(Paragraph(self.t("الخصومات") + ": " + rtl(f"{(fin.get('discounts') or 0):,.2f} دج"), body_style))
            story.append(Paragraph(rtl(self.t("المرتجعات") + f": {returns_t:,.2f} دج"), body_style))
            story.append(Paragraph(rtl(self.t("المصاريف") + f": {expenses:,.2f} دج"), body_style))
            story.append(HRFlowable(width="100%", thickness=1.2, color=colors.HexColor("#272C36")))
            story.append(Paragraph(rtl(self.t("الصافي النقدي في الصندوق") + f": {final_drawer:,.2f} دج"), total_style))
            story.append(HRFlowable(width="100%", thickness=1.2, color=colors.HexColor("#272C36")))
            story.append(Spacer(1, 2 * mm))
            story.append(Paragraph(rtl("شكراً لكم — Supermarket Pro"), center_style))

            doc.build(story)
            self.toast(f"{self.t('تم تصدير التقرير بنجاح')}\n{path}", "success")
        except ImportError:
            self.toast(
                self.t("يحتاج تثبيت المكتبة")
                + ": reportlab + arabic-reshaper + python-bidi",
                "danger",
            )
        except Exception as exc:
            self.toast(f"{self.t('تعذر تصدير التقرير')}: {exc}", "danger")

    # ---------------------------------------------------------
    # Daily / Hourly Interactive Trend Chart
    # ---------------------------------------------------------

    def _render_trend_panel(self, parent, report):
        """لوحة الرسم التفاعلي: الإتجاه اليومي أو الإيراد بالساعة مع تلميح عند التمرير."""
        daily = report.get("daily_timeline", []) or []
        hourly = report.get("hourly_revenue", []) or []

        panel = self.make_card(parent)
        panel.pack(fill="x", pady=(0, 10))

        canvas_bg = (
            self.colors["dark_card"] if self.is_dark
            else (self.colors["grey_card"] if self.is_grey else "#FFFFFF")
        )

        head = ctk.CTkFrame(panel, fg_color="transparent")
        head.pack(fill="x", padx=16, pady=(12, 2))
        ctk.CTkLabel(
            head, text="📈 " + self.t("الإتجاه اليومي") + " / " + self.t("الإيراد بالساعة"),
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
            text_color=self.text()
        ).pack(side="right")

        legend = ctk.CTkFrame(head, fg_color="transparent")
        legend.pack(side="left", padx=(8, 0))
        ctk.CTkLabel(legend, text="———", font=ctk.CTkFont(size=11), text_color=self.colors["secondary"]).pack(side="right")
        ctk.CTkLabel(legend, text=self.t("إجمالي الإيراد"), font=ctk.CTkFont(family=self.ui_font_family, size=9), text_color=self.muted()).pack(side="right", padx=(2, 8))
        ctk.CTkLabel(legend, text="———", font=ctk.CTkFont(size=11), text_color=self.colors["accent"]).pack(side="right")
        ctk.CTkLabel(legend, text=self.t("صافي الربح"), font=ctk.CTkFont(family=self.ui_font_family, size=9), text_color=self.muted()).pack(side="right", padx=(2, 0))

        toggles = ctk.CTkFrame(panel, fg_color="transparent")
        toggles.pack(fill="x", padx=16, pady=(6, 2))
        btn_daily = ctk.CTkButton(
            toggles, text=self.t("الإتجاه اليومي"), height=30, width=130, corner_radius=8,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold")
        )
        btn_daily.pack(side="right", padx=3)
        btn_hourly = ctk.CTkButton(
            toggles, text=self.t("الإيراد بالساعة"), height=30, width=130, corner_radius=8,
            fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=10)
        )
        btn_hourly.pack(side="right", padx=3)

        canvas_w, canvas_h = 780, 240
        canvas = ctk.CTkCanvas(panel, width=canvas_w, height=canvas_h, highlightthickness=0, bg=canvas_bg)
        canvas.pack(anchor="center", padx=8, pady=(6, 2))

        hint = ctk.CTkLabel(
            panel, text="🖱 " + self.t("مرّر المؤشر فوق النقاط لعرض التفاصيل"),
            font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
            text_color=self.colors["info"]
        )
        hint.pack(pady=(0, 10))

        state = {"pts": [], "hl": []}

        def _set_style(mode):
            if mode == "daily":
                btn_daily.configure(fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"], text_color="white")
                btn_hourly.configure(fg_color=self.card(), hover_color=self.border(), text_color=self.text())
            else:
                btn_hourly.configure(fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"], text_color="white")
                btn_daily.configure(fg_color=self.card(), hover_color=self.border(), text_color=self.text())

        def _redraw(mode):
            _set_style(mode)
            canvas.delete("all")
            state["pts"] = []
            state["hl"] = []
            data = daily if mode == "daily" else hourly
            if not data:
                canvas.create_text(
                    canvas_w // 2, canvas_h // 2, text=self.t("لا توجد بيانات كافية للرسم"),
                    fill=self.muted(), font=("Tahoma", 12)
                )
                return

            labels, revenue, profit, counts = [], [], [], []
            for row in data:
                if mode == "daily":
                    d = str(row[0] or "")
                    labels.append(d[5:] if len(d) >= 10 else d)
                else:
                    labels.append(f"{int(row[0] or 0):02d}:00")
                revenue.append(float(row[1] or 0))
                cogs = float(row[2] or 0)
                profit.append(float(row[1] or 0) - cogs)
                counts.append(int(row[3] or 0))

            n = len(revenue)
            pad_l, pad_r, pad_t, pad_b = 54, 30, 14, 30
            cw = canvas_w - pad_l - pad_r
            ch = canvas_h - pad_t - pad_b

            all_vals = revenue + profit + [0.0]
            vmax = max(all_vals)
            vmin = min(all_vals)
            if vmax <= 0 and vmin >= 0:
                vmax, vmin = 1.0, 0.0
            span = (vmax - vmin) or 1.0

            def y_of(v):
                return pad_t + ch - ((v - vmin) / span) * ch

            steps = 4
            for i in range(steps + 1):
                v = vmin + (span * i) / steps
                y = y_of(v)
                canvas.create_line(pad_l, y, canvas_w - pad_r, y, fill=self.border(), dash=(3, 4), width=1)
                canvas.create_text(pad_l - 6, y, text=f"{v:,.0f}", anchor="e", fill=self.muted(), font=("Tahoma", 7))

            xcoords = [pad_l + i * (cw / (n - 1)) for i in range(n)] if n > 1 else [pad_l + cw // 2]
            rev_y = [y_of(v) for v in revenue]
            prf_y = [y_of(v) for v in profit]

            for i in range(n - 1):
                canvas.create_line(xcoords[i], rev_y[i], xcoords[i + 1], rev_y[i + 1],
                                   fill=self.colors["secondary"], width=2, smooth=True)
            for i in range(n - 1):
                canvas.create_line(xcoords[i], prf_y[i], xcoords[i + 1], prf_y[i + 1],
                                   fill=self.colors["accent"], width=2, smooth=True)

            state["pts"] = []
            for i in range(n):
                state["pts"].append((xcoords[i], rev_y[i], prf_y[i], labels[i], revenue[i], profit[i], counts[i]))
                canvas.create_oval(xcoords[i] - 3, rev_y[i] - 3, xcoords[i] + 3, rev_y[i] + 3,
                                   fill=self.colors["secondary"], outline="")
                canvas.create_oval(xcoords[i] - 2, prf_y[i] - 2, xcoords[i] + 2, prf_y[i] + 2,
                                   fill=self.colors["accent"], outline="")

            label_step = max(1, (n + 11) // 12)
            for i in range(0, n, label_step):
                canvas.create_text(xcoords[i], canvas_h - pad_b + 14, text=labels[i], anchor="n",
                                   fill=self.muted(), font=("Tahoma", 8))

        def _on_motion(event):
            for it in state.get("hl", []):
                canvas.delete(it)
            state["hl"] = []
            best = None
            best_d = 30
            for (x, rv, pv, lab, rev, prf, cnt) in state.get("pts", []):
                d = abs(event.x - x)
                if d < best_d:
                    best_d = d
                    best = (x, rv, pv, lab, rev, prf, cnt)
            if best is None:
                hint.configure(text="🖱 " + self.t("مرّر المؤشر فوق النقاط لعرض التفاصيل"))
                return
            x, rv, pv, lab, rev, prf, cnt = best
            state["hl"] = [
                canvas.create_line(x, 8, x, canvas_h - 8, fill=self.border(), dash=(2, 3), width=1),
                canvas.create_oval(x - 5, rv - 5, x + 5, rv + 5, outline=self.colors["secondary"], width=2),
                canvas.create_oval(x - 4, pv - 4, x + 4, pv + 4, outline=self.colors["accent"], width=2),
            ]
            hint.configure(
                text=self.t(f"{lab} • {self.t('إجمالي الإيراد')}: {rev:,.0f} دج • "
                            f"{self.t('صافي الربح')}: {prf:,.0f} دج • {self.t('الفواتير')}: {cnt}")
            )

        canvas.bind("<Motion>", _on_motion)
        btn_daily.configure(command=lambda: _redraw("daily"))
        btn_hourly.configure(command=lambda: _redraw("hourly"))
        _redraw("daily")

    # ---------------------------------------------------------
    # Deep-Dive Profit Breakdown
    # ---------------------------------------------------------

    def _render_profit_tab(self, parent, report):
        """الأرباح التفصيلية: ربح حسب الفئة + تحذيرات هامش الربح."""
        categories = report.get("profit_by_category", []) or []
        fin = report.get("financial", {}) or {}
        net_profit = float(fin.get("net_profit", 0))
        margin = float(fin.get("profit_margin_pct", 0))
        try:
            warnings = self.reports_manager.get_margin_warnings(report.get("top_products", []) or [])
        except Exception:
            warnings = {"warnings": [], "below_cost": [], "near_cost": [], "count": 0}

        scroll = ctk.CTkScrollableFrame(parent, fg_color="transparent")
        scroll.pack(fill="both", expand=True, padx=6, pady=6)

        kp = ctk.CTkFrame(scroll, fg_color="transparent")
        kp.pack(fill="x", pady=(0, 8))
        profitable = sum(1 for c in categories if (float(c[1] or 0) - float(c[2] or 0)) > 0)
        chips = [
            ("💰 " + self.t("صافي الربح بعد المصاريف"), f"{net_profit:,.0f} دج", self.colors["primary"]),
            ("📊 " + self.t("الهامش"), f"{margin:.1f}%", self.colors["secondary"]),
            ("🗂 " + self.t("الفئات المربحة"), str(profitable), self.colors["accent"]),
            ("⚠ " + self.t("تحذيرات الهامش"), str(warnings["count"]),
             self.colors["danger"] if warnings["count"] else self.colors["secondary"]),
        ]
        for i, (label, value, accent) in enumerate(chips):
            kp.grid_columnconfigure(i, weight=1)
            cell = self.make_card(kp)
            cell.grid(row=0, column=i, sticky="nsew", padx=4)
            ctk.CTkLabel(cell, text=value, font=ctk.CTkFont(family=self.ui_font_family, size=15, weight="bold"),
                         text_color=accent).pack(anchor="e", padx=12, pady=(10, 2))
            ctk.CTkLabel(cell, text=label, font=ctk.CTkFont(family=self.ui_font_family, size=10),
                         text_color=self.muted()).pack(anchor="e", padx=12, pady=(0, 8))

        # -- Profit by category (horizontal bars)
        chart_card = self.make_card(scroll)
        chart_card.pack(fill="x", pady=(0, 8))
        hh = ctk.CTkFrame(chart_card, fg_color="transparent")
        hh.pack(fill="x", padx=16, pady=(10, 2))
        ctk.CTkLabel(hh, text="📊 " + self.t("الأرباح حسب الفئة"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
                     text_color=self.text()).pack(anchor="e")

        canvas_bg = (
            self.colors["dark_card"] if self.is_dark
            else (self.colors["grey_card"] if self.is_grey else "#FFFFFF")
        )
        if categories:
            canvas_h = max(120, 36 * len(categories))
            cv = ctk.CTkCanvas(chart_card, width=780, height=canvas_h, highlightthickness=0, bg=canvas_bg)
            cv.pack(anchor="center", padx=8, pady=(4, 10))
            profits = [(float(c[1] or 0) - float(c[2] or 0)) for c in categories]
            max_profit = max([p for p in profits] + [1.0])
            pad_l, pad_r = 10, 230
            bar_w = 780 - pad_l - pad_r
            bh = min(22, canvas_h // len(categories) - 5)
            for i, c in enumerate(categories):
                name = str(c[0] or self.t("غير مصنّف"))
                profit = profits[i]
                y = 10 + i * (bh + 6)
                if profit >= 0:
                    length = max(1, (profit / max_profit) * bar_w)
                    cv.create_rectangle(pad_l, y, pad_l + length, y + bh, fill=self.colors["secondary"], outline="")
                    cv.create_text(pad_l + length + 6, y + bh / 2, text=f"{profit:,.0f}", anchor="w",
                                   fill=self.text(), font=("Tahoma", 8))
                else:
                    cv.create_rectangle(pad_l, y + 4, pad_l + 6, y + bh - 4, fill=self.colors["danger"], outline="")
                    cv.create_text(pad_l + 10, y + bh / 2, text=self.t(f"{profit:,.0f} (خسارة)"), anchor="w",
                                   fill=self.colors["danger"], font=("Tahoma", 8))
                cv.create_text(pad_l + bar_w + 170, y + bh / 2, text=name, anchor="w",
                               fill=self.text(), font=("Tahoma", 8))
        else:
            ctk.CTkLabel(chart_card, text=self.t("لا توجد بيانات كافية للرسم"),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11),
                         text_color=self.muted()).pack(pady=14)

        # -- Margin warnings
        warn_card = self.make_card(scroll)
        warn_card.pack(fill="x", pady=(0, 4))
        ctk.CTkLabel(
            warn_card, text="⚠ " + self.t("تحذيرات هامش الربح") + f" ({warnings['count']})",
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
            text_color=self.colors["danger"] if warnings["count"] else self.colors["secondary"]
        ).pack(anchor="e", padx=16, pady=(10, 4))

        if not warnings["warnings"]:
            ctk.CTkLabel(warn_card, text="🎉 " + self.t("لا توجد منتجات بهامش منخفض"),
                         font=ctk.CTkFont(family=self.ui_font_family, size=11),
                         text_color=self.colors["secondary"]).pack(anchor="e", padx=16, pady=(0, 12))
            return

        warn_header = [self.t("المنتج"), self.t("الكمية"), self.t("الإيراد"), self.t("التكلفة"), self.t("صافي الربح"), self.t("الهامش")]
        warn_weights = [4, 1, 2, 2, 2, 1]
        hdr2 = ctk.CTkFrame(warn_card, fg_color=self.bg(), corner_radius=7)
        hdr2.pack(fill="x", padx=14, pady=(2, 3))
        for ci, txt in enumerate(warn_header):
            hdr2.grid_columnconfigure(ci, weight=warn_weights[ci])
            ctk.CTkLabel(hdr2, text=self.t(txt), font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                         text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=6)

        for i, (name, qty, revenue, cogs, profit, mg) in enumerate(warnings["warnings"][:40]):
            below = mg < 0
            color = self.colors["danger"] if below else self.colors["accent"]
            rw = ctk.CTkFrame(warn_card, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=6)
            rw.pack(fill="x", padx=14, pady=1)
            vals = [str(name)[:40], f"{qty:,.0f}", f"{revenue:,.0f}", f"{cogs:,.0f}", f"{profit:,.0f}", f"{mg:+.2f}%"]
            for ci, val in enumerate(vals):
                rw.grid_columnconfigure(ci, weight=warn_weights[ci])
                ctk.CTkLabel(rw, text=val,
                             font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold" if ci == 5 else "normal"),
                             text_color=color if ci == 5 else self.text(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=5)

        below_n = len(warnings.get("below_cost") or [])
        if below_n:
            ctk.CTkLabel(
                warn_card,
                text=f"🔴 {below_n} " + self.t("منتجات تُباع بخسارة") + f" • {len(warnings.get('near_cost') or [])} " + self.t("منتجات قريبة من التكلفة"),
                font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                text_color=self.colors["danger"]
            ).pack(anchor="e", padx=16, pady=(6, 10))

    def _render_top_products_tab(self, parent, report):
        perf = report.get("top_products", [])
        if not perf:
            ctk.CTkLabel(parent, text=self.t("لا توجد بيانات مبيعات لهذه الفترة"), font=ctk.CTkFont(family=self.ui_font_family, size=12), text_color=self.muted()).pack(pady=30)
            return

        sort_frame = ctk.CTkFrame(parent, fg_color="transparent")
        sort_frame.pack(fill="x", padx=10, pady=(10, 5))
        ctk.CTkLabel(sort_frame, text=self.t("ترتيب حسب:"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(side="right", padx=(0, 5))

        sort_var = tk.StringVar(value="qty")
        scroll = ctk.CTkScrollableFrame(parent, fg_color="transparent")
        scroll.pack(fill="both", expand=True, padx=6, pady=4)

        def _rebuild(*_a):
            for w in scroll.winfo_children():
                w.destroy()
            key = sort_var.get()
            items = list(perf)
            if key == "profit":
                items.sort(key=lambda x: float(x[5] or 0), reverse=True)
            else:
                items.sort(key=lambda x: float(x[2] or 0), reverse=True)

            hdr = ctk.CTkFrame(scroll, fg_color=self.card(), corner_radius=8)
            hdr.pack(fill="x", pady=(0, 3))
            for ci, txt in enumerate([self.t("#"), self.t("المنتج"), self.t("الكمية"), self.t("الإيراد"), self.t("التكلفة"), self.t("صافي الربح")]):
                hdr.grid_columnconfigure(ci, weight=[0, 4, 2, 2, 2, 2][ci])
                ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=7)

            for i, item in enumerate(items[:30]):
                pid, name, qty, rev, cost, profit = item
                rw = ctk.CTkFrame(scroll, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
                rw.pack(fill="x", pady=1)
                vals = [str(i + 1), str(name)[:35], f"{float(qty or 0):,.0f}", f"{float(rev or 0):,.0f}", f"{float(cost or 0):,.0f}", f"{float(profit or 0):,.0f}"]
                colors_row = [self.text(), self.text(), self.text(), self.colors["secondary"], self.colors["accent"], self.colors["secondary"] if float(profit or 0) >= 0 else self.colors["danger"]]
                for ci, val in enumerate(vals):
                    rw.grid_columnconfigure(ci, weight=[0, 4, 2, 2, 2, 2][ci])
                    ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold" if ci in (1, 5) else "normal"), text_color=colors_row[ci], anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=6)

        ctk.CTkRadioButton(sort_frame, text=self.t("الكمية المباعة"), variable=sort_var, value="qty", font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.text(), command=_rebuild).pack(side="right", padx=5)
        ctk.CTkRadioButton(sort_frame, text=self.t("صافي الربح"), variable=sort_var, value="profit", font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.text(), command=_rebuild).pack(side="right", padx=5)
        _rebuild()

    def _render_peak_hours_tab(self, parent):
        import tkinter as _tk
        from datetime import datetime

        AR_DAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"]
        DAY_NAME_TO_DOW = {
            "الأحد": 1, "الاثنين": 2, "الثلاثاء": 3,
            "الأربعاء": 4, "الخميس": 5, "الجمعة": 6, "السبت": 7
        }

        now = datetime.now()
        current_hour = now.hour
        current_dow = now.isoweekday() % 7
        current_day_ar = AR_DAYS[current_dow]

        # ── 1. Tool Strip Container ──
        strip = ctk.CTkFrame(parent, fg_color="transparent")
        strip.pack(fill="x", padx=10, pady=(10, 4))

        day_var = _tk.StringVar(value=self.t(current_day_ar))
        hour_var = _tk.StringVar(value=str(current_hour).zfill(2))

        day_lbl = ctk.CTkLabel(strip, text=self.t("اليوم:"), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.text())
        day_lbl.pack(side="right", padx=(0, 4))
        day_menu = ctk.CTkOptionMenu(strip, variable=day_var, values=[self.t(d) for d in AR_DAYS], width=120, height=32, font=ctk.CTkFont(family=self.ui_font_family, size=10))
        day_menu.pack(side="right", padx=(0, 10))

        hour_lbl = ctk.CTkLabel(strip, text=self.t("الساعة:"), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.text())
        hour_lbl.pack(side="right", padx=(0, 4))
        hour_vals = [str(h).zfill(2) for h in range(24)]
        hour_menu = ctk.CTkOptionMenu(strip, variable=hour_var, values=hour_vals, width=65, height=32, font=ctk.CTkFont(family=self.ui_font_family, size=10))
        hour_menu.pack(side="right", padx=(0, 10))

        btn_now = ctk.CTkButton(strip, text=self.t("🕒 الوقت الحالي"), height=32, width=120, corner_radius=8, fg_color=self.colors["info"], hover_color="#0EA5E9", text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"))
        btn_now.pack(side="left", padx=(8, 0))

        btn_predict = ctk.CTkButton(strip, text=self.t("توقع الازدحام"), height=32, width=115, corner_radius=8, fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"], text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"))
        btn_predict.pack(side="left", padx=4)

        now_badge = ctk.CTkLabel(strip, text=self.t(f"🕒 التوقيت الحالي: {current_day_ar} {current_hour:02d}:00"), font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"), text_color=self.colors["info"])
        now_badge.pack(side="left", padx=(10, 0))

        # ── 2. Executive Prediction Card Container ──
        status_frame = ctk.CTkFrame(parent, fg_color=self.card(), corner_radius=14, border_width=1, border_color=self.border())
        status_frame.pack(fill="x", padx=10, pady=8)

        col1 = ctk.CTkFrame(status_frame, fg_color="transparent")
        col1.pack(side="right", fill="y", padx=(0, 12), pady=14)
        badge_icon = ctk.CTkLabel(col1, text="🟢", font=ctk.CTkFont(size=36))
        badge_icon.pack(anchor="e")
        badge_text = ctk.CTkLabel(col1, text=self.t("هدوء تام"), font=ctk.CTkFont(family=self.ui_font_family, size=14, weight="bold"), text_color=self.colors["secondary"])
        badge_text.pack(anchor="e")
        badge_rec = ctk.CTkLabel(col1, text=self.t("كاشير واحد كافي"), font=ctk.CTkFont(family=self.ui_font_family, size=9), text_color=self.muted())
        badge_rec.pack(anchor="e")

        sep = ctk.CTkFrame(status_frame, fg_color=self.border(), width=2)
        sep.pack(side="right", fill="y", padx=6, pady=14)

        col2 = ctk.CTkFrame(status_frame, fg_color="transparent")
        col2.pack(side="right", fill="both", expand=True, padx=6, pady=14)
        ctk.CTkLabel(col2, text=self.t("📊 حركة الزبائن"), font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted()).pack(anchor="e")
        vol_invoices = ctk.CTkLabel(col2, text="—", font=ctk.CTkFont(family=self.ui_font_family, size=22, weight="bold"), text_color=self.text())
        vol_invoices.pack(anchor="e", pady=(2, 0))
        vol_pct = ctk.CTkLabel(col2, text=self.t("مستوى الإشغال: —"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted())
        vol_pct.pack(anchor="e")

        sep2 = ctk.CTkFrame(status_frame, fg_color=self.border(), width=2)
        sep2.pack(side="right", fill="y", padx=6, pady=14)

        col3 = ctk.CTkFrame(status_frame, fg_color="transparent")
        col3.pack(side="right", fill="both", expand=True, padx=(12, 0), pady=14)
        ctk.CTkLabel(col3, text=self.t("💰 الإيراد المتوقع"), font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted()).pack(anchor="e")
        rev_val = ctk.CTkLabel(col3, text="—", font=ctk.CTkFont(family=self.ui_font_family, size=22, weight="bold"), text_color=self.colors["secondary"])
        rev_val.pack(anchor="e", pady=(2, 0))
        rev_per_inv = ctk.CTkLabel(col3, text=self.t("متوسط الفاتورة: —"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted())
        rev_per_inv.pack(anchor="e")

        # ── 3. Chart Canvas Container ──
        chart_outer = ctk.CTkFrame(parent, fg_color=self.bg(), corner_radius=12)
        chart_outer.pack(fill="x", padx=10, pady=(0, 4))
        ctk.CTkLabel(chart_outer, text=self.t("متوسط الفواتير لكل ساعة"), font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.text()).pack(anchor="e", padx=14, pady=(10, 2))
        chart_canvas_frame = ctk.CTkFrame(chart_outer, fg_color="transparent")
        chart_canvas_frame.pack(fill="x", padx=8, pady=(0, 6))

        canvas_w = 780
        canvas_h = 220
        chart_cv = ctk.CTkCanvas(chart_canvas_frame, width=canvas_w, height=canvas_h, highlightthickness=0, bg="#171A21" if self.is_dark else "#FFFFFF")
        chart_cv.pack(anchor="center")

        # ── 4. Busiest Hours Bar Container ──
        busiest_frame = ctk.CTkFrame(parent, fg_color=self.card(), corner_radius=10, border_width=1, border_color=self.border())
        busiest_frame.pack(fill="x", padx=10, pady=(0, 8))
        busiest_label = ctk.CTkLabel(busiest_frame, text="", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"), text_color=self.text(), anchor="e", wraplength=700, justify="right")
        busiest_label.pack(anchor="e", padx=14, pady=10)

        # ── 5. Definition of _refresh Logic ──
        def _refresh(*_a):
            day_name = self._to_ar(day_var.get())
            hour_val = int(hour_var.get())

            result = self.reports_manager.predict_crowd_level(day_name, hour_val)
            level = result.get("level", "unknown")
            avg_inv = float(result.get("avg_invoices", 0.0))
            avg_vol = float(result.get("avg_volume", 0.0))

            if level == "peak":
                badge_icon.configure(text="🔴")
                badge_text.configure(text=self.t("ساعة ذروة"), text_color=self.colors["danger"])
                badge_rec.configure(text=self.t("يُنصح بكاشير إضافي"))
            elif level == "medium":
                badge_icon.configure(text="🟡")
                badge_text.configure(text=self.t("حركة متوسطة"), text_color=self.colors["accent"])
                badge_rec.configure(text=self.t("كاشيران مطلوبان"))
            else:
                badge_icon.configure(text="🟢")
                badge_text.configure(text=self.t("هدوء تام"), text_color=self.colors["secondary"])
                badge_rec.configure(text=self.t("كاشير واحد كافي"))

            vol_invoices.configure(text=self.t(f"{avg_inv:,.1f} فاتورة/يوم"))

            pct_val = 0.0
            try:
                dow_id = DAY_NAME_TO_DOW.get(day_name, 1)
                traffic_all = self.reports_manager.get_hourly_traffic(day_of_week=dow_id)
                total_all_inv = sum(r[2] for r in traffic_all.get("rows", []))
                total_all_days = int(traffic_all.get("total_days", 0) or 0)
                if total_all_inv > 0 and total_all_days > 0:
                    daily_avg = total_all_inv / total_all_days
                    pct_val = (avg_inv / daily_avg * 100) if daily_avg > 0 else 0
            except Exception:
                pass

            pct_color = self.colors["danger"] if pct_val > 15 else (self.colors["accent"] if pct_val > 8 else self.colors["secondary"])
            vol_pct.configure(text=self.t(f"مستوى الإشغال: {pct_val:.0f}%"), text_color=pct_color)

            rev_val.configure(text=self.t(f"{avg_vol:,.0f} دج"))
            if avg_inv > 0:
                rev_per_inv.configure(text=self.t(f"متوسط الفاتورة: {avg_vol / avg_inv:,.0f} دج"))
            else:
                rev_per_inv.configure(text=self.t("متوسط الفاتورة: —"))

            dow = DAY_NAME_TO_DOW.get(day_name, 1)
            try:
                traffic = self.reports_manager.get_hourly_traffic(day_of_week=dow)
            except Exception:
                traffic = {"total_days": 0, "rows": []}

            hourly = {}
            for r in traffic.get("rows", []):
                h = r[1]
                hourly[h] = hourly.get(h, 0) + r[2]

            total_days_chart = int(traffic.get("total_days", 0) or 0)
            hourly_avg = {h: (hourly.get(h, 0) / total_days_chart if total_days_chart else 0) for h in range(24)}

            max_val = max(hourly_avg.values()) if hourly_avg else 1.0
            max_val_y = max(10, int(max_val * 1.25))

            # Redraw Canvas Chart
            chart_cv.delete("all")
            pad_l, pad_r, pad_t, pad_b = 40, 12, 10, 28
            chart_w = canvas_w - pad_l - pad_r
            chart_h = canvas_h - pad_t - pad_b

            guide_ticks = [0, max(2, int(max_val_y / 2)), max_val_y]
            for gt in guide_ticks:
                y = pad_t + chart_h - (gt / max_val_y) * chart_h
                chart_cv.create_line(pad_l, y, canvas_w - pad_r, y, fill=self.border(), dash=(3, 4), width=1)
                chart_cv.create_text(pad_l - 6, y, text=str(int(gt)), anchor="e", fill=self.muted(), font=("Tahoma", 8))

            bar_gap = 3
            bar_w = max(8, (chart_w - bar_gap * 23) // 24)

            for h in range(24):
                val = hourly_avg.get(h, 0.0)
                bh = max(6, int((val / max_val_y) * chart_h)) if val > 0 else 0
                x0 = pad_l + h * (bar_w + bar_gap)
                x1 = x0 + bar_w
                y1 = pad_t + chart_h
                y0 = y1 - bh

                color = self.colors["danger"] if val > 25 else (self.colors["accent"] if val >= 8 else self.colors["secondary"])

                if bh > 0:
                    chart_cv.create_rectangle(x0, y0, x1, y1, fill=color, outline="", width=0)

                if h == hour_val:
                    chart_cv.create_rectangle(x0 - 2, pad_t, x1 + 2, y1, outline=self.colors["info"], width=2)

                if val > 0:
                    chart_cv.create_text((x0 + x1) / 2, y0 - 5, text=f"{val:.1f}", anchor="s", fill=self.text(), font=("Tahoma", 7))

                if h % 3 == 0:
                    chart_cv.create_text((x0 + x1) / 2, y1 + 12, text=str(h), anchor="n", fill=self.muted(), font=("Tahoma", 8))

            sorted_hours = sorted(range(24), key=lambda h: hourly_avg.get(h, 0), reverse=True)
            top2 = [h for h in sorted_hours if hourly_avg.get(h, 0) > 0][:2]

            if top2 and total_days_chart > 0:
                ranges = [f"[{th:02d}:00 - {th + 1:02d}:00]" for th in top2]
                busiest_label.configure(text=self.t(f"🔥 أكثر الساعات ازدحاماً في هذا اليوم: {' و '.join(ranges)}   (متوسط إجمالي: {sum(hourly_avg.get(h, 0) for h in top2):,.1f} فاتورة)"))
            elif total_days_chart == 0:
                busiest_label.configure(text=self.t("لا توجد بيانات كافية لتحديد ساعات الذروة"))
            else:
                busiest_label.configure(text=self.t("لا توجد حركة زبائن مسجلة لهذا اليوم"))

        def _goto_now(*_a):
            nd = datetime.now()
            day_var.set(self.t(AR_DAYS[nd.isoweekday() % 7]))
            hour_var.set(str(nd.hour).zfill(2))
            _refresh()

        # ── 6. Bind Commands & Trigger Initial Draw ──
        btn_now.configure(command=_goto_now)
        btn_predict.configure(command=_refresh)
        day_menu.configure(command=_refresh)
        hour_menu.configure(command=_refresh)

        _refresh()

    def _render_slow_moving_tab(self, parent, report):
        slow = report.get("slow_moving", [])
        if not slow:
            ctk.CTkLabel(parent, text=self.t("لا توجد منتجات بطيئة الحركة 🎉"), font=ctk.CTkFont(family=self.ui_font_family, size=13), text_color=self.colors["secondary"]).pack(pady=30)
            return

        ctk.CTkLabel(parent, text=self.t(f"المنتجات التي بيعت 2 قطعة أو أقل خلال 30 يومًا ({len(slow)} منتج)"), font=ctk.CTkFont(family=self.ui_font_family, size=11), text_color=self.muted()).pack(anchor="e", padx=14, pady=(10, 5))

        scroll = ctk.CTkScrollableFrame(parent, fg_color="transparent")
        scroll.pack(fill="both", expand=True, padx=6, pady=4)

        hdr = ctk.CTkFrame(scroll, fg_color=self.card(), corner_radius=8)
        hdr.pack(fill="x", pady=(0, 3))
        for ci, txt in enumerate([self.t("#"), self.t("المنتج"), self.t("الوحدة"), self.t("المخزون الحالي"), self.t("الكمية المباعة"), self.t("التكلفة")]):
            hdr.grid_columnconfigure(ci, weight=[0, 4, 1, 2, 2, 2][ci])
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=7)

        for i, item in enumerate(slow[:50]):
            pid, name, unit, stock, sold, cost = item
            rw = ctk.CTkFrame(scroll, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
            rw.pack(fill="x", pady=1)
            vals = [str(i + 1), str(name)[:35], str(unit or ""), f"{float(stock or 0):,.0f}", f"{float(sold or 0):,.0f}", f"{float(cost or 0):,.0f}"]
            for ci, val in enumerate(vals):
                rw.grid_columnconfigure(ci, weight=[0, 4, 1, 2, 2, 2][ci])
                color = self.colors["danger"] if ci == 4 and float(sold or 0) == 0 else self.text()
                ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=color, anchor="e").grid(row=0, column=ci, sticky="ew", padx=8, pady=6)

    def _render_device_breakdown_tab(self, parent, report):
        breakdown = report.get("device_breakdown", [])
        if not breakdown:
            ctk.CTkLabel(parent, text=self.t("لا توجد بيانات أجهزة لهذه الفترة"), font=ctk.CTkFont(family=self.ui_font_family, size=12), text_color=self.muted()).pack(pady=30)
            return

        hdr = ctk.CTkFrame(parent, fg_color=self.card(), corner_radius=8)
        hdr.pack(fill="x", padx=14, pady=(14, 3))
        for ci, txt in enumerate([self.t("الجهاز"), self.t("عدد الوصلات"), self.t("إجمالي الإيراد"), self.t("المرتجعات")]):
            hdr.grid_columnconfigure(ci, weight=1)
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=12, pady=7)

        for i, item in enumerate(breakdown):
            dev_name, receipts, gross, returns = item
            rw = ctk.CTkFrame(parent, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
            rw.pack(fill="x", padx=14, pady=1)
            vals = [str(dev_name), str(receipts), f"{float(gross or 0):,.0f} دج", f"{float(returns or 0):,.0f} دج"]
            for ci, val in enumerate(vals):
                rw.grid_columnconfigure(ci, weight=1)
                ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold" if ci == 0 else "normal"), text_color=self.text(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=12, pady=8)

    def _render_returns_voids_tab(self, parent, report):
        returns = report.get("returns", [])
        voided = report.get("voided", [])

        if returns:
            ctk.CTkLabel(parent, text=self.t(f"📋 المرتجعات ({len(returns)})"), font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"), text_color=self.text()).pack(anchor="e", padx=14, pady=(10, 5))
            scroll_ret = ctk.CTkScrollableFrame(parent, fg_color="transparent", height=200)
            scroll_ret.pack(fill="x", padx=6, pady=(0, 8))

            for i, ret in enumerate(returns[:50]):
                rid, inv, sid, cid, amt, dev, rdate, note = ret
                rw = ctk.CTkFrame(scroll_ret, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
                rw.pack(fill="x", pady=1)
                ctk.CTkLabel(rw, text=self.t(f"↩️ {str(inv)} | {float(amt or 0):,.0f} دج | {str(dev or '')} | {str(rdate or '')[:16]}"), font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.text(), anchor="e").pack(fill="x", padx=10, pady=5)
        else:
            ctk.CTkLabel(parent, text=self.t("لا توجد مرتجعات"), font=ctk.CTkFont(family=self.ui_font_family, size=11), text_color=self.muted()).pack(pady=(15, 5))

        if voided:
            ctk.CTkLabel(parent, text=self.t(f"🚫 الفواتير الملغاة ({len(voided)})"), font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"), text_color=self.colors["danger"]).pack(anchor="e", padx=14, pady=(10, 5))
            scroll_void = ctk.CTkScrollableFrame(parent, fg_color="transparent", height=150)
            scroll_void.pack(fill="x", padx=6, pady=(0, 8))

            for i, v in enumerate(voided[:30]):
                vid, vinv, vdate, vdev = v
                rw = ctk.CTkFrame(scroll_void, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
                rw.pack(fill="x", pady=1)
                ctk.CTkLabel(rw, text=f"🚫 {str(vinv)} | {str(vdev or '')} | {str(vdate or '')[:16]}", font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.colors["danger"], anchor="e").pack(fill="x", padx=10, pady=5)
        else:
            ctk.CTkLabel(parent, text=self.t("لا توجد فواتير ملغاة 🎉"), font=ctk.CTkFont(family=self.ui_font_family, size=11), text_color=self.colors["secondary"]).pack(pady=(5, 15))

    def _render_expenses_tab(self, parent, report):
        expenses = report.get("expenses", [])
        if not expenses:
            ctk.CTkLabel(parent, text=self.t("لا توجد مصاريف مسجلة لهذه الفترة"), font=ctk.CTkFont(family=self.ui_font_family, size=12), text_color=self.muted()).pack(pady=30)
            return

        hdr = ctk.CTkFrame(parent, fg_color=self.card(), corner_radius=8)
        hdr.pack(fill="x", padx=14, pady=(14, 3))
        for ci, txt in enumerate([self.t("#"), self.t("العنوان"), self.t("الفئة"), self.t("المبلغ"), self.t("الدفع"), self.t("الجهاز"), self.t("التاريخ"), self.t("ملاحظة")]):
            hdr.grid_columnconfigure(ci, weight=[0, 3, 2, 2, 1, 1, 2, 2][ci])
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"), text_color=self.muted(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=6, pady=7)

        scroll_exp = ctk.CTkScrollableFrame(parent, fg_color="transparent")
        scroll_exp.pack(fill="both", expand=True, padx=6, pady=4)

        for i, exp in enumerate(expenses):
            eid, title, cat, amt, drawer, devn, edate, note = exp
            rw = ctk.CTkFrame(scroll_exp, fg_color=self.bg() if i % 2 == 0 else self.card(), corner_radius=7)
            rw.pack(fill="x", pady=1)
            vals = [str(eid), str(title or "")[:30], str(cat or ""), f"{float(amt or 0):,.0f} دج", self.t("نقدًا") if drawer == 1 else self.t("خارجي"), str(devn or ""), str(edate or "")[:16], str(note or "")[:25]]
            for ci, val in enumerate(vals):
                rw.grid_columnconfigure(ci, weight=[0, 3, 2, 2, 1, 1, 2, 2][ci])
                ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.text(), anchor="e").grid(row=0, column=ci, sticky="ew", padx=6, pady=5)

    # =========================================================
    # Settings
    # =========================================================

    @staticmethod
    def _sql_literal(value):
        """تمثيل قيمة كنص SQL حرفي داخل ملف النسخة الاحتياطية."""
        import datetime as _dt
        if value is None:
            return "NULL"
        if isinstance(value, bool):
            return "1" if value else "0"
        if isinstance(value, (int, float)):
            return repr(value)
        if isinstance(value, _dt.datetime):
            return "'" + value.strftime("%Y-%m-%d %H:%M:%S") + "'"
        if isinstance(value, _dt.date):
            return "'" + value.isoformat() + "'"
        if isinstance(value, (bytes, bytearray)):
            return "X'" + bytes(value).hex() + "'"
        s = str(value)
        s = (s.replace("\\", "\\\\").replace("'", "\\'")
              .replace("\n", "\\n").replace("\r", "\\r").replace("\x00", ""))
        return "'" + s + "'"

    def backup_database(self):
        """إنشاء نسخة احتياطية من قاعدة بيانات MySQL كملف SQL قابل للاستعادة."""
        import os
        from tkinter import filedialog

        default_name = f"supermarket_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.sql"
        path = filedialog.asksaveasfilename(
            title=self.t("حفظ نسخة احتياطية"),
            defaultextension=".sql",
            initialfile=default_name,
            filetypes=[
                ("SQL Dump", "*.sql"),
                ("All files", "*.*")
            ]
        )
        if not path:
            return

        conn = None
        try:
            conn = self.db.get_connection()
            cur = conn.cursor()

            cur.execute("SHOW TABLES")
            tables = [r[0] for r in cur.fetchall()]

            with open(path, "w", encoding="utf-8") as f:
                f.write("-- Supermarket Pro backup (MySQL/MariaDB)\n")
                f.write(f"-- {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
                f.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n\n")

                for table in tables:
                    cur.execute("SHOW CREATE TABLE `%s`" % table)
                    ddl_row = cur.fetchone()
                    if not ddl_row:
                        continue
                    f.write(f"DROP TABLE IF EXISTS `{table}`;\n")
                    f.write(str(ddl_row[1]) + ";\n\n")

                    cur.execute("SELECT * FROM `%s`" % table)
                    rows = cur.fetchall()
                    if not rows:
                        continue
                    columns = [d[0] for d in cur.description]
                    col_list = ", ".join(f"`{c}`" for c in columns)

                    batch = []
                    for row in rows:
                        values = ", ".join(self._sql_literal(v) for v in row)
                        batch.append(f"({values})")
                        if len(batch) >= 200:
                            f.write(f"INSERT INTO `{table}` ({col_list}) VALUES\n"
                                    + ",\n".join(batch) + ";\n\n")
                            batch = []
                    if batch:
                        f.write(f"INSERT INTO `{table}` ({col_list}) VALUES\n"
                                + ",\n".join(batch) + ";\n\n")
                    f.write("\n")

                f.write("SET FOREIGN_KEY_CHECKS=1;\n")

            size_mb = os.path.getsize(path) / (1024 * 1024)
            self.toast(
                f"تم إنشاء النسخة الاحتياطية بنجاح\n"
                f"{path}\n"
                f"الحجم: {size_mb:.2f} MB",
                "success"
            )
        except Exception as exc:
            self.toast(f"فشل إنشاء النسخة الاحتياطية:\n{exc}", "danger")
        finally:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass

    # =========================================================
    # App Settings
    # =========================================================

    def _settings_file(self):
        settings_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "config",
            "app_settings.json",
        )
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        return settings_path

    def load_app_settings(self):
        defaults = {
            "store_name": "Supermarket Pro",
            "store_phone": "",
            "store_address": "",
            "invoice_footer": "شكرًا لزيارتكم",
            "default_paper": "80mm",
            "ask_before_print": True,
            "allow_debt": True,
            "low_stock_threshold": 5,
            "auto_print_invoice": False,
            "theme_mode": "dark",
            "appearance": "dark",
            "language": "ar",
        }
        try:
            path = self._settings_file()
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    defaults.update(data)
        except Exception:
            pass
        return defaults

    def save_app_settings(self):
        try:
            settings_path = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "config",
                "app_settings.json",
            )
            os.makedirs(os.path.dirname(settings_path), exist_ok=True)
            with open(settings_path, "w", encoding="utf-8") as f:
                json.dump(self.settings, f, ensure_ascii=False, indent=4)
            return True
        except Exception as exc:
            self.toast(f"تعذر حفظ الإعدادات: {exc}", "danger")
            return False

    def _settings_entry(self, parent, label, value, width=430, show=None):
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=18, pady=5)
        ctk.CTkLabel(row, text=self.t(label), width=170, anchor="e",
                     font=ctk.CTkFont(family=self.ui_font_family, size=11),
                     text_color=self.text()).pack(side="right", padx=(10, 0))
        entry = ctk.CTkEntry(row, width=width, height=38, show=show or "",
                             font=ctk.CTkFont(family=self.ui_font_family, size=11))
        entry.insert(0, str(value or ""))
        entry.pack(side="right", fill="x", expand=True)
        return entry

    def _settings_entry_with_eye(self, parent, label, value, width=430):
        """حقل إدخال مع زر عين لإظهار/إخفاء المحتوى (كلمة المرور).

        إظهار المحتوى إجراء حساس: يتطلب التحقق من PIN بصلاحية مدير عبر
        require_pin؛ وعند الفشل أو الإلغاء تبقى القيمة مخفية. عند النجاح
        تُعرض مؤقتًا ثم تُعاد الحماية تلقائيًا بعد 30 ثانية.
        """
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=18, pady=5)
        ctk.CTkLabel(row, text=self.t(label), width=170, anchor="e",
                     font=ctk.CTkFont(family=self.ui_font_family, size=11),
                     text_color=self.text()).pack(side="right", padx=(10, 0))
        entry = ctk.CTkEntry(row, width=width, height=38, show="*",
                             font=ctk.CTkFont(family=self.ui_font_family, size=11))
        entry.insert(0, str(value or ""))
        entry.pack(side="right", fill="x", expand=True)

        auto_hide = {"id": None}

        def _rehide():
            try:
                entry.configure(show="*")
            except Exception:
                pass
            try:
                eye_btn.configure(text="👁")
            except Exception:
                pass

        def toggle_visibility():
            if entry.cget("show") == "*":
                # إظهار كلمة المرور إجراء حساس: يتطلب PIN بصلاحية مدير.
                if not self.require_pin("عرض كلمة المرور", "admin"):
                    self.toast(
                        self.t("لم يتم التحقق من الهوية. تبقى كلمة المرور مخفية."),
                        "danger"
                    )
                    entry.configure(show="*")
                    return
                entry.configure(show="")
                eye_btn.configure(text="🙈")
                try:
                    if auto_hide["id"] is not None:
                        self.after_cancel(auto_hide["id"])
                except Exception:
                    pass
                auto_hide["id"] = self.after(30000, _rehide)
            else:
                entry.configure(show="*")
                eye_btn.configure(text="👁")
                try:
                    if auto_hide["id"] is not None:
                        self.after_cancel(auto_hide["id"])
                        auto_hide["id"] = None
                except Exception:
                    pass

        eye_btn = ctk.CTkButton(
            row,
            text="👁",
            width=38,
            height=38,
            corner_radius=8,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=14),
            command=toggle_visibility,
        )
        eye_btn.pack(side="right", padx=(6, 0))
        return entry

    def _settings_switch(self, parent, label, value):
        sw = ctk.CTkSwitch(parent, text=self.t(label), onvalue=1, offvalue=0,
                           font=ctk.CTkFont(family=self.ui_font_family, size=11),
                           text_color=self.text())
        sw.select() if value else sw.deselect()
        sw.pack(anchor="e", padx=18, pady=6)
        return sw


    def get_auto_print_invoice(self):
        try:
            return bool(self.settings.get("auto_print_invoice", False))
        except Exception:
            return False

    def _save_auto_print_invoice_setting(self, enabled):
        try:
            self.settings["auto_print_invoice"] = bool(enabled)
        except Exception:
            pass


    def show_settings(self):
        if not self._guard_db_nav("الإعدادات", "ضبط النظام والشبكة", "settings"):
            return
        self.clear_content()
        self.current_page = "settings"
        self.highlight_nav()
        self.page_header(
            "الإعدادات",
            "إعدادات المتجر والفواتير والبيع وحماية البيانات"
        )

        scroll = ctk.CTkScrollableFrame(
            self.content_area, fg_color="transparent"
        )
        scroll.pack(fill="both", expand=True)

        # معلومات المتجر
        store = self.make_card(scroll)
        store.pack(fill="x", pady=5)

        ctk.CTkLabel(
            store, text=self.t("🏪 معلومات المتجر"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 5))

        ctk.CTkLabel(
            store, text=self.t("تظهر هذه المعلومات في الفواتير."),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10
            ),
            text_color=self.muted()
        ).pack(anchor="e", padx=18, pady=(0, 8))

        store_name = self._settings_entry(
            store, "اسم المتجر", self.settings.get("store_name")
        )
        store_phone = self._settings_entry(
            store, "رقم الهاتف", self.settings.get("store_phone")
        )
        store_address = self._settings_entry(
            store, "العنوان", self.settings.get("store_address")
        )

        # الفواتير والطباعة
        invoice = self.make_card(scroll)
        invoice.pack(fill="x", pady=5)

        ctk.CTkLabel(
            invoice, text=self.t("🧾 الفواتير والطباعة"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 8))

        paper_row = ctk.CTkFrame(
            invoice, fg_color="transparent"
        )
        paper_row.pack(fill="x", padx=18, pady=7)

        ctk.CTkLabel(
            paper_row, text=self.t("حجم الفاتورة الافتراضي"),
            width=170, anchor="e",
            font=ctk.CTkFont(
                family=self.ui_font_family, size=11
            ),
            text_color=self.text()
        ).pack(side="right", padx=(10, 0))

        paper_var = tk.StringVar(
            value=self.settings.get("default_paper", "80mm")
        )

        ctk.CTkRadioButton(
            paper_row, text=self.t("80mm"),
            variable=paper_var, value="80mm"
        ).pack(side="right", padx=10)

        ctk.CTkRadioButton(
            paper_row, text=self.t("A4"),
            variable=paper_var, value="A4"
        ).pack(side="right", padx=10)

        auto_print = self._settings_switch(
            invoice,
            "طباعة الفاتورة تلقائياً بعد الدفع",
            self.settings.get("auto_print_invoice", False)
        )

        ask_print = self._settings_switch(
            invoice,
            "اسألني قبل طباعة الفاتورة",
            self.settings.get("ask_before_print", True)
        )

        footer = self._settings_entry(
            invoice, "رسالة أسفل الفاتورة",
            self.settings.get(
                "invoice_footer", "شكرًا لزيارتكم"
            )
        )

        # البيع والديون
        sales = self.make_card(scroll)
        sales.pack(fill="x", pady=5)

        ctk.CTkLabel(
            sales, text=self.t("💰 البيع والديون"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 5))

        allow_debt = self._settings_switch(
            sales,
            "السماح بتسجيل المبيعات بالدين",
            self.settings.get("allow_debt", True)
        )

        # حد الخصم الذي يتطلب رمز PIN عند تجاوزه.
        pin_threshold = self._settings_entry(
            sales,
            "حد الخصم الذي يتطلب رمز PIN",
            self.settings.get("pin_discount_threshold", 500),
            width=180
        )

        # المخزون
        stock = self.make_card(scroll)
        stock.pack(fill="x", pady=5)

        ctk.CTkLabel(
            stock, text=self.t("📦 المخزون"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 5))

        threshold = self._settings_entry(
            stock,
            "حد المخزون المنخفض",
            self.settings.get("low_stock_threshold", 5),
            width=180
        )

        # قاعدة البيانات — اتصال MySQL/MariaDB للمشاركة بين عدة أجهزة.
        db_card = self.make_card(scroll)
        db_card.pack(fill="x", pady=5)

        ctk.CTkLabel(
            db_card, text=self.t("🔌 قاعدة البيانات"),
            font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 3))

        ctk.CTkLabel(
            db_card,
            text=self.t("الاتصال بخادم MySQL/MariaDB لمشاركة البيانات بين عدة أجهزة."),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(anchor="e", padx=18, pady=(0, 8))

        _mode_label_text = self._network_mode_label((getattr(self.db, "config", {}) or {}).get("network_mode"))
        ctk.CTkLabel(
            db_card,
            text=f"{self.t('الوضع الحالي')}: {self.t(_mode_label_text)}",
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            text_color=self.colors["primary"]
        ).pack(anchor="e", padx=18, pady=(0, 8))

        _db_cfg = getattr(self.db, "config", {}) or {}
        db_host = self._settings_entry(db_card, "عنوان الخادم",
                                       _db_cfg.get("host", "localhost"), width=180)
        db_pc_ip = self._settings_entry(
            db_card,
            "عنوان IP لهذا الجهاز",
            str(_db_cfg.get("local_ip") or "") or self._resolved_local_ip(),
            width=180
        )
        db_port = self._settings_entry(db_card, "المنفذ", _db_cfg.get("port", 3306), width=180)
        db_user = self._settings_entry(db_card, "اسم المستخدم", _db_cfg.get("user", "root"), width=180)
        db_password = self._settings_entry_with_eye(
            db_card, "كلمة المرور", _db_cfg.get("password", ""), width=180
        )
        db_name = self._settings_entry(db_card, "اسم قاعدة البيانات",
                                       _db_cfg.get("database", "supermarket_pro"), width=180)

        def save_db_settings():
            # تعديل إعدادات قاعدة البيانات إجراء حساس: يتطلب رمز PIN بصلاحية مدير.
            if not self.require_pin("تعديل إعدادات قاعدة البيانات", "admin"):
                return
            try:
                port_value = int(str(db_port.get()).strip() or 3306)
                if not (0 < port_value < 65536):
                    raise ValueError
            except Exception:
                self.toast(self.t("المنفذ يجب أن يكون رقمًا صحيحًا بين 1 و 65535"), "danger")
                return

            candidate = {
                "host": str(db_host.get()).strip() or "localhost",
                "port": port_value,
                "user": str(db_user.get()).strip() or "root",
                "password": str(db_password.get()),
                "database": str(db_name.get()).strip() or "supermarket_pro",
                # عنوان IP هذا الجهاز: قيمة مخصصة، أو None للاكتشاف التلقائي.
                "local_ip": str(db_pc_ip.get()).strip() or None,
                # الحفاظ على الدور الحالي (server/client/local) والربط بين
                # الأجهزة عند الحفظ، وإلا يُكتب network_mode: null في الملف
                # ويعرض معالج الإعداد الأول عند إعادة التشغيل.
                "network_mode": (
                    get_active_config().get("network_mode")
                    or self.db.config.get("network_mode")
                ),
                "store_linked": bool(
                    get_active_config().get("store_linked", False)
                    or self.db.config.get("store_linked", False)
                ),
            }

            ok, message = test_database_connection(candidate, create_database=True)
            if not ok:
                self.toast(f"{self.t('فشل الاتصال بالخادم')}:\n{message}", "danger")
                return

            if save_database_config(candidate):
                self.log_action("db_config_updated", "settings", None,
                                f"{candidate['host']}:{candidate['port']}/{candidate['database']}")
                self.toast(
                    self.t("تم حفظ إعدادات قاعدة البيانات. أعد تشغيل البرنامج لتطبيق التغييرات."),
                    "success"
                )
            else:
                self.toast(self.t("تعذر حفظ ملف الإعدادات"), "danger")

        ctk.CTkButton(
            db_card,
            text="🔌 " + self.t("اختبار وحفظ الاتصال"),
            command=save_db_settings,
            height=42,
            corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(fill="x", padx=18, pady=(4, 6))

        ctk.CTkButton(
            db_card,
            text="🌐 " + self.t("تغيير وضع الشبكة"),
            command=self._toggle_network_mode_from_settings,
            height=42,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(fill="x", padx=18, pady=(0, 16))

        # اللغة
        language_card = self.make_card(scroll)
        language_card.pack(fill="x", pady=5)

        ctk.CTkLabel(
            language_card, text=self.t("اللغة"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ), text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 5))

        ctk.CTkLabel(
            language_card, text=self.t("اختر لغة البرنامج"),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(anchor="e", padx=18, pady=(0, 8))

        language_row = ctk.CTkFrame(language_card, fg_color="transparent")
        language_row.pack(fill="x", padx=18, pady=(0, 16))

        def lang_button(label, code):
            active = self.language == code
            return ctk.CTkButton(
                language_row,
                text=label,
                command=lambda c=code: self._set_language(c),
                height=44, width=130, corner_radius=9,
                fg_color=self.colors["primary"] if active else self.card(),
                hover_color=self.colors["primary_hover"] if active else self.border(),
                text_color="white" if active else self.text(),
                border_width=0 if active else 1,
                border_color=self.border(),
                font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
            )

        lang_button("العربية", "ar").pack(side="right", padx=5)
        lang_button("Français", "fr").pack(side="right", padx=5)
        lang_button("English", "en").pack(side="right", padx=5)

        # المظهر: ثلاثة أزرار متجاورة كما طلبت.
        appearance = self.make_card(scroll)
        appearance.pack(fill="x", pady=5)

        ctk.CTkLabel(
            appearance, text=self.t("🎨 المظهر"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=16, weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 5))

        ctk.CTkLabel(
            appearance,
            text=self.t("اختر مظهر البرنامج"),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=10
            ),
            text_color=self.muted()
        ).pack(anchor="e", padx=18, pady=(0, 8))

        theme_row = ctk.CTkFrame(
            appearance, fg_color="transparent"
        )
        theme_row.pack(
            fill="x", padx=18, pady=(0, 16)
        )

        def theme_button(parent, label, mode):
            label = self.t(label)
            active = self.theme_mode == mode
            return ctk.CTkButton(
                parent,
                text=label,
                command=lambda: self._set_theme_mode(mode, save=False),
                height=44,
                width=120,
                corner_radius=9,
                fg_color=(
                    self.colors["primary"]
                    if active else self.card()
                ),
                hover_color=(
                    self.colors["primary_hover"]
                    if active else self.border()
                ),
                text_color=(
                    "white" if active else self.text()
                ),
                border_width=0 if active else 1,
                border_color=self.border(),
                font=ctk.CTkFont(
                    family=self.ui_font_family,
                    size=11,
                    weight="bold"
                )
            )

        theme_button(theme_row, "☀ فاتح", "light").pack(
            side="right", padx=5
        )
        theme_button(theme_row, "● داكن", "dark").pack(
            side="right", padx=5
        )
        theme_button(theme_row, "■ رمادي", "grey").pack(
            side="right", padx=5
        )

        # الإجراءات
        actions = ctk.CTkFrame(
            scroll, fg_color="transparent"
        )
        actions.pack(fill="x", pady=12)

        def save_settings():
            # حفظ الإعدادات إجراء حساس: يتطلب رمز PIN بصلاحية مدير.
            if not self.require_pin("حفظ الإعدادات", "admin"):
                return

            try:
                threshold_value = int(
                    float(
                        threshold.get().strip().replace(",", ".")
                    )
                )
                if threshold_value < 0:
                    raise ValueError
            except Exception:
                self.toast(
                    "حد المخزون يجب أن يكون رقماً صحيحاً موجباً أو صفراً.",
                    "danger"
                )
                return

            try:
                pin_threshold_value = int(
                    float(
                        pin_threshold.get().strip().replace(",", ".")
                    )
                )
                if pin_threshold_value < 0:
                    raise ValueError
            except Exception:
                self.toast(
                    "حد الخصم الذي يتطلب PIN يجب أن يكون رقماً صحيحاً موجباً أو صفراً.",
                    "danger"
                )
                return

            self.settings.update({
                "store_name": (
                    store_name.get().strip()
                    or "Supermarket Pro"
                ),
                "store_phone": store_phone.get().strip(),
                "store_address": store_address.get().strip(),
                "invoice_footer": (
                    footer.get().strip()
                    or "شكرًا لزيارتكم"
                ),
                "default_paper": paper_var.get(),
                "auto_print_invoice": bool(auto_print.get()),
                "ask_before_print": bool(ask_print.get()),
                "allow_debt": bool(allow_debt.get()),
                "low_stock_threshold": threshold_value,
                "pin_discount_threshold": pin_threshold_value,
                "theme_mode": self.theme_mode,
                "appearance": self.theme_mode,
            })

            if self.save_app_settings():
                self.log_action("settings_updated", "settings", None)
                self.toast(
                    "تم حفظ الإعدادات بنجاح.",
                    "success"
                )

        ctk.CTkButton(
            actions,
            text=self.t("💾 حفظ الإعدادات"),
            command=save_settings,
            height=46,
            width=190,
            corner_radius=9,
            fg_color=self.colors["primary"],
            hover_color=self.colors["primary_hover"],
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=11,
                weight="bold"
            )
        ).pack(side="right", padx=5)

        ctk.CTkButton(
            actions,
            text=self.t("💾 نسخة احتياطية الآن"),
            command=self.backup_database,
            height=46,
            width=190,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border()
        ).pack(side="right", padx=5)

        # إدارة التصنيفات والمستخدمين وسجل النشاطات.
        mgmt_row = ctk.CTkFrame(
            scroll, fg_color="transparent"
        )
        mgmt_row.pack(fill="x", pady=(0, 8))

        ctk.CTkButton(
            mgmt_row,
            text=self.t("👥 المستخدمون"),
            command=self.open_users_manager,
            height=42,
            width=160,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=11,
                weight="bold"
            )
        ).pack(side="right", padx=5)

        ctk.CTkButton(
            mgmt_row,
            text=self.t("🏷 التصنيفات"),
            command=self.open_categories_manager,
            height=42,
            width=160,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=11,
                weight="bold"
            )
        ).pack(side="right", padx=5)

        ctk.CTkButton(
            mgmt_row,
            text=self.t("📋 سجل النشاطات"),
            command=self.open_audit_log,
            height=42,
            width=170,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=11,
                weight="bold"
            )
        ).pack(side="right", padx=5)

        ctk.CTkButton(
            mgmt_row,
            text="⌨ " + self.t("اختصارات لوحة المفاتيح"),
            height=38,
            corner_radius=9,
            fg_color=self.card(),
            hover_color=self.border(),
            text_color=self.text(),
            border_width=1,
            border_color=self.border(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
            command=self.show_shortcuts_modal
        ).pack(side="right", padx=4)

        license_frame = self.make_card(scroll)
        license_frame.pack(fill="x", pady=5)

        ctk.CTkLabel(
            license_frame,
            text=self.t("معلومات الترخيص"),
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=16,
                weight="bold"
            ),
            text_color=self.text()
        ).pack(anchor="e", padx=18, pady=(15, 10))

        try:
            from security.license import LicenseManager
            license_info = LicenseManager().get_license_info()
        except Exception:
            license_info = None

        ctk.CTkLabel(
            license_frame,
            text=(
                f"{self.t('✓ البرنامج مفعل — ')}{license_info[1]}"
                if license_info
                else self.t("معلومات الترخيص غير متوفرة")
            ),
            font=ctk.CTkFont(
                family=self.ui_font_family,
                size=11,
                weight="bold"
            ),
            text_color=(
                self.colors["secondary"]
                if license_info
                else self.colors["danger"]
            )
        ).pack(anchor="e", padx=18, pady=(0, 16))

    # =========================================================
    # Exit
    # =========================================================


        auto_print_invoice_var = tk.BooleanVar(
            value=self.get_auto_print_invoice()
        )
        self.auto_print_invoice_var = auto_print_invoice_var

        ctk.CTkLabel(
            actions,
            text=self.t("طباعة الفاتورة بعد الدفع"),
            anchor="e",
            text_color=self.text(),
            font=ctk.CTkFont(
                family=self.ui_font_family, size=12, weight="bold"
            )
        ).pack(fill="x", padx=20, pady=(10, 3))

        ctk.CTkSwitch(
            actions,
            text=self.t("طباعة الفاتورة تلقائياً"),
            variable=auto_print_invoice_var,
            onvalue=True,
            offvalue=False
        ).pack(anchor="e", padx=20, pady=(0, 10))


    # ------------------------------------------------------------------
    # RTL/LTR helpers & Keyboard Shortcuts modal
    # ------------------------------------------------------------------

    def flow(self, side):
        """Flip horizontal direction for LTR languages (en/fr)."""
        if getattr(self, "language", "ar") in ("en", "fr"):
            return "left" if side == "right" else "right"
        return side

    def align(self):
        """Text anchor for the current UI language direction."""
        return "w" if getattr(self, "language", "ar") in ("en", "fr") else "e"

    def show_shortcuts_modal(self):
        win = ctk.CTkToplevel(self)
        win.title(self.t("اختصارات لوحة المفاتيح"))
        win.geometry("620x580")
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 620, 580)
        win.bind("<Escape>", lambda e: win.destroy())

        container = ctk.CTkFrame(win, fg_color=self.bg())
        container.pack(fill="both", expand=True, padx=20, pady=20)

        head = ctk.CTkFrame(container, fg_color="transparent")
        head.pack(fill="x", pady=(0, 12))
        ctk.CTkLabel(
            head,
            text="⌨ " + self.t("دليل اختصارات لوحة المفاتيح"),
            font=ctk.CTkFont(family=self.ui_font_family, size=18, weight="bold"),
            text_color=self.text()
        ).pack(side=self.flow("right"))

        ctk.CTkLabel(
            head,
            text=self.t("اضغط Escape للإغلاق"),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(side=self.flow("left"), pady=4)

        scroll = ctk.CTkScrollableFrame(container, fg_color=self.card(), corner_radius=12)
        scroll.pack(fill="both", expand=True)

        shortcuts_list = [
            ("F1",  self.t("نقطة البيع (POS)"),               self.t("الانتقال الفوري إلى شاشة البيع والكاشير الرئيسية")),
            ("F2",  self.t("إدارة المنتجات"),                   self.t("فتح قائمة المنتجات لتعديل الأسعار أو مراجعة المخزون")),
            ("F3",  self.t("إضافة منتج جديد"),                 self.t("فتح نافذة تسجيل صنف جديد في المتجر")),
            ("F4",  self.t("التركيز على البحث"),               self.t("نقل المؤشر مباشرة لخانة البحث لمسح الباركود في أي شاشة")),
            ("F5",  self.t("تحديث البيانات"),                   self.t("إعادة تحميل وتحديث الصفحة والبيانات الحالية")),
            ("F6",  self.t("اختيار العميل"),                   self.t("تحديد زبون نقدي أو اختيار عميل لتسجيل البيع بالدين")),
            ("F7",  self.t("خصم الفاتورة / المنتج"),           self.t("تطبيق تخفيض بمبلغ ثابت (دج) أو نسبة مئوية (%)")),
            ("F8",  self.t("الدفع وإتمام البيع"),              self.t("تأكيد واستلام المبلغ وإنهاء عملية البيع وطباعة الفاتورة")),
            ("F9",  self.t("تعليق السلة الحالية"),             self.t("حفظ سلة الزبون مؤقتاً لخدمة زبون آخر سريعاً")),
            ("F10", self.t("السلات المعلقة"),                  self.t("استعراض قائمة السلات المؤجلة لاسترجاعها أو حذفها")),
            ("F12", self.t("تفريغ ومسح السلة"),               self.t("إلغاء وإفراغ جميع محتويات السلة بعد التأكيد")),
            ("Ctrl + F", self.t("البحث العام"),                self.t("نقل المؤشر إلى خانة البحث في الصفحة النشطة")),
            ("Ctrl + N", self.t("منتج جديد سريع"),            self.t("اختصار بديل لإضافة صنف جديد")),
            ("Escape", self.t("إلغاء / إغلاق النوافذ"),        self.t("إغلاق أي نافذة منبثقة مفتوحة أو مسح خانة البحث")),
        ]

        for key, title, desc in shortcuts_list:
            row = ctk.CTkFrame(scroll, fg_color=self.bg(), corner_radius=9)
            row.pack(fill="x", padx=6, pady=3)

            badge = ctk.CTkLabel(
                row, text=key, width=80, height=32, corner_radius=7,
                fg_color=self.colors["primary"], text_color="white",
                font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
            )
            badge.pack(side=self.flow("right"), padx=10, pady=8)

            info = ctk.CTkFrame(row, fg_color="transparent")
            info.pack(side=self.flow("right"), fill="x", expand=True, padx=8)

            ctk.CTkLabel(
                info, text=self.t(title),
                font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
                text_color=self.text(), anchor=self.align()
            ).pack(fill="x")

            ctk.CTkLabel(
                info, text=self.t(desc),
                font=ctk.CTkFont(family=self.ui_font_family, size=10),
                text_color=self.muted(), anchor=self.align()
            ).pack(fill="x", pady=(2, 0))

        ctk.CTkButton(
            container, text=self.t("إغلاق"),
            height=38, corner_radius=9,
            fg_color=self.card(), hover_color=self.border(),
            text_color=self.text(), border_width=1, border_color=self.border(),
            command=win.destroy
        ).pack(fill="x", pady=(12, 0))

    def quit_app(self):
        if self.confirm(
            "تأكيد الخروج",
            "هل أنت متأكد من إغلاق البرنامج؟"
        ):
            self.destroy()

    def _on_main_close(self):
        """معالج زر إغلاق النافذة (X) — إغلاق نظيف ومضمون حتى عند انقطاع
        الاتصال بقاعدة البيانات، فلا تبقى العملية عالقة أو غير قابلة للإغلاق."""
        try:
            responder = getattr(self, "_discovery_responder", None)
            if responder is not None:
                responder.stop()
                self._discovery_responder = None
        except Exception:
            pass
        try:
            self.destroy()
        except Exception:
            pass


    # ========================================
    # المشتريات (فواتير الشراء من الموردين)
    # ========================================
    def show_purchases(self):
        """صفحة المشتريات: فواتير الشراء من الموردين مع ملخص ومتابعة الحسابات الدائنة."""
        if not self._guard_db_nav("المشتريات", "إدارة فواتير الشراء من الموردين", "purchases"):
            return
        self.clear_content()
        self.current_page = "purchases"
        self.highlight_nav()

        self.page_header("🛒 المشتريات", "فواتير الشراء من الموردين")

        action_bar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        action_bar.pack(fill="x", pady=(0, 10))

        search_var = tk.StringVar()
        search_entry = ctk.CTkEntry(
            action_bar, textvariable=search_var, height=38, corner_radius=9,
            placeholder_text=self.t("ابحث برقم الفاتورة أو اسم المورد..."),
            font=ctk.CTkFont(family=self.ui_font_family, size=11)
        )
        search_entry.pack(side=self.flow("right"), padx=(0, 8), fill="x", expand=True)

        ctk.CTkButton(
            action_bar, text=self.t("＋ فاتورة شراء جديدة"), command=self._open_purchase_form,
            height=38, width=210, corner_radius=9,
            fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
            text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold")
        ).pack(side=self.flow("right"))

        scroll = ctk.CTkScrollableFrame(self.content_area, fg_color="transparent")
        scroll.pack(fill="both", expand=True)

        is_server = str(get_active_config().get("network_mode") or "").strip().lower() == "server"

        def _fetch():
            dev = None if is_server else self._get_device_name()
            term = search_var.get().strip()
            try:
                return self.db.get_purchases(search=term or None, device_name=dev, limit=300)
            except Exception:
                return []

        rows = _fetch()
        total_gross = sum(float(r[3] or 0) for r in rows)
        total_discount = sum(float(r[5] or 0) for r in rows)
        total_paid = sum(float(r[4] or 0) for r in rows)
        total_remaining = sum(float(r[3] or 0) - float(r[5] or 0) - float(r[4] or 0) for r in rows)
        total_remaining = max(0.0, total_remaining)
        try:
            suppliers_balance = sum(float(s[3] or 0) for s in (self.db.get_suppliers() or []))
        except Exception:
            suppliers_balance = 0.0

        summary_card = self.make_card(scroll)
        summary_card.pack(fill="x", pady=(0, 10))
        sum_hdr = ctk.CTkFrame(summary_card, fg_color="transparent")
        sum_hdr.pack(fill="x", padx=16, pady=(14, 8))
        ctk.CTkLabel(
            sum_hdr, text=self.t("📊 ملخص المشتريات"),
            font=ctk.CTkFont(family=self.ui_font_family, size=15, weight="bold"),
            text_color=self.text()
        ).pack(side=self.flow("right"))
        ctk.CTkLabel(
            sum_hdr, text=self.t("العمليات الأخيرة"),
            font=ctk.CTkFont(family=self.ui_font_family, size=10),
            text_color=self.muted()
        ).pack(side=self.flow("left"), pady=4)
        sum_bar = ctk.CTkFrame(summary_card, fg_color=self.bg(), corner_radius=10)
        sum_bar.pack(fill="x", padx=14, pady=(0, 14))
        metrics = [
            (self.t("إجمالي المشتريات"), total_gross),
            (self.t("المدفوع"), total_paid),
            (self.t("المتبقي"), total_remaining),
            (self.t("رصيد الموردين"), suppliers_balance),
            (self.t("عدد الفواتير"), len(rows)),
        ]
        for i, (lbl, val) in enumerate(metrics):
            sum_bar.grid_columnconfigure(i, weight=1)
            cell = ctk.CTkFrame(sum_bar, fg_color="transparent")
            cell.grid(row=0, column=i, sticky="nsew", padx=8, pady=12)
            txt = self.t(f"{val:,.0f} د.ج") if isinstance(val, float) or isinstance(val, int) else str(val)
            ctk.CTkLabel(cell, text=lbl, font=ctk.CTkFont(family=self.ui_font_family, size=10), text_color=self.muted()).pack(anchor=self.align())
            ctk.CTkLabel(cell, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"), text_color=self.text()).pack(anchor=self.align(), pady=(3, 0))

        table_card = self.make_card(scroll)
        table_card.pack(fill="x", pady=(0, 10))

        hdr = ctk.CTkFrame(table_card, fg_color=self.card(), corner_radius=8)
        hdr.pack(fill="x", padx=14, pady=(14, 3))
        cols = ["#", self.t("رقم الفاتورة"), self.t("المورد"), self.t("الإجمالي"),
                self.t("الخصم"), self.t("المدفوع"), self.t("المتبقي"), self.t("التاريخ"), ""]
        weights = [0, 3, 2, 2, 1, 1, 1, 2, 3]
        for ci, txt in enumerate(cols):
            hdr.grid_columnconfigure(ci, weight=weights[ci])
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                         text_color=self.muted(), anchor=self.align()).grid(row=0, column=ci, sticky="ew", padx=6, pady=7)

        def _refresh(_event=None):
            for w in table_card.winfo_children()[1:]:
                w.destroy()
            data = _fetch()
            if not data:
                ctk.CTkLabel(table_card, text=self.t("لم يتم العثور على نتائج"),
                             font=ctk.CTkFont(family=self.ui_font_family, size=12), text_color=self.muted()).pack(pady=25)
                return
            for ri, rec in enumerate(data):
                pid, inum, sname, gross, paid, disc, pdate, devn, note = rec
                remaining = max(0.0, float(gross or 0) - float(disc or 0) - float(paid or 0))
                rw = ctk.CTkFrame(table_card, fg_color=self.bg() if ri % 2 == 0 else self.card(), corner_radius=7)
                rw.pack(fill="x", padx=14, pady=1)
                vals = [str(pid), str(inum or ""), str(sname or "-")[:30], f"{float(gross or 0):,.0f}",
                        f"{float(disc or 0):,.0f}", f"{float(paid or 0):,.0f}", f"{remaining:,.0f}", str(pdate or "")[:16]]
                for ci, val in enumerate(vals):
                    rw.grid_columnconfigure(ci, weight=weights[ci])
                    color = self.colors["danger"] if ci == 6 and remaining > 0 else self.text()
                    ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10),
                                 text_color=color, anchor=self.align()).grid(row=0, column=ci, sticky="ew", padx=6, pady=6)
                btns = ctk.CTkFrame(rw, fg_color="transparent")
                btns.grid(row=0, column=len(vals), padx=4, pady=4)
                ctk.CTkButton(btns, text=self.t("عرض"), width=46, height=26, corner_radius=6,
                              fg_color=self.bg(), hover_color=self.border(), text_color=self.colors["info"],
                              font=ctk.CTkFont(family=self.ui_font_family, size=10),
                              command=lambda pid2=pid: self._show_purchase_details(pid2)).pack(side="left", padx=2)
                ctk.CTkButton(btns, text=self.t("تسديد"), width=56, height=26, corner_radius=6,
                              fg_color=self.bg(), hover_color=self.border(), text_color=self.colors["secondary"],
                              font=ctk.CTkFont(family=self.ui_font_family, size=10),
                              command=self._pay_supplier_dialog).pack(side="left", padx=2)
                ctk.CTkButton(btns, text="🗑", width=30, height=26, corner_radius=6, fg_color="transparent",
                              hover_color=self.colors["danger"], text_color=self.colors["danger"],
                              font=ctk.CTkFont(size=12),
                              command=lambda pid2=pid: self._delete_purchase_flow(pid2)).pack(side="left", padx=2)

        _refresh()
        search_entry.bind("<Return>", _refresh)

    def _open_purchase_form(self):
        """نافذة تسجيل فاتورة شراء جديدة من مورد (مخزون + رصيد المورد + حركات مخزون + متغيرات)."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("فاتورة شراء جديدة"))
        win.transient(self)
        win.grab_set()
        self.center_window(win, 1140, 790)
        try:
            win.minsize(980, 560)
        except Exception:
            pass

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=14, pady=14)

        ctk.CTkFrame(card, fg_color=self.colors["primary"], height=5, corner_radius=0).pack(fill="x")
        head = ctk.CTkFrame(card, fg_color="transparent")
        head.pack(fill="x", padx=18, pady=(12, 8))
        ctk.CTkLabel(head, text=self.t("🛒 فاتورة شراء جديدة"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold"),
                     text_color=self.colors["primary"]).pack(side=self.flow("right"))
        ctk.CTkLabel(head, text=self.t("تسجيل مشتريات من المورد مع تحديث المخزون والرصيد"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=10),
                     text_color=self.muted()).pack(side=self.flow("left"), pady=4)

        scroll_body = ctk.CTkScrollableFrame(card, fg_color="transparent", corner_radius=0)
        scroll_body.pack(fill="both", expand=True, padx=8, pady=(0, 4))

        body = ctk.CTkFrame(scroll_body, fg_color="transparent")
        body.pack(fill="both", expand=True)

        left = ctk.CTkFrame(body, fg_color="transparent")
        left.pack(side=self.flow("right"), fill="both", expand=True, padx=(0, 8))
        right = ctk.CTkFrame(body, fg_color="transparent", width=330)
        right.pack(side=self.flow("right"), fill="y")
        try:
            right.pack_propagate(False)
        except Exception:
            pass

        # ===================== المورد =====================
        ctk.CTkLabel(left, text=self.t("المورد *"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        supplier_row = ctk.CTkFrame(left, fg_color="transparent")
        supplier_row.pack(fill="x", pady=(2, 2))

        try:
            suppliers = self.db.get_suppliers() or []
        except Exception:
            suppliers = []
        supplier_ids = [int(s[0]) for s in suppliers]
        supplier_names = [str(s[1] or "") for s in suppliers]
        supplier_var = tk.StringVar(value=supplier_names[0] if supplier_names else "")
        menu = ctk.CTkOptionMenu(supplier_row, variable=supplier_var, values=supplier_names,
                                 height=38, font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                 fg_color=self.bg(), button_color=self.colors["primary"],
                                 button_hover_color=self.colors["primary_hover"])
        menu.pack(side=self.flow("right"), fill="x", expand=True)

        ctk.CTkButton(supplier_row, text=self.t("＋"), width=40, height=38, corner_radius=9,
                      fg_color=self.colors["secondary"], hover_color="#16A34A",
                      text_color="white", font=ctk.CTkFont(size=16),
                      command=lambda: self._quick_add_supplier_form(
                          parent_win=win,
                          callback=_after_quick_add)).pack(side=self.flow("right"), padx=(6, 0))

        def _after_quick_add(new_id, name):
            if name not in supplier_names:
                suppliers.append((int(new_id), name, "", 0.0))
                supplier_names.append(name)
                supplier_ids.append(int(new_id))
                menu.configure(values=supplier_names)
            supplier_var.set(name)
            _update_supplier_hint()

        supplier_hint = ctk.CTkLabel(left, text=self.t("رصيد المورد: 0.00 د.ج"),
                                     anchor=self.align(),
                                     font=ctk.CTkFont(family=self.ui_font_family, size=9),
                                     text_color=self.muted())
        supplier_hint.pack(anchor=self.align(), fill="x", pady=(2, 6))

        def _supplier_balance(name=""):
            try:
                idx = supplier_names.index(name)
                return float(suppliers[idx][3] or 0)
            except Exception:
                return 0.0

        def _update_supplier_hint(_name=None):
            bal = _supplier_balance(supplier_var.get())
            supplier_hint.configure(text=self.t("رصيد المورد:") + self.t(f" {bal:,.2f} د.ج"))

        menu.configure(command=_update_supplier_hint)

        # ===================== بحث المنتجات =====================
        ctk.CTkLabel(left, text=self.t("البحث في المنتجات"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        search_var = tk.StringVar()
        search_entry = ctk.CTkEntry(left, textvariable=search_var, height=42, corner_radius=9,
                                    placeholder_text=self.t("ابحث بالاسم أو الباركود..."),
                                    font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                    fg_color=self.bg(), border_color=self.border())
        search_entry.pack(fill="x", pady=(2, 4))

        prev_hint = ctk.CTkLabel(left, text=self.t("سعر الشراء السابق: —"), anchor=self.align(),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=9),
                                 text_color=self.colors["secondary"])
        prev_hint.pack(anchor=self.align(), fill="x", pady=(0, 2))

        results_container = ctk.CTkScrollableFrame(left, fg_color=self.bg(), corner_radius=9, height=170)
        results_container.pack(fill="x")

        ctk.CTkLabel(left,
                     text=self.t("تلميح: انقر على المنتج لإضافته فورًا، ثم عدّل الكمية والسعر في قائمة البنود."),
                     font=ctk.CTkFont(family=self.ui_font_family, size=9),
                     text_color=self.muted(), anchor=self.align(), wraplength=560).pack(anchor=self.align(), fill="x", pady=(6, 4))

        # ===================== بنود الفاتورة (سلة قابلة للتعديل) =====================
        cart = []
        discount_var = tk.StringVar(value="0")
        paid_var = tk.StringVar(value="")
        note_var = tk.StringVar(value="")
        mode_labels = [self.t("نقدًا"), self.t("على الحساب"), self.t("دفعة جزئية")]
        mode_var = tk.StringVar(value=mode_labels[0])

        ctk.CTkLabel(left, text=self.t("المنتجات المختارة"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.text()).pack(anchor=self.align(), fill="x", pady=(4, 2))
        cart_container = ctk.CTkScrollableFrame(left, fg_color=self.bg(), corner_radius=9, height=240)
        cart_container.pack(fill="both", expand=True, pady=(0, 2))

        def _fmt(v):
            return f"{v:,.2f}"

        def current_totals():
            subtotal = sum(float(i["total"]) for i in cart)
            try:
                disc = float(discount_var.get().replace(",", ".").strip() or 0)
            except Exception:
                disc = 0.0
            disc = max(0.0, disc)
            net = max(0.0, subtotal - disc)
            return subtotal, disc, net

        def compute_paid(net):
            mode = mode_var.get()
            if mode == mode_labels[0]:
                return net
            if mode == mode_labels[1]:
                return 0.0
            try:
                v = float(paid_var.get().replace(",", ".").strip() or 0)
            except Exception:
                v = 0.0
            return min(max(0.0, v), net)

        # ===================== عمود الملخص والدفع =====================
        ctk.CTkLabel(right, text=self.t("الملخص والدفع"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"),
                     text_color=self.text()).pack(anchor=self.align(), fill="x", pady=(0, 4))
        summary = ctk.CTkFrame(right, fg_color=self.bg(), corner_radius=9)
        summary.pack(fill="x")

        def _value_row(parent, text, color=None):
            row = ctk.CTkFrame(parent, fg_color="transparent")
            row.pack(fill="x", padx=12, pady=(6, 1))
            ctk.CTkLabel(row, text=text, anchor=self.align(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10),
                         text_color=self.muted()).pack(anchor=self.align(), side=self.flow("right"))
            val = ctk.CTkLabel(row, text=self.t("0.00 د.ج"), anchor=self.align(),
                               font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                               text_color=color or self.text())
            val.pack(anchor=self.align(), side=self.flow("left"))
            return val

        subtotal_label = _value_row(summary, self.t("المجموع الفرعي"))
        discount_label = _value_row(summary, self.t("الخصم"))
        net_label = _value_row(summary, self.t("الإجمالي"), self.colors["primary"])
        paid_label = _value_row(summary, self.t("المدفوع"), self.colors["secondary"])
        remain_label = _value_row(summary, self.t("المتبقي"), self.colors["danger"])

        ctk.CTkLabel(right, text=self.t("طريقة الدفع"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x", pady=(10, 2))
        seg = ctk.CTkSegmentedButton(right, values=mode_labels, variable=mode_var, height=34,
                                     font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                     fg_color=self.bg(), selected_color=self.colors["primary"], corner_radius=8)
        seg.pack(fill="x", pady=(0, 6))

        def _on_mode(_choice=None):
            _, _, net = current_totals()
            if mode_var.get() == mode_labels[2]:
                paid_entry.configure(state="normal")
                paid_var.set(f"{net:,.2f}")
            else:
                paid_entry.configure(state="disabled")
                paid_var.set("" if mode_var.get() == mode_labels[0] else "0.00")
            update_sums()

        seg.configure(command=_on_mode)

        ctk.CTkLabel(right, text=self.t("المبلغ المدفوع (د.ج)"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        paid_entry = ctk.CTkEntry(right, textvariable=paid_var, height=32, corner_radius=8,
                                  placeholder_text=self.t("المبلغ المدفوع"), state="disabled",
                                  font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                  fg_color=self.bg(), border_color=self.border())
        paid_entry.pack(fill="x", pady=(2, 8))
        paid_entry.bind("<KeyRelease>", lambda e: update_sums())

        ctk.CTkLabel(right, text=self.t("الخصم (د.ج)"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        discount_entry = ctk.CTkEntry(right, textvariable=discount_var, height=32, corner_radius=8,
                                      font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                      fg_color=self.bg(), border_color=self.border())
        discount_entry.pack(fill="x", pady=(2, 8))
        discount_entry.bind("<KeyRelease>", lambda e: update_sums())

        ctk.CTkLabel(right, text=self.t("ملاحظة"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        note_entry = ctk.CTkEntry(right, textvariable=note_var, height=34, corner_radius=8,
                                  placeholder_text=self.t("تشمل التوصيل..."),
                                  font=ctk.CTkFont(family=self.ui_font_family, size=11),
                                  fg_color=self.bg(), border_color=self.border())
        note_entry.pack(fill="x", pady=(2, 0))
        note_entry.bind("<Return>", lambda e: _save())

        def update_sums():
            subtotal, disc, net = current_totals()
            paid = compute_paid(net)
            subtotal_label.configure(text=self.t(f"{_fmt(subtotal)} د.ج"))
            discount_label.configure(text=self.t(f"{_fmt(disc)} د.ج"))
            net_label.configure(text=self.t(f"{_fmt(net)} د.ج"))
            paid_label.configure(text=self.t(f"{_fmt(paid)} د.ج"))
            remain_label.configure(text=self.t(f"{_fmt(max(0.0, net - paid))} د.ج"))

        def cart_key(pid, vid):
            return f"p{int(pid or 0)}-v{int(vid) if vid else 0}"

        _sug = {"rows": [], "idx": -1}

        def clear_suggestions():
            _sug["rows"] = []
            _sug["idx"] = -1
            try:
                for w in results_container.winfo_children():
                    w.destroy()
            except Exception:
                pass

        def _show_prev_hint(name, price_val, _vid=None):
            try:
                pv = float(price_val or 0)
            except Exception:
                pv = 0.0
            text = self.t("سعر الشراء السابق") + self.t(f": {_fmt(pv)} د.ج")
            if name:
                text += f"  •  {str(name)[:26]}"
            prev_hint.configure(text=text)

        def render_cart():
            for w in cart_container.winfo_children():
                w.destroy()
            if not cart:
                cart_container.configure(height=130)
                ctk.CTkLabel(cart_container, text=self.t("لا توجد منتجات في الفاتورة"),
                             font=ctk.CTkFont(family=self.ui_font_family, size=11),
                             text_color=self.muted()).pack(pady=24)
                update_sums()
                return
            hdr = ctk.CTkFrame(cart_container, fg_color="transparent")
            hdr.pack(fill="x", padx=4, pady=(6, 2))
            heads = [self.t("المنتج"), self.t("الكمية"), self.t("سعر الشراء (د.ج)"), self.t("الإجمالي"), ""]
            weights = [4, 1, 1, 1, 0]
            for ci, (txt, wt) in enumerate(zip(heads, weights)):
                hdr.grid_columnconfigure(ci, weight=wt)
                ctk.CTkLabel(hdr, text=txt,
                             font=ctk.CTkFont(family=self.ui_font_family, size=9, weight="bold"),
                             text_color=self.muted(), anchor=self.align()).grid(row=0, column=ci, sticky="ew", padx=6, pady=3)

            def make_edit(var, item, what, label_total):
                def _on_edit(_e=None):
                    vtxt = var.get().replace(",", ".").strip()
                    try:
                        val = float(vtxt)
                    except Exception:
                        return
                    if what == "quantity":
                        if val <= 0:
                            val = item.get("quantity", 1.0)
                        item["quantity"] = val
                    else:
                        item["purchase_price"] = max(0.0, val)
                        _show_prev_hint(item.get("name", ""), item.get("prev_price", 0), item.get("variant_id"))
                    item["total"] = round(item["quantity"] * item["purchase_price"], 2)
                    label_total.configure(text=self.t(f"{_fmt(item['total'])} د.ج"))
                    update_sums()
                return _on_edit

            for item in cart:
                rw = ctk.CTkFrame(cart_container, fg_color=self.card(), corner_radius=7)
                rw.pack(fill="x", padx=4, pady=2)
                for ci, wt in enumerate(weights):
                    rw.grid_columnconfigure(ci, weight=wt)

                name_lbl = ctk.CTkFrame(rw, fg_color="transparent")
                name_lbl.grid(row=0, column=0, sticky="ew", padx=6, pady=4)
                ctk.CTkLabel(name_lbl, text=str(item["name"])[:28], anchor=self.align(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                             text_color=self.text()).pack(anchor=self.align(), fill="x")
                if item.get("prev_price"):
                    ctk.CTkLabel(name_lbl,
                                 text=self.t("سعر الشراء السابق") + self.t(f": {_fmt(item['prev_price'])} د.ج"),
                                 anchor=self.align(),
                                 font=ctk.CTkFont(family=self.ui_font_family, size=8),
                                 text_color=self.colors["secondary"]).pack(anchor=self.align(), fill="x")

                q_var = tk.StringVar(value=f"{item['quantity']:g}")
                p_var = tk.StringVar(value=f"{item['purchase_price']:g}")
                total_lbl = ctk.CTkLabel(rw, text=self.t(f"{_fmt(item['total'])} د.ج"), anchor="center",
                                         font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                                         text_color=self.text())

                q_entry = ctk.CTkEntry(rw, textvariable=q_var, height=30, width=64, corner_radius=6,
                                       font=ctk.CTkFont(family=self.ui_font_family, size=10),
                                       fg_color=self.bg(), border_color=self.border())
                q_entry.grid(row=0, column=1, sticky="ew", padx=3)
                q_entry.bind("<KeyRelease>", make_edit(q_var, item, "quantity", total_lbl))

                p_entry = ctk.CTkEntry(rw, textvariable=p_var, height=30, width=64, corner_radius=6,
                                       font=ctk.CTkFont(family=self.ui_font_family, size=10),
                                       fg_color=self.bg(), border_color=self.border())
                p_entry.grid(row=0, column=2, sticky="ew", padx=3)
                p_entry.bind("<KeyRelease>", make_edit(p_var, item, "price", total_lbl))

                total_lbl.grid(row=0, column=3, sticky="ew", padx=3)

                def _remove(item_key=item["key"]):
                    for j, it in enumerate(cart):
                        if it["key"] == item_key:
                            cart.pop(j)
                            break
                    render_cart()

                ctk.CTkButton(rw, text="✕", width=28, height=28, corner_radius=6, fg_color="transparent",
                              hover_color=self.colors["danger"], text_color=self.colors["danger"],
                              font=ctk.CTkFont(size=13), command=_remove).grid(row=0, column=4, padx=4)
            update_sums()
            n = len(cart)
            cart_container.configure(height=min(560, 76 + n * 52))

        def add_item(pid, vid, name, qty=1, price=0.0, prev_price=0.0, unit=""):
            try:
                q = float(qty or 1)
            except Exception:
                q = 1.0
            if q <= 0:
                q = 1.0
            try:
                p = float(price or 0)
            except Exception:
                p = 0.0
            p = max(0.0, p)
            try:
                pp = float(prev_price or 0)
            except Exception:
                pp = 0.0
            key = cart_key(pid, vid)
            for item in cart:
                if item["key"] == key:
                    item["quantity"] = round(item["quantity"] + q, 4)
                    item["purchase_price"] = p
                    item["total"] = round(item["quantity"] * p, 2)
                    item["prev_price"] = pp if pp > 0 else item.get("prev_price", 0)
                    break
            else:
                cart.append({
                    "key": key, "product_id": int(pid),
                    "variant_id": int(vid) if vid else None,
                    "name": str(name or f"#{int(pid)}"),
                    "quantity": q, "purchase_price": p, "total": round(q * p, 2),
                    "prev_price": pp, "unit": unit or "",
                })
            _show_prev_hint(name, pp or p, vid)
            search_var.set("")
            clear_suggestions()
            render_cart()

        def _pick_variant(entry, variants):
            ppick = ctk.CTkToplevel(win)
            ppick.title(self.t("اختر متغير المنتج"))
            ppick.transient(win)
            ppick.grab_set()
            try:
                self.center_window(ppick, 560, 90 + 58 * max(1, len(variants)))
            except Exception:
                pass
            box = ctk.CTkFrame(ppick, fg_color=self.bg())
            box.pack(fill="both", expand=True, padx=18, pady=18)
            ctk.CTkLabel(box, text=str(entry["nm"]), anchor=self.align(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=16, weight="bold"),
                         text_color=self.text()).pack(anchor=self.align(), fill="x")
            ctk.CTkLabel(box, text=self.t("اختر المتغير ثم اضغط إضافة لتعبئة رصيده"), anchor=self.align(),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10),
                         text_color=self.muted()).pack(anchor=self.align(), fill="x", pady=(2, 8))
            for v in variants:
                vid, vname, vbc, vqty, vprice = v[:5]
                try:
                    vqty = float(vqty or 0)
                except Exception:
                    vqty = 0.0
                row = ctk.CTkFrame(box, fg_color=self.card(), corner_radius=8)
                row.pack(fill="x", pady=3)
                txt = f"{vname}    {self.t('المتاح:')} {vqty:g}"
                if vbc:
                    txt += f"  [{vbc}]"
                ctk.CTkLabel(row, text=txt, anchor=self.align(),
                             font=ctk.CTkFont(family=self.ui_font_family, size=11),
                             text_color=self.text()).pack(side=self.flow("right"), fill="x", expand=True, padx=10, pady=8)

                def _choose(vv=v):
                    try:
                        dp = float(entry["last_pp"]) if float(entry["last_pp"] or 0) > 0 else float(entry["cost"] or 0)
                    except Exception:
                        dp = 0.0
                    ppick.destroy()
                    add_item(entry["pid"], vv[0], f"{entry['nm']} ({vv[1]})", 1, dp, dp, entry.get("unit", ""))

                ctk.CTkButton(row, text=self.t("إضافة"), width=78, height=30, corner_radius=7,
                              fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                              text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=10),
                              command=_choose).pack(side=self.flow("right"), padx=8, pady=6)

        def _pick(entry):
            _show_prev_hint(entry["nm"], entry.get("last_pp", 0), entry.get("vid"))
            if entry.get("vid"):
                add_item(entry["pid"], entry["vid"], entry["nm"], 1,
                         entry.get("last_pp") or entry.get("cost") or 0,
                         entry.get("last_pp") or entry.get("cost") or 0,
                         entry.get("unit", ""))
                return
            variants = []
            try:
                variants = self.db.get_product_variants(entry["pid"]) or []
            except Exception:
                variants = []
            if variants:
                _pick_variant(entry, variants)
            else:
                add_item(entry["pid"], None, entry["nm"], 1,
                         entry.get("last_pp") or entry.get("cost") or 0,
                         entry.get("last_pp") or entry.get("cost") or 0,
                         entry.get("unit", ""))

        def _set_highlight():
            rows = _sug["rows"]
            for i, ent in enumerate(rows):
                try:
                    ent["label"].configure(
                        text_color=self.colors["primary"] if i == _sug["idx"] else self.text()
                    )
                except Exception:
                    pass

        def _do_search(_e=None):
            for w in results_container.winfo_children():
                w.destroy()
            _sug["rows"] = []
            _sug["idx"] = -1
            term = search_var.get().strip()
            if not term:
                prev_hint.configure(text=self.t("سعر الشراء السابق: —"))
                return
            conn = None
            prows = []
            vrows = []
            try:
                conn = self.db.get_connection()
                prows = conn.execute(
                    "SELECT p.id, p.barcode, p.name, p.price, p.cost, p.quantity, p.unit, "
                    "COALESCE((SELECT pi.purchase_price FROM purchase_items pi "
                    "           JOIN purchases pu ON pu.id = pi.purchase_id "
                    "           WHERE pi.product_id = p.id "
                    "           ORDER BY pu.id DESC LIMIT 1), p.cost) AS last_pp "
                    "FROM products p "
                    "WHERE p.name LIKE ? OR p.barcode LIKE ? "
                    "ORDER BY p.name LIMIT 25",
                    (f"%{term}%", f"%{term}%"),
                ).fetchall() or []
                vrows = conn.execute(
                    "SELECT v.id, v.product_id, v.variant_name, v.barcode, v.quantity, v.price, "
                    "p.name, p.unit, "
                    "COALESCE((SELECT pi.purchase_price FROM purchase_items pi "
                    "           WHERE pi.variant_id = v.id ORDER BY pi.id DESC LIMIT 1), p.cost) AS v_last_pp "
                    "FROM product_variants v "
                    "JOIN products p ON p.id = v.product_id "
                    "WHERE v.barcode LIKE ? OR v.variant_name LIKE ? "
                    "ORDER BY v.variant_name LIMIT 25",
                    (f"%{term}%", f"%{term}%"),
                ).fetchall() or []
            except Exception:
                prows = []
                vrows = []
            finally:
                if conn:
                    try:
                        conn.close()
                    except Exception:
                        pass

            entries = []
            for row in prows:
                pid, bc, nm, price, cost, qty, unit, last_pp = row
                entries.append({"kind": "product", "pid": pid, "vid": None, "nm": str(nm or ""),
                                "bc": bc, "stk": qty, "unit": unit or "",
                                "last_pp": last_pp, "cost": cost or price or 0, "vname": None})
            for row in vrows:
                vid, vpid, vname, vbc, vqty, vprice, pname, unit, v_last_pp = row
                entries.append({"kind": "variant", "pid": vpid, "vid": vid,
                                "nm": f"{str(pname or '')} ({str(vname or '')})", "bc": vbc,
                                "stk": vqty, "unit": unit or "", "last_pp": v_last_pp,
                                "cost": vprice or 0, "vname": vname})

            seen = set()
            uniq = []
            for e in entries:
                tag = (e["pid"], e["vid"], str(e["bc"] or "").lower())
                if tag in seen or not str(e["nm"] or "").strip():
                    continue
                seen.add(tag)
                uniq.append(e)
            entries = uniq

            if not entries:
                ctk.CTkLabel(results_container, text=self.t("لا توجد نتائج"),
                             font=ctk.CTkFont(family=self.ui_font_family, size=11),
                             text_color=self.muted()).pack(pady=14)
                prev_hint.configure(text=self.t("سعر الشراء السابق: —"))
                return

            for e in entries:
                rw = ctk.CTkFrame(results_container, fg_color=self.card(), corner_radius=7)
                rw.pack(fill="x", padx=4, pady=2)
                try:
                    stk = float(e["stk"] or 0)
                except Exception:
                    stk = 0.0
                try:
                    lpp = float(e["last_pp"] or 0)
                except Exception:
                    lpp = 0.0
                line1 = str(e["nm"])
                if e["bc"]:
                    line1 += f"  [{e['bc']}]"
                if e["vid"]:
                    line1 += f"  ·  {self.t('متغير')}"
                line2 = self.t(
                    f"المخزون: {stk:g} {e['unit']}"
                    f"    •    سعر الشراء السابق: {lpp:,.2f} د.ج"
                )
                info = ctk.CTkFrame(rw, fg_color="transparent")
                info.pack(side=self.flow("right"), fill="x", expand=True, padx=8, pady=4)
                lbl = ctk.CTkLabel(info, text=f"{line1}\n{line2}", anchor=self.align(), justify="right",
                                   font=ctk.CTkFont(family=self.ui_font_family, size=10),
                                   text_color=self.text())
                lbl.pack(fill="x")
                ctk.CTkButton(rw, text=self.t("＋"), width=30, height=28, corner_radius=6,
                              fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                              text_color="white", font=ctk.CTkFont(size=14),
                              command=lambda ee=e: _pick(ee)).pack(side=self.flow("right"), padx=4)
                _sug["rows"].append({"entry": e, "label": lbl})
                for w_ in (rw, info, lbl):
                    w_.bind("<Button-1>", lambda ev, ee=e: _pick(ee))
                for ch in info.winfo_children():
                    ch.bind("<Button-1>", lambda ev, ee=e: _pick(ee))
            _set_highlight()

        def _move(delta):
            rows = _sug["rows"]
            if not rows:
                return
            _sug["idx"] = (_sug["idx"] + delta) % len(rows)
            _set_highlight()
            try:
                results_container._parent_canvas.yview_moveto(
                    max(0.0, min(1.0, (_sug["idx"] - 2) / max(1, len(rows))))
                )
            except Exception:
                pass

        def _on_return(_e=None):
            rows = _sug["rows"]
            if 0 <= _sug["idx"] < len(rows):
                _pick(rows[_sug["idx"]]["entry"])
            else:
                _do_search()

        def _on_escape(_e=None):
            search_var.set("")
            clear_suggestions()
            prev_hint.configure(text=self.t("سعر الشراء السابق: —"))

        _pending_search = {"job": None}

        def _schedule_search(_e=None):
            if _e is not None and getattr(_e, "keysym", "") in ("Up", "Down", "Left", "Right"):
                return
            job = _pending_search["job"]
            if job is not None:
                try:
                    search_entry.after_cancel(job)
                except Exception:
                    pass
                _pending_search["job"] = None
            try:
                _pending_search["job"] = search_entry.after(150, _do_search)
            except Exception:
                _do_search()

        search_entry.bind("<KeyRelease>", _schedule_search)
        search_entry.bind("<Return>", _on_return)
        search_entry.bind("<Down>", lambda e: _move(1))
        search_entry.bind("<Up>", lambda e: _move(-1))
        search_entry.bind("<Escape>", _on_escape)

        # ===================== الحفظ =====================
        def _tr_db_error(msg):
            msg_s = str(msg)
            table = [
                ("المورد المحدد غير موجود", "المورد المحدد غير موجود"),
                ("لا توجد منتجات في الفاتورة", "لا توجد منتجات في الفاتورة"),
                ("منتج غير صالح في الفاتورة", "منتج غير صالح في الفاتورة"),
                ("منتج غير موجود في الفاتورة", "منتج غير موجود في الفاتورة"),
                ("كمية المنتج يجب أن تكون أكبر من صفر", "كمية المنتج يجب أن تكون أكبر من صفر"),
                ("سعر الشراء لا يمكن أن يكون سالبًا", "سعر الشراء لا يمكن أن يكون سالبًا"),
                ("متغير المنتج غير صالح", "متغير المنتج غير صالح"),
                ("المتغير لا ينتمي إلى هذا المنتج", "متغير المنتج غير صالح"),
            ]
            for prefix, key in table:
                if msg_s.startswith(prefix):
                    return self.t(key)
            return msg_s

        def _save():
            if not supplier_names or supplier_var.get() not in supplier_names:
                self.show_message(self.t("فاتورة شراء جديدة"), self.t("اختر موردًا أولًا"), "warning")
                return
            sid = supplier_ids[supplier_names.index(supplier_var.get())]
            if not cart:
                self.show_message(self.t("فاتورة شراء جديدة"), self.t("لا توجد منتجات في الفاتورة"), "warning")
                return
            subtotal, disc, net = current_totals()
            paid = compute_paid(net)
            items = [{"product_id": int(i["product_id"]),
                      "variant_id": i.get("variant_id"),
                      "quantity": float(i["quantity"]),
                      "purchase_price": float(i["purchase_price"])} for i in cart]
            try:
                ok, result, pid, _net_val, _remaining = self.db.create_purchase_invoice(
                    supplier_id=sid,
                    items=items,
                    total_amount=round(subtotal, 2),
                    paid_amount=round(paid, 2),
                    discount=round(disc, 2),
                    device_name=self._get_device_name(),
                    note=note_var.get().strip(),
                )
            except Exception as exc:
                self.show_message(self.t("تعذر حفظ فاتورة الشراء"), str(exc), "danger")
                return
            if ok:
                self.log_action("purchase_create", "purchase", pid, result)
                self.toast(self.t("تم تسجيل فاتورة الشراء بنجاح"), "success")
                win.destroy()
                self.show_purchases()
            else:
                self.show_message(self.t("تعذر حفظ فاتورة الشراء"), self._tr_db_error(result), "danger")

        footer = ctk.CTkFrame(card, fg_color="transparent")
        ctk.CTkFrame(card, fg_color=self.border(), height=1, corner_radius=0).pack(fill="x", padx=18)
        footer.pack(fill="x", padx=18, pady=(10, 14))
        ctk.CTkButton(footer, text=self.t("💾 حفظ الفاتورة"), height=46, corner_radius=9,
                      fg_color=self.colors["primary"], hover_color=self.colors["primary_hover"],
                      text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold"),
                      command=_save).pack(side=self.flow("right"), fill="x", expand=True, padx=(0, 8))
        ctk.CTkButton(footer, text=self.t("إلغاء"), height=46, corner_radius=9,
                      fg_color="transparent", hover_color=self.colors["danger"],
                      border_width=1, border_color=self.border(),
                      text_color=self.text(), font=ctk.CTkFont(family=self.ui_font_family, size=13),
                      command=win.destroy).pack(side=self.flow("right"), fill="x", expand=True, padx=(8, 0))
        win.bind("<Escape>", lambda e: win.destroy())

        if not supplier_names:
            ctk.CTkLabel(left, text=self.t("لا يوجد موردون بعد — استعمل زر ＋ للإضافة"),
                         font=ctk.CTkFont(family=self.ui_font_family, size=10),
                         text_color=self.colors["accent"], anchor=self.align()).pack(anchor=self.align(), fill="x", pady=(2, 0))
        _on_mode(None)
        render_cart()
        update_sums()
        _update_supplier_hint()
        search_entry.focus_set()
    def _quick_add_supplier_form(self, parent_win=None, callback=None):
        """نافذة فرعية لإضافة مورد سريع من داخل فاتورة الشراء."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("إضافة مورد جديد"))
        win.resizable(False, False)
        win.transient(parent_win or self)
        win.grab_set()
        self.center_window(win, 480, 500)

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=16, pady=16)
        ctk.CTkFrame(card, fg_color=self.colors["secondary"], height=5, corner_radius=0).pack(fill="x")
        ctk.CTkLabel(card, text=self.t("＋ إضافة مورد جديد"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold"),
                     text_color=self.colors["secondary"]).pack(pady=(16, 4))

        fields = ctk.CTkFrame(card, fg_color="transparent")
        fields.pack(fill="x", padx=20, pady=(10, 0))

        ctk.CTkLabel(fields, text=self.t("اسم المورد *"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        name_entry = ctk.CTkEntry(fields, height=36, font=ctk.CTkFont(family=self.ui_font_family, size=11))
        name_entry.pack(fill="x", pady=(2, 8))

        ctk.CTkLabel(fields, text=self.t("الهاتف"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        phone_entry = ctk.CTkEntry(fields, height=36, font=ctk.CTkFont(family=self.ui_font_family, size=11))
        phone_entry.pack(fill="x", pady=(2, 8))

        ctk.CTkLabel(fields, text=self.t("العنوان"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x")
        address_entry = ctk.CTkEntry(fields, height=36, font=ctk.CTkFont(family=self.ui_font_family, size=11))
        address_entry.pack(fill="x", pady=(2, 8))

        def _save():
            name = name_entry.get().strip()
            if not name:
                self.show_message(self.t("إضافة مورد جديد"), self.t("اسم المورد مطلوب"), "warning")
                return
            ok, res = self.db.add_supplier(
                name=name,
                phone=phone_entry.get().strip(),
                address=address_entry.get().strip(),
            )
            if ok:
                self.toast(self.t("تمت إضافة المورد بنجاح"), "success")
                if callback:
                    callback(int(res), name)
                win.destroy()
            else:
                self.show_message(self.t("إضافة مورد جديد"), str(res), "danger")

        def _on_enter(_event=None):
            _save()

        name_entry.bind("<Return>", _on_enter)
        phone_entry.bind("<Return>", _on_enter)

        buttons = ctk.CTkFrame(card, fg_color="transparent")
        buttons.pack(fill="x", padx=20, pady=(14, 16))
        ctk.CTkButton(buttons, text=self.t("حفظ"), height=38, corner_radius=9,
                      fg_color=self.colors["secondary"], hover_color="#16A34A",
                      text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                      command=_save).pack(side="left", fill="x", expand=True, padx=(0, 4))
        ctk.CTkButton(buttons, text=self.t("إلغاء"), height=38, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=11),
                      command=win.destroy).pack(side="right", fill="x", expand=True, padx=(4, 0))
        name_entry.focus_set()

    def _show_purchase_details(self, purchase_id):
        """نافذة تفاصيل فاتورة شراء: ترويسة + بنود + إجماليات."""
        rec = self.db.get_purchase(purchase_id)
        if not rec:
            self.show_message(self.t("تفاصيل فاتورة الشراء"), self.t("فاتورة الشراء غير موجودة"), "warning")
            return
        items = self.db.get_purchase_items(purchase_id) or []
        _, sup_id, inum, gross, paid, disc, pdate, devn, note = rec
        try:
            sname = next((str(s[1]) for s in (self.db.get_suppliers() or []) if int(s[0]) == int(sup_id or 0)), "-")
        except Exception:
            sname = "-"
        net = max(0.0, float(gross or 0) - float(disc or 0))
        remaining = max(0.0, net - float(paid or 0))

        win = ctk.CTkToplevel(self)
        win.title(self.t("تفاصيل فاتورة الشراء"))
        win.transient(self)
        win.grab_set()
        self.center_window(win, 780, 580)

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=14, pady=14)
        ctk.CTkFrame(card, fg_color=self.colors["primary"], height=5, corner_radius=0).pack(fill="x")
        ctk.CTkLabel(card, text="🧾 " + self.t("تفاصيل فاتورة الشراء"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold"),
                     text_color=self.colors["primary"]).pack(pady=(14, 6))

        info = ctk.CTkFrame(card, fg_color=self.bg(), corner_radius=9)
        info.pack(fill="x", padx=16, pady=(0, 8))
        info_rows = [
            (self.t("رقم الفاتورة"), str(inum or "")),
            (self.t("المورد"), str(sname)),
            (self.t("التاريخ"), str(pdate or "")[:16]),
            (self.t("الجهاز"), str(devn or "")),
        ]
        for li, (k, v) in enumerate(info_rows):
            info.grid_columnconfigure(li, weight=1)
            cell = ctk.CTkFrame(info, fg_color="transparent")
            cell.grid(row=0, column=li, sticky="ew", padx=10, pady=10)
            ctk.CTkLabel(cell, text=k, font=ctk.CTkFont(family=self.ui_font_family, size=9),
                         text_color=self.muted()).pack(anchor=self.align())
            ctk.CTkLabel(cell, text=v, font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                         text_color=self.text()).pack(anchor=self.align(), pady=(2, 0))

        if note:
            ctk.CTkLabel(card, text=f"{self.t('ملاحظة')}: {str(note)[:120]}", anchor=self.align(), wraplength=680,
                         font=ctk.CTkFont(family=self.ui_font_family, size=10),
                         text_color=self.muted()).pack(anchor=self.align(), fill="x", padx=18, pady=(0, 8))

        scroll = ctk.CTkScrollableFrame(card, fg_color=self.bg(), corner_radius=9, height=230)
        scroll.pack(fill="both", expand=True, padx=16, pady=(0, 8))
        cols = ["#", self.t("المنتج"), self.t("الكمية"), self.t("سعر الشراء"), self.t("المجموع")]
        weights = [0, 5, 1, 2, 2]
        hdr = ctk.CTkFrame(scroll, fg_color="transparent")
        hdr.pack(fill="x", padx=4, pady=(6, 2))
        for ci, txt in enumerate(cols):
            hdr.grid_columnconfigure(ci, weight=weights[ci])
            ctk.CTkLabel(hdr, text=txt, font=ctk.CTkFont(family=self.ui_font_family, size=10, weight="bold"),
                         text_color=self.muted(), anchor=self.align()).grid(row=0, column=ci, sticky="ew", padx=6, pady=4)
        for ri, it in enumerate(items):
            iid, ipid, iname, iqty, iprice, itotal, *rest = it
            vname = rest[1] if len(rest) > 1 and rest[1] else None
            disp_name = f"{iname or '-'} ({vname})" if vname else (iname or "-")
            rw = ctk.CTkFrame(scroll, fg_color=self.card() if ri % 2 == 0 else self.bg(), corner_radius=6)
            rw.pack(fill="x", padx=4, pady=1)
            vals = [str(iid), str(disp_name), f"{float(iqty or 0):g}", f"{float(iprice or 0):,.2f}", f"{float(itotal or 0):,.2f}"]
            for ci, val in enumerate(vals):
                rw.grid_columnconfigure(ci, weight=weights[ci])
                ctk.CTkLabel(rw, text=val, font=ctk.CTkFont(family=self.ui_font_family, size=10),
                             text_color=self.text(), anchor=self.align()).grid(row=0, column=ci, sticky="ew", padx=6, pady=6)

        totals = ctk.CTkFrame(card, fg_color=self.bg(), corner_radius=9)
        totals.pack(fill="x", padx=16, pady=(0, 10))
        total_rows = [
            (self.t("الإجمالي") + " (" + self.t("قبل الخصم") + ")", self.t(f"{float(gross or 0):,.2f} د.ج")),
            (self.t("الخصم"), self.t(f"{float(disc or 0):,.2f} د.ج")),
            (self.t("صافي الفاتورة"), self.t(f"{net:,.2f} د.ج")),
            (self.t("المدفوع"), self.t(f"{float(paid or 0):,.2f} د.ج")),
            (self.t("المتبقي"), self.t(f"{remaining:,.2f} د.ج")),
        ]
        for tri, (k, v) in enumerate(total_rows):
            totals.grid_columnconfigure(tri, weight=1)
            cellc = ctk.CTkFrame(totals, fg_color="transparent")
            cellc.grid(row=0, column=tri, sticky="ew", padx=8, pady=10)
            kw = {"font": ctk.CTkFont(family=self.ui_font_family, size=9), "text_color": self.muted()}
            kw2 = {"font": ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold"), "text_color": self.colors["danger"] if k == self.t("المتبقي") and remaining > 0 else self.text()}
            ctk.CTkLabel(cellc, text=k, **kw).pack(anchor=self.align())
            ctk.CTkLabel(cellc, text=v, **kw2).pack(anchor=self.align(), pady=(2, 0))

        ctk.CTkButton(card, text=self.t("إغلاق"), height=38, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=11),
                      command=win.destroy).pack(fill="x", padx=16, pady=(0, 14))

    def _pay_supplier_dialog(self):
        """تسديد جزء أو كامل رصيد المورد (الحساب الدائن)."""
        try:
            suppliers = self.db.get_suppliers() or []
        except Exception:
            suppliers = []
        debtors = [s for s in suppliers if float(s[3] or 0) > 0]
        if not debtors:
            self.show_message(self.t("تسديد رصيد مورد"), self.t("لا توجد أرصدة مستحقة للموردين"), "info")
            return

        win = ctk.CTkToplevel(self)
        win.title(self.t("تسديد رصيد مورد"))
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        self.center_window(win, 520, 440)

        card = ctk.CTkFrame(win, fg_color=self.card(), corner_radius=14)
        card.pack(fill="both", expand=True, padx=16, pady=16)
        ctk.CTkFrame(card, fg_color=self.colors["secondary"], height=5, corner_radius=0).pack(fill="x")
        ctk.CTkLabel(card, text="💰 " + self.t("تسديد رصيد مورد"),
                     font=ctk.CTkFont(family=self.ui_font_family, size=17, weight="bold"),
                     text_color=self.colors["secondary"]).pack(pady=(16, 4))

        opts = [self.t(f"{s[1]} — {float(s[3] or 0):,.2f} د.ج") for s in debtors]
        supp_var = tk.StringVar(value=opts[0])
        ctk.CTkLabel(card, text=self.t("اختر المورد"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x", padx=20)
        ctk.CTkOptionMenu(card, variable=supp_var, values=opts, height=36,
                          fg_color=self.bg(), button_color=self.colors["secondary"],
                          button_hover_color="#16A34A",
                          font=ctk.CTkFont(family=self.ui_font_family, size=11)).pack(fill="x", padx=20, pady=(2, 10))

        ctk.CTkLabel(card, text=self.t("المبلغ المطلوب تسديده (د.ج)"), anchor=self.align(),
                     font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                     text_color=self.muted()).pack(anchor=self.align(), fill="x", padx=20)
        amount_var = tk.StringVar(value="")
        amount_entry = ctk.CTkEntry(card, textvariable=amount_var, height=36,
                                    placeholder_text=self.t("أدخل المبلغ..."),
                                    font=ctk.CTkFont(family=self.ui_font_family, size=11))
        amount_entry.pack(fill="x", padx=20, pady=(2, 10))
        hint = ctk.CTkLabel(card, text="", anchor=self.align(),
                            font=ctk.CTkFont(family=self.ui_font_family, size=10),
                            text_color=self.colors["danger"])
        hint.pack(anchor=self.align(), fill="x", padx=20)

        def _save(_event=None):
            try:
                amount = float(amount_var.get().replace(",", ".").strip() or 0)
            except Exception:
                amount = 0.0
            if amount <= 0:
                hint.configure(text=self.t("المبلغ يجب أن يكون أكبر من صفر"))
                return
            if supp_var.get() not in opts:
                return
            idx = opts.index(supp_var.get())
            sid = int(debtors[idx][0])
            ok, res = self.db.record_supplier_payment(sid, amount, note=self.t("تسديد حساب مورد"))
            if ok:
                self.log_action("supplier_payment", "supplier", sid, f"{amount:,.2f}")
                self.toast(self.t("تم تسجيل التسديد بنجاح"), "success")
                win.destroy()
                self.show_purchases()
            else:
                hint.configure(text=self.t(str(res)))

        amount_entry.bind("<Return>", _save)

        buttons = ctk.CTkFrame(card, fg_color="transparent")
        buttons.pack(fill="x", padx=20, pady=(10, 16))
        ctk.CTkButton(buttons, text=self.t("تسديد"), height=38, corner_radius=9,
                      fg_color=self.colors["secondary"], hover_color="#16A34A",
                      text_color="white", font=ctk.CTkFont(family=self.ui_font_family, size=11, weight="bold"),
                      command=_save).pack(side="left", fill="x", expand=True, padx=(0, 4))
        ctk.CTkButton(buttons, text=self.t("إلغاء"), height=38, corner_radius=9,
                      fg_color=self.card(), hover_color=self.border(), text_color=self.text(),
                      border_width=1, border_color=self.border(),
                      font=ctk.CTkFont(family=self.ui_font_family, size=11),
                      command=win.destroy).pack(side="right", fill="x", expand=True, padx=(4, 0))

    def _delete_purchase_flow(self, purchase_id):
        """حذف فاتورة شراء بإذن المسؤول بعد التأكيد (مع عكس المخزون والرصيد)."""
        if not self.require_pin("حذف فاتورة شراء", "admin"):
            return
        if not self.confirm(self.t("تأكيد الحذف"), self.t("هل أنت متأكد من حذف فاتورة الشراء؟")):
            return
        ok, msg = self.db.delete_purchase(purchase_id)
        if ok:
            self.log_action("purchase_delete", "purchase", purchase_id, str(msg))
            self.toast(self.t(str(msg)), "success")
            self.show_purchases()
        else:
            self.show_message(self.t("لا يمكن حذف الفاتورة"), msg, "danger")

    # ========================================
    # الموردون
    # ========================================
    def show_suppliers(self):
        """صفحة الموردين: إضافة وتعديل وحذف معلومات المورد."""
        if not self._guard_db_nav("الموردون", "إدارة بيانات الموردين", "suppliers"):
            return
        self.clear_content()
        self.current_page = "suppliers"
        self.highlight_nav()

        self.page_header(
            "الموردون",
            "إدارة بيانات الموردين ومعلومات التواصل"
        )

        try:
            conn = self.db.get_connection()
            conn.execute("""
                CREATE TABLE IF NOT EXISTS suppliers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    phone TEXT DEFAULT '',
                    address TEXT DEFAULT '',
                    email TEXT DEFAULT '',
                    contact_person TEXT DEFAULT '',
                    balance REAL DEFAULT 0,
                    notes TEXT DEFAULT ''
                )
            """)
            rows = conn.execute("""
                SELECT id, name, phone, address, email, contact_person, notes,
                       COALESCE(balance, 0)
                FROM suppliers ORDER BY name COLLATE NOCASE
            """).fetchall()
            conn.commit()
            conn.close()
        except Exception:
            rows = []

        toolbar = ctk.CTkFrame(self.content_area, fg_color="transparent")
        toolbar.pack(fill="x", pady=(0, 12))

        ctk.CTkButton(
            toolbar, text=self.t("＋ إضافة مورد"), width=200, height=46,
            corner_radius=10, command=self.add_supplier
        ).pack(side="right")

        search_var = tk.StringVar()
        search = ctk.CTkEntry(
            toolbar, textvariable=search_var, height=42,
            placeholder_text=self.t("ابحث باسم المورد أو الهاتف...")
        )
        search.pack(side="left", fill="x", expand=True, padx=(0, 12))

        container = self.make_card(self.content_area)
        container.pack(fill="both", expand=True)

        list_frame = ctk.CTkScrollableFrame(container, fg_color="transparent")
        list_frame.pack(fill="both", expand=True, padx=10, pady=10)

        def render(*_):
            for child in list_frame.winfo_children():
                child.destroy()
            term = search_var.get().strip().lower()
            filtered = []
            for r in rows:
                hay = " ".join(str(x or "") for x in r).lower()
                if not term or term in hay:
                    filtered.append(r)
            if not filtered:
                ctk.CTkLabel(
                    list_frame, text=self.t("لا توجد نتائج."),
                    font=ctk.CTkFont(family=self.ui_font_family, size=18),
                    text_color=self.muted()
                ).pack(pady=70)
                return
            for r in filtered:
                rid, name, phone, address, email, contact, notes, balance = r
                card = self.make_card(list_frame, corner_radius=12)
                card.pack(fill="x", padx=4, pady=5)
                try:
                    bal = float(balance or 0)
                except Exception:
                    bal = 0.0
                bal_txt = self.t(f"{bal:,.2f} د.ج")
                info = (
                    f"{name}\n"
                    f"{self.t('الهاتف')}: {phone or '-'}    •    {self.t('المسؤول')}: {contact or '-'}\n"
                    f"{self.t('العنوان')}: {address or '-'}    •    {self.t('البريد')}: {email or '-'}\n"

                    f"{self.t('الرصيد')}: {bal_txt}"
                )
                ctk.CTkLabel(
                    card, text=info, justify="right", anchor="e",
                    text_color=self.text(),
                    font=ctk.CTkFont(family=self.ui_font_family, size=13)
                ).pack(side="right", fill="x", expand=True, padx=15, pady=12)
                ctk.CTkButton(
                    card, text=self.t("تعديل"), width=90, height=38,
                    command=lambda rr=r: self.add_supplier(rr)
                ).pack(side="left", padx=5, pady=10)
                ctk.CTkButton(
                    card, text=self.t("حذف"), width=90, height=38,
                    fg_color=self.colors.get("danger", "#b91c1c"),
                    hover_color=self.colors.get("danger_hover", "#991b1b"),
                    command=lambda rid=rid: self.delete_supplier(rid)
                ).pack(side="left", padx=5, pady=10)
        search_var.trace_add("write", render)
        render()

    def add_supplier(self, existing=None):
        """نافذة إضافة/تعديل مورد - تخطيط ثابت بدون عناصر مقصوصة."""
        win = ctk.CTkToplevel(self)
        win.title(self.t("إضافة مورد") if existing is None else self.t("تعديل المورد"))
        win.geometry("720x760")
        win.minsize(650, 700)
        win.transient(self)
        win.grab_set()
        try:
            self.center_window(win, 720, 760)
        except Exception:
            pass

        outer = self.make_card(win)
        outer.pack(fill="both", expand=True, padx=16, pady=16)

        ctk.CTkLabel(
            outer, text=(self.t("إضافة مورد") if existing is None else self.t("تعديل المورد")),
            text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=24, weight="bold")
        ).pack(anchor="e", padx=22, pady=(18, 4))
        ctk.CTkLabel(
            outer, text=self.t("أدخل معلومات المورد في الحقول التالية"),
            text_color=self.muted(),
            font=ctk.CTkFont(family=self.ui_font_family, size=11)
        ).pack(anchor="e", padx=22, pady=(0, 10))

        form = ctk.CTkScrollableFrame(outer, fg_color="transparent")
        form.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        vals = existing or (None, "", "", "", "", "", "")
        fields = [
            ("الاسم الكامل *", "اسم المورد *", vals[1], True, self.t("مثال: مؤسسة التوزيع الحديثة")),
            ("رقم الهاتف", "الهاتف", vals[2], False, self.t("مثال: 0550123456")),
            ("العنوان أو المنطقة", "العنوان", vals[3], False, self.t("مثال: وسط المدينة")),
            ("البريد الإلكتروني", "البريد الإلكتروني", vals[4], False, ""),
            ("اسم المسؤول", "اسم المسؤول", vals[5], False, ""),
        ]
        entries = {}
        for title, key, value, required, placeholder in fields:
            ctk.CTkLabel(
                form, text=(self.t(title) + ("  *" if required else "")), anchor=self.align(),
                text_color=self.text(),
                font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
            ).pack(fill="x", padx=18, pady=(10, 4))
            e = ctk.CTkEntry(
                form, height=46,
                placeholder_text=placeholder or None,
                font=ctk.CTkFont(family=self.ui_font_family, size=13)
            )
            e.insert(0, value or "")
            e.pack(fill="x", padx=18, pady=(0, 6))
            entries[key] = e

        ctk.CTkLabel(
            form, text=self.t("ملاحظات"), anchor="e", text_color=self.text(),
            font=ctk.CTkFont(family=self.ui_font_family, size=12, weight="bold")
        ).pack(fill="x", padx=18, pady=(10, 4))
        notes = ctk.CTkTextbox(form, height=110,
                               font=ctk.CTkFont(family=self.ui_font_family, size=13))
        notes.pack(fill="x", padx=18, pady=(0, 14))
        if vals[6]:
            notes.insert("1.0", vals[6])

        footer = ctk.CTkFrame(outer, fg_color="transparent")
        footer.pack(fill="x", padx=18, pady=(4, 16))

        def save():
            name = entries["اسم المورد *"].get().strip()
            if not name:
                try:
                    from tkinter import messagebox
                    messagebox.showwarning(self.t("المورد"), self.t("اسم المورد مطلوب."), parent=win)
                except Exception:
                    pass
                entries["اسم المورد *"].focus_set()
                return
            data = (
                name,
                entries["الهاتف"].get().strip(),
                entries["العنوان"].get().strip(),
                entries["البريد الإلكتروني"].get().strip(),
                entries["اسم المسؤول"].get().strip(),
                notes.get("1.0", "end").strip()
            )
            conn = None
            try:
                conn = self.db.get_connection()
                conn.execute("""CREATE TABLE IF NOT EXISTS suppliers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    phone TEXT DEFAULT '',
                    address TEXT DEFAULT '',
                    email TEXT DEFAULT '',
                    contact_person TEXT DEFAULT '',
                    balance REAL DEFAULT 0,
                    notes TEXT DEFAULT ''
                )""")
                if existing:
                    conn.execute("""UPDATE suppliers SET name=?, phone=?, address=?, email=?,
                        contact_person=?, notes=? WHERE id=?""", (*data, existing[0]))
                else:
                    conn.execute("""INSERT INTO suppliers
                        (name, phone, address, email, contact_person, notes)
                        VALUES (?, ?, ?, ?, ?, ?)""", data)
                conn.commit()
                conn.close()
                win.destroy()
                self.show_suppliers()
            except Exception as exc:
                try:
                    if conn:
                        conn.rollback(); conn.close()
                except Exception:
                    pass
                try:
                    from tkinter import messagebox
                    messagebox.showerror(self.t("خطأ"), self.t(f"تعذر حفظ المورد:\n{exc}"), parent=win)
                except Exception:
                    pass

        ctk.CTkButton(
            footer, text=self.t("إلغاء"), width=190, height=52, corner_radius=12,
            fg_color=self.border(), hover_color=self.colors.get("border_light", self.border()),
            command=win.destroy,
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")
        ).pack(side="left", padx=5)
        ctk.CTkButton(
            footer, text=self.t("✓ حفظ المورد"), width=280, height=52, corner_radius=12,
            command=save,
            font=ctk.CTkFont(family=self.ui_font_family, size=13, weight="bold")
        ).pack(side="right", padx=5)

        win.after(150, lambda: self._focus_if_alive(entries.get("اسم المورد *")))

    def delete_supplier(self, supplier_id):
        if not self.require_pin("حذف مورد", "admin"):
            return
        try:
            from tkinter import messagebox
            if not messagebox.askyesno(self.t("حذف المورد"), self.t("هل تريد حذف هذا المورد؟"), parent=self):
                return
        except Exception:
            return
        conn = None
        try:
            conn = self.db.get_connection()
            conn.execute("DELETE FROM suppliers WHERE id=?", (supplier_id,))
            conn.commit()
            conn.close()
            self.log_action("supplier_delete", "supplier", supplier_id)
            self.show_suppliers()
        except Exception as exc:
            try:
                if conn:
                    conn.rollback()
                    conn.close()
            except Exception:
                pass

#
#
if __name__ == "__main__":
    app = MainWindow()
    app.mainloop()
