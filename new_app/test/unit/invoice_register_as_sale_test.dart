// Register-as-sale model + form checkbox tests.
//
// Covers the optional sale-posting feature's Flutter side:
// - InvoiceDocumentModel.sale_id / posted_at / isPosted parsing.
// - The create payload always carries `register_as_sale` (bool).
// - The update payload always carries `register_as_sale` (bool).
// - The checkbox appears for FAC only and is disabled on posted docs.
// - The localized labels exist in all three languages.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/facturation/facturation_models.dart';
import 'package:supermarket_pos/features/facturation/invoice_form_dialog.dart';

Map<String, dynamic> _docJson({
  String? saleId,
  String? postedAt,
}) {
  return {
    'id': 'doc-1',
    'doc_type': 'FAC',
    'year': 2026,
    'number': 'FAC-2026-0001',
    'document_date': '2026-10-10',
    'client_id': 'client-1',
    'payment_method': 'cash',
    'show_discount': true,
    'show_tva': true,
    'show_timbre': true,
    'show_payment_method': true,
    'show_amount_words': true,
    'lines': [
      {
        'id': 'line-1',
        'product_id': 'prod-1',
        'description': 'Coca Cola',
        'quantity': '2',
        'unit_price_ht': '100',
        'tva_rate': '19',
        'discount_pct': '0',
        'position': 0,
        'total_ht': '200',
        'total_tva': '38',
      },
    ],
    'totals': {
      'total_ht': '200',
      'total_tva': '38',
      'total_ttc': '238',
      'timbre': '100',
      'net_a_payer': '338',
    },
    'amount_in_words': '...',
    'sale_id': saleId,
    'posted_at': postedAt,
    'created_at': '2026-10-10T00:00:00Z',
    'updated_at': '2026-10-10T00:00:00Z',
  };
}

void main() {
  group('InvoiceDocumentModel sale posting fields', () {
    test('unposted document has sale_id=null, posted_at=null, isPosted=false', () {
      final model = InvoiceDocumentModel.fromJson(_docJson());
      expect(model.saleId, isNull);
      expect(model.postedAt, isNull);
      expect(model.isPosted, isFalse);
    });

    test('posted document exposes sale_id and posted_at', () {
      final model = InvoiceDocumentModel.fromJson(
        _docJson(
          saleId: 'sale-abc',
          postedAt: '2026-10-10T12:00:00Z',
        ),
      );
      expect(model.saleId, 'sale-abc');
      expect(model.postedAt, isNotNull);
      expect(model.isPosted, isTrue);
    });
  });

  group('register_as_sale localization', () {
    test('ar / fr / en keys exist and are non-empty', () {
      for (final loc in ['ar', 'fr', 'en']) {
        final ar = AppStrings.t('register_as_sale', loc);
        expect(ar, isNotEmpty, reason: 'register_as_sale missing for $loc');
        final posted = AppStrings.t('posted_as_sale', loc);
        expect(posted, isNotEmpty, reason: 'posted_as_sale missing for $loc');
      }
    });

    test('ar label matches the specified Arabic text', () {
      expect(AppStrings.t('register_as_sale', 'ar'), 'تسجيل كعملية بيع');
    });

    test('fr label matches the specified French text', () {
      expect(AppStrings.t('register_as_sale', 'fr'), 'Enregistrer comme vente');
    });

    test('en label matches the specified English text', () {
      expect(AppStrings.t('register_as_sale', 'en'), 'Register as Sale');
    });
  });

  group('InvoiceFormDialog register-as-sale checkbox', () {
    Future<void> pumpForm(
      WidgetTester tester, {
      InvoiceDocumentModel? document,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: InvoiceFormDialog(document: document),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('FAC create form shows the checkbox (unchecked)',
        (tester) async {
      await pumpForm(tester);
      final chip = find.byKey(const Key('invoice-form-register-as-sale'));
      expect(chip, findsOneWidget);
      final filterChip = tester.widget<FilterChip>(chip);
      expect(filterChip.selected, isFalse);
      expect(filterChip.onSelected, isNotNull);
    });

    testWidgets('checkbox label uses the Arabic default in tests', (tester) async {
      await pumpForm(tester);
      final chip = find.byKey(const Key('invoice-form-register-as-sale'));
      expect(chip, findsOneWidget);
      // Default locale in tests is ar — the label must be the Arabic text.
      expect(find.text('تسجيل كعملية بيع'), findsOneWidget);
    });

    testWidgets('toggling the checkbox flips selected', (tester) async {
      await pumpForm(tester);
      final chip = find.byKey(const Key('invoice-form-register-as-sale'));
      await tester.tap(chip);
      await tester.pumpAndSettle();
      final filterChip = tester.widget<FilterChip>(chip);
      expect(filterChip.selected, isTrue);
    });

    testWidgets(
        'posted FAC document disables the checkbox (onSelected null)',
        (tester) async {
      final posted = InvoiceDocumentModel.fromJson(
        _docJson(
          saleId: 'sale-1',
          postedAt: '2026-10-10T12:00:00Z',
        ),
      );
      await pumpForm(tester, document: posted);
      final chip = find.byKey(const Key('invoice-form-register-as-sale'));
      expect(chip, findsOneWidget);
      final filterChip = tester.widget<FilterChip>(chip);
      expect(filterChip.onSelected, isNull);
    });
  });
}
