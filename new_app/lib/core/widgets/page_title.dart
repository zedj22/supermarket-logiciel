import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The H1 at the top of a screen: one component so "Reports", "Products",
/// "Inventory"… all sit on the same baseline with the same weight.
///
/// [trailing] renders on the far end (export buttons, refresh, filters) and
/// wraps under the title on a narrow window instead of overflowing.
class PageTitle extends StatelessWidget {
  const PageTitle({
    super.key,
    required this.title,
    this.titleKey,
    this.trailing,
  });

  final String title;

  /// Stable finder key for the title text itself.
  final Key? titleKey;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.pageTitle(Theme.of(context));
    if (trailing == null) {
      return Text(title, key: titleKey, style: style, softWrap: false);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below ~520px the title + action no longer fit on one line.
        if (constraints.maxWidth.isFinite && constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, key: titleKey, style: style, maxLines: 2),
              const SizedBox(height: 8),
              trailing!,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: Text(title, key: titleKey, style: style)),
            const SizedBox(width: 12),
            trailing!,
          ],
        );
      },
    );
  }
}
