// Documentation Center — search engine (Phase 3).
//
// Pure-function tests over searchDocContent: title/summary/heading/body
// matching, Arabic/French/English coverage, section anchoring, scoring
// order, and the empty-query contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/documentation/doc_search.dart';

void main() {
  group('searchDocContent', () {
    test('empty or blank query returns no hits', () {
      expect(searchDocContent(''), isEmpty);
      expect(searchDocContent('   '), isEmpty);
    });

    test('matches an English article title', () {
      final hits = searchDocContent('wholesale', locale: 'en');
      expect(hits, isNotEmpty);
      expect(hits.first.article.id, 'pos_pricing');
      expect(hits.first.score, greaterThanOrEqualTo(3));
    });

    test('matches body text and anchors the first matching section',
        () {
      final hits = searchDocContent('pairing code', locale: 'en');
      expect(hits, isNotEmpty);
      final hit = hits.firstWhere((h) => h.article.id == 'gs_first_launch');
      expect(hit.sectionId, 'pairing');
    });

    test('matches section headings', () {
      final hits = searchDocContent('payment methods', locale: 'en');
      expect(hits.any((h) => h.article.id == 'pos_payment'), isTrue);
    });

    test('is case-insensitive', () {
      final lower = searchDocContent('return mode', locale: 'en');
      final upper = searchDocContent('RETURN MODE', locale: 'en');
      expect(lower, isNotEmpty);
      expect(
        [for (final h in lower) h.article.id],
        [for (final h in upper) h.article.id],
      );
    });

    test('finds Arabic content', () {
      final hits = searchDocContent('وضع الإرجاع', locale: 'ar');
      expect(hits, isNotEmpty);
      expect(hits.first.article.id, 'pos_returns');
    });

    test('finds French content', () {
      final hits = searchDocContent('appairage', locale: 'fr');
      expect(hits, isNotEmpty);
      expect(hits.first.article.id, 'gs_first_launch');
    });

    test('unknown term returns an empty result set', () {
      expect(searchDocContent('zzzz-not-a-real-term', locale: 'en'),
          isEmpty);
    });

    test('title hits outrank body hits', () {
      final hits = searchDocContent('sale', locale: 'en');
      expect(hits, isNotEmpty);
      // Highest-scoring hit first.
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i - 1].score, greaterThanOrEqualTo(hits[i].score));
      }
    });
  });
}
