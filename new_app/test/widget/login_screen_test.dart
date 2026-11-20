import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class NoSessionCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => false;

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clearAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void stubBootRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    // Cold start drops the persisted session through the shared client.
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/setup/check'),
        data: {'setup_needed': false},
        statusCode: 200,
      ),
    );
  }

  Widget buildApp(MockDio dio) {
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(NoSessionCredentialStorage()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: LoginScreen()),
      ),
    );
  }

  testWidgets(
      'login screen loads users from public endpoint and never calls GET /api/v1/users',
      (tester) async {
    final dio = MockDio();
    stubBootRequests(dio);
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
        data: {
          'items': [
            {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
            },
          ],
          'total': 1,
        },
        statusCode: 200,
      ),
    );

    await tester.pumpWidget(buildApp(dio));
    await tester.pumpAndSettle();

    expect(find.text('Admin'), findsOneWidget);
    verify(() => dio.get('/api/v1/auth/login-users')).called(1);
    verifyNever(() => dio.get('/api/v1/users'));
  });

  testWidgets('login user discovery failure shows backend error, not connection error',
      (tester) async {
    final dio = MockDio();
    stubBootRequests(dio);
    when(() => dio.get('/api/v1/auth/login-users')).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
          statusCode: 500,
          data: {
            'error': {'code': 'INTERNAL_ERROR', 'message': 'Backend exploded'},
          },
        ),
      ),
    );

    await tester.pumpWidget(buildApp(dio));
    await tester.pumpAndSettle();

    expect(find.text('Backend exploded'), findsOneWidget);
    verifyNever(() => dio.get('/api/v1/users'));
  });
}