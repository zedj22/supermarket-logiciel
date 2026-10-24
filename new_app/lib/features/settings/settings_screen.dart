import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/raw_scanner/raw_scanner_poc.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme_mode.dart';
import '../../theme/theme_provider.dart';
import '../auth/permission_helpers.dart';
import '../loyalty/loyalty_models.dart';
import '../loyalty/loyalty_providers.dart';
import 'backup_models.dart';
import 'backup_provider.dart';
import 'pos_settings_provider.dart';
import 'raw_scanner_poc_panel.dart';
import 'scan_settings_provider.dart';
import 'settings_models.dart';
import 'settings_provider.dart';

/// Language + theme (Phase 6), the server-owned store settings
/// (Phase 17, §17.1) and the backup catalogue (Phase 17, §17.2).
///
/// The store section is rendered only for `settings_manage` — matching the
/// server, which rejects `PUT /api/v1/settings` for anyone else.  The
/// backup section is rendered only for `backup_restore` (admin), matching
/// the server's `POST /backups` / `POST /backups/{id}/restore`.  Both are
/// loaded lazily on first render, so a manager/cashier never issues a
/// settings or backup request at all.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const Map<AppLocale, String> languageNames = {
    AppLocale.ar: 'العربية',
    AppLocale.fr: 'Français',
    AppLocale.en: 'English',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final localeState = ref.watch(localeProvider);
    final themeState = ref.watch(themeProvider);
    final canManage = ref.watch(hasPermissionProvider(settingsManageScope));
    final canBackup = ref.watch(hasPermissionProvider(backupRestoreScope));

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('settings', loc),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.t('language', loc),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<AppLocale>(
                      key: const Key('settings-language-dropdown'),
                      initialValue: localeState.locale,
                      isExpanded: true,
                      items: [
                        for (final entry in languageNames.entries)
                          DropdownMenuItem<AppLocale>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          ref.read(localeProvider.notifier).setLocale(value);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.t('theme', loc),
                      style: theme.textTheme.titleMedium,
                    ),
                    RadioGroup<AppThemeMode>(
                      groupValue: themeState.mode,
                      onChanged: (value) {
                        if (value != null) {
                          ref.read(themeProvider.notifier).setTheme(value);
                        }
                      },
                      child: Column(
                        children: [
                          RadioListTile<AppThemeMode>(
                            key: const Key('settings-theme-dark'),
                            title: Text(AppStrings.t('dark_theme', loc)),
                            value: AppThemeMode.dark,
                          ),
                          RadioListTile<AppThemeMode>(
                            key: const Key('settings-theme-light'),
                            title: Text(AppStrings.t('light_theme', loc)),
                            value: AppThemeMode.light,
                          ),
                          RadioListTile<AppThemeMode>(
                            key: const Key('settings-theme-grey'),
                            title: Text(AppStrings.t('grey_theme', loc)),
                            value: AppThemeMode.grey,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _ScanActionsSection(),
            const SizedBox(height: 16),
            const _PosActionsSection(),
            // Scanner diagnostics (ScanDiagnosticsSection) is intentionally
            // NOT rendered here for now — the implementation, its panel
            // widget and its tests remain in scan_diagnostics_panel.dart
            // so the surface can be re-added unchanged later.
            if (kRawScannerPocEnabled) ...[
              const SizedBox(height: 16),
              const RawScannerPocSection(),
            ],
            if (canManage) ...[
              const SizedBox(height: 16),
              const _StoreSettingsSection(),
              const SizedBox(height: 16),
              const _CompanySettingsSection(),
              const SizedBox(height: 16),
              const _LoyaltySettingsSection(),
              const SizedBox(height: 16),
              const _StorageSection(),
            ],
            if (canBackup) ...[
              const SizedBox(height: 16),
              const _BackupSection(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Client-local scan-action toggles (POS): an unknown-barcode scan can
/// raise the existing Add Product form with the code prefilled, and an
/// out-of-stock scan can raise the existing Adjust Stock dialog. Both OFF
/// by default, both persisted in SharedPreferences
/// (scan_settings_provider.dart), both independent — deliberately NOT part
/// of the server-owned StoreSettings surface, so no backend, schema or
/// migration is involved. Like language/theme, every user sees them: they
/// are operator preferences, not store permissions.
class _ScanActionsSection extends ConsumerWidget {
  const _ScanActionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final settings = ref.watch(scanSettingsProvider);
    final notifier = ref.read(scanSettingsProvider.notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('settings_scan_actions', loc),
              style: theme.textTheme.titleMedium,
            ),
            SwitchListTile(
              key: const Key('settings-open-add-product-on-unknown-barcode'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                AppStrings.t('open_add_product_on_unknown_barcode', loc),
              ),
              subtitle: Text(
                AppStrings.t('open_add_product_on_unknown_barcode_desc', loc),
              ),
              value: settings.openAddProductOnUnknownBarcode,
              onChanged: (value) =>
                  notifier.setOpenAddProductOnUnknownBarcode(value),
            ),
            SwitchListTile(
              key: const Key('settings-open-adjust-stock-on-out-of-stock-scan'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                AppStrings.t('open_adjust_stock_on_out_of_stock_scan', loc),
              ),
              subtitle: Text(
                AppStrings.t('open_adjust_stock_on_out_of_stock_scan_desc', loc),
              ),
              value: settings.openAdjustStockOnOutOfStockScan,
              onChanged: (value) =>
                  notifier.setOpenAdjustStockOnOutOfStockScan(value),
            ),
          ],
        ),
      ),
    );
  }
}

/// Client-local POS operator preferences (SharedPreferences, same
/// synchronous-read pattern as the scan actions): currently the Quick Sale
/// with Space toggle. OFF by default — an installation that never saved a
/// value keeps the ordinary Space → payment-dialog flow. Deliberately not
/// part of the server-owned StoreSettings surface: a per-device operator
/// preference, no backend, schema or migration involved. Like
/// language/theme/scan actions, every user sees it.
class _PosActionsSection extends ConsumerWidget {
  const _PosActionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final settings = ref.watch(posSettingsProvider);
    final notifier = ref.read(posSettingsProvider.notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('settings_pos_actions', loc),
              style: theme.textTheme.titleMedium,
            ),
            SwitchListTile(
              key: const Key('settings-quick-sale-with-space'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                AppStrings.t('quick_sale_with_space', loc),
              ),
              subtitle: Text(
                AppStrings.t('quick_sale_with_space_desc', loc),
              ),
              value: settings.quickSaleWithSpace,
              onChanged: (value) => notifier.setQuickSaleWithSpace(value),
            ),
          ],
        ),
      ),
    );
  }
}

/// Server-owned store / receipt / POS settings (`GET` + `PUT /settings`).
///
/// Lifecycle notes:
/// * the `GET` is issued once, from `initState`, and never for a user
///   without `settings_manage`;
/// * the form is keyed on the loaded [StoreSettings] so a **successful**
///   save re-seeds it from the server response, while a **failed** save
///   leaves the operator's typing untouched;
/// * `saved` is only ever reported from the `save()` future's `true`.
class _StoreSettingsSection extends ConsumerStatefulWidget {
  const _StoreSettingsSection();

  @override
  ConsumerState<_StoreSettingsSection> createState() =>
      _StoreSettingsSectionState();
}

class _StoreSettingsSectionState extends ConsumerState<_StoreSettingsSection> {
  late final TextEditingController _storeName;
  late final TextEditingController _storePhone;
  late final TextEditingController _storeAddress;
  late final TextEditingController _invoiceFooter;
  late final TextEditingController _lowStockThreshold;

  bool _askBeforePrint = false;
  bool _autoPrintInvoice = false;
  bool _allowDebt = true;
  String _defaultPaper = '80mm';
  int _lowStock = 5;

  // Phase 6 company/fiscal identity: this section does not edit those
  // fields (the company section below does), but the PUT body is the whole
  // form, so the draft carries them — always as the last snapshot values,
  // which is exactly what the server already stores.  Re-seeded on every
  // snapshot change, so a save here never reverts a company value.
  String _storeWilaya = '';
  String _storeEmail = '';
  String _storeNif = '';
  String _storeNis = '';
  String _storeRc = '';
  String _storeAi = '';
  String _storeRib = '';

  @override
  void initState() {
    super.initState();
    _storeName = TextEditingController();
    _storePhone = TextEditingController();
    _storeAddress = TextEditingController();
    _invoiceFooter = TextEditingController();
    _lowStockThreshold = TextEditingController();
    final current = ref.read(settingsProvider).settings;
    if (current != null) _seedFrom(current);
    // Deferred out of initState: the provider must not be read while the
    // widget tree is still building.
    Future.microtask(_loadIfNeeded);
  }

  void _loadIfNeeded() {
    if (!mounted) return;
    final state = ref.read(settingsProvider);
    if (state.settings == null &&
        state.status != SettingsStatus.loading &&
        state.status != SettingsStatus.saving) {
      ref.read(settingsProvider.notifier).load();
    }
  }

  @override
  void dispose() {
    _storeName.dispose();
    _storePhone.dispose();
    _storeAddress.dispose();
    _invoiceFooter.dispose();
    _lowStockThreshold.dispose();
    super.dispose();
  }

  void _seedFrom(StoreSettings settings) {
    _storeName.text = settings.storeName;
    _storePhone.text = settings.storePhone;
    _storeAddress.text = settings.storeAddress;
    _invoiceFooter.text = settings.invoiceFooter;
    _lowStock = settings.lowStockThreshold;
    _lowStockThreshold.text = settings.lowStockThreshold.toString();
    _askBeforePrint = settings.askBeforePrint;
    _autoPrintInvoice = settings.autoPrintInvoice;
    _allowDebt = settings.allowDebt;
    _defaultPaper = settings.defaultPaper;
    _storeWilaya = settings.storeWilaya;
    _storeEmail = settings.storeEmail;
    _storeNif = settings.storeNif;
    _storeNis = settings.storeNis;
    _storeRc = settings.storeRc;
    _storeAi = settings.storeAi;
    _storeRib = settings.storeRib;
  }

  StoreSettings get _draft => StoreSettings(
        storeName: _storeName.text,
        storePhone: _storePhone.text,
        storeAddress: _storeAddress.text,
        invoiceFooter: _invoiceFooter.text,
        storeWilaya: _storeWilaya,
        storeEmail: _storeEmail,
        storeNif: _storeNif,
        storeNis: _storeNis,
        storeRc: _storeRc,
        storeAi: _storeAi,
        storeRib: _storeRib,
        defaultPaper: _defaultPaper,
        askBeforePrint: _askBeforePrint,
        autoPrintInvoice: _autoPrintInvoice,
        allowDebt: _allowDebt,
        lowStockThreshold: _lowStock,
      );

  Future<void> _save() async {
    final ok = await ref.read(settingsProvider.notifier).save(_draft);
    if (!ok || !mounted) return; // never report a failed save as saved
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('settings_saved', loc))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(settingsProvider);

    // A successful save (or a background reload) replaces the server
    // snapshot — re-seed the form from it.  A *failed* save leaves
    // `settings` untouched, so this never wipes what the operator typed.
    ref.listen<SettingsState>(settingsProvider, (previous, next) {
      final settings = next.settings;
      if (settings != null && settings != previous?.settings) {
        setState(() => _seedFrom(settings));
      }
    });

    if (state.settings == null) {
      if (state.hasError) {
        return _loadError(theme, loc, state.errorMessage);
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            key: const Key('settings-store-loading'),
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }

    final settings = state.settings!;
    final hasChanges = _draft != settings;

    return Card(
      // Re-keys the whole subtree when the server snapshot changes, so a
      // dropdown seeded with `initialValue` re-initialises from the freshly
      // saved values instead of keeping stale field state.
      key: ValueKey<StoreSettings?>(settings),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.hasError) _errorBanner(theme, loc, state),
            _sectionTitle(theme, loc, 'settings_store'),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-store-name'),
              controller: _storeName,
              label: AppStrings.t('store_name', loc),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-store-phone'),
              controller: _storePhone,
              label: AppStrings.t('phone', loc),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-store-address'),
              controller: _storeAddress,
              label: AppStrings.t('address', loc),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            _sectionTitle(theme, loc, 'settings_receipt'),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-invoice-footer'),
              controller: _invoiceFooter,
              label: AppStrings.t('invoice_footer', loc),
              maxLines: 2,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('settings-paper-dropdown'),
              initialValue: _defaultPaper,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: AppStrings.t('default_paper', loc),
              ),
              items: [
                for (final paper in StoreSettings.papers)
                  DropdownMenuItem<String>(value: paper, child: Text(paper)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _defaultPaper = value);
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('settings-ask-before-print'),
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.t('ask_before_print', loc)),
              value: _askBeforePrint,
              onChanged: (value) => setState(() => _askBeforePrint = value),
            ),
            SwitchListTile(
              key: const Key('settings-auto-print'),
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.t('auto_print_invoice', loc)),
              value: _autoPrintInvoice,
              onChanged: (value) => setState(() => _autoPrintInvoice = value),
            ),
            const SizedBox(height: 16),
            _sectionTitle(theme, loc, 'settings_pos'),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('settings-allow-debt'),
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.t('allow_debt', loc)),
              value: _allowDebt,
              onChanged: (value) => setState(() => _allowDebt = value),
            ),
            _textField(
              key: const Key('settings-low-stock-threshold'),
              controller: _lowStockThreshold,
              label: AppStrings.t('low_stock_threshold', loc),
              keyboardType: TextInputType.number,
              errorText: _lowStock < 0
                  ? AppStrings.t('validation_error', loc)
                  : null,
              onChanged: (value) {
                setState(
                  () => _lowStock = int.tryParse(value.trim()) ?? -1,
                );
              },
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton(
                  key: const Key('settings-save-button'),
                  onPressed: state.isSaving || !hasChanges || _lowStock < 0
                      ? null
                      : _save,
                  child: state.isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(AppStrings.t('save', loc)),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const Key('settings-refresh-button'),
                  onPressed: state.isSaving
                      ? null
                      : () => ref.read(settingsProvider.notifier).load(),
                  child: Text(AppStrings.t('refresh', loc)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String loc, String key) => Text(
        AppStrings.t(key, loc),
        style: theme.textTheme.titleMedium,
      );

  Widget _textField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? errorText,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        errorText: errorText,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }

  Widget _errorBanner(ThemeData theme, String loc, SettingsState state) {
    final headline = state.failedDuringSave
        ? 'settings_save_failed'
        : 'settings_load_failed';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        key: const Key('settings-error-banner'),
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${AppStrings.t(headline, loc)}'
              '${state.errorMessage == null ? '' : ' — ${state.errorMessage}'}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
          IconButton(
            key: const Key('settings-error-dismiss'),
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(settingsProvider.notifier).clearError(),
          ),
        ],
      ),
    );
  }

  Widget _loadError(ThemeData theme, String loc, String? detail) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const Key('settings-load-error'),
          children: [
            Text(
              AppStrings.t('settings_load_failed', loc),
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref.read(settingsProvider.notifier).load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Company / fiscal identity (Stage 1, factura_simple parity): the seven
/// Phase 6 `store_*` fields on `GET` + `PUT /api/v1/settings`.
///
/// The legacy company form had 10 fields (name, address, wilaya, phone,
/// email, rc, nif, ai, nis, rib).  Three of them — name, address, phone —
/// already live in the store section above: they ARE `store_name` /
/// `store_address` / `store_phone` (backend `settings.py` documents the
/// mapping), so all 10 legacy company fields are editable on this screen
/// without a second controller bound to the same value.
///
/// Lifecycle: the parent builds this widget only for `settings_manage`
/// holders, exactly like the store section.  It never issues its own GET —
/// while the provider snapshot is still null (load in flight or failed) it
/// renders nothing and the store section owns the loading/error UI; once a
/// snapshot exists it seeds from it and re-seeds on every snapshot change.
/// The save PUTs the whole form: the 7 edited company fields from these
/// controllers, everything else from the last snapshot — so saving company
/// information can never revert an unrelated saved setting.
class _CompanySettingsSection extends ConsumerStatefulWidget {
  const _CompanySettingsSection();

  @override
  ConsumerState<_CompanySettingsSection> createState() =>
      _CompanySettingsSectionState();
}

class _CompanySettingsSectionState
    extends ConsumerState<_CompanySettingsSection> {
  late final TextEditingController _wilaya;
  late final TextEditingController _email;
  late final TextEditingController _rc;
  late final TextEditingController _nif;
  late final TextEditingController _ai;
  late final TextEditingController _nis;
  late final TextEditingController _rib;

  @override
  void initState() {
    super.initState();
    _wilaya = TextEditingController();
    _email = TextEditingController();
    _rc = TextEditingController();
    _nif = TextEditingController();
    _ai = TextEditingController();
    _nis = TextEditingController();
    _rib = TextEditingController();
    final current = ref.read(settingsProvider).settings;
    if (current != null) _seedFrom(current);
  }

  @override
  void dispose() {
    _wilaya.dispose();
    _email.dispose();
    _rc.dispose();
    _nif.dispose();
    _ai.dispose();
    _nis.dispose();
    _rib.dispose();
    super.dispose();
  }

  void _seedFrom(StoreSettings settings) {
    _wilaya.text = settings.storeWilaya;
    _email.text = settings.storeEmail;
    _rc.text = settings.storeRc;
    _nif.text = settings.storeNif;
    _ai.text = settings.storeAi;
    _nis.text = settings.storeNis;
    _rib.text = settings.storeRib;
  }

  /// The PUT body = last snapshot + these 7 edited fields (full form, as
  /// the endpoint's contract requires).
  StoreSettings _draftFrom(StoreSettings snapshot) => snapshot.copyWith(
        storeWilaya: _wilaya.text,
        storeEmail: _email.text,
        storeRc: _rc.text,
        storeNif: _nif.text,
        storeAi: _ai.text,
        storeNis: _nis.text,
        storeRib: _rib.text,
      );

  Future<void> _save(StoreSettings snapshot) async {
    final ok =
        await ref.read(settingsProvider.notifier).save(_draftFrom(snapshot));
    if (!ok || !mounted) return; // never report a failed save as saved
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('settings_saved', loc))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(settingsProvider);

    // A successful save (or a background reload) replaces the server
    // snapshot — re-seed these controllers from it.  A failed save leaves
    // `settings` untouched, so the operator's typing survives (same
    // contract as the store section).
    ref.listen<SettingsState>(settingsProvider, (previous, next) {
      final settings = next.settings;
      if (settings != null && settings != previous?.settings) {
        setState(() => _seedFrom(settings));
      }
    });

    final settings = state.settings;
    if (settings == null) {
      // Loading or load-failed: the store section above renders the
      // spinner / retry card, so this section simply stays out of the way.
      return const SizedBox.shrink();
    }

    final hasChanges = _draftFrom(settings) != settings;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('settings_company', loc),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-wilaya'),
              controller: _wilaya,
              label: AppStrings.t('wilaya', loc),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-email'),
              controller: _email,
              label: AppStrings.t('email', loc),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-rc'),
              controller: _rc,
              label: AppStrings.t('rc', loc),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-nif'),
              controller: _nif,
              label: AppStrings.t('nif', loc),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-ai'),
              controller: _ai,
              label: AppStrings.t('ai', loc),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-nis'),
              controller: _nis,
              label: AppStrings.t('nis', loc),
            ),
            const SizedBox(height: 12),
            _textField(
              key: const Key('settings-company-rib'),
              controller: _rib,
              label: AppStrings.t('rib', loc),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('settings-company-save-button'),
              onPressed: state.isSaving || !hasChanges
                  ? null
                  : () => _save(settings),
              child: state.isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(AppStrings.t('save', loc)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textField({
    required Key key,
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }
}

/// Server-side backup catalogue (`GET` + `POST /api/v1/backups` and
/// `POST /api/v1/backups/{id}/restore`), Phase 17 §17.2.
///
/// Admin-only, exactly like the endpoints it calls.  The section never
/// claims success on its own: `create()` / `restore()` return `true` only
/// for a 2xx answer, and those futures are the sole trigger for the
/// "created" / "restored" snackbars.
class _BackupSection extends ConsumerStatefulWidget {
  const _BackupSection();

  @override
  ConsumerState<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<_BackupSection> {
  @override
  void initState() {
    super.initState();
    // Deferred: the provider must not be read during build.
    Future.microtask(_loadIfNeeded);
  }

  void _loadIfNeeded() {
    if (!mounted) return;
    final state = ref.read(backupProvider);
    if (state.status == BackupStatus.idle && !state.busy) {
      ref.read(backupProvider.notifier).load();
    }
  }

  Future<void> _create() async {
    final ok = await ref.read(backupProvider.notifier).create();
    if (!mounted) return;
    _snack(ok ? 'backup_created' : 'backup_create_failed');
  }

  Future<void> _restore(BackupInfo backup) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppStrings.t('backup_restore_confirm', loc)),
        content: Text(
          '${AppStrings.t('backup_restore_warning', loc)}\n\n'
          '${backup.filename}',
        ),
        actions: [
          TextButton(
            key: const Key('settings-backup-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          FilledButton(
            key: const Key('settings-backup-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppStrings.t('confirm', loc)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await ref.read(backupProvider.notifier).restore(backup.id);
    if (!mounted) return;
    _snack(ok ? 'backup_restored' : 'backup_restore_failed');
  }

  void _snack(String messageKey) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t(messageKey, loc))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(backupProvider);
    // A failed *create* is not a failed *load*: the headline has to name
    // what actually went wrong or the operator chases the wrong fix.
    final headline =
        state.failedDuringAction ? 'backup_failed' : 'backup_load_failed';

    return Card(
      key: const Key('settings-backup-section'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.hasError)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  key: const Key('settings-backup-error'),
                  children: [
                    Icon(Icons.error_outline, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${AppStrings.t(headline, loc)}'
                        '${state.errorMessage == null ? '' : ' — ${state.errorMessage}'}',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                    IconButton(
                      key: const Key('settings-backup-error-dismiss'),
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          ref.read(backupProvider.notifier).clearError(),
                    ),
                  ],
                ),
              ),
            Text(
              AppStrings.t('backups', loc),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('settings-backup-create'),
              onPressed: state.busy ? null : _create,
              icon: state.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(AppStrings.t('backup_create', loc)),
            ),
            const SizedBox(height: 8),
            if (state.isLoading && state.items.isEmpty)
              const Center(
                key: Key('settings-backup-loading'),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (state.items.isEmpty)
              Text(
                AppStrings.t('backup_empty', loc),
                key: const Key('settings-backup-empty'),
                style: theme.textTheme.bodyMedium,
              )
            else
              Column(
                key: const Key('settings-backup-list'),
                children: [
                  for (final backup in state.items) _tile(backup, state, loc),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BackupInfo backup, BackupState state, String loc) {
    final restoring = state.pendingRestoreId == backup.id;
    return ListTile(
      key: ValueKey<String>('settings-backup-item-${backup.id}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(backup.filename),
      subtitle: Text(
        '${formatBytes(backup.size)} · ${formatBackupDate(backup.createdAt)}',
      ),
      trailing: OutlinedButton(
        key: ValueKey<String>('settings-backup-restore-${backup.id}'),
        onPressed: state.busy ? null : () => _restore(backup),
        child: restoring
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(AppStrings.t('backup_restore', loc)),
      ),
    );
  }
}

/// Phase E — loyalty rules (`GET` + `PUT /api/v1/loyalty/settings`).
///
/// Same lifecycle contract as the store section: loaded lazily from
/// `initState`, re-seeded whenever the server snapshot changes (a
/// successful save updates it from the response, a failed one leaves the
/// operator's typing alone), and `saved` is only ever reported from
/// `save()`'s `true`. Rendered only for `settings_manage` — the server
/// rejects the `PUT` for anyone else.
class _LoyaltySettingsSection extends ConsumerStatefulWidget {
  const _LoyaltySettingsSection();

  @override
  ConsumerState<_LoyaltySettingsSection> createState() =>
      _LoyaltySettingsSectionState();
}

class _LoyaltySettingsSectionState
    extends ConsumerState<_LoyaltySettingsSection> {
  late final TextEditingController _amountPerPoint;
  late final TextEditingController _cashbackRate;
  late final TextEditingController _maxRewardDiscount;
  late final TextEditingController _minRewardPoints;

  bool _pointsEnabled = false;
  bool _cashbackEnabled = false;
  bool _earnOnDebt = true;

  @override
  void initState() {
    super.initState();
    _amountPerPoint = TextEditingController();
    _cashbackRate = TextEditingController();
    _maxRewardDiscount = TextEditingController();
    _minRewardPoints = TextEditingController();
    final current = ref.read(loyaltySettingsProvider).settings;
    if (current != null) _seedFrom(current);
    // Deferred out of initState: the provider must not be read while the
    // widget tree is still building.
    Future.microtask(_loadIfNeeded);
  }

  void _loadIfNeeded() {
    if (!mounted) return;
    final state = ref.read(loyaltySettingsProvider);
    if (state.settings == null &&
        state.status != LoyaltySettingsStatus.loading &&
        state.status != LoyaltySettingsStatus.saving) {
      ref.read(loyaltySettingsProvider.notifier).load();
    }
  }

  @override
  void dispose() {
    _amountPerPoint.dispose();
    _cashbackRate.dispose();
    _maxRewardDiscount.dispose();
    _minRewardPoints.dispose();
    super.dispose();
  }

  static String _numText(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  void _seedFrom(LoyaltySettings settings) {
    // The merchant edits DZD per point (the inverse of `points_rate`);
    // the server derives and reports the stored rate, so re-seeding from
    // the snapshot never drifts from what was typed.
    _amountPerPoint.text = _numText(settings.amountPerPoint);
    _cashbackRate.text = _numText(settings.cashbackRate);
    _maxRewardDiscount.text = _numText(settings.maxRewardDiscountPercent);
    _minRewardPoints.text = settings.minRewardPoints.toString();
    _pointsEnabled = settings.pointsEnabled;
    _cashbackEnabled = settings.cashbackEnabled;
    _earnOnDebt = settings.earnOnDebtSettlement;
  }

  LoyaltySettings get _draft => LoyaltySettings(
        pointsEnabled: _pointsEnabled,
        // A stale/placeholder rate is harmless: `amount_per_point` (the
        // inverse) wins server-side whenever both are present.
        pointsRate: 0,
        cashbackEnabled: _cashbackEnabled,
        cashbackRate: double.tryParse(_cashbackRate.text.trim()) ?? -1,
        maxRewardDiscountPercent:
            double.tryParse(_maxRewardDiscount.text.trim()) ?? -1,
        earnOnDebtSettlement: _earnOnDebt,
        amountPerPoint:
            double.tryParse(_amountPerPoint.text.trim()) ?? -1,
        minRewardPoints:
            int.tryParse(_minRewardPoints.text.trim()) ?? -1,
      );

  /// Server field constraints mirrored client-side so the Save button is
  /// never able to fire an obviously invalid body (0 parks reward
  /// redemption, 100 allows it over the whole amount due; amount per
  /// point is [0.001, 1e6] and the milestone is a whole [1, 1e6]).
  bool _valid(LoyaltySettings draft) =>
      draft.cashbackRate >= 0 &&
      draft.maxRewardDiscountPercent >= 0 &&
      draft.maxRewardDiscountPercent <= 100 &&
      draft.amountPerPoint >= 0.001 &&
      draft.amountPerPoint <= 1000000 &&
      draft.minRewardPoints >= 1 &&
      draft.minRewardPoints <= 1000000;

  Future<void> _save() async {
    final draft = _draft;
    if (!_valid(draft)) return;
    final ok = await ref.read(loyaltySettingsProvider.notifier).save(draft);
    if (!ok || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('settings_saved', loc))),
    );
  }

  String? _fieldError(TextEditingController controller, {double? max}) {
    final text = controller.text.trim();
    final value = double.tryParse(text);
    if (text.isEmpty || value == null) return AppStrings.t('validation_error', loc());
    if (value < 0) return AppStrings.t('validation_error', loc());
    if (max != null && value > max) return AppStrings.t('validation_error', loc());
    return null;
  }

  String? _intFieldError(TextEditingController controller) {
    final text = controller.text.trim();
    final value = int.tryParse(text);
    if (text.isEmpty || value == null) {
      return AppStrings.t('validation_error', loc());
    }
    if (value < 1 || value > 1000000) {
      return AppStrings.t('validation_error', loc());
    }
    return null;
  }

  String loc() => ref.read(localeProvider).flutterLocale.languageCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(loyaltySettingsProvider);

    // Re-seed on a fresh snapshot (first load or successful save); a
    // FAILED save never replaces `settings`, so typing survives.
    ref.listen<LoyaltySettingsState>(loyaltySettingsProvider, (prev, next) {
      final settings = next.settings;
      if (settings != null && settings != prev?.settings) {
        setState(() => _seedFrom(settings));
      }
    });

    if (state.settings == null) {
      if (state.hasError) return _loadError(theme, loc, state.errorMessage);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            key: const Key('settings-loyalty-loading'),
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }

    final settings = state.settings!;
    final draft = _draft;
    final hasChanges = draft != settings;
    final valid = _valid(draft);

    return Card(
      // Re-keys the subtree when the server snapshot changes so seeded
      // fields re-initialise from freshly saved values.
      key: ValueKey<LoyaltySettings?>(settings),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.hasError) _errorBanner(theme, loc, state),
            Text(
              AppStrings.t('loyalty_settings', loc),
              key: const Key('settings-loyalty-title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('settings-loyalty-points-enabled'),
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.t('loyalty_settings_points_enabled', loc)),
              value: _pointsEnabled,
              onChanged: (value) => setState(() => _pointsEnabled = value),
            ),
            SwitchListTile(
              key: const Key('settings-loyalty-cashback-enabled'),
              contentPadding: EdgeInsets.zero,
              title:
                  Text(AppStrings.t('loyalty_settings_cashback_enabled', loc)),
              value: _cashbackEnabled,
              onChanged: (value) => setState(() => _cashbackEnabled = value),
            ),
            SwitchListTile(
              key: const Key('settings-loyalty-earn-debt'),
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.t('loyalty_settings_earn_on_debt', loc)),
              value: _earnOnDebt,
              onChanged: (value) => setState(() => _earnOnDebt = value),
            ),
            const SizedBox(height: 12),
            _numField(
              key: const Key('settings-loyalty-amount-per-point'),
              controller: _amountPerPoint,
              label: AppStrings.t('loyalty_settings_amount_per_point', loc),
            ),
            const SizedBox(height: 12),
            _intField(
              key: const Key('settings-loyalty-min-reward-points'),
              controller: _minRewardPoints,
              label: AppStrings.t('loyalty_settings_min_reward_points', loc),
            ),
            const SizedBox(height: 12),
            _numField(
              key: const Key('settings-loyalty-cashback-rate'),
              controller: _cashbackRate,
              label: AppStrings.t('loyalty_settings_cashback_rate', loc),
            ),
            const SizedBox(height: 12),
            _numField(
              key: const Key('settings-loyalty-max-reward-discount'),
              controller: _maxRewardDiscount,
              label: AppStrings.t(
                'loyalty_settings_max_reward_discount',
                loc,
              ),
              max: 100,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton(
                  key: const Key('settings-loyalty-save-button'),
                  onPressed: state.isSaving || !hasChanges || !valid
                      ? null
                      : _save,
                  child: state.isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(AppStrings.t('save', loc)),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const Key('settings-loyalty-refresh-button'),
                  onPressed: state.isSaving
                      ? null
                      : () => ref.read(loyaltySettingsProvider.notifier).load(),
                  child: Text(AppStrings.t('refresh', loc)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField({
    required Key key,
    required TextEditingController controller,
    required String label,
    double? max,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        errorText: _fieldError(controller, max: max),
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _intField({
    required Key key,
    required TextEditingController controller,
    required String label,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        errorText: _intFieldError(controller),
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _errorBanner(ThemeData theme, String loc, LoyaltySettingsState state) {
    final headline =
        state.failedDuringSave ? 'settings_save_failed' : 'settings_load_failed';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        key: const Key('settings-loyalty-error-banner'),
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${AppStrings.t(headline, loc)}'
              '${state.errorMessage == null ? '' : ' — ${state.errorMessage}'}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
          IconButton(
            key: const Key('settings-loyalty-error-dismiss'),
            icon: const Icon(Icons.close),
            onPressed: () =>
                ref.read(loyaltySettingsProvider.notifier).clearError(),
          ),
        ],
      ),
    );
  }

  Widget _loadError(ThemeData theme, String loc, String? detail) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const Key('settings-loyalty-load-error'),
          children: [
            Text(
              AppStrings.t('settings_load_failed', loc),
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  ref.read(loyaltySettingsProvider.notifier).load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry point to the read-only Storage & Data Usage page.
///
/// Visible only under `settings_manage`, the same permission the backend
/// enforces on `GET /api/v1/storage` — a lower-privileged operator never
/// sees the button, and the page itself re-checks the permission too.
class _StorageSection extends ConsumerWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('storage_usage', loc),
              key: const Key('settings-storage-title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.t('storage_usage_desc', loc),
              key: const Key('settings-storage-desc'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const Key('settings-storage-open'),
              onPressed: () => context.go('/storage-usage'),
              icon: const Icon(Icons.storage),
              label: Text(AppStrings.t('storage_open', loc)),
            ),
          ],
        ),
      ),
    );
  }
}


