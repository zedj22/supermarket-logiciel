import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/strings.dart';
import '../features/auth/auth_provider.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/permission_helpers.dart';
import '../features/auth/setup_screen.dart';
import '../l10n/locale_provider.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/clients/clients_screen.dart';
import '../features/packs/packs_screen.dart';
import '../features/pos/pos_screen.dart';
import '../features/products/products_screen.dart';
import '../features/returns/returns_screen.dart';
import '../features/stock/stock_screen.dart';
import '../features/sales/sales_screen.dart';
import '../features/debts/debts_screen.dart';
import '../features/suppliers/suppliers_screen.dart';
import '../features/expenses/expenses_screen.dart';
import '../features/purchases/purchases_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/users/users_screen.dart';
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

      // While checking, show nothing (loading handled by app)
      if (isChecking) return null;

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

      // Authenticated on login/setup → redirect to home
      if (isAuthenticated && (path == '/login' || path == '/setup')) return '/';

      return null;
    },
    routes: [
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
            path: '/reports',
            name: 'reports',
            builder: (context, state) => const ReportsScreen(),
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
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
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
  static const String userManageScope = 'user_manage';

  /// Scope required to see the Products destination and screens.
  static const String productViewScope = 'product_view';

  /// Scope required to see the Stock / Inventory destination (Phase 7).
  static const String inventoryViewScope = 'inventory_view';

  /// Scope required to see the POS destination (Phase 8).
  static const String posSaleScope = 'pos_sale';

  /// Scope required to see the Clients destination (Phase 9).
  static const String customerViewScope = 'customer_view';

  /// Scope required to see the Suppliers destination (Phase 11).
  static const String supplierViewScope = 'supplier_view';

  /// Scope required to see the Purchases destination (Phase 11).
  static const String purchaseViewScope = 'purchase_view';

  /// Scope required to see the Returns destination (Phase 12).
  static const String returnViewScope = 'pos_return';

  /// Scope required to see the Expenses destination (Phase 13).
  static const String expenseViewScope = 'expense_view';

  /// Scope required to see the Reports destination and dashboard KPIs
  /// (Phase 14 — `report_financial`; §10: the rail entry AND the
  /// dashboard/reports content are gated on it).
  static const String reportViewScope = 'report_financial';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final user = ref.watch(currentUserProvider);
    final canManageUsers = ref.watch(hasPermissionProvider(userManageScope));
    final canViewProducts = ref.watch(hasPermissionProvider(productViewScope));
    final canViewInventory = ref.watch(hasPermissionProvider(inventoryViewScope));
    final canSell = ref.watch(hasPermissionProvider(posSaleScope));
    final canViewCustomers = ref.watch(hasPermissionProvider(customerViewScope));
    final canViewSuppliers = ref.watch(hasPermissionProvider(supplierViewScope));
    final canViewPurchases = ref.watch(hasPermissionProvider(purchaseViewScope));
    final canViewReturns = ref.watch(hasPermissionProvider(returnViewScope));
    final canViewExpenses = ref.watch(hasPermissionProvider(expenseViewScope));
    final canViewReports = ref.watch(hasPermissionProvider(reportViewScope));
    // Phase 16 §17: only admins see the device registry.
    final canManageDevices =
        ref.watch(hasPermissionProvider(deviceManageScope));

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

    final destinations = <NavigationRailDestination>[
      NavigationRailDestination(
        icon: const Icon(Icons.dashboard_outlined),
        selectedIcon: const Icon(Icons.dashboard),
        label: Text(AppStrings.t('dashboard', loc)),
      ),
      if (canSell)
        NavigationRailDestination(
          icon: const Icon(Icons.point_of_sale_outlined),
          selectedIcon: const Icon(Icons.point_of_sale),
          label: Text(AppStrings.t('pos', loc)),
        ),
      if (canViewReturns)
        NavigationRailDestination(
          icon: const Icon(Icons.undo_outlined),
          selectedIcon: const Icon(Icons.undo),
          label: Text(AppStrings.t('returns_history', loc)),
        ),
      if (canViewExpenses)
        NavigationRailDestination(
          icon: const Icon(Icons.payments_outlined),
          selectedIcon: const Icon(Icons.payments),
          label: Text(AppStrings.t('expenses', loc)),
        ),
      if (canViewProducts) ...[
        NavigationRailDestination(
          icon: const Icon(Icons.inventory_2_outlined),
          selectedIcon: const Icon(Icons.inventory_2),
          label: Text(AppStrings.t('products', loc)),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.local_offer_outlined),
          selectedIcon: const Icon(Icons.local_offer),
          label: Text(AppStrings.t('packs', loc)),
        ),
      ],
      if (canViewInventory)
        NavigationRailDestination(
          icon: const Icon(Icons.warehouse_outlined),
          selectedIcon: const Icon(Icons.warehouse),
          label: Text(AppStrings.t('stock', loc)),
        ),
      if (canViewCustomers) ...[
        NavigationRailDestination(
          icon: const Icon(Icons.contact_phone_outlined),
          selectedIcon: const Icon(Icons.contact_phone),
          label: Text(AppStrings.t('clients', loc)),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.receipt_long_outlined),
          selectedIcon: const Icon(Icons.receipt_long),
          label: Text(AppStrings.t('debts', loc)),
        ),
      ],
      if (canViewSuppliers)
        NavigationRailDestination(
          icon: const Icon(Icons.factory_outlined),
          selectedIcon: const Icon(Icons.factory),
          label: Text(AppStrings.t('suppliers', loc)),
        ),
      if (canViewPurchases)
        NavigationRailDestination(
          icon: const Icon(Icons.shopping_cart_outlined),
          selectedIcon: const Icon(Icons.shopping_cart),
          label: Text(AppStrings.t('purchases', loc)),
        ),
      if (canManageUsers)
        NavigationRailDestination(
          icon: const Icon(Icons.people_outline),
          selectedIcon: const Icon(Icons.people),
          label: Text(AppStrings.t('user_list', loc)),
        ),
      if (canViewReports)
        NavigationRailDestination(
          icon: const Icon(Icons.summarize_outlined),
          selectedIcon: const Icon(Icons.summarize),
          label: Text(AppStrings.t('reports', loc)),
        ),
      if (canManageDevices)
        NavigationRailDestination(
          icon: const Icon(Icons.devices_outlined),
          selectedIcon: const Icon(Icons.devices),
          label: Text(AppStrings.t('lan_devices_title', loc)),
        ),
      NavigationRailDestination(
        icon: const Icon(Icons.settings_outlined),
        selectedIcon: const Icon(Icons.settings),
        label: Text(AppStrings.t('settings', loc)),
      ),
    ];

    int? selectedIndex;
    var index = 0;
    if (location == '/') {
      selectedIndex = index;
    }
    if (canSell) {
      index += 1;
      if (location == '/pos') selectedIndex = index;
    }
    if (canViewReturns) {
      index += 1;
      if (location == '/returns') selectedIndex = index;
    }
    if (canViewExpenses) {
      index += 1;
      if (location == '/expenses') selectedIndex = index;
    }
    if (canViewProducts) {
      index += 1;
      if (location == '/products') selectedIndex = index;
      index += 1;
      if (location == '/packs') selectedIndex = index;
    }
    if (canViewInventory) {
      index += 1;
      if (location == '/stock') selectedIndex = index;
    }
    if (canViewCustomers) {
      index += 1;
      if (location == '/clients') selectedIndex = index;
      index += 1;
      if (location == '/debts') selectedIndex = index;
    }
    if (canViewSuppliers) {
      index += 1;
      if (location == '/suppliers') selectedIndex = index;
    }
    if (canViewPurchases) {
      index += 1;
      if (location == '/purchases') selectedIndex = index;
    }
    if (canManageUsers) {
      index += 1;
      if (location == '/users') selectedIndex = index;
    }
    if (canViewReports) {
      index += 1;
      if (location == '/reports') selectedIndex = index;
    }
    if (canManageDevices) {
      index += 1;
      if (location == '/devices') selectedIndex = index;
    }
    index += 1;
    if (location == '/settings') selectedIndex = index;

    void onDestinationSelected(int target) {
      var i = 0;
      if (i++ == target) {
        context.go('/');
        return;
      }
      if (canSell && i++ == target) {
        context.go('/pos');
        return;
      }
      if (canViewReturns && i++ == target) {
        context.go('/returns');
        return;
      }
      if (canViewExpenses && i++ == target) {
        context.go('/expenses');
        return;
      }
      if (canViewProducts && i++ == target) {
        context.go('/products');
        return;
      }
      if (canViewProducts && i++ == target) {
        context.go('/packs');
        return;
      }
      if (canViewInventory && i++ == target) {
        context.go('/stock');
        return;
      }
      if (canViewCustomers && i++ == target) {
        context.go('/clients');
        return;
      }
      if (canViewCustomers && i++ == target) {
        context.go('/debts');
        return;
      }
      if (canViewSuppliers && i++ == target) {
        context.go('/suppliers');
        return;
      }
      if (canViewPurchases && i++ == target) {
        context.go('/purchases');
        return;
      }
      if (canManageUsers && i++ == target) {
        context.go('/users');
        return;
      }
      if (canViewReports && i++ == target) {
        context.go('/reports');
        return;
      }
      if (canManageDevices && i++ == target) {
        context.go('/devices');
        return;
      }
      if (i++ == target) {
        context.go('/settings');
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.t('app_name', loc)),
        actions: [
          // Phase 16: steady-state LAN health indicator (§14 — chip only,
          // never a modal once the wizard is done).
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: ConnectionStatusChip(),
          ),
          if (user != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
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
          if (destinations.isNotEmpty) ...[
            NavigationRail(
              // QA fix round (Bug 2): with all destinations + labels the
              // rail's internal destination Column overflows on short
              // windows. `scrollable: true` wraps it in the framework's
              // own scroll view — no destination is hidden or removed,
              // tall-window layout is unchanged (content still sizes to
              // its intrinsic height and is aligned as before).
              scrollable: true,
              selectedIndex: selectedIndex,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: child),
        ],
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
