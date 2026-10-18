// Create / edit supplier dialog (Phase 11).
//
// Same architecture as CustomerFormDialog: the dialog owns its fields
// and submit flow, delegates persistence to the suppliersProvider
// notifier (which returns a localized PosApiError or null on success),
// then pops. `balance` is NEVER sent — server-owned projection.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_toast.dart';
import 'suppliers_error.dart';
import 'suppliers_providers.dart';
import 'supplier_models.dart';

/// Opens the supplier form. Returns the freshly created [SupplierModel]
/// on a successful create (so a caller like the purchase editor can
/// select it immediately), or null on cancel / edit / failure.
Future<SupplierModel?> showSupplierFormDialog(
  BuildContext context, {
  SupplierModel? supplier,
}) {
  return showDialog<SupplierModel>(
    context: context,
    builder: (_) => SupplierFormDialog(supplier: supplier),
  );
}

class SupplierFormDialog extends ConsumerStatefulWidget {
  final SupplierModel? supplier;

  const SupplierFormDialog({super.key, this.supplier});

  @override
  ConsumerState<SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends ConsumerState<SupplierFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _email;
  late final TextEditingController _contact;
  late final TextEditingController _notes;

  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.supplier != null;

  @override
  void initState() {
    super.initState();
    final s = widget.supplier;
    _name = TextEditingController(text: s?.name ?? '');
    _phone = TextEditingController(text: s?.phone ?? '');
    _address = TextEditingController(text: s?.address ?? '');
    _email = TextEditingController(text: s?.email ?? '');
    _contact = TextEditingController(text: s?.contactPerson ?? '');
    _notes = TextEditingController(text: s?.notes ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _email.dispose();
    _contact.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _validate(String loc) {
    if (_name.text.trim().isEmpty) {
      return AppStrings.t('field_required', loc);
    }
    if (_phone.text.trim().length > 30) {
      return AppStrings.t('phone', loc);
    }
    if (_email.text.trim().length > 100) {
      return AppStrings.t('email', loc);
    }
    if (_contact.text.trim().length > 100) {
      return AppStrings.t('contact_person', loc);
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    String? nullable(String value) => value.trim().isEmpty ? null : value.trim();
    return {
      'name': _name.text.trim(),
      'phone': nullable(_phone.text),
      'address': nullable(_address.text),
      'email': nullable(_email.text),
      'contact_person': nullable(_contact.text),
      'notes': nullable(_notes.text),
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

    final notifier = ref.read(suppliersProvider.notifier);
    final payload = _payload();
    SupplierModel? created;
    PosApiError? result;
    if (_isEdit) {
      result = await notifier.updateSupplier(widget.supplier!.id, payload);
    } else {
      (created, result) = await notifier.createSupplier(payload);
    }

    if (!mounted) return;
    if (result == null) {
      // Pop with the created supplier so a quick-add caller (purchase
      // editor) can select it without re-searching; edits pop null.
      Navigator.pop(context, created);
      showPosToast(
        context,
        message: AppStrings.t(
          _isEdit ? 'supplier_updated' : 'supplier_created',
          loc,
        ),
        kind: PosToastKind.success,
        key: const Key('supplier-form-success-toast'),
      );
    } else {
      final failure = result;
      setState(() {
        _saving = false;
        _error = failure.message;
        _errorDetail = failure.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    return AlertDialog(
      key: const Key('supplier-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_supplier' : 'add_supplier', loc),
        key: const Key('supplier-form-title'),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('supplier-name-field'),
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
                key: const Key('supplier-phone-field'),
                controller: _phone,
                enabled: !_saving,
                maxLength: 30,
                keyboardType: TextInputType.phone,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
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
                key: const Key('supplier-address-field'),
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
                key: const Key('supplier-email-field'),
                controller: _email,
                enabled: !_saving,
                maxLength: 100,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: AppStrings.t('email', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('supplier-contact-field'),
                controller: _contact,
                enabled: !_saving,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: AppStrings.t('contact_person', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('supplier-notes-field'),
                controller: _notes,
                enabled: !_saving,
                maxLength: 2000,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: AppStrings.t('note', loc),
                  hintText: AppStrings.t('note_hint', loc),
                  counterText: '',
                  alignLabelWithHint: true,
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
                  key: const Key('supplier-form-error'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_errorDetail != null && _errorDetail!.isNotEmpty)
                  Text(
                    _errorDetail!,
                    key: const Key('supplier-form-error-detail'),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('supplier-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('supplier-form-submit'),
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
