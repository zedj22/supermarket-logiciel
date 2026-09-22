# modules/packs.py

from database.db_manager import DatabaseManager


class PacksManager:
    """إدارة الباقات/المجموعات: باقة تجمع منتجات موجودة بسعر ثابت.

    الباقة تُعرف باسم وسعر ثابت ومجموعة بنود (pack_items) كل بند يحدد منتجًا
    وكمية ثابتة منه داخل الباقة الواحدة. بيع الباقة يخصم من مخزون كل مكون.
    """

    def __init__(self):
        self.db = DatabaseManager()
        self.last_error = ""

    # ---------------------------------------------------------
    # CRUD
    # ---------------------------------------------------------
    def add_pack(self, name, price, items, image_path=None):
        """إنشاء باقة جديدة.

        items: قائمة tuples (product_id, quantity).
        يعيد (True, pack_id) أو (False, error).
        """
        conn = self.db.get_connection()
        cursor = conn.cursor()
        try:
            if not items:
                self.last_error = "يجب تحديد منتج واحد على الأقل للباقة"
                return False, self.last_error
            cursor.execute(
                "INSERT INTO packs (name, price, image_path) VALUES (?, ?, ?)",
                (str(name).strip(), float(price or 0), image_path)
            )
            pack_id = cursor.lastrowid
            for product_id, qty in items:
                if float(qty or 0) <= 0:
                    raise ValueError("كمية مكون الباقة يجب أن تكون أكبر من صفر")
                cursor.execute(
                    "INSERT INTO pack_items (pack_id, product_id, quantity) VALUES (?, ?, ?)",
                    (pack_id, int(product_id), float(qty))
                )
            conn.commit()
            return True, pack_id
        except Exception as e:
            try:
                conn.rollback()
            except Exception:
                pass
            self.last_error = str(e)
            return False, self.last_error
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def update_pack(self, pack_id, name, price, items, image_path=None, is_active=None):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        try:
            if not items:
                self.last_error = "يجب تحديد منتج واحد على الأقل للباقة"
                return False, self.last_error
            cursor.execute(
                "UPDATE packs SET name = ?, price = ?, image_path = ? WHERE id = ?",
                (str(name).strip(), float(price or 0), image_path, int(pack_id))
            )
            cursor.execute("DELETE FROM pack_items WHERE pack_id = ?", (int(pack_id),))
            for product_id, qty in items:
                if float(qty or 0) <= 0:
                    raise ValueError("كمية مكون الباقة يجب أن تكون أكبر من صفر")
                cursor.execute(
                    "INSERT INTO pack_items (pack_id, product_id, quantity) VALUES (?, ?, ?)",
                    (int(pack_id), int(product_id), float(qty))
                )
            if is_active is not None:
                cursor.execute(
                    "UPDATE packs SET is_active = ? WHERE id = ?",
                    (1 if is_active else 0, int(pack_id))
                )
            conn.commit()
            return True, int(pack_id)
        except Exception as e:
            try:
                conn.rollback()
            except Exception:
                pass
            self.last_error = str(e)
            return False, self.last_error
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def set_active(self, pack_id, is_active):
        conn = self.db.get_connection()
        try:
            conn.execute(
                "UPDATE packs SET is_active = ? WHERE id = ?",
                (1 if is_active else 0, int(pack_id))
            )
            conn.commit()
            return True
        except Exception:
            self.last_error = "تعذر تحديث حالة الباقة"
            return False
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def delete_pack(self, pack_id):
        """حذف الباقة: حذف فعلي إذا لم تُبع من قبل، وإلا تعطيلها (is_active=0)."""
        conn = self.db.get_connection()
        try:
            used = conn.execute(
                "SELECT COUNT(*) FROM sale_items WHERE pack_id = ?", (int(pack_id),)
            ).fetchone()
            if used and int(used[0] or 0) > 0:
                conn.execute("UPDATE packs SET is_active = 0 WHERE id = ?", (int(pack_id),))
                conn.commit()
                return False, "تم تعطيل الباقة لأنها مرتبطة بمبيعات سابقة"
            conn.execute("DELETE FROM pack_items WHERE pack_id = ?", (int(pack_id),))
            conn.execute("DELETE FROM packs WHERE id = ?", (int(pack_id),))
            conn.commit()
            return True, "تم حذف الباقة"
        except Exception as e:
            self.last_error = str(e)
            return False, self.last_error
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # ---------------------------------------------------------
    # القراءة
    # ---------------------------------------------------------
    def get_all_packs(self, include_inactive=True):
        """يعيد جميع الباقات مع إحصائية (عدد المكونات) —
        العمود الأخير = عدد المكونات."""
        conn = self.db.get_connection()
        if include_inactive:
            query = (
                "SELECT p.id, p.name, p.price, p.is_active, COUNT(pi.id) AS cnt "
                "FROM packs p LEFT JOIN pack_items pi ON pi.pack_id = p.id "
                "GROUP BY p.id ORDER BY p.is_active DESC, p.name"
            )
        else:
            query = (
                "SELECT p.id, p.name, p.price, p.is_active, COUNT(pi.id) AS cnt "
                "FROM packs p LEFT JOIN pack_items pi ON pi.pack_id = p.id "
                "WHERE p.is_active = 1 GROUP BY p.id ORDER BY p.name"
            )
        try:
            return conn.execute(query).fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_pack(self, pack_id):
        conn = self.db.get_connection()
        try:
            return conn.execute(
                "SELECT id, name, price, image_path, is_active FROM packs WHERE id = ?",
                (int(pack_id),)
            ).fetchone()
        except Exception:
            return None
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_pack_items(self, pack_id):
        """يعيد مكونات الباقة مع اسم المنتج وسعره الحالي:
        (product_id, name, unit_qty, unit_price)."""
        conn = self.db.get_connection()
        try:
            return conn.execute(
                """
                SELECT pi.product_id, p.name, pi.quantity, p.price
                FROM pack_items pi
                JOIN products p ON p.id = pi.product_id
                WHERE pi.pack_id = ?
                ORDER BY pi.id
                """,
                (int(pack_id),)
            ).fetchall()
        except Exception:
            return []
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def get_sum_price(self, pack_id):
        """مجموع أسعار المكونات بسعرها الحالي (سعر التجزئة العادي)."""
        items = self.get_pack_items(pack_id)
        return sum(float(i[2] or 0) * float(i[3] or 0) for i in items)

    def check_component_availability(self, pack_id):
        """يفحص توفر كل مكونات الباقة.

        يعيد (ok, message, shortages) حيث shortages قائمة
        (product_name, needed, available).
        """
        items = self.get_pack_items(pack_id)
        conn = self.db.get_connection()
        try:
            shortages = []
            for product_id, name, unit_qty, _price in items:
                row = conn.execute(
                    "SELECT quantity FROM products WHERE id = ?", (int(product_id),)
                ).fetchone()
                available = float(row[0] or 0) if row else 0.0
                if available < float(unit_qty or 0) - 1e-9:
                    shortages.append((name, float(unit_qty or 0), available))
            if shortages:
                parts = "، ".join(
                    f"{nm} (مطلوب {need:g}، متوفر {avail:g})"
                    for nm, need, avail in shortages
                )
                return False, f"مخزون غير كافٍ للباقة: {parts}", shortages
            return True, "", []
        finally:
            try:
                conn.close()
            except Exception:
                pass
