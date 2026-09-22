from database.db_manager import DatabaseManager
from datetime import datetime, date, timedelta

class InventoryManager:
    def __init__(self):
        self.db = DatabaseManager()
        self.low_threshold = 5
        # لا نسمح لفشل قاعدة البيانات بأن يُسقط إنشاء المدير.
        try:
            self._ensure_table()
        except Exception as exc:
            print(f"⚠ تعذر تجهيز جدول حركة المخزون الآن: {exc}")

    def _ensure_table(self):
        # قبل اختيار وضع الشبكة لا يوجد خادم محدد بعد؛ نتخطى الإنشاء بهدوء.
        if getattr(self.db, "mode", None) is None:
            return
        conn = self.db.get_connection()
        cur = conn.cursor()
        cur.execute('''
            CREATE TABLE IF NOT EXISTS inventory_movements (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                product_id INTEGER NOT NULL,
                quantity_change REAL NOT NULL,
                reason TEXT DEFAULT '',
                movement_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.commit()
        conn.close()

    def get_products(self):
        conn = self.db.get_connection()
        cur = conn.cursor()
        cur.execute('''
            SELECT id, barcode, name, price, quantity, unit, cost, expiry_date
            FROM products
            ORDER BY name
        ''')
        rows = cur.fetchall()
        conn.close()
        return rows

    def get_stats(self):
        products = self.get_products()
        today = date.today()
        out = 0
        low = 0
        expiring = 0
        for p in products:
            qty = float(p[4] or 0)
            if qty <= 0:
                out += 1
            elif qty <= self.low_threshold:
                low += 1
            expiry = p[7]
            if expiry:
                try:
                    d = datetime.strptime(str(expiry)[:10], '%Y-%m-%d').date()
                    if 0 <= (d - today).days <= 30:
                        expiring += 1
                except (ValueError, TypeError):
                    pass
        return {'total': len(products), 'out': out, 'low': low, 'expiring': expiring}

    def change_stock(self, product_id, quantity_change, reason=''):
        conn = self.db.get_connection()
        cur = conn.cursor()
        try:
            cur.execute('SELECT quantity FROM products WHERE id = ?', (product_id,))
            row = cur.fetchone()
            if not row:
                conn.close()
                return False, 'المنتج غير موجود'
            current = float(row[0] or 0)
            new_qty = current + float(quantity_change)
            if new_qty < 0:
                conn.close()
                return False, f'لا يمكن أن تصبح الكمية سالبة. المتوفر: {current:g}'
            cur.execute('UPDATE products SET quantity = ? WHERE id = ?', (new_qty, product_id))
            cur.execute('''INSERT INTO inventory_movements
                (product_id, quantity_change, reason) VALUES (?, ?, ?)''',
                (product_id, float(quantity_change), reason))
            conn.commit()
            conn.close()
            return True, 'تم تحديث المخزون بنجاح'
        except Exception as e:
            conn.rollback()
            conn.close()
            return False, str(e)

    def add_stock(self, product_id, amount, reason='إدخال مخزون'):
        """إضافة كمية وتسجيلها في سجل الحركة."""
        amount = float(amount)
        if amount <= 0:
            return False, 'الكمية يجب أن تكون أكبر من صفر'
        return self.change_stock(product_id, amount, reason)

    def remove_stock(self, product_id, amount, reason='إخراج مخزون'):
        """إخراج كمية مع منع المخزون من أن يصبح سالبًا."""
        amount = float(amount)
        if amount <= 0:
            return False, 'الكمية يجب أن تكون أكبر من صفر'
        return self.change_stock(product_id, -amount, reason)

    def get_product_movement_summary(self, product_id):
        """ملخص حركة منتج: الداخل والخارج وعدد العمليات."""
        conn = self.db.get_connection()
        try:
            row = conn.execute("""
                SELECT
                    COALESCE(SUM(CASE WHEN quantity_change > 0 THEN quantity_change ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN quantity_change < 0 THEN -quantity_change ELSE 0 END), 0),
                    COUNT(*)
                FROM inventory_movements
                WHERE product_id = ?
            """, (product_id,)).fetchone()
            return {'incoming': float(row[0] or 0), 'outgoing': float(row[1] or 0), 'operations': int(row[2] or 0)}
        finally:
            conn.close()

    def get_movements(self, product_id=None, limit=100):
        conn = self.db.get_connection()
        cur = conn.cursor()
        if product_id is None:
            cur.execute('''
                SELECT m.id, p.name, m.quantity_change, m.reason, m.movement_date
                FROM inventory_movements m JOIN products p ON p.id=m.product_id
                ORDER BY m.movement_date DESC LIMIT ?
            ''', (limit,))
        else:
            cur.execute('''
                SELECT m.id, p.name, m.quantity_change, m.reason, m.movement_date
                FROM inventory_movements m JOIN products p ON p.id=m.product_id
                WHERE m.product_id=? ORDER BY m.movement_date DESC LIMIT ?
            ''', (product_id, limit))
        rows = cur.fetchall()
        conn.close()
        return rows
