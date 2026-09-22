# security/license.py

import hashlib
import uuid
import platform
from database.db_manager import DatabaseManager

class LicenseManager:
    def __init__(self):
        # DatabaseManager كسول: عندما لا يكون وضع الشبكة محددًا بعد (None)
        # لا يتصل بقاعدة البيانات إطلاقًا — فلا يُسقط بدء التشغيل قبل أن
        # يختار المستخدم دور الجهاز في معالج الإعداد الأول.
        # وإذا كان الوضع محددًا والخادم غير متاح، يسجّل تحذيرًا فقط.
        self.db = DatabaseManager()
        self.device_id = self.get_device_id()

    def get_device_id(self):
        system_info = f"{platform.node()}-{platform.system()}-{platform.processor()}"
        return hashlib.md5(system_info.encode()).hexdigest()

    def generate_serial(self):
        return f"SM-{uuid.uuid4().hex[:8].upper()}-{uuid.uuid4().hex[:4].upper()}"

    def activate_license(self, serial_number):
        # أي فشل في قاعدة البيانات يتدرّج بهدوء ولا يُسقط التطبيق.
        try:
            conn = self.db.get_connection()
            try:
                cursor = conn.cursor()

                cursor.execute('SELECT id FROM license WHERE serial_number = ? AND is_active = 0', (serial_number,))
                result = cursor.fetchone()

                if result:
                    cursor.execute('''UPDATE license
                        SET device_id = ?, activated_date = CURRENT_TIMESTAMP, is_active = 1
                        WHERE serial_number = ?''', (self.device_id, serial_number))
                    conn.commit()
                    return True, "✅ تم تفعيل البرنامج بنجاح"
                else:
                    return False, "❌ رقم السيريال غير صحيح أو مستخدم بالفعل"
            finally:
                conn.close()
        except Exception as exc:
            return False, f"تعذر الوصول لقاعدة البيانات: {exc}"

    def check_license(self):
        try:
            conn = self.db.get_connection()
            try:
                cursor = conn.cursor()
                cursor.execute('SELECT id FROM license WHERE device_id = ? AND is_active = 1', (self.device_id,))
                result = cursor.fetchone()
                return result is not None
            finally:
                conn.close()
        except Exception:
            return False

    def get_license_info(self):
        try:
            conn = self.db.get_connection()
            try:
                cursor = conn.cursor()
                cursor.execute('SELECT serial_number, activated_date, expiry_date FROM license WHERE device_id = ? AND is_active = 1', (self.device_id,))
                info = cursor.fetchone()
                return info
            finally:
                conn.close()
        except Exception:
            return None