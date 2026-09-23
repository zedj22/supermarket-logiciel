// Create/edit purchase unit dialog (Phase 6 architectural correction).
//
// Fields: name, unit type, multiplier, barcode, default flag.
// NO selling price — purchase packaging is separate from commercial selling.
// Returns via Navigator.pop on success; shows error inline otherwise.
//
// Staged mode (create-product flow): when [staged] is true Save returns
// the payload map — the product form submits children atomically.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';
import 'products_providers.dart';

const List<String> kPurchaseUnitTypes = [
  'piece',
  'kg',
  'gram',
  'liter',
  'milliliter',
  'meter',
  'pack',
];

/// Returns:
/// - `staged=true`  → Map payload
/// - `staged=false` → bool success
Future<Object?> showPurchaseUnitFormDialog(
  BuildContext context, {
  String? productId,
  PurchaseUnitModel? unit,
  bool staged = false,
}) {
  assert(staged || productId != null, 'productId required unless staged');
  return showDialog<Object>(
    context: context,
    builder: (_) => PurchaseUnitFormDialog(
      productId: productId,
      unit: unit,
      staged: staged,
    ),
  );
}

class PurchaseUnitFormDialog extends ConsumerStatefulWidget {
  final String? productId;
  final PurchaseUnitModel? unit;
  final bool staged;

  const PurchaseUnitFormDialog({
    super.key,
    this.productId,
    this.unit,
    this.staged = false,
  });

  @override
  ConsumerState<PurchaseUnitFormDialog> createState() =>
      _PurchaseUnitFormDialogState();
}

class _PurchaseUnitFormDialogState
    extends ConsumerState<PurchaseUnitFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _multiplier;
  late final TextEditingController _barcode;
  String _unitType = 'piece';
  bool _isDefault = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.unit != null;

  @override
  void initState() {
    super.initState();
    final u = widget.unit;
    _name = TextEditingController(text: u?.name ?? '');
    _multiplier = TextEditingController(
      text: u != null ? _trim(u.multiplier) : '1',
    );
    _barcode = TextEditingController(text: u?.barcode ?? '');
    _unitType = u?.unitType ?? 'piece';
    _isDefault = u?.isDefault ?? false;
  }

  static String _trim(String value) {
    if (!value.contains('.')) return value;
    return value.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  @override
  void dispose() {
    _name.dispose();
    _multiplier.dispose();
    _barcode.dispose();
    super.dispose();
  }

  String? _validate() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (_name.text.trim().isEmpty) return AppStrings.t('name', loc);
    final mult = double.tryParse(_multiplier.text.trim());
    if (mult == null || mult <= 0) {
      return '${AppStrings.t('multiplier', loc)} > 0';
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    String? nonEmpty(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    if (_isEdit) {
      return {
        'name': _name.text.trim(),
        'unit_type': _unitType,
        'multiplier': _multiplier.text.trim(),
        if (nonEmpty(_barcode) != null) 'barcode': nonEmpty(_barcode),
        'is_default': _isDefault,
      };
    }
    return {
      'name': _name.text.trim(),
      'unit_type': _unitType,
      'multiplier': _multiplier.text.trim(),
      if (nonEmpty(_barcode) != null) 'barcode': nonEmpty(_barcode),
      'is_default': _isDefault,
    };
  }

  Future<void> _submit() async {
    final validation = _validate();
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final payload = _payload();

    // Staged (create-product): return payload — parent submits atomically.
    if (widget.staged) {
      if (!mounted) return;
      Navigator.pop(context, payload);
      return;
    }

    final notifier = ref.read(purchaseUnitsProvider.notifier);
    final error = _isEdit
        ? await notifier.update(widget.productId!, widget.unit!.id, payload)
        : await notifier.create(widget.productId!, payload);

    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('purchase-unit-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_purchase_unit' : 'add_purchase_unit', loc),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('purchase-unit-name-field'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: AppStrings.t('purchase_unit_name', loc),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('purchase-unit-type-field'),
                      initialValue: _unitType,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('unit', loc),
                      ),
                      items: [
                        for (final t in kPurchaseUnitTypes)
                          DropdownMenuItem(
                            value: t,
                            child: Text(AppStrings.unitLabel(t, loc)),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _unitType = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('purchase-unit-multiplier-field'),
                      controller: _multiplier,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: AppStrings.t('multiplier', loc),
                        helperText: AppStrings.t('multiplier_hint', loc),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('purchase-unit-barcode-field'),
                controller: _barcode,
                decoration: InputDecoration(
                  labelText: AppStrings.t('barcode', loc),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('purchase-unit-default-checkbox'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(AppStrings.t('is_default_purchase_unit', loc)),
                value: _isDefault,
                onChanged: (v) {
                  setState(() => _isDefault = v ?? false);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('purchase-unit-form-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('purchase-unit-form-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
