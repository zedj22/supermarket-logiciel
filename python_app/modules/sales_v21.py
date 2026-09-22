# modules/sales.py

from database.db_manager import DatabaseManager
import datetime
import sqlite3


class SalesManager:
    def __init__(self):
        self.db = DatabaseManager()

    def create_invoice(self, customer_id, items, discount=0, paid_amount=0):
        """
        إنشاء فاتورة بشكل آمن.

        قواعد الدفع:
        - المدفوع الكامل: الدين = 0
        - المدفوع الجزئي: الدين = الإجمالي - المدفوع
        - الدين الكامل: paid_amount = 0 وبالتالي الدين = الإجمالي
        - الدفع الزائد: الدين = 0 والباقي = المدفوع - الإجمالي
        - كل بيع يسجل خروجًا من المخزون مع رقم الفاتورة في inventory_movements

        customer_id <= 0 يعني بيع بدون عميل مسجل.
        في هذه الحالة لا يتم تسجيل أي دين.
        """
        conn = self.db.get_connection()
        cursor = conn.cursor()

        try:
            # تنظيف والتحقق من المدخلات
            customer_id = int(customer_id or 0)
            discount = float(discount or 0)
            paid_amount = float(paid_amount or 0)

            if paid_amount < 0:
                raise ValueError("المبلغ المدفوع لا يمكن أن يكون سالبًا")

            if discount < 0:
                raise ValueError("الخصم لا يمكن أن يكون سالبًا")

            if not items:
                raise ValueError("لا توجد منتجات في الفاتورة")

            # حساب الإجمالي
            total = 0.0

            for item in items:
                quantity = float(item.get("quantity", 0))
                price = float(item.get("price", 0))

                if quantity <= 0:
                    raise ValueError("كمية المنتج يجب أن تكون أكبر من صفر")

                if price < 0:
                    raise ValueError("سعر المنتج لا يمكن أن يكون سالبًا")

                total += price * quantity

            total_after_discount = max(0.0, total - discount)

            # لا نسمح بدين بدون عميل مسجل.
            # إذا كان هناك عميل نقدي/غير مسجل، يعتبر أي دفع ناقص غير صالح.
            debt_amount = max(0.0, total_after_discount - paid_amount)
            change = max(0.0, paid_amount - total_after_discount)

            if debt_amount > 0 and customer_id <= 0:
                raise ValueError(
                    "لا يمكن تسجيل دين بدون اختيار عميل"
                )

            # التأكد من وجود العميل قبل إضافة الدين
            if customer_id > 0:
                cursor.execute(
                    "SELECT id FROM customers WHERE id = ?",
                    (customer_id,)
                )
                customer = cursor.fetchone()

                if not customer:
                    raise ValueError("العميل المحدد غير موجود")

            # رقم فاتورة أكثر أمانًا من الاعتماد على الثواني فقط
            now = datetime.datetime.now()
            invoice_number = (
                f"INV-{now.strftime('%Y%m%d-%H%M%S')}-"
                f"{int(now.microsecond / 1000):03d}"
            )

            # إنشاء الفاتورة
            cursor.execute(
                """
                INSERT INTO sales
                (invoice_number, customer_id, total, discount,
                 paid_amount, change_amount)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    invoice_number,
                    customer_id,
                    total,
                    discount,
                    paid_amount,
                    change
                )
            )

            sale_id = cursor.lastrowid

            # إضافة عناصر الفاتورة + خصم المخزون
            for item in items:
                product_id = int(item["product_id"])
                quantity = float(item["quantity"])
                price = float(item["price"])
                item_total = price * quantity

                # التأكد من وجود المنتج والكمية
                cursor.execute(
                    """
                    SELECT id, name, quantity
                    FROM products
                    WHERE id = ?
                    """,
                    (product_id,)
                )
                product = cursor.fetchone()

                if not product:
                    raise ValueError(
                        f"المنتج رقم {product_id} غير موجود"
                    )

                available_quantity = float(product[2] or 0)

                if available_quantity < quantity:
                    raise ValueError(
                        f"الكمية غير كافية للمنتج: {product[1]} "
                        f"(المتوفر: {available_quantity:g})"
                    )

                cursor.execute(
                    """
                    INSERT INTO sale_items
                    (sale_id, product_id, quantity, price, total)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        sale_id,
                        product_id,
                        quantity,
                        price,
                        item_total
                    )
                )

                # خصم الكمية من المخزون داخل نفس المعاملة
                cursor.execute(
                    """
                    UPDATE products
                    SET quantity = quantity - ?
                    WHERE id = ? AND quantity >= ?
                    """,
                    (quantity, product_id, quantity)
                )

                if cursor.rowcount != 1:
                    raise ValueError(
                        f"تعذر خصم المخزون للمنتج: {product[1]}"
                    )

                # تسجيل خروج المخزون وربطه برقم الفاتورة.
                # نسجل الحركة في نفس transaction حتى لا يحدث فرق بين
                # كمية المنتج وسجل حركة المخزون إذا فشلت الفاتورة.
                cursor.execute(
                    """
                    CREATE TABLE IF NOT EXISTS inventory_movements (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        product_id INTEGER NOT NULL,
                        quantity_change REAL NOT NULL,
                        reason TEXT DEFAULT '',
                        movement_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    )
                    """
                )

                cursor.execute(
                    """
                    INSERT INTO inventory_movements
                    (product_id, quantity_change, reason)
                    VALUES (?, ?, ?)
                    """,
                    (
                        product_id,
                        -quantity,
                        f"بيع - {invoice_number}"
                    )
                )

            # إضافة الدين فقط إذا كان هناك عميل ودين فعلي
            if customer_id > 0 and debt_amount > 0:
                cursor.execute(
                    """
                    UPDATE customers
                    SET balance = balance + ?
                    WHERE id = ?
                    """,
                    (debt_amount, customer_id)
                )

            # كل العملية تتم أو لا تتم
            conn.commit()

            return (
                True,
                invoice_number,
                total_after_discount,
                change
            )

        except Exception as e:
            # إلغاء كل التغييرات إذا فشل أي جزء من العملية
            try:
                conn.rollback()
            except Exception:
                pass

            return False, None, 0, 0

        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_sales_by_period(self, period="today"):
        conn = self.db.get_connection()
        cursor = conn.cursor()

        try:
            now = datetime.datetime.now()

            if period == "today":
                start_date = now.strftime("%Y-%m-%d")

                cursor.execute(
                    """
                    SELECT *
                    FROM sales
                    WHERE DATE(sale_date) = ?
                    ORDER BY sale_date DESC
                    """,
                    (start_date,)
                )

            elif period == "week":
                week_ago = (
                    now - datetime.timedelta(days=7)
                ).strftime("%Y-%m-%d")

                cursor.execute(
                    """
                    SELECT *
                    FROM sales
                    WHERE DATE(sale_date) >= ?
                    ORDER BY sale_date DESC
                    """,
                    (week_ago,)
                )

            elif period == "month":
                month_ago = (
                    now - datetime.timedelta(days=30)
                ).strftime("%Y-%m-%d")

                cursor.execute(
                    """
                    SELECT *
                    FROM sales
                    WHERE DATE(sale_date) >= ?
                    ORDER BY sale_date DESC
                    """,
                    (month_ago,)
                )

            else:
                year_ago = (
                    now - datetime.timedelta(days=365)
                ).strftime("%Y-%m-%d")

                cursor.execute(
                    """
                    SELECT *
                    FROM sales
                    WHERE DATE(sale_date) >= ?
                    ORDER BY sale_date DESC
                    """,
                    (year_ago,)
                )

            return cursor.fetchall()

        finally:
            conn.close()

    def get_sales_summary(self, period="today"):
        sales = self.get_sales_by_period(period)

        if not sales:
            return {
                "total": 0,
                "count": 0,
                "average": 0,
                "max": 0,
                "min": 0
            }

        # حسب بنية جدول sales الحالية:
        # index 3 = total
        totals = [float(s[3] or 0) for s in sales]

        return {
            "total": sum(totals),
            "count": len(totals),
            "average": sum(totals) / len(totals),
            "max": max(totals),
            "min": min(totals)
        }

    def get_top_products(self, limit=5):
        conn = self.db.get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute(
                """
                SELECT
                    p.name,
                    SUM(si.quantity) AS total_quantity,
                    SUM(si.total) AS total_revenue
                FROM sale_items si
                JOIN products p
                    ON si.product_id = p.id
                GROUP BY si.product_id
                ORDER BY total_quantity DESC
                LIMIT ?
                """,
                (limit,)
            )

            return cursor.fetchall()

        finally:
            conn.close()

    def get_customer_debt(self, customer_id):
        """إرجاع رصيد دين العميل الحالي."""
        conn = self.db.get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute(
                "SELECT balance FROM customers WHERE id = ?",
                (customer_id,)
            )
            row = cursor.fetchone()
            return float(row[0] or 0) if row else 0.0
        finally:
            conn.close()

    def get_total_debt(self):
        """إرجاع مجموع ديون جميع العملاء."""
        conn = self.db.get_connection()
        cursor = conn.cursor()

        try:
            cursor.execute(
                "SELECT COALESCE(SUM(balance), 0) FROM customers WHERE balance > 0"
            )
            row = cursor.fetchone()
            return float(row[0] or 0)
        finally:
            conn.close()
