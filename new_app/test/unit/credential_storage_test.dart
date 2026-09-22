import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureCredentialStorage', () {
    test('can be instantiated', () {
      final storage = SecureCredentialStorage();
      expect(storage, isNotNull);
      expect(storage, isA<SecureCredentialStorage>());
    });

    test('has correct API methods', () {
      final storage = SecureCredentialStorage();
      expect(storage.saveToken, isA<Function>());
      expect(storage.readToken, isA<Function>());
      expect(storage.saveUserId, isA<Function>());
      expect(storage.readUserId, isA<Function>());
      expect(storage.saveUserName, isA<Function>());
      expect(storage.readUserName, isA<Function>());
      expect(storage.saveUserRoles, isA<Function>());
      expect(storage.readUserRoles, isA<Function>());
      expect(storage.saveUserPermissions, isA<Function>());
      expect(storage.readUserPermissions, isA<Function>());
      expect(storage.clearAll, isA<Function>());
      expect(storage.hasToken, isA<Function>());
    });
  });
}
