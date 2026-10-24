// Loyalty Discount dialog — redeem a server-validated reward percent on
// the CURRENT sale.
//
// The percent is FREE-ENTRY (12%, 17%, 18.5% …) in a numeric field, capped
// by the owner's `max_reward_discount_percent`: an over-cap or invalid
// value is REJECTED with a local error and can never be confirmed (the
// session notifier and the server's `validate_reward_percent` re-enforce
// the same boundary on every other path).
//
// Contract: NOTHING is written to the loyalty session until Confirm.
// Every money figure shown is the preview endpoint's answer, fetched for
// the chosen percent with the exact payload the totals-panel session path
// uses (same endpoint, same LoyaltyPreview parsing — no client-side
// calculation, no second loyalty model). Cancel — or a barrier/system-back
// dismissal — simply closes: the sale and the loyalty balance are
// untouched. Confirm runs the EXISTING single-slot path: setRewardPercent
// (replaces the selection, never stacks it) plus an awaited previewNow()
// so the provider revalidates the preview against the current cart before
// the dialog closes; the footer's amount-due and the payment dialog then
// read that authoritative state.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../features/auth/auth_provider.dart';
import '../loyalty/loyalty_models.dart';
import '../loyalty/loyalty_providers.dart';
import 'pos_models.dart';
import 'pos_providers.dart';

/// Opens the Loyalty Discount dialog for the CURRENT cart + customer.
Future<void> showLoyaltyDiscountDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const LoyaltyDiscountDialog(),
  );
}

class LoyaltyDiscountDialog extends ConsumerStatefulWidget {
  const LoyaltyDiscountDialog({super.key});

  @override
  ConsumerState<LoyaltyDiscountDialog> createState() =>
      _LoyaltyDiscountDialogState();
}

class _LoyaltyDiscountDialogState extends ConsumerState<LoyaltyDiscountDialog> {
  /// Percent the cashier is choosing — LOCAL until Confirm (the preview
  /// endpoint serves one percent at a time, so the dialog keeps its own
  /// selection and only the confirmed percent reaches the provider).
  late double _chosen;

  /// Free-entry percent field: any valid value up to the server cap
  /// (12, 17, 18.5 …) — the old fixed 5-step dropdown is gone. Empty
  /// means "None" (no reward on this sale).
  late final TextEditingController _percentInput;

  /// Local input validation failure (unparseable, negative, above the
  /// cap). While set, Confirm is disabled and [_chosen] keeps its last
  /// VALID value — an invalid keystroke can never commit.
  String? _inputError;

  /// Server preview fetched for [_chosen] on the current cart total —
  /// display source for the discount and amount-due rows. Null while a
  /// fetch is in flight or after a failure (Confirm stays disabled).
  LoyaltyPreview? _preview;

  bool _busy = false;

  /// Monotonic token for the LOCAL preview fetches: a fast typist can
  /// change the percent while a request is in flight, and only the
  /// newest request's answer may land (older answers are dropped, never
  /// rendered under a newer selection).
  int _fetchToken = 0;

  /// Last local preview fetch FAILED (network/server) — the placeholder
  /// shows the error hint instead of a pending spinner. Reset by any
  /// later successful fetch or a percent change.
  bool _fetchFailed = false;

  /// Cart total this widget last rendered — when the cart moves under the
  /// modal (programmatic edits, stock corrections) the local preview is
  /// stale by definition and must be refetched.
  double? _seenTotal;

  @override
  void initState() {
    super.initState();
    final loyalty = ref.read(posLoyaltyProvider);
    _chosen = loyalty.rewardPercent;
    _percentInput = TextEditingController(
      text: _chosen > 0 ? _percentLabel(_chosen) : '',
    );
    // Reuse the session's own matching preview when it already answers
    // this percent + this total; otherwise fetch one right after mount.
    _preview = loyalty.previewMatches ? loyalty.preview : null;
    _seenTotal = ref.read(posCartProvider).totals.total;
    if (_preview == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void dispose() {
    _percentInput.dispose();
    super.dispose();
  }

  /// Fetches the SERVER preview for the currently chosen percent (exact
  /// payload shape of PosLoyaltyNotifier._previewNow — same validation).
  Future<LoyaltyPreview?> _fetchPreview(double percent) async {
    final loyaltyCustomerId = ref.read(posLoyaltyProvider).customerId;
    final cart = ref.read(posCartProvider);
    final customerId = loyaltyCustomerId ?? cart.customer?.id;
    final total = cart.totals.total;
    if (customerId == null || total <= 0) return null;
    try {
      final response = await ref.read(apiClientProvider).dio.post(
        '/api/v1/loyalty/preview',
        data: {
          'customer_id': customerId,
          'gross_total': total.toStringAsFixed(2),
          'reward_percent': percent,
        },
      );
      final preview = LoyaltyPreview.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      // Stale-answer guard — the modal blocks cart edits, but the guard
      // keeps the display honest if the session moved on anyway.
      final current = ref.read(posCartProvider);
      final stillCurrent = current.customer?.id == customerId &&
          current.totals.total == total &&
          percent == _chosen;
      return stillCurrent ? preview : null;
    } on DioException {
      return null;
    }
  }

  Future<void> _refresh() async {
    final token = ++_fetchToken;
    setState(() => _busy = true);
    final preview = await _fetchPreview(_chosen);
    if (!mounted || token != _fetchToken) return; // superseded
    setState(() {
      _preview = preview;
      _fetchFailed = preview == null;
      _busy = false;
    });
  }

  Future<void> _select(double percent) async {
    if (percent == _chosen) return;
    setState(() {
      _chosen = percent;
      _fetchFailed = false;
    });
    await _refresh();
  }

  /// Free-entry handler: only a VALID percent ever reaches [_chosen] —
  /// anything else raises a local error and leaves the last valid choice
  /// (plus the Confirm guard) untouched. Excessive percents are REJECTED,
  /// never clamped — the same convention the server domain
  /// (`validate_reward_percent`) and the session notifier enforce.
  void _onPercentChanged(String raw) {
    final loc = Localizations.localeOf(context).languageCode;
    final text = raw.trim();
    if (text.isEmpty) {
      setState(() => _inputError = null);
      _select(0);
      return;
    }
    final value = double.tryParse(text);
    if (value == null || value.isNaN || value.isInfinite || value < 0) {
      setState(() => _inputError = AppStrings.t('invalid_amount', loc));
      return;
    }
    // The server's hard ceiling is 100 (pydantic le=100) and the owner's
    // cap only ever lowers it — so a percent the cap has not answered
    // yet can already be refused above 100 without waiting.
    if (value > 100) {
      setState(() => _inputError = AppStrings.t('loyalty_redeem_exceeds', loc));
      return;
    }
    final maxPercent =
        ref.read(posLoyaltyProvider).maxRewardDiscountPercent;
    final capKnown = ref.read(posLoyaltyProvider).previewOnCurrentCart;
    if (value > 0 && capKnown && value > maxPercent + 0.0001) {
      setState(() => _inputError = AppStrings.t('loyalty_redeem_exceeds', loc));
      return;
    }
    setState(() => _inputError = null);
    _select(value);
  }

  /// The "None" affordance the old dropdown's zero option provided: one
  /// tap clears the field and the selection.
  void _clearPercent() {
    _percentInput.clear();
    setState(() => _inputError = null);
    _select(0);
  }

  /// Confirm: the ONE write path — the existing single-slot session
  /// setter (replaces, never stacks → no duplicate redemption possible)
  /// and an awaited preview so the provider revalidates before closing.
  Future<void> _confirm() async {
    if (_busy) return;
    final percent = _chosen;
    setState(() => _busy = true);
    final notifier = ref.read(posLoyaltyProvider.notifier);
    notifier.setRewardPercent(percent);
    await notifier.previewNow();
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  /// Display guard mirroring PosLoyaltyState.previewMatches for the
  /// locally fetched preview (percent AND current total must line up).
  bool _usable(LoyaltyPreview preview, double cartTotal) =>
      preview.rewardPercent == _chosen &&
      (preview.grossTotal - cartTotal).abs() < 0.005;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final currency = AppStrings.t('currency', loc);
    final cart = ref.watch(posCartProvider);
    final loyalty = ref.watch(posLoyaltyProvider);
    final customer = cart.customer;
    final cartTotal = cart.totals.total;

    final balance = loyalty.balance;
    final points =
        balance?.pointsBalance ?? _preview?.pointsBalance ?? 0.0;
    final cashback =
        balance?.cashbackBalance ?? _preview?.cashbackBalance ?? 0.0;
    final rewards = loyalty.availableRewards;

    // Owner cap for the free-entry field: shown as the field's helper
    // text and enforced on every keystroke (and again by the session
    // notifier and the server at Confirm / checkout).
    final maxPercent = loyalty.maxRewardDiscountPercent;
    final capKnown = loyalty.previewOnCurrentCart;

    final preview = _preview;
    final usable = preview != null && _usable(preview, cartTotal);
    // The cart can move underneath the modal (programmatic edits): the
    // local preview answers the OLD total by definition — refetch so the
    // due row never shows a stale answer. User input is blocked by the
    // modal, so this fires only for real provider-side changes. While a
    // fetch is in flight the detection is DEFERRED (the in-flight answer
    // may be stale) — the flag stays behind until a build with _busy
    // false catches up.
    if (_seenTotal != cartTotal && !_busy) {
      _seenTotal = cartTotal;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_busy) _refresh();
      });
    }
    // Revalidate at Confirm: while a percent > 0 is chosen the SERVER's
    // eligibility answer must still hold (and the session must not be
    // mid-load or in error). Clearing (None) needs no eligibility, but a
    // percent beyond the owner's cap is never confirmable — the same
    // boundary PosLoyaltyState.exceeds enforces. A locally invalid
    // keystroke (unparseable / negative / over-cap) also blocks Confirm:
    // it never became [_chosen], but the field must not look committable.
    final eligibleNow = _chosen > 0
        ? !loyalty.loading &&
            loyalty.error == null &&
            loyalty.canSelectReward &&
            (maxPercent <= 0 || _chosen <= maxPercent + 0.0001)
        : true;
    final canConfirm = !_busy &&
        _inputError == null &&
        usable &&
        eligibleNow &&
        !cart.isEmpty &&
        customer != null;

    return AlertDialog(
      key: const Key('pos-loyalty-dialog'),
      title: Row(
        children: [
          Icon(Icons.stars, size: 22, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppStrings.t('loyalty_redeem', loc),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Selected customer identity.
            Row(
              children: [
                Icon(Icons.person_outline, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        customer?.name ?? '',
                        key: const Key('pos-loyalty-dialog-customer'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (customer?.phone != null)
                        Text(
                          customer!.phone!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: cs.outlineVariant),
            const SizedBox(height: 8),
            // Balance: points · rewards × · cashback (bidi: every numeric
            // segment its own LTR isolate — W7 contract of the old block).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    AppStrings.t('loyalty', loc),
                    key: const Key('pos-loyalty-label'),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${bidiIsolateLtr(formatLoyaltyPoints(points))} '
                    '${AppStrings.t('loyalty_points', loc)}'
                    ' · ${bidiIsolateLtr('$rewards×')} '
                    '${AppStrings.t('loyalty_reward', loc)}'
                    ' · ${bidiIsolateLtr(
                      '${PaymentMath.money(cashback)} $currency',
                    )}',
                    key: const Key('pos-loyalty-balance'),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Free-entry percent: any valid value up to the server-owned
            // cap (12, 17, 18.5 …). The field never mutates the session —
            // Confirm is still the only write path — and an over-cap or
            // unparseable value shows the error and blocks Confirm.
            Row(
              children: [
                Flexible(
                  child: Text(
                    AppStrings.t('loyalty_reward', loc),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: TextField(
                    key: const Key('pos-loyalty-reward-input'),
                    controller: _percentInput,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: AppStrings.t('loyalty_reward', loc),
                      suffixText: '%',
                      helperText: capKnown && maxPercent > 0
                          ? '${AppStrings.t('loyalty_redeem_max', loc)}: '
                              '${_percentLabel(maxPercent)}%'
                          : null,
                    ),
                    onChanged: _onPercentChanged,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('pos-loyalty-reward-clear'),
                  tooltip: AppStrings.t('loyalty_reward_none', loc),
                  onPressed: _busy ? null : _clearPercent,
                  icon: const Icon(Icons.clear),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (_inputError != null) ...[
              const SizedBox(height: 6),
              Text(
                _inputError!,
                key: const Key('pos-loyalty-reward-error'),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            ],
            const SizedBox(height: 10),
            // Server preview rows: discount for the chosen percent, then
            // the amount the payment must cover. While a fetch is in
            // flight (or failed) the rows show a neutral pending marker
            // and Confirm stays disabled — eligibility/money stay known
            // before anything can be applied.
            if (usable) ...[
              Row(
                children: [
                  Flexible(
                    child: Text(
                      AppStrings.t('loyalty_reward', loc),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: numericText(
                      '-${PaymentMath.money(preview.rewardDiscount)} $currency',
                      key: const Key('pos-loyalty-dialog-discount'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.success,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      AppStrings.t('amount_due', loc),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: numericText(
                      '${PaymentMath.money(preview.amountDue)} $currency',
                      key: const Key('pos-loyalty-dialog-due'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ] else
              SizedBox(
                height: 24,
                child: Center(
                  child: !_busy && _fetchFailed
                      ? Text(
                          AppStrings.t('error', loc),
                          key: const Key('pos-loyalty-dialog-error'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.error,
                          ),
                        )
                      : const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pos-loyalty-dialog-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('pos-loyalty-dialog-confirm'),
          onPressed: canConfirm ? _confirm : null,
          child: Text(AppStrings.t('confirm', loc)),
        ),
      ],
    );
  }
}

/// Percent label matching the totals-panel dropdown items: plain number
/// form ('5', '12.5') — the caller decides whether to append '%'.
String _percentLabel(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return formatGrouped(
    value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), ''),
  );
}
