# modules/debts.py
# سجل ديون ومدفوعات العملاء - Supermarket Pro

from database.db_manager import DatabaseManager
from datetime import datetime


class DebtManager:
    """إدارة سجل الديون والمدفوعات مع الحفاظ على رصيد العميل الحالي في جدول customers."""

    def __init__(self):
        self.db = DatabaseManager()
        # لا نسمح لفشل قاعدة البيانات بأن يُسقط إنشاء المدير؛
        # تُعاد المحاولة تلقائيًا مع كل عملية لاحقة تُستخدم هذا الشق.
        try:
            self.ensure_table()
        except Exception as exc:
            print(f"⚠ تعذر تجهيز جدول الديون الآن: {exc}")

    def ensure_table(self):
        # قبل اختيار وضع الشبكة لا يوجد خادم محدد بعد؛ نتخطى الإنشاء بهدوء.
        if getattr(self.db, "mode", None) is None:
            return
        conn = self.db.get_connection()
        try:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS debt_transactions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    customer_id INTEGER NOT NULL,
                    transaction_type TEXT NOT NULL,
                    amount REAL NOT NULL,
                    note TEXT DEFAULT '',
                    reference TEXT DEFAULT '',
                    transaction_date TEXT NOT NULL
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_debt_customer
                ON debt_transactions(customer_id)
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_debt_date
                ON debt_transactions(transaction_date)
            """)
            conn.commit()
        finally:
            conn.close()

    def _add(self, customer_id, transaction_type, amount, note='', reference=''):
        amount = float(amount)
        if amount <= 0:
            return False, "المبلغ يجب أن يكون أكبر من صفر"

        conn = self.db.get_connection()
        try:
            conn.execute(
                """
                INSERT INTO debt_transactions
                    (customer_id, transaction_type, amount, note, reference, transaction_date)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    customer_id,
                    transaction_type,
                    amount,
                    note,
                    reference,
                    datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                )
            )
            conn.commit()
            return True, "تم تسجيل العملية"
        except Exception as exc:
            return False, str(exc)
        finally:
            conn.close()

    def record_debt(self, customer_id, amount, note='بيع بالدين', reference=''):
        return self._add(customer_id, 'debt', amount, note, reference)

    def record_payment(self, customer_id, amount, note='تسديد دين', reference=''):
        return self._add(customer_id, 'payment', amount, note, reference)

    def get_customer_history(self, customer_id):
        conn = self.db.get_connection()
        try:
            cursor = conn.execute(
                """
                SELECT id, transaction_type, amount, note, reference, transaction_date
                FROM debt_transactions
                WHERE customer_id = ?
                ORDER BY id DESC
                """,
                (customer_id,)
            )
            return cursor.fetchall()
        finally:
            conn.close()

    def get_customer_totals(self, customer_id):
        conn = self.db.get_connection()
        try:
            cursor = conn.execute(
                """
                SELECT
                    COALESCE(SUM(CASE WHEN transaction_type='debt' THEN amount ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN transaction_type='payment' THEN amount ELSE 0 END), 0)
                FROM debt_transactions
                WHERE customer_id = ?
                """,
                (customer_id,)
            )
            row = cursor.fetchone()
            return float(row[0] or 0), float(row[1] or 0)
        finally:
            conn.close()
