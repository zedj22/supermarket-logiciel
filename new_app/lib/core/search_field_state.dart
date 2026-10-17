import 'package:flutter/widgets.dart';

/// Mirrors a provider's persisted search query into the screen's own
/// [TextEditingController].
///
/// Why this is needed: the query lives in a Riverpod provider, which
/// survives navigation, while the controller dies with the page's
/// [State]. Coming back to a page the provider still filters by the old
/// term but the field renders empty — the filter the user can see in the
/// list is no longer visible (or removable) in the UI that produced it.
///
/// Screens call this from `initState` with the query they are about to
/// load. A short query is not truncated, so the field always shows
/// exactly what the provider is filtering on.
void seedSearchField(TextEditingController controller, String query) {
  if (query.trim().isEmpty || controller.text == query) return;
  controller.value = TextEditingValue(
    text: query,
    selection: TextSelection.collapsed(offset: query.length),
  );
}
