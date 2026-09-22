# modules/products.py

from database.db_manager import DatabaseManager
import sqlite3

class ProductManager:
    def __init__(self):
        self.db = DatabaseManager()
    
    def add_product(self, barcode, name, price, cost, quantity, unit='قطعة', expiry_date=None, image_path=None):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        try:
            cursor.execute('''INSERT INTO products 
                (barcode, name, price, cost, quantity, unit, expiry_date, image_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
                (barcode, name, price, cost, quantity, unit, expiry_date, image_path))
            conn.commit()
            conn.close()
            return True, "✅ تم إضافة المنتج بنجاح"
        except sqlite3.IntegrityError:
            conn.close()
            return False, "❌ الباركود موجود مسبقاً"
        except Exception as e:
            conn.close()
            return False, f"❌ خطأ: {str(e)}"
    
    def get_all_products(self):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        # الأعمدة الجديدة (category_id, category_name) في النهاية
        # حتى لا تتأثر الأكواد التي تعتمد على ترتيب الأعمدة.
        cursor.execute('''SELECT p.id, p.barcode, p.name, p.price, p.quantity, p.unit,
            p.category_id, c.name
            FROM products p
            LEFT JOIN categories c ON c.id = p.category_id
            ORDER BY p.name''')
        products = cursor.fetchall()
        conn.close()
        return products
    
    def search_product(self, search_term):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('''SELECT p.id, p.barcode, p.name, p.price, p.quantity, p.unit,
            p.category_id, c.name
            FROM products p
            LEFT JOIN categories c ON c.id = p.category_id
            WHERE p.name LIKE ? OR p.barcode LIKE ?
            ORDER BY p.name''', (f'%{search_term}%', f'%{search_term}%'))
        products = cursor.fetchall()
        conn.close()
        return products
    
    def update_stock(self, product_id, quantity_change):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('UPDATE products SET quantity = quantity + ? WHERE id = ?', (quantity_change, product_id))
        conn.commit()
        conn.close()
    
    def get_product_by_barcode(self, barcode):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id, name, price, quantity FROM products WHERE barcode = ?', (barcode,))
        product = cursor.fetchone()
        conn.close()
        return product
    
    def get_product_by_id(self, product_id):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id, barcode, name, price, cost, quantity, unit, expiry_date FROM products WHERE id = ?', (product_id,))
        product = cursor.fetchone()
        conn.close()
        return product
    
    def update_product(self, product_id, barcode, name, price, cost, quantity, unit, expiry_date=None):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('''UPDATE products 
            SET barcode = ?, name = ?, price = ?, cost = ?, quantity = ?, unit = ?, expiry_date = ?
            WHERE id = ?''',
            (barcode, name, price, cost, quantity, unit, expiry_date, product_id))
        conn.commit()
        conn.close()
        return True, "✅ تم تحديث المنتج بنجاح"
    
    def delete_product(self, product_id):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('DELETE FROM products WHERE id = ?', (product_id,))
        conn.commit()
        conn.close()
        return True, "✅ تم حذف المنتج"
    
    def get_low_stock_products(self, threshold=5):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id, name, quantity, unit FROM products WHERE quantity <= ? ORDER BY quantity ASC', (threshold,))
        products = cursor.fetchall()
        conn.close()
        return products