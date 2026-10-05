import 'package:flutter/material.dart';

import '../colors.dart';
import '../../theme/app_theme.dart';

/// What a [StatusChip] means. The hue, the tinted fill and the foreground
/// all derive from it — screens never pass a raw [Color].
enum StatusTone { success, warning, error, info, neutral }

/// Compact status/stock badge: a tinted pill with a legible foreground in
/// light, dark *and* grey (the tint + foreground are resolved from the
/// active brightness, see [AppColors.tint]/[AppColors.onTint]).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.leading,
    this.testKey,
    this.dense = false,
  });

  final String label;
  final StatusTone tone;
  final Widget? leading;
  final Key? testKey;

  /// Smaller padding for chips inside a table cell.
  final bool dense;

  Color _accent(BuildContext context) => switch (tone) {
        StatusTone.success => AppColors.success,
        StatusTone.warning => AppColors.warning,
        StatusTone.error => AppColors.error,
        StatusTone.info => AppColors.info,
        StatusTone.neutral => Theme.of(context).colorScheme.onSurface,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final accent = _accent(context);
    final isNeutral = tone == StatusTone.neutral;
    final fill = isNeutral
        ? theme.dividerColor.withValues(
            alpha: brightness == Brightness.light ? 0.55 : 0.75,
          )
        : AppColors.tint(accent, brightness);
    final fg = isNeutral
        ? theme.textTheme.labelSmall?.color ?? theme.colorScheme.onSurface
        : AppColors.onTint(accent, brightness);
    return Container(
      key: testKey,
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 7, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 5)],
          // A Row lays non-flex children out on an unbounded main axis, so the
          // label must be flexible to ellipsize instead of overflowing narrow
          // table cells.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.caption(theme).copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The dot that precedes a status in a few dense lists.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
