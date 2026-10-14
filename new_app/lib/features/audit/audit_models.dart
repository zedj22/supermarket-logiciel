// Audit trail models (Slice B) — a 1:1 mirror of what
// GET /api/v1/audit, /summary and /{id} return (backend
// app/schemas/audit.py). Nothing is recomputed client-side: the summary
// cards come from the server's aggregate over the filtered window, the
// diff is the server's computed field-level diff, and the outcome is
// whatever the server says — including the honest `unknown` for legacy
// rows written before the column existed.
import '../../core/strings.dart';

/// Base path of the read-only audit surface.
const String kAuditPath = '/api/v1/audit';

/// Canonical `AuditModule` vocabulary exactly as the backend enum stores
/// it (`app/models/enums.py`) — filter dropdown, never localized in the
/// payload.
const List<String> kAuditModules = <String>[
  'auth',
  'users',
  'products',
  'categories',
  'inventory',
  'sales',
  'returns',
  'purchases',
  'customers',
  'suppliers',
  'debts',
  'expenses',
  'promotions',
  'packs',
  'facturation',
  'settings',
  'devices',
  'backups',
  'exports',
  'print',
  'reports',
  'system',
];

/// Canonical `AuditAction` vocabulary (`app/models/enums.py`).
const List<String> kAuditActions = <String>[
  'create',
  'update',
  'delete',
  'login',
  'logout',
  'void',
  'return',
  'payment',
  'adjustment',
  'backup',
  'restore',
  'receive',
  'export',
  'print',
  'device_pair',
  'device_approve',
  'device_reject',
  'device_revoke',
];

/// Outcome codes the API can return. The first three are the backend
/// `AuditOutcome` enum; `unknown` is what legacy NULL rows are surfaced
/// as — never silently upgraded to "success".
const List<String> kAuditOutcomes = <String>[
  'success',
  'failure',
  'denied',
  'unknown',
];

/// Localization key for an outcome code (`audit_outcome_<code>`).
String auditOutcomeKey(String code) => 'audit_outcome_$code';

/// Localization key for a module code. NULL / empty modules (legacy
/// rows) are an explicit "unknown", not a blank cell.
String auditModuleKey(String? code) {
  if (code == null || code.trim().isEmpty) return 'audit_module_unknown';
  return 'audit_module_${code.trim()}';
}

/// Localization key for an action code (`audit_action_<code>`).
String auditActionKey(String code) => 'audit_action_$code';

/// One audit event as `GET /api/v1/audit` (and `/summary` siblings)
/// returns it. UUIDs travel as strings — the client never parses them.
class AuditEvent {
  final String id;
  final DateTime occurredAt;
  final DateTime? recordedAt;

  /// `success` | `failure` | `denied` | `unknown` (legacy NULL rows).
  final String outcome;
  final String? module;
  final String action;
  final String? actorId;

  /// Snapshotted name; may be the backend's `deleted user` marker when
  /// the FK was SET NULL — render through [actorLabel], never raw.
  final String? actorName;
  final String? deviceId;

  /// Registry display name — only ever set when [deviceVerified] is true.
  final String? deviceName;

  /// true = validated by device_guard, false = unvalidated header claim,
  /// null = no device offered.
  final bool? deviceVerified;
  final String? sessionId;
  final String? requestId;
  final String? ipAddress;
  final String? entityType;
  final String? entityId;
  final String? entityRef;
  final String? reason;
  final String? details;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  /// Server-computed `{field: {before, after}}`.
  final Map<String, dynamic>? diff;
  final Map<String, dynamic>? metadata;

  const AuditEvent({
    required this.id,
    required this.occurredAt,
    this.recordedAt,
    required this.outcome,
    this.module,
    required this.action,
    this.actorId,
    this.actorName,
    this.deviceId,
    this.deviceName,
    this.deviceVerified,
    this.sessionId,
    this.requestId,
    this.ipAddress,
    this.entityType,
    this.entityId,
    this.entityRef,
    this.reason,
    this.details,
    this.before,
    this.after,
    this.diff,
    this.metadata,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> json) {
    return AuditEvent(
      id: '${json['id'] ?? ''}',
      occurredAt:
          DateTime.tryParse('${json['occurred_at']}') ?? DateTime.now(),
      recordedAt: json['recorded_at'] == null
          ? null
          : DateTime.tryParse('${json['recorded_at']}'),
      outcome: '${json['outcome'] ?? 'unknown'}',
      module: json['module'] as String?,
      action: '${json['action'] ?? ''}',
      actorId: json['actor_id'] as String?,
      actorName: json['actor_name'] as String?,
      deviceId: json['device_id'] as String?,
      deviceName: json['device_name'] as String?,
      deviceVerified: json['device_verified'] as bool?,
      sessionId: json['session_id'] as String?,
      requestId: json['request_id'] as String?,
      ipAddress: json['ip_address'] as String?,
      entityType: json['entity_type'] as String?,
      entityId: json['entity_id'] as String?,
      entityRef: json['entity_ref'] as String?,
      reason: json['reason'] as String?,
      details: json['details'] as String?,
      before: json['before'] is Map
          ? Map<String, dynamic>.from(json['before'] as Map)
          : null,
      after: json['after'] is Map
          ? Map<String, dynamic>.from(json['after'] as Map)
          : null,
      diff: json['diff'] is Map
          ? Map<String, dynamic>.from(json['diff'] as Map)
          : null,
      metadata: json['metadata'] is Map
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
    );
  }

  /// What the "who" column prints: the snapshotted name, the backend's
  /// `deleted user` marker rendered in the operator's language, or an
  /// explicit placeholder when the row carries no actor at all (legacy /
  /// system rows). Never an empty cell, never the raw marker.
  String actorLabel(String loc) {
    final name = actorName?.trim();
    if (name != null && name.isNotEmpty) {
      if (name == 'deleted user') {
        return AppStrings.t('audit_actor_deleted', loc);
      }
      return name;
    }
    return AppStrings.t('audit_none', loc);
  }

  /// What the "which PC" column prints: the verified registry name, the
  /// claimed device id (the screen appends the unverified marker next to
  /// it), or an explicit placeholder.
  String deviceLabel(String loc) {
    final name = deviceName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final id = deviceId?.trim();
    if (id != null && id.isNotEmpty) return id;
    return AppStrings.t('audit_none', loc);
  }

  bool get isUnverifiedClaim => deviceVerified == false;
}

/// One page of `GET /api/v1/audit`.
class AuditListPage {
  final List<AuditEvent> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const AuditListPage({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 25,
    this.pages = 1,
  });

  factory AuditListPage.fromJson(Map<String, dynamic> json) {
    return AuditListPage(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => AuditEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      pageSize: json['page_size'] as int? ?? 25,
      pages: json['pages'] as int? ?? 1,
    );
  }
}

/// One `{key, count}` group row of `GET /api/v1/audit/summary`.
class AuditGroupCount {
  final String? key;
  final int count;

  const AuditGroupCount({this.key, this.count = 0});

  factory AuditGroupCount.fromJson(Map<String, dynamic> json) {
    return AuditGroupCount(
      key: json['key'] as String?,
      count: json['count'] as int? ?? 0,
    );
  }
}

/// `GET /api/v1/audit/summary` — aggregate counts for the SAME filtered
/// window as the list. The cards are never inferred from the visible
/// page; the server owns the arithmetic.
class AuditSummary {
  final int total;
  final int success;
  final int failure;
  final int denied;
  final int unknown;
  final int distinctUsers;
  final int distinctDevices;
  final List<AuditGroupCount> byAction;
  final List<AuditGroupCount> byModule;

  const AuditSummary({
    this.total = 0,
    this.success = 0,
    this.failure = 0,
    this.denied = 0,
    this.unknown = 0,
    this.distinctUsers = 0,
    this.distinctDevices = 0,
    this.byAction = const [],
    this.byModule = const [],
  });

  factory AuditSummary.fromJson(Map<String, dynamic> json) {
    return AuditSummary(
      total: json['total'] as int? ?? 0,
      success: json['success'] as int? ?? 0,
      failure: json['failure'] as int? ?? 0,
      denied: json['denied'] as int? ?? 0,
      unknown: json['unknown'] as int? ?? 0,
      distinctUsers: json['distinct_users'] as int? ?? 0,
      distinctDevices: json['distinct_devices'] as int? ?? 0,
      byAction: (json['by_action'] as List<dynamic>? ?? const [])
          .map((e) => AuditGroupCount.fromJson(e as Map<String, dynamic>))
          .toList(),
      byModule: (json['by_module'] as List<dynamic>? ?? const [])
          .map((e) => AuditGroupCount.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
