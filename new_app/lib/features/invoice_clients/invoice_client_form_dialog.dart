// Create / edit invoice (fiscal) client dialog (Phase 8).
//
// Same architecture as SupplierFormDialog: the dialog owns its fields
// and submit flow, delegates persistence to the invoiceClientsProvider
// notifier (which returns a localized PosApiError or null on success),
// then pops. Invoice clients are the fiscal document identity — a
// SEPARATE domain from the POS Customer.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../facturation/facturation_models.dart';
import '../pos/pos_toast.dart';
import 'invoice_clients_providers.dart';

Future<void> showInvoiceClientFormDialog(
  BuildContext context, {
  InvoiceClientModel? client,
}) {
  return showDialog(
    context: context,
    builder: (_) => InvoiceClientFormDialog(client: client),
  );
}

class InvoiceClientFormDialog extends ConsumerStatefulWidget {
  final InvoiceClientModel? client;

  const InvoiceClientFormDialog({super.key, this.client});

  @override
  ConsumerState<InvoiceClientFormDialog> createState() =>
      _InvoiceClientFormDialogState();
}

class _InvoiceClientFormDialogState
    extends ConsumerState<InvoiceClientFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _wilaya;
  late final TextEditingController _phone;
  late final TextEditingController _nif;
  late final TextEditingController _rc;
  late final TextEditingController _ai;
  late final TextEditingController _nis;

  bool _saving = false;
  String? _error;
  String? _errorDetail;

  bool get _isEdit => widget.client != null;

  @override
  void initState() {
    super.initState();
    final c = widget.client;
    _name = TextEditingController(text: c?.name ?? '');
    _address = TextEditingController(text: c?.address ?? '');
    _wilaya = TextEditingController(text: c?.wilaya ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _nif = TextEditingController(text: c?.nif ?? '');
    _rc = TextEditingController(text: c?.rc ?? '');
    _ai = TextEditingController(text: c?.ai ?? '');
    _nis = TextEditingController(text: c?.nis ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _wilaya.dispose();
    _phone.dispose();
    _nif.dispose();
    _rc.dispose();
    _ai.dispose();
    _nis.dispose();
    super.dispose();
  }

  String? _validate(String loc) {
    if (_name.text.trim().isEmpty) {
      return AppStrings.t('field_required', loc);
    }
    if (_phone.text.trim().length > 30) {
      return AppStrings.t('phone', loc);
    }
    if (_wilaya.text.trim().length > 100) {
      return AppStrings.t('wilaya', loc);
    }
    for (final field in [_nif, _rc, _ai, _nis]) {
      if (field.text.trim().length > 30) {
        return AppStrings.t('field_required', loc);
      }
    }
    return null;
  }

  Map<String, dynamic> _payload() {
    String? nullable(String value) =>
        value.trim().isEmpty ? null : value.trim();
    return {
      'name': _name.text.trim(),
      'address': nullable(_address.text),
      'wilaya': nullable(_wilaya.text),
      'phone': nullable(_phone.text),
      'nif': nullable(_nif.text),
      'rc': nullable(_rc.text),
      'ai': nullable(_ai.text),
      'nis': nullable(_nis.text),
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

    final notifier = ref.read(invoiceClientsProvider.notifier);
    final payload = _payload();
    final result = _isEdit
        ? await notifier.updateClient(widget.client!.id, payload)
        : await notifier.createClient(payload);

    if (!mounted) return;
    if (result == null) {
      Navigator.pop(context);
      showPosToast(
        context,
        message: AppStrings.t(
          _isEdit ? 'invoice_client_updated' : 'invoice_client_created',
          loc,
        ),
        kind: PosToastKind.success,
        key: const Key('invoice-client-form-success-toast'),
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
      key: const Key('invoice-client-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_invoice_client' : 'add_invoice_client', loc),
        key: const Key('invoice-client-form-title'),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('invoice-client-name-field'),
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
                key: const Key('invoice-client-address-field'),
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
                key: const Key('invoice-client-wilaya-field'),
                controller: _wilaya,
                enabled: !_saving,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: AppStrings.t('wilaya', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('invoice-client-phone-field'),
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
                key: const Key('invoice-client-nif-field'),
                controller: _nif,
                enabled: !_saving,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: AppStrings.t('nif', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('invoice-client-rc-field'),
                controller: _rc,
                enabled: !_saving,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: AppStrings.t('rc', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('invoice-client-ai-field'),
                controller: _ai,
                enabled: !_saving,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: AppStrings.t('ai', loc),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _errorDetail = null;
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('invoice-client-nis-field'),
                controller: _nis,
                enabled: !_saving,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: AppStrings.t('nis', loc),
                  counterText: '',
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
                  key: const Key('invoice-client-form-error'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_errorDetail != null && _errorDetail!.isNotEmpty)
                  Text(
                    _errorDetail!,
                    key: const Key('invoice-client-form-error-detail'),
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
          key: const Key('invoice-client-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton(
          key: const Key('invoice-client-form-submit'),
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
