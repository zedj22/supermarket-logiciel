# main.py - الملف الرئيسي للتشغيل

import sys
import os
import customtkinter as ctk

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from gui.main_window import MainWindow
from security.license import LicenseManager

if __name__ == "__main__":
    # التحقق من الترخيص
    license_manager = LicenseManager()
    
    # تعطيل التحقق مؤقتاً للتجربة
    # if not license_manager.check_license():
    #     print("❌ البرنامج غير مفعل. يرجى إدخال رقم السيريال.")
    #     sys.exit(1)
    
    # تشغيل البرنامج
    app = MainWindow()
    app.mainloop()