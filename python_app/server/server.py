# server/server.py - خادم Flask للتواصل

from flask import Flask, request, jsonify
import sys
import os

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from modules.products import ProductManager
from modules.sales import SalesManager
from security.license import LicenseManager

app = Flask(__name__)
product_manager = ProductManager()
sales_manager = SalesManager()
license_manager = LicenseManager()

@app.route('/api/check_license', methods=['POST'])
def check_license():
    data = request.json
    serial = data.get('serial')
    if not serial:
        return jsonify({'success': False, 'message': 'رقم السيريال مطلوب'})
    
    success, message = license_manager.activate_license(serial)
    return jsonify({'success': success, 'message': message})

@app.route('/api/search_product', methods=['GET'])
def search_product():
    search = request.args.get('search', '')
    products = product_manager.search_product(search)
    result = []
    for p in products:
        result.append({
            'id': p[0],
            'barcode': p[1],
            'name': p[2],
            'price': p[3],
            'quantity': p[4]
        })
    return jsonify({'success': True, 'products': result})

@app.route('/api/get_product_by_barcode', methods=['GET'])
def get_product_by_barcode():
    barcode = request.args.get('barcode', '')
    product = product_manager.get_product_by_barcode(barcode)
    if product:
        return jsonify({
            'success': True,
            'product': {
                'id': product[0],
                'name': product[1],
                'price': product[2],
                'quantity': product[3]
            }
        })
    return jsonify({'success': False, 'message': 'المنتج غير موجود'})

@app.route('/api/add_sale', methods=['POST'])
def add_sale():
    data = request.json
    items = data.get('items', [])
    customer_id = data.get('customer_id', 0)
    paid_amount = data.get('paid_amount', 0)
    
    success, invoice, total, change = sales_manager.create_invoice(customer_id, items, 0, paid_amount)
    
    if success:
        return jsonify({
            'success': True,
            'invoice': invoice,
            'total': total,
            'change': change
        })
    reason = getattr(sales_manager, "last_error", None) or "فشلت عملية البيع"
    return jsonify({'success': False, 'message': f"فشلت عملية البيع: {reason}"})

@app.route('/api/get_all_products', methods=['GET'])
def get_all_products():
    products = product_manager.get_all_products()
    result = []
    for p in products:
        result.append({
            'id': p[0],
            'barcode': p[1],
            'name': p[2],
            'price': p[3],
            'quantity': p[4],
            'unit': p[5]
        })
    return jsonify({'success': True, 'products': result})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)