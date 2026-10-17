import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A labelled block inside a screen: accent chip + title + a rule that runs
/// to the end of the row.
///
/// Used by Reports section breaks, Dashboard panels and Devices groups so
/// they all read as the same kind of object.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.titleKey,
    this.accent,
    this.icon,
    this.trailing,
    this.dense = false,
  });

  final String title;

  /// Localization key the title came from — also drives the finder key
  /// (`report-section-<key>`), which the report tests rely on.
  final String? titleKey;

  /// Semantic accent (`null` → theme primary). Drives the chip and the
  /// rule tint only.
  final Color? accent;

  final IconData? icon;

  final Widget? trailing;

  /// Tighter vertical rhythm for headers stacked inside a scroll view.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(top: dense ? 4 : 16, bottom: dense ? 4 : 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 15, color: color),
            ),
            const SizedBox(width: 8),
          ],
          // Flexible, not bare: inside a Row the title gets unbounded
          // width, so `overflow: ellipsis` never engages and a long
          // localized title pushes the rule (and any trailing action)
          // past the right edge instead of shrinking.
          Flexible(
            child: Text(
              title,
              key: titleKey == null ? null : Key('report-section-$titleKey'),
              style: AppTheme.sectionTitle(theme),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}
