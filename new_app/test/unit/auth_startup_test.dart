// Cold start must ALWAYS begin unauthenticated.
//
// Root cause pinned here: `AuthNotifier` used to replay the token persisted
// in the keystore through `POST /api/v1/auth/verify-token` and adopt that
// session, so launching the Windows app dropped straight into the previous
// user's shell with no PIN. These tests hold the contract:
//   * a saved access token never authenticates at startup;
//   * a saved refresh token never authenticates either;
//   * the stale session is dropped (keystore + shared client) during boot;
//   * only a `POST /auth/login` with the user's PIN establishes a session;
//   * a wrong PIN leaves the app unauthenticated with nothing persisted;
//   * logout clears the session and returns to unauthenticated.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class _FakeStorage extends SecureCredentialStorage {
  _FakeStorage({
    this.accessToken,
    this.refreshToken,
    this.permissions = const [],
  });

  String? accessToken;
  String? refreshToken;
  List<String> permissions;
  int clearAllCalls = 0;

  @override
  Future<bool> hasToken() async =>
      accessToken != null && accessToken!.isNotEmpty;

  @override
  Future<String?> readToken() async => accessToken;

  @override
  Future<void> saveToken(String token) async => accessToken = token;

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async =>
      this.permissions = permissions;

  @override
  Future<List<String>> readUserRoles() async => const [];

  @override
  Future<List<String>> readUserPermissions() async => permissions;

  @override
  Future<void> saveDeviceToken(String token) async {}

  @override
  Future<String?> readDeviceToken() async => 'device-token';

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
    accessToken = null;
    permissions = const [];
  }
}

const _setupPath = '/api/v1/auth/setup/check';
const _loginPath = '/api/v1/auth/login';
const _logoutPath = '/api/v1/auth/logout';
const _verifyPath = '/api/v1/auth/verify-token';
const _mePath = '/api/v1/auth/me';

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDio dio;
  late ApiClient client;

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(_setupPath))
        .thenAnswer((_) async => _ok(_setupPath, {'setup_needed': false}));
    client = ApiClient(dio: dio);
  });

  /// Boot the notifier and wait for `_initialize` to settle.
  Future<AuthNotifier> boot(_FakeStorage storage) async {
    final notifier = AuthNotifier(client, storage);
    addTearDown(notifier.dispose);
    for (var i = 0; i < 100 && notifier.state.status == AuthStatus.checking; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return notifier;
  }

  group('startup is always unauthenticated', () {
    test('a persisted access token never authenticates', () async {
      final storage = _FakeStorage(
        accessToken: 'tok-saved',
        permissions: const ['pos_sale', 'user_manage'],
      );

      final auth = await boot(storage);

      expect(auth.state.status, AuthStatus.unauthenticated);
      expect(auth.state.user, isNull);
      // No session is proven with a stored credential…
      verifyNever(() => dio.post(_verifyPath, data: any(named: 'data')));
      verifyNever(() => dio.get(_mePath));
      // …and the stale one is dropped rather than kept for a later bypass.
      expect(storage.accessToken, isNull);
      expect(storage.permissions, isEmpty);
      expect(storage.clearAllCalls, 1);
      expect(client.hasToken, isFalse);
    });

    test('a persisted refresh token never authenticates either', () async {
      final storage = _FakeStorage(
        accessToken: 'tok-saved',
        refreshToken: 'refresh-saved',
      );

      final auth = await boot(storage);

      expect(auth.state.status, AuthStatus.unauthenticated);
      expect(auth.state.user, isNull);
      verifyNever(() => dio.post(_verifyPath, data: any(named: 'data')));
      verifyNever(() => dio.post(_loginPath, data: any(named: 'data')));
      expect(client.hasToken, isFalse);
      expect(storage.accessToken, isNull);
    });

    test('the device pairing token survives a cold start', () async {
      final storage = _FakeStorage(accessToken: 'tok-saved');

      await boot(storage);

      expect(await storage.readDeviceToken(), 'device-token',
          reason: 'device identity is not the user session');
    });

    test('a backend that still needs its first admin reports setupRequired',
        () async {
      when(() => dio.get(_setupPath))
          .thenAnswer((_) async => _ok(_setupPath, {'setup_needed': true}));

      final auth = await boot(_FakeStorage(accessToken: 'tok-saved'));

      expect(auth.state.status, AuthStatus.setupRequired);
    });

    test('an unreachable backend settles on login, never on a session',
        () async {
      when(() => dio.get(_setupPath)).thenThrow(
        DioException.connectionError(
          requestOptions: RequestOptions(path: _setupPath),
          reason: 'service down',
        ),
      );

      final auth = await boot(_FakeStorage(accessToken: 'tok-saved'));

      expect(auth.state.status, AuthStatus.unauthenticated);
      expect(client.hasToken, isFalse);
    });
  });

  group('login is the only way in', () {
    void stubLogin({required String pin, bool valid = true}) {
      when(() => dio.post(_loginPath, data: any(named: 'data')))
          .thenAnswer((invocation) async {
        final body = invocation.namedArguments[#data] as Map;
        if (body['pin'] != pin || !valid) {
          throw DioException(
            requestOptions: RequestOptions(path: _loginPath),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: _loginPath),
              statusCode: 401,
              data: {
                'error': {'code': 'INVALID_PIN', 'message': 'Invalid PIN'},
              },
            ),
          );
        }
        return _ok(_loginPath, {
          'access_token': 'tok-fresh',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
          },
        });
      });
      when(() => dio.get(_mePath)).thenAnswer(
        (_) async => _ok(_mePath, {
          'id': 'u1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': [
            {'name': 'admin'},
          ],
          'permissions': ['user_manage', 'pos_sale'],
        }),
      );
    }

    test('the correct PIN establishes the session and keeps its permissions',
        () async {
      stubLogin(pin: '1234');
      final storage = _FakeStorage();
      final auth = await boot(storage);

      await auth.login(userId: 'u1', pin: '1234');

      expect(auth.state.status, AuthStatus.authenticated);
      expect(auth.state.user?.fullName, 'Admin');
      expect(auth.state.user?.roles, contains('admin'));
      expect(auth.state.user?.permissions,
          containsAll(<String>['user_manage', 'pos_sale']));
      expect(client.hasToken, isTrue);
      expect(storage.accessToken, 'tok-fresh');
    });

    test('a wrong PIN is refused and nothing is persisted', () async {
      stubLogin(pin: '1234');
      final storage = _FakeStorage();
      final auth = await boot(storage);

      await auth.login(userId: 'u1', pin: '9999');

      expect(auth.state.status, isNot(AuthStatus.authenticated));
      expect(auth.state.user, isNull);
      expect(storage.accessToken, isNull);
      expect(client.hasToken, isFalse);
    });

    test('logout clears the session and returns to unauthenticated', () async {
      stubLogin(pin: '1234');
      when(() => dio.post(_logoutPath, data: any(named: 'data')))
          .thenAnswer((_) async => _ok(_logoutPath, {'message': 'ok'}));
      final storage = _FakeStorage();
      final auth = await boot(storage);
      await auth.login(userId: 'u1', pin: '1234');
      expect(auth.state.status, AuthStatus.authenticated);

      await auth.logout();

      expect(auth.state.status, AuthStatus.unauthenticated);
      expect(auth.state.user, isNull);
      expect(storage.accessToken, isNull);
      expect(client.hasToken, isFalse);
    });
  });
}
