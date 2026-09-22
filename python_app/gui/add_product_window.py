# gui/add_product_window.py - تصميم عصري

import customtkinter as ctk
from tkinter import messagebox
import sys
import os

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from modules.products import ProductManager

class AddProductWindow(ctk.CTkToplevel):
    def __init__(self, parent):
        super().__init__(parent)
        
        self.parent = parent
        self.title("➕ إضافة منتج جديد")
        self.geometry("550x600")
        self.resizable(False, False)
        
        # جعل النافذة في المنتصف
        self.transient(parent)
        self.grab_set()
        
        self.product_manager = ProductManager()
        
        self.create_widgets()
    
    def create_widgets(self):
        # إطار رئيسي مع ظل
        main_frame = ctk.CTkFrame(self, fg_color="#1a1a2e", corner_radius=15)
        main_frame.pack(fill="both", expand=True, padx=20, pady=20)
        
        # عنوان
        ctk.CTkLabel(
            main_frame,
            text="➕ إضافة منتج جديد",
            font=ctk.CTkFont(size=24, weight="bold"),
            text_color="#ffffff"
        ).pack(pady=(20, 30))
        
        # حقل الباركود
        barcode_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        barcode_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(barcode_frame, text="🔢", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.barcode_entry = ctk.CTkEntry(
            barcode_frame,
            placeholder_text="الباركود (اختياري)",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.barcode_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # حقل الاسم
        name_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        name_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(name_frame, text="📝", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.name_entry = ctk.CTkEntry(
            name_frame,
            placeholder_text="اسم المنتج *",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.name_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # حقل السعر
        price_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        price_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(price_frame, text="💰", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.price_entry = ctk.CTkEntry(
            price_frame,
            placeholder_text="سعر البيع *",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.price_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # حقل سعر الشراء
        cost_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        cost_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(cost_frame, text="💲", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.cost_entry = ctk.CTkEntry(
            cost_frame,
            placeholder_text="سعر الشراء (اختياري)",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.cost_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # حقل الكمية
        qty_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        qty_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(qty_frame, text="📦", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.quantity_entry = ctk.CTkEntry(
            qty_frame,
            placeholder_text="الكمية *",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.quantity_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # حقل الوحدة
        unit_frame = ctk.CTkFrame(main_frame, fg_color="#2d2d44", corner_radius=10)
        unit_frame.pack(fill="x", padx=30, pady=5)
        
        ctk.CTkLabel(unit_frame, text="📐", font=ctk.CTkFont(size=16)).pack(side="left", padx=(10, 5))
        self.unit_entry = ctk.CTkEntry(
            unit_frame,
            placeholder_text="الوحدة (قطعة، كيلو، علبة...)",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=40
        )
        self.unit_entry.pack(side="left", fill="x", expand=True, padx=5)
        
        # أزرار
        btn_frame = ctk.CTkFrame(main_frame, fg_color="transparent")
        btn_frame.pack(pady=30)
        
        ctk.CTkButton(
            btn_frame,
            text="💾 حفظ المنتج",
            command=self.save_product,
            font=ctk.CTkFont(size=15, weight="bold"),
            height=45,
            width=180,
            corner_radius=10,
            fg_color="#34a853",
            hover_color="#2d9248"
        ).pack(side="left", padx=10)
        
        ctk.CTkButton(
            btn_frame,
            text="❌ إلغاء",
            command=self.destroy,
            font=ctk.CTkFont(size=15),
            height=45,
            width=180,
            corner_radius=10,
            fg_color="#2d2d44",
            hover_color="#3d3d54"
        ).pack(side="left", padx=10)
    
    def save_product(self):
        barcode = self.barcode_entry.get().strip()
        name = self.name_entry.get().strip()
        price = self.price_entry.get().strip()
        quantity = self.quantity_entry.get().strip()
        unit = self.unit_entry.get().strip() or "قطعة"
        cost = self.cost_entry.get().strip() or 0
        
        if not name or not price or not quantity:
            messagebox.showerror("خطأ", "⚠️ الاسم، السعر والكمية حقول مطلوبة")
            return
        
        try:
            price = float(price)
            quantity = int(quantity)
            cost = float(cost) if cost else 0
        except ValueError:
            messagebox.showerror("خطأ", "⚠️ السعر والكمية يجب أن يكونا أرقاماً")
            return
        
        success, message = self.product_manager.add_product(
            barcode, name, price, cost, quantity, unit, None
        )
        
        if success:
            messagebox.showinfo("نجاح", "✅ تم إضافة المنتج بنجاح!")
            self.destroy()
            self.parent.load_products()
        else:
            messagebox.showerror("خطأ", f"❌ {message}")