# modules/reports.py

from database.db_manager import DatabaseManager
from modules.sales import SalesManager
from modules.products import ProductManager
from modules.customers import CustomerManager
import datetime


# ترتيب أيام الأسبوع حسب MySQL DAYOFWEEK (1=الأحد .. 7=السبت)
DAY_NAME_TO_DOW = {
    "الأحد": 1,
    "الاثنين": 2,
    "الثلاثاء": 3,
    "الأربعاء": 4,
    "الخميس": 5,
    "الجمعة": 6,
    "السبت": 7,
}


class ReportsManager:
    def __init__(self):
        self.db = DatabaseManager()
        self.sales_manager = SalesManager()
        self.product_manager = ProductManager()
        self.customer_manager = CustomerManager()

    # ---------------------------------------------------------
    # واجهات متوافقة مع الشاشات القديمة (لوحة التحكم وغيرها)
    # ---------------------------------------------------------

    def get_sales_by_period(self, period="today"):
        return self.sales_manager.get_sales_by_period(period)

    def get_sales_summary(self, period="today"):
        return self.sales_manager.get_sales_summary(period)

    def get_top_products(self, limit=5):
        return self.sales_manager.get_top_products(limit)

    def get_low_stock_products(self, threshold=5):
        return self.product_manager.get_low_stock_products(threshold)

    def get_customers_with_debt(self):
        customers = self.customer_manager.get_all_customers()
        return [c for c in customers if c[3] > 0]

    def get_dashboard_stats(self):
        products = self.product_manager.get_all_products()
        customers = self.customer_manager.get_all_customers()
        sales_summary = self.get_sales_summary("today")

        debt_customers_count = sum(1 for c in (customers or []) if c[3] > 0)

        return {
            "total_products": len(products),
            "total_customers": len(customers),
            "total_stock_value": sum(p[3] * p[4] for p in products) if products else 0,
            "today_sales": sales_summary["total"],
            "today_sales_count": sales_summary["count"],
            "low_stock_count": len(self.get_low_stock_products()),
            "debt_customers_count": debt_customers_count
        }

    # ---------------------------------------------------------
    # التقارير المتقدمة
    # ---------------------------------------------------------

    @staticmethod
    def resolve_period(period_or_dates):
        """تحويل مدخلات الفترة إلى (start_date, end_date) بصيغة YYYY-MM-DD.

        period_or_dates: سلسلة مفاتيح (today/yesterday/week/month/7days) أو
        tuple/list من تاريخين (start, end).
        """
        today = datetime.date.today()
        if isinstance(period_or_dates, (list, tuple)) and len(period_or_dates) >= 2:
            return str(period_or_dates[0]), str(period_or_dates[1])
        key = str(period_or_dates or "today")
        mapping = {
            "yesterday": today - datetime.timedelta(days=1),
            "week": today - datetime.timedelta(days=6),
            "7days": today - datetime.timedelta(days=6),
            "month": today.replace(day=1),
            "today": today,
        }
        base = mapping.get(key, today)
        if key == "yesterday":
            return base.isoformat(), base.isoformat()
        return base.isoformat(), today.isoformat()

    def get_full_report(self, period_or_dates="today", device_name=None):
        """تقرير شامل لفترة محددة: مالي + منتجات + بطيئة الحركة + أجهزة + مرتجعات/إلغاء.

        period_or_dates: مفتاح فترة (today/yesterday/7days/week/month) أو
        tuple (start_date, end_date).

        device_name: إن حُدد، يُفلتر التقرير لجهاز واحد فقط
        (السيرفر PC1 يضبط None لمشاهدة كل الأجهزة).
        """
        start, end = self.resolve_period(period_or_dates)
        dev = device_name or None
        return {
            "start_date": start,
            "end_date": end,
            "financial": self.db.get_financial_report(start, end, dev),
            "top_products": self.db.get_product_performance(start, end, dev),
            "slow_moving": self.db.get_slow_moving_products(),
            "device_breakdown": self.db.get_device_breakdown(start, end),
            "returns": self.db.get_returns(device_name=dev, limit=200),
            "voided": self.db.get_voided_invoices(start, end, dev),
            "debt_collected": self.db.get_debt_collected(start, end),
            "expenses": self.db.get_expenses(start, end, dev),
            "profit_by_category": self.db.get_profit_by_category(start, end, dev),
            "daily_timeline": self.db.get_daily_timeline(start, end, dev),
            "hourly_revenue": self.db.get_hourly_revenue(start, end, dev),
        }

    def get_margin_warnings(self, products=None, margin_threshold=5.0):
        """منتجات تُباع بهامش ربح منخفض أو بخسارة (تحت أو قرب التكلفة).

        products: قائمة من get_product_performance على شكل
        (product_id, name, qty_sold, revenue, cogs, net_profit).
        إن حُذفت، تُحسب لأفضل 100 منتج حاليًا بدون رابط فترة (استدعاء كامل).

        margin_threshold: هامش ربح % يُعتبر تحته المنتج "قرب التكلفة".

        تُعيد dict:
          {"warnings": [(name, qty, revenue, cogs, profit, margin_pct), ...],
           "below_cost": [...], "near_cost": [...], "count": n}
        """
        below = []
        near = []
        if not products:
            products = self.db.get_product_performance(
                datetime.date.today().isoformat(),
                datetime.date.today().isoformat(),
                None,
            )
        for row in (products or [])[:1000]:
            if len(row) < 6:
                continue
            try:
                name = str(row[1] or "منتج")
                qty = float(row[2] or 0)
                revenue = float(row[3] or 0)
                cogs = float(row[4] or 0)
                profit = float(row[5] or 0)
            except Exception:
                continue
            if revenue <= 0:
                continue
            margin = (profit / revenue) * 100.0
            entry = (name, qty, revenue, cogs, profit, margin)
            if margin < 0:
                below.append(entry)
            elif margin <= margin_threshold:
                near.append(entry)
        below.sort(key=lambda x: x[4])
        near.sort(key=lambda x: x[5])
        return {
            "warnings": below + near,
            "below_cost": below,
            "near_cost": near,
            "count": len(below) + len(near),
        }

    def get_hourly_traffic(self, day_of_week=None, device_name=None, lookback_days=60):
        """بيانات حركة العملاء بالساعة (لرسم المخطط التفاعلي)."""
        return self.db.get_hourly_traffic_data(
            day_of_week=day_of_week,
            device_name=device_name or None,
            lookback_days=lookback_days,
        )

    def predict_crowd_level(self, day_name, hour_24, device_name=None):
        """توقع مستوى الازدحام ليوم/ساعة من بيانات آخر 60 يومًا.

        day_name: اسم اليوم بالعربية (الأحد .. السبت).
        hour_24: الساعة بصيغة 0-23.

        يُعيد dict:
          level (low/medium/peak), label, avg_invoices, avg_volume, count, total_days
        """
        dow = DAY_NAME_TO_DOW.get(str(day_name))
        if dow is None:
            return {
                "level": "unknown", "label": "يوم غير معروف",
                "avg_invoices": 0.0, "avg_volume": 0.0,
                "count": 0, "total_days": 0,
            }
        traffic = self.get_hourly_traffic(day_of_week=dow, device_name=device_name or None, lookback_days=60)
        rows = [r for r in traffic.get("rows", []) if r[1] == int(hour_24)]
        total_days = int(traffic.get("total_days", 0) or 0)

        invoices = sum((r[2] or 0) for r in rows)
        volume = sum((r[3] or 0) for r in rows)
        avg_invoices = (invoices / total_days) if total_days else 0.0
        avg_volume = (volume / total_days) if total_days else 0.0

        if avg_invoices > 25:
            level = "peak"
            label = "ازدحام شديد (ذروة) 🔴 - يُنصح بتشغيل جهاز كاشير إضافي"
        elif avg_invoices >= 8:
            level = "medium"
            label = "متوسط 🟡"
        else:
            level = "low"
            label = "منخفض (هدوء) 🟢"

        return {
            "level": level,
            "label": label,
            "avg_invoices": avg_invoices,
            "avg_volume": avg_volume,
            "count": invoices,
            "total_days": total_days,
        }