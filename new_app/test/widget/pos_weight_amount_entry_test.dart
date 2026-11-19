// Klick POS — weight/length AMOUNT entry (QuantityDialog modes).
//
// Mode toggle + amount mode are offered ONLY for selling units whose
// `unit_type` is weight (kg, gram) or length (meter); count-based units
// (piece, box, pack) keep the plain Phase 6 dialog. Amount → quantity
// uses the exact HALF-UP scaled math from core/amount_entry.dart, the
// ACTUAL total is recomputed from the rounded quantity and shown before
// confirmation, and a zero/invalid price disables amount mode with an
// explanation. The confirm contract is unchanged: the dialog returns a
// canonical quantity STRING (the cart, checkout and stock guard already
// speak fractional quantities).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/quantity_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

/// Mirrors the LTR isolate the app wraps quantity segments in (W7).
String _m(String v) => bidiIsolateLtr(v);

/// kg selling unit — weight, explicit price, 5 kg per unit.
const kgUnit = SellingUnitModel(
  id: 'su-kg',
  productId: 'prod-1',
  name: 'Kg',
  multiplier: '1',
  unitType: 'kg',
  sellingPrice: '250',
  availableSellingQty: '8',
  availableBaseQty: '8',
);

SellingUnitModel _unit({
  required String unitType,
  String id = 'su-x',
  String name = 'U',
  String multiplier = '1',
  String? sellingPrice = '250',
  String availableSelling = '8',
  String availableBase = '8',
}) =>
    SellingUnitModel(
      id: id,
      productId: 'prod-1',
      name: name,
      multiplier: multiplier,
      unitType: unitType,
      sellingPrice: sellingPrice,
      availableSellingQty: availableSelling,
      availableBaseQty: availableBase,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget app,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(home: Scaffold(body: app)),
    ),
  );
  await tester.pump();
}

void main() {
  group('mode toggle gating (weight/length only)', () {
    testWidgets('kg unit shows the quantity/amount toggle (amount default)',
        (tester) async {
      await _pump(
        tester,
        const QuantityDialog(unit: kgUnit, unitPrice: '250'),
      );
      expect(find.byKey(const Key('quantity-mode-quantity')), findsOneWidget);
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);
      // Amount entry is the opening default now; quantity stays one tap away.
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
      expect(find.byKey(const Key('quantity-input')), findsNothing);
      await tester.tap(find.byKey(const Key('quantity-mode-quantity')));
      await tester.pump();
      expect(find.byKey(const Key('quantity-input')), findsOneWidget);
    });

    testWidgets('gram unit shows the toggle too', (tester) async {
      await _pump(
        tester,
        const QuantityDialog(
          unit: SellingUnitModel(
            id: 'su-g',
            productId: 'p',
            name: 'Gram',
            multiplier: '1',
            unitType: 'gram',
            sellingPrice: '2',
          ),
          unitPrice: '2',
        ),
      );
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
    });

    testWidgets('piece and box units never see the toggle (regression)',
        (tester) async {
      await _pump(
        tester,
        QuantityDialog(
          unit: _unit(unitType: 'piece', sellingPrice: '10'),
          unitPrice: '10',
        ),
      );
      expect(find.byKey(const Key('quantity-mode-quantity')), findsNothing);
      expect(find.byKey(const Key('quantity-mode-amount')), findsNothing);
      expect(find.byKey(const Key('quantity-input')), findsOneWidget);

      await _pump(
        tester,
        QuantityDialog(
          unit: _unit(unitType: 'box', sellingPrice: '220'),
          unitPrice: '220',
        ),
      );
      expect(find.byKey(const Key('quantity-mode-amount')), findsNothing);
    });

    testWidgets('liter (volume) shows the toggle and defaults to amount',
        (tester) async {
      await _pump(
        tester,
        QuantityDialog(
          unit: _unit(unitType: 'liter', sellingPrice: '50'),
          unitPrice: '50',
        ),
      );
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('quantity-mode-amount')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
    });
  });

  group('Mode A — by quantity', () {
    testWidgets('reachable by switching; fraction accepted; line total shown',
        (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: kgUnit,
                  productQuantity: '8',
                  productUnit: 'kg',
                  unitPrice: '250',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      // Amount is the opening default; quantity mode is one tap away.
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('quantity-mode-amount')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('quantity-mode-quantity')));
      await tester.pump();
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const Key('quantity-mode-quantity')),
      );
      expect(chip.selected, isTrue);

      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '2.5',
      );
      await tester.pump();
      // 2.5 × 250 = 625 — the Mode A line-total preview.
      expect(
        find.byKey(const Key('quantity-line-total')),
        findsOneWidget,
      );
      expect(find.textContaining('625'), findsWidgets);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '2.5');
    });

    testWidgets('switching to amount mode hides the quantity field',
        (tester) async {
      await _pump(
        tester,
        const QuantityDialog(unit: kgUnit, unitPrice: '250'),
      );
      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
      expect(find.byKey(const Key('quantity-input')), findsNothing);

      await tester.tap(find.byKey(const Key('quantity-mode-quantity')));
      await tester.pump();
      expect(find.byKey(const Key('quantity-input')), findsOneWidget);
      expect(find.byKey(const Key('amount-input')), findsNothing);
    });
  });

  group('default mode — By amount on every opening', () {
    bool amountSelected(WidgetTester tester) => tester
        .widget<ChoiceChip>(find.byKey(const Key('quantity-mode-amount')))
        .selected;

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();
    }

    Widget opener(SellingUnitModel unit, String price) => Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () => showQuantityDialog(
                context,
                unit: unit,
                productQuantity: '20',
                productUnit: unit.unitType,
                unitPrice: price,
              ),
              child: const Text('open'),
            ),
          ),
        );

    testWidgets('kg opens in amount mode with the amount field focused',
        (tester) async {
      await _pump(tester, opener(kgUnit, '250'));
      await openDialog(tester);

      expect(amountSelected(tester), isTrue);
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
      expect(find.byKey(const Key('quantity-input')), findsNothing);
    });

    testWidgets('liter opens in amount mode', (tester) async {
      await _pump(
        tester,
        opener(_unit(unitType: 'liter', name: 'Liter', sellingPrice: '50'),
            '50'),
      );
      await openDialog(tester);

      expect(amountSelected(tester), isTrue);
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
    });

    testWidgets('meter opens in amount mode', (tester) async {
      await _pump(
        tester,
        opener(_unit(unitType: 'meter', name: 'Meter', sellingPrice: '20'),
            '20'),
      );
      await openDialog(tester);

      expect(amountSelected(tester), isTrue);
    });

    testWidgets(
        'reopening after a quantity-mode session starts in amount mode again '
        '(nothing is inherited)', (tester) async {
      await _pump(tester, opener(kgUnit, '250'));

      await openDialog(tester);
      await tester.tap(find.byKey(const Key('quantity-mode-quantity')));
      await tester.pump();
      expect(amountSelected(tester), isFalse);
      await tester.tap(find.byKey(const Key('quantity-cancel')));
      await tester.pumpAndSettle();

      await openDialog(tester);
      expect(amountSelected(tester), isTrue);
      expect(find.byKey(const Key('amount-input')), findsOneWidget);
    });

    testWidgets('amount → quantity conversion uses the existing unit price',
        (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: kgUnit,
                  productQuantity: '8',
                  productUnit: 'kg',
                  unitPrice: '250',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await openDialog(tester);

      // No mode switch needed any more: the dialog IS in amount mode.
      await tester.enterText(find.byKey(const Key('amount-input')), '100');
      await tester.pump();
      expect(
        find.text('Computed quantity: ${_m('0.4')} Kg'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '0.4');
    });
  });

  group('Mode B — by amount', () {
    testWidgets('100 DA at 250/kg → computed 0.4 kg, line total 100',
        (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: kgUnit,
                  productQuantity: '8',
                  productUnit: 'kg',
                  unitPrice: '250',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '100');
      await tester.pump();

      expect(
        find.byKey(const Key('amount-computed-quantity')),
        findsOneWidget,
      );
      // 'Computed quantity: 0.4 Kg'
      expect(find.text('Computed quantity: ${_m('0.4')} Kg'), findsOneWidget);
      // Exact division → actual == requested, no requested-amount note.
    expect(find.text('Line total: ${_m('100')}'), findsOneWidget);
    expect(find.byKey(const Key('amount-requested')), findsNothing);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '0.4');
    });

    testWidgets('rounding: 100 DA at 300 → 0.333 for 99.9 with the '
        'requested amount disclosed', (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: _unit(
                    unitType: 'kg',
                    name: 'Kg',
                    sellingPrice: '300',
                  ),
                  productQuantity: '8',
                  productUnit: 'kg',
                  unitPrice: '300',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '100');
      await tester.pump();

      expect(find.text('Computed quantity: ${_m('0.333')} Kg'), findsOneWidget);
      // The ACTUAL charge from the rounded quantity — never a silent 100.
    expect(find.text('Line total: ${_m('99.9')}'), findsOneWidget);
    expect(find.text('Requested amount: ${_m('100')}'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '0.333');
    });

    testWidgets('length: 50 DA at 20/m → 2.5 m', (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: _unit(unitType: 'meter', name: 'Meter', sellingPrice: '20'),
                  productQuantity: '50',
                  productUnit: 'meter',
                  unitPrice: '20',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '50');
      await tester.pump();
      expect(find.text('Computed quantity: ${_m('2.5')} Meter'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '2.5');
    });

    testWidgets('amount divides by the SELLING unit price with multiplier — '
        '2000 DA at 1000/sack → 2 sacks (not base kilograms)',
        (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: _unit(
                    id: 'su-sack',
                    unitType: 'kg',
                    name: 'Sack',
                    multiplier: '5',
                    sellingPrice: '1000',
                  ),
                  productQuantity: '20',
                  productUnit: 'kg',
                  unitPrice: '1000',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '2000');
      await tester.pump();
      // In SELLING units (sacks) — not base kilograms.
      expect(find.text('Computed quantity: ${_m('2')} Sack'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '2');
    });
  });

  group('Mode B — validation', () {
    Future<void> openAmount(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
    }

    testWidgets('empty amount → enter_amount error', (tester) async {
      await _pump(
        tester,
        const QuantityDialog(unit: kgUnit, unitPrice: '250'),
      );
      await openAmount(tester);
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pump();
      final error = tester.widget<Text>(
        find.byKey(const Key('quantity-error')),
      );
      expect(error.data, 'Enter amount');
    });

    testWidgets('non-numeric, zero and negative → invalid_amount error',
        (tester) async {
      await _pump(
        tester,
        const QuantityDialog(unit: kgUnit, unitPrice: '250'),
      );
      await openAmount(tester);
      for (final bad in ['abc', '0', '-5']) {
        await tester.enterText(find.byKey(const Key('amount-input')), bad);
        await tester.tap(find.byKey(const Key('quantity-submit')));
        await tester.pump();
        final error = tester.widget<Text>(
          find.byKey(const Key('quantity-error')),
        );
        expect(
          error.data,
          'Invalid amount',
          reason: 'amount "$bad" must be rejected',
        );
      }
    });

    testWidgets('huge amount exceeding the POS quantity cap → too_large',
        (tester) async {
      await _pump(
        tester,
        const QuantityDialog(
          unit: SellingUnitModel(
            id: 'su-micro',
            productId: 'p',
            name: 'Bit',
            multiplier: '1',
            unitType: 'kg',
            sellingPrice: '0.001',
          ),
          productQuantity: '9999999',
          unitPrice: '0.001',
        ),
      );
      await openAmount(tester);
      await tester.enterText(find.byKey(const Key('amount-input')), '9999999');
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pump();
      expect(find.byKey(const Key('quantity-error')), findsOneWidget);
    });

    testWidgets('converted quantity over base stock → out_of_stock',
        (tester) async {
      await _pump(
        tester,
        const QuantityDialog(
          unit: SellingUnitModel(
            id: 'su-sack',
            productId: 'p',
            name: 'Sack',
            multiplier: '5',
            unitType: 'kg',
            sellingPrice: '1000',
          ),
          productQuantity: '8', // 8 kg base → max 1 sack
          productUnit: 'kg',
          unitPrice: '1000',
        ),
      );
      await openAmount(tester);
      // 3000 → 3 sacks → 15 kg needed > 8 kg stock.
      await tester.enterText(find.byKey(const Key('amount-input')), '3000');
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pump();
      expect(find.byKey(const Key('quantity-error')), findsOneWidget);
    });
  });

  group('zero / invalid price', () {
    testWidgets('amount chip disabled with explanation; quantity mode works',
        (tester) async {
      String? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-btn'),
              onPressed: () async {
                result = await showQuantityDialog(
                  context,
                  unit: _unit(unitType: 'kg', sellingPrice: null),
                  productQuantity: '8',
                  productUnit: 'kg',
                  unitPrice: '0',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const Key('quantity-mode-amount')),
      );
      expect(chip.onSelected, isNull); // disabled
      expect(
        find.byKey(const Key('amount-mode-unavailable')),
        findsOneWidget,
      );
      expect(
        find.text('Invalid price — amount entry unavailable'),
        findsOneWidget,
      );

      // Quantity mode still accepts the fraction.
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '1.5',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '1.5');
    });

    testWidgets('null unitPrice also disables amount mode', (tester) async {
      await _pump(
        tester,
        QuantityDialog(
          unit: _unit(unitType: 'kg', sellingPrice: null),
          productQuantity: '8',
        ),
      );
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const Key('quantity-mode-amount')),
      );
      expect(chip.onSelected, isNull);
    });
  });

  group('fractional quantity contract', () {
    test('amount-mode result string is checkout-ready for CartLine', () {
      // The dialog returns the canonical quantity TEXT — the same value
      // the cart stores verbatim and toSaleJson() sends as `quantity`.
      const line = CartLine(
        productId: 'prod-1',
        name: 'Flour',
        quantity: '0.4',
        unitPrice: '250',
        productUnit: 'kg',
        unitName: 'kg',
      );
      final json = line.toSaleJson();
      expect(json['quantity'], '0.4');
      expect(json['unit_price'], '250');
      expect(json['selling_unit_id'], isNull);
    });
  });
}
