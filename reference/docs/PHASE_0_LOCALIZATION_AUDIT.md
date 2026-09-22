# PHASE 0 — Localization Audit

## Overview

- **Languages**: Arabic (primary), French, English
- **Translation System**: Python dict `_TRANSLATIONS` in `MainWindow` class
- **Translation Keys**: ~500+ keys (Arabic string → {ar, en, fr})
- **Currency**: Algerian Dinar (د.ج / DZD / DA)

## Translation Architecture

### Current System
```python
_TRANSLATIONS = {
    'سوبرماركت برو': {'en': 'Supermarket Pro', 'fr': 'Supermarket Pro'},
    'لوحة التحكم': {'en': 'Dashboard', 'fr': 'Tableau de bord'},
    # ... ~500 more entries
}

def t(self, value):
    if self.language == 'ar':
        return value  # Arabic is the key itself
    return self._TRANSLATIONS.get(value, {}).get(self.language, value)
```

### Issues

1. **Arabic is the key** — Translation keys are Arabic strings, not semantic keys
2. **Missing translations** — Many strings not in dictionary (hardcoded Arabic)
3. **No validation** — Missing translations silently fall back to Arabic
4. **Mixed languages** — Some UI elements have hardcoded French/English
5. **Dynamic strings** — f-strings with variables cannot be translated
6. **RTL handling** — Manual, not systematic

## Translation Coverage

### Fully Translated (in `_TRANSLATIONS`)
- Navigation labels
- Button labels
- Dialog titles
- Form labels
- Status messages
- Error messages
- Settings labels
- Report labels
- Print templates

### Partially Translated
- Tooltip texts
- Empty states
- Loading messages
- Validation messages

### NOT Translated (Hardcoded)
- SQL error messages (in `_friendly_error`)
- Technical error messages
- Some date formats
- Some number formats
- Print layout text (partially)

## RTL Support

### Current Implementation
- Arabic text direction set manually per widget
- `customtkinter` handles basic RTL
- No systematic RTL layout engine
- Tables may not align properly

### Requirements for New System
- Full RTL layout support
- Automatic text direction detection
- Mixed LTR/RTL text handling (Arabic + numbers)
- RTL table alignment
- RTL invoice/print layout

## Translation Key Structure (Proposed)

```
# Current (Arabic as key)
'لوحة التحكم': {'en': 'Dashboard', 'fr': 'Tableau de bord'}

# Proposed (semantic key)
'nav.dashboard': {'ar': 'لوحة التحكم', 'en': 'Dashboard', 'fr': 'Tableau de bord'}
'product.add': {'ar': 'إضافة منتج', 'en': 'Add Product', 'fr': 'Ajouter un produit'}
'sale.complete': {'ar': 'إتمام البيع', 'en': 'Complete Sale', 'fr': 'Finaliser la vente'}
'error.stock_insufficient': {'ar': 'المخزون غير كافٍ', 'en': 'Insufficient stock', 'fr': 'Stock insuffisant'}
```

## Missing Translations Inventory

### Hardcoded Arabic in main_window.py
- Line 4667: `except Exception: pass` (no message)
- Line 4950: `except Exception: pass` (no message)
- Line 10623: `"العميل غير موجود"` (not in translations)
- Line 10749: `"الدين الكامل يتطلب اختيار عميل"` (not in translations)
- Line 10754: `"أدخل مبلغًا صحيحًا"` (not in translations)
- Line 10758: `"المبلغ لا يمكن أن يكون سالبًا"` (not in translations)
- Line 10762: `"استخدم دفعًا جزئيًا..."` (not in translations)
- Line 10766: `"للدفع الكامل اختر نقدي أو بطاقة"` (not in translations)
- Line 10776: `"تسجيل الدين معطل من الإعدادات"` (not in translations)
- Line 10780: `"يجب اختيار عميل لتسجيل الدين"` (not in translations)

### Hardcoded Arabic in sales.py
- All validation messages (lines 78-84, 94-97, 109-111, etc.)
- All `_friendly_error` translations (lines 32-45)

### Hardcoded Arabic in modules
- customers.py: Success messages
- inventory.py: Validation messages
- packs.py: Error messages
- products.py: Success/error messages

## Recommendations for New System

1. **Use semantic keys** — `product.add` instead of Arabic strings
2. **Mandatory translations** — Build fails if any key missing in any language
3. **No hardcoded strings** — Every user-visible string must use translation function
4. **Flutter localization** — Use Flutter's built-in l10n system
5. **ARB files** — Use Flutter's standard ARB format for translations
6. **RTL engine** — Use Flutter's built-in RTL support
7. **Dynamic string translation** — Use parameterized translations
8. **Translation validation** — CI/CD checks for missing translations
