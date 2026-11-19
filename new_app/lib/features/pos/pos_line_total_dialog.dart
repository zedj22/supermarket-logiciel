// POS money-entry dialogs.
//
// Two cashier entries share this file because they follow the same rules:
//   * edit a cart line's TOTAL (double-click on the line total), and
//   * add a PRICE-ONLY custom item (no catalog product, no stock).
//
// Both parse with one funnel ([parsePosAmount]) and both hand back plain,
// ungrouped decimal text — the shape the cart fields and the sale payload
// use everywhere. Neither dialog computes totals: the cart line does that
// (CartLine.withManualTotal), so there is a single source of arithmetic.
import 'package:flutter/material.dart';

import '../../core/number_format.dart';
import '../../core/strings.dart';
import 'pos_models.dart';

/// Parses a typed monetary amount, tolerating the grouping/spacing the app
/// itself renders (`1 250,50` / `1,250.50`). Returns null when the text is
/// not a finite, non-negative number.
double? parsePosAmount(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  text = text.replaceAll(' ', '').replaceAll('\u00a0', '');
  // A lone decimal comma is a decimal point; commas used as thousands
  // separators disappear (they are always followed by exactly 3 digits).
  if (text.contains(',') && !text.contains('.')) {
    final parts = text.split(',');
    text = parts.length == 2 && parts[1].length <= 3
        ? '${parts[0]}.${parts[1]}'
        : text.replaceAll(',', '');
  } else {
    text = text.replaceAll(',', '');
  }
  final value = double.tryParse(text);
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// "Edit line total" — returns the new total as plain text, or null when the
/// cashier cancelled (the cart is then left exactly as it was).
///
/// The dialog never allows a total above the line's GROSS: the backend
/// expresses a manual total as a line discount and rejects a negative one,
/// so a "surcharge" is not representable and is refused here instead of
/// failing at checkout. A custom line is the exception — with quantity 1 its
/// unit price IS the total, so any positive amount is legitimate.
Future<String?> showLineTotalDialog(
  BuildContext context, {
  required CartLine line,
  required String loc,
}) {
  return showDialog<String>(
    context: context,
    // Explicit choice only: a stray click must never silently discard (or
    // apply) a cashier's amount.
    barrierDismissible: false,
    builder: (_) => _LineTotalDialog(line: line, loc: loc),
  );
}

class _LineTotalDialog extends StatefulWidget {
  const _LineTotalDialog({required this.line, required this.loc});

  final CartLine line;
  final String loc;

  @override
  State<_LineTotalDialog> createState() => _LineTotalDialogState();
}

class _LineTotalDialogState extends State<_LineTotalDialog> {
  late final TextEditingController _total = TextEditingController(
    text: posPlainAmount(widget.line.lineTotal),
  );
  String? _error;

  @override
  void dispose() {
    _total.dispose();
    super.dispose();
  }

  /// A custom line has no discount to give back (its price IS the total), so
  /// its ceiling is open; every other line can only be reduced.
  double? get _ceiling => widget.line.customLine ? null : widget.line.lineGross;

  void _submit() {
    final loc = widget.loc;
    final value = parsePosAmount(_total.text);
    if (value == null || value <= 0) {
      setState(
        () => _error = AppStrings.t('line_total_must_be_positive', loc),
      );
      return;
    }
    final ceiling = _ceiling;
    if (ceiling != null && value > ceiling + 0.0001) {
      setState(() => _error = AppStrings.t('line_total_above_gross', loc));
      return;
    }
    Navigator.of(context).pop(posPlainAmount(value));
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('line-total-dialog'),
      title: Text(AppStrings.t('edit_line_total', loc)),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${AppStrings.t('current_total', loc)}: '
                '${formatGroupedFixed(widget.line.lineTotal, 2)}',
                key: const Key('line-total-current'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('line-total-input'),
                controller: _total,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                // The app's monetary emphasis, from the central ramp — not
                // a one-off size.
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                decoration: InputDecoration(
                  labelText: AppStrings.t('new_total', loc),
                  errorText: _error,
                  errorMaxLines: 2,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('line-total-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('line-total-confirm'),
          onPressed: _submit,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}

/// "Add custom item" — a price-only line. Returns the name (already
/// defaulted to the localized "Unregistered item" when left empty) and the
/// price as plain text, or null on cancel.
Future<({String name, String price})?> showCustomItemDialog(
  BuildContext context, {
  required String loc,
}) {
  return showDialog<({String name, String price})>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CustomItemDialog(loc: loc),
  );
}

class _CustomItemDialog extends StatefulWidget {
  const _CustomItemDialog({required this.loc});

  final String loc;

  @override
  State<_CustomItemDialog> createState() => _CustomItemDialogState();
}

class _CustomItemDialogState extends State<_CustomItemDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _price = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  void _submit() {
    final loc = widget.loc;
    final value = parsePosAmount(_price.text);
    if (value == null || value <= 0) {
      setState(
        () => _error = AppStrings.t('custom_item_price_required', loc),
      );
      return;
    }
    final typed = _name.text.trim();
    Navigator.of(context).pop((
      name: typed.isEmpty ? AppStrings.t('unregistered_item', loc) : typed,
      price: posPlainAmount(value),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('custom-item-dialog'),
      title: Text(AppStrings.t('add_custom_item', loc)),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('custom-item-name'),
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: AppStrings.t('custom_item_name', loc),
                  hintText: AppStrings.t('unregistered_item', loc),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('custom-item-price'),
                controller: _price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                // The app's monetary emphasis, from the central ramp — not
                // a one-off size.
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                decoration: InputDecoration(
                  labelText: AppStrings.t('total_price', loc),
                  errorText: _error,
                  errorMaxLines: 2,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('custom-item-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('custom-item-confirm'),
          onPressed: _submit,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}
