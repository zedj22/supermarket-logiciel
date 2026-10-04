import 'package:flutter/material.dart';

import '../../core/strings.dart';

/// Placeholder for the Phase 2 sales list (route `/sales`).
///
/// Every visible string goes through `AppStrings.t` — a screen reached by
/// URL must not answer in English regardless of the operator's language.
class SalesScreen extends StatelessWidget {
  const SalesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.t('sales', loc))),
      body: Center(
        child: Text(AppStrings.t('no_data', loc)),
      ),
    );
  }
}
