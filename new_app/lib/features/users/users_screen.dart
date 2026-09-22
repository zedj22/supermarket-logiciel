import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_models.dart';
import '../auth/auth_provider.dart';

class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  List<UserListItem> _users = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final apiClient = ref.read(apiClientProvider);
      final response = await apiClient.dio.get('/api/v1/users');
      final items = (response.data['items'] as List<dynamic>)
          .map((u) => UserListItem.fromJson(u as Map<String, dynamic>))
          .toList();
      setState(() {
        _users = items;
        _loading = false;
      });
    } on DioException catch (_) {
      setState(() {
        _loading = false;
        _error = AppStrings.t(
          'network_error_retry',
          ref.read(localeProvider).flutterLocale.languageCode,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = ref.watch(localeProvider);
    final loc = locale.flutterLocale.languageCode;
    final isAdmin = ref.watch(isAdminProvider);

    if (!isAdmin) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('user_list', loc),
                style: theme.textTheme.headlineSmall,
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _showCreateDialog(context),
                icon: const Icon(Icons.person_add),
                label: Text(AppStrings.t('create_user', loc)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadUsers,
                              child: Text(AppStrings.t('retry', loc)),
                            ),
                          ],
                        ),
                      )
                    : _buildUserList(theme, loc),
          ),
        ],
      ),
    );
  }

  Widget _buildUserList(ThemeData theme, String loc) {
    return ListView.builder(
      itemCount: _users.length,
      itemBuilder: (context, index) {
        final user = _users[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: user.isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
              child: Text(
                user.fullName.isNotEmpty
                    ? user.fullName[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            title: Text(user.fullName),
            subtitle: Text(user.roleNames.join(', ')),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: user.isActive,
                  onChanged: (val) => _toggleActive(user, val),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) =>
                      _handleAction(action, user, context),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(AppStrings.t('edit', loc)),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(AppStrings.t('delete', loc)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleActive(UserListItem user, bool active) async {
    try {
      final apiClient = ref.read(apiClientProvider);
      await apiClient.dio.put(
        '/api/v1/users/${user.id}',
        data: {'is_active': active},
      );
      _loadUsers();
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.response?.data['message'] ?? 'Error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _handleAction(String action, UserListItem user, BuildContext ctx) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    switch (action) {
      case 'delete':
        showDialog(
          context: ctx,
          builder: (ctx) => AlertDialog(
            title: Text(AppStrings.t('delete', loc)),
            content: Text(AppStrings.t('delete_user_confirm', loc)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel', loc)),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _deleteUser(user);
                },
                child: Text(AppStrings.t('confirm', loc)),
              ),
            ],
          ),
        );
        break;
    }
  }

  Future<void> _deleteUser(UserListItem user) async {
    try {
      final apiClient = ref.read(apiClientProvider);
      await apiClient.dio.delete('/api/v1/users/${user.id}');
      _loadUsers();
    } on DioException catch (e) {
      if (mounted) {
        final loc = ref.read(localeProvider).flutterLocale.languageCode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data['message'] ??
                  AppStrings.t('error', loc),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _showCreateDialog(BuildContext ctx) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final nameController = TextEditingController();
    final pinController = TextEditingController();
    final pinConfirmController = TextEditingController();
    String selectedRole = 'cashier';

    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.t('create_user', loc)),
          content: SizedBox(
            width: 350,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('name', loc),
                    prefixIcon: const Icon(Icons.person),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('pin', loc),
                    prefixIcon: const Icon(Icons.lock),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinConfirmController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('confirm_pin', loc),
                    prefixIcon: const Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('role', loc),
                    prefixIcon: const Icon(Icons.admin_panel_settings),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'cashier',
                      child: Text(AppStrings.t('cashier', loc)),
                    ),
                    DropdownMenuItem(
                      value: 'manager',
                      child: Text(AppStrings.t('manager', loc)),
                    ),
                    DropdownMenuItem(
                      value: 'admin',
                      child: Text(AppStrings.t('admin', loc)),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => selectedRole = val);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.t('cancel', loc)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) return;
                if (pinController.text != pinConfirmController.text) return;
                Navigator.pop(ctx);
                await _createUser(
                  nameController.text.trim(),
                  pinController.text,
                  selectedRole,
                );
              },
              child: Text(AppStrings.t('create_user', loc)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createUser(
      String name, String pin, String role) async {
    try {
      final apiClient = ref.read(apiClientProvider);
      await apiClient.dio.post(
        '/api/v1/users',
        data: {
          'name': name,
          'pin': pin,
          'role_names': [role],
        },
      );
      _loadUsers();
    } on DioException catch (e) {
      if (mounted) {
        final loc = ref.read(localeProvider).flutterLocale.languageCode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.response?.data['message'] ??
                  AppStrings.t('error', loc),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
}
