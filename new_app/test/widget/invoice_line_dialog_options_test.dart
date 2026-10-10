// Stage 3A — invoice line dialog option identity widget tests.
//
// Verifies the edit-mode rehydration contract: a saved draft line
// carrying variant / selling-unit / pack links re-opens with the
// selection intact and round-trips the same ids on submit. Plain
// product and free-text lines keep their existing behavior.
//
// No dio is exercised (pickers are never opened) — a bare
// ProviderScope with the default locale is enough.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/facturation/facturation_models.dart';
import 'package:supermarket_pos/features/facturation/invoice_line_dialog.dart';

void main() {
  testWidgets('variant line edit rehydrates selection and round-trips ids',
      (tester) async {
    const initial = DraftInvoiceLine(
      productId: 'p1',
      productName: 'Coca Cola',
      variantId: 'v1',
      variantName: 'Big',
      description: 'Coca Cola · Big',
      quantity: '2',
      unitPriceHt: '120.000',
      tvaRate: 19,
      discountPct: '0',
    );
    DraftInvoiceLine? submitted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () async {
                  submitted = await showInvoiceLineDialog(
                    context,
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();

    // Product header + the selected variant shown on its button.
    // The harness default locale is ar (LocaleState default).
    expect(find.byKey(const Key('invoice-line-product')), findsOneWidget);
    expect(
      find.text('${AppStrings.t('variants', 'ar')}: Big'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('invoice-line-pick-variant')), findsOneWidget);
    expect(
      find.byKey(const Key('invoice-line-pick-selling-unit')),
      findsOneWidget,
    );
    // Not free-text → no description field.
    expect(find.byKey(const Key('invoice-line-description')), findsNothing);

    await tester.tap(find.byKey(const Key('invoice-line-submit')));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.productId, 'p1');
    expect(submitted!.variantId, 'v1');
    expect(submitted!.sellingUnitId, isNull);
    expect(submitted!.packId, isNull);
    expect(submitted!.description, 'Coca Cola · Big');
  });

  testWidgets('selling-unit line edit rehydrates the unit link',
      (tester) async {
    const initial = DraftInvoiceLine(
      productId: 'p1',
      productName: 'Coca Cola',
      sellingUnitId: 'u1',
      sellingUnitName: 'Box',
      description: 'Coca Cola · Box',
      quantity: '1',
      unitPriceHt: '2200.000',
      tvaRate: 19,
    );
    DraftInvoiceLine? submitted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () async {
                  submitted = await showInvoiceLineDialog(
                    context,
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();

    expect(
      find.text('${AppStrings.t('selling_units', 'ar')}: Box'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('invoice-line-submit')));
    await tester.pumpAndSettle();

    expect(submitted!.sellingUnitId, 'u1');
    expect(submitted!.variantId, isNull);
    expect(submitted!.productId, 'p1');
  });

  testWidgets('pack line edit shows pack name, no product options',
      (tester) async {
    const initial = DraftInvoiceLine(
      packId: 'k1',
      packName: 'Pack Promo',
      description: 'Pack Promo',
      quantity: '1',
      unitPriceHt: '250.000',
      tvaRate: 0,
    );
    DraftInvoiceLine? submitted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () async {
                  submitted = await showInvoiceLineDialog(
                    context,
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();

    // Header shows the pack; product option buttons are absent.
    expect(find.text('Pack Promo'), findsOneWidget);
    expect(find.byKey(const Key('invoice-line-pick-variant')), findsNothing);
    expect(
      find.byKey(const Key('invoice-line-pick-selling-unit')),
      findsNothing,
    );
    expect(find.byKey(const Key('invoice-line-pick-product')), findsOneWidget);
    // Not free-text → no description field.
    expect(find.byKey(const Key('invoice-line-description')), findsNothing);

    await tester.tap(find.byKey(const Key('invoice-line-submit')));
    await tester.pumpAndSettle();

    expect(submitted!.packId, 'k1');
    expect(submitted!.productId, isNull);
    expect(submitted!.variantId, isNull);
    expect(submitted!.sellingUnitId, isNull);
    expect(submitted!.quantity, '1');
    expect(submitted!.unitPriceHt, '250.000');
  });

  testWidgets(
      'ids-only edit (persisted line) recovers the variant name from '
      'the description', (tester) async {
    // The persisted InvoiceLineModel carries ids but no display names.
    const initial = DraftInvoiceLine(
      productId: 'p1',
      variantId: 'v1',
      description: 'Coca Cola · Big',
      quantity: '2',
      unitPriceHt: '120.000',
      tvaRate: 19,
    );
    DraftInvoiceLine? submitted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () async {
                  submitted = await showInvoiceLineDialog(
                    context,
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();

    // The name was recovered from the "Product · Option" convention.
    expect(
      find.text('${AppStrings.t('variants', 'ar')}: Big'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('invoice-line-submit')));
    await tester.pumpAndSettle();

    expect(submitted!.variantId, 'v1');
    expect(submitted!.variantName, 'Big');
  });

  testWidgets('free-text line keeps the description field (regression)',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: InvoiceLineDialog(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invoice-line-description')), findsOneWidget);
    // The pack entry is offered on free-text lines.
    expect(find.byKey(const Key('invoice-line-pick-pack')), findsOneWidget);
  });

  testWidgets('plain product line round-trips without option ids',
      (tester) async {
    const initial = DraftInvoiceLine(
      productId: 'p1',
      productName: 'Coca Cola',
      description: 'Coca Cola',
      quantity: '3',
      unitPriceHt: '100.000',
      tvaRate: 19,
    );
    DraftInvoiceLine? submitted;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-dialog'),
                onPressed: () async {
                  submitted = await showInvoiceLineDialog(
                    context,
                    initial: initial,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();

    expect(find.text('Coca Cola'), findsOneWidget);
    expect(find.byKey(const Key('invoice-line-pick-variant')), findsOneWidget);

    await tester.tap(find.byKey(const Key('invoice-line-submit')));
    await tester.pumpAndSettle();

    expect(submitted!.productId, 'p1');
    expect(submitted!.variantId, isNull);
    expect(submitted!.sellingUnitId, isNull);
    expect(submitted!.packId, isNull);
  });
}
