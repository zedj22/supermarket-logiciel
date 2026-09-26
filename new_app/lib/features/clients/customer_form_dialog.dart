// Create / edit client dialog (Phase 9).
//
// Same architecture as ProductFormDialog: the dialog owns its fields and
// submit flow, delegates persistence to the customersProvider notifier
// (which returns a localized PosApiError or null on success), then pops.
// Money fields are validated with the exact milli parser — no float math.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_toast.dart';
import 'clients_providers.dart';
import 'customer_models.dart';

Future<void> showCustomerFormDialog(
  BuildContext context, {
  CustomerModel? customer,
}) {
  return showDialog(
    context: context,
    builder: (_) => CustomerFormDialog(customer: customer),
  );
}

class CustomerFormDialog extends ConsumerStatefulWidget {
  final CustomerModel? customer;

  const CustomerFormDialog({super.key, this.customer});

  @override
  ConsumerState<CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends ConsumerState<CustomerFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _ceiling;

  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.customer != null;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _name = TextEditingController(text: c?.name ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _address = TextEditingController(text: c?.address ?? '');
    _ceiling = TextEditingController(
      text: c != null ? formatMoney(c.debtCeiling) : '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _ceiling.dispose();
    super.dispose();
  }

  String? _validate(String loc) {
    if (_name.text.trim().isEmpty) {
      return AppStrings.t('field_required', loc);
    }
    if (_phone.text.trim().length > 30) {
      return AppStrings.t('phone', loc);
    }
    final ceiling = _ceiling.text.trim();
    if (ceiling.isNotEmpty && moneyToMilli(ceiling) == null) {
      return AppStrings.t('invalid_amount', loc);
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    final ceiling = _ceiling.text.trim();
    return {
      'name': _name.text.trim(),
      'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      'address': _address.text.trim().isEmpty ? null : _address.text.trim(),
      'debt_ceiling': ceiling.isEmpty ? '0' : ceiling,
    };
  }

  Future<void> _submit() async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final validation = _validate(loc);
    if (validation != null) {
      setState(() {
        _error = validation;
        _errorDetail = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _errorDetail = null;
    });

    final notifier = ref.read(customersProvider.notifier);
    final payload = _payload();
    final result = _isEdit
        ? await notifier.updateCustomer(widget.customer!.id, payload)
        : await notifier.createCustomer(payload);

    if (!mounted) return;
    if (result == null) {
      Navigator.pop(context);
      showPosToast(
        context,
        message: AppStrings.t(
          _isEdit ? 'client_updated' : 'client_created',
          loc,
        ),
        kind: PosToastKind.success,
        key: const Key('client-form-success-toast'),
      );
    } else {
      setState(() {
        _saving = false;
        _error = result.message;
        _errorDetail = result.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    return AlertDialog(
      key: const Key('client-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_client' : 'add_client', loc),
        key: const Key('client-form-title'),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('client-name-field'),
              controller: _name,
              enabled: !_saving,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: AppStrings.t('name', loc),
                counterText: '',
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('client-phone-field'),
              controller: _phone,
              enabled: !_saving,
              maxLength: 30,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                LengthLimitingTextInputFormatter(30),
              ],
              decoration: InputDecoration(
                labelText: AppStrings.t('phone', loc),
                counterText: '',
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('client-address-field'),
              controller: _address,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: AppStrings.t('address', loc),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('client-ceiling-field'),
              controller: _ceiling,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                LengthLimitingTextInputFormatter(15),
              ],
              decoration: InputDecoration(
                labelText: AppStrings.t('debt_ceiling', loc),
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _errorDetail = null;
              }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('client-form-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
              if (_errorDetail != null && _errorDetail!.isNotEmpty)
                Text(
                  _errorDetail!,
                  key: const Key('client-form-error-detail'),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('client-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('client-form-submit'),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('save', loc)),
        ),
      ],
    );
  }
}
