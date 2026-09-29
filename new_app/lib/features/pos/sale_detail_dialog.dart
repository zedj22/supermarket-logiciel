// Sale detail dialog (UX FIX #4 Part B).
//
// Opens from a Sale History row: loads GET /api/v1/sales/{id}, shows
// header / lines / totals / payments, and exposes actions:
//   Print | Reprint | Copy invoice | Refresh | Close
//
// Print is NEVER part of the sale transaction — the sale is already
// committed. Print preview confirms before sending; any printer failure
// shows a localized error (sale stays intact; retry allowed).
//
// Known limitation: cashier user is not persisted by the API. All line
// display data (product, variant, selling unit + multiplier) comes from
// the historical snapshots captured at checkout (UX FIX #11) — no catalog
// API is ever called. Raw UUIDs are not shown in the primary UI (optional
// secondary technical section).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../returns/return_create_dialog.dart';
import '../returns/return_providers.dart';
import '../returns/return_void_dialog.dart';
import 'pos_error_message.dart';
import 'pos_models.dart';
import 'pos_providers.dart';
import 'pos_toast.dart';
import 'print_service.dart';

Future<void> showSaleDetailDialog(
  BuildContext context, {
  required String saleId,
  String? invoiceNumber,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SaleDetailDialog(
      saleId: saleId,
      invoiceNumber: invoiceNumber,
    ),
  );
}

/// Formats a base-unit quantity for display (48 → "48", 4.5 → "4.5").
String _fmtQty(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  final fixed = value.toStringAsFixed(3);
  return fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Builds the plain-text receipt used by print preview and the printer.
///
/// Line rows come exclusively from the sale line's historical snapshots
/// (UX FIX #11): stored variant name, stored selling unit name and stored
/// multiplier (base quantity). Nothing is looked up in the catalog.
String buildReceiptText(SaleDetail sale, String locale) {
  final buffer = StringBuffer()
    ..writeln(AppStrings.t('invoice_number', locale))
    ..writeln(sale.invoiceNumber)
    ..writeln(
      '${AppStrings.t('sale_history', locale)}: '
      '${sale.saleDate.toLocal().toString().substring(0, 16)}',
    )
    ..writeln(
      '${AppStrings.t('status', locale)}: ${sale.status}',
    )
    ..writeln('-' * 32);
  for (final line in sale.lines) {
    final variant = line.variantName;
    final sellingUnit = line.sellingUnitName;
    final unitLabel = (sellingUnit != null && sellingUnit.isNotEmpty)
        ? sellingUnit
        : line.productUnit;
    final title = (variant != null && variant.isNotEmpty)
        ? '${line.productName} ($variant)'
        : line.productName;
    buffer.writeln(
      '$title  '
      '${line.quantity} $unitLabel  '
      '${line.unitPrice}  '
      '${line.lineTotal}',
    );
    final baseQty = line.baseQuantity;
    if (baseQty != null) {
      buffer.writeln(
        '  ${AppStrings.t('base', locale)}: '
        '${_fmtQty(baseQty)} ${line.productUnit}',
      );
    }
  }
  buffer.writeln('-' * 32);
  buffer.writeln('${AppStrings.t('subtotal', locale)}: ${sale.subtotal}');
  buffer.writeln('${AppStrings.t('discount', locale)}: ${sale.discount}');
  buffer.writeln('${AppStrings.t('total', locale)}: ${sale.total}');
  buffer.writeln('${AppStrings.t('amount_paid', locale)}: ${sale.paid}');
  buffer.writeln('${AppStrings.t('change', locale)}: ${sale.change}');
  if ((double.tryParse(sale.debt) ?? 0) > 0) {
    buffer.writeln('${AppStrings.t('debt', locale)}: ${sale.debt}');
  }
  buffer.writeln(
    '${AppStrings.t('payment_method', locale)}: ${sale.paymentMethod}',
  );
  return buffer.toString();
}

class SaleDetailDialog extends ConsumerStatefulWidget {
  final String saleId;
  final String? invoiceNumber;

  const SaleDetailDialog({
    super.key,
    required this.saleId,
    this.invoiceNumber,
  });

  @override
  ConsumerState<SaleDetailDialog> createState() => _SaleDetailDialogState();
}

class _SaleDetailDialogState extends ConsumerState<SaleDetailDialog> {
  SaleDetail? _sale;
  bool _loading = false;
  String? _error;
  bool _printBusy = false;
  String? _printError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get('/api/v1/sales/${widget.saleId}');
      final data = response.data as Map<String, dynamic>? ?? const {};
      final sale = SaleDetail.fromJson(data);
      if (!mounted) return;
      setState(() {
        _sale = sale;
        _loading = false;
      });
    } on DioException catch (e) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      // Localized headline first (UX FIX #12 — FIX #5); backend English
      // text is never the primary line of a POS error.
      final message = posApiMessage(e, loc);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = message;
      });
    } catch (_) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppStrings.t('api_error_retry', loc);
      });
    }
  }

  Future<void> _copyInvoice() async {
    final invoice = _sale?.invoiceNumber ?? widget.invoiceNumber ?? '';
    if (invoice.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: invoice));
    if (!mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('invoice_copied', loc),
      kind: PosToastKind.success,
    );
  }

  /// Phase 12 VOID (GATE 1 + GATE 9): terminal, reason mandatory, the
  /// sale snapshot keeps its totals and only gains the void attribution.
  Future<void> _void() async {
    final sale = _sale;
    if (sale == null || sale.isVoided) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final reason = await showVoidReasonDialog(
      context,
      invoiceNumber: sale.invoiceNumber,
    );
    if (reason == null || !mounted) return;

    final deviceId = await ref.read(posDeviceIdProvider.future);
    final (result, error) = await ref.read(returnsApiProvider).voidSale(
          saleId: sale.id,
          reason: reason,
          deviceId: deviceId,
        );
    if (!mounted) return;
    if (error != null) {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('sale-void-error-toast'),
      );
      return;
    }
    final cashDetail = result == null || result.cashPending == '0'
        ? null
        : '${AppStrings.t('return_cash_pending', loc)}: '
            '${result.cashPending}';
    showPosToast(
      context,
      message: AppStrings.t('void_success', loc),
      detail: cashDetail,
      kind: PosToastKind.success,
      key: const Key('sale-void-success-toast'),
    );
    await _load();
  }

  /// Phase 12 linked return: the dialog prices every line server-side and
  /// the invoice detail is refreshed from the API afterwards.
  Future<void> _returnItems() async {
    final sale = _sale;
    if (sale == null || sale.isVoided) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final result = await showReturnCreateDialog(context, sale: sale);
    if (result == null || !mounted) return;
    showPosToast(
      context,
      message: result.idempotentReplay
          ? AppStrings.t('return_replay', loc)
          : AppStrings.t('return_success', loc),
      detail: '${AppStrings.t('return_refund_total', loc)}: '
          '${result.refundTotal}',
      kind: PosToastKind.success,
      key: const Key('sale-return-success-toast'),
    );
    await _load();
  }

  Future<void> _showPrintPreview() async {
    final sale = _sale;
    if (sale == null || _printBusy) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final receipt = buildReceiptText(sale, loc);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('print-preview-dialog'),
        title: Text(AppStrings.t('print_preview', loc)),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Text(
              receipt,
              key: const Key('print-preview-body'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('print-preview-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('print', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _print(receipt);
  }

  Future<void> _print(String receipt) async {
    setState(() {
      _printBusy = true;
      _printError = null;
    });
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    try {
      await ref.read(printServiceProvider).printText(receipt);
      if (!mounted) return;
      setState(() => _printBusy = false);
    } on PrintServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _printBusy = false;
        // Never "success" on failure — localized error only.
        _printError = e.message.isEmpty
            ? AppStrings.t('print_failed', loc)
            : '${AppStrings.t('print_failed', loc)}: ${e.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _printBusy = false;
        _printError = AppStrings.t('print_failed', loc);
      });
    }
  }

  String _fmtMoney(String raw) {
    final v = double.tryParse(raw);
    return v == null ? raw : v.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final sale = _sale;
    final canVoid = ref.watch(hasPermissionProvider('pos_void'));
    final canReturn = ref.watch(hasPermissionProvider('pos_return'));

    return AlertDialog(
      key: const Key('sale-detail-dialog'),
      title: Text(
        sale?.invoiceNumber ?? widget.invoiceNumber ?? '',
        key: const Key('sale-detail-invoice'),
      ),
      content: SizedBox(
        width: 560,
        height: 440,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      key: const Key('sale-detail-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : sale == null
                    ? Center(child: Text(AppStrings.t('api_error_retry', loc)))
                    : SingleChildScrollView(
                        key: const Key('sale-detail-body'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _metaRow(loc, theme, sale),
                            const SizedBox(height: 8),
                            Text(
                              AppStrings.t('sales', loc),
                              key: const Key('sale-detail-lines-title'),
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            for (var i = 0; i < sale.lines.length; i++)
                              _lineTile(loc, theme, sale.lines[i], i),
                            const Divider(height: 16),
                            _totals(theme, sale, loc),
                            const SizedBox(height: 8),
                            Text(
                              '${AppStrings.t('payment_method', loc)}: '
                              '${sale.paymentMethod}',
                              key: const Key('sale-detail-payment'),
                              style: theme.textTheme.bodyMedium,
                            ),
                            if (sale.customerId != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                AppStrings.t('customer', loc),
                                key: const Key('sale-detail-customer'),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (_printError != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                _printError!,
                                key: const Key('print-error'),
                                style:
                                    TextStyle(color: theme.colorScheme.error),
                              ),
                            ],
                            // Secondary technical section (IDs only).
                            const SizedBox(height: 12),
                            Text(
                              'id: ${sale.id}'
                              '${sale.deviceId != null ? ' · device: ${sale.deviceId}' : ''}',
                              key: const Key('sale-detail-technical'),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
      ),
      actions: [
        TextButton(
          key: const Key('sale-copy-invoice'),
          onPressed: sale == null ? null : _copyInvoice,
          child: Text(AppStrings.t('copy_invoice', loc)),
        ),
        if (canReturn)
          TextButton(
            key: const Key('sale-return'),
            onPressed: sale == null || sale.isVoided ? null : _returnItems,
            child: Text(AppStrings.t('return_create', loc)),
          ),
        if (canVoid)
          TextButton(
            key: const Key('sale-void'),
            onPressed: sale == null || sale.isVoided ? null : _void,
            child: Text(AppStrings.t('void_invoice', loc)),
          ),
        TextButton(
          key: const Key('sale-detail-refresh'),
          onPressed: _loading ? null : _load,
          child: Text(AppStrings.t('refresh', loc)),
        ),
        TextButton(
          key: const Key('sale-reprint'),
          onPressed: sale == null || _printBusy ? null : _showPrintPreview,
          child: Text(AppStrings.t('reprint', loc)),
        ),
        ElevatedButton(
          key: const Key('sale-print'),
          onPressed: sale == null || _printBusy ? null : _showPrintPreview,
          child: _printBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.t('print', loc)),
        ),
        TextButton(
          key: const Key('sale-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('close', loc)),
        ),
      ],
    );
  }

  Widget _metaRow(String loc, ThemeData theme, SaleDetail sale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${AppStrings.t('status', loc)}: ${sale.status}',
          key: const Key('sale-detail-status'),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          sale.saleDate.toLocal().toString().substring(0, 16),
          key: const Key('sale-detail-date'),
          style: theme.textTheme.bodySmall,
        ),
        if (sale.isVoided) ...[
          const SizedBox(height: 4),
          // GATE 9: totals stay untouched, only this attribution is shown.
          Text(
            [
              AppStrings.t('status_void', loc),
              if (sale.voidReason != null && sale.voidReason!.isNotEmpty)
                sale.voidReason!,
              if (sale.voidedAt != null)
                sale.voidedAt!.toLocal().toString().substring(0, 16),
            ].join(' · '),
            key: const Key('sale-detail-voided'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _lineTile(
    String loc,
    ThemeData theme,
    SaleDetailLine line,
    int index,
  ) {
    final sellingUnit = line.sellingUnitName;
    final hasSellingUnit = sellingUnit != null && sellingUnit.isNotEmpty;
    // Historical selling-unit name (raw, like a product name); otherwise
    // the localized base-unit label.
    final unitLabel = hasSellingUnit
        ? sellingUnit
        : AppStrings.unitLabel(line.productUnit, loc);
    final variant = line.variantName;
    final baseQty = line.baseQuantity;
    return Padding(
      key: Key('sale-detail-line-$index'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(line.productName, style: theme.textTheme.bodyMedium),
                if (variant != null && variant.isNotEmpty)
                  Text(
                    variant,
                    key: Key('sale-detail-line-variant-$index'),
                    style: theme.textTheme.bodySmall,
                  ),
                Text(
                  '${line.quantity} $unitLabel × '
                  '${_fmtMoney(line.unitPrice)} '
                  '${AppStrings.t('currency', loc)}',
                  key: Key('sale-detail-line-qty-$index'),
                  style: theme.textTheme.bodySmall,
                ),
                if (hasSellingUnit && baseQty != null)
                  Text(
                    // Short "Base:" label (UX FIX #12 — human QA wording).
                    '${AppStrings.t('base', loc)}: '
                    '${_fmtQty(baseQty)} '
                    '${AppStrings.unitLabel(line.productUnit, loc)}',
                    key: Key('sale-detail-line-base-$index'),
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          Text(
            _fmtMoney(line.lineTotal),
            key: Key('sale-detail-line-total-$index'),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _totals(ThemeData theme, SaleDetail sale, String loc) {
    Widget row(String label, String value, {Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              Text(value, key: key, style: theme.textTheme.bodyMedium),
            ],
          ),
        );

    return Column(
      children: [
        row(
          AppStrings.t('subtotal', loc),
          _fmtMoney(sale.subtotal),
          key: const Key('sale-detail-subtotal'),
        ),
        row(
          AppStrings.t('discount', loc),
          _fmtMoney(sale.discount),
          key: const Key('sale-detail-discount'),
        ),
        row(
          AppStrings.t('total', loc),
          _fmtMoney(sale.total),
          key: const Key('sale-detail-total'),
        ),
        row(
          AppStrings.t('amount_paid', loc),
          _fmtMoney(sale.paid),
          key: const Key('sale-detail-paid'),
        ),
        if ((double.tryParse(sale.debt) ?? 0) > 0)
          row(
            AppStrings.t('debt', loc),
            _fmtMoney(sale.debt),
            key: const Key('sale-detail-debt'),
          ),
      ],
    );
  }
}
