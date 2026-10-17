/// Shared presentation building blocks (Phase 17 UI polish).
///
/// Nothing in here knows about a specific screen: a table header, a page
/// title, a section rule, a status chip and the empty/loading states are
/// the same object on Products, Reports, Inventory and Purchases. Screens
/// supply localized strings and column specs; the *look* lives here and in
/// `lib/theme/app_theme.dart`.
library;

export 'h_scroll_view.dart';
export 'logo_mark.dart';
export 'page_title.dart';
export 'section_header.dart';
export 'state_views.dart';
export 'status_chip.dart';
export 'table_header.dart';
