// Audit event detail dialog (Slice B).
//
// Opens by event id and re-fetches GET /api/v1/audit/{id} so the
// operator sees the authoritative record (parsed snapshots + the
// server-computed diff), not a stale list row. Loading, failure and
// retry are explicit; a not-found event says so. Secrets never appear
// here — the backend redacts them before storage (Slice A).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'audit_error.dart';
import 'audit_models.dart';

Future<void> showAuditDetailDialog(
  BuildContext context, {
  required String eventId,
}) {
  return showDialog(
    context: context,
    builder: (context) => AuditDetailDialog(eventId: eventId),
  );
}

class AuditDetailDialog extends ConsumerStatefulWidget {
  const AuditDetailDialog({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<AuditDetailDialog> createState() => _AuditDetailDialogState();
}

class _AuditDetailDialogState extends ConsumerState<AuditDetailDialog> {
  int _requestId = 0;
  bool _loading = true;
  String? _error;
  AuditEvent? _event;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    try {
      final response = await ref
          .read(apiClientProvider)
          .dio
          .get('$kAuditPath/${widget.eventId}');
      if (requestId != _requestId || !mounted) return;
      setState(() {
        _event = AuditEvent.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        );
        _loading = false;
      });
    } on DioException catch (e) {
      if (requestId != _requestId || !mounted) return;
      setState(() {
        _loading = false;
        _error = auditApiMessage(e, loc);
      });
    } catch (_) {
      if (requestId != _requestId || !mounted) return;
      setState(() {
        _loading = false;
        _error = AppStrings.t('api_error_retry', loc);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    // Reduced-motion / disable-animations: content appears instantly.
    final animationDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);

    return AlertDialog(
      key: const Key('audit-detail-dialog'),
      title: Text(
        AppStrings.t('audit_detail_title', loc),
        key: const Key('audit-detail-title'),
      ),
      content: SizedBox(
        width: 760,
        child: AnimatedSize(
          duration: animationDuration,
          child: _loading
              ? const Padding(
                  key: Key('audit-detail-loading'),
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _error != null
                  ? _ErrorPane(message: _error!, onRetry: _fetch)
                  : _EventPane(event: _event!, loc: loc),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('audit-detail-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.t('close', loc)),
        ),
      ],
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, key: const Key('audit-detail-error')),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('audit-detail-retry'),
          onPressed: onRetry,
          child: Text(AppStrings.t('retry', loc)),
        ),
      ],
    );
  }
}

class _EventPane extends StatelessWidget {
  const _EventPane({required this.event, required this.loc});

  final AuditEvent event;
  final String loc;

  static const _dash = '—';

  String _fmtTime(DateTime? value) =>
      value == null ? _dash : value.toLocal().toString().substring(0, 16);

  String _text(String? value) =>
      (value == null || value.trim().isEmpty) ? _dash : value;

  Widget _row(String label, String value, {Key? valueKey}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value, key: valueKey)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcomeColor = switch (event.outcome) {
      'success' => Colors.green,
      'failure' => Colors.red,
      'denied' => Colors.orange,
      _ => theme.disabledColor,
    };

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Outcome + reason — the "what happened / why" answer.
          Row(
            children: [
              Container(
                key: const Key('audit-detail-outcome'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: outcomeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: outcomeColor),
                ),
                child: Text(
                  AppStrings.t(auditOutcomeKey(event.outcome), loc),
                  style: TextStyle(color: outcomeColor),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${AppStrings.t('audit_module', loc)}: '
                  '${AppStrings.t(auditModuleKey(event.module), loc)}'
                  ' · ${AppStrings.t('audit_action', loc)}: '
                  '${AppStrings.t(auditActionKey(event.action), loc)}',
                  key: const Key('audit-detail-what'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // When.
          _row(
            AppStrings.t('audit_occurred_at', loc),
            _fmtTime(event.occurredAt),
            valueKey: const Key('audit-detail-occurred-at'),
          ),
          _row(
            AppStrings.t('audit_recorded_at', loc),
            _fmtTime(event.recordedAt),
            valueKey: const Key('audit-detail-recorded-at'),
          ),
          const Divider(),
          // Who + which PC (with the verification state made explicit).
          _row(
            AppStrings.t('audit_actor', loc),
            event.actorLabel(loc),
            valueKey: const Key('audit-detail-actor'),
          ),
          _row(
            AppStrings.t('audit_device', loc),
            event.deviceVerified == null && event.deviceId == null
                ? _dash
                : '${event.deviceLabel(loc)}'
                    '${event.isUnverifiedClaim ? ' (${AppStrings.t('audit_device_unverified', loc)})' : ''}',
            valueKey: const Key('audit-detail-device'),
          ),
          _row(
            AppStrings.t('audit_ip_address', loc),
            _text(event.ipAddress),
            valueKey: const Key('audit-detail-ip'),
          ),
          _row(
            AppStrings.t('audit_session_id', loc),
            _text(event.sessionId),
          ),
          _row(
            AppStrings.t('audit_request_id', loc),
            _text(event.requestId),
            valueKey: const Key('audit-detail-request-id'),
          ),
          const Divider(),
          // What entity.
          _row(
            AppStrings.t('audit_entity_type', loc),
            _text(event.entityType),
            valueKey: const Key('audit-detail-entity-type'),
          ),
          _row(
            AppStrings.t('audit_entity', loc),
            _text(event.entityRef),
            valueKey: const Key('audit-detail-entity-ref'),
          ),
          _row(
            AppStrings.t('audit_entity_id', loc),
            _text(event.entityId),
          ),
          _row(
            AppStrings.t('audit_reason', loc),
            _text(event.reason),
            valueKey: const Key('audit-detail-reason'),
          ),
          _row(
            AppStrings.t('audit_event_id', loc),
            event.id,
            valueKey: const Key('audit-detail-id'),
          ),
          // What changed — the server-computed field-level diff.
          if (event.diff != null && event.diff!.isNotEmpty) ...[
            const Divider(),
            Text(
              AppStrings.t('audit_diff', loc),
              key: const Key('audit-detail-diff-title'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            _DiffTable(diff: event.diff!, loc: loc),
          ],
          // Structured context.
          if ((event.details ?? '').trim().isNotEmpty) ...[
            const Divider(),
            Text(
              AppStrings.t('audit_details', loc),
              style: theme.textTheme.titleSmall,
            ),
            Text(
              event.details!,
              key: const Key('audit-detail-details'),
            ),
          ],
          if (event.metadata != null && event.metadata!.isNotEmpty) ...[
            const Divider(),
            Text(
              AppStrings.t('audit_metadata', loc),
              style: theme.textTheme.titleSmall,
            ),
            Text(
              const JsonEncoder.withIndent('  ').convert(event.metadata),
              key: const Key('audit-detail-metadata'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// Field-level diff table: one row per changed field with its before and
/// after values exactly as the server computed them.
class _DiffTable extends StatelessWidget {
  const _DiffTable({required this.diff, required this.loc});

  final Map<String, dynamic> diff;
  final String loc;

  @override
  Widget build(BuildContext context) {
    const headStyle = TextStyle(fontWeight: FontWeight.w700);
    return Table(
      key: const Key('audit-detail-diff'),
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(2),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(
          children: [
            _head(AppStrings.t('audit_field', loc), headStyle),
            _head(AppStrings.t('audit_diff_before', loc), headStyle),
            _head(AppStrings.t('audit_diff_after', loc), headStyle),
          ],
        ),
        for (final entry in diff.entries)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  entry.key,
                  key: Key('audit-diff-field-${entry.key}'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _cell(_render(entry.value, 'before')),
              _cell(_render(entry.value, 'after')),
            ],
          ),
      ],
    );
  }

  String _render(dynamic value, String side) {
    if (value is Map) {
      final inner = value[side];
      return inner == null ? '—' : inner.toString();
    }
    // Non-map entries still deserve a visible value, not a blank cell.
    if (side == 'after') return value?.toString() ?? '—';
    return '—';
  }

  Widget _head(String text, TextStyle style) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(text, style: style),
      );

  Widget _cell(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(text),
      );
}
