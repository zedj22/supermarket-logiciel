// Phase 17 (§17.1) — SettingsNotifier contract.
//
// The load/save state machine is where a settings feature can lie to the
// operator ("Saved!" when nothing was written), so that is what this file
// pins down:
//
//  * `save()` returns `true` ONLY on a 2xx — a failed PUT keeps the previous
//    server snapshot, flags `failedDuringSave` and carries the message;
//  * `load()` failures never blank a form that was already populated;
//  * the request itself (verb, path, full body) is exactly what the
//    backend's contract requires.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/settings_models.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';

import '../helpers/settings_fake_adapter.dart';

SettingsNotifier _notifier(FakeJsonAdapter adapter) {
  return SettingsNotifier(fakeDio(adapter), () => 'en');
}

const _serverErrorBody = <String, Object>{
  'error': <String, Object>{'code': 'internal_error', 'message': 'boom'},
};

StoreSettings _seed() => StoreSettings.fromJson(kDefaultSettingsJson);

void main() {
  group('SettingsNotifier.load', () {
    test('GETs /settings and stores the parsed payload', () async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 200, body: kDefaultSettingsJson),
      );
      final notifier = _notifier(adapter);

      await notifier.load();

      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path, '/api/v1/settings');

      final state = notifier.state;
      expect(state.status, SettingsStatus.loaded);
      expect(state.settings?.storeName, 'Supermarket Pro');
      expect(state.hasError, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('a failed GET reports the error and leaves settings null', () async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 500, body: _serverErrorBody),
      );
      final notifier = _notifier(adapter);

      await notifier.load();

      final state = notifier.state;
      expect(state.status, SettingsStatus.error);
      expect(state.settings, isNull);
      expect(state.failedDuringSave, isFalse, reason: 'this was a load');
      expect(state.errorMessage, 'boom');
    });

    test('a network failure maps to the localized network message', () async {
      final adapter = FakeJsonAdapter((options) async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      final notifier = _notifier(adapter);

      await notifier.load();

      expect(notifier.state.status, SettingsStatus.error);
      expect(notifier.state.failedDuringSave, isFalse);
      expect(
        notifier.state.errorMessage,
        AppStrings.t('network_error_retry', 'en'),
      );
    });

    test('clearError is a no-op when there is no snapshot to return to',
        () async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 500, body: _serverErrorBody),
      );
      final notifier = _notifier(adapter);
      await notifier.load();

      notifier.clearError();

      expect(notifier.state.hasError, isTrue,
          reason: 'the screen still needs its retry action');
      expect(notifier.state.settings, isNull);
    });
  });

  group('SettingsNotifier.save', () {
    test('PUTs the full body and returns true on 2xx', () async {
      final adapter = FakeJsonAdapter((options) async {
        if (options.method == 'PUT') {
          return (
            statusCode: 200,
            body: Map<String, dynamic>.from(options.data as Map),
          );
        }
        return (statusCode: 200, body: kDefaultSettingsJson);
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      final next = _seed().copyWith(
        storeName: 'Boutique Centrale',
        allowDebt: false,
        lowStockThreshold: 3,
      );
      final ok = await notifier.save(next);

      expect(ok, isTrue);
      final request = adapter.requests.last;
      expect(request.method, 'PUT');
      expect(request.path, '/api/v1/settings');

      final body = Map<String, dynamic>.from(
        request.data as Map<String, dynamic>,
      );
      expect(body, hasLength(16));
      expect(body['store_name'], 'Boutique Centrale');
      expect(body['allow_debt'], isFalse);
      expect(body['low_stock_threshold'], 3);
      expect(body['default_paper'], '80mm');

      final state = notifier.state;
      expect(state.status, SettingsStatus.loaded);
      expect(state.settings?.storeName, 'Boutique Centrale');
      expect(state.hasError, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('save carries the Phase 6 company/fiscal fields and leaves the '
        'unrelated settings from the snapshot untouched', () async {
      final adapter = FakeJsonAdapter((options) async {
        if (options.method == 'PUT') {
          return (
            statusCode: 200,
            body: Map<String, dynamic>.from(options.data as Map),
          );
        }
        return (statusCode: 200, body: kDefaultSettingsJson);
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      final next = _seed().copyWith(
        storeWilaya: 'Alger',
        storeEmail: 'contact@store.dz',
        storeNif: '1600011111111111',
        storeNis: '1600022222222222',
        storeRc: '16/00-9999999 B 99',
        storeAi: '1600033333333333',
        storeRib: '0079 1111 2222 3333 44',
      );
      final ok = await notifier.save(next);

      expect(ok, isTrue);
      final body = Map<String, dynamic>.from(
        adapter.requests.last.data as Map<String, dynamic>,
      );
      expect(body['store_wilaya'], 'Alger');
      expect(body['store_email'], 'contact@store.dz');
      expect(body['store_nif'], '1600011111111111');
      expect(body['store_nis'], '1600022222222222');
      expect(body['store_rc'], '16/00-9999999 B 99');
      expect(body['store_ai'], '1600033333333333');
      expect(body['store_rib'], '0079 1111 2222 3333 44');
      // Unrelated settings ride along unchanged from the snapshot.
      expect(body['store_name'], 'Supermarket Pro');
      expect(body['invoice_footer'], '');
      expect(body['allow_debt'], isTrue);
      expect(body['default_paper'], '80mm');

      expect(notifier.state.settings?.storeWilaya, 'Alger');
      expect(notifier.state.settings?.storeRib, '0079 1111 2222 3333 44');
    });

    test(
        'a rejected PUT returns false, keeps the old snapshot and flags '
        'failedDuringSave — never reports success', () async {
      var call = 0;
      final adapter = FakeJsonAdapter((options) async {
        call++;
        if (call == 1) {
          return (statusCode: 200, body: kDefaultSettingsJson);
        }
        return (
          statusCode: 403,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'FORBIDDEN',
              'message': 'Insufficient permissions',
            },
          },
        );
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.save(_seed().copyWith(storeName: 'NOPE'));

      expect(ok, isFalse, reason: 'a failed save must not be reported as done');
      final state = notifier.state;
      expect(state.status, SettingsStatus.error);
      expect(state.failedDuringSave, isTrue);
      expect(state.errorMessage, 'Insufficient permissions');
      expect(
        state.settings?.storeName,
        'Supermarket Pro',
        reason: 'the stale-but-valid server snapshot must survive',
      );

      // ...and clearing that banner returns to a usable, loaded form.
      notifier.clearError();
      expect(notifier.state.status, SettingsStatus.loaded);
      expect(notifier.state.errorMessage, isNull);
      expect(notifier.state.failedDuringSave, isFalse);
      expect(notifier.state.settings?.storeName, 'Supermarket Pro');
    });

    test('a 422 surfaces the backend validation message', () async {
      var call = 0;
      final adapter = FakeJsonAdapter((options) async {
        call++;
        if (call == 1) {
          return (statusCode: 200, body: kDefaultSettingsJson);
        }
        return (
          statusCode: 422,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'VALIDATION_ERROR',
              'message': 'store_name must not be blank',
            },
          },
        );
      });
      final notifier = _notifier(adapter);
      await notifier.load();
      expect(notifier.state.settings?.storeName, 'Supermarket Pro');

      final ok = await notifier.save(_seed().copyWith(storeName: '   '));

      expect(ok, isFalse);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.method, 'PUT');
      expect(notifier.state.failedDuringSave, isTrue);
      expect(
        notifier.state.errorMessage,
        'store_name must not be blank',
      );
      expect(notifier.state.settings?.storeName, 'Supermarket Pro');
    });

    test('save before any load never invents a snapshot', () async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 500, body: _serverErrorBody),
      );
      final notifier = _notifier(adapter);

      final ok = await notifier.save(_seed());

      expect(ok, isFalse);
      expect(notifier.state.settings, isNull);
      expect(notifier.state.failedDuringSave, isTrue);
    });

    test('a network failure during save is still a failure', () async {
      var call = 0;
      final adapter = FakeJsonAdapter((options) async {
        call++;
        if (call == 1) {
          return (statusCode: 200, body: kDefaultSettingsJson);
        }
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      final notifier = _notifier(adapter);
      await notifier.load();

      final ok = await notifier.save(_seed().copyWith(storeName: 'X'));

      expect(ok, isFalse);
      expect(notifier.state.failedDuringSave, isTrue);
      expect(
        notifier.state.errorMessage,
        AppStrings.t('network_error_retry', 'en'),
      );
      expect(notifier.state.settings?.storeName, 'Supermarket Pro');
    });
  });
}
