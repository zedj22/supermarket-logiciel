import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/shortcuts.dart';
import '../core/strings.dart';
import '../core/widgets/logo_mark.dart';
import '../features/auth/auth_provider.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/permission_helpers.dart';
import '../features/auth/setup_screen.dart';
import '../features/shell/app_nav_rail.dart';
import '../features/splash/splash_screen.dart';
import '../features/shell/nav_items.dart';
import '../features/shell/shortcuts_help_dialog.dart';
import '../l10n/locale_provider.dart';
import '../features/about/about_screen.dart';
import '../features/audit/audit_screen.dart';
import '../features/documentation/documentation_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/clients/clients_screen.dart';
import '../features/packs/packs_screen.dart';
import '../features/pos/pos_screen.dart';
import '../features/products/product_form_dialog.dart';
import '../features/products/products_screen.dart';
import '../features/returns/returns_screen.dart';
import '../features/stock/stock_screen.dart';
import '../features/sales/sales_screen.dart';
import '../features/debts/debts_screen.dart';
import '../features/suppliers/suppliers_screen.dart';
import '../features/expenses/expenses_screen.dart';
import '../features/promotions/promotions_screen.dart';
import '../features/purchases/purchases_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/zakat/zakat_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/storage/storage_screen.dart';
import '../features/users/users_screen.dart';
import '../features/facturation/facturation_screen.dart';
import '../features/invoice_clients/invoice_clients_screen.dart';
import '../features/data_transfer/data_transfer_screen.dart';
import '../features/backup_restore/backup_restore_screen.dart';
import '../features/hardware/connected_devices_screen.dart';
import '../features/devices/device_identity.dart';
import '../features/devices/connection_provider.dart';
import '../features/devices/devices_screen.dart';
import '../features/devices/reconnect_dialog.dart';
import '../features/devices/setup_wizard_screen.dart';
import '../features/devices/widgets/status_chip.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Keep ONE GoRouter instance for the app's lifetime. Recreating the
  // router on every AuthState change remounted LoginScreen and wiped its
  // local selected-user/PIN state (wrong PIN appeared to "return" to the
  // user list). Instead, notify GoRouter so it re-runs redirect only.
  final authRefresh = ValueNotifier<int>(0);
  ref.listen<AuthState>(
    authProvider,
    (previous, next) => authRefresh.value++,
  );
  // Phase 16: finishing (or skipping) the first-run wizard must re-run the
  // redirect so an unpaired client is pushed into /setup-network.
  ref.listen(
    networkConfiguredProvider,
    (previous, next) => authRefresh.value++,
  );
  // The startup splash is a redirect state, so the moment its one-shot
  // gate opens the redirect must re-run to reveal the real destination.
  ref.listen(splashGateProvider, (previous, next) {
    if (next) authRefresh.value++;
  });

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: authRefresh,
    redirect: (context, state) {
      // Read live state — do not capture a snapshot from provider build.
      final authState = ref.read(authProvider);
      final path = state.matchedLocation;
      final isAuthenticated = authState.status == AuthStatus.authenticated;
      final isSetupRequired = authState.status == AuthStatus.setupRequired;
      final isChecking = authState.status == AuthStatus.checking;

      // Startup splash: every destination resolves to /splash while auth
      // is still checking AND until the one-shot brand sequence has
      // completed. Checked first so no other gate reads happen mid-boot,
      // and returning null on /splash itself keeps the redirect loop-free.
      if (isChecking || !ref.read(splashGateProvider)) {
        return path == '/splash' ? null : '/splash';
      }

      // Phase 16 (§23.2): a client that has never completed the wizard has
      // no device identity, so there is nothing it can legitimately do.
      // Checked before setup/login so the very first screen is the wizard.
      final bootstrapped = ref.read(installBootstrappedProvider);
      final configured = ref.read(networkConfiguredProvider);
      if (bootstrapped &&
          configured.hasValue &&
          !configured.requireValue &&
          path != '/setup-network') {
        return '/setup-network';
      }

      // Setup required → force setup screen
      if (isSetupRequired && path != '/setup' && path != '/setup-network') {
        return '/setup';
      }

      // Unauthenticated (including login failure / session expiry)
      // → force login. Staying on /login returns null (no remount loop).
      if (!isAuthenticated &&
          path != '/login' &&
          path != '/setup' &&
          path != '/setup-network') {
        return '/login';
      }

      // Authenticated on login/setup/splash → redirect to home. The splash
      // case is the one that matters after the gate opens: without it a
      // restored session would sit on /splash forever (null = stay).
      if (isAuthenticated &&
          (path == '/login' || path == '/setup' || path == '/splash')) {
        return '/';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        name: 'splash',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: const SplashScreen(),
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 350),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
      GoRoute(
        path: '/setup-network',
        name: 'setup-network',
        builder: (context, state) => const SetupWizardScreen(),
      ),
      GoRoute(
        path: '/setup',
        name: 'setup',
        builder: (context, state) => const SetupScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            ScaffoldWithNav(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/',
            name: 'dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/pos',
            name: 'pos',
            builder: (context, state) => const PosScreen(),
          ),
          GoRoute(
            path: '/returns',
            name: 'returns',
            builder: (context, state) => const ReturnsScreen(),
          ),
          GoRoute(
            path: '/expenses',
            name: 'expenses',
            builder: (context, state) => const ExpensesScreen(),
          ),
          GoRoute(
            path: '/clients',
            name: 'clients',
            builder: (context, state) => const ClientsScreen(),
          ),
          GoRoute(
            path: '/products',
            name: 'products',
            builder: (context, state) => const ProductsScreen(),
          ),
          GoRoute(
            path: '/packs',
            name: 'packs',
            builder: (context, state) => const PacksScreen(),
          ),
          GoRoute(
            path: '/promotions',
            name: 'promotions',
            builder: (context, state) => const PromotionsScreen(),
          ),
          GoRoute(
            path: '/stock',
            name: 'stock',
            builder: (context, state) => const StockScreen(),
          ),
          GoRoute(
            path: '/sales',
            name: 'sales',
            builder: (context, state) => const SalesScreen(),
          ),
          GoRoute(
            path: '/debts',
            name: 'debts',
            builder: (context, state) => const DebtsScreen(),
          ),
          GoRoute(
            path: '/suppliers',
            name: 'suppliers',
            builder: (context, state) => const SuppliersScreen(),
          ),
          GoRoute(
            path: '/purchases',
            name: 'purchases',
            builder: (context, state) => const PurchasesScreen(),
          ),
          GoRoute(
            path: '/facturation',
            name: 'facturation',
            builder: (context, state) => const FacturationScreen(),
          ),
          GoRoute(
            path: '/invoice-clients',
            name: 'invoice-clients',
            builder: (context, state) => const InvoiceClientsScreen(),
          ),
          GoRoute(
            path: '/reports',
            name: 'reports',
            builder: (context, state) => const ReportsScreen(),
          ),
          GoRoute(
            path: '/zakat',
            name: 'zakat',
            builder: (context, state) => const ZakatScreen(),
          ),
          GoRoute(
            path: '/users',
            name: 'users',
            builder: (context, state) => const UsersScreen(),
          ),
          GoRoute(
            path: '/devices',
            name: 'devices',
            builder: (context, state) => const DevicesScreen(),
          ),
          // Objective 4 — Administration surfaces. Backend RBAC remains
          // the security boundary; the scopes here only hide the rail
          // entry from users who could never load the screen.
          GoRoute(
            path: '/data-transfer',
            name: 'data-transfer',
            builder: (context, state) => const DataTransferScreen(),
          ),
          GoRoute(
            path: '/backup-restore',
            name: 'backup-restore',
            builder: (context, state) => const BackupRestoreScreen(),
          ),
          GoRoute(
            path: '/connected-devices',
            name: 'connected-devices',
            builder: (context, state) => const ConnectedDevicesScreen(),
          ),
          GoRoute(
            path: '/audit-log',
            name: 'audit-log',
            builder: (context, state) => const AuditScreen(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/about',
            name: 'about',
            builder: (context, state) => const AboutScreen(),
          ),
          GoRoute(
            path: '/storage-usage',
            name: 'storage-usage',
            builder: (context, state) => const StorageUsageScreen(),
          ),
          GoRoute(
            path: '/documentation',
            name: 'documentation',
            builder: (context, state) => const DocumentationScreen(),
          ),
        ],
      ),
    ],
  );

  ref.onDispose(() {
    authRefresh.dispose();
    router.dispose();
  });

  return router;
});

/// Minimal authenticated desktop shell: app title, current user, logout,
/// permission-gated navigation, and page content. No business features.
class ScaffoldWithNav extends ConsumerWidget {
  final String location;
  final Widget child;
  const ScaffoldWithNav({super.key, required this.location, required this.child});

  /// Scope required by the backend for `GET /api/v1/users` and user CRUD.
  static const String userManageScope = NavScopes.userManage;

  /// Scope required to see the Products destination and screens.
  static const String productViewScope = NavScopes.productView;

  /// Scope required to see the Stock / Inventory destination (Phase 7).
  static const String inventoryViewScope = NavScopes.inventoryView;

  /// Scope required to see the POS destination (Phase 8).
  static const String posSaleScope = NavScopes.posSale;

  /// Scope required to see the Clients destination (Phase 9).
  static const String customerViewScope = NavScopes.customerView;

  /// Scope required to see the Suppliers destination (Phase 11).
  static const String supplierViewScope = NavScopes.supplierView;

  /// Scope required to see the Purchases destination (Phase 11).
  static const String purchaseViewScope = NavScopes.purchaseView;

  /// Scope required to see the Returns destination (Phase 12).
  static const String returnViewScope = NavScopes.returnView;

  /// Scope required to see the Expenses destination (Phase 13).
  static const String expenseViewScope = NavScopes.expenseView;

  /// Scope required to see the Promotions destination (Phase 18).
  static const String promotionViewScope = NavScopes.promotionView;

  /// Scope required to see the Reports destination and dashboard KPIs
  /// (Phase 14 — `report_financial`; §10: the rail entry AND the
  /// dashboard/reports content are gated on it).
  static const String reportViewScope = NavScopes.reportFinancial;

  /// Scope required to see the Facturation and Invoice Clients
  /// destinations (Phase 9 Stage C — `facturation_view`; Admin +
  /// Manager only; backend RBAC remains the security boundary).
  static const String facturationViewScope = NavScopes.facturationView;

  /// One- or two-letter monogram for the header avatar. Works on UTF-16
  /// safe boundaries (`runes`, not `substring`) so an Arabic or emoji
  /// leading character cannot throw mid-build.
  static String _initials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    String firstWord(String s) => String.fromCharCodes(s.runes.take(1));
    final words = trimmed.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return (firstWord(words.first) + firstWord(words.last)).toUpperCase();
    }
    return firstWord(trimmed).toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final user = ref.watch(currentUserProvider);

    // Phase 16 (§14 / §23.1): the reconnect modal is a BOOT-TIME prompt and
    // happens at most once per run. `connecting` is only ever entered from
    // `bootstrap()`, a completed pairing or an explicit "retry now", so a
    // mid-session flap (`connected` → `reconnecting`) never opens a modal —
    // the chip reports it instead.
    ref.listen(lanConnectionProvider, (previous, next) {
      if (ref.read(reconnectPromptShownProvider)) return;
      if (previous?.phase != LanPhase.connecting) return;
      if (next.phase != LanPhase.reconnecting &&
          next.phase != LanPhase.disconnected) {
        return;
      }
      if (!next.isPaired && next.baseUrl == null) return;
      ref.read(reconnectPromptShownProvider.notifier).state = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ReconnectDialog.show(context).then((action) {
          if (!context.mounted) return;
          if (action == ReconnectAction.retry) {
            ref.read(lanConnectionProvider.notifier).retryNow();
          } else if (action == ReconnectAction.manualEntry) {
            context.go('/setup-network');
          }
        });
      });
    });

    // ONE list drives the tiles, the selection and the taps — the shell
    // only decides *who may see what* (buildNavGroups answers each scope
    // once, through the same permission provider as before).
    final groups = buildNavGroups(
      can: (scope) => ref.watch(hasPermissionProvider(scope)),
    );

    // Below ~760px the identity caption goes and the monogram avatar
    // carries the operator alone — otherwise the actions eat the bar and
    // squeeze the wordmark to nothing on a short window.
    final headerCompact = MediaQuery.sizeOf(context).width < 760;

    return AppShortcuts(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 16,
          // Brand block: the drawn logo mark + the one wordmark Text the
          // shell has always shown (`app_name`, found exactly once). The
          // bar hands this Row only what the actions left over, so the
          // logo steps aside before the wordmark can overflow.
          title: LayoutBuilder(
            builder: (context, box) {
              final showLogo = box.maxWidth >= 140;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showLogo) ...[
                    const AppLogoMark(size: 28),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      AppStrings.t('app_name', loc),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            // Phase 17 §18 — the keyboard map needs a single, always
            // reachable entry point, whatever screen is on top.
            IconButton(
              key: const Key('shortcuts-help-button'),
              tooltip: AppStrings.t('shortcuts_title', loc),
              onPressed: () => showShortcutsDialog(context),
              icon: const Icon(Icons.keyboard),
            ),
            // Phase 16: steady-state LAN health indicator (§14 — chip only,
            // never a modal once the wizard is done).
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: ConnectionStatusChip(),
            ),
            if (user != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Monogram avatar: initials off the operator's own
                    // name, so two tills on the counter are told apart at
                    // a glance without reading the caption. The tooltip
                    // keeps the full name reachable when the compact
                    // header drops the caption.
                    Tooltip(
                      message: user.fullName,
                      child: Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          _initials(user.fullName),
                          key: const Key('shell-user-avatar'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (!headerCompact)
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            user.fullName,
                            key: const Key('shell-user-name'),
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            user.roles
                                .map((r) => AppStrings.t(r, loc))
                                .join(', '),
                            key: const Key('shell-user-roles'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 12),
                child: TextButton.icon(
                  key: const Key('logout-button'),
                  onPressed: () => ref.read(authProvider.notifier).logout(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: Text(AppStrings.t('logout', loc)),
                ),
              ),
            ],
          ],
        ),
        body: Row(
          children: [
            if (groups.isNotEmpty) ...[
              AppNavRail(
                location: location,
                groups: groups,
                onNavigate: context.go,
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Global keyboard map (Phase 17 §18).
///
/// The shell answers the keys that mean the same thing on every screen:
///
///   F1 / F2      → routes (POS / Products)
///   F3 / Ctrl+N  → add-product form, permission-gated on `product_create`
///   F4 / Ctrl+F  → the *current* page's search field
///   F5           → the *current* page's safe refresh
///
/// F4/F5 delegate through [PageShortcutsRegistry] because only the
/// mounted screen knows which field to focus and which read-only lists it
/// may reload — the POS refuses to touch its cart, so a global refresh
/// can never destroy an in-progress sale.
///
/// Ordering matters: this widget sits *outside* the page, so a key the
/// page binds (POS: F6–F12, SPACE, `+`/`-`/`*`, its own F4/F5) is claimed
/// by the page first and never reaches here; everything the page does not
/// bind bubbles up and is answered here. While a dialog route is open its
/// focus scope owns the keys entirely, so none of these fire behind a
/// modal.
///
/// One activator per key: `CallbackShortcuts` runs *every* matching
/// binding, so no key may be declared twice at the same layer.
class AppShortcuts extends ConsumerWidget {
  const AppShortcuts({super.key, required this.child});

  /// The shell (usually the whole [Scaffold]).
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAddProduct = ref.watch(hasPermissionProvider('product_create'));

    void go(String path) => context.go(path);

    void focusSearch() => PageShortcutsRegistry.current?.focusSearch?.call();

    void refresh() => PageShortcutsRegistry.current?.refresh?.call();

    void addProduct() {
      if (!canAddProduct) return;
      showProductFormDialog(context);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1): () => go('/pos'),
        const SingleActivator(LogicalKeyboardKey.f2): () => go('/products'),
        const SingleActivator(LogicalKeyboardKey.f3): addProduct,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            addProduct,
        const SingleActivator(LogicalKeyboardKey.f4): focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): refresh,
      },
      // The Focus anchor is what makes the layer reachable: key events are
      // dispatched from the primary focus node UP its ancestor chain, so
      // the shell needs a focusable node of its own to bubble through when
      // the page itself has nothing focused. `skipTraversal` keeps it out
      // of the Tab order and it never requests focus on its own, so page
      // autofocused fields (the POS search box) are unaffected.
      child: Focus(
        key: const Key('shell-shortcuts-focus'),
        skipTraversal: true,
        child: child,
      ),
    );
  }
}

class Placeholder extends StatelessWidget {
  final String title;
  const Placeholder({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child:
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
    );
  }
}
