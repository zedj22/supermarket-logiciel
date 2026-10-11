// Documentation Center — client-side search (Phase 3).
//
// Pure functions over the registry + doc_content.dart. No widgets, no
// providers — unit-testable directly. Matching is case-insensitive for
// Latin scripts and substring-based, so it works for Arabic, French and
// English alike.
import 'doc_content.dart';
import 'doc_models.dart';
import 'doc_registry.dart';

/// One search hit: the matched article plus the first matching section
/// (so the UI can scroll/anchor there), when the match was inside one.
class DocSearchHit {
  const DocSearchHit({
    required this.article,
    this.sectionId,
    required this.score,
  });

  final DocArticle article;
  final String? sectionId;

  /// Higher is better: title 3, summary 2, heading 1.5, body 1.
  final double score;
}

const int _maxHits = 30;

/// Searches [chapters] for [query] in [locale]. Returns hits ordered by
/// score (desc), then registry order. An empty/blank query returns [].
List<DocSearchHit> searchDocContent(
  String query, {
  String locale = 'en',
  List<DocChapter> chapters = const [],
}) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return const [];

  final source = chapters.isEmpty ? docChapters : chapters;
  final hits = <DocSearchHit>[];

  for (final chapter in source) {
    for (final article in chapter.articles) {
      var bestScore = 0.0;
      String? bestSection;

      final title = docT(article.titleKey, locale).toLowerCase();
      final summary = docT(article.summaryKey, locale).toLowerCase();
      if (title.contains(normalized)) bestScore = 3;
      if (bestScore < 2 && summary.contains(normalized)) bestScore = 2;

      for (final section in article.sections) {
        var sectionMatched = false;
        final heading = docT(section.headingKey, locale).toLowerCase();
        if (heading.contains(normalized)) {
          sectionMatched = true;
          if (bestScore < 1.5) bestScore = 1.5;
        }
        for (final block in section.blocks) {
          if (block.kind == DocBlockKind.steps) {
            for (final key in block.steps) {
              if (docT(key, locale).toLowerCase().contains(normalized)) {
                sectionMatched = true;
                if (bestScore < 1) bestScore = 1;
              }
            }
          } else if (block.textKey != null) {
            if (docT(block.textKey!, locale)
                .toLowerCase()
                .contains(normalized)) {
              sectionMatched = true;
              if (bestScore < 1) bestScore = 1;
            }
          }
        }
        if (sectionMatched && bestSection == null) {
          bestSection = section.id;
        }
      }

      if (bestScore > 0) {
        hits.add(DocSearchHit(
          article: article,
          sectionId: bestSection,
          score: bestScore,
        ));
      }
    }
  }

  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    // Stable: registry order for ties.
    final order = <String>[
      for (final a2 in allDocArticles()) a2.id,
    ];
    return order
        .indexOf(a.article.id)
        .compareTo(order.indexOf(b.article.id));
  });

  return hits.length > _maxHits ? hits.sublist(0, _maxHits) : hits;
}
