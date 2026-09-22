# modules/customers.py

from database.db_manager import DatabaseManager

class CustomerManager:
    def __init__(self):
        self.db = DatabaseManager()
    
    def add_customer(self, name, phone='', address='', debt_ceiling=0):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        try:
            try:
                ceiling = float(debt_ceiling or 0)
            except (TypeError, ValueError):
                ceiling = 0.0
            cursor.execute(
                'INSERT INTO customers (name, phone, address, debt_ceiling) VALUES (?, ?, ?, ?)',
                (name, phone, address, ceiling)
            )
            conn.commit()
            conn.close()
            return True, "✅ تم إضافة الزبون بنجاح"
        except Exception as e:
            conn.close()
            return False, str(e)
    
    def get_all_customers(self):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id, name, phone, balance FROM customers ORDER BY name')
        customers = cursor.fetchall()
        conn.close()
        return customers
    
    def search_customer(self, search_term):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            '''SELECT id, name, phone, balance 
               FROM customers 
               WHERE name LIKE ? OR phone LIKE ?
               ORDER BY name''',
            (f'%{search_term}%', f'%{search_term}%')
        )
        customers = cursor.fetchall()
        conn.close()
        return customers
    
    def get_customer_by_id(self, customer_id):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id, name, phone, address, balance FROM customers WHERE id = ?', (customer_id,))
        customer = cursor.fetchone()
        conn.close()
        return customer
    
    def update_customer(self, customer_id, name, phone, address):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            'UPDATE customers SET name = ?, phone = ?, address = ? WHERE id = ?',
            (name, phone, address, customer_id)
        )
        conn.commit()
        conn.close()
        return True, "✅ تم تحديث الزبون بنجاح"
    
    def update_balance(self, customer_id, amount):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('UPDATE customers SET balance = balance + ? WHERE id = ?', (amount, customer_id))
        conn.commit()
        conn.close()
        return True, "✅ تم تحديث الرصيد"
    
    def delete_customer(self, customer_id):
        conn = self.db.get_connection()
        cursor = conn.cursor()
        cursor.execute('DELETE FROM customers WHERE id = ?', (customer_id,))
        conn.commit()
        conn.close()
        return True, "✅ تم حذف الزبون"