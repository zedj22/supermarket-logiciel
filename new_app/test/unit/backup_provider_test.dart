// Phase 17 (§17.2) — BackupNotifier contract.
//
// A backup feature can lie in two damaging ways: announcing a backup that
// was never written, or announcing a restore that the server refused.
// Both are pinned down here — `create()` / `restore()` return `true` only
// on a 2xx, and every failure keeps the previous catalogue on screen.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/backup_models.dart';
import 'package:supermarket_pos/features/settings/backup_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const _serverError = <String, Object>{
  'error': <String, Object>{'code': 'internal_error', 'message': 'boom'},
};

const _backupJson = <String, Object>{
  'id': 3,
  'filename': 'backup_20261003_153000.sql',
  'size': 4096,
  'created_at': '2026-10-03T15:30:52+00:00',
};

Map<String, Object> _listing(List<Map<String, Object>> items) => <String, Object>{
      'items': items,
      'count': items.length,
    };

/// Records the requests that matter; a `null` status means "succeed".
///
/// A failure body of `{}` (no `error.message`) is what lets a test reach
/// the status-code fallbacks — the real backend always sends a message, but
/// a proxy/502 in front of it does not.
FakeJsonAdapter _adapter({
  List<Map<String, Object>> items = const <Map<String, Object>>[_backupJson],
  int? loadStatus,
  int? createStatus,
  int? restoreStatus,
  bool restoreWithMessage = true,
  String restoreMessage = 'This backup has been modified since it was '
      'created and will not be restored.',
}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (options.method == 'POST' && path == BackupInfo.backupsPath) {
      if (createStatus != null) {
        return (
          statusCode: createStatus,
          body: createStatus == 503
              ? const <String, Object>{}
              : _serverError,
        );
      }
      return (statusCode: 201, body: _backupJson);
    }
    if (options.method == 'POST' && path.endsWith('/restore')) {
      if (restoreStatus != null) {
        return (
          statusCode: restoreStatus,
          body: restoreWithMessage
              ? <String, Object>{
                  'error': <String, Object>{
                    'code': 'BUSINESS_RULE_ERROR',
                    'message': restoreMessage,
                  },
                }
              // A proxy or an unhandled 404 answers with no message: the
              // client has to fall back to the localized status text.
              : const <String, Object>{},
        );
      }
      return (
        statusCode: 200,
        body: <String, Object>{'restored': true, 'backup': _backupJson},
      );
    }
    if (loadStatus != null) {
      return (
        statusCode: loadStatus,
        body: loadStatus == 503 ? const <String, Object>{} : _serverError,
      );
    }
    return (statusCode: 200, body: _listing(items));
  });
}

BackupNotifier _notifier(FakeJsonAdapter adapter) =>
    BackupNotifier(fakeDio(adapter), () => 'en');

void main() {
  group('BackupNotifier.load', () {
    test('GETs /backups and stores the parsed catalogue', () async {
      final adapter = _adapter();
      final notifier = _notifier(adapter);

      await notifier.load();

      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path, BackupInfo.backupsPath);

      final state = notifier.state;
      expect(state.status, BackupStatus.loaded);
      expect(state.items.single.filename, 'backup_20261003_153000.sql');
      expect(state.errorMessage, isNull);
    });

    test('an empty catalogue is a loaded state, not an error', () async {
      final notifier = _notifier(_adapter(items: const []));

      await notifier.load();

      expect(notifier.state.status, BackupStatus.loaded);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.hasError, isFalse);
    });

    test('a failed load is reported and keeps the previous list', () async {
      var fail = false;
      final adapter = FakeJsonAdapter((options) async {
        if (fail) return (statusCode: 500, body: _serverError);
        return (statusCode: 200, body: _listing(const <Map<String, Object>>[
          _backupJson,
        ]));
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      fail = true;
      await notifier.load();

      expect(notifier.state.status, BackupStatus.error);
      expect(notifier.state.errorMessage, 'boom');
      expect(notifier.state.items, hasLength(1),
          reason: 'a blip must not empty the screen');
    });

    test('clearError returns to the list when there is one', () async {
      final adapter = _adapter(loadStatus: 500);
      final notifier = _notifier(adapter);
      await notifier.load();
      expect(notifier.state.hasError, isTrue);

      notifier.clearError();
      expect(notifier.state.status, BackupStatus.idle,
          reason: 'nothing loaded yet, so the retry path applies');
    });
  });

  group('BackupNotifier.create', () {
    test('POSTs and re-reads the catalogue, returning true', () async {
      final adapter = _adapter();
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.create();

      expect(ok, isTrue);
      final post = adapter.requests[1];
      expect(post.method, 'POST');
      expect(post.path, BackupInfo.backupsPath);
      expect(adapter.requests[2].method, 'GET');
      expect(notifier.state.status, BackupStatus.loaded);
      expect(notifier.state.busy, isFalse);
      expect(notifier.state.errorMessage, isNull);
    });

    test('a failed create returns false and never claims success', () async {
      final adapter = _adapter(createStatus: 500);
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.create();

      expect(ok, isFalse, reason: 'an unaudited/failed dump is not a backup');
      final state = notifier.state;
      expect(state.status, BackupStatus.error);
      expect(state.errorMessage, 'boom');
      expect(state.busy, isFalse);
      expect(state.items, hasLength(1));
    });
  });

  group('BackupNotifier.restore', () {
    test('posts to /backups/{id}/restore and returns true', () async {
      final adapter = _adapter();
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.restore(3);

      expect(ok, isTrue);
      final post = adapter.requests[1];
      expect(post.method, 'POST');
      expect(post.path, '/api/v1/backups/3/restore');
      expect(notifier.state.busy, isFalse);
      expect(notifier.state.pendingRestoreId, isNull);
      expect(notifier.state.errorMessage, isNull);
    });

    test('a refused restore (422) is reported as a failure', () async {
      final adapter = _adapter(restoreStatus: 422);
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.restore(3);

      expect(ok, isFalse,
          reason: 'a rejected restore must never be announced as done');
      expect(notifier.state.status, BackupStatus.error);
      expect(notifier.state.errorMessage, 'This backup has been modified '
          'since it was created and will not be restored.');
      expect(adapter.requests, hasLength(2),
          reason: 'no catalogue refresh after a refused restore');
    });

    test('a 404 with a backend message shows that message', () async {
      final adapter = _adapter(
        restoreStatus: 404,
        restoreMessage: 'backup 404 does not exist',
      );
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.restore(404);

      expect(ok, isFalse);
      expect(notifier.state.errorMessage, 'backup 404 does not exist');
    });

    test('a message-less 404 falls back to the localized text', () async {
      final adapter = _adapter(restoreStatus: 404, restoreWithMessage: false);
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.restore(404);

      expect(ok, isFalse);
      expect(notifier.state.errorMessage, AppStrings.t('not_found', 'en'));
    });

    test('missing server-side tools surface the 503 message', () async {
      // 503 with no message body: a proxy or an unhandled tool error.
      final adapter = _adapter(createStatus: 503);
      final notifier = _notifier(adapter);
      await notifier.load();

      // 503 from create → the tooling message, not a generic retry hint.
      final ok = await notifier.create();

      expect(ok, isFalse);
      expect(
        notifier.state.errorMessage,
        AppStrings.t('backup_tools_missing', 'en'),
      );
    });

    test('a network failure during restore is still a failure', () async {
      var call = 0;
      final adapter = FakeJsonAdapter((options) async {
        call++;
        if (call == 1) {
          return (statusCode: 200, body: _listing(const <Map<String, Object>>[
            _backupJson,
          ]));
        }
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.restore(3);

      expect(ok, isFalse);
      expect(
        notifier.state.errorMessage,
        AppStrings.t('network_error_retry', 'en'),
      );
      expect(notifier.state.busy, isFalse);
      expect(notifier.state.pendingRestoreId, isNull);
    });
  });
}
