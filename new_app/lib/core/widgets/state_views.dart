import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The one "nothing here yet" surface: icon in a tinted circle, one line of
/// localized copy, and an optional action.
///
/// Screens previously each grew their own `Center(Text('no_data'))`, which
/// is why empty pages felt like a rendering bug rather than a state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.accent,
    this.action,
    this.testKey = const Key('empty-state'),
    this.messageKey,
    this.compact = false,
  });

  final String message;
  final IconData icon;

  /// Semantic accent (`null` → theme primary).
  final Color? accent;

  /// Optional recovery/next-step control.
  final Widget? action;

  final Key testKey;

  /// Finder key for the copy itself, when a test asserts on the text.
  final Key? messageKey;

  /// Tighter padding for an empty state nested inside a panel.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    return Center(
      key: testKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 44 : 56,
            height: compact ? 44 : 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: compact ? 22 : 28, color: color),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            key: messageKey,
            textAlign: TextAlign.center,
            style: AppTheme.secondary(theme),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

/// The one "working…" surface. Never shows a bare spinner without copy —
/// an unexplained spinner reads as a hang.
class LoadingState extends StatelessWidget {
  const LoadingState({
    super.key,
    required this.message,
    this.testKey = const Key('loading-state'),
    this.spinnerKey = const Key('loading-spinner'),
  });

  final String message;
  final Key testKey;
  final Key spinnerKey;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: testKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(key: spinnerKey, strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            key: const Key('loading-message'),
            style: AppTheme.secondary(Theme.of(context)),
          ),
        ],
      ),
    );
  }
}
