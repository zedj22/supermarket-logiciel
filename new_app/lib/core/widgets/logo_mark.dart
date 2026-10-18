import 'package:flutter/material.dart';

import 'klick_logo.dart';

/// The product mark: the drawn Klick POS cart.
///
/// There is no image asset in the bundle on purpose — the app must look
/// identical on every machine, offline, with no font or image fetch, so
/// the mark is vector-drawn and tinted with the current theme accent.
class AppLogoMark extends StatelessWidget {
  const AppLogoMark({super.key, this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    return KlickPosLogo(
      size: size,
      markColor: Theme.of(context).colorScheme.primary,
    );
  }
}
