// Documentation Center — reusable presentation widgets (Phase 3).
// Kept separate from the screen so the screen stays a thin layout +
// state shell; Phase 4 chapters reuse these unchanged.
import 'package:flutter/material.dart';

import '../../core/strings.dart';
import '../../theme/app_theme.dart';
import 'doc_content.dart';
import 'doc_models.dart';
import 'doc_registry.dart';

/// Search input with a leading icon and a clear button while non-empty.
class DocSearchField extends StatelessWidget {
  const DocSearchField({
    super.key,
    required this.controller,
    required this.loc,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String loc;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      textField: true,
      label: AppStrings.t('documentation_search_hint', loc),
      child: TextField(
        key: const Key('documentation-search-field'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: AppStrings.t('documentation_search_hint', loc),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('documentation-search-clear'),
                  tooltip: AppStrings.t('documentation_search_clear', loc),
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: onClear,
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}

/// Sidebar list of chapters and their articles. The current article is
/// highlighted; chapter headers use the same tone as the nav rail.
class DocSidebar extends StatelessWidget {
  const DocSidebar({
    super.key,
    required this.loc,
    required this.selectedArticleId,
    required this.onSelectArticle,
  });

  final String loc;
  final String selectedArticleId;
  final ValueChanged<DocArticle> onSelectArticle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      key: const Key('documentation-sidebar'),
      padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 8, 16),
      children: [
        for (final chapter in docChapters) ...[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 16, 12, 4),
            child: Row(
              key: Key('documentation-chapter-${chapter.id}'),
              children: [
                Icon(
                  chapter.icon,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    docT(chapter.titleKey, loc),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final article in chapter.articles)
            ListTile(
              key: Key('documentation-article-${article.id}'),
              dense: true,
              selected: article.id == selectedArticleId,
              selectedTileColor:
                  theme.colorScheme.primary.withValues(alpha: 0.10),
              title: Text(
                docT(article.titleKey, loc),
                style: theme.textTheme.bodyMedium,
              ),
              onTap: () => onSelectArticle(article),
            ),
        ],
      ],
    );
  }
}

/// Renders one article: breadcrumb, title, summary, then each section.
/// When [anchorSectionId] is set, the view scrolls that section into
/// view once after the first layout.
class DocArticleView extends StatefulWidget {
  const DocArticleView({
    super.key,
    required this.article,
    required this.loc,
    this.anchorSectionId,
  });

  final DocArticle article;
  final String loc;
  final String? anchorSectionId;

  @override
  State<DocArticleView> createState() => _DocArticleViewState();
}

class _DocArticleViewState extends State<DocArticleView> {
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{};
  String? _pendingAnchor;

  @override
  void initState() {
    super.initState();
    _pendingAnchor = widget.anchorSectionId;
  }

  @override
  void didUpdateWidget(DocArticleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article.id != widget.article.id ||
        oldWidget.anchorSectionId != widget.anchorSectionId) {
      _pendingAnchor = widget.anchorSectionId;
    }
  }

  void _scrollToAnchor() {
    final anchor = _pendingAnchor;
    _pendingAnchor = null;
    if (anchor == null) return;
    final key = _sectionKeys[anchor];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: Duration(
        milliseconds:
            MediaQuery.disableAnimationsOf(context) ? 0 : 200,
      ),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = widget.loc;
    final article = widget.article;
    final chapter = findChapterOf(article);

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor());

    return SingleChildScrollView(
      key: const Key('documentation-article-view'),
      padding: const EdgeInsetsDirectional.fromSTEB(24, 16, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Breadcrumb.
              Row(
                key: const Key('documentation-breadcrumb'),
                children: [
                  Flexible(
                    child: Text(
                      [
                        if (chapter != null) docT(chapter.titleKey, loc),
                        docT(article.titleKey, loc),
                      ].join(' › '),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                docT(article.titleKey, loc),
                key: const Key('documentation-title'),
                style: AppTheme.pageTitle(theme),
              ),
              const SizedBox(height: 6),
              Text(
                docT(article.summaryKey, loc),
                key: const Key('documentation-summary'),
                style: AppTheme.body(theme).copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 20),
              // Phase 4: article screenshots (always empty until a safe
              // demo-dataset capture exists; see screenshotRefs).
              for (final ref in article.screenshotRefs) ...[
                Semantics(
                  image: true,
                  label: '${docT(article.titleKey, loc)} — $ref',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/docshots/$ref',
                      key: Key('documentation-screenshot-$ref'),
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              for (final section in article.sections) ...[
                KeyedSubtree(
                  key: _sectionKeys.putIfAbsent(
                    section.id,
                    () => GlobalKey(debugLabel: 'doc-section-${section.id}'),
                  ),
                  child: _SectionView(section: section, loc: loc, theme: theme),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  DocChapter? findChapterOf(DocArticle article) =>
      findDocChapter(article.chapterId);
}

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.section,
    required this.loc,
    required this.theme,
  });

  final DocSection section;
  final String loc;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final secondary = theme.colorScheme.onSurface.withValues(alpha: 0.75);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          docT(section.headingKey, loc),
          style: AppTheme.sectionTitle(theme),
        ),
        const SizedBox(height: 8),
        for (final block in section.blocks) ...[
          if (block.kind == DocBlockKind.paragraph)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                docT(block.textKey!, loc),
                style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
              ),
            )
          else if (block.kind == DocBlockKind.steps)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < block.steps.length; i++)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i + 1}. ',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              docT(block.steps[i], loc),
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: secondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          else if (block.kind == DocBlockKind.tip)
            _Callout(
              icon: Icons.tips_and_updates_outlined,
              iconColor: theme.colorScheme.primary,
              text: docT(block.textKey!, loc),
              loc: loc,
              semanticLabel: AppStrings.t('documentation_tip', loc),
            )
          else if (block.kind == DocBlockKind.warning)
            _Callout(
              icon: Icons.warning_amber_outlined,
              iconColor: theme.colorScheme.error,
              text: docT(block.textKey!, loc),
              loc: loc,
              semanticLabel: AppStrings.t('documentation_warning', loc),
            ),
        ],
      ],
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.loc,
    required this.semanticLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String text;
  final String loc;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '$semanticLabel: $text',
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: BorderDirectional(
            start: BorderSide(color: iconColor, width: 3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty / no-results state used by the search area and the initial view.
class DocEmptyState extends StatelessWidget {
  const DocEmptyState({
    super.key,
    required this.icon,
    required this.messageKey,
    required this.loc,
  });

  final IconData icon;
  final String messageKey;
  final String loc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.t(messageKey, loc),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Previous / next article navigation across the whole manual.
class DocPrevNextBar extends StatelessWidget {
  const DocPrevNextBar({
    super.key,
    required this.loc,
    required this.previousId,
    required this.nextId,
    required this.onTap,
  });

  final String loc;
  final String? previousId;
  final String? nextId;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final prevTitle =
        previousId != null ? _titleFor(previousId!, loc) : null;
    final nextTitle = nextId != null ? _titleFor(nextId!, loc) : null;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 24),
      child: Row(
        children: [
          Expanded(
            child: previousId == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('documentation-prev'),
                      onPressed: () => onTap(previousId!),
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: Text(
                        '${AppStrings.t('documentation_prev', loc)}\n$prevTitle',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: nextId == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      key: const Key('documentation-next'),
                      onPressed: () => onTap(nextId!),
                      icon: const Icon(Icons.chevron_right, size: 18),
                      label: Text(
                        '${AppStrings.t('documentation_next', loc)}\n$nextTitle',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static String _titleFor(String articleId, String loc) {
    final article = findDocArticle(articleId);
    if (article == null) return articleId;
    return docT(article.titleKey, loc);
  }
}
