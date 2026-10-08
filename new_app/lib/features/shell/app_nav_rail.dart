import 'package:flutter/material.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../theme/app_theme.dart';
import 'nav_items.dart';

/// The grouped navigation sidebar.
///
/// One widget owns the whole rail — group kickers, the selected tile and
/// the collapsible groups — and it is fed by [buildNavGroups], the single
/// source of truth for what a user may see. Permission filtering happens
/// *before* the widget is built (the shell passes only the visible
/// groups), so this widget has no idea what a scope is; it just renders
/// what it is given, in that order.
///
/// Collapsing is a pure presentation affordance: a group opens by default,
/// and the group containing the *current* page is always forced open so a
/// destination is never hidden behind its own header while you are on it.
class AppNavRail extends StatefulWidget {
  const AppNavRail({
    super.key,
    required this.location,
    required this.groups,
    required this.onNavigate,
  });

  /// Current route (from `state.matchedLocation`).
  final String location;

  /// Already permission-filtered groups, in display order.
  final List<NavGroup> groups;

  /// Opens a destination (`context.go(path)`).
  final ValueChanged<String> onNavigate;

  /// Rail width: room for "Approvisionnement" and "Returns history" on one
  /// line, without eating the content column (the Products workspace test
  /// requires >75% of the window to stay with the page).
  static const double width = 216;

  @override
  State<AppNavRail> createState() => _AppNavRailState();
}

class _AppNavRailState extends State<AppNavRail> {
  /// Title keys of the groups the user folded away.
  final Set<String> _collapsed = <String>{};

  bool _isActive(NavGroup group) =>
      group.items.any((item) => item.path == widget.location);

  bool _isExpanded(NavGroup group) =>
      !_collapsed.contains(group.titleKey) || _isActive(group);

  void _toggle(NavGroup group) {
    setState(() {
      if (!_collapsed.remove(group.titleKey)) {
        // Never fold the group the current page lives in — the selected
        // tile would disappear under its own header.
        if (!_isActive(group)) _collapsed.add(group.titleKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final accent = theme.colorScheme.primary;
    final brightness = theme.brightness;

    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        width: AppNavRail.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final group in widget.groups) ...[
                      _GroupHeader(
                        titleKey: group.titleKey,
                        title: AppStrings.t(group.titleKey, loc),
                        expanded: _isExpanded(group),
                        onTap: () => _toggle(group),
                      ),
                      if (_isExpanded(group))
                        for (final item in group.items)
                          _DestinationTile(
                            path: item.path,
                            label: AppStrings.t(item.labelKey, loc),
                            icon: item.icon,
                            selectedIcon: item.selectedIcon,
                            selected: item.path == widget.location,
                            accent: accent,
                            brightness: brightness,
                            onTap: () => widget.onNavigate(item.path),
                          ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section kicker: label pinned to the start, fold marker at the end.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.titleKey,
    required this.title,
    required this.expanded,
    required this.onTap,
  });

  /// Localization key — also the stable finder key, so tests do not care
  /// which language the kicker happens to render in.
  final String titleKey;
  final String title;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 3),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  key: Key('nav-group-$titleKey'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.navGroupLabel(theme).copyWith(
                    color: theme.textTheme.labelSmall?.color,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Vertical chevrons mirror on their own when they are the
              // horizontal pair (chevron_right is registered as a mirrored
              // icon in the RTL test), so a folded group always points
              // "forward" in both directions.
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: theme.textTheme.labelSmall?.color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One destination row: icon + label, accent wash and a leading accent
/// bar when it is the page you are on.
class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.accent,
    required this.brightness,
    required this.onTap,
  });

  /// Route — the stable finder key (`nav-item-/pos`).
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final Color accent;
  final Brightness brightness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = selected
        ? AppTheme.navItemLabel(theme).copyWith(
            fontWeight: FontWeight.w700,
            color: accent,
          )
        : AppTheme.navItemLabel(theme);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        key: Key('nav-item-$path'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.selectedFill(accent, brightness)
                : null,
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? BorderDirectional(
                    start: BorderSide(color: accent, width: 3),
                  )
                : null,
          ),
          child: Row(
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 20,
                color: selected
                    ? accent
                    : theme.textTheme.bodySmall?.color ??
                        theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
