// Customer picker dialog (F6) — search name/phone via GET /customers/search.
//
// Quick-add: the "Add new customer" button under the search field opens
// the SAME CustomerFormDialog the Clients page uses (one customer
// management implementation, one POST /api/v1/customers). On a successful
// create the picker refreshes its list and pops the freshly created
// customer, so the POS sale selects it immediately — the cart, its
// quantities, discounts and payment state are untouched (only
// `posCartProvider.customer` changes in the caller).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/customer_form_dialog.dart';
import 'pos_models.dart';
import 'pos_providers.dart';

Future<PosCustomer?> showCustomerPickerDialog(BuildContext context) {
  return showDialog<PosCustomer>(
    context: context,
    builder: (_) => const CustomerPickerDialog(),
  );
}

class CustomerPickerDialog extends ConsumerStatefulWidget {
  const CustomerPickerDialog({super.key});

  @override
  ConsumerState<CustomerPickerDialog> createState() =>
      _CustomerPickerDialogState();
}

class _CustomerPickerDialogState extends ConsumerState<CustomerPickerDialog> {
  late final TextEditingController _query;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    Future.microtask(() {
      ref.read(customerSearchProvider.notifier).setQuery('');
      ref.read(customerSearchProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Quick-add: open the customer form, then select the freshly created
  /// customer without leaving the POS screen. The typed query is reset so
  /// the refreshed list actually contains the new customer. A cancelled
  /// or failed create pops null from the form — the picker stays open and
  /// NOTHING is selected (the current cart customer is kept).
  Future<void> _quickAddCustomer() async {
    final created = await showCustomerFormDialog(context);
    if (created == null || !mounted) return;
    _query.clear();
    final search = ref.read(customerSearchProvider.notifier);
    search.setQuery('');
    await search.load();
    if (!mounted) return;
    Navigator.pop(
      context,
      PosCustomer(
        id: created.id,
        name: created.name,
        phone: created.phone,
        balance: double.tryParse(created.balance) ?? 0,
        isArchived: created.isArchived,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final state = ref.watch(customerSearchProvider);
    // Backend POST /api/v1/customers requires CUSTOMER_MANAGE — same
    // gate the Clients screen's add button uses.
    final canManage = ref.watch(hasPermissionProvider('customer_manage'));

    return AlertDialog(
      key: const Key('customer-picker-dialog'),
      title: Text(AppStrings.t('select_customer', loc)),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('customer-search-input'),
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(
                labelText: AppStrings.t('search_customers', loc),
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (v) =>
                  ref.read(customerSearchProvider.notifier).setQuery(v),
            ),
            const SizedBox(height: 12),
            // Quick-add sits directly under the search field, so it is
            // also the empty-results affordance ("no customers found"
            // renders right below it).
            if (canManage)
              OutlinedButton.icon(
                key: const Key('customer-quick-add'),
                onPressed: _quickAddCustomer,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: Text(AppStrings.t('quick_add_customer', loc)),
              ),
            const SizedBox(height: 12),
            if (state.loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.error != null)
              Expanded(
                child: Center(
                  child: Text(
                    state.error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              )
            else if (state.items.isEmpty)
              Expanded(
                child: Center(
                  child: Text(AppStrings.t('no_customers_found', loc)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: state.items.length,
                  itemBuilder: (context, index) {
                    final customer = state.items[index];
                    return ListTile(
                      key: Key('customer-row-${customer.id}'),
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(customer.name),
                      subtitle: customer.phone == null
                          ? null
                          : Text(customer.phone!),
                      onTap: () => Navigator.pop(context, customer),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('customer-clear'),
          onPressed: () => Navigator.pop(context, null),
          child: Text(AppStrings.t('walk_in_customer', loc)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
      ],
    );
  }
}
