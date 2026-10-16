// Stage 2 — full A4 invoice preview sheet (legacy-parity).
//
// Visual/behavioral reference: factura_simple `invoice_preview.dart`,
// aligned with the server PDF template
// `backend/app/printing/templates/facture_a4.py`:
//   company identity + bordered title box → client box → items table
//   (gated Remise / TVA columns) → totals stack (gated TVA / timbre rows)
//   → French amount in words → payment method → notes → signature rule.
//
// Authority split (unchanged): every monetary value rendered here comes
// from the server preview response (POST /factures/preview) or the
// settings snapshot — Flutter performs NO fiscal arithmetic. Display
// formatting follows the Facturation UI conventions (Stage C-1):
// DD/MM/YYYY Latin-digit dates and trimmed `DA` money.
//
// Documented differences from the server PDF (unavoidable):
// - Money: preview trims trailing zeros (`100 DA`); the PDF prints two
//   fixed decimals (`100.00 DA`).
// - Date: the preview title box shows DD/MM/YYYY (Facturation display
//   policy); the PDF prints the stored ISO date.
// - Fonts/metrics and page-breaking: screen text vs printed page.
//
// RTL (ar): mirrors the printed page exactly like `facture_a4.py` —
// the sheet carries its own Directionality (locale-driven), Rows and
// Alignments flip naturally, and the items Table (physical by spec) is
// reversed explicitly. Latin-digit dates/money are unaffected.
import 'package:flutter/material.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../settings/settings_models.dart';
import 'facturation_format.dart';
import 'facturation_models.dart';

/// doc_type → title label key (backend `DOC_TITLE_KEYS`).
const Map<String, String> kDocTitleKeys = {
  DocTypeValue.fac: 'doc_facture',
  DocTypeValue.dev: 'doc_devis',
  DocTypeValue.pro: 'doc_proforma',
  DocTypeValue.bc: 'doc_bon_commande',
  DocTypeValue.bl: 'doc_bon_livraison',
};

/// Full-document preview sheet, sized as a miniature A4 page (595 × 842
/// pt) and scaled to the available width by [FittedBox].
class InvoicePreviewSheet extends StatelessWidget {
  final String docType;
  final String paymentMethod;
  final String? notes;
  final StoreSettings company;
  final InvoiceClientModel? client;
  final InvoiceDocumentPreviewModel preview;
  final bool showDiscount;
  final bool showTva;
  final bool showTimbre;
  final bool showPaymentMethod;
  final bool showAmountWords;
  final String loc;

  const InvoicePreviewSheet({
    super.key,
    required this.docType,
    required this.paymentMethod,
    this.notes,
    required this.company,
    required this.client,
    required this.preview,
    this.showDiscount = true,
    this.showTva = true,
    this.showTimbre = true,
    this.showPaymentMethod = true,
    this.showAmountWords = true,
    required this.loc,
  });

  bool get _rtl => loc == 'ar';

  String _t(String key) => AppStrings.t(key, loc);

  Widget _text(
    String? s, {
    bool bold = false,
    double size = 9,
    Color? color,
    Key? key,
    TextAlign? align,
  }) {
    if (s == null || s.trim().isEmpty) return const SizedBox.shrink();
    return Text(
      s,
      key: key,
      textAlign: align,
      style: TextStyle(
        fontSize: size,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        color: color ?? Colors.black,
      ),
    );
  }

  /// Legacy ``_id``: `"{label} : {value}"`, skipped when the value is blank.
  Widget _id(String labelKey, String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return _text('${_t(labelKey)} : $v');
  }

  Widget _cell(
    String s, {
    TextAlign align = TextAlign.start,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: numericText(
        s,
        textAlign: align,
        style: TextStyle(
          fontSize: 8.5,
          color: Colors.black,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  /// One totals row. [keyName] stays the legacy Phase 8 widget key
  /// (`invoice-form-total-total_ht` … — baseline test contract); [labelKey]
  /// is the backend `printing/labels.py` label the PDF prints.
  Widget _totalRow(
    String keyName,
    String labelKey,
    String value, {
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _text(_t(labelKey), size: bold ? 11 : 9, bold: bold),
          numericText(
            value,
            key: Key('invoice-form-total-$keyName'),
            style: TextStyle(
              fontSize: bold ? 11 : 9,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  /// One party's printed identity lines (PDF `_company_lines` /
  /// `_client_block` order): bare address/wilaya, then labeled ids.
  List<Widget> _identityLines({
    required String? address,
    required String? wilaya,
    String? phone,
    String? rc,
    String? nif,
    String? ai,
    String? nis,
    String? email,
    String? rib,
  }) {
    final lines = <Widget>[];
    for (final value in [address, wilaya]) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty) lines.add(_text(text));
    }
    lines
      ..add(_id('phone', phone))
      ..add(_id('fiscal_email', email))
      ..add(_id('fiscal_rc', rc))
      ..add(_id('fiscal_nif', nif))
      ..add(_id('fiscal_ai', ai))
      ..add(_id('fiscal_nis', nis))
      ..add(_id('fiscal_rib', rib));
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final lines = preview.lines;
    final totals = preview.totals;
    final companyName = company.storeName.trim();
    final client = this.client;
    final notes = (this.notes ?? '').trim();
    final amountInWords = preview.amountInWords.trim();
    final timbreMilli = moneyToMilli(totals.timbre);
    final timbreVisible = showTimbre && (timbreMilli ?? 0) > 0;

    // PDF number_align: left when rtl, right when ltr — under the
    // locale-driven Directionality that is exactly TextAlign.end.
    const numberAlign = TextAlign.end;

    // Logical-order header keys; reversed physically for RTL.
    final headerLabels = <String>[
      '#',
      'col_description',
      'col_qty',
      'col_unit_price_ht',
      if (showDiscount) 'col_remise_pct',
      if (showTva) 'col_tva_rate',
      'col_ht',
    ];
    final headerAligns = <TextAlign>[
      TextAlign.center,
      TextAlign.start,
      TextAlign.center,
      numberAlign,
      if (showDiscount) numberAlign,
      if (showTva) numberAlign,
      numberAlign,
    ];
    final headerCells = <Widget>[
      for (var i = 0; i < headerLabels.length; i++)
        _cell(
          headerLabels[i] == '#' ? '#' : _t(headerLabels[i]),
          align: headerAligns[i],
          bold: true,
        ),
    ];

    // Legacy column geometry: N° 22, Désignation flex, Qté 34, P.U. flex,
    // gated Remise 44 / TVA 36, Total flex — total width 595 − padding.
    final columnWidths = <int, TableColumnWidth>{};
    var idx = 0;
    columnWidths[idx++] = const FixedColumnWidth(22);
    columnWidths[idx++] = const FlexColumnWidth(4);
    columnWidths[idx++] = const FixedColumnWidth(34);
    columnWidths[idx++] = const FlexColumnWidth(1.6);
    if (showDiscount) columnWidths[idx++] = const FixedColumnWidth(44);
    if (showTva) columnWidths[idx++] = const FixedColumnWidth(36);
    columnWidths[idx++] = const FlexColumnWidth(1.8);

    final headerRow = _rtl
        ? TableRow(
            decoration: BoxDecoration(color: Colors.grey.shade300),
            children: headerCells.reversed.toList(),
          )
        : TableRow(
            decoration: BoxDecoration(color: Colors.grey.shade300),
            children: headerCells,
          );
    final reversedWidths = _rtl
        ? {
            for (var i = 0; i < columnWidths.length; i++)
              columnWidths.length - 1 - i: columnWidths[i]!,
          }
        : columnWidths;

    final tableRows = <TableRow>[headerRow];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final cells = <Widget>[
        _cell('${i + 1}', align: TextAlign.center),
        _cell(line.description),
        _cell(formatMoney(line.quantity), align: TextAlign.center),
        _cell(
          formatDisplayMoney(line.unitPriceHt, loc),
          align: numberAlign,
        ),
        if (showDiscount)
          _cell(formatMoney(line.discountPct), align: numberAlign),
        if (showTva) _cell(formatMoney(line.tvaRate), align: numberAlign),
        _cell(
          formatDisplayMoney(line.totalHt, loc),
          align: numberAlign,
        ),
      ];
      tableRows.add(
        TableRow(children: _rtl ? cells.reversed.toList() : cells),
      );
    }

    final titleBox = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
      ),
      child: Column(
        // Stretch so TextAlign.end (PDF right-align, mirrored in RTL)
        // applies across the full box width.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _text(
            _t(kDocTitleKeys[docType] ?? docType),
            bold: true,
            size: 14,
            align: TextAlign.end,
            key: const Key('invoice-preview-title'),
          ),
          const SizedBox(height: 4),
          _text(
            'N° : ${preview.number}',
            align: TextAlign.end,
            key: const Key('invoice-form-preview-number'),
          ),
          _text(
            '${_t('date')} : ${formatDisplayDate(preview.documentDate, loc)}',
            align: TextAlign.end,
            key: const Key('invoice-preview-date'),
          ),
        ],
      ),
    );

    final companyBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        companyName.isEmpty
            ? _text(
                _t('company_missing'),
                size: 9,
                color: Colors.grey,
                key: const Key('invoice-preview-company-missing'),
              )
            : _text(
                companyName,
                bold: true,
                size: 15,
                key: const Key('invoice-preview-company-name'),
              ),
        const SizedBox(height: 4),
        ..._identityLines(
          address: company.storeAddress,
          wilaya: company.storeWilaya,
          phone: company.storePhone,
          email: company.storeEmail,
          rc: company.storeRc,
          nif: company.storeNif,
          ai: company.storeAi,
          nis: company.storeNis,
          rib: company.storeRib,
        ),
      ],
    );

    final clientBox = client == null
        ? null
        : Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade600),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _text(
                  _t('customer'),
                  size: 8,
                  color: Colors.grey.shade700,
                ),
                _text(
                  client.name,
                  bold: true,
                  size: 11,
                  key: const Key('invoice-preview-client-name'),
                ),
                ..._identityLines(
                  address: client.address,
                  wilaya: client.wilaya,
                  phone: client.phone,
                  rc: client.rc,
                  nif: client.nif,
                  ai: client.ai,
                  nis: client.nis,
                ),
              ],
            ),
          );

    // Signature: legacy preview block (label, gap, rule to sign on),
    // aligned to the reading end like facture_a4.
    final signature = Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _text(
            _t('signature'),
            bold: true,
            size: 9,
            key: const Key('invoice-preview-signature'),
          ),
          const SizedBox(height: 4),
          Container(
            width: 180,
            height: 70,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.grey.shade500),
              ),
            ),
          ),
        ],
      ),
    );

    return Directionality(
      textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr,
      child: DecoratedBox(
        key: const Key('invoice-preview-sheet'),
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black26)],
        ),
        child: FittedBox(
          fit: BoxFit.fitWidth,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 595,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 842),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: seller identity on the reading start edge,
                    // bordered title box opposite (legacy row / facture_a4).
                    // Directionality flips the Row for ar.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: companyBlock),
                        const SizedBox(width: 16),
                        SizedBox(width: 238, child: titleBox),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (clientBox != null) ...[
                      clientBox,
                      const SizedBox(height: 14),
                    ],
                    Table(
                      border: TableBorder.all(
                        color: Colors.grey.shade600,
                        width: 0.5,
                      ),
                      columnWidths: reversedWidths,
                      children: tableRows,
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: SizedBox(
                        width: 230,
                        child: Column(
                          children: [
                            _totalRow(
                              'total_ht',
                              'col_ht',
                              formatDisplayMoney(totals.totalHt, loc),
                            ),
                            if (showTva)
                              _totalRow(
                                'total_tva',
                                'col_total_tva',
                                formatDisplayMoney(totals.totalTva, loc),
                              ),
                            _totalRow(
                              'total_ttc',
                              'col_ttc',
                              formatDisplayMoney(totals.totalTtc, loc),
                            ),
                            if (timbreVisible)
                              _totalRow(
                                'timbre',
                                'col_timbre',
                                formatDisplayMoney(totals.timbre, loc),
                              ),
                            const Divider(color: Colors.black54),
                            _totalRow(
                              'net_a_payer',
                              'col_net_a_payer',
                              formatDisplayMoney(totals.netAPayer, loc),
                              bold: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (showAmountWords && amountInWords.isNotEmpty)
                      _text(
                        amountInWords,
                        bold: true,
                        size: 9.5,
                        key: const Key('invoice-form-preview-words'),
                      ),
                    const SizedBox(height: 6),
                    if (showPaymentMethod)
                      _text(
                        '${_t('payment_method')} : '
                        '${_t('payment_$paymentMethod')}',
                        key: const Key('invoice-preview-payment'),
                      ),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _text(
                        '${_t('note')} : $notes',
                        key: const Key('invoice-preview-notes'),
                      ),
                    ],
                    const SizedBox(height: 40),
                    signature,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
