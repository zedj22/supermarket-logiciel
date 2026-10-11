// Documentation Center — main screen (Phase 3).
//
// Desktop layout: search + chapter/article sidebar on wide windows; on
// narrow windows the sidebar collapses into chapter and article
// dropdowns. Search replaces the reading area with live results; picking
// a result opens the article and anchors the matching section.
//
// Additive only: static content from the registry, no network calls, no
// business logic. Motion ≤ 300 ms and fully disabled under reduced
// motion.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import 'doc_content.dart';
import 'doc_models.dart';
import 'doc_registry.dart';
import 'doc_search.dart';
import 'doc_widgets.dart';

/// Sidebar/dropdown switch point.
const double kDocNarrowBreakpoint = 860;

class DocumentationScreen extends ConsumerStatefulWidget {
  const DocumentationScreen({super.key});

  @override
  ConsumerState<DocumentationScreen> createState() =>
      _DocumentationScreenState();
}

class _DocumentationScreenState extends ConsumerState<DocumentationScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// Live query driving the results view.
  String _query = '';

  late String _selectedArticleId;

  /// Section to scroll to after opening an article from a search hit.
  String? _anchorSectionId;

  @override
  void initState() {
    super.initState();
    _selectedArticleId = allDocArticles().first.id;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectArticle(String articleId, {String? sectionId}) {
    final article = findDocArticle(articleId);
    if (article == null) return;
    setState(() {
      _selectedArticleId = articleId;
      _anchorSectionId = sectionId;
      if (_query.isNotEmpty) {
        _query = '';
        _searchController.clear();
      }
    });
  }

  void _clearSearch() {
    setState(() {
      _query = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final article = findDocArticle(_selectedArticleId)!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < kDocNarrowBreakpoint;
        return Column(
          key: const Key('documentation-screen'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (narrow) _buildNarrowHeader(loc, article),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!narrow)
                    SizedBox(
                      width: 300,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(
                                12, 16, 12, 8),
                            child: DocSearchField(
                              controller: _searchController,
                              loc: loc,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                              onClear: _clearSearch,
                            ),
                          ),
                          Expanded(
                            child: DocSidebar(
                              loc: loc,
                              selectedArticleId: _selectedArticleId,
                              onSelectArticle: (a) => _selectArticle(a.id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!narrow) const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: _buildContentArea(loc, article, reduceMotion)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // -- narrow header -------------------------------------------------------

  Widget _buildNarrowHeader(String loc, DocArticle current) {
    final chapter = findDocChapter(current.chapterId)!;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DocSearchField(
            controller: _searchController,
            loc: loc,
            onChanged: (value) => setState(() => _query = value),
            onClear: _clearSearch,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: AppStrings.t('documentation_chapter', loc),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const Key('documentation-chapter-dropdown'),
                      value: chapter.id,
                      isExpanded: true,
                      items: [
                        for (final c in docChapters)
                          DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              docT(c.titleKey, loc),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (chapterId) {
                        final c = findDocChapter(chapterId ?? chapter.id);
                        if (c != null && c.articles.isNotEmpty) {
                          _selectArticle(c.articles.first.id);
                        }
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: AppStrings.t('documentation_article', loc),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const Key('documentation-article-dropdown'),
                      value: current.id,
                      isExpanded: true,
                      items: [
                        for (final a in chapter.articles)
                          DropdownMenuItem(
                            value: a.id,
                            child: Text(
                              docT(a.titleKey, loc),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (articleId) {
                        if (articleId != null) _selectArticle(articleId);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, thickness: 1),
        ],
      ),
    );
  }

  // -- content area --------------------------------------------------------

  Widget _buildContentArea(
    String loc,
    DocArticle current,
    bool reduceMotion,
  ) {
    final Widget child;
    if (_query.trim().isNotEmpty) {
      child = _buildSearchResults(loc);
    } else {
      child = Column(
        children: [
          Expanded(
            child: DocArticleView(
              article: current,
              loc: loc,
              anchorSectionId: _anchorSectionId,
            ),
          ),
          Builder(
            builder: (context) => DocPrevNextBar(
              loc: loc,
              previousId: adjacentDocArticleId(current.id, next: false),
              nextId: adjacentDocArticleId(current.id, next: true),
              onTap: (id) => _selectArticle(id),
            ),
          ),
        ],
      );
    }

    if (reduceMotion) return child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: KeyedSubtree(
        key: ValueKey<String>(
          _query.trim().isEmpty
              ? 'article-${current.id}'
              : 'results-$_query',
        ),
        child: child,
      ),
    );
  }

  Widget _buildSearchResults(String loc) {
    final hits = searchDocContent(_query, locale: loc);
    if (hits.isEmpty) {
      return DocEmptyState(
        key: const Key('documentation-no-results'),
        icon: Icons.search_off,
        messageKey: 'documentation_no_results_hint',
        loc: loc,
      );
    }
    return ListView.separated(
      key: const Key('documentation-results'),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 24),
      itemCount: hits.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              AppStrings.t('documentation_search_results', loc),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }
        final hit = hits[index - 1];
        final chapter = findDocChapter(hit.article.chapterId);
        return Card(
          key: Key('documentation-result-${hit.article.id}'),
          margin: EdgeInsets.zero,
          child: ListTile(
            title: Text(docT(hit.article.titleKey, loc)),
            subtitle: Text(
              [
                if (chapter != null) docT(chapter.titleKey, loc),
                docT(hit.article.summaryKey, loc),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _selectArticle(
              hit.article.id,
              sectionId: hit.sectionId,
            ),
          ),
        );
      },
    );
  }
}
