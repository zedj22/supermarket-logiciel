// Customer picker dialog (F6) — search name/phone via GET /customers/search.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
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

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final state = ref.watch(customerSearchProvider);

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
