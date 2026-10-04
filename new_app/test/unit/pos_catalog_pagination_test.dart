// Phase 17 POS catalog pagination (§11 gates).
//
// The POS browse/search/category catalog now walks the paginated
// GET /api/v1/products endpoint (page_size ≤ 100) and appends pages on
// scroll. Gates covered here:
//   - page-1 contract: path/page/page_size/status, no search/category keys,
//     server totals, `pages` fallback of ceil(total/pageSize)
//   - loadMore: next-page append in order, filter params preserved,
//     dedupe by stable id, hasMore=false stops further requests
//   - guards: no append while a page-1 load or another append is in flight
//   - failures: page-1 error vs append error (rows kept, retry works)
//   - staleness: a slow page-1 or page-2 from an older generation is
//     discarded, never merged into the newer result set
//   - debounce: typing coalesces into one request; clear() cancels it
//   - category: setCategory resets to page 1, switching replaces rows,
//     clear() drops the filter
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

class MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDio dio;
  late PosSearchNotifier notifier;

  /// Every catalog request the notifier issued, in order.
  late List<Map<String, dynamic>> captured;

  const debounceWait = Duration(milliseconds: 350);

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    dio = MockDio();
    captured = <Map<String, dynamic>>[];
    notifier = PosSearchNotifier(dio, () => 'en', pageSize: 3);
  });

  tearDown(() => notifier.dispose());

  Map<String, dynamic> productJson(int n) =>
      {'id': 'p-$n', 'name': 'Product $n'};

  Map<String, dynamic> pageBody({
    required List<int> ids,
    required int total,
    int? pages,
  }) {
    final body = <String, dynamic>{
      'items': [for (final id in ids) productJson(id)],
      'total': total,
    };
    if (pages != null) body['pages'] = pages;
    return body;
  }

  Response<dynamic> ok(Object? data) => Response<dynamic>(
        requestOptions: RequestOptions(path: kPosCatalogPath),
        statusCode: 200,
        data: data,
      );

  DioException serverError() => DioException(
        requestOptions: RequestOptions(path: kPosCatalogPath),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: kPosCatalogPath),
          statusCode: 500,
        ),
        type: DioExceptionType.badResponse,
      );

  void stubWith(
    FutureOr<Response<dynamic>> Function(Map<String, dynamic> params) handler,
  ) {
    when(() => dio.get(
          kPosCatalogPath,
          queryParameters: any(named: 'queryParameters'),
        )).thenAnswer((invocation) async {
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters]! as Map,
      );
      captured.add(params);
      return handler(params);
    });
  }

  /// Flushes microtask work started by a fire-and-forget notifier call
  /// (setCategory / setQuery-triggered loads whose futures aren't returned).
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<String> ids() => notifier.state.items.map((p) => p.id).toList();

  group('page-1 load contract', () {
    test(
        'initial load hits /api/v1/products with page/page_size/status and '
        'no search or category keys', () async {
      stubWith((params) => ok(pageBody(ids: [1, 2, 3], total: 250, pages: 3)));

      await notifier.load();

      expect(captured, hasLength(1));
      expect(captured.single, {
        'page': 1,
        'page_size': 3,
        'status': 'active',
      });
      expect(ids(), ['p-1', 'p-2', 'p-3']);
      expect(notifier.state.currentPage, 1);
      expect(notifier.state.total, 250);
      expect(notifier.state.pages, 3);
      expect(notifier.state.hasMore, isTrue);
      expect(notifier.state.loading, isFalse);
      expect(notifier.state.loadingMore, isFalse);
      expect(notifier.state.error, isNull);
      expect(notifier.state.loadMoreError, isNull);
    });

    test('default page size is kPosCatalogPageSize (backend max is 100)',
        () async {
      expect(kPosCatalogPageSize, 100);
      final fresh = PosSearchNotifier(dio, () => 'en');
      addTearDown(fresh.dispose);
      expect(fresh.state.pageSize, kPosCatalogPageSize);

      stubWith((params) => ok(pageBody(ids: [1], total: 1, pages: 1)));
      await fresh.load();

      expect(captured.single['page_size'], kPosCatalogPageSize);
    });

    test('pages falls back to ceil(total/pageSize) when omitted', () async {
      stubWith((params) => ok(pageBody(ids: [1], total: 250)));

      await notifier.load();

      expect(notifier.state.pages, 84); // ceil(250 / 3)
      expect(notifier.state.hasMore, isTrue);
    });

    test('page-1 failure sets error with no rows; the next load clears it',
        () async {
      stubWith((params) => throw serverError());
      await notifier.load();
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.loading, isFalse);

      stubWith((params) => ok(pageBody(ids: [1], total: 1, pages: 1)));
      await notifier.load();
      expect(notifier.state.error, isNull);
      expect(ids(), ['p-1']);
    });
  });

  group('loadMore append', () {
    test('appends the next page in order and advances currentPage', () async {
      stubWith((params) {
        final page = params['page'] as int;
        return page == 1
            ? ok(pageBody(ids: [1, 2, 3], total: 6, pages: 2))
            : ok(pageBody(ids: [4, 5, 6], total: 6, pages: 2));
      });

      await notifier.load();
      await notifier.loadMore();

      expect(captured, hasLength(2));
      expect(captured[1], {'page': 2, 'page_size': 3, 'status': 'active'});
      expect(ids(), ['p-1', 'p-2', 'p-3', 'p-4', 'p-5', 'p-6']);
      expect(notifier.state.currentPage, 2);
      expect(notifier.state.hasMore, isFalse);
      expect(notifier.state.loadingMore, isFalse);
    });

    test('dedupes ids already on screen (server repeated a row)', () async {
      stubWith((params) {
        final page = params['page'] as int;
        return page == 1
            ? ok(pageBody(ids: [1, 2, 3], total: 6, pages: 2))
            : ok(pageBody(ids: [3, 4], total: 6, pages: 2));
      });

      await notifier.load();
      await notifier.loadMore();

      expect(ids(), ['p-1', 'p-2', 'p-3', 'p-4']);
      expect(notifier.state.currentPage, 2);
    });

    test('stops requesting once the last page is reached', () async {
      stubWith((params) {
        final page = params['page'] as int;
        return page == 1
            ? ok(pageBody(ids: [1, 2, 3], total: 4, pages: 2))
            : ok(pageBody(ids: [4], total: 4, pages: 2));
      });

      await notifier.load();
      await notifier.loadMore();
      expect(notifier.state.hasMore, isFalse);
      final callsAfterLast = captured.length;

      await notifier.loadMore();
      await notifier.loadMore();

      expect(captured, hasLength(callsAfterLast));
      expect(ids(), ['p-1', 'p-2', 'p-3', 'p-4']);
    });

    test('appended pages keep search and category params', () async {
      stubWith((params) {
        final page = params['page'] as int;
        return ok(pageBody(
          ids: page == 1 ? [1, 2] : [3],
          total: 3,
          pages: 2,
        ));
      });

      notifier.setQuery('milk');
      await Future<void>.delayed(debounceWait);
      expect(captured, hasLength(1));
      expect(captured.single['search'], 'milk');

      notifier.setCategory('cat-9');
      await settle();
      expect(captured, hasLength(2));
      expect(captured[1]['page'], 1);
      expect(captured[1]['search'], 'milk');
      expect(captured[1]['category_id'], 'cat-9');
      expect(ids(), ['p-1', 'p-2']); // category switch replaced the rows

      await notifier.loadMore();
      expect(captured, hasLength(3));
      expect(captured[2], {
        'page': 2,
        'page_size': 3,
        'status': 'active',
        'search': 'milk',
        'category_id': 'cat-9',
      });
      expect(ids(), ['p-1', 'p-2', 'p-3']);
    });
  });

  group('guards', () {
    test('loadMore is a no-op while a page-1 load is in flight', () async {
      Completer<Response<dynamic>>? gate;
      stubWith((params) {
        final page = params['page'] as int;
        if (page == 1 && gate != null && !gate.isCompleted) {
          return gate.future;
        }
        return ok(pageBody(ids: [page], total: 4, pages: 2));
      });

      await notifier.load();
      expect(notifier.state.hasMore, isTrue);

      gate = Completer<Response<dynamic>>();
      final inflight = notifier.load();
      await settle();
      expect(notifier.state.loading, isTrue);
      expect(notifier.state.hasMore, isTrue);

      await notifier.loadMore();
      expect(captured.where((p) => p['page'] == 2), isEmpty);

      gate.complete(ok(pageBody(ids: [1], total: 4, pages: 2)));
      await inflight;
    });

    test('a second loadMore while one is in flight issues no extra request',
        () async {
      Completer<Response<dynamic>>? gate;
      stubWith((params) {
        final page = params['page'] as int;
        if (page == 2 && gate != null && !gate.isCompleted) {
          return gate.future;
        }
        return ok(pageBody(ids: [page * 10], total: 20, pages: 3));
      });

      await notifier.load();
      expect(notifier.state.hasMore, isTrue);

      gate = Completer<Response<dynamic>>();
      final first = notifier.loadMore();
      await settle();
      expect(notifier.state.loadingMore, isTrue);

      await notifier.loadMore(); // guarded — no new request
      expect(captured.where((p) => p['page'] == 2), hasLength(1));

      gate.complete(ok(pageBody(ids: [20], total: 20, pages: 3)));
      await first;
      expect(notifier.state.loadingMore, isFalse);
      expect(notifier.state.currentPage, 2);
      expect(ids(), ['p-10', 'p-20']);
    });
  });

  group('append failure', () {
    test('keeps loaded rows, surfaces loadMoreError, and retries cleanly',
        () async {
      var failPage2 = true;
      stubWith((params) {
        final page = params['page'] as int;
        if (page == 2 && failPage2) throw serverError();
        return ok(pageBody(ids: [page], total: 6, pages: 3));
      });

      await notifier.load();
      expect(ids(), ['p-1']);

      await notifier.loadMore();
      expect(notifier.state.loadMoreError, isNotNull);
      expect(ids(), ['p-1']); // rows stay on screen
      expect(notifier.state.currentPage, 1);
      expect(notifier.state.loadingMore, isFalse);
      expect(notifier.state.hasMore, isTrue); // still retryable

      failPage2 = false;
      await notifier.loadMore();
      expect(notifier.state.loadMoreError, isNull);
      expect(ids(), ['p-1', 'p-2']);
      expect(notifier.state.currentPage, 2);
    });
  });

  group('stale responses', () {
    test('a slow page-1 never overwrites newer results', () async {
      final stale = Completer<Response<dynamic>>();
      var page1Calls = 0;
      stubWith((params) {
        page1Calls++;
        if (page1Calls == 1) return stale.future;
        return ok(pageBody(ids: [7], total: 1, pages: 1));
      });

      final old = notifier.load();
      await settle();
      expect(notifier.state.loading, isTrue);

      notifier.setCategory('cat-new'); // bumps the generation + reloads
      await settle();
      expect(captured.last['category_id'], 'cat-new');
      expect(ids(), ['p-7']);

      stale.complete(ok(pageBody(ids: [1, 2], total: 2, pages: 1)));
      await old;

      expect(ids(), ['p-7']); // late page-1 discarded, not merged/replaced
      expect(notifier.state.currentPage, 1);
      expect(notifier.state.loading, isFalse);
    });

    test('a slow page-2 never appends into a changed result set', () async {
      final staleAppend = Completer<Response<dynamic>>();
      var page2Calls = 0;
      stubWith((params) {
        final page = params['page'] as int;
        if (page == 2) {
          page2Calls++;
          if (page2Calls == 1) return staleAppend.future;
          return ok(pageBody(ids: [9], total: 9, pages: 3));
        }
        return ok(pageBody(ids: [1, 2], total: 9, pages: 3));
      });

      await notifier.load();
      expect(ids(), ['p-1', 'p-2']);

      final append = notifier.loadMore(); // gated, loadingMore = true
      await settle();
      expect(notifier.state.loadingMore, isTrue);

      notifier.setQuery('other'); // result set changes mid-append
      staleAppend.complete(ok(pageBody(ids: [5, 6], total: 9, pages: 3)));
      await append;

      // The stale page-2 was dropped: no p-5/p-6 ever appear.
      expect(ids(), ['p-1', 'p-2']);
      expect(notifier.state.currentPage, 1);

      await Future<void>.delayed(debounceWait); // debounced replacement load
      expect(captured.last['page'], 1);
      expect(captured.last['search'], 'other');
      expect(notifier.state.query, 'other');
      expect(notifier.state.loadingMore, isFalse);
      expect(ids(), ['p-1', 'p-2']);
    });
  });

  group('search debounce', () {
    test('typing coalesces into one request with the final query', () async {
      stubWith((params) => ok(pageBody(ids: [1], total: 1, pages: 1)));

      notifier.setQuery('m');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(captured, isEmpty); // still inside the debounce window

      notifier.setQuery('mi');
      notifier.setQuery('milk');
      await Future<void>.delayed(debounceWait);

      expect(captured, hasLength(1));
      expect(captured.single['search'], 'milk');
      expect(notifier.state.query, 'milk');
      expect(ids(), ['p-1']);
    });

    test('clear() cancels a pending search and resets the state', () async {
      stubWith((params) => ok(pageBody(ids: [1], total: 1, pages: 1)));
      await notifier.load();
      expect(captured, hasLength(1));

      notifier.setQuery('bread');
      notifier.clear();
      await Future<void>.delayed(debounceWait);

      expect(captured, hasLength(1)); // debounce cancelled — no request
      expect(notifier.state.query, '');
      expect(notifier.state.items, isEmpty);
      expect(notifier.state.currentPage, 0);
      expect(notifier.state.categoryId, isNull);
      expect(notifier.state.hasMore, isFalse);
      expect(notifier.state.loading, isFalse);
    });
  });

  group('category', () {
    test('setCategory resets to page 1, switching replaces rows, clear '
        'drops the filter', () async {
      stubWith((params) {
        final page = params['page'] as int;
        final cat = params['category_id'];
        return ok(pageBody(
          ids: [page == 1 && cat == 'cat-a' ? 1 : 2],
          total: 1,
          pages: 1,
        ));
      });

      notifier.setCategory('cat-a');
      await settle();
      expect(captured.single, {
        'page': 1,
        'page_size': 3,
        'status': 'active',
        'category_id': 'cat-a',
      });
      expect(ids(), ['p-1']);

      notifier.setCategory('cat-b'); // switch → replacement, not append
      await settle();
      expect(captured.last['category_id'], 'cat-b');
      expect(captured.last['page'], 1);
      expect(notifier.state.currentPage, 1);
      expect(ids(), ['p-2']);

      notifier.clear();
      expect(notifier.state.categoryId, isNull);
      expect(notifier.state.items, isEmpty);

      await notifier.load();
      expect(captured.last.containsKey('category_id'), isFalse);
    });
  });
}
