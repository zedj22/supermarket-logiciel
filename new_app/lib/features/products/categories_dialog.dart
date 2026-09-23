// Manage categories dialog (Phase 5).
//
// List/create/edit/archive categories. Archive (soft-delete) only —
// historical product references are never destroyed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'models.dart';
import 'products_providers.dart';

Future<void> showCategoriesDialog(BuildContext context) {
  return showDialog(context: context, builder: (_) => const CategoriesDialog());
}

class CategoriesDialog extends ConsumerStatefulWidget {
  const CategoriesDialog({super.key});

  @override
  ConsumerState<CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends ConsumerState<CategoriesDialog> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(categoriesProvider.notifier).load(status: 'all'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(categoriesProvider);

    return AlertDialog(
      key: const Key('categories-dialog'),
      title: Text(AppStrings.t('manage_categories', loc)),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: SizedBox(
        width: MediaQuery.of(context).size.width < 700
            ? MediaQuery.of(context).size.width * 0.9
            : 480,
        height: MediaQuery.of(context).size.height < 500
            ? MediaQuery.of(context).size.height * 0.6
            : 360,
        child: state.loading && state.items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : state.error != null && state.items.isEmpty
                ? Center(child: Text(state.error!))
                : state.items.isEmpty
                    ? Center(
                        child: Text(
                          AppStrings.t('no_data', loc),
                          key: const Key('categories-empty'),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: state.items.length,
                        itemBuilder: (context, index) {
                          final category = state.items[index];
                          return ListTile(
                            key: Key('category-row-${category.id}'),
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            title: Text(category.name),
                            subtitle: Text(
                              '${AppStrings.t('products', loc)}: '
                              '${category.productCount}',
                            ),
                            trailing: category.isArchived
                                ? Chip(
                                    label: Text(
                                      AppStrings.t('archived', loc),
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  )
                                : PopupMenuButton<String>(
                                    onSelected: (action) =>
                                        _handleAction(action, category),
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(
                                          AppStrings.t('edit', loc),
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'archive',
                                        child: Text(
                                          AppStrings.t('delete', loc),
                                        ),
                                      ),
                                    ],
                                  ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        ElevatedButton.icon(
          key: const Key('create-category-button'),
          onPressed: () => _showCategoryForm(),
          icon: const Icon(Icons.add),
          label: Text(AppStrings.t('create_category', loc)),
        ),
      ],
    );
  }

  void _handleAction(String action, CategoryModel category) {
    switch (action) {
      case 'edit':
        _showCategoryForm(category: category);
        break;
      case 'archive':
        _confirmArchive(category);
        break;
    }
  }

  void _confirmArchive(CategoryModel category) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.t('delete', loc)),
        content: Text(AppStrings.t('archive_category_confirm', loc)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          TextButton(
            key: const Key('confirm-archive-category'),
            onPressed: () async {
              Navigator.pop(ctx);
              final error = await ref
                  .read(categoriesProvider.notifier)
                  .archive(category.id);
              if (error != null && mounted) {
                _showError(error);
              }
            },
            child: Text(AppStrings.t('confirm', loc)),
          ),
        ],
      ),
    );
  }

  void _showCategoryForm({CategoryModel? category}) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final controller = TextEditingController(text: category?.name ?? '');
    String? error;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            AppStrings.t(
              category != null ? 'edit_category' : 'create_category',
              loc,
            ),
          ),
          content: SizedBox(
            width: MediaQuery.of(context).size.width < 500
                ? MediaQuery.of(context).size.width * 0.8
                : 360,
            child: TextField(
              key: const Key('category-name-field'),
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: AppStrings.t('name', loc),
                errorText: error,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.t('cancel', loc)),
            ),
            ElevatedButton(
              key: const Key('category-form-submit'),
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(
                    () => error = AppStrings.t('name', loc),
                  );
                  return;
                }
                final notifier = ref.read(categoriesProvider.notifier);
                final result = category != null
                    ? await notifier.update(category.id, name)
                    : await notifier.create(name);
                if (!ctx.mounted) return;
                if (result == null) {
                  Navigator.pop(ctx);
                } else {
                  setDialogState(() => error = result);
                }
              },
              child: Text(AppStrings.t('save', loc)),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}
