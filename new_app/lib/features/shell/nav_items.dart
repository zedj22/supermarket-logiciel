import 'package:flutter/material.dart';

/// The scopes that gate a rail destination. One home for them so the
/// shell and the nav model can never drift apart — `ScaffoldWithNav`
/// re-exports these as its own constants for existing callers.
class NavScopes {
  NavScopes._();

  static const String userManage = 'user_manage';
  static const String productView = 'product_view';
  static const String inventoryView = 'inventory_view';
  static const String posSale = 'pos_sale';
  static const String customerView = 'customer_view';
  static const String supplierView = 'supplier_view';
  static const String purchaseView = 'purchase_view';
  static const String returnView = 'pos_return';
  static const String expenseView = 'expense_view';
  static const String promotionView = 'promotion_view';
  static const String reportFinancial = 'report_financial';
  static const String deviceManage = 'device_manage';
}

/// One destination in the rail.
class NavItem {
  const NavItem({
    required this.path,
    required this.labelKey,
    required this.icon,
    required this.selectedIcon,
    this.scope,
  });

  /// Route to open (`context.go`).
  final String path;

  /// Localization key of the visible label.
  final String labelKey;

  final IconData icon;
  final IconData selectedIcon;

  /// Backend scope required to see this item (`null` = always visible).
  final String? scope;

  bool get alwaysVisible => scope == null;
}

/// A labelled section of the rail. Groups are *business* groupings
/// (Sales, Catalog, People…), never a technical layer, and they keep the
/// destinations in the order the store already knows them.
class NavGroup {
  const NavGroup({required this.titleKey, required this.items});

  final String titleKey;
  final List<NavItem> items;
}

/// The single source of truth for the navigation rail.
///
/// The permission question is answered exactly once per scope through
/// [can], and the *same* list drives the visible items, the selected
/// highlight and the tap targets — the old code kept three hand-maintained
/// copies of this sequence (destinations, selectedIndex,
/// onDestinationSelected) that had to be edited in lockstep.
///
/// Group order (each group only holds destinations the user may see):
///
///   Overview      Dashboard
///   Sales         POS · Returns · Expenses
///   Catalog       Products · Packs · Promotions · Stock
///   People        Clients · Debts · Users
///   Supply        Suppliers · Purchases
///   Insights      Reports
///   Administration Devices · Settings
///
/// Empty groups are dropped, so a cashier without reports/suppliers sees
/// no orphaned headers.
List<NavGroup> buildNavGroups({required bool Function(String scope) can}) {
  final groups = <NavGroup>[
    NavGroup(
      titleKey: 'nav_group_overview',
      items: const [
        NavItem(
          path: '/',
          labelKey: 'dashboard',
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
        ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_sales',
      items: [
        if (can(NavScopes.posSale))
          const NavItem(
            path: '/pos',
            labelKey: 'pos',
            icon: Icons.point_of_sale_outlined,
            selectedIcon: Icons.point_of_sale,
            scope: NavScopes.posSale,
          ),
        if (can(NavScopes.returnView))
          const NavItem(
            path: '/returns',
            labelKey: 'returns_history',
            icon: Icons.undo_outlined,
            selectedIcon: Icons.undo,
            scope: NavScopes.returnView,
          ),
        if (can(NavScopes.expenseView))
          const NavItem(
            path: '/expenses',
            labelKey: 'expenses',
            icon: Icons.payments_outlined,
            selectedIcon: Icons.payments,
            scope: NavScopes.expenseView,
          ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_catalog',
      items: [
        if (can(NavScopes.productView)) ...[
          const NavItem(
            path: '/products',
            labelKey: 'products',
            icon: Icons.inventory_2_outlined,
            selectedIcon: Icons.inventory_2,
            scope: NavScopes.productView,
          ),
          const NavItem(
            path: '/packs',
            labelKey: 'packs',
            icon: Icons.local_offer_outlined,
            selectedIcon: Icons.local_offer,
            scope: NavScopes.productView,
          ),
        ],
        if (can(NavScopes.promotionView))
          const NavItem(
            path: '/promotions',
            labelKey: 'promotions',
            icon: Icons.sell_outlined,
            selectedIcon: Icons.sell,
            scope: NavScopes.promotionView,
          ),
        if (can(NavScopes.inventoryView))
          const NavItem(
            path: '/stock',
            labelKey: 'stock',
            icon: Icons.warehouse_outlined,
            selectedIcon: Icons.warehouse,
            scope: NavScopes.inventoryView,
          ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_people',
      items: [
        if (can(NavScopes.customerView)) ...[
          const NavItem(
            path: '/clients',
            labelKey: 'clients',
            icon: Icons.contact_phone_outlined,
            selectedIcon: Icons.contact_phone,
            scope: NavScopes.customerView,
          ),
          const NavItem(
            path: '/debts',
            labelKey: 'debts',
            icon: Icons.receipt_long_outlined,
            selectedIcon: Icons.receipt_long,
            scope: NavScopes.customerView,
          ),
        ],
        if (can(NavScopes.userManage))
          const NavItem(
            path: '/users',
            labelKey: 'user_list',
            icon: Icons.people_outline,
            selectedIcon: Icons.people,
            scope: NavScopes.userManage,
          ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_supply',
      items: [
        if (can(NavScopes.supplierView))
          const NavItem(
            path: '/suppliers',
            labelKey: 'suppliers',
            icon: Icons.factory_outlined,
            selectedIcon: Icons.factory,
            scope: NavScopes.supplierView,
          ),
        if (can(NavScopes.purchaseView))
          const NavItem(
            path: '/purchases',
            labelKey: 'purchases',
            icon: Icons.shopping_cart_outlined,
            selectedIcon: Icons.shopping_cart,
            scope: NavScopes.purchaseView,
          ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_insights',
      items: [
        if (can(NavScopes.reportFinancial))
          const NavItem(
            path: '/reports',
            labelKey: 'reports',
            icon: Icons.summarize_outlined,
            selectedIcon: Icons.summarize,
            scope: NavScopes.reportFinancial,
          ),
      ],
    ),
    NavGroup(
      titleKey: 'nav_group_administration',
      items: [
        if (can(NavScopes.deviceManage))
          const NavItem(
            path: '/devices',
            labelKey: 'lan_devices_title',
            icon: Icons.devices_outlined,
            selectedIcon: Icons.devices,
            scope: NavScopes.deviceManage,
          ),
        const NavItem(
          path: '/settings',
          labelKey: 'settings',
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
        ),
      ],
    ),
  ];

  return groups.where((group) => group.items.isNotEmpty).toList();
}
