class AuthUser {
  final String id;
  final String fullName;
  final bool isActive;
  final List<String> roles;
  final List<String> permissions;

  const AuthUser({
    required this.id,
    required this.fullName,
    required this.isActive,
    this.roles = const [],
    this.permissions = const [],
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final roleList = (json['roles'] as List<dynamic>? ?? const []);
    final roles = <String>[];
    final nestedPermissions = <String>{};
    for (final r in roleList) {
      if (r is! Map) continue;
      final name = r['name'];
      if (name is String) roles.add(name);
      final perms = r['permissions'];
      if (perms is List) {
        for (final p in perms) {
          if (p is String) {
            nestedPermissions.add(p);
          } else if (p is Map && p['scope'] is String) {
            nestedPermissions.add(p['scope'] as String);
          }
        }
      }
    }
    // Login/verify responses (UserResponse) have NO top-level permissions —
    // only /auth/me does. Scopes arrive nested under roles[].permissions[].
    final topLevel = (json['permissions'] as List<dynamic>? ?? const [])
        .whereType<String>();
    return AuthUser(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      isActive: json['is_active'] as bool? ?? true,
      roles: roles,
      permissions: {...topLevel, ...nestedPermissions}.toList(),
    );
  }

  bool hasPermission(String scope) => permissions.contains(scope);
  bool get isAdmin => roles.contains('admin');
  bool get isManager => roles.contains('manager');
  bool get isCashier => roles.contains('cashier');
}

class LoginResult {
  final String accessToken;
  final int expiresIn;
  final AuthUser user;

  const LoginResult({
    required this.accessToken,
    required this.expiresIn,
    required this.user,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      accessToken: json['access_token'] as String,
      expiresIn: json['expires_in'] as int,
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}

class SetupResult {
  final String userId;
  final String name;

  const SetupResult({required this.userId, required this.name});

  factory SetupResult.fromJson(Map<String, dynamic> json) {
    return SetupResult(
      userId: json['user_id'] as String,
      name: json['name'] as String,
    );
  }
}

class UserListItem {
  final String id;
  final String fullName;
  final bool isActive;
  final List<String> roleNames;

  const UserListItem({
    required this.id,
    required this.fullName,
    required this.isActive,
    this.roleNames = const [],
  });

  factory UserListItem.fromJson(Map<String, dynamic> json) {
    return UserListItem(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      isActive: json['is_active'] as bool? ?? true,
      roleNames: (json['roles'] as List<dynamic>?)
              ?.map((r) => r['name'] as String)
              .toList() ??
          [],
    );
  }
}
