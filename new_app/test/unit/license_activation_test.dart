// Phase L2-C — the licensing status snapshot and the activation flow.
//
// Pins: defensive parsing of the additive `GET /api/v1/license/status`
// contract (never a guess from a malformed body), the localization key
// derived from every real backend failure code the activation endpoints
// can answer with, the exact endpoint calls of the flow (request →
// activate → status refresh), immediate snapshot refresh after a
// successful activation with the refresh being best-effort, and the rule
// that a failed attempt never touches a known snapshot (the backend
// writes nothing on failure — the client mirrors that).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/features/licensing/license_snapshot.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

const _statusPath = '/api/v1/license/status';
const _requestPath = '/api/v1/license/activation-request';
const _activatePath = '/api/v1/license/activate';

Map<String, dynamic> _trialStatusPayload({
  String mode = 'trial',
  String status = 'active',
}) =>
    <String, dynamic>{
      'mode': mode,
      'status': status,
      'license_type': null,
      'license_id': null,
      'activated_at': null,
      'trial': <String, dynamic>{
        'mode': 'trial',
        'status': status,
        'trial_active': status == 'active',
        'trial_expired': status != 'active',
        'first_launch_at': '2026-11-01T00:00:00Z',
        'expires_at': '2026-11-11T00:00:00Z',
        'observed_at': '2026-11-02T00:00:00Z',
        'remaining_seconds': 777600,
        'trial_days': 10,
      },
    };

Map<String, dynamic> _lifetimeStatusPayload() => <String, dynamic>{
      'mode': 'lifetime',
      'status': 'active',
      'license_type': 'lifetime',
      'license_id': 'LIC-42',
      'activated_at': '2026-11-03T09:30:00Z',
      'trial': <String, dynamic>{
        'mode': 'trial_expired',
        'status': 'expired',
        'trial_active': false,
        'trial_expired': true,
        'expires_at': '2026-11-01T00:00:00Z',
        'remaining_seconds': 0,
        'trial_days': 10,
      },
    };

Response<dynamic> _response(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

DioException _envelope(int status, String code) {
  return DioException(
    requestOptions: RequestOptions(path: _activatePath),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: _activatePath),
      statusCode: status,
      data: {
        'error': {
          'code': code,
          'message': 'backend text for $code',
          'details': <String, dynamic>{},
        },
      },
    ),
  );
}

DioException _network() => DioException.connectionError(
      requestOptions: RequestOptions(path: _activatePath),
      reason: 'connection refused',
    );

void main() {
  late MockDio dio;
  late ApiClient api;

  setUp(() {
    dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    api = ApiClient(dio: dio);
  });

  /// Controller with a directly observable snapshot slot (no provider
  /// container needed — the controller only talks to its callbacks).
  ActivationController controllerWith({
    LicenseSnapshot? initial,
  }) {
    LicenseSnapshot? current = initial;
    return ActivationController(
      api: api,
      setSnapshot: (snapshot) => current = snapshot,
      currentSnapshot: () => current,
    );
  }

  group('LicenseSnapshot parsing', () {
    test('a lifetime payload yields a verified lifetime snapshot', () {
      final snapshot = LicenseSnapshot.tryParse(_lifetimeStatusPayload());

      expect(snapshot, isNotNull);
      expect(snapshot!.isLifetime, isTrue);
      expect(snapshot.mode, LicenseSnapshotMode.lifetime);
      expect(snapshot.status, LicenseSnapshotStatus.active);
      expect(snapshot.licenseType, 'lifetime');
      expect(snapshot.licenseId, 'LIC-42');
      expect(snapshot.activatedAt, isNotNull);
      expect(snapshot.trial.trialExpired, isTrue,
          reason: 'the nested trial block stays truthful too');
    });

    test('a trial payload is never lifetime', () {
      final snapshot = LicenseSnapshot.tryParse(_trialStatusPayload());

      expect(snapshot, isNotNull);
      expect(snapshot!.isLifetime, isFalse);
      expect(snapshot.mode, LicenseSnapshotMode.trial);
      expect(snapshot.licenseId, isNull);
      expect(snapshot.trial.trialActive, isTrue);
    });

    test('a non-map payload yields null, never a guess', () {
      expect(LicenseSnapshot.tryParse(null), isNull);
      expect(LicenseSnapshot.tryParse('lifetime'), isNull);
      expect(LicenseSnapshot.tryParse(42), isNull);
      expect(LicenseSnapshot.tryParse(<Object>[1, 2]), isNull);
    });

    test('unrecognized enums degrade to unknown/unavailable', () {
      final snapshot = LicenseSnapshot.tryParse(<String, dynamic>{
        'mode': 'perpetual',
        'status': 'suspended',
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.mode, LicenseSnapshotMode.unknown);
      expect(snapshot.status, LicenseSnapshotStatus.unavailable);
      expect(snapshot.isLifetime, isFalse);
    });

    test('a missing trial block falls back to unknown, a bad time to null',
        () {
      final snapshot = LicenseSnapshot.tryParse(<String, dynamic>{
        'mode': 'lifetime',
        'status': 'active',
        'activated_at': 'not-a-timestamp',
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.activatedAt, isNull);
      expect(snapshot.trial.status, LicenseStatus.unavailable,
          reason: 'no trial info is unknown, never active');
    });
  });

  group('activationErrorKey', () {
    test('no response at all is a network error', () {
      expect(activationErrorKey(_network()),
          'license_activation_error_network');
    });

    test('the licensing codes keep their dedicated keys', () {
      expect(activationErrorKey(_envelope(403, 'license_invalid')),
          'license_error_invalid');
      expect(activationErrorKey(_envelope(403, 'license_invalid_key')),
          'license_error_invalid_key');
      expect(activationErrorKey(_envelope(403, 'license_bound_elsewhere')),
          'license_error_bound_elsewhere');
      expect(activationErrorKey(_envelope(503, 'license_status_unavailable')),
          'license_error_status_unavailable');
    });

    test('the request-shape and rate-limit codes map to activation keys',
        () {
      expect(activationErrorKey(_envelope(422, 'VALIDATION_ERROR')),
          'license_activation_error_validation');
      expect(activationErrorKey(_envelope(429, 'RATE_LIMITED')),
          'license_activation_error_rate_limited');
    });

    test('any other answered failure is a server error', () {
      expect(activationErrorKey(_envelope(500, 'INTERNAL_ERROR')),
          'license_activation_error_server');
      expect(activationErrorKey(_envelope(502, 'BAD_GATEWAY')),
          'license_activation_error_server');
    });
  });

  group('ActivationController.requestCode', () {
    test('posts the request endpoint and stores both returned codes',
        () async {
      when(() => dio.post(_requestPath)).thenAnswer(
        (_) async => _response(_requestPath, {
          'request_code': 'SMPr1.abc',
          'fingerprint_display_code': 'ABCD-EFGH',
        }),
      );

      final controller = controllerWith();
      await controller.requestCode();

      verify(() => dio.post(_requestPath)).called(1);
      final state = controller.state;
      expect(state.phase, ActivationPhase.idle);
      expect(state.requestCode, 'SMPr1.abc');
      expect(state.fingerprintDisplayCode, 'ABCD-EFGH');
      expect(state.hasRequest, isTrue);
      expect(state.errorMessageKey, isNull);
    });

    test('a network failure surfaces the network key and keeps no code',
        () async {
      when(() => dio.post(_requestPath)).thenThrow(_network());

      final controller = controllerWith();
      await controller.requestCode();

      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.errorMessageKey,
          'license_activation_error_network');
      expect(controller.state.hasRequest, isFalse);
    });

    test('a malformed success payload fails as a server error', () async {
      when(() => dio.post(_requestPath))
          .thenAnswer((_) async => _response(_requestPath, <String, dynamic>{}));

      final controller = controllerWith();
      await controller.requestCode();

      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.errorMessageKey,
          'license_activation_error_server');
    });

    test('a failure never erases an already generated request code',
        () async {
      when(() => dio.post(_requestPath)).thenAnswer(
        (_) async => _response(_requestPath, {
          'request_code': 'SMPr1.keep',
          'fingerprint_display_code': 'AAAA-BBBB',
        }),
      );
      final controller = controllerWith();
      await controller.requestCode();
      expect(controller.state.requestCode, 'SMPr1.keep');

      await controller.requestCode(); // second call now fails
      when(() => dio.post(_requestPath)).thenThrow(_network());
      await controller.requestCode();

      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.requestCode, 'SMPr1.keep',
          reason: 'the user must keep what to send to the owner');
    });
  });

  group('ActivationController.activate', () {
    test('a valid code posts the exact contract and refreshes the status',
        () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenAnswer((_) async => _response(_activatePath, _lifetimeStatusPayload()));
      when(() => dio.get(_statusPath))
          .thenAnswer((_) async => _response(_statusPath, _lifetimeStatusPayload()));

      final controller = controllerWith();
      final accepted = await controller.activate('  SMP1.abc  ');

      expect(accepted, isTrue);
      expect(controller.state.phase, ActivationPhase.success);
      final captured = verify(
        () => dio.post(_activatePath, data: captureAny(named: 'data')),
      ).captured;
      expect(captured, hasLength(1));
      expect(captured.single, {'activation_code': 'SMP1.abc'},
          reason: 'the trimmed code must be posted under the exact field');
      verify(() => dio.get(_statusPath)).called(1);
      expect(controller.snapshot?.isLifetime, isTrue,
          reason: 'the snapshot must show the new license immediately');
    });

    test('a failing status refresh keeps the activation-response snapshot',
        () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenAnswer((_) async => _response(_activatePath, _lifetimeStatusPayload()));
      when(() => dio.get(_statusPath)).thenThrow(_network());

      final controller = controllerWith();
      final accepted = await controller.activate('SMP1.abc');

      expect(accepted, isTrue);
      expect(controller.state.phase, ActivationPhase.success);
      expect(controller.snapshot?.isLifetime, isTrue,
          reason: 'the activate response alone already carried the status');
    });

    test('an invalid code fails without touching a known snapshot',
        () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_envelope(403, 'license_invalid'));

      final initial = LicenseSnapshot.tryParse(_lifetimeStatusPayload());
      final controller = controllerWith(initial: initial);
      final accepted = await controller.activate('SMP1.tampered');

      expect(accepted, isFalse);
      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.errorMessageKey, 'license_error_invalid');
      expect(controller.state.errorCode, 'license_invalid');
      expect(controller.snapshot, same(initial),
          reason: 'a failed attempt never downgrades a known license');
      verifyNever(() => dio.get(_statusPath));
    });

    test('wrong machine maps to its own key', () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_envelope(403, 'license_bound_elsewhere'));

      final controller = controllerWith();
      await controller.activate('SMP1.other');

      expect(controller.state.errorMessageKey, 'license_error_bound_elsewhere');
      expect(controller.state.errorCode, 'license_bound_elsewhere');
    });

    test('an unknown signing key maps to its own key', () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_envelope(403, 'license_invalid_key'));

      final controller = controllerWith();
      await controller.activate('SMP1.key');

      expect(controller.state.errorMessageKey, 'license_error_invalid_key');
      expect(controller.state.errorCode, 'license_invalid_key');
    });

    test('rate limiting maps to the activation rate-limit key', () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_envelope(429, 'RATE_LIMITED'));

      final controller = controllerWith();
      await controller.activate('SMP1.abc');

      expect(controller.state.errorMessageKey,
          'license_activation_error_rate_limited');
      expect(controller.state.errorCode, 'RATE_LIMITED');
    });

    test('an unreachable server maps to the network key', () async {
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_network());

      final controller = controllerWith();
      final accepted = await controller.activate('SMP1.abc');

      expect(accepted, isFalse);
      expect(controller.state.errorMessageKey,
          'license_activation_error_network');
      expect(controller.state.errorCode, isNull);
    });

    test('an empty code is rejected client-side without any request',
        () async {
      final controller = controllerWith();
      final accepted = await controller.activate('   ');

      expect(accepted, isFalse);
      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.errorMessageKey,
          'license_activation_error_empty');
      verifyNever(
          () => dio.post(_activatePath, data: any(named: 'data')));
    });

    test('a failure preserves an existing request code for a retry',
        () async {
      when(() => dio.post(_requestPath)).thenAnswer(
        (_) async => _response(_requestPath, {
          'request_code': 'SMPr1.retry',
          'fingerprint_display_code': 'CCCC-DDDD',
        }),
      );
      when(() => dio.post(_activatePath, data: any(named: 'data')))
          .thenThrow(_envelope(403, 'license_invalid'));

      final controller = controllerWith();
      await controller.requestCode();
      await controller.activate('SMP1.bad');

      expect(controller.state.phase, ActivationPhase.failure);
      expect(controller.state.requestCode, 'SMPr1.retry');
      expect(controller.state.fingerprintDisplayCode, 'CCCC-DDDD');
    });
  });

  group('ActivationController.ensureStatus', () {
    test('a successful fetch applies the parsed snapshot', () async {
      when(() => dio.get(_statusPath))
          .thenAnswer((_) async => _response(_statusPath, _lifetimeStatusPayload()));

      final controller = controllerWith();
      await controller.ensureStatus();

      expect(controller.snapshot?.isLifetime, isTrue);
    });

    test('an unreachable endpoint never throws and changes nothing',
        () async {
      when(() => dio.get(_statusPath)).thenThrow(_network());
      final initial = LicenseSnapshot.tryParse(_trialStatusPayload());
      final controller = controllerWith(initial: initial);

      await controller.ensureStatus();

      expect(controller.snapshot, same(initial));
    });
  });
}
