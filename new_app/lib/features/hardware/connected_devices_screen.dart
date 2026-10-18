// Objective 3 — hardware attached to the server PC (§Objective 3).
//
// Honest by construction: every list comes from
// `GET /api/v1/hardware/overview` (live Windows CIM/PnP discovery on the
// machine running the backend), the discovery warnings are shown
// verbatim, and a non-Windows server answers with empty lists plus a
// note — nothing is ever guessed or faked. The three test actions post
// to the hardware endpoints and report what Windows actually answered:
// `ok: false` in a 200 response is a failure, never a success.
//
// Not to be confused with `/api/v1/devices` (the LAN pairing registry):
// a paired tablet is a client; a barcode scanner plugged into the
// server is hardware.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../core/widgets/page_title.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/status_chip.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_toast.dart';
import '../devices/devices_screen.dart' show deviceManageScope;

class ConnectedDevicesScreen extends ConsumerStatefulWidget {
  const ConnectedDevicesScreen({super.key});

  @override
  ConsumerState<ConnectedDevicesScreen> createState() =>
      _ConnectedDevicesScreenState();
}

class _ConnectedDevicesScreenState
    extends ConsumerState<ConnectedDevicesScreen> {
  Map<String, dynamic>? _overview;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  /// Busy key of the test action in flight (`printer:HP`, ...).
  String? _testing;

  @override
  void initState() {
    super.initState();
    // Deferred so the permission gate decides first: a non-admin must
    // never trigger a discovery walk (§17).
    Future.microtask(() async {
      if (!ref.read(hasPermissionProvider(deviceManageScope))) return;
      await _load();
    });
  }

  String _loc() => ref.read(localeProvider).flutterLocale.languageCode;

  Dio get _dio => ref.read(apiClientProvider).dio;

  String _messageOf(DioException e) {
    final message = backendErrorMessage(e);
    if (message != null) return message;
    if (isConnectionError(e)) return AppStrings.t('network_error_retry', _loc());
    return AppStrings.t('api_error_retry', _loc());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _dio.get('/api/v1/hardware/overview');
      final data = response.data;
      if (!mounted) return;
      setState(() {
        _overview = data is Map<String, dynamic> ? data : null;
        _loading = false;
        if (data is! Map<String, dynamic>) {
          _error = AppStrings.t('api_error_retry', _loc());
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageOf(e);
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppStrings.t('api_error_retry', _loc());
      });
    }
  }

  Future<void> _refresh() async {
    final loc = _loc();
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final response = await _dio.post('/api/v1/hardware/overview/refresh');
      final data = response.data;
      if (!mounted) return;
      setState(() {
        _overview = data is Map<String, dynamic> ? data : null;
        _refreshing = false;
        if (data is! Map<String, dynamic>) {
          _error = AppStrings.t('api_error_retry', loc);
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _error = _messageOf(e);
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _error = AppStrings.t('api_error_retry', loc);
      });
    }
  }

  /// One test action; [successKey]/[failureKey] are decided by the
  /// HTTP answer AND the `ok` flag — a 200 with `ok: false` is a
  /// failure the operator has to see.
  Future<void> _testAction({
    required String path,
    required String deviceKey,
    required String successKey,
    required String failureKey,
    required String name,
  }) async {
    final loc = _loc();
    setState(() => _testing = deviceKey);
    try {
      final response =
          await _dio.post(path, data: <String, dynamic>{'name': name});
      final body = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : const <String, dynamic>{};
      final ok = body['ok'] == true;
      final message = body['message'];
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t(ok ? successKey : failureKey, loc),
        detail: message is String && message.isNotEmpty ? message : null,
        kind: ok ? PosToastKind.success : PosToastKind.error,
        key: const Key('hardware-test-toast'),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t(failureKey, loc),
        detail: _messageOf(e),
        kind: PosToastKind.error,
        key: const Key('hardware-test-toast'),
      );
    } on Object {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t(failureKey, loc),
        kind: PosToastKind.error,
        key: const Key('hardware-test-toast'),
      );
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  // -------------------------------------------------------------------------
  // Status maps (backend enums → localized keys)
  // -------------------------------------------------------------------------

  static (String, StatusTone) _printerStatus(String status) => switch (status) {
        'idle' => ('hw_status_idle', StatusTone.success),
        'printing' => ('hw_status_printing', StatusTone.info),
        'offline' => ('hw_status_offline', StatusTone.error),
        _ => ('hw_status_unknown', StatusTone.neutral),
      };

  static (String, StatusTone) _pnpStatus(String status) {
    final normalized = status.toUpperCase();
    if (normalized == 'OK') return ('hw_pnp_ok', StatusTone.success);
    if (normalized == 'ERROR') return ('hw_pnp_error', StatusTone.error);
    return ('hw_pnp_unknown', StatusTone.neutral);
  }

  // -------------------------------------------------------------------------
  // Data helpers
  // -------------------------------------------------------------------------

  List<Map<String, dynamic>> _list(String key) {
    final raw = _overview?[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  List<String> get _warnings {
    final raw = _overview?['warnings'];
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }

  static String _formatTime(Object? raw) {
    if (raw is! String || raw.length < 16) return '';
    return raw.substring(0, 16).replaceFirst('T', ' ');
  }

  // -------------------------------------------------------------------------
  // Tiles
  // -------------------------------------------------------------------------

  Widget _printerTile(Map<String, dynamic> printer, int index, String loc) {
    final theme = Theme.of(context);
    final name = '${printer['name'] ?? ''}';
    final driver = printer['driver_name'];
    final port = printer['port_name'];
    final isDefault = printer['is_default'] == true;
    final details = <String>[
      if (driver is String && driver.isNotEmpty) driver,
      if (port is String && port.isNotEmpty) port,
    ].join(' · ');
    final (String statusKey, StatusTone tone) =
        _printerStatus('${printer['status'] ?? ''}');
    final testing = _testing == 'printer:$name';

    return Card(
      key: Key('printer-$index'),
      child: ListTile(
        leading: Icon(
          Icons.print_outlined,
          color: isDefault ? theme.colorScheme.primary : null,
        ),
        title: Text(name, key: Key('printer-name-$index')),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDefault)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: StatusChip(
                  label: AppStrings.t('hw_default', loc),
                  tone: StatusTone.info,
                  dense: true,
                  testKey: Key('printer-default-$index'),
                ),
              ),
            if (details.isNotEmpty)
              Text(details, key: Key('printer-details-$index')),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusChip(
              label: AppStrings.t(statusKey, loc),
              tone: tone,
              dense: true,
              testKey: Key('printer-status-$index'),
            ),
            const SizedBox(width: 4),
            if (testing)
              Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    key: Key('printer-test-busy-$index'),
                  ),
                ),
              )
            else
              IconButton(
                key: Key('printer-test-$index'),
                tooltip: AppStrings.t('hw_test_page', loc),
                iconSize: 20,
                icon: const Icon(Icons.print),
                onPressed: () => _testAction(
                  path: '/api/v1/hardware/printers/test-page',
                  deviceKey: 'printer:$name',
                  successKey: 'hw_test_page_ok',
                  failureKey: 'hw_test_page_failed',
                  name: name,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pnpTile({
    required Map<String, dynamic> device,
    required int index,
    required String loc,
    required String keyPrefix,
    required IconData icon,
    String? testKey, // busy key, e.g. `scanner:$name` (null = no action)
    String? testPath,
    String? testTooltipKey,
    String? testSuccessKey,
    String? testFailureKey,
  }) {
    final name = '${device['name'] ?? ''}';
    final className = device['class_name'];
    final manufacturer = device['manufacturer'];
    final description = device['description'];
    final details = <String>[
      if (description is String && description.isNotEmpty) description,
      if (className is String && className.isNotEmpty) className,
      if (manufacturer is String && manufacturer.isNotEmpty) manufacturer,
    ].join(' · ');
    final (String statusKey, StatusTone tone) =
        _pnpStatus('${device['status'] ?? ''}');
    final busy = testKey != null && _testing == testKey;

    return Card(
      key: Key('$keyPrefix-$index'),
      child: ListTile(
        leading: Icon(icon),
        title: Text(name, key: Key('$keyPrefix-name-$index')),
        subtitle: details.isEmpty
            ? null
            : Text(details, key: Key('$keyPrefix-details-$index')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusChip(
              label: AppStrings.t(statusKey, loc),
              tone: tone,
              dense: true,
              testKey: Key('$keyPrefix-status-$index'),
            ),
            if (testPath != null) ...[
              const SizedBox(width: 4),
              if (busy)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      key: Key('$keyPrefix-test-busy-$index'),
                    ),
                  ),
                )
              else
                IconButton(
                  key: Key('$keyPrefix-test-$index'),
                  tooltip: AppStrings.t(
                    testTooltipKey ?? 'hw_test_scanner',
                    loc,
                  ),
                  iconSize: 20,
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => _testAction(
                    path: testPath,
                    deviceKey: testKey ?? '',
                    successKey: testSuccessKey ?? 'hw_pnp_ok',
                    failureKey: testFailureKey ?? 'hw_pnp_error',
                    name: name,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _category(
    String loc, {
    required String title,
    required String titleKey,
    required IconData icon,
    required int count,
    required String empty,
    required Key emptyKey,
    required List<Widget> children,
    String? note,
    Key? noteKey,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: title,
          titleKey: titleKey,
          icon: icon,
          trailing: StatusChip(
            label: '$count',
            tone: StatusTone.neutral,
            dense: true,
            testKey: Key('$titleKey-count'),
          ),
        ),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              empty,
              key: emptyKey,
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          ...children,
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              note,
              key: noteKey,
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Page
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canManage = ref.watch(hasPermissionProvider(deviceManageScope));

    if (!canManage) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          key: const Key('connected-devices-denied'),
        ),
      );
    }

    final printers = _list('printers');
    final scanners = _list('scanners');
    final usb = _list('usb_devices');
    final serial = _list('serial_ports');
    final warnings = _warnings;
    final platform = _overview?['platform'];
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              title: AppStrings.t('nav_connected_devices', loc),
              titleKey: const Key('connected-devices-title'),
              trailing: OutlinedButton.icon(
                key: const Key('hw-refresh'),
                onPressed:
                    (_refreshing || _loading) ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(AppStrings.t('hw_refresh', loc)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.t('hw_server_note', loc),
              key: const Key('connected-devices-note'),
              style: theme.textTheme.bodySmall,
            ),
            if (_overview != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (platform is String && platform.isNotEmpty)
                      StatusChip(
                        label: platform,
                        tone: StatusTone.neutral,
                        dense: true,
                        testKey: const Key('hw-platform'),
                      ),
                    Text(
                      '${AppStrings.t('date', loc)}: '
                      '${_formatTime(_overview?['scanned_at'])}',
                      key: const Key('hw-scanned-at'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  key: const Key('hw-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_loading && _overview == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_overview != null) ...[
              if (warnings.isNotEmpty)
                Card(
                  key: const Key('hw-warnings'),
                  color: AppColors.warning.withValues(alpha: 0.10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.warning_amber_outlined,
                                size: 18),
                            const SizedBox(width: 8),
                            Text(
                              AppStrings.t('hw_warnings_title', loc),
                              key: const Key('hw-warnings-title'),
                              style: theme.textTheme.titleSmall,
                            ),
                          ],
                        ),
                        for (final warning in warnings)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              warning,
                              key: Key('hw-warning-$warning'),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              _category(
                loc,
                title: AppStrings.t('hw_printers', loc),
                titleKey: 'hw_printers',
                icon: Icons.print_outlined,
                count: printers.length,
                empty: AppStrings.t('hw_none', loc),
                emptyKey: const Key('hw-printers-empty'),
                children: [
                  for (var i = 0; i < printers.length; i++)
                    _printerTile(printers[i], i, loc),
                ],
              ),
              _category(
                loc,
                title: AppStrings.t('hw_scanners', loc),
                titleKey: 'hw_scanners',
                icon: Icons.scanner_outlined,
                count: scanners.length,
                empty: AppStrings.t('hw_none', loc),
                emptyKey: const Key('hw-scanners-empty'),
                children: [
                  for (var i = 0; i < scanners.length; i++)
                    _pnpTile(
                      device: scanners[i],
                      index: i,
                      loc: loc,
                      keyPrefix: 'scanner',
                      icon: Icons.scanner_outlined,
                      testKey: 'scanner:${scanners[i]['name'] ?? ''}',
                      testPath: '/api/v1/hardware/scanners/test',
                      testTooltipKey: 'hw_test_scanner',
                      testSuccessKey: 'hw_scanner_ok',
                      testFailureKey: 'hw_scanner_failed',
                    ),
                ],
              ),
              _category(
                loc,
                title: AppStrings.t('hw_usb', loc),
                titleKey: 'hw_usb',
                icon: Icons.usb,
                count: usb.length,
                empty: AppStrings.t('hw_none', loc),
                emptyKey: const Key('hw-usb-empty'),
                children: [
                  for (var i = 0; i < usb.length; i++)
                    _pnpTile(
                      device: usb[i],
                      index: i,
                      loc: loc,
                      keyPrefix: 'usb',
                      icon: Icons.usb,
                    ),
                ],
              ),
              _category(
                loc,
                title: AppStrings.t('hw_serial', loc),
                titleKey: 'hw_serial',
                icon: Icons.developer_board_outlined,
                count: serial.length,
                empty: AppStrings.t('hw_none', loc),
                emptyKey: const Key('hw-serial-empty'),
                note: AppStrings.t('hw_port_probe_note', loc),
                noteKey: const Key('hw-serial-note'),
                children: [
                  for (var i = 0; i < serial.length; i++)
                    _pnpTile(
                      device: serial[i],
                      index: i,
                      loc: loc,
                      keyPrefix: 'serial',
                      icon: Icons.developer_board_outlined,
                      testKey: 'port:${serial[i]['name'] ?? ''}',
                      testPath: '/api/v1/hardware/serial-ports/test',
                      testTooltipKey: 'hw_test_port',
                      testSuccessKey: 'hw_port_ok',
                      testFailureKey: 'hw_port_failed',
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
