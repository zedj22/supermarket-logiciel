// Purchase detail dialog (Phase 11): historical lines, status badge,
// lifecycle actions (receive / cancel / draft delete) per permission.
//
// The document is append-only once received (Phase 0 rule 4): drafts
// can be edited or hard-deleted (audited), received documents can only
// be cancelled (symmetric reversal), cancelled documents are terminal.
// PMP is never shown as recomputed here — the server owns valuation.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';
import 'purchase_form_dialog.dart';
import 'purchase_models.dart';
import 'purchases_error.dart';
import 'purchases_providers.dart';

String _timestampOf(DateTime? value) {
  if (value == null) return '';
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final h = value.hour.toString().padLeft(2, '0');
  final min = value.minute.toString().padLeft(2, '0');
  final s = value.second.toString().padLeft(2, '0');
  return '${value.year}-$m-$d $h:$min:$s';
}

Future<void> showPurchaseDetailDialog(
  BuildContext context, {
  required String purchaseId,
}) {
  return showDialog(
    context: context,
    builder: (_) => PurchaseDetailDialog(purchaseId: purchaseId),
  );
}

class PurchaseDetailDialog extends ConsumerStatefulWidget {
  final String purchaseId;

  const PurchaseDetailDialog({super.key, required this.purchaseId});

  @override
  ConsumerState<PurchaseDetailDialog> createState() =>
      _PurchaseDetailDialogState();
}

class _PurchaseDetailDialogState extends ConsumerState<PurchaseDetailDialog> {
  Future<void> _reload() async {
    ref.read(purchaseDetailProvider(widget.purchaseId).notifier).load();
    ref.read(purchasesProvider.notifier).refresh();
  }

  Color _statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case PurchaseStatusValue.received:
        return scheme.primary;
      case PurchaseStatusValue.cancelled:
        return scheme.error;
      default:
        return scheme.tertiary;
    }
  }

  Future<void> _edit(PurchaseModel purchase) async {
    await showPurchaseFormDialog(context, draft: purchase);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _receive(PurchaseModel purchase) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('purchase-receive-confirm'),
        title: Text(AppStrings.t('receive_purchase_confirm', loc)),
        content: Text(purchase.invoiceNumber),
        actions: [
          TextButton(
            key: const Key('purchase-receive-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('purchase-receive-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('receive', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error =
        await ref.read(purchasesProvider.notifier).receive(purchase.id);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('purchase_received', loc),
        detail: purchase.invoiceNumber,
        kind: PosToastKind.success,
        key: const Key('purchase-receive-success-toast'),
      );
      await _reload();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('purchase-receive-error-toast'),
      );
      // A 409 means the document already moved on — re-sync.
      await _reload();
    }
  }

  Future<void> _cancel(PurchaseModel purchase) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('purchase-cancel-confirm'),
        title: Text(AppStrings.t('cancel_purchase_confirm', loc)),
        content: Text(purchase.invoiceNumber),
        actions: [
          TextButton(
            key: const Key('purchase-cancel-dialog-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('purchase-cancel-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('cancel_purchase', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error =
        await ref.read(purchasesProvider.notifier).cancel(purchase.id);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('purchase_cancelled', loc),
        detail: purchase.invoiceNumber,
        kind: PosToastKind.success,
        key: const Key('purchase-cancel-success-toast'),
      );
      await _reload();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('purchase-cancel-error-toast'),
      );
      await _reload();
    }
  }

  Future<void> _deleteDraft(PurchaseModel purchase) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('purchase-delete-confirm'),
        title: Text(AppStrings.t('delete_draft_confirm', loc)),
        content: Text(purchase.invoiceNumber),
        actions: [
          TextButton(
            key: const Key('purchase-delete-dialog-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('purchase-delete-confirm-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppStrings.t('delete_draft', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final error =
        await ref.read(purchasesProvider.notifier).deleteDraft(purchase.id);
    if (!mounted) return;
    if (error == null) {
      showPosToast(
        context,
        message: AppStrings.t('purchase_deleted', loc),
        detail: purchase.invoiceNumber,
        kind: PosToastKind.success,
        key: const Key('purchase-delete-success-toast'),
      );
      Navigator.pop(context); // close the detail dialog
      ref.read(purchasesProvider.notifier).refresh();
    } else {
      showPosToast(
        context,
        message: error.message,
        detail: error.detail,
        kind: PosToastKind.error,
        key: const Key('purchase-delete-error-toast'),
      );
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canCreate = ref.watch(hasPermissionProvider('purchase_create'));
    final canDelete = ref.watch(hasPermissionProvider('purchase_delete'));
    final detail = ref.watch(purchaseDetailProvider(widget.purchaseId));

    return AlertDialog(
      key: const Key('purchase-detail-dialog'),
      title: Text(
        AppStrings.t('purchase_detail', loc),
        key: const Key('purchase-detail-title'),
      ),
      content: SizedBox(
        width: 820,
        height: 560,
        child: detail.when(
          loading: () => const Center(
            key: Key('purchase-detail-loading'),
            child: CircularProgressIndicator(),
          ),
          error: (error, _) => Center(
            key: const Key('purchase-detail-error'),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(purchasesApiMessage(error, loc)),
                const SizedBox(height: 8),
                ElevatedButton(
                  key: const Key('purchase-detail-retry'),
                  onPressed: () => ref
                      .read(purchaseDetailProvider(widget.purchaseId).notifier)
                      .load(),
                  child: Text(AppStrings.t('retry', loc)),
                ),
              ],
            ),
          ),
          data: (purchase) {
            if (purchase == null) {
              return Center(
                key: const Key('purchase-detail-missing'),
                child: Text(AppStrings.t('purchase_not_found', loc)),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        purchase.invoiceNumber,
                        key: const Key('purchase-detail-invoice'),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    Chip(
                      key: const Key('purchase-detail-status'),
                      backgroundColor:
                          _statusColor(context, purchase.status)
                              .withValues(alpha: 0.15),
                      label: Text(
                        AppStrings.t(
                          'purchase_status_${purchase.status}',
                          loc,
                        ),
                        style: TextStyle(
                          color: _statusColor(context, purchase.status),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('purchase-detail-refresh'),
                      tooltip: AppStrings.t('refresh', loc),
                      onPressed: () => ref
                          .read(
                            purchaseDetailProvider(widget.purchaseId).notifier,
                          )
                          .load(),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                  ],
                ),
                Text(
                  [
                    // Supplier is optional — always shown; a purchase with
                    // none reads "Supplier: No supplier".
                    '${AppStrings.t('supplier', loc)}: '
                    '${purchase.supplierName == null || purchase.supplierName!.isEmpty ? AppStrings.t('no_supplier', loc) : purchase.supplierName}',
                    if (purchase.purchaseDate != null)
                      '${AppStrings.t('date', loc)}: '
                      '${bidiIsolateLtr(_timestampOf(purchase.purchaseDate))}',
                    if (purchase.receivedAt != null)
                      '${AppStrings.t('received_at', loc)}: '
                      '${bidiIsolateLtr(_timestampOf(purchase.receivedAt))}',
                    if (purchase.cancelledAt != null)
                      '${AppStrings.t('cancelled_at', loc)}: '
                      '${bidiIsolateLtr(_timestampOf(purchase.cancelledAt))}',
                  ].join(' · '),
                  key: const Key('purchase-detail-meta'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Card(
                  key: const Key('purchase-detail-totals'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        _DetailTotal(
                          labelKey: 'subtotal',
                          value: formatMoney(purchase.subtotal),
                          testKey: 'purchase-detail-subtotal',
                        ),
                        _DetailTotal(
                          labelKey: 'discount',
                          value: formatMoney(purchase.discount),
                          testKey: 'purchase-detail-discount',
                        ),
                        _DetailTotal(
                          labelKey: 'total',
                          value: formatMoney(purchase.total),
                          testKey: 'purchase-detail-total',
                          emphasized: true,
                        ),
                        _DetailTotal(
                          labelKey: 'paid',
                          value: formatMoney(purchase.paid),
                          testKey: 'purchase-detail-paid',
                        ),
                        _DetailTotal(
                          labelKey: 'remaining',
                          value: formatMoney(purchase.unpaid),
                          testKey: 'purchase-detail-remaining',
                        ),
                      ],
                    ),
                  ),
                ),
                if (purchase.note != null && purchase.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${AppStrings.t('note', loc)}: ${purchase.note}',
                      key: const Key('purchase-detail-note'),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.t('purchase_lines', loc),
                  key: const Key('purchase-detail-lines-title'),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: purchase.lines.isEmpty
                      ? Center(
                          key: const Key('purchase-detail-lines-empty'),
                          child: Text(AppStrings.t('no_data', loc)),
                        )
                      : ListView.builder(
                          key: const Key('purchase-detail-lines'),
                          itemCount: purchase.lines.length,
                          itemBuilder: (context, index) {
                            final line = purchase.lines[index];
                            final unit = line.purchaseUnitName == null
                                ? line.productUnit
                                : '${line.purchaseUnitName}'
                                    ' ×${line.unitMultiplier ?? ''}';
                            return ListTile(
                              key: Key('purchase-detail-line-$index'),
                              dense: true,
                              title: Text(
                                [
                                  line.productName,
                                  if (line.variantId != null &&
                                      line.productSku != null)
                                    line.productSku!,
                                ].join(' · '),
                                key: Key('purchase-detail-line-name-$index'),
                              ),
                              // Bidi: the optional Arabic "Base:" segment
                              // stays natural; each grouped amount is its
                              // own LTR isolate (whole-string LTR still
                              // reverses digits after Arabic — W7).
                              subtitle: Text(
                                '${line.quantity} $unit × '
                                '${bidiIsolateLtr(formatMoney(line.unitCost))}'
                                '${line.baseQtyEquivalent == null ? '' : ' '
                                    '· ${AppStrings.t('base', loc)}: '
                                    '${bidiIsolateLtr(line.baseQtyEquivalent!)}'}',
                                key: Key('purchase-detail-line-math-$index'),
                              ),
                              trailing: numericText(
                                formatMoney(line.lineTotal),
                                key: Key('purchase-detail-line-total-$index'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('purchase-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('close', loc)),
        ),
        if (detail.value != null && detail.value!.isDraft) ...[
          if (canCreate)
            OutlinedButton.icon(
              key: const Key('purchase-detail-edit'),
              onPressed: () => _edit(detail.value!),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(AppStrings.t('edit', loc)),
            ),
          if (canCreate)
            ElevatedButton.icon(
              key: const Key('purchase-detail-receive'),
              onPressed: () => _receive(detail.value!),
              icon: const Icon(Icons.download_done, size: 18),
              label: Text(AppStrings.t('receive', loc)),
            ),
          if (canDelete)
            OutlinedButton.icon(
              key: const Key('purchase-detail-delete'),
              onPressed: () => _deleteDraft(detail.value!),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(AppStrings.t('delete_draft', loc)),
            ),
        ],
        if (detail.value != null && detail.value!.isReceived && canDelete)
          ElevatedButton.icon(
            key: const Key('purchase-detail-cancel'),
            onPressed: () => _cancel(detail.value!),
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: Text(AppStrings.t('cancel_purchase', loc)),
          ),
      ],
    );
  }
}

class _DetailTotal extends StatelessWidget {
  final String labelKey;
  final String value;
  final bool emphasized;
  final String testKey;

  const _DetailTotal({
    required this.labelKey,
    required this.value,
    required this.testKey,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        key: Key(testKey),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t(labelKey, loc),
              style: theme.textTheme.bodySmall,
            ),
            numericText(
              value,
              key: Key('$testKey-value'),
              style: emphasized
                  ? theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    )
                  : theme.textTheme.titleSmall,
            ),
          ],
        ),
      ),
    );
  }
}
