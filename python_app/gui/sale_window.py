# gui/sale_window.py - تصميم عصري

import customtkinter as ctk
from tkinter import messagebox
import sys
import os

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from modules.products import ProductManager
from modules.sales import SalesManager
from modules.customers import CustomerManager

class SaleWindow(ctk.CTkToplevel):
    def __init__(self, parent):
        super().__init__(parent)
        
        self.parent = parent
        self.title("💰 عملية بيع جديدة")
        self.geometry("1000x650")
        self.minsize(800, 500)
        
        self.transient(parent)
        self.grab_set()
        
        self.product_manager = ProductManager()
        self.sales_manager = SalesManager()
        self.customer_manager = CustomerManager()
        
        self.cart = []
        self.total = 0
        
        self.create_widgets()
    
    def create_widgets(self):
        # إطار رئيسي
        main_frame = ctk.CTkFrame(self, fg_color="#0f0f1a")
        main_frame.pack(fill="both", expand=True, padx=15, pady=15)
        
        # قسم المنتجات (يسار)
        left_frame = ctk.CTkFrame(main_frame, fg_color="#1a1a2e", corner_radius=12)
        left_frame.pack(side="left", fill="both", expand=True, padx=(0, 10))
        
        # عنوان
        ctk.CTkLabel(
            left_frame,
            text="🛒 إضافة منتج",
            font=ctk.CTkFont(size=20, weight="bold"),
            text_color="#ffffff"
        ).pack(anchor="w", padx=20, pady=15)
        
        # البحث
        search_frame = ctk.CTkFrame(left_frame, fg_color="#2d2d44", corner_radius=10)
        search_frame.pack(fill="x", padx=20, pady=(0, 15))
        
        ctk.CTkLabel(search_frame, text="🔍", font=ctk.CTkFont(size=18)).pack(side="left", padx=(10, 5))
        self.search_entry = ctk.CTkEntry(
            search_frame,
            placeholder_text="ابحث بالاسم أو الباركود...",
            font=ctk.CTkFont(size=14),
            fg_color="transparent",
            border_width=0,
            height=45
        )
        self.search_entry.pack(side="left", fill="x", expand=True, padx=5)
        self.search_entry.bind("<Return>", self.add_product_to_cart)
        
        ctk.CTkButton(
            search_frame,
            text="إضافة",
            command=self.add_product_to_cart,
            font=ctk.CTkFont(size=14),
            height=35,
            corner_radius=8,
            fg_color="#1a73e8",
            hover_color="#1557b0",
            width=80
        ).pack(side="right", padx=5)
        
        # قائمة المنتجات المقترحة
        ctk.CTkLabel(
            left_frame,
            text="المنتجات المتاحة:",
            font=ctk.CTkFont(size=14),
            text_color="#888888"
        ).pack(anchor="w", padx=20, pady=(0, 10))
        
        product_list_frame = ctk.CTkScrollableFrame(left_frame, fg_color="transparent", height=250)
        product_list_frame.pack(fill="both", expand=True, padx=20, pady=(0, 15))
        
        products = self.product_manager.get_all_products()
        if products:
            for p in products[:10]:
                item_frame = ctk.CTkFrame(product_list_frame, fg_color="#2d2d44", corner_radius=8)
                item_frame.pack(fill="x", pady=2)
                
                ctk.CTkLabel(
                    item_frame,
                    text=f"{p[2]}",
                    font=ctk.CTkFont(size=14),
                    text_color="#ffffff"
                ).pack(side="left", padx=10)
                
                ctk.CTkLabel(
                    item_frame,
                    text=f"{p[3]:.2f} د.ج",
                    font=ctk.CTkFont(size=14),
                    text_color="#34a853"
                ).pack(side="right", padx=10)
                
                ctk.CTkLabel(
                    item_frame,
                    text=f"📦 {p[4]}",
                    font=ctk.CTkFont(size=12),
                    text_color="#fbbc04"
                ).pack(side="right", padx=10)
        else:
            ctk.CTkLabel(
                product_list_frame,
                text="📭 لا توجد منتجات",
                font=ctk.CTkFont(size=14),
                text_color="#888888"
            ).pack(pady=20)
        
        # قسم السلة (يمين)
        right_frame = ctk.CTkFrame(main_frame, fg_color="#1a1a2e", corner_radius=12)
        right_frame.pack(side="right", fill="both", expand=True, padx=(10, 0))
        
        # عنوان السلة
        ctk.CTkLabel(
            right_frame,
            text="🛒 سلة المشتريات",
            font=ctk.CTkFont(size=20, weight="bold"),
            text_color="#ffffff"
        ).pack(anchor="w", padx=20, pady=15)
        
        # قائمة السلة
        self.cart_frame = ctk.CTkScrollableFrame(right_frame, fg_color="transparent")
        self.cart_frame.pack(fill="both", expand=True, padx=20, pady=(0, 15))
        
        # المجموع
        total_frame = ctk.CTkFrame(right_frame, fg_color="#2d2d44", corner_radius=10)
        total_frame.pack(fill="x", padx=20, pady=(0, 15))
        
        self.total_label = ctk.CTkLabel(
            total_frame,
            text="المجموع: 0.00 د.ج",
            font=ctk.CTkFont(size=24, weight="bold"),
            text_color="#34a853"
        )
        self.total_label.pack(pady=15)
        
        # أزرار
        btn_frame = ctk.CTkFrame(right_frame, fg_color="transparent")
        btn_frame.pack(fill="x", padx=20, pady=(0, 15))
        
        ctk.CTkButton(
            btn_frame,
            text="💳 إتمام البيع",
            command=self.complete_sale,
            font=ctk.CTkFont(size=15, weight="bold"),
            height=45,
            corner_radius=10,
            fg_color="#34a853",
            hover_color="#2d9248"
        ).pack(side="right", padx=(0, 5))
        
        ctk.CTkButton(
            btn_frame,
            text="🗑️ مسح الكل",
            command=self.clear_cart,
            font=ctk.CTkFont(size=14),
            height=45,
            corner_radius=10,
            fg_color="#ea4335",
            hover_color="#c62828"
        ).pack(side="right", padx=5)
    
    def add_product_to_cart(self, event=None):
        search = self.search_entry.get().strip()
        if not search:
            messagebox.showwarning("تنبيه", "⚠️ اكتب اسم المنتج أو الباركود")
            return
        
        products = self.product_manager.search_product(search)
        if not products:
            messagebox.showerror("خطأ", "❌ المنتج غير موجود")
            return
        
        product = products[0]
        
        dialog = ctk.CTkInputDialog(text="أدخل الكمية:", title="الكمية")
        quantity_str = dialog.get_input()
        
        if not quantity_str:
            return
        
        try:
            quantity = int(quantity_str)
            if quantity <= 0:
                messagebox.showerror("خطأ", "⚠️ الكمية يجب أن تكون أكبر من 0")
                return
        except ValueError:
            messagebox.showerror("خطأ", "⚠️ الكمية يجب أن تكون رقماً")
            return
        
        if quantity > product[4]:
            messagebox.showerror("خطأ", f"⚠️ الكمية المتوفرة: {product[4]}")
            return
        
        # إضافة إلى السلة
        self.cart.append({
            "id": product[0],
            "name": product[2],
            "price": product[3],
            "quantity": quantity,
            "total": product[3] * quantity
        })
        
        self.update_cart_display()
        self.search_entry.delete(0, "end")
        self.search_entry.focus()
    
    def update_cart_display(self):
        for widget in self.cart_frame.winfo_children():
            widget.destroy()
        
        self.total = 0
        for i, item in enumerate(self.cart):
            # بطاقة العنصر
            card = ctk.CTkFrame(self.cart_frame, fg_color="#2d2d44", corner_radius=8)
            card.pack(fill="x", pady=3)
            
            # اسم المنتج
            ctk.CTkLabel(
                card,
                text=item["name"],
                font=ctk.CTkFont(size=14, weight="bold"),
                text_color="#ffffff"
            ).pack(side="left", padx=10)
            
            # الكمية والسعر
            ctk.CTkLabel(
                card,
                text=f"x{item['quantity']}",
                font=ctk.CTkFont(size=14),
                text_color="#fbbc04"
            ).pack(side="left", padx=5)
            
            ctk.CTkLabel(
                card,
                text=f"{item['price']:.2f} د.ج",
                font=ctk.CTkFont(size=14),
                text_color="#888888"
            ).pack(side="left", padx=5)
            
            ctk.CTkLabel(
                card,
                text=f"= {item['total']:.2f} د.ج",
                font=ctk.CTkFont(size=14, weight="bold"),
                text_color="#34a853"
            ).pack(side="left", padx=5)
            
            # زر حذف
            ctk.CTkButton(
                card,
                text="✖",
                command=lambda idx=i: self.remove_from_cart(idx),
                font=ctk.CTkFont(size=12),
                width=30,
                height=30,
                corner_radius=6,
                fg_color="#ea4335",
                hover_color="#c62828"
            ).pack(side="right", padx=5)
            
            self.total += item["total"]
        
        self.total_label.configure(text=f"المجموع: {self.total:.2f} د.ج")
    
    def remove_from_cart(self, index):
        del self.cart[index]
        self.update_cart_display()
    
    def clear_cart(self):
        if self.cart and messagebox.askyesno("تأكيد", "هل أنت متأكد من مسح السلة؟"):
            self.cart = []
            self.update_cart_display()
    
    def complete_sale(self):
        if not self.cart:
            messagebox.showerror("خطأ", "⚠️ السلة فارغة")
            return
        
        dialog = ctk.CTkInputDialog(
            text=f"💰 المجموع: {self.total:.2f} د.ج\nأدخل المبلغ المدفوع:",
            title="الدفع"
        )
        paid_str = dialog.get_input()
        
        if not paid_str:
            return
        
        try:
            paid = float(paid_str)
            if paid < self.total:
                messagebox.showerror("خطأ", "⚠️ المبلغ المدفوع أقل من المجموع")
                return
        except ValueError:
            messagebox.showerror("خطأ", "⚠️ المبلغ يجب أن يكون رقماً")
            return
        
        items = [{"product_id": item["id"], "quantity": item["quantity"], "price": item["price"]} for item in self.cart]
        success, invoice_number, total, change = self.sales_manager.create_invoice(0, items, 0, paid)
        
        if success:
            messagebox.showinfo(
                "✅ نجاح",
                f"تمت عملية البيع بنجاح!\n\n📄 رقم الفاتورة: {invoice_number}\n💰 المجموع: {total:.2f} د.ج\n🔄 الباقي: {change:.2f} د.ج"
            )
            self.clear_cart()
            self.parent.load_products()
            self.destroy()
        else:
            messagebox.showerror("خطأ", "❌ فشلت عملية البيع")