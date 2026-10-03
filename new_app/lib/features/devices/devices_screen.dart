// Phase 16 — server-side device management (§23.1 devices screen).
//
// This is the store server's view: generate/rotate the 6-digit pairing
// code, approve or reject pending pairing requests, revoke registered
// devices. It never renders a device token — the token is delivered exactly
// once, to the paired client, on the pairing poll (§12.2).
//
// Permission-gated: every call needs `device_manage`, and the nav entry is
// gated the same way (§17).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';

/// Scope required by the backend for the whole `/api/v1/devices` admin API.
const String deviceManageScope = 'device_manage';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;
  String? _code;
  bool _codeBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _t(String key) =>
      AppStrings.t(key, ref.read(localeProvider).flutterLocale.languageCode);

  Dio get _dio => ref.read(apiClientProvider).dio;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _dio.get('/api/v1/devices');
      final data = response.data is Map
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
      final raw = data['items'];
      setState(() {
        _items = raw is List
            ? raw.whereType<Map<String, dynamic>>().toList()
            : const [];
        _loading = false;
      });
    } on DioException catch (e) {
      setState(() {
        _loading = false;
        _error = _messageOf(e);
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _error = AppStrings.t('api_error_retry', _loc());
      });
    }
  }

  String _loc() => ref.read(localeProvider).flutterLocale.languageCode;

  String _messageOf(DioException e) {
    final message = backendErrorMessage(e);
    if (message != null) return message;
    if (isConnectionError(e)) return AppStrings.t('network_error_retry', _loc());
    return AppStrings.t('api_error_retry', _loc());
  }

  Future<void> _requestCode() async {
    setState(() => _codeBusy = true);
    try {
      final response = await _dio.get('/api/v1/devices/pairing-code');
      final data = response.data is Map
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};
      setState(() {
        _code = data['code'] as String?;
        _codeBusy = false;
      });
    } on DioException catch (e) {
      setState(() {
        _codeBusy = false;
        _error = _messageOf(e);
      });
    }
  }

  Future<void> _post(String action, {String? deviceId}) async {
    final id = deviceId;
    if (id == null) return;
    try {
      await _dio.post(
        '/api/v1/devices/$id/$action',
        data: action == 'approve' ? null : <String, dynamic>{},
      );
      await _load();
    } on DioException catch (e) {
      if (mounted) {
        setState(() => _error = _messageOf(e));
      }
    }
  }

  Future<void> _approveWithConfirm(Map<String, dynamic> device) async {
    final confirmed = await _confirm(
      title: _t('lan_approve'),
      body: '${device['display_name'] ?? ''}\n${device['device_id'] ?? ''}',
      confirmLabel: _t('lan_approve'),
    );
    if (confirmed != true) return;
    await _post('approve', deviceId: device['device_id'] as String?);
  }

  Future<void> _revokeWithConfirm(Map<String, dynamic> device) async {
    final confirmed = await _confirm(
      title: _t('lan_revoke'),
      body: _t('lan_revoke_confirm'),
      confirmLabel: _t('lan_revoke'),
      destructive: true,
    );
    if (confirmed != true) return;
    await _post('revoke', deviceId: device['device_id'] as String?);
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.t('cancel', _loc())),
          ),
          FilledButton(
            key: Key('confirm-$confirmLabel'),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error)
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canManage = ref.watch(hasPermissionProvider(deviceManageScope));

    if (!canManage) {
      return Center(
        child: Text(AppStrings.t('permission_denied', loc)),
      );
    }

    final pending = _items.where((d) => d['status'] == 'pending').toList();
    final registered = _items.where((d) => d['status'] != 'pending').toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            AppStrings.t('lan_devices_title', loc),
            key: const Key('devices-title'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildCodeCard(loc),
          const SizedBox(height: 24),
          _sectionHeader(AppStrings.t('lan_pending_devices', loc)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                key: const Key('devices-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (pending.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                AppStrings.t('lan_no_pending', loc),
                key: const Key('no-pending'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else
            for (final device in pending) _pendingTile(device, loc),
          const SizedBox(height: 24),
          _sectionHeader(AppStrings.t('lan_registered_devices', loc)),
          if (registered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                AppStrings.t('lan_no_registered', loc),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else
            for (final device in registered) _registeredTile(device, loc),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            key: const Key('devices-refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(AppStrings.t('refresh', loc)),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _buildCodeCard(String loc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.t('lan_pairing_code', loc),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_code != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _code!,
                    key: const Key('pairing-code-value'),
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          letterSpacing: 8,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t('lan_pairing_code_hint', loc),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )
            else
              Text(
                AppStrings.t('lan_enter_pairing_code', loc),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('generate-code'),
              onPressed: _codeBusy ? null : _requestCode,
              icon: const Icon(Icons.password),
              label: Text(AppStrings.t('lan_generate_code', loc)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingTile(Map<String, dynamic> device, String loc) {
    return Card(
      key: Key('pending-${device['device_id']}'),
      child: ListTile(
        leading: const Icon(Icons.hourglass_top),
        title: Text('${device['display_name'] ?? ''}'),
        subtitle: Text(_subtitle(device, loc)),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('approve-${device['device_id']}'),
              tooltip: AppStrings.t('lan_approve', loc),
              icon: const Icon(Icons.check_circle, color: Colors.green),
              onPressed: () => _approveWithConfirm(device),
            ),
            IconButton(
              key: Key('reject-${device['device_id']}'),
              tooltip: AppStrings.t('lan_reject', loc),
              icon: const Icon(Icons.cancel, color: Colors.red),
              onPressed: () =>
                  _post('deny', deviceId: device['device_id'] as String?),
            ),
          ],
        ),
      ),
    );
  }

  Widget _registeredTile(Map<String, dynamic> device, String loc) {
    final status = (device['status'] as String?) ?? 'pending';
    final (color, key) = switch (status) {
      'approved' => (Colors.green, 'lan_status_approved'),
      'rejected' => (Colors.red, 'lan_status_rejected'),
      'revoked' => (Colors.red, 'lan_status_revoked'),
      _ => (Colors.amber, 'lan_status_pending'),
    };
    return Card(
      key: Key('device-${device['device_id']}'),
      child: ListTile(
        leading: Icon(Icons.circle, color: color, size: 14),
        title: Text('${device['display_name'] ?? ''}'),
        subtitle: Text(_subtitle(device, loc)),
        isThreeLine: true,
        trailing: status == 'approved'
            ? IconButton(
                key: Key('revoke-${device['device_id']}'),
                tooltip: AppStrings.t('lan_revoke', loc),
                icon: const Icon(Icons.block, color: Colors.red),
                onPressed: () => _revokeWithConfirm(device),
              )
            : Text(
                AppStrings.t(key, loc),
                style: TextStyle(color: color),
              ),
      ),
    );
  }

  String _subtitle(Map<String, dynamic> device, String loc) {
    final parts = <String>[
      '${device['device_id'] ?? ''}',
      AppStrings.t('lan_status_${device['status'] ?? 'pending'}', loc),
    ];
    final ip = device['last_ip'] ?? device['requested_ip'];
    if (ip != null) {
      parts.add('${AppStrings.t('lan_device_ip', loc)}: $ip');
    }
    final version = device['client_version'];
    if (version != null) {
      parts.add('${AppStrings.t('lan_device_version', loc)}: $version');
    }
    final seen = _formatTime(device['last_seen_at']);
    if (seen != null) {
      parts.add('${AppStrings.t('lan_device_last_seen', loc)}: $seen');
    }
    return parts.join('\n');
  }

  String? _formatTime(Object? raw) {
    if (raw is! String || raw.length < 16) return null;
    return raw.substring(0, 16).replaceFirst('T', ' ');
  }
}
