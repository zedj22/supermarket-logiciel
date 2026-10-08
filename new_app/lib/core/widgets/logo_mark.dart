import 'package:flutter/material.dart';

/// The product mark: a rounded tile carrying the storefront glyph.
///
/// There is no image asset in the bundle on purpose — the app must look
/// identical on every machine, offline, with no font or image fetch, so
/// the mark is drawn from the theme accent and a Material icon.
class AppLogoMark extends StatelessWidget {
  const AppLogoMark({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [accent, accent.withValues(alpha: 0.75)],
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: Icon(
        Icons.storefront,
        size: size * 0.58,
        color: Colors.white,
      ),
    );
  }
}
