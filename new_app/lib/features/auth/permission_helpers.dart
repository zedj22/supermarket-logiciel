import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';
import 'auth_models.dart';

final hasPermissionProvider = Provider.family<bool, String>((ref, scope) {
  final user = ref.watch(currentUserProvider);
  return user?.hasPermission(scope) ?? false;
});

final hasAnyPermissionProvider =
    Provider.family<bool, List<String>>((ref, scopes) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  return scopes.any((s) => user.hasPermission(s));
});

extension AuthUserExtension on AuthUser {
  bool hasAnyPermission(List<String> scopes) {
    return scopes.any((s) => permissions.contains(s));
  }
}
