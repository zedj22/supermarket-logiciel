import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureCredentialStorage {
  static const _keyToken = 'auth_access_token';
  static const _keyUserId = 'auth_user_id';
  static const _keyUserName = 'auth_user_name';
  static const _keyUserRoles = 'auth_user_roles';
  static const _keyUserPermissions = 'auth_user_permissions';

  final FlutterSecureStorage _storage;

  SecureCredentialStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<void> saveToken(String token) async {
    await _storage.write(key: _keyToken, value: token);
  }

  Future<String?> readToken() async {
    return _storage.read(key: _keyToken);
  }

  Future<void> saveUserId(String userId) async {
    await _storage.write(key: _keyUserId, value: userId);
  }

  Future<String?> readUserId() async {
    return _storage.read(key: _keyUserId);
  }

  Future<void> saveUserName(String name) async {
    await _storage.write(key: _keyUserName, value: name);
  }

  Future<String?> readUserName() async {
    return _storage.read(key: _keyUserName);
  }

  Future<void> saveUserRoles(List<String> roles) async {
    await _storage.write(key: _keyUserRoles, value: roles.join(','));
  }

  Future<List<String>> readUserRoles() async {
    final raw = await _storage.read(key: _keyUserRoles);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',');
  }

  Future<void> saveUserPermissions(List<String> permissions) async {
    await _storage.write(
        key: _keyUserPermissions, value: permissions.join(','));
  }

  Future<List<String>> readUserPermissions() async {
    final raw = await _storage.read(key: _keyUserPermissions);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',');
  }

  Future<void> clearAll() async {
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyUserId);
    await _storage.delete(key: _keyUserName);
    await _storage.delete(key: _keyUserRoles);
    await _storage.delete(key: _keyUserPermissions);
  }

  Future<bool> hasToken() async {
    final token = await readToken();
    return token != null && token.isNotEmpty;
  }
}
