// Legacy POS catalog layout for widget tests.
//
// `show_pos_product_list` is OFF by default for every installation (the
// scanner-first POS hides the product catalog and gives the workspace to the
// cart). A suite that exercises the catalog, its packs/favorites rows or the
// panel layout therefore opts in explicitly, exactly like an administrator
// would from Settings.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';

/// Provider override that turns `show_pos_product_list` ON for one test run.
///
/// Constructed without `SharedPreferences` on purpose: the state is set
/// synchronously in memory and never persisted between tests.
Override posCatalogMode() => posSettingsProvider.overrideWith(
      (ref) => PosSettingsNotifier()..setShowPosProductList(true),
    );
