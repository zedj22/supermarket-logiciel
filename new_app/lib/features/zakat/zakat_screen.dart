// Zakat al-Tijarah screen — calculator + saved history.
//
// RBAC: `report_financial` to view (same scope as the backend; § — no new
// permission was introduced). The shell provides the Scaffold/AppBar —
// this is content only.
//
// The calculator is a TRANSPARENT calculation aid: it posts the entered
// figures to the server, which runs the official formula
// (2.5 % via `(amount × 2.5) / 100`, nisab from the entered gold price
// or a manual override) and returns the result + warnings. Nothing here
// touches sales, inventory or accounting, and no money math happens on
// the client.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../core/widgets/page_title.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/customer_models.dart';
import 'zakat_error.dart';
import 'zakat_models.dart';
import 'zakat_pdf.dart';
import 'zakat_providers.dart';
import 'zakat_widgets.dart';

const List<String> _kInventoryBases = <String>['market', 'cost', 'override'];
const List<String> _kDebtTreatments = <String>[
  'deduct_all',
  'deduct_due_only',
  'no_deduction',
];
const List<String> _kPaymentMethods = <String>[
  'cash',
  'transfer',
  'cheque',
  'other',
];

class ZakatScreen extends ConsumerStatefulWidget {
  const ZakatScreen({super.key});

  @override
  ConsumerState<ZakatScreen> createState() => _ZakatScreenState();
}

class _ZakatScreenState extends ConsumerState<ZakatScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  // -- form controllers ----------------------------------------------------
  late final TextEditingController _zakatDate;
  late final TextEditingController _hawlStart;
  late final TextEditingController _goldPrice;
  late final TextEditingController _nisabOverride;
  late final TextEditingController _overrideValue;
  late final TextEditingController _overrideReason;
  late final TextEditingController _collectible;
  late final TextEditingController _doubtful;
  late final TextEditingController _notes;

  String _inventoryBasis = 'market';
  bool _useImported = true;
  bool _cashProvided = false;
  String _debtTreatment = 'deduct_all';

  final List<ZakatEditableLine> _cashLines = <ZakatEditableLine>[];
  final List<ZakatEditableLine> _otherLines = <ZakatEditableLine>[];
  final List<ZakatEditableLine> _liabilityLines = <ZakatEditableLine>[];

  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _zakatDate = TextEditingController();
    _hawlStart = TextEditingController();
    _goldPrice = TextEditingController();
    _nisabOverride = TextEditingController();
    _overrideValue = TextEditingController();
    _overrideReason = TextEditingController();
    _collectible = TextEditingController();
    _doubtful = TextEditingController();
    _notes = TextEditingController();
    // Seed defaults from the context once it lands (today's date, the
    // server-side defaults) — never invents money figures. The first
    // post-frame callback also fires the initial context fetch. The
    // provider listener is registered in build (ref.listen is build-only).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zakatContextProvider.notifier).load();
      _seedFromContext();
    });
  }

  void _seedFromContext() {
    final data = ref.read(zakatContextProvider).data;
    if (data == null || _seeded) return;
    _seeded = true;
    setState(() {
      _zakatDate.text = data.today;
      _inventoryBasis = data.defaults.inventoryBasis;
      _debtTreatment = data.defaults.debtTreatment;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _zakatDate.dispose();
    _hawlStart.dispose();
    _goldPrice.dispose();
    _nisabOverride.dispose();
    _overrideValue.dispose();
    _overrideReason.dispose();
    _collectible.dispose();
    _doubtful.dispose();
    _notes.dispose();
    _disposeLines(_cashLines);
    _disposeLines(_otherLines);
    _disposeLines(_liabilityLines);
    super.dispose();
  }

  static void _disposeLines(List<ZakatEditableLine> lines) {
    for (final l in lines) {
      l.label.dispose();
      l.amount.dispose();
      l.due?.dispose();
    }
  }

  void _addLine(List<ZakatEditableLine> list, {bool due = false}) {
    setState(() {
      list.add(
        ZakatEditableLine(
          label: TextEditingController(),
          amount: TextEditingController(),
          due: due ? ValueNotifier<bool?>(null) : null,
        ),
      );
    });
  }

  void _removeLine(List<ZakatEditableLine> list, int index) {
    setState(() {
      list[index].label.dispose();
      list[index].amount.dispose();
      list[index].due?.dispose();
      list.removeAt(index);
    });
  }

  List<ZakatLineInput> _wireLines(
    List<ZakatEditableLine> editable, {
    bool withDue = false,
  }) {
    final out = <ZakatLineInput>[];
    for (final line in editable) {
      final label = line.label.text.trim();
      final amount = ZakatMoneyField.wireValue(line.amount);
      if (label.isEmpty || amount == null) continue;
      out.add(
        ZakatLineInput(
          label: label,
          amount: amount,
          due: withDue ? line.due?.value : null,
        ),
      );
    }
    return out;
  }

  /// Snapshot of the form as the wire payload (normalized money strings).
  ZakatCalculationInput _buildInput() {
    return ZakatCalculationInput(
      zakatDate: _zakatDate.text.trim(),
      hawlStartDate: _hawlStart.text.trim().isEmpty
          ? null
          : _hawlStart.text.trim(),
      goldPricePerGram: ZakatMoneyField.wireValue(_goldPrice),
      nisabOverride: ZakatMoneyField.wireValue(_nisabOverride),
      inventoryBasis: _inventoryBasis,
      inventoryOverrideValue: ZakatMoneyField.wireValue(_overrideValue),
      inventoryOverrideReason: _overrideReason.text.trim().isEmpty
          ? null
          : _overrideReason.text.trim(),
      useImportedInventory: _useImported,
      cashProvided: _cashProvided,
      cashItems: _wireLines(_cashLines),
      collectibleReceivables: ZakatMoneyField.wireValue(_collectible),
      doubtfulReceivables: ZakatMoneyField.wireValue(_doubtful),
      otherReceivableItems: _wireLines(_otherLines),
      debtTreatment: _debtTreatment,
      liabilityItems: _wireLines(_liabilityLines, withDue: true),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
  }

  Future<void> _calculate() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    // Nisab exclusivity + override rules live server-side, but a local
    // pre-check gives instant feedback without a round-trip.
    final hasGold = ZakatMoneyField.wireValue(_goldPrice) != null;
    final hasOverride = ZakatMoneyField.wireValue(_nisabOverride) != null;
    if (hasGold && hasOverride) {
      _toast(AppStrings.t('zakat_nisab_exclusive', loc), error: true);
      return;
    }
    if (_inventoryBasis == 'override' &&
        (ZakatMoneyField.wireValue(_overrideValue) == null ||
            _overrideReason.text.trim().isEmpty)) {
      _toast(AppStrings.t('zakat_override_incomplete', loc), error: true);
      return;
    }
    await ref.read(zakatFormProvider.notifier).calculate(_buildInput());
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final detail =
        await ref.read(zakatFormProvider.notifier).save(_buildInput());
    if (!mounted) return;
    if (detail != null) {
      _toast(AppStrings.t('zakat_save_done', loc));
      ref.read(zakatHistoryProvider.notifier).refresh();
    }
  }

  Future<void> _previewPdf() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final dio = ref.read(apiClientProvider).dio;
    await exportZakatPreviewPdf(
      context: context,
      dio: dio,
      loc: loc,
      input: _buildInput(),
    );
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('zakat-toast'),
        content: Text(message),
        backgroundColor:
            error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    // Re-seed whenever a fresh context response lands (build-scoped
    // listen — riverpod only allows ref.listen here).
    ref.listen(zakatContextProvider, (previous, next) => _seedFromContext());
    final canView = ref.watch(hasPermissionProvider('report_financial'));
    if (!canView) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PageTitle(
            title: AppStrings.t('zakat_title', loc),
            titleKey: const Key('zakat-title'),
          ),
          const SizedBox(height: 24),
          Center(
            key: const Key('zakat-denied'),
            child: Text(AppStrings.t('permission_denied', loc)),
          ),
        ],
      );
    }
    final contextState = ref.watch(zakatContextProvider);
    return ListView(
      key: const Key('zakat-screen'),
      padding: const EdgeInsets.all(16),
      children: [
        PageTitle(
          title: AppStrings.t('zakat_title', loc),
          titleKey: const Key('zakat-title'),
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('zakat-reload-context'),
                onPressed: contextState.loading
                    ? null
                    : () =>
                        ref.read(zakatContextProvider.notifier).load(),
                icon: const Icon(Icons.refresh),
                label: Text(AppStrings.t('refresh', loc)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              key: const Key('zakat-tab-calculator'),
              text: AppStrings.t('zakat_tab_calculator', loc),
            ),
            Tab(
              key: const Key('zakat-tab-history'),
              text: AppStrings.t('zakat_tab_history', loc),
            ),
          ],
        ),
        SizedBox(
          // ~620px keeps both tab bodies readable without a nested scroll.
          height: MediaQuery.sizeOf(context).height - 220,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildCalculator(contextState, loc),
              const _ZakatHistoryPane(),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Calculator tab
  // -------------------------------------------------------------------------

  Widget _buildCalculator(ZakatContextState contextState, String loc) {
    final form = ref.watch(zakatFormProvider);
    if (contextState.data == null && contextState.error != null) {
      return Center(
        key: const Key('zakat-context-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(contextState.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('zakat-context-retry'),
              onPressed: () => ref.read(zakatContextProvider.notifier).load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.only(top: 12, bottom: 24),
      child: KeyedSubtree(
        // Remount once the server defaults land so the seeded dropdown
        // values are picked up by `initialValue`.
        key: ValueKey<bool>(_seeded),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (contextState.data != null)
                _officialReferenceBanner(contextState.data!, loc),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumns = constraints.maxWidth >= 980 &&
                      constraints.maxWidth.isFinite;
                  final cardWidth = twoColumns
                      ? (constraints.maxWidth - 16) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      SizedBox(
                        width: cardWidth,
                        child: _datesCard(contextState, loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _nisabCard(contextState, loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _inventoryCard(contextState, loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _cashCard(loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _receivablesCard(contextState, loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _liabilitiesCard(contextState, loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _notesCard(loc),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: _actionsCard(form, loc),
                      ),
                      if (form.result != null)
                        SizedBox(
                          width:
                              twoColumns ? constraints.maxWidth : cardWidth,
                          child: _resultCard(form.result!, loc),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _officialReferenceBanner(ZakatContext data, String loc) {
    final ref0 = data.officialNisabReference;
    final theme = Theme.of(context);
    return Card(
      key: const Key('zakat-official-reference'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('zakat_official_nisab', loc),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            // Bidi: Arabic labels/notes stay natural; the grouped money
            // and the "(year, purity)" numeric group are LTR isolates
            // (a forced-LTR whole-string still reverses grouped digits
            // after an Arabic label — W7).
            Text(
              '${AppStrings.t('zakat_nisab', loc)}: '
              '${bidiIsolateLtr(
                '${zakatMoneyLabel(ref0.amount)} ${AppStrings.t('currency', loc)}',
              )}'
              ' — ${AppStrings.t('zakat_official_nisab_note', loc)} '
              '${bidiIsolateLtr('(${ref0.hijriYear}, ${ref0.purity})')}',
              key: const Key('zakat-official-nisab-line'),
              style: theme.textTheme.bodySmall,
            ),
            if (ref0.source.isNotEmpty)
              Text(
                ref0.source,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _datesCard(ZakatContextState contextState, String loc) {
    return ZakatSectionCard(
      testKey: const Key('zakat-section-dates'),
      title: AppStrings.t('zakat_section_dates', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZakatDateField(
            controller: _zakatDate,
            labelKey: 'zakat_calculation_date',
            required: true,
            testKey: const Key('zakat-field-date'),
          ),
          const SizedBox(height: 12),
          ZakatDateField(
            controller: _hawlStart,
            labelKey: 'zakat_hawl_start',
            testKey: const Key('zakat-field-hawl'),
          ),
          if (contextState.data != null) ...[
            const SizedBox(height: 8),
            Text(
              '${AppStrings.t('zakat_hawl', loc)}: '
              '${contextState.data!.defaults.hawlDays} '
              '${AppStrings.t('zakat_days', loc)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _nisabCard(ZakatContextState contextState, String loc) {
    final official = contextState.data?.officialNisabReference;
    return ZakatSectionCard(
      testKey: const Key('zakat-section-nisab'),
      title: AppStrings.t('zakat_nisab', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppStrings.t('zakat_nisab_hint', loc),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ZakatMoneyField(
                  controller: _goldPrice,
                  labelKey: 'zakat_gold_price',
                  testKey: const Key('zakat-field-gold-price'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('zakat-use-official-gold'),
                tooltip: AppStrings.t('zakat_use_official_reference', loc),
                onPressed: official == null
                    ? null
                    : () => setState(
                          // Plain (ungrouped): editable field, re-parsed by
                          // moneyToMilli before it reaches the wire.
                          () => _goldPrice.text = formatMoneyPlain(
                            official.goldPricePerGram,
                          ),
                        ),
                icon: const Icon(Icons.auto_awesome_outlined),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ZakatMoneyField(
            controller: _nisabOverride,
            labelKey: 'zakat_nisab_override',
            testKey: const Key('zakat-field-nisab-override'),
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.t('zakat_nisab_exclusive', loc),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _inventoryCard(ZakatContextState contextState, String loc) {
    final inventory = contextState.data?.inventory;
    return ZakatSectionCard(
      testKey: const Key('zakat-section-inventory'),
      title: AppStrings.t('zakat_inventory_basis', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('zakat-field-basis'),
            initialValue: _inventoryBasis,
            decoration: InputDecoration(
              labelText: AppStrings.t('zakat_inventory_basis', loc),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final basis in _kInventoryBases)
                DropdownMenuItem<String>(
                  value: basis,
                  child: Text(AppStrings.t(zakatBasisKey(basis), loc)),
                ),
            ],
            onChanged: (v) =>
                setState(() => _inventoryBasis = v ?? 'market'),
          ),
          CheckboxListTile(
            key: const Key('zakat-field-use-imported'),
            contentPadding: EdgeInsets.zero,
            value: _useImported,
            title: Text(AppStrings.t('zakat_use_imported', loc)),
            onChanged: _inventoryBasis == 'override'
                ? null
                : (v) => setState(() => _useImported = v ?? true),
          ),
          if (inventory != null)
            // Bidi: Arabic label natural; the product count and the
            // grouped money are LTR isolates (W7).
            Text(
              '${AppStrings.t('zakat_imported_summary', loc)}: '
              '${bidiIsolateLtr('${inventory.productCount}')} — '
              '${bidiIsolateLtr(
                '${zakatMoneyLabel(inventory.totalMarketValue)} '
                '${AppStrings.t('currency', loc)}',
              )}',
              key: const Key('zakat-imported-summary'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_inventoryBasis == 'override') ...[
            const SizedBox(height: 12),
            ZakatMoneyField(
              controller: _overrideValue,
              labelKey: 'zakat_override_value',
              required: true,
              testKey: const Key('zakat-field-override-value'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('zakat-field-override-reason'),
              controller: _overrideReason,
              maxLength: 255,
              decoration: InputDecoration(
                labelText: AppStrings.t('zakat_override_reason', loc),
                border: const OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cashCard(String loc) {
    return ZakatSectionCard(
      testKey: const Key('zakat-section-cash'),
      title: AppStrings.t('zakat_row_cash', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const Key('zakat-field-cash-provided'),
            contentPadding: EdgeInsets.zero,
            value: _cashProvided,
            title: Text(AppStrings.t('zakat_cash_provided', loc)),
            onChanged: (v) => setState(() => _cashProvided = v ?? false),
          ),
          if (_cashProvided)
            ZakatLineItemsEditor(
              testKey: const Key('zakat-cash-lines'),
              lines: _cashLines,
              addLabelKey: 'zakat_add_cash_line',
              onAdd: () => _addLine(_cashLines),
              onRemove: (i) => _removeLine(_cashLines, i),
            ),
        ],
      ),
    );
  }

  Widget _receivablesCard(ZakatContextState contextState, String loc) {
    final ledger = contextState.data?.receivablesReference;
    return ZakatSectionCard(
      testKey: const Key('zakat-section-receivables'),
      title: AppStrings.t('zakat_row_collectible', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ledger != null)
            // Bidi: Arabic label natural; grouped money + currency and
            // the "(n)" count are LTR isolates (W7).
            Text(
              '${AppStrings.t('zakat_ledger_total', loc)}: '
              '${bidiIsolateLtr(
                '${zakatMoneyLabel(ledger.ledgerTotal)} '
                '${AppStrings.t('currency', loc)}',
              )} '
              '${bidiIsolateLtr('(${ledger.debtorCount})')}',
              key: const Key('zakat-ledger-total'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          ZakatMoneyField(
            controller: _collectible,
            labelKey: 'zakat_row_collectible',
            required: true,
            testKey: const Key('zakat-field-collectible'),
          ),
          const SizedBox(height: 12),
          ZakatMoneyField(
            controller: _doubtful,
            labelKey: 'zakat_doubtful_receivables',
            testKey: const Key('zakat-field-doubtful'),
          ),
          Text(
            AppStrings.t('zakat_warn_doubtful_excluded', loc),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ZakatLineItemsEditor(
            testKey: const Key('zakat-other-receivable-lines'),
            lines: _otherLines,
            addLabelKey: 'zakat_add_receivable_line',
            onAdd: () => _addLine(_otherLines),
            onRemove: (i) => _removeLine(_otherLines, i),
          ),
        ],
      ),
    );
  }

  Widget _liabilitiesCard(ZakatContextState contextState, String loc) {
    final ap = contextState.data?.liabilitiesReference;
    return ZakatSectionCard(
      testKey: const Key('zakat-section-liabilities'),
      title: AppStrings.t('zakat_debt_treatment', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('zakat-field-debt-treatment'),
            initialValue: _debtTreatment,
            decoration: InputDecoration(
              labelText: AppStrings.t('zakat_debt_treatment', loc),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final method in _kDebtTreatments)
                DropdownMenuItem<String>(
                  value: method,
                  child: Text(AppStrings.t(zakatMethodKey(method), loc)),
                ),
            ],
            onChanged: (v) =>
                setState(() => _debtTreatment = v ?? 'deduct_all'),
          ),
          if (ap != null) ...[
            const SizedBox(height: 8),
            // Bidi: Arabic label natural; grouped money + currency and
            // the "(n)" count are LTR isolates (W7).
            Text(
              '${AppStrings.t('zakat_supplier_total', loc)}: '
              '${bidiIsolateLtr(
                '${zakatMoneyLabel(ap.supplierBalanceTotal)} '
                '${AppStrings.t('currency', loc)}',
              )} '
              '${bidiIsolateLtr('(${ap.supplierCount})')}',
              key: const Key('zakat-supplier-total'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          ZakatLineItemsEditor(
            testKey: const Key('zakat-liability-lines'),
            lines: _liabilityLines,
            addLabelKey: 'zakat_add_liability_line',
            onAdd: () => _addLine(_liabilityLines, due: true),
            onRemove: (i) => _removeLine(_liabilityLines, i),
            showDue: true,
          ),
        ],
      ),
    );
  }

  Widget _notesCard(String loc) {
    return ZakatSectionCard(
      testKey: const Key('zakat-section-notes'),
      title: AppStrings.t('notes', loc),
      child: TextFormField(
        key: const Key('zakat-field-notes'),
        controller: _notes,
        maxLength: 500,
        maxLines: 2,
        decoration: InputDecoration(
          labelText: AppStrings.t('notes', loc),
          border: const OutlineInputBorder(),
          counterText: '',
        ),
      ),
    );
  }

  Widget _actionsCard(ZakatFormState form, String loc) {
    return ZakatSectionCard(
      testKey: const Key('zakat-section-actions'),
      title: AppStrings.t('zakat_actions', loc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (form.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                form.error!,
                key: const Key('zakat-form-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('zakat-calculate'),
                onPressed: form.busy || form.saving ? null : _calculate,
                icon: form.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.calculate_outlined),
                label: Text(AppStrings.t('zakat_calculate', loc)),
              ),
              OutlinedButton.icon(
                key: const Key('zakat-save'),
                onPressed: form.busy || form.saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(AppStrings.t('zakat_save', loc)),
              ),
              OutlinedButton.icon(
                key: const Key('zakat-pdf'),
                onPressed: form.busy || form.saving ? null : _previewPdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(AppStrings.t('zakat_pdf', loc)),
              ),
              TextButton(
                key: const Key('zakat-reset'),
                onPressed: form.busy || form.saving
                    ? null
                    : () {
                        _formKey.currentState?.reset();
                        ref.read(zakatFormProvider.notifier).clearResult();
                        setState(() {
                          _seeded = false;
                          _zakatDate.clear();
                          _hawlStart.clear();
                          _goldPrice.clear();
                          _nisabOverride.clear();
                          _overrideValue.clear();
                          _overrideReason.clear();
                          _collectible.clear();
                          _doubtful.clear();
                          _notes.clear();
                          _cashProvided = false;
                          _useImported = true;
                          _inventoryBasis = 'market';
                          _debtTreatment = 'deduct_all';
                          _disposeLines(_cashLines);
                          _disposeLines(_otherLines);
                          _disposeLines(_liabilityLines);
                          _cashLines.clear();
                          _otherLines.clear();
                          _liabilityLines.clear();
                        });
                        _seedFromContext();
                      },
                child: Text(AppStrings.t('reset', loc)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultCard(ZakatCalculateResponse result, String loc) {
    final r = result.result;
    final theme = Theme.of(context);
    return ZakatSectionCard(
      testKey: const Key('zakat-result'),
      title: AppStrings.t('zakat_section_result', loc),
      actions: [ZakatStatusChip(status: r.status, testKey: const Key('zakat-result-status'))],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZakatResultRow(
            labelKey: 'zakat_net_zakatable',
            value:
                '${zakatMoneyLabel(r.netZakatable)} ${AppStrings.t('currency', loc)}',
            emphasized: true,
            testKey: const Key('zakat-result-net'),
          ),
          ZakatResultRow(
            labelKey: r.isProvisional
                ? 'zakat_provisional_due'
                : 'zakat_due_amount',
            value:
                '${zakatMoneyLabel(r.zakatDue ?? r.provisionalZakatDue)} '
                '${AppStrings.t('currency', loc)}',
            emphasized: true,
            testKey: const Key('zakat-result-due'),
          ),
          ZakatResultRow(
            labelKey: 'zakat_nisab',
            value:
                '${zakatMoneyLabel(r.nisabAmount)} '
                '(${AppStrings.t(zakatNisabSourceKey(r.nisabSource), loc)})',
            testKey: const Key('zakat-result-nisab'),
          ),
          ZakatResultRow(
            labelKey: 'zakat_hawl',
            value: r.hawlCompleted == null
                ? AppStrings.t('zakat_unknown', loc)
                : '${zakatBoolLabel(r.hawlCompleted, loc)}'
                    ' (${r.hawlDaysElapsed ?? 0} ${AppStrings.t('zakat_days', loc)})',
            testKey: const Key('zakat-result-hawl'),
          ),
          ZakatResultRow(
            labelKey: 'zakat_rate',
            value: '${AppStrings.t('zakat_rate_note', loc)} '
                '(${r.zakatRate})',
          ),
          const Divider(),
          ZakatResultRow(
            labelKey: 'zakat_row_inventory',
            value:
                '${zakatMoneyLabel(r.inventoryValue)} '
                '(${AppStrings.t(zakatBasisKey(r.inventoryBasis), loc)})',
          ),
          ZakatResultRow(
            labelKey: 'zakat_row_cash',
            value: r.cashProvided
                ? zakatMoneyLabel(r.cashTotal)
                : AppStrings.t('zakat_unknown', loc),
          ),
          ZakatResultRow(
            labelKey: 'zakat_row_collectible',
            value: zakatMoneyLabel(
              r.collectibleReceivables ?? r.receivablesIncludedTotal,
            ),
          ),
          ZakatResultRow(
            labelKey: 'zakat_total_deducted',
            value: zakatMoneyLabel(r.deductionsApplied),
          ),
          if (r.eligibilityReasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final reason in r.eligibilityReasons)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      AppStrings.t(zakatEligibilityKey(reason), loc),
                    ),
                  ),
              ],
            ),
          ],
          if (r.missingFields.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final field in r.missingFields)
                  Chip(
                    key: Key('zakat-missing-$field'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.errorContainer,
                    label: Text(
                      AppStrings.t(zakatMissingFieldKey(field), loc),
                    ),
                  ),
              ],
            ),
          ],
          if (r.warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              AppStrings.t('zakat_warnings', loc),
              style: theme.textTheme.titleSmall,
            ),
            for (final warning in r.warnings)
              ZakatWarningTile(
                warning: warning,
                testKey: Key('zakat-warn-${warning.code.toLowerCase()}'),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            AppStrings.t('zakat_disclaimer', loc),
            key: const Key('zakat-disclaimer'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// History tab
// ---------------------------------------------------------------------------

/// Saved-calculation history: loads page 1 on mount, appends via
/// "load more", opens the snapshot detail dialog and exports PDFs.
class _ZakatHistoryPane extends ConsumerStatefulWidget {
  const _ZakatHistoryPane();

  @override
  ConsumerState<_ZakatHistoryPane> createState() => _ZakatHistoryPaneState();
}

class _ZakatHistoryPaneState extends ConsumerState<_ZakatHistoryPane> {
  @override
  void initState() {
    super.initState();
    // First mount of the tab triggers the initial page load.
    Future.microtask(
      () => ref.read(zakatHistoryProvider.notifier).load(refresh: true),
    );
  }

  Future<void> _openDetail(String calculationId, String loc) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: const Key('zakat-detail-dialog'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: ZakatDetailPane(
            calculationId: calculationId,
            loc: loc,
            onPaymentRecorded: () => ref
                .read(zakatDetailProvider(calculationId).notifier)
                .load(calculationId),
          ),
        ),
      ),
    );
    if (mounted) ref.read(zakatHistoryProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final history = ref.watch(zakatHistoryProvider);
    if (history.items.isEmpty && history.loading) {
      return const Center(
        key: Key('zakat-history-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (history.items.isEmpty && history.error != null) {
      return Center(
        key: const Key('zakat-history-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(history.error!),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('zakat-history-retry'),
              onPressed: () =>
                  ref.read(zakatHistoryProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    return Column(
      key: const Key('zakat-history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${AppStrings.t('zakat_history_count', loc)}: '
                  '${history.total}',
                  key: const Key('zakat-history-total'),
                ),
              ),
              IconButton(
                key: const Key('zakat-history-refresh'),
                onPressed: () =>
                    ref.read(zakatHistoryProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
                tooltip: AppStrings.t('refresh', loc),
              ),
            ],
          ),
        ),
        ZakatHistoryHeader(testKey: const Key('zakat-history-header')),
        Expanded(
          child: history.items.isEmpty
              ? Center(
                  key: const Key('zakat-history-empty'),
                  child: Text(AppStrings.t('state_no_data', loc)),
                )
              : ListView.builder(
                  itemCount:
                      history.items.length + (history.hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= history.items.length) {
                      return Center(
                        child: TextButton(
                          key: const Key('zakat-history-more'),
                          onPressed: history.loadingMore
                              ? null
                              : () => ref
                                  .read(zakatHistoryProvider.notifier)
                                  .loadMore(),
                          child: Text(AppStrings.t('zakat_load_more', loc)),
                        ),
                      );
                    }
                    final item = history.items[index];
                    return ZakatHistoryRow(
                      testKey: Key('zakat-history-row-$index'),
                      item: item,
                      onOpen: () => _openDetail(item.id, loc),
                      onPdf: () async {
                        final dio = ref.read(apiClientProvider).dio;
                        await exportZakatDetailPdf(
                          context: context,
                          dio: dio,
                          loc: loc,
                          calculationId: item.id,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Detail pane (dialog body)
// ---------------------------------------------------------------------------

/// Full snapshot view: summary numbers, result breakdown, payments list,
/// and the payment + PDF actions.
class ZakatDetailPane extends ConsumerStatefulWidget {
  const ZakatDetailPane({
    super.key,
    required this.calculationId,
    required this.loc,
    required this.onPaymentRecorded,
  });

  final String calculationId;
  final String loc;
  final VoidCallback onPaymentRecorded;

  @override
  ConsumerState<ZakatDetailPane> createState() => _ZakatDetailPaneState();
}

class _ZakatDetailPaneState extends ConsumerState<ZakatDetailPane> {
  bool _paying = false;

  @override
  void initState() {
    super.initState();
    // Fetch the snapshot on first mount (the family notifier is created
    // lazily, so this is the only trigger).
    Future.microtask(
      () => ref.read(zakatDetailProvider(widget.calculationId).notifier).load(
            widget.calculationId,
          ),
    );
  }

  Future<void> _recordPayment() async {
    final amount = await showDialog<_PaymentDraft>(
      context: context,
      builder: (_) => _PaymentDialog(loc: widget.loc),
    );
    if (amount == null || !mounted) return;
    setState(() => _paying = true);
    final loc = widget.loc;
    final dio = ref.read(apiClientProvider).dio;
    try {
      await dio.post(
        '$kZakatPath/${widget.calculationId}/payment',
        data: <String, dynamic>{
          'client_request_id': zakatClientRequestId(),
          'amount': amount.amount,
          'method': amount.method,
          if (amount.paidAt != null && amount.paidAt!.isNotEmpty)
            'paid_at': amount.paidAt,
          if (amount.note != null && amount.note!.trim().isNotEmpty)
            'note': amount.note!.trim(),
        },
      );
      widget.onPaymentRecorded();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('zakat-payment-toast'),
            content: Text(AppStrings.t('zakat_payment_done', loc)),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('zakat-payment-toast'),
            content: Text(zakatApiMessage(e, loc)),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    final theme = Theme.of(context);
    final state = ref.watch(zakatDetailProvider(widget.calculationId));
    final current = state.data;
    if (current == null && state.error == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (current == null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(state.error!)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${AppStrings.t('zakat_detail_title', loc)} — '
                  '${current.zakatDate}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              ZakatStatusChip(status: current.status),
              IconButton(
                key: const Key('zakat-detail-close'),
                icon: const Icon(Icons.close),
                tooltip: AppStrings.t('close', loc),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ZakatResultRow(
                    labelKey: 'zakat_net_zakatable',
                    value:
                        '${zakatMoneyLabel(current.netZakatable)} '
                        '${AppStrings.t('currency', loc)}',
                    emphasized: true,
                  ),
                  ZakatResultRow(
                    labelKey: 'zakat_due_amount',
                    value:
                        '${zakatMoneyLabel(current.zakatDue ?? current.provisionalZakatDue)} '
                        '${AppStrings.t('currency', loc)}',
                    emphasized: true,
                  ),
                  ZakatResultRow(
                    labelKey: 'zakat_payments_total',
                    value: zakatMoneyLabel(current.paymentsTotal),
                  ),
                  if (current.notes != null && current.notes!.isNotEmpty)
                    ZakatResultRow(
                      labelKey: 'notes',
                      value: current.notes!,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.t('zakat_payments_section', loc),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (current.payments.isEmpty)
                    Text(
                      AppStrings.t('zakat_no_payments', loc),
                      key: const Key('zakat-no-payments'),
                    )
                  else
                    for (final payment in current.payments)
                      ZakatResultRow(
                        labelKey: 'zakat_payment_row',
                        // Bidi: the "(paid at)" timestamp group is one LTR
                        // isolate (its date/time groups would otherwise
                        // swap after the Arabic method label — W7).
                        value:
                            '${zakatMoneyLabel(payment.amount)} '
                            '${AppStrings.t('currency', loc)} — '
                            '${AppStrings.t(zakatPaymentMethodKey(payment.method), loc)} '
                            '${bidiIsolateLtr('(${payment.paidAt})')}',
                        testKey: Key('zakat-payment-${payment.id}'),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('zakat-payment-button'),
                onPressed: _paying ? null : _recordPayment,
                icon: const Icon(Icons.payments_outlined),
                label: Text(AppStrings.t('zakat_payment_title', loc)),
              ),
              OutlinedButton.icon(
                key: const Key('zakat-detail-pdf'),
                onPressed: () async {
                  final dio = ref.read(apiClientProvider).dio;
                  if (!context.mounted) return;
                  await exportZakatDetailPdf(
                    context: context,
                    dio: dio,
                    loc: loc,
                    calculationId: widget.calculationId,
                  );
                },
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(AppStrings.t('zakat_pdf', loc)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

@immutable
class _PaymentDraft {
  const _PaymentDraft({
    required this.amount,
    required this.method,
    this.paidAt,
    this.note,
  });

  final String amount;
  final String method;
  final String? paidAt;
  final String? note;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.loc});

  final String loc;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _paidAt = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String _method = 'cash';

  @override
  void dispose() {
    _amount.dispose();
    _paidAt.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    return AlertDialog(
      key: const Key('zakat-payment-dialog'),
      title: Text(AppStrings.t('zakat_payment_title', loc)),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZakatMoneyField(
                controller: _amount,
                labelKey: 'zakat_col_amount',
                required: true,
                testKey: const Key('zakat-payment-amount'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('zakat-payment-method'),
                initialValue: _method,
                decoration: InputDecoration(
                  labelText: AppStrings.t('zakat_payment_method', loc),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final method in _kPaymentMethods)
                    DropdownMenuItem<String>(
                      value: method,
                      child: Text(
                        AppStrings.t(zakatPaymentMethodKey(method), loc),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _method = v ?? 'cash'),
              ),
              const SizedBox(height: 12),
              ZakatDateField(
                controller: _paidAt,
                labelKey: 'zakat_payment_paid_at',
                testKey: const Key('zakat-payment-date'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('zakat-payment-note'),
                controller: _note,
                maxLength: 255,
                decoration: InputDecoration(
                  labelText: AppStrings.t('zakat_col_note', loc),
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('zakat-payment-cancel'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('zakat-payment-submit'),
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            final wire = ZakatMoneyField.wireValue(_amount);
            if (wire == null) return;
            Navigator.of(context).pop(
              _PaymentDraft(
                amount: wire,
                method: _method,
                paidAt: _paidAt.text.trim().isEmpty
                    ? null
                    : _paidAt.text.trim(),
                note: _note.text,
              ),
            );
          },
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
