// Documentation Center — registry integrity (Phase 3).
//
// Pins the stable chapter/article ids (deep-link targets), proves every
// content key resolves in all three locales, and checks the adjacency
// helper used by previous/next navigation.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/documentation/doc_content.dart';
import 'package:supermarket_pos/features/documentation/doc_models.dart';
import 'package:supermarket_pos/features/documentation/doc_registry.dart';

void main() {
  group('Documentation registry', () {
    test('chapter ids are stable and unique', () {
      final ids = [for (final c in docChapters) c.id];
      expect(ids, ['getting_started', 'dashboard', 'pos']);
      expect(ids.toSet().length, ids.length);
    });

    test('article ids are stable, unique and chapter-linked', () {
      final ids = [for (final a in allDocArticles()) a.id];
      expect(ids, [
        'gs_first_launch',
        'gs_admin_login',
        'gs_navigation',
        'gs_workflow',
        'dash_overview',
        'dash_controls',
        'pos_opening',
        'pos_selling',
        'pos_pricing',
        'pos_payment',
        'pos_printing',
        'pos_history',
        'pos_shortcuts',
        'pos_returns',
      ]);
      expect(ids.toSet().length, ids.length);
      for (final article in allDocArticles()) {
        expect(findDocChapter(article.chapterId), isNotNull,
            reason: '${article.id} points at unknown chapter');
      }
    });

    test('find helpers resolve known ids and reject unknown ones', () {
      expect(findDocChapter('pos'), isNotNull);
      expect(findDocChapter('nope'), isNull);
      expect(findDocArticle('pos_returns'), isNotNull);
      expect(findDocArticle('nope'), isNull);
    });

    test('adjacentDocArticleId walks the global order with ends capped',
        () {
      expect(adjacentDocArticleId('gs_first_launch', next: false), isNull);
      expect(adjacentDocArticleId('gs_first_launch', next: true),
          'gs_admin_login');
      expect(adjacentDocArticleId('pos_returns', next: true), isNull);
      expect(adjacentDocArticleId('pos_returns', next: false),
          'pos_shortcuts');
      expect(adjacentDocArticleId('unknown', next: true), isNull);
    });

    test('every registry content key resolves in ar, fr and en', () {
      final keys = allDocContentKeys().toList();
      expect(keys, isNotEmpty);
      final missing = <String>[];
      for (final key in keys) {
        if (!docKeyResolved(key)) missing.add(key);
      }
      expect(missing, isEmpty,
          reason: 'unresolved/empty doc content keys: $missing');
    });

    test('the three required Phase 3 chapters carry their articles', () {
      expect(findDocChapter('getting_started')!.articles.length, 4);
      expect(findDocChapter('dashboard')!.articles.length, 2);
      expect(findDocChapter('pos')!.articles.length, 8);
      for (final chapter in docChapters) {
        expect(chapter.articles, isNotEmpty);
        for (final article in chapter.articles) {
          expect(article.sections, isNotEmpty,
              reason: '${article.id} has no sections');
        }
      }
    });

    test('docT falls back to English then the raw key', () {
      expect(docT('chapter.pos.title', 'ar'), isNot('chapter.pos.title'));
      expect(docT('chapter.pos.title', 'xx'), docT('chapter.pos.title', 'en'));
      expect(docT('totally.unknown.key', 'en'), 'totally.unknown.key');
    });

    test('content blocks only use supported kinds', () {
      for (final article in allDocArticles()) {
        for (final section in article.sections) {
          for (final block in section.blocks) {
            switch (block.kind) {
              case DocBlockKind.paragraph:
              case DocBlockKind.tip:
              case DocBlockKind.warning:
                expect(block.textKey, isNotNull);
                expect(block.steps, isEmpty);
              case DocBlockKind.steps:
                expect(block.textKey, isNull);
                expect(block.steps, isNotEmpty);
            }
          }
        }
      }
    });
  });
}
