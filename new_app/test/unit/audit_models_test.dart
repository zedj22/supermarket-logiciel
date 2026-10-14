// Audit trail model tests (Slice B) — parsing mirrors the backend
// contract exactly (app/schemas/audit.py): honest `unknown` outcomes for
// legacy rows, snapshotted actor names with the `deleted user` marker,
// device names only when verified, and the server-computed diff passed
// through untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/audit/audit_models.dart';

void main() {
  const locales = ['ar', 'fr', 'en'];

  Map<String, dynamic> eventJson({
    String id = '3d0f4a6e-1111-2222-3333-444455556666',
    String outcome = 'success',
    String? module = 'sales',
    String action = 'void',
    String? actorName = 'Amel B.',
    String? deviceName = 'Caisse 1',
    bool? deviceVerified = true,
    String? reason,
    Map<String, dynamic>? diff,
  }) =>
      {
        'id': id,
        'occurred_at': '2026-10-01T09:30:00Z',
        'recorded_at': '2026-10-01T09:30:02Z',
        'outcome': outcome,
        'module': module,
        'action': action,
        'actor_id': '00000000-0000-0000-0000-0000000000a1',
        'actor_name': actorName,
        'device_id': 'POS-1',
        'device_name': deviceName,
        'device_verified': deviceVerified,
        'session_id': 'sess-1',
        'request_id': 'req-1',
        'ip_address': '192.168.1.10',
        'entity_type': 'sale',
        'entity_id': '9b0c1d2e-5555-6666-7777-888899990000',
        'entity_ref': 'VTE-2026-0042',
        'reason': reason,
        'details': '{"cashier":"amel"}',
        'before': {'status': 'completed'},
        'after': {'status': 'void'},
        'diff': diff ??
            {
              'status': {'before': 'completed', 'after': 'void'},
            },
        'metadata': {'source': 'pos'},
      };

  group('AuditEvent.fromJson', () {
    test('parses the full backend contract', () {
      final event = AuditEvent.fromJson(eventJson(reason: 'Wrong item'));

      expect(event.id, '3d0f4a6e-1111-2222-3333-444455556666');
      expect(event.occurredAt.toUtc().hour, 9);
      expect(event.recordedAt, isNotNull);
      expect(event.outcome, 'success');
      expect(event.module, 'sales');
      expect(event.action, 'void');
      expect(event.actorId, '00000000-0000-0000-0000-0000000000a1');
      expect(event.actorName, 'Amel B.');
      expect(event.deviceId, 'POS-1');
      expect(event.deviceName, 'Caisse 1');
      expect(event.deviceVerified, isTrue);
      expect(event.sessionId, 'sess-1');
      expect(event.requestId, 'req-1');
      expect(event.ipAddress, '192.168.1.10');
      expect(event.entityType, 'sale');
      expect(event.entityRef, 'VTE-2026-0042');
      expect(event.reason, 'Wrong item');
      expect(event.details, '{"cashier":"amel"}');
      expect(event.before, {'status': 'completed'});
      expect(event.after, {'status': 'void'});
      expect(event.diff?['status'], {'before': 'completed', 'after': 'void'});
      expect(event.metadata, {'source': 'pos'});
      expect(event.isUnverifiedClaim, isFalse);
    });

    test('a missing outcome is honest unknown, never success', () {
      final json = eventJson()
        ..remove('outcome');
      final event = AuditEvent.fromJson(json);
      expect(event.outcome, 'unknown');
    });

    test('a null module surfaces as the unknown-module key', () {
      final event = AuditEvent.fromJson(eventJson(module: null));
      expect(event.module, isNull);
      expect(auditModuleKey(event.module), 'audit_module_unknown');
    });

    test('legacy NULL device verification is null, not a false claim', () {
      final event = AuditEvent.fromJson(
        eventJson(deviceName: null, deviceVerified: null),
      );
      expect(event.deviceVerified, isNull);
      expect(event.isUnverifiedClaim, isFalse);
      expect(event.deviceLabel('en'), 'POS-1');
    });

    test('an unvalidated header claim is flagged', () {
      final event = AuditEvent.fromJson(
        eventJson(deviceName: null, deviceVerified: false),
      );
      expect(event.isUnverifiedClaim, isTrue);
    });
  });

  group('display labels', () {
    test('actorLabel uses the snapshotted name', () {
      final event = AuditEvent.fromJson(eventJson(actorName: 'Amel B.'));
      expect(event.actorLabel('en'), 'Amel B.');
    });

    test('actorLabel localizes the deleted-user marker', () {
      final event = AuditEvent.fromJson(eventJson(actorName: 'deleted user'));
      expect(event.actorLabel('en'), AppStrings.t('audit_actor_deleted', 'en'));
      expect(event.actorLabel('ar'), AppStrings.t('audit_actor_deleted', 'ar'));
      expect(event.actorLabel('ar'), isNot('deleted user'));
    });

    test('actorLabel falls back to an explicit placeholder, not blank', () {
      final event = AuditEvent.fromJson(eventJson(actorName: null));
      expect(event.actorLabel('en'), AppStrings.t('audit_none', 'en'));
      expect(event.actorLabel('en').trim(), isNotEmpty);
    });

    test('deviceLabel prefers the verified registry name', () {
      final event = AuditEvent.fromJson(eventJson());
      expect(event.deviceLabel('en'), 'Caisse 1');
    });

    test('deviceLabel falls back to the claimed id, then a placeholder', () {
      final named = AuditEvent.fromJson(
        eventJson(deviceName: null, deviceVerified: false),
      );
      expect(named.deviceLabel('en'), 'POS-1');

      final none = AuditEvent.fromJson(
        eventJson(deviceName: null, deviceVerified: null)
          ..remove('device_id'),
      );
      expect(none.deviceLabel('en'), AppStrings.t('audit_none', 'en'));
    });
  });

  group('AuditListPage / AuditSummary', () {
    test('parses a paginated page', () {
      final page = AuditListPage.fromJson({
        'items': [eventJson(), eventJson(id: 'other')],
        'total': 42,
        'page': 2,
        'page_size': 25,
        'pages': 2,
      });
      expect(page.items.length, 2);
      expect(page.total, 42);
      expect(page.page, 2);
      expect(page.pageSize, 25);
      expect(page.pages, 2);
    });

    test('parses the server aggregates incl. group counts', () {
      final summary = AuditSummary.fromJson({
        'total': 42,
        'success': 30,
        'failure': 8,
        'denied': 3,
        'unknown': 1,
        'distinct_users': 4,
        'distinct_devices': 2,
        'by_action': [
          {'key': 'void', 'count': 7},
          {'key': null, 'count': 2},
        ],
        'by_module': [
          {'key': 'sales', 'count': 20},
        ],
      });
      expect(summary.total, 42);
      expect(summary.success, 30);
      expect(summary.failure, 8);
      expect(summary.denied, 3);
      expect(summary.unknown, 1);
      expect(summary.distinctUsers, 4);
      expect(summary.distinctDevices, 2);
      expect(summary.byAction.first.key, 'void');
      expect(summary.byAction.first.count, 7);
      expect(summary.byAction.last.key, isNull);
      expect(summary.byModule.single.key, 'sales');
    });
  });

  group('vocabulary localization coverage', () {
    test('every module / action / outcome code has all three locales', () {
      final missing = <String>[];
      for (final locale in locales) {
        for (final code in kAuditOutcomes) {
          if (!AppStrings.translations[locale]!
              .containsKey(auditOutcomeKey(code))) {
            missing.add('auditOutcomeKey($code)@$locale');
          }
        }
        for (final code in kAuditModules) {
          if (!AppStrings.translations[locale]!
              .containsKey(auditModuleKey(code))) {
            missing.add('auditModuleKey($code)@$locale');
          }
        }
        for (final code in kAuditActions) {
          if (!AppStrings.translations[locale]!
              .containsKey(auditActionKey(code))) {
            missing.add('auditActionKey($code)@$locale');
          }
        }
        if (!AppStrings.translations[locale]!
            .containsKey(auditModuleKey(null))) {
          missing.add('auditModuleKey(null)@$locale');
        }
      }
      expect(missing, isEmpty, reason: 'missing audit vocabulary: $missing');
    });
  });
}
