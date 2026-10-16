// Invoice (facturation) editor dialog (Phase 8): create a new document
// or edit an existing one's mutable fields.
//
// Editor owns the draft state: invoice-client picker, doc-type / date /
// payment-method / show-flags, staged lines (each via the line dialog),
// and a server-side preview. Fiscal totals ALWAYS come from
// POST /factures/preview — Flutter never computes HT / TVA / TTC /
// timbre / net à payer authority; the live total row is display-only
// integer milli math until the preview response lands.
//
// Stage 2: once the form is valid, changes auto-refresh the preview
// (350 ms debounce, legacy invoice_page pattern) and the response
// renders as a full A4 sheet (InvoicePreviewSheet) — company identity
// from the settings snapshot, everything fiscal from the preview
// response. A failed or superseded preview never leaves stale values
// on screen.
//
// Immutable after create: doc_type / year / number / document_date
// (the form locks them in edit mode; the server rejects changes).
// No DELETE exists — historical fiscal documents are never deleted.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../pos/pos_toast.dart';
import '../settings/settings_models.dart';
import '../settings/settings_provider.dart';
import 'facturation_format.dart';
import 'facturation_models.dart';
import 'facturation_pickers.dart';
import 'facturation_providers.dart';
import 'invoice_line_dialog.dart';
import 'invoice_preview_sheet.dart';

Future<void> showInvoiceFormDialog(
  BuildContext context, {
  InvoiceDocumentModel? document,
}) {
  return showDialog(
    context: context,
    builder: (_) => InvoiceFormDialog(document: document),
  );
}

class InvoiceFormDialog extends ConsumerStatefulWidget {
  final InvoiceDocumentModel? document;

  const InvoiceFormDialog({super.key, this.document});

  @override
  ConsumerState<InvoiceFormDialog> createState() => _InvoiceFormDialogState();
}

class _InvoiceFormDialogState extends ConsumerState<InvoiceFormDialog> {
  String? _clientId;
  String? _clientName;
  String _docType = DocTypeValue.fac;
  DateTime? _documentDate;
  String _paymentMethod = PaymentMethodValue.cash;
  final List<DraftInvoiceLine> _lines = [];

  late final TextEditingController _notes;

  bool _showDiscount = true;
  bool _showTva = true;
  bool _showTimbre = true;
  bool _showPaymentMethod = true;
  bool _showAmountWords = true;

  /// Register-as-sale (only FAC; checked = post as POS sale after save).
  bool _registerAsSale = false;

  bool _saving = false;
  bool _previewing = false;
  String? _error;
  String? _errorDetail;

  InvoiceDocumentPreviewModel? _preview;

  /// Debounced auto-refresh (legacy 350 ms) + stale-response guard: a
  /// slow response must never overwrite a newer one.
  Timer? _previewDebounce;
  int _previewRequestId = 0;

  bool get _isEdit => widget.document != null;

  @override
  void initState() {
    super.initState();
    final doc = widget.document;
    _clientId = doc?.clientId;
    _clientName = doc?.client?.name;
    _docType = doc?.docType ?? DocTypeValue.fac;
    _documentDate = doc == null ? null : DateTime.tryParse(doc.documentDate);
    _paymentMethod = doc?.paymentMethod ?? PaymentMethodValue.cash;
    _notes = TextEditingController(text: doc?.notes ?? '');
    if (doc != null) {
      _showDiscount = doc.showDiscount;
      _showTva = doc.showTva;
      _showTimbre = doc.showTimbre;
      _showPaymentMethod = doc.showPaymentMethod;
      _showAmountWords = doc.showAmountWords;
      _lines.addAll(
        doc.lines.map(
          (l) => DraftInvoiceLine(
            productId: l.productId,
            // Stage 3A option identity — rehydrated so an edit
            // round-trip keeps variant / unit / pack links intact.
            variantId: l.variantId,
            sellingUnitId: l.sellingUnitId,
            packId: l.packId,
            description: l.description,
            quantity: l.quantity,
            unitPriceHt: l.unitPriceHt,
            tvaRate: int.tryParse(l.tvaRate.split('.').first) ?? 0,
            discountPct: l.discountPct,
          ),
        ),
      );
    }
    // Company identity for the preview sheet (Stage 1 settings). Silent:
    // a failed settings load degrades to the company_missing hint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      loadStoreSettingsOnce(ref);
    });
    // Legacy parity: an already-valid form previews immediately.
    _schedulePreview();
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _notes.dispose();
    super.dispose();
  }

  // ── Display-only totals (integer milli math, never fiscal authority) ──

  int get _subtotalHtMilli {
    var sum = 0;
    for (final line in _lines) {
      sum += line.lineHtMilli;
    }
    return sum;
  }

  int get _subtotalTvaMilli {
    var sum = 0;
    for (final line in _lines) {
      sum += line.lineTvaMilli;
    }
    return sum;
  }

  // ── Validation ───────────────────────────────────────────────────────

  String? _validate(String loc) {
    if (_clientId == null || _clientId!.isEmpty) {
      return AppStrings.t('select_invoice_client', loc);
    }
    if (_lines.isEmpty) return AppStrings.t('purchase_requires_lines', loc);
    for (final line in _lines) {
      final qty = qtyToMilli(line.quantity);
      if (qty == null || qty <= 0) return AppStrings.t('invalid_qty', loc);
      if (line.isFreeText) {
        if (line.description.trim().isEmpty) {
          return AppStrings.t('field_required', loc);
        }
        if (moneyToMilli(line.unitPriceHt) == null) {
          return AppStrings.t('invalid_amount', loc);
        }
        if (line.tvaRate == null) return AppStrings.t('tva_rate', loc);
      } else if (line.unitPriceHt.trim().isNotEmpty &&
          moneyToMilli(line.unitPriceHt) == null) {
        return AppStrings.t('invalid_amount', loc);
      }
    }
    return null;
  }

  // ── Payloads ─────────────────────────────────────────────────────────

  /// Full create body (POST /factures).
  Map<String, dynamic> _createPayload() {
    final notes = _notes.text.trim();
    return {
      'doc_type': _docType,
      'client_id': _clientId,
      if (_documentDate != null)
        'document_date':
            '${_documentDate!.year.toString().padLeft(4, '0')}-'
            '${_documentDate!.month.toString().padLeft(2, '0')}-'
            '${_documentDate!.day.toString().padLeft(2, '0')}',
      'payment_method': _paymentMethod,
      if (notes.isNotEmpty) 'notes': notes,
      'show_discount': _showDiscount,
      'show_tva': _showTva,
      'show_timbre': _showTimbre,
      'show_payment_method': _showPaymentMethod,
      'show_amount_words': _showAmountWords,
      'register_as_sale': _registerAsSale,
      'lines': [for (final line in _lines) line.toPayload()],
    };
  }

  /// Partial update body (PUT /factures/{id}) — immutable identity and
  /// document_date are NEVER sent.
  Map<String, dynamic> _updatePayload() {
    final notes = _notes.text.trim();
    return {
      'client_id': _clientId,
      'payment_method': _paymentMethod,
      'notes': notes.isEmpty ? null : notes,
      'show_discount': _showDiscount,
      'show_tva': _showTva,
      'show_timbre': _showTimbre,
      'show_payment_method': _showPaymentMethod,
      'show_amount_words': _showAmountWords,
      'register_as_sale': _registerAsSale,
      'lines': [for (final line in _lines) line.toPayload()],
    };
  }

  // ── Actions ──────────────────────────────────────────────────────────

  Future<void> _pickClient() async {
    final client = await showInvoiceClientPicker(context);
    if (client == null || !mounted) return;
    setState(() {
      _clientId = client.id;
      _clientName = client.name;
      _error = null;
      _errorDetail = null;
      _preview = null;
    });
    _schedulePreview();
  }

  Future<void> _addLine() async {
    final line = await showInvoiceLineDialog(context);
    if (line == null || !mounted) return;
    setState(() {
      _lines.add(line);
      _error = null;
      _errorDetail = null;
      _preview = null;
    });
    _schedulePreview();
  }

  Future<void> _editLine(int index) async {
    final line = await showInvoiceLineDialog(context, initial: _lines[index]);
    if (line == null || !mounted) return;
    setState(() {
      _lines[index] = line;
      _error = null;
      _errorDetail = null;
      _preview = null;
    });
    _schedulePreview();
  }

  void _removeLine(int index) {
    setState(() {
      _lines.removeAt(index);
      _error = null;
      _errorDetail = null;
      _preview = null;
    });
    _schedulePreview();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _documentDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _documentDate = picked;
      _error = null;
      _preview = null;
    });
    _schedulePreview();
  }

  /// Debounced auto-refresh (legacy `invoice_page._schedulePreview`):
  /// only fires for a valid form, so a half-built draft never spams the
  /// endpoint or surfaces validation noise while typing.
  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _saving) return;
      _runPreview(silent: true);
    });
  }

  Future<void> _runPreview({bool silent = false}) async {
    if (_saving) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final validation = _validate(loc);
    if (validation != null) {
      // Silent (auto) runs skip an invalid form without shouting; the
      // explicit Preview button reports the reason, as before.
      if (!silent) {
        setState(() {
          _error = validation;
          _errorDetail = null;
        });
      }
      return;
    }
    final requestId = ++_previewRequestId;
    setState(() {
      _previewing = true;
      _error = null;
      _errorDetail = null;
    });
    final (preview, error) = await ref
        .read(facturationDocumentProvider)
        .preview(_createPayload());
    // Stale-response guard: only the latest request may touch state.
    if (!mounted || requestId != _previewRequestId) return;
    setState(() {
      _previewing = false;
      if (error != null) {
        _error = error.message;
        _errorDetail = error.detail;
        _preview = null;
      } else {
        _preview = preview;
      }
    });
  }

  Future<void> _submit() async {
    if (_saving) return;
    _previewDebounce?.cancel();
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

    final notifier = ref.read(facturationDocumentProvider);
    final (doc, error) = _isEdit
        ? await notifier.update(widget.document!.id, _updatePayload())
        : await notifier.create(_createPayload());

    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      ref.read(facturationProvider.notifier).refresh();
      showPosToast(
        context,
        message: AppStrings.t(
          _isEdit ? 'document_updated' : 'document_created',
          loc,
        ),
        detail: doc?.number,
        kind: PosToastKind.success,
        key: const Key('invoice-form-success-toast'),
      );
    } else {
      setState(() {
        _saving = false;
        _error = error.message;
        _errorDetail = error.detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final invoiceLoc = ref.watch(effectiveInvoiceLanguageProvider);
    final theme = Theme.of(context);
    final totals = _preview?.totals;
    final companySettings = ref.watch(settingsProvider).settings;

    return AlertDialog(
      key: const Key('invoice-form-dialog'),
      title: Text(
        AppStrings.t(_isEdit ? 'edit_document' : 'new_document', loc),
        key: const Key('invoice-form-title'),
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Client ───────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _clientName ?? AppStrings.t('select_invoice_client', loc),
                      key: const Key('invoice-form-client'),
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('invoice-form-pick-client'),
                    onPressed: _saving ? null : _pickClient,
                    icon: const Icon(Icons.search, size: 18),
                    label: Text(
                      AppStrings.t(
                        _clientId == null ? 'select' : 'edit',
                        loc,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ── Doc type / date / payment ────────────────────────
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('invoice-form-doc-type'),
                      initialValue: _docType,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('doc_type', loc),
                        isDense: true,
                      ),
                      items: [
                        for (final type in DocTypeValue.all)
                          DropdownMenuItem<String>(
                            value: type,
                            child: Text(
                              AppStrings.t('doc_type_${type.toLowerCase()}', loc),
                            ),
                          ),
                      ],
                      onChanged: _saving || _isEdit
                          ? null
                          : (value) {
                              setState(() {
                                _docType = value ?? DocTypeValue.fac;
                                _error = null;
                                _preview = null;
                              });
                              _schedulePreview();
                            },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('invoice-form-date'),
                      onPressed: _saving || _isEdit ? null : _pickDate,
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text(
                        _documentDate == null
                            ? AppStrings.t('document_date', loc)
                            : formatDisplayDate(
                                _documentDate!
                                    .toIso8601String()
                                    .substring(0, 10),
                                loc,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('invoice-form-payment'),
                      initialValue: _paymentMethod,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppStrings.t('payment_method', loc),
                        isDense: true,
                      ),
                      items: [
                        for (final method in PaymentMethodValue.all)
                          DropdownMenuItem<String>(
                            value: method,
                            child: Text(
                              AppStrings.t('payment_$method', loc),
                            ),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(() {
                                _paymentMethod =
                                    value ?? PaymentMethodValue.cash;
                                _error = null;
                                _preview = null;
                              });
                              _schedulePreview();
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ── Invoice PDF language (independent of the UI locale) ─
              DropdownButtonFormField<String>(
                key: const Key('invoice-form-language'),
                initialValue: invoiceLoc,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: AppStrings.t('invoice_language', loc),
                  isDense: true,
                ),
                items: [
                  for (final code in const ['ar', 'fr', 'en'])
                    DropdownMenuItem<String>(
                      value: code,
                      child: Text(
                        AppStrings.t('language_$code', loc),
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        ref
                            .read(invoiceLanguageProvider.notifier)
                            .state = value;
                        setState(() {
                          _error = null;
                          _preview = null;
                        });
                        _schedulePreview();
                      },
              ),
              if (_isEdit) ...[
                const SizedBox(height: 8),
                Text(
                  '${AppStrings.t('number', loc)}: ${widget.document!.number} · '
                  '${AppStrings.t('document_date', loc)}: ${formatDisplayDate(widget.document!.documentDate, loc)}',
                  key: const Key('invoice-form-identity'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              // ── Show flags ───────────────────────────────────────
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    key: const Key('invoice-form-show-discount'),
                    label: Text(AppStrings.t('show_discount', loc)),
                    selected: _showDiscount,
                    onSelected: _saving
                        ? null
                        : (v) {
                            setState(() {
                              _showDiscount = v;
                              _preview = null;
                            });
                            _schedulePreview();
                          },
                  ),
                  FilterChip(
                    key: const Key('invoice-form-show-tva'),
                    label: Text(AppStrings.t('show_tva', loc)),
                    selected: _showTva,
                    onSelected: _saving
                        ? null
                        : (v) {
                            setState(() {
                              _showTva = v;
                              _preview = null;
                            });
                            _schedulePreview();
                          },
                  ),
                  FilterChip(
                    key: const Key('invoice-form-show-timbre'),
                    label: Text(AppStrings.t('show_timbre', loc)),
                    selected: _showTimbre,
                    onSelected: _saving
                        ? null
                        : (v) {
                            setState(() {
                              _showTimbre = v;
                              _preview = null;
                            });
                            _schedulePreview();
                          },
                  ),
                  FilterChip(
                    key: const Key('invoice-form-show-payment'),
                    label: Text(AppStrings.t('show_payment_method', loc)),
                    selected: _showPaymentMethod,
                    onSelected: _saving
                        ? null
                        : (v) {
                            setState(() {
                              _showPaymentMethod = v;
                              _preview = null;
                            });
                            _schedulePreview();
                          },
                  ),
                  FilterChip(
                    key: const Key('invoice-form-show-words'),
                    label: Text(AppStrings.t('show_amount_words', loc)),
                    selected: _showAmountWords,
                    onSelected: _saving
                        ? null
                        : (v) {
                            setState(() {
                              _showAmountWords = v;
                              _preview = null;
                            });
                            _schedulePreview();
                          },
                  ),
                  // Register-as-sale (FAC only): post as a real POS sale
                  // through the authoritative SaleService (stock, sales,
                  // reports, financials). Disabled on non-FAC doc types
                  // and on already-posted documents (server locks content
                  // edits; reversal is via POS void / return).
                  if (_docType == DocTypeValue.fac)
                    FilterChip(
                      key: const Key('invoice-form-register-as-sale'),
                      label: Text(AppStrings.t('register_as_sale', loc)),
                      selected: _registerAsSale,
                      onSelected: (_saving || (widget.document?.isPosted ?? false))
                          ? null
                          : (v) {
                              setState(() {
                                _registerAsSale = v;
                                _preview = null;
                              });
                            },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // ── Notes ────────────────────────────────────────────
              TextField(
                key: const Key('invoice-form-notes'),
                controller: _notes,
                enabled: !_saving,
                maxLength: 2000,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: AppStrings.t('note', loc),
                  counterText: '',
                ),
                onChanged: (_) {
                  setState(() {
                    _error = null;
                    _preview = null;
                  });
                  _schedulePreview();
                },
              ),
              const SizedBox(height: 12),
              // ── Lines ────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${AppStrings.t('lines', loc)} (${_lines.length})',
                      key: const Key('invoice-form-lines-label'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('invoice-form-add-line'),
                    onPressed: _saving ? null : _addLine,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(AppStrings.t('add_line', loc)),
                  ),
                ],
              ),
              if (_lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    AppStrings.t('purchase_requires_lines', loc),
                    key: const Key('invoice-form-lines-empty'),
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                for (var i = 0; i < _lines.length; i++)
                  Card(
                    margin: const EdgeInsets.only(top: 4),
                    child: ListTile(
                      key: Key('invoice-form-line-$i'),
                      dense: true,
                      title: Text(
                        _lines[i].description.isEmpty
                            ? (_lines[i].productName ?? '')
                            : _lines[i].description,
                      ),
                      // Bidi: quantity stays natural; each grouped money
                      // / percent segment is its own LTR isolate (the
                      // Arabic "line total" label would otherwise reverse
                      // the digits — W7).
                      subtitle: Text(
                        '${_lines[i].quantity} × '
                        '${bidiIsolateLtr(formatDisplayMoney(_lines[i].unitPriceHt, loc))}'
                        '${_lines[i].tvaRate != null ? ' · TVA ${bidiIsolateLtr('${_lines[i].tvaRate}%')}' : ''}'
                        '${_lines[i].discountPct != '0' ? ' · ${bidiIsolateLtr('-${_lines[i].discountPct}%')}' : ''}'
                        ' · ${AppStrings.t('line_total', loc)}: '
                        '${bidiIsolateLtr(formatDisplayMoney(_lines[i].lineHt, loc))}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key('invoice-form-line-edit-$i'),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed:
                                _saving ? null : () => _editLine(i),
                          ),
                          IconButton(
                            key: Key('invoice-form-line-remove-$i'),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed:
                                _saving ? null : () => _removeLine(i),
                          ),
                        ],
                      ),
                    ),
                  ),
              const SizedBox(height: 12),
              // ── Preview sheet / totals ──────────────────────────
              if (_previewing)
                const Center(
                  key: Key('invoice-form-preview-loading'),
                  child: LinearProgressIndicator(),
                )
              else if (totals != null)
                // Stage 2: the whole A4 document, not just totals. The
                // company identity comes from the settings snapshot; all
                // fiscal values from the server preview response. The
                // sheet's FittedBox scales it to the dialog width.
                Center(
                  child: InvoicePreviewSheet(
                    key: const Key('invoice-form-preview'),
                    docType: _docType,
                    paymentMethod: _paymentMethod,
                    notes: _notes.text,
                    company:
                        companySettings ?? StoreSettings.fromJson(const {}),
                    client: _preview!.client,
                    preview: _preview!,
                    showDiscount: _showDiscount,
                    showTva: _showTva,
                    showTimbre: _showTimbre,
                    showPaymentMethod: _showPaymentMethod,
                    showAmountWords: _showAmountWords,
                    loc: invoiceLoc,
                  ),
                )
              else
                // Display-only fallback before the first preview.
                // Bidi: Arabic labels natural; each grouped total is its
                // own LTR isolate (W7).
                Text(
                  '${AppStrings.t('subtotal', loc)}: '
                  '${bidiIsolateLtr(formatDisplayMoney(milliToMoney(_subtotalHtMilli), loc))} · '
                  '${AppStrings.t('tva', loc)}: '
                  '${bidiIsolateLtr(formatDisplayMoney(milliToMoney(_subtotalTvaMilli), loc))}',
                  key: const Key('invoice-form-display-totals'),
                  style: theme.textTheme.titleSmall,
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('invoice-form-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                if (_errorDetail != null && _errorDetail!.isNotEmpty)
                  Text(
                    _errorDetail!,
                    key: const Key('invoice-form-error-detail'),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('invoice-form-cancel'),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        if (!_isEdit)
          OutlinedButton(
            key: const Key('invoice-form-preview-button'),
            onPressed: _saving || _previewing
                ? null
                : () {
                    _previewDebounce?.cancel();
                    _runPreview();
                  },
            child: Text(AppStrings.t('preview', loc)),
          ),
        ElevatedButton(
          key: const Key('invoice-form-submit'),
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
