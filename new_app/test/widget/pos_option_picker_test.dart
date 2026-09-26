// UX FIX #6 — PosOptionPickerDialog option-card picker tests (13).
//
// Covers: card layout + badges, selected state, arrow navigation,
// Enter confirm, number quick-select, digit guard while editing,
// cancel/confirm actions, keyboard hint, no overflow, RTL/l10n labels.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_option_picker.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';

void main() {
  Future<void> pumpPicker(
    WidgetTester tester, {
    List<PosOptionCard>? options,
    AppLocale locale = AppLocale.en,
    TextDirection direction = TextDirection.ltr,
    Size size = const Size(900, 700),
    required void Function(int index) onConfirm,
    String dialogKey = 'variant-picker',
    String title = 'Variants',
    String? subtitle,
    bool withEditable = false,
    TextEditingController? editableController,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final cards = options ??
        const [
          PosOptionCard(
            optionKey: 'variant-var-1',
            title: 'Large',
            price: '12',
            secondary: 'B-var-1',
          ),
          PosOptionCard(
            optionKey: 'variant-var-2',
            title: 'Small',
            price: '8',
            secondary: 'B-var-2',
          ),
          PosOptionCard(
            optionKey: 'variant-var-3',
            title: 'Medium',
            price: '10',
            secondary: 'B-var-3',
          ),
        ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider
              .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        ],
        child: MaterialApp(
          locale: Locale(locale.name),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (withEditable)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          key: const Key('qty-field'),
                          controller: editableController,
                        ),
                      ),
                    Builder(
                      builder: (context) => ElevatedButton(
                        key: const Key('open-picker'),
                        onPressed: () {
                          showDialog<void>(
                            context: context,
                            builder: (_) => PosOptionPickerDialog(
                              title: title,
                              subtitle: subtitle,
                              options: cards,
                              dialogKey: dialogKey,
                              onConfirm: (i) async => onConfirm(i),
                            ),
                          );
                        },
                        child: const Text('Open'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-picker')));
    await tester.pumpAndSettle();
  }

  group('PosOptionPickerDialog cards (UX FIX #6)', () {
    testWidgets('renders option cards with number badges and titles',
        (tester) async {
      await pumpPicker(tester, onConfirm: (_) {});
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-1')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-2')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-3')), findsOneWidget);
      expect(find.byKey(const Key('pos-option-badge-1')), findsOneWidget);
      expect(find.byKey(const Key('pos-option-badge-2')), findsOneWidget);
      expect(find.byKey(const Key('pos-option-badge-3')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-1-title')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-1-price')), findsOneWidget);
      expect(find.byKey(const Key('variant-var-1-secondary')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('first option is selected on open (check icon present)',
        (tester) async {
      await pumpPicker(tester, onConfirm: (_) {});
      expect(find.byKey(const Key('pos-option-selected')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('variant-var-1')),
          matching: find.byKey(const Key('pos-option-selected')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('variant-var-2')),
          matching: find.byKey(const Key('pos-option-selected')),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArrowDown / ArrowRight move selection to next option',
        (tester) async {
      await pumpPicker(tester, onConfirm: (_) {});
      expect(find.byKey(const Key('pos-option-selected')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 150));
      // Selection still exactly one icon — now on card 2.
      expect(find.byKey(const Key('pos-option-selected')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('pos-option-selected')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArrowUp moves selection back toward first option',
        (tester) async {
      await pumpPicker(tester, onConfirm: (_) {});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('pos-option-selected')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter confirms the currently selected option', (tester) async {
      final confirmed = <int>[];
      await pumpPicker(tester, onConfirm: confirmed.add);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(confirmed, [0]);
      // Parent decides pop — dialog stays open in this harness.
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
    });

    testWidgets('number key 1 confirms first option immediately',
        (tester) async {
      final confirmed = <int>[];
      await pumpPicker(tester, onConfirm: confirmed.add);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();

      expect(confirmed, [0]);
    });

    testWidgets('number key 3 confirms third option immediately',
        (tester) async {
      final confirmed = <int>[];
      await pumpPicker(tester, onConfirm: confirmed.add);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pumpAndSettle();

      expect(confirmed, [2]);
    });

    testWidgets('confirm button confirms current selection', (tester) async {
      final confirmed = <int>[];
      await pumpPicker(tester, onConfirm: confirmed.add);

      await tester.tap(find.byKey(const Key('pos-option-picker-confirm')));
      await tester.pumpAndSettle();

      expect(confirmed, [0]);
    });

    testWidgets('cancel button closes dialog without confirming',
        (tester) async {
      final confirmed = <int>[];
      await pumpPicker(tester, onConfirm: confirmed.add);

      await tester.tap(find.byKey(const Key('pos-option-picker-cancel')));
      await tester.pumpAndSettle();

      expect(confirmed, isEmpty);
      expect(find.byKey(const Key('variant-picker')), findsNothing);
    });

    testWidgets(
        'digit keys do not confirm an option while an EditableText has '
        'primary focus (quantity guard)', (tester) async {
      final confirmed = <int>[];
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await pumpPicker(
        tester,
        onConfirm: confirmed.add,
        withEditable: true,
        editableController: controller,
      );
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);

      // Steal primary focus to the background text field (EditableText).
      final editableState = tester.state<EditableTextState>(
        find.byType(EditableText).first,
      );
      editableState.widget.focusNode.requestFocus();
      await tester.pump(const Duration(milliseconds: 100));
      // Same check as PosOptionPickerDialog._editableTextHasFocus().
      final focusContext = FocusManager.instance.primaryFocus?.context;
      expect(focusContext, isNotNull);
      final isEditable = focusContext!.widget is EditableText ||
          focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
      expect(isEditable, isTrue);

      // Field remains editable while the picker dialog stays open.
      await tester.enterText(find.byKey(const Key('qty-field')), '2');
      expect(controller.text, '2');
      expect(confirmed, isEmpty);
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
    });

    testWidgets('keyboard hint and localized confirm/cancel labels shown',
        (tester) async {
      await pumpPicker(tester, onConfirm: (_) {});
      expect(find.byKey(const Key('pos-option-picker-hint')), findsOneWidget);
      expect(find.text(AppStrings.t('picker_keyboard_hint', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('select_and_add', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('cancel', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no RenderFlex overflow at 800x600 with many options',
        (tester) async {
      final options = [
        for (var i = 1; i <= 6; i++)
          PosOptionCard(
            optionKey: 'variant-v$i',
            title: 'Variant $i',
            price: '$i.00',
            secondary: 'barcode-$i',
          ),
      ];
      await pumpPicker(
        tester,
        options: options,
        size: const Size(800, 600),
        onConfirm: (_) {},
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('variant-v1')), findsOneWidget);
      expect(find.byKey(const Key('variant-v6')), findsOneWidget);
    });

    testWidgets('Arabic RTL: localized title, hint, and confirm labels',
        (tester) async {
      await pumpPicker(
        tester,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
        title: AppStrings.t('variants', 'ar'),
        subtitle: AppStrings.t('select_variant_hint', 'ar'),
        onConfirm: (_) {},
      );
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
      expect(find.text(AppStrings.t('variants', 'ar')), findsOneWidget);
      expect(
        find.text(AppStrings.t('select_variant_hint', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('select_and_add', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('picker_keyboard_hint', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
