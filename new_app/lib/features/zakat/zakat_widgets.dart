// Shared building blocks for the Zakat screen.
//
// No money math anywhere: every figure is a raw server string run through
// `formatMoney` (trailing-zero trim only). Input fields validate with
// `moneyToMilli` (reject, never round) and hand the NORMALIZED string
// (`milliToMoney`) to the providers — the server is the only place the
// formula runs.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../core/widgets/table_header.dart';
import '../../theme/app_theme.dart';
import '../clients/customer_models.dart';
import 'zakat_models.dart';

/// `120.500` → `120.5`; `null` → `—`.
String zakatMoneyLabel(String? raw) =>
    raw == null || raw.isEmpty ? '—' : formatMoney(raw);

/// Derives a child key from a parent [testKey], e.g.
/// `zakatSubKey(Key('zakat-history-row-0'), 'open')` →
/// `Key('zakat-history-row-0-open')`. Strips the `[<...>]` wrapper that
/// [Key.toString] adds so the value is a clean, predictable string.
Key zakatSubKey(Key parent, String suffix) {
  final raw = parent is ValueKey ? parent.value.toString() : '$parent';
  return Key('$raw-$suffix');
}

/// Localized yes/no/unknown for the tri-state booleans of the result.
String zakatBoolLabel(bool? value, String loc) {
  if (value == null) return AppStrings.t('zakat_unknown', loc);
  return AppStrings.t(value ? 'zakat_yes' : 'zakat_no', loc);
}

// ---------------------------------------------------------------------------
// Section card
// ---------------------------------------------------------------------------

/// One titled form/result section; the calculator lays several of these
/// out in a responsive [Wrap].
class ZakatSectionCard extends StatelessWidget {
  const ZakatSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.testKey,
    this.actions,
  });

  final String title;
  final Widget child;
  final Key? testKey;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: testKey,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    key: testKey == null
                        ? null
                        : zakatSubKey(testKey!, 'title'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                ...?actions,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Money input
// ---------------------------------------------------------------------------

/// Money text field with house-rule validation: digits + up to 3 decimals,
/// empty allowed unless [required]. Never rounds — invalid input shows a
/// localized error instead.
class ZakatMoneyField extends StatelessWidget {
  const ZakatMoneyField({
    super.key,
    required this.controller,
    required this.labelKey,
    this.required = false,
    this.enabled = true,
    this.testKey,
    this.helperKey,
  });

  final TextEditingController controller;
  final String labelKey;
  final bool required;
  final bool enabled;
  final Key? testKey;
  final String? helperKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return TextFormField(
      key: testKey,
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: AppStrings.t(labelKey, loc),
        helperText: helperKey == null ? null : AppStrings.t(helperKey!, loc),
        border: const OutlineInputBorder(),
      ),
      validator: (value) {
        final raw = (value ?? '').trim();
        if (raw.isEmpty) {
          return required ? AppStrings.t('field_required', loc) : null;
        }
        if (moneyToMilli(raw) == null) {
          return AppStrings.t('zakat_invalid_amount', loc);
        }
        return null;
      },
    );
  }

  /// Normalized wire value (`120,5` → `120.500`); empty → null.
  static String? wireValue(TextEditingController controller) {
    final raw = controller.text.trim();
    if (raw.isEmpty) return null;
    final milli = moneyToMilli(raw);
    if (milli == null) return raw; // server-side validation will answer
    return milliToMoney(milli);
  }
}

// ---------------------------------------------------------------------------
// Date input
// ---------------------------------------------------------------------------

/// Date field with a picker button; the wire format is ISO `yyyy-MM-dd`.
class ZakatDateField extends StatelessWidget {
  const ZakatDateField({
    super.key,
    required this.controller,
    required this.labelKey,
    this.required = false,
    this.firstDate,
    this.testKey,
  });

  final TextEditingController controller;
  final String labelKey;
  final bool required;
  final DateTime? firstDate;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return TextFormField(
      key: testKey,
      controller: controller,
      readOnly: true,
      decoration: InputDecoration(
        labelText: AppStrings.t(labelKey, loc),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          key: testKey == null ? null : zakatSubKey(testKey!, 'picker'),
          icon: const Icon(Icons.calendar_today_outlined),
          tooltip: AppStrings.t(labelKey, loc),
          onPressed: () async {
            final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: initial,
              firstDate: firstDate ?? DateTime(2020, 1, 1),
              lastDate: DateTime.now(),
            );
            if (picked == null || !context.mounted) return;
            controller.text =
                '${picked.year.toString().padLeft(4, '0')}-'
                '${picked.month.toString().padLeft(2, '0')}-'
                '${picked.day.toString().padLeft(2, '0')}';
          },
        ),
      ),
      validator: (value) {
        final raw = (value ?? '').trim();
        if (raw.isEmpty) {
          return required ? AppStrings.t('field_required', loc) : null;
        }
        if (DateTime.tryParse(raw) == null) {
          return AppStrings.t('validation_error', loc);
        }
        return null;
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Line-items editor (cash / receivables / liabilities)
// ---------------------------------------------------------------------------

@immutable
class ZakatEditableLine {
  const ZakatEditableLine({
    required this.label,
    required this.amount,
    this.due,
  });

  final TextEditingController label;
  final TextEditingController amount;

  /// Liabilities only — tri-state due toggle (null = unknown).
  final ValueNotifier<bool?>? due;
}

/// One editable line row: label + amount (+ optional due toggle).
class ZakatLineItemsEditor extends StatelessWidget {
  const ZakatLineItemsEditor({
    super.key,
    required this.lines,
    required this.addLabelKey,
    required this.onAdd,
    required this.onRemove,
    this.showDue = false,
    this.testKey,
    this.labelKey = 'zakat_col_item',
    this.amountKey = 'zakat_col_amount',
  });

  final List<ZakatEditableLine> lines;
  final String addLabelKey;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  final bool showDue;
  final Key? testKey;
  final String labelKey;
  final String amountKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return Column(
      key: testKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextFormField(
                  key: testKey == null ? null : zakatSubKey(testKey!, 'label-$i'),
                  controller: lines[i].label,
                  decoration: InputDecoration(
                    labelText: AppStrings.t(labelKey, loc),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  // A line whose label is blank would be silently dropped
                  // by the serializer (server requires min_length=1), so
                  // block submission here instead of losing the amount.
                  validator: (value) {
                    final raw = (value ?? '').trim();
                    return raw.isEmpty ? AppStrings.t('field_required', loc) : null;
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ZakatMoneyField(
                  controller: lines[i].amount,
                  labelKey: amountKey,
                  required: true,
                  testKey: testKey == null ? null : zakatSubKey(testKey!, 'amount-$i'),
                ),
              ),
              if (showDue) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: ValueListenableBuilder<bool?>(
                    valueListenable: lines[i].due!,
                    builder: (context, due, _) => DropdownButton<bool?>(
                      key: testKey == null
                          ? null
                          : zakatSubKey(testKey!, 'due-$i'),
                      value: due,
                      items: [
                        DropdownMenuItem<bool?>(
                          value: null,
                          child: Text(AppStrings.t('zakat_unknown', loc)),
                        ),
                        DropdownMenuItem<bool?>(
                          value: true,
                          child: Text(AppStrings.t('zakat_due_yes', loc)),
                        ),
                        DropdownMenuItem<bool?>(
                          value: false,
                          child: Text(AppStrings.t('zakat_due_no', loc)),
                        ),
                      ],
                      onChanged: lines[i].due == null
                          ? null
                          : (v) => lines[i].due!.value = v,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                key: testKey == null ? null : zakatSubKey(testKey!, 'remove-$i'),
                icon: const Icon(Icons.close),
                tooltip: AppStrings.t('zakat_remove_line', loc),
                onPressed: () => onRemove(i),
              ),
            ],
          ),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: testKey == null ? null : zakatSubKey(testKey!, 'add'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(AppStrings.t(addLabelKey, loc)),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Result panel
// ---------------------------------------------------------------------------

/// Warning row: localized message for the code + the server detail values.
class ZakatWarningTile extends StatelessWidget {
  const ZakatWarningTile({super.key, required this.warning, this.testKey});

  final ZakatWarning warning;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    // Bidi: each server detail value is its own LTR isolate so grouped
    // numeric runs never swap next to the Arabic warning label (W7).
    final detail = warning.detail.isEmpty
        ? ''
        : ' (${warning.detail.values.map(bidiIsolateLtr).join(', ')})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${AppStrings.t(warning.labelKey, loc)}$detail',
              key: testKey,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Key/value row of the result breakdown.
class ZakatResultRow extends StatelessWidget {
  const ZakatResultRow({
    super.key,
    required this.labelKey,
    required this.value,
    this.emphasized = false,
    this.testKey,
  });

  final String labelKey;
  final String value;
  final bool emphasized;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              AppStrings.t(labelKey, loc),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: emphasized ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: numericText(
              value,
              key: testKey,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status chip: final (green) / provisional (orange).
class ZakatStatusChip extends StatelessWidget {
  const ZakatStatusChip({super.key, required this.status, this.testKey});

  final String status;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final provisional = status == 'provisional';
    final color =
        provisional ? theme.colorScheme.tertiary : theme.colorScheme.primary;
    return Chip(
      key: testKey,
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withValues(alpha: 0.14),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      label: Text(
        AppStrings.t(zakatStatusKey(status), loc),
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History table
// ---------------------------------------------------------------------------

/// One row of the saved-calculation history.
class ZakatHistoryRow extends StatelessWidget {
  const ZakatHistoryRow({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onPdf,
    this.testKey,
  });

  final ZakatCalculationSummary item;
  final VoidCallback onOpen;
  final VoidCallback onPdf;
  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    return Container(
      key: testKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          _cell(context, flex: 2, child: Text(item.zakatDate)),
          _cell(
            context,
            flex: 2,
            child: ZakatStatusChip(
              status: item.status,
              testKey: testKey == null
                  ? null
                  : zakatSubKey(testKey!, 'status'),
            ),
          ),
          _cell(
            context,
            flex: 2,
            child: numericText(
              zakatMoneyLabel(item.netZakatable),
              key: testKey == null ? null : zakatSubKey(testKey!, 'net'),
            ),
          ),
          _cell(
            context,
            flex: 2,
            child: numericText(
              item.zakatDue ??
                  zakatMoneyLabel(item.provisionalZakatDue),
              key: testKey == null ? null : zakatSubKey(testKey!, 'due'),
            ),
          ),
          _cell(
            context,
            flex: 2,
            child: numericText(
              zakatMoneyLabel(item.paymentsTotal),
              key: testKey == null ? null : zakatSubKey(testKey!, 'payments'),
            ),
          ),
          SizedBox(
            width: 96,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: testKey == null ? null : zakatSubKey(testKey!, 'open'),
                  icon: const Icon(Icons.visibility_outlined),
                  tooltip: AppStrings.t('zakat_open_detail', loc),
                  onPressed: onOpen,
                ),
                IconButton(
                  key: testKey == null ? null : zakatSubKey(testKey!, 'pdf'),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  tooltip: AppStrings.t('zakat_pdf', loc),
                  onPressed: onPdf,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context, {
    required int flex,
    required Widget child,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: child,
      ),
    );
  }
}

/// Pinned column labels for the history table (sibling of the rows).
class ZakatHistoryHeader extends StatelessWidget {
  const ZakatHistoryHeader({super.key, this.testKey});

  final Key? testKey;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    Widget cell(int flex, String labelKey) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Text(
              AppStrings.t(labelKey, loc),
              style: AppTheme.tableHeader(Theme.of(context)),
            ),
          ),
        );
    return TableHeaderRow(
      testKey: testKey,
      children: [
        cell(2, 'zakat_calculation_date'),
        cell(2, 'zakat_col_status'),
        cell(2, 'zakat_col_net'),
        cell(2, 'zakat_due_amount'),
        cell(2, 'zakat_payments_total'),
        const SizedBox(width: 96),
      ],
    );
  }
}
