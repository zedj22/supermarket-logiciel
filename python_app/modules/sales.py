# modules/sales.py

from database.db_manager import DatabaseManager
import datetime
import sqlite3


class SalesManager:
    def __init__(self):
        self.db = DatabaseManager()
        self.last_error = ""
        self.last_error_raw = ""

    @staticmethod
    def _friendly_error(e):
        """ترجمة استثناء قاعدة البيانات إلى رسالة عربية قصيرة قابلة للتنفيذ.

        رسائل ValueError داخل هذا الملف (مثل «الكمية غير كافية للمنتج») هي
        أصلًا عربية ومفهومة، فنعيدها كما هي. أخطاء قاعدة البيانات (قيد المفتاح
        الأجنبي، الازدواج، العمود غير المعروف، الاتصال...) تُترجم إلى رسالة
        قصيرة لا تعرض نصًا تقنيًا إنجليزيًا خامًا للكاشير.
        """
        if isinstance(e, ValueError):
            return str(e)
        s = str(e)
        low = s.lower()
        # شكل sqlite/pymysql: (1452, 'Cannot add or update a child row...')
        code = ""
        if isinstance(e, Exception) and e.args and isinstance(e.args[0], (int, str)):
            code = str(e.args[0])
        if code == "1452" or "foreign key" in low or "a child row" in low:
            return "تعارض في بيانات العميل أو المنتج المرتبط بالفاتورة"
        if code == "1451" or "restrict" in low or "cannot delete" in low:
            return "لا يمكن تعديل هذا السجل لأنه مرتبط بسجلات أخرى محفوظة"
        if code == "1062" or "duplicate" in low:
            return "سجل مكرر لا يمكن إضافته (رقم فاتورة أو باركود مستخدم)"
        if code == "1054" or "unknown column" in low:
            return "خطأ داخلي في بنية قاعدة البيانات؛ تواصل مع المسؤول"
        if "1146" == code or "table" in low and "doesn't exist" in low:
            return "جدول قاعدة البيانات مفقود؛ أعد تهيئة التطبيق"
        if "connection" in low or "can't connect" in low or "timed out" in low or code == "2003":
            return "تعذر الاتصال بالخادم؛ تحقق من الشبكة وتشغيل الخادم"
        if code == "1045" or "access denied" in low:
            return "بيانات دخول الخادم غير صحيحة أو الصلاحية غير كافية"
        return s if s else "خطأ غير معروف"

    def create_invoice(self, customer_id, items, discount=0, paid_amount=0, device_name="PC1"):
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

        device_name: اسم الجهاز الذي أصدر الفاتورة (PC1 للسيرفر أو hostname للعميل).
        """
        conn = self.db.get_connection()
        cursor = conn.cursor()

        # تُقرأ من واجهة نقاط البيع لبناء رسالة خطأ قصيرة وقابلة للتنفيذ؛
        # last_error_raw يحمل التفاصيل التقنية الكاملة للتدقيق لاحقًا.
        self.last_error = ""
        self.last_error_raw = ""

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
            # customer_id <= 0 = بيع بدون عميل مسجل (زبون نقدي عابر).
            # في MySQL تُفعَّل قيود المفاتيح الأجنبية تلقائيًا بعكس SQLite،
            # فلا يصح إدخال 0 في عمود customer_id لأنه غير موجود في جدول
            # customers؛ نستبدله بـ NULL إذا لم يكن هناك عميل.
            db_customer_id = None if customer_id <= 0 else customer_id
            cursor.execute(
                """
                INSERT INTO sales
                (invoice_number, customer_id, total, discount,
                 paid_amount, change_amount, device_name)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    invoice_number,
                    db_customer_id,
                    total,
                    discount,
                    paid_amount,
                    change,
                    str(device_name or "PC1")[:100]
                )
            )

            sale_id = cursor.lastrowid

            # إضافة عناصر الفاتورة + خصم المخزون
            for item in items:
                # ===== باقة (مجموعة منتجات بسعر ثابت) =====
                # تُفصَّل إلى: صف ملخّص واحد (بدون منتج، يحمل سعر الباقة وعددها)
                # + صف لكل مكون على سعره وكميته، مع وسم pack_id حتى تظهر كخط
                # واحد في الفاتورة مع تتبع دقيق للكلفة والأرباح والمخزون لكل مكون.
                if item.get("is_pack"):
                    pack_id = int(item["pack_id"])
                    pack_price = float(item["price"])
                    pack_qty = float(item["quantity"])
                    components = item.get("components") or []

                    # الصف الملخص للباقة (بسعر الباقة الثابت)
                    cursor.execute(
                        """
                        INSERT INTO sale_items
                        (sale_id, product_id, quantity, price, total, pack_id)
                        VALUES (?, NULL, ?, ?, ?, ?)
                        """,
                        (sale_id, pack_qty, pack_price, pack_price * pack_qty, pack_id)
                    )

                    if not components:
                        raise ValueError("الباقة بدون مكونات لا يمكن بيعها")

                    for comp in components:
                        cid = int(comp["product_id"])
                        unit_qty = float(comp["unit_qty"])
                        cprice = float(comp.get("unit_price") or 0)
                        need_qty = unit_qty * pack_qty

                        cursor.execute(
                            "SELECT id, name, quantity FROM products WHERE id = ?",
                            (cid,)
                        )
                        cprod = cursor.fetchone()
                        if not cprod:
                            raise ValueError(f"منتج مكوّن غير موجود: {comp.get('name')}")
                        cavailable = float(cprod[2] or 0)
                        if cavailable < need_qty:
                            raise ValueError(
                                f"الكمية غير كافية للمنتج: {cprod[1]} "
                                f"(المطلوب للباقة: {need_qty:g})"
                            )

                        cursor.execute(
                            """
                            INSERT INTO sale_items
                            (sale_id, product_id, quantity, price, total, pack_id)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            (sale_id, cid, need_qty, cprice, cprice * need_qty, pack_id)
                        )
                        cursor.execute(
                            """
                            UPDATE products
                            SET quantity = quantity - ?
                            WHERE id = ? AND quantity >= ?
                            """,
                            (need_qty, cid, need_qty)
                        )
                        if cursor.rowcount != 1:
                            raise ValueError(f"تعذر خصم المخزون للمنتج: {cprod[1]}")
                        cursor.execute(
                            """
                            INSERT INTO inventory_movements
                            (product_id, quantity_change, reason)
                            VALUES (?, ?, ?)
                            """,
                            (cid, -need_qty, f"بيع باقة - {invoice_number}")
                        )
                    continue

                product_id = int(item["product_id"])
                quantity = float(item["quantity"])
                price = float(item["price"])
                item_total = price * quantity
                variant_id = item.get("variant_id")
                if variant_id in (None, "", 0):
                    variant_id = None
                else:
                    variant_id = int(variant_id)

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

                # ===== متغير المنتج (مقاس/لون): خصم من مخزون المتغير وإجمالي المنتج =====
                if variant_id is not None:
                    cursor.execute(
                        "SELECT id, variant_name, quantity FROM product_variants WHERE id = ?",
                        (variant_id,)
                    )
                    variant = cursor.fetchone()
                    if not variant:
                        raise ValueError(
                            f"متغير المنتج رقم {variant_id} غير موجود"
                        )
                    vavailable = float(variant[2] or 0)
                    if vavailable < quantity:
                        raise ValueError(
                            f"الكمية غير كافية لمتغير: {variant[1]} "
                            f"(المتوفر: {vavailable:g})"
                        )
                    cursor.execute(
                        "UPDATE product_variants SET quantity = quantity - ? WHERE id = ? AND quantity >= ?",
                        (quantity, variant_id, quantity)
                    )
                    if cursor.rowcount != 1:
                        raise ValueError(
                            f"تعذر خصم مخزون المتغير: {variant[1]}"
                        )

                else:
                    available_quantity = float(product[2] or 0)
                    if available_quantity < quantity:
                        raise ValueError(
                            f"الكمية غير كافية للمنتج: {product[1]} "
                            f"(المتوفر: {available_quantity:g})"
                        )

                cursor.execute(
                    """
                    INSERT INTO sale_items
                    (sale_id, product_id, variant_id, quantity, price, total)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        sale_id,
                        product_id,
                        variant_id,
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
                # (جدول inventory_movements يُنشأ مسبقًا في modules/inventory.py؛
                #  حذفنا إنشاؤه هنا لأن DDL في MySQL يلتزم تلقائيًا فكسر ذرية العملية)
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
            # إلغاء كل التغييرات إذا فشل أي جزء من العملية.
            # لا نُسقط العملية الأصلية: نُبقي التفاصيل التقنية الكاملة في
            # last_error_raw لسجل التدقيق، ونضع رسالة قصيرة قابلة للتنفيذ
            # في last_error ليقرأها الكاشير (لا نعرض أي تتبع إنجليزي خام).
            try:
                conn.rollback()
            except Exception:
                pass
            self.last_error_raw = f"{type(e).__name__}: {e}"
            self.last_error = self._friendly_error(e)

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
