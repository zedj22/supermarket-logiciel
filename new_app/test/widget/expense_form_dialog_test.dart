// Phase 13 — Expense form + cancellation dialogs (widget tests).
//
// Contracts under test:
//  - create: client-side validation only blocks a non-positive amount —
//    the title is OPTIONAL (Fix Round 2 / B1) and is omitted from the
//    body when blank; the POST carries EXACTLY the backend-accepted
//    fields (`client_request_id`, `title?`, `category`, `amount`,
//    `paid_from_drawer`, `note`) — never `id` / `expense_date` /
//    `user_id` / `status`, so backdating is impossible from the UI
//    (GATE 6/B6).
//  - one `client_request_id` per dialog open (GATE 10).
//  - cancel: a reason is mandatory (localized, never a backend string),
//    the POST body is `{reason}`, and a 409 keeps the dialog open with a
//    localized message.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/expenses/expense_cancel_dialog.dart';
import 'package:supermarket_pos/features/expenses/expense_form_dialog.dart';
import 'package:supermarket_pos/features/expenses/expense_models.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  String? _token;
  List<String> _roles = [];
  List<String> _permissions = [];

  @override
  Future<bool> hasToken() async => _token != null && _token!.isNotEmpty;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveToken(String token) async => _token = token;

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async => _roles = roles;

  @override
  Future<void> saveUserPermissions(List<String> permissions) async =>
      _permissions = permissions;

  @override
  Future<List<String>> readUserRoles() async => _roles;

  @override
  Future<List<String>> readUserPermissions() async => _permissions;

  @override
  Future<void> clearAll() async {
    _token = null;
    _roles = [];
    _permissions = [];
  }
}

const _createPath = '/api/v1/expenses';
const _cancelPath = '/api/v1/expenses/exp-1/cancel';

Map<String, dynamic> _expenseJson({
  String id = 'exp-1',
  String? title = 'Electricity',
  String category = 'utilities',
  String amount = '120.500',
  bool paidFromDrawer = true,
  String status = 'posted',
  bool idempotentReplay = false,
  String? cancelReason,
}) =>
    {
      'id': id,
      'title': title,
      'category': category,
      'amount': amount,
      'paid_from_drawer': paidFromDrawer,
      'note': null,
      'status': status,
      'user_id': '00000000-0000-0000-0000-0000000000a1',
      'device_id': null,
      'client_request_id': 'req-1',
      'expense_date': '2026-09-29T10:00:00Z',
      'cancelled_at': status == 'cancelled'
          ? '2026-09-29T11:00:00Z'
          : null,
      'cancelled_by': status == 'cancelled'
          ? '00000000-0000-0000-0000-0000000000a1'
          : null,
      'cancel_reason': cancelReason,
      'created_at': '2026-09-29T10:00:00Z',
      'updated_at': '2026-09-29T10:00:00Z',
      'idempotent_replay': idempotentReplay,
    };

/// One captured POST (path + body) — the dialog payload contract is
/// asserted from this list.
class _Posted {
  final String path;
  final Map<String, dynamic> data;
  _Posted(this.path, this.data);
}

DioException _envelopeException(String path, int status, String code) {
  return DioException(
    requestOptions: RequestOptions(path: path),
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: {
        'error': {
          'code': code,
          'message': 'raw backend text',
          'message_key': code.toLowerCase(),
          'details': null,
        },
      },
    ),
    type: DioExceptionType.badResponse,
  );
}

void _stubPost(
  MockDio dio,
  List<_Posted> posted, {
  Object? Function(String path)? failWith,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String;
      final data =
          Map<String, dynamic>.from(invocation.namedArguments[#data] as Map);
      posted.add(_Posted(path, data));
      final failure = failWith?.call(path);
      if (failure != null) throw failure;
      final status = path == _createPath ? 201 : 200;
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: status,
        data: path == _cancelPath
            ? _expenseJson(
                status: 'cancelled',
                cancelReason: '${data['reason'] ?? ''}',
              )
            : _expenseJson(),
      );
    },
  );
}

Future<void> _pumpHost(
  WidgetTester tester,
  MockDio dio, {
  AppLocale locale = AppLocale.en,
}) async {
  final storage = FakeCredentialStorage();
  await storage.saveToken('tok');
  await storage.saveUserPermissions(
    const ['expense_view', 'expense_create', 'expense_cancel'],
  );
  await storage.saveUserRoles(const ['cashier']);

  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(storage),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open-form'),
                    onPressed: () => showExpenseFormDialog(context),
                    child: const Text('form'),
                  ),
                ),
                Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open-cancel'),
                    onPressed: () => showExpenseCancelDialog(
                      context,
                      expense: ExpenseItem(
                        id: 'exp-1',
                        title: 'Electricity',
                        category: 'utilities',
                        amount: '120.500',
                        paidFromDrawer: true,
                        status: 'posted',
                        expenseDate: DateTime(2026, 9, 29, 10),
                      ),
                    ),
                    child: const Text('cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openForm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-form')));
  await tester.pumpAndSettle();
}

Future<void> _openCancel(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-cancel')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Expense form dialog — validation', () {
    testWidgets('title is optional: only a bad amount blocks the POST',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);
      await _openForm(tester);

      // No title entered (Fix Round 2 / B1): the missing title alone must
      // NOT produce a validation error — only the amount can.
      final save = find.byKey(const Key('expense-form-save'));
      await tester.tap(save);
      await tester.pump();

      expect(find.byKey(const Key('expense-form-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('expense_amount_invalid', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('expense_title_required', 'en')),
        findsNothing,
        reason: 'B1: the title is no longer required',
      );
      expect(posted, isEmpty, reason: 'invalid input must never POST');

      // An amount without any title is enough to create the expense.
      await tester.enterText(
        find.byKey(const Key('expense-form-amount')),
        '120.500',
      );
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(posted, hasLength(1));
      expect(
        posted.single.data.containsKey('title'),
        isFalse,
        reason: 'an empty title is omitted, never invented client-side',
      );
      expect(find.byKey(const Key('expense-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('whitespace-only title is omitted from the payload',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);
      await _openForm(tester);

      await tester.enterText(
        find.byKey(const Key('expense-form-title-input')),
        '    ',
      );
      await tester.enterText(
        find.byKey(const Key('expense-form-amount')),
        '10',
      );
      await tester.tap(find.byKey(const Key('expense-form-save')));
      await tester.pumpAndSettle();

      expect(posted, hasLength(1));
      expect(posted.single.data.containsKey('title'), isFalse);
      expect(posted.single.data['amount'], '10.000');
      expect(tester.takeException(), isNull);
    });
  });

  group('Expense form dialog — payload contract (B6/GATE 10)', () {
    testWidgets('sends only backend-accepted fields, normalized money',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);
      await _openForm(tester);

      await tester.enterText(
        find.byKey(const Key('expense-form-title-input')),
        'Cleaning supplies',
      );
      await tester.enterText(
        find.byKey(const Key('expense-form-amount')),
        '120.5',
      );
      await tester.tap(find.byKey(const Key('expense-form-drawer')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('expense-form-save')));
      await tester.pumpAndSettle();

      expect(posted, hasLength(1));
      final call = posted.single;
      expect(call.path, '/api/v1/expenses');
      expect(
        call.data.keys.toSet(),
        {
          'client_request_id',
          'title',
          'category',
          'amount',
          'paid_from_drawer',
        },
        reason: 'the body must never carry id/status/user_id/expense_date',
      );
      expect(call.data['title'], 'Cleaning supplies');
      expect(call.data['category'], 'rent', reason: 'default category');
      expect(call.data['amount'], '120.500', reason: 'server-normalized money');
      expect(call.data['paid_from_drawer'], isFalse);
      expect('${call.data['client_request_id']}', isNotEmpty);

      // Success closes the dialog and hands the created expense back.
      expect(find.byKey(const Key('expense-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every reopen issues a fresh client_request_id',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);

      for (var i = 0; i < 2; i++) {
        await _openForm(tester);
        await tester.enterText(
          find.byKey(const Key('expense-form-title-input')),
          'Rent $i',
        );
        await tester.enterText(
          find.byKey(const Key('expense-form-amount')),
          '${i + 1}00',
        );
        await tester.tap(find.byKey(const Key('expense-form-save')));
        await tester.pumpAndSettle();
      }

      expect(posted, hasLength(2));
      expect(
        posted[0].data['client_request_id'],
        isNot(posted[1].data['client_request_id']),
        reason: 'a dialog reopen must start a NEW idempotency key',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Expense form dialog — backend failure', () {
    testWidgets('IDEMPOTENCY_CONFLICT shows a localized line and stays open',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(
        dio,
        posted,
        failWith: (path) => path == _createPath
            ? _envelopeException(path, 409, 'IDEMPOTENCY_CONFLICT')
            : null,
      );
      await _pumpHost(tester, dio);
      await _openForm(tester);

      await tester.enterText(
        find.byKey(const Key('expense-form-title-input')),
        'Electricity',
      );
      await tester.enterText(
        find.byKey(const Key('expense-form-amount')),
        '120.500',
      );
      await tester.tap(find.byKey(const Key('expense-form-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('expense-form-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('error_idempotency_conflict', 'en')),
        findsOneWidget,
        reason: 'the message must be localized, never the raw backend text',
      );
      expect(
        find.byKey(const Key('expense-form-error-detail')),
        findsOneWidget,
        reason: 'the raw backend text is the secondary detail line only',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Expense cancel dialog — terminal action (GATE 1)', () {
    testWidgets('an empty reason blocks the POST with a localized line',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);
      await _openCancel(tester);

      expect(find.byKey(const Key('expense-cancel-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('expense-cancel-confirm')));
      await tester.pump();

      expect(posted, isEmpty);
      expect(
        find.text(AppStrings.t('reason_required', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('expense-cancel-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('posts {reason} only and closes on success', (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(dio, posted);
      await _pumpHost(tester, dio);
      await _openCancel(tester);

      await tester.enterText(
        find.byKey(const Key('expense-cancel-reason-input')),
        'Duplicate payment',
      );
      await tester.tap(find.byKey(const Key('expense-cancel-confirm')));
      await tester.pumpAndSettle();

      expect(posted, hasLength(1));
      expect(posted.single.path, _cancelPath);
      expect(posted.single.data.keys.toSet(), {'reason'});
      expect(posted.single.data['reason'], 'Duplicate payment');

      // Terminal: the dialog closes after the POST (never a second submit).
      expect(find.byKey(const Key('expense-cancel-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('EXPENSE_ALREADY_CANCELLED keeps the dialog open, localized',
        (tester) async {
      final dio = MockDio();
      final posted = <_Posted>[];
      _stubPost(
        dio,
        posted,
        failWith: (path) => path == _cancelPath
            ? _envelopeException(path, 409, 'EXPENSE_ALREADY_CANCELLED')
            : null,
      );
      await _pumpHost(tester, dio);
      await _openCancel(tester);

      await tester.enterText(
        find.byKey(const Key('expense-cancel-reason-input')),
        'Too late',
      );
      await tester.tap(find.byKey(const Key('expense-cancel-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('expense-cancel-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('expense_already_cancelled', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
