// Invoice-level discount dialog (F7): amount / percent input modes.
//
// Contracts under test (client side; the server re-validates on checkout):
//  - amount mode is the ORIGINAL behaviour: a fixed DZD figure is stored
//    verbatim as `invoice_discount`, exactly what the dialog opened with;
//  - percent mode is a pure INPUT mode: it previews live against the
//    current subtotal (after line discounts) and converts to a rounded
//    2-decimal amount AT SAVE TIME — only the amount is ever persisted;
//  - validation rejects (never clamps): unparseable/negative input and an
//    amount above the eligible subtotal → `invalid_amount`; a percent
//    above 100 → `discount_percent_too_high`; a rejection keeps the
//    dialog open and the stored discount untouched;
//  - reopening lands in amount mode with the stored amount prefilled.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/pos/invoice_discount_dialog.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Subtotal under test: 3 × 10 = 30 (no line discounts).
const _line = CartLine(
  productId: 'p1',
  name: 'Bread',
  quantity: '3',
  unitPrice: '10',
);

Future<ProviderContainer> _pumpDialog(
  WidgetTester tester, {
  AppLocale locale = AppLocale.en,
  bool withLine = true,
  String initialDiscount = '',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final dio = MockDio();
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('opener'),
              onPressed: () => showInvoiceDiscountDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('opener'))),
    listen: false,
  );
  final notifier = container.read(posCartProvider.notifier);
  if (withLine) notifier.addLine(_line);
  if (initialDiscount.isNotEmpty) {
    notifier.setInvoiceDiscount(initialDiscount);
  }
  await tester.pump();

  await tester.tap(find.byKey(const Key('opener')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
  return container;
}

Finder _segment(String label, String loc) => find.descendant(
      of: find.byKey(const Key('invoice-discount-mode')),
      matching: find.text(AppStrings.t(label, loc)),
    );

String _previewOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data ?? '';

/// The active input mode is observable through the field's decoration:
/// amount mode labels the field "Amount" with no suffix, percent mode
/// labels it "Percentage" with a '%' suffix.
void expectMode(WidgetTester tester, String labelKey, String loc) {
  final field = tester
      .widget<TextField>(find.byKey(const Key('invoice-discount-input')));
  expect(field.decoration?.labelText, AppStrings.t(labelKey, loc),
      reason: 'active mode is $labelKey');
  expect(
    field.decoration?.suffixText,
    labelKey == 'discount_type_percent' ? '%' : isNull,
  );
}

void main() {
  const loc = 'en';
  final currency = AppStrings.t('currency', loc);

  group('amount mode (original behaviour preserved)', () {
    testWidgets(
        'opens in amount mode with the stored amount prefilled and saves '
        'it verbatim', (tester) async {
      final container =
          await _pumpDialog(tester, initialDiscount: '15.5');

      expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('invoice-discount-input')))
            .controller!
            .text,
        '15.5',
        reason: 'reopening lands on the stored amount',
      );
      expectMode(tester, 'discount_type_amount', loc);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '10',
      );
      await tester.pump();
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-amount')),
        '-10.00 $currency',
      );
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-total')),
        '20.00',
        reason: 'subtotal 30 − discount 10',
      );

      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);
      expect(container.read(posCartProvider).invoiceDiscount, '10.0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an amount above the subtotal is rejected, not clamped',
        (tester) async {
      final container = await _pumpDialog(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '50',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pump();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-discount-error')))
            .data,
        AppStrings.t('invalid_amount', loc),
      );
      expect(container.read(posCartProvider).invoiceDiscount, '0',
          reason: 'a rejected input never changes the stored discount');

      // Typing again clears the error (the rejection is live, not sticky).
      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '12',
      );
      await tester.pump();
      expect(find.byKey(const Key('invoice-discount-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unparseable input shows invalid_amount and never saves',
        (tester) async {
      final container = await _pumpDialog(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '12.3.4',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pump();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-discount-error')))
            .data,
        AppStrings.t('invalid_amount', loc),
      );
      expect(container.read(posCartProvider).invoiceDiscount, '0',
          reason: 'a rejected input never changes the stored discount');
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancel leaves the stored discount untouched', (tester) async {
      final container = await _pumpDialog(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '9',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, AppStrings.t('cancel', loc)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);
      expect(container.read(posCartProvider).invoiceDiscount, '0',
          reason: 'a rejected input never changes the stored discount');
      expect(tester.takeException(), isNull);
    });
  });

  group('percent mode', () {
    Future<void> toPercent(WidgetTester tester) async {
      await tester.tap(_segment('discount_type_percent', loc));
      await tester.pump();
      expectMode(tester, 'discount_type_percent', loc);
    }

    testWidgets(
        'previews against the subtotal and converts to a rounded amount '
        'at save time (only the amount is stored)', (tester) async {
      final container = await _pumpDialog(tester);
      await toPercent(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '10',
      );
      await tester.pump();
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-amount')),
        '-3.00 $currency',
        reason: '10% of the 30 subtotal',
      );
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-total')),
        '27.00',
      );

      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);
      expect(container.read(posCartProvider).invoiceDiscount, '3.0',
          reason: 'the percent never reaches the cart state — only money');
      expect(tester.takeException(), isNull);
    });

    testWidgets('sub-step percents round to 2 decimals at save time',
        (tester) async {
      final container = await _pumpDialog(tester);
      await toPercent(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '12.5',
      );
      await tester.pump();
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-amount')),
        '-3.75 $currency',
      );

      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();

      expect(container.read(posCartProvider).invoiceDiscount, '3.75');
      expect(tester.takeException(), isNull);
    });

    testWidgets('100% discounts the whole subtotal', (tester) async {
      final container = await _pumpDialog(tester);
      await toPercent(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '100',
      );
      await tester.pump();
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-amount')),
        '-30.00 $currency',
      );
      expect(
        _previewOf(tester, const Key('invoice-discount-preview-total')),
        '0.00',
      );

      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();

      expect(container.read(posCartProvider).invoiceDiscount, '30.0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('above 100% is rejected with its own message, never saved',
        (tester) async {
      final container = await _pumpDialog(tester);
      await toPercent(tester);

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '150',
      );
      await tester.pump();
      // Live: no preview money for an invalid percent.
      expect(
        find.byKey(const Key('invoice-discount-preview-amount')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pump();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-discount-error')))
            .data,
        AppStrings.t('discount_percent_too_high', loc),
      );
      expect(container.read(posCartProvider).invoiceDiscount, '0',
          reason: 'a rejected input never changes the stored discount');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'reopening after a percent save lands in amount mode with the '
        'converted amount prefilled', (tester) async {
      final container = await _pumpDialog(tester);
      await toPercent(tester);
      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '10',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();
      expect(container.read(posCartProvider).invoiceDiscount, '3.0');

      await tester.tap(find.byKey(const Key('opener')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      expectMode(tester, 'discount_type_amount', loc);
      expect(
        tester
            .widget<TextField>(
                find.byKey(const Key('invoice-discount-input')))
            .controller!
            .text,
        '3.0',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('empty cart guard', () {
    testWidgets('any amount above a zero subtotal is rejected', (tester) async {
      final container = await _pumpDialog(tester, withLine: false);

      expect(
        find.textContaining(AppStrings.t('subtotal_label', loc)),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '10',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pump();

      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-discount-error')))
            .data,
        AppStrings.t('invalid_amount', loc),
      );
      expect(container.read(posCartProvider).invoiceDiscount, '0',
          reason: 'a rejected input never changes the stored discount');
      expect(tester.takeException(), isNull);
    });
  });

  group('localization', () {
    testWidgets('the mode selector and errors speak the active locale',
        (tester) async {
      await _pumpDialog(tester, locale: AppLocale.fr);

      expect(
        find.text(AppStrings.t('discount_type_amount', 'fr')),
        findsWidgets,
      );
      expect(
        find.text(AppStrings.t('discount_type_percent', 'fr')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '150',
      );
      await tester.pump();
      await tester.tap(_segment('discount_type_percent', 'fr'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('invoice-discount-input')),
        '150',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-discount-error')))
            .data,
        AppStrings.t('discount_percent_too_high', 'fr'),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
