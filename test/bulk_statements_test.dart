import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/bulk_statement_service.dart';
import 'package:sfcapp/utils/bulk_statements.dart';
import 'package:sfcapp/widgets/bulk_statements_dialog.dart';

final _facility = FacilityModel(
  id: 'f1',
  name: 'Oak Storage',
  ownerUid: 'owner',
  createdAt: DateTime(2026, 1, 1),
  address: '1 Example Rd\nAnytown, ND 79401',
  phone: '(555) 123-4567',
);

Address _address(String street, {String city = 'Anytown'}) => Address(
      id: 'a-$street',
      type: AddressType.mailing,
      street1: street,
      city: city,
      state: 'ND',
      zipCode: '79401',
      isPrimary: true,
      createdAt: DateTime(2026, 1, 1),
    );

TenantModel _tenant(String id, String name, String unit, {String? street}) =>
    TenantModel(
      id: id,
      facilityId: 'f1',
      name: name,
      email: '',
      phone: '(555) 010-0100',
      unitNumber: unit,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
      addresses: [if (street != null) _address(street)],
    );

/// Rent and past-history payments are stored at 12:00 UTC on their day.
DateTime _noon(int y, int m, int d) => DateTime.utc(y, m, d, 12);

LedgerEntry _entry(String tenantId, String id, LedgerEntryType type,
        double amount, DateTime at, String description,
        {LedgerEntryStatus status = LedgerEntryStatus.posted}) =>
    LedgerEntry(
      id: id,
      tenantId: tenantId,
      facilityId: 'f1',
      type: type,
      amount: amount,
      description: description,
      entryDate: at,
      status: status,
      createdAt: at,
      createdBy: 'owner',
    );

LedgerEntry _rent(String tenantId, String id, double amount, DateTime at,
        String month) =>
    _entry(tenantId, id, LedgerEntryType.rentCharge, amount, at, '$month rent');

LedgerEntry _payment(String tenantId, String id, double amount, DateTime at) =>
    _entry(tenantId, id, LedgerEntryType.payment, -amount, at, 'Check');

// Two two-unit customers: Pat's records agree on the address (one has it,
// the other none); Sam's two records carry different addresses. Lee has no
// ledger, Kim is paid up, Jo is in credit.
final _patA1 = _tenant('pat1', 'Pat Example', 'A-1', street: '12 Example Ave');
final _patA2 = _tenant('pat2', 'Pat Example', 'A-2');
final _samB1 = _tenant('sam1', 'Sam Sample', 'B-1', street: '3 Sample St');
final _samB2 = _tenant('sam2', 'Sam Sample', 'B-2', street: '9 Other Rd');
final _lee = _tenant('lee', 'Lee Empty', 'C-1');
final _kim = _tenant('kim', 'Kim Paid', 'D-1');
final _jo = _tenant('jo', 'Jo Credit', 'E-1');

final _tenants = [_patA1, _patA2, _samB1, _samB2, _lee, _kim, _jo];

final _ledgers = <String, List<LedgerEntry>>{
  'pat1': [
    _rent('pat1', 'p1a', 50, _noon(2026, 8, 1), 'August'),
    _rent('pat1', 'p1s', 50, _noon(2026, 9, 1), 'September'),
  ],
  'pat2': [_rent('pat2', 'p2s', 40, _noon(2026, 9, 1), 'September')],
  'sam1': [_rent('sam1', 's1s', 70, _noon(2026, 9, 1), 'September')],
  'sam2': [_rent('sam2', 's2s', 70, _noon(2026, 9, 1), 'September')],
  'lee': [],
  'kim': [
    _rent('kim', 'k1', 60, _noon(2026, 9, 1), 'September'),
    _payment('kim', 'k2', 60, _noon(2026, 9, 2)),
  ],
  'jo': [
    _rent('jo', 'j1', 30, _noon(2026, 9, 1), 'September'),
    _payment('jo', 'j2', 50, _noon(2026, 9, 2)),
  ],
};

const _all = StatementPeriod.allHistory();

/// Hands back the fixture ledgers; [gate] holds the read open until the
/// test completes it, so a test can see the Load step.
class _Reader implements StatementLedgerReader {
  final Map<String, List<LedgerEntry>> ledgers;
  final Completer<void>? gate;
  List<String>? asked;
  String? facilityId;
  _Reader(this.ledgers, {this.gate});

  @override
  Future<Map<String, List<LedgerEntry>>> read(
      String facilityId, List<String> tenantIds) async {
    this.facilityId = facilityId;
    asked = tenantIds;
    if (gate != null) await gate!.future;
    return {for (final id in tenantIds) id: ledgers[id] ?? const []};
  }
}

/// The words of an uncompressed PDF in stream order, joined with spaces.
/// The pdf package writes each word as its own `[(word)]TJ`, so a phrase is
/// found only after joining them back up.
String _words(List<int> bytes) => RegExp(r'\[\((.*?)\)\]TJ')
    .allMatches(latin1.decode(bytes))
    .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'))
    .join(' ');

int _pageObjects(List<int> bytes) =>
    RegExp(r'/Type\s*/Page\b(?!s)').allMatches(latin1.decode(bytes)).length;

void main() {
  final today = DateTime(2026, 9, 28, 10);

  group('StatementPeriod', () {
    test('a month runs from its first day to its last', () {
      final sep = StatementPeriod.month(2026, 9);
      expect(sep.startDate, DateTime(2026, 9, 1));
      expect(sep.endDate, DateTime(2026, 9, 30));
      expect(StatementPeriod.month(2026, 12).endDate, DateTime(2026, 12, 31));
      expect(StatementPeriod.month(2028, 2).endDate, DateTime(2028, 2, 29));
      expect(sep.isAllHistory, isFalse);
      expect(_all.isAllHistory, isTrue);
    });
  });

  group('sameCustomerKey', () {
    test('trims, lowercases and collapses whitespace', () {
      expect(sameCustomerKey(_tenant('x', '  Pat   EXAMPLE ', 'A-1')),
          'pat example');
      expect(sameCustomerKey(_patA2), sameCustomerKey(_patA1));
      expect(sameCustomerKey(_samB1), isNot(sameCustomerKey(_patA1)));
    });
  });

  group('chunkIds', () {
    test('runs of at most 30, in order, none empty', () {
      final ids = [for (var i = 0; i < 65; i++) 't$i'];
      final chunks = chunkIds(ids, 30);
      expect(chunks.map((c) => c.length), [30, 30, 5]);
      expect(chunks.expand((c) => c), ids);
      expect(chunkIds(const [], 30), isEmpty);
      expect(chunkIds(['a'], 30), [['a']]);
    });
  });

  group('planBulkStatements', () {
    test('combines same-name records whose addresses agree, one statement '
        'at the first member with every unit, merged rows and the summed '
        'balance', () {
      final plan = planBulkStatements(_tenants, _ledgers,
          period: _all, combineSamePerson: true, skipNoActivity: false);

      expect(plan.jobs.map((j) => j.tenants.map((t) => t.id).join('+')),
          ['pat1+pat2', 'sam1', 'sam2', 'lee', 'kim', 'jo']);
      final pat = plan.jobs.first;
      expect(pat.isCombined, isTrue);
      expect(pat.holder.id, 'pat1', reason: 'the record with the address');
      expect(pat.unitLabels, ['A-1', 'A-2']);
      expect(pat.lines.closingBalance, 140);
      // Merged in date order, each row saying which unit it is for.
      expect(pat.lines.rows.map((r) => r.description), [
        'A-1: August rent',
        'A-1: September rent',
        'A-2: September rent',
      ]);
      expect(pat.lines.rows.map((r) => r.runningBalance), [50, 100, 140]);

      // Sam's addresses differ: two statements, and a note.
      expect(plan.notCombinedAddressesDiffer.map((g) => g.map((t) => t.id)),
          [['sam1', 'sam2']]);
      expect(plan.jobs[1].isCombined, isFalse);
      expect(plan.jobs[1].lines.rows.single.description, 'September rent',
          reason: 'a single-record statement needs no unit prefix');
    });

    test('a group with no address anywhere still combines; a group whose '
        'first record has none takes the address from the other', () {
      final first = _tenant('b1', 'Bo Both', 'F-1');
      final second = _tenant('b2', 'Bo Both', 'F-2', street: '5 Found Ln');
      final third = _tenant('n1', 'No Address', 'G-1');
      final fourth = _tenant('n2', 'No Address', 'G-2');
      final ledgers = {
        for (final t in [first, second, third, fourth])
          t.id: [_rent(t.id, 'r-${t.id}', 20, _noon(2026, 9, 1), 'September')],
      };
      final plan = planBulkStatements([first, second, third, fourth], ledgers,
          period: _all, combineSamePerson: true);

      expect(plan.jobs.length, 2);
      expect(plan.jobs[0].tenants.map((t) => t.id), ['b1', 'b2']);
      expect(plan.jobs[0].holder.id, 'b2');
      expect(plan.jobs[1].tenants.map((t) => t.id), ['n1', 'n2']);
      expect(plan.noMailingAddress.map((t) => t.id), ['n1']);
      expect(plan.notCombinedAddressesDiffer, isEmpty);
    });

    test('a group sits where its first member is, in list order', () {
      final plan = planBulkStatements([_samB1, _patA2, _kim, _patA1], _ledgers,
          period: _all, combineSamePerson: true);
      expect(plan.jobs.map((j) => j.tenants.map((t) => t.id).join('+')),
          ['sam1', 'pat2+pat1', 'kim']);
      expect(plan.jobs[1].unitLabels, ['A-2', 'A-1']);
    });

    test('combine off: every record prints on its own', () {
      final plan = planBulkStatements(_tenants, _ledgers,
          period: _all, skipNoActivity: false);
      expect(plan.jobs.length, _tenants.length);
      expect(plan.jobs.every((j) => !j.isCombined), isTrue);
      // The differing addresses are still reported, so the owner knows why
      // ticking Combine would not merge them.
      expect(plan.notCombinedAddressesDiffer.length, 1);
      expect(plan.noMailingAddress.map((t) => t.id), ['pat2', 'lee', 'kim', 'jo']);
    });

    test('skips: no ledger entries, then nothing owed, each record counted '
        'once', () {
      final plan = planBulkStatements(_tenants, _ledgers,
          period: _all, skipNothingOwed: true);
      expect(plan.skippedNoActivity.map((t) => t.id), ['lee']);
      expect(plan.skippedNothingOwed.map((t) => t.id), ['kim', 'jo'],
          reason: 'a credit is nothing owed; Lee is already out');
      expect(plan.jobs.map((j) => j.holder.id), ['pat1', 'pat2', 'sam1', 'sam2']);
      expect(plan.noMailingAddress.map((t) => t.id), ['pat2']);

      // With the no-activity skip off, an empty ledger owes nothing too.
      final owedOnly = planBulkStatements(_tenants, _ledgers,
          period: _all, skipNothingOwed: true, skipNoActivity: false);
      expect(owedOnly.skippedNoActivity, isEmpty);
      expect(owedOnly.skippedNothingOwed.map((t) => t.id), ['lee', 'kim', 'jo']);

      // Only voided entries is no activity.
      final voided = planBulkStatements([_lee], {
        'lee': [
          _entry('lee', 'v', LedgerEntryType.lateFee, 10, _noon(2026, 9, 5),
              'Late fee', status: LedgerEntryStatus.voided),
        ],
      }, period: _all);
      expect(voided.skippedNoActivity.map((t) => t.id), ['lee']);
    });

    test('a group is skipped as a whole by its combined balance', () {
      final owes = _tenant('o1', 'Owes One', 'H-1');
      final credit = _tenant('o2', 'Owes One', 'H-2');
      final ledgers = {
        'o1': [_rent('o1', 'r1', 30, _noon(2026, 9, 1), 'September')],
        'o2': [
          _rent('o2', 'r2', 30, _noon(2026, 9, 1), 'September'),
          _payment('o2', 'p2', 60, _noon(2026, 9, 2)),
        ],
      };
      final plan = planBulkStatements([owes, credit], ledgers,
          period: _all, combineSamePerson: true, skipNothingOwed: true);
      expect(plan.jobs, isEmpty);
      expect(plan.skippedNothingOwed.map((t) => t.id), ['o1', 'o2']);
    });

    test('a month: earlier entries become the balance forward, and a tenant '
        'with only earlier entries still gets a statement', () {
      final plan = planBulkStatements([_patA1, _kim], _ledgers,
          period: StatementPeriod.month(2026, 9));
      final pat = plan.jobs[0].lines;
      expect(pat.balanceForward, 50);
      expect(pat.rows.map((r) => r.description), ['September rent']);
      expect(pat.closingBalance, 100);

      final aug = planBulkStatements([_patA1], _ledgers,
          period: StatementPeriod.month(2026, 8));
      expect(aug.jobs.single.lines.rows.map((r) => r.description),
          ['August rent']);
      expect(aug.jobs.single.lines.closingBalance, 50);

      // July: nothing yet, nothing before, but the ledger is not empty, so
      // the statement prints (at $0.00) rather than being skipped.
      final jul = planBulkStatements([_patA1], _ledgers,
          period: StatementPeriod.month(2026, 7));
      expect(jul.jobs.single.lines.rows, isEmpty);
      expect(jul.skippedNoActivity, isEmpty);
    });

    test('unit labels come from the caller when given', () {
      final plan = planBulkStatements([_patA1, _patA2], _ledgers,
          period: _all,
          combineSamePerson: true,
          unitLabels: (t) => ['${t.unitNumber} (Complex 2)']);
      expect(plan.jobs.single.unitLabels, ['A-1 (Complex 2)', 'A-2 (Complex 2)']);
      expect(plan.jobs.single.lines.rows.first.description,
          'A-1 (Complex 2): August rent');
    });
  });

  group('buildBulkStatementsPdf', () {
    BulkStatementPlan plan({bool combine = true}) => planBulkStatements(
        _tenants, _ledgers,
        period: _all, combineSamePerson: combine, skipNothingOwed: true);

    test('one PDF, every statement in order, each name and unit line in it',
        () async {
      final progress = <(int, int)>[];
      final result = await BulkStatementService.buildBulkStatementsPdf(
        plan(),
        _facility,
        printedOn: today,
        period: _all,
        compress: false,
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(result.statementCount, 3);
      expect(result.pageCount, greaterThanOrEqualTo(result.statementCount));
      expect(_pageObjects(result.bytes), result.pageCount);
      expect(progress, [(1, 3), (2, 3), (3, 3)]);

      final words = _words(result.bytes);
      expect(words, contains('Pat Example'));
      expect(words, contains('Units: A-1, A-2'));
      expect(words, contains('A-1: August rent'));
      expect(words, contains('A-2: September rent'));
      expect(words, contains(r'Current Balance: $140.00'));
      expect(words, contains('Sam Sample'));
      expect(words, contains('Unit: B-1'));
      expect(words, contains('Unit: B-2'));
      expect(words, contains('Date: Sep 28, 2026'));
      // Skipped: not on any page.
      expect(words, isNot(contains('Kim Paid')));
      expect(words, isNot(contains('Lee Empty')));
      // Pat before Sam, as the list had them.
      expect(words.indexOf('Pat Example'), lessThan(words.indexOf('Sam Sample')));
    });

    test('a month period dates the statement today and names the period',
        () async {
      final sep = StatementPeriod.month(2026, 9);
      final result = await BulkStatementService.buildBulkStatementsPdf(
        planBulkStatements([_patA1], _ledgers, period: sep),
        _facility,
        printedOn: today,
        period: sep,
        compress: false,
      );
      final words = _words(result.bytes);
      expect(words, contains('Sep 1, 2026 - Sep 30, 2026'));
      expect(words, contains('Balance forward'));
      expect(words, contains(r'Balance as of Sep 30, 2026: $100.00'));
    });

    test('duplex pads a statement with an odd page count to an even one',
        () async {
      final single = await BulkStatementService.buildBulkStatementsPdf(
          plan(), _facility, printedOn: today, period: _all);
      final duplex = await BulkStatementService.buildBulkStatementsPdf(
          plan(), _facility, printedOn: today, period: _all, duplex: true);
      // Each fixture statement is one page.
      expect(single.pageCount, 3);
      expect(duplex.pageCount, 6);
      expect(duplex.statementCount, 3);
      expect(_pageObjects(duplex.bytes), 6);
    });

    test('cancel after two statements throws and hands back no bytes',
        () async {
      var done = 0;
      await expectLater(
        BulkStatementService.buildBulkStatementsPdf(
          plan(),
          _facility,
          printedOn: today,
          period: _all,
          onProgress: (d, _) => done = d,
          isCancelled: () => done >= 2,
        ),
        throwsA(isA<BulkStatementsCancelled>()),
      );
      expect(done, 2, reason: 'the third statement was never laid out');
    });

    test('an empty plan is an empty document', () async {
      final result = await BulkStatementService.buildBulkStatementsPdf(
        planBulkStatements(const [], const {}, period: _all),
        _facility,
        printedOn: today,
        period: _all,
      );
      expect(result.statementCount, 0);
      expect(result.pageCount, 0);
    });
  });

  group('bulkStatementsFileName', () {
    test('facility, "statements", the period month; file-unsafe characters '
        'dropped', () {
      expect(
          bulkStatementsFileName(
              'Oak Storage', StatementPeriod.month(2026, 10), today),
          'Oak Storage statements Oct 2026.pdf');
      expect(bulkStatementsFileName('Oak Storage', _all, today),
          'Oak Storage statements Sep 2026.pdf');
      expect(
          bulkStatementsFileName('Oak / Pine: "Storage"?', _all, today),
          'Oak Pine Storage statements Sep 2026.pdf');
      expect(bulkStatementsFileName('   ', _all, today),
          'Tenant statements Sep 2026.pdf');
    });
  });

  group('Print statements dialog', () {
    Future<_Reader> open(WidgetTester tester,
        {List<TenantModel>? tenants, Completer<void>? gate}) async {
      final reader = _Reader(_ledgers, gate: gate);
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBulkStatementsDialog(
                context,
                tenants: tenants ?? _tenants,
                facility: _facility,
                reader: reader,
                today: today,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      // A held read shows the Load step's indeterminate bar, which never
      // settles; one frame is enough to see it.
      if (gate == null) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      return reader;
    }

    FilledButton build(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('bulk-statements-build')));

    Future<void> tick(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('reads every selected ledger first, then shows the options',
        (tester) async {
      final gate = Completer<void>();
      final reader = await open(tester, gate: gate);

      expect(find.text('Reading 7 ledgers...'), findsOneWidget);
      expect(reader.facilityId, 'f1');
      expect(reader.asked, _tenants.map((t) => t.id).toList());
      expect(find.byKey(const Key('bulk-statements-build')), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Reading 7 ledgers...'), findsNothing);
      expect(find.byKey(const Key('bulk-statements-build')), findsOneWidget);
    });

    testWidgets('defaults: this month, no combining, skip empty ledgers only, '
        'single-sided; the counts and notes', (tester) async {
      await open(tester);

      expect(find.text('7 tenants selected. Statements print in the order the '
          'list shows them now.'), findsOneWidget);
      expect(find.text('Sep'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('Combine units for the same person (1 person, 2 units)'),
          findsOneWidget);
      expect(find.text('Skip tenants who owe nothing (2)'), findsOneWidget,
          reason: 'Kim and Jo; Lee is already out for having no entries');
      expect(find.text('Skip tenants with no ledger entries (1)'), findsOneWidget);
      expect(find.text('Printed separately: Sam Sample (different addresses)'),
          findsOneWidget);
      expect(find.text('No mailing address on file: 3'), findsOneWidget);
      expect(find.text('Pat Example, Kim Paid, Jo Credit'), findsOneWidget);
      expect(find.text('Build 6 statements'), findsOneWidget);
      expect(build(tester).onPressed, isNotNull);

      bool ticked(String key) =>
          tester.widget<CheckboxListTile>(find.byKey(Key(key))).value ?? false;
      expect(ticked('bulk-statements-combine'), isFalse);
      expect(ticked('bulk-statements-skip-nothing-owed'), isFalse);
      expect(ticked('bulk-statements-skip-no-activity'), isTrue);
      expect(ticked('bulk-statements-duplex'), isFalse);
    });

    testWidgets('each option recounts the statements and the notes',
        (tester) async {
      await open(tester);

      await tick(tester, 'bulk-statements-combine');
      expect(find.text('Build 5 statements'), findsOneWidget);
      expect(find.text('No mailing address on file: 2'), findsOneWidget,
          reason: "Pat's statement now carries the A-1 address");

      await tick(tester, 'bulk-statements-skip-nothing-owed');
      expect(find.text('Build 3 statements'), findsOneWidget);
      expect(find.byKey(const Key('bulk-statements-no-address')), findsNothing);

      // Lee comes back in, with an empty ledger that owes nothing.
      await tick(tester, 'bulk-statements-skip-no-activity');
      expect(find.text('Skip tenants who owe nothing (3)'), findsOneWidget);
      expect(find.text('Build 3 statements'), findsOneWidget);
      await tick(tester, 'bulk-statements-skip-nothing-owed');
      expect(find.text('Build 6 statements'), findsOneWidget);
      expect(find.text('No mailing address on file: 3'), findsOneWidget);
      expect(find.text('Lee Empty, Kim Paid, Jo Credit'), findsOneWidget);
    });

    testWidgets('all history hides the month; a month recounts by its '
        'balance', (tester) async {
      await open(tester, tenants: [_patA1, _kim]);
      expect(find.byKey(const Key('bulk-statements-month')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-statements-period-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bulk-statements-month')), findsNothing);
      expect(find.byKey(const Key('bulk-statements-year')), findsNothing);

      await tester.tap(find.byKey(const Key('bulk-statements-period-month')));
      await tester.pumpAndSettle();
      // July: Pat has no rows and nothing forward, so owes nothing then.
      await tester.tap(find.byKey(const Key('bulk-statements-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jul').last);
      await tester.pumpAndSettle();
      expect(find.text('Skip tenants who owe nothing (2)'), findsOneWidget);
      await tick(tester, 'bulk-statements-skip-nothing-owed');
      expect(find.text('Nothing to print: every selected tenant is skipped.'),
          findsOneWidget);
      expect(build(tester).onPressed, isNull);
    });

    testWidgets('Build makes the PDF and offers Print and Download PDF',
        (tester) async {
      await open(tester);
      await tick(tester, 'bulk-statements-combine');
      await tick(tester, 'bulk-statements-skip-nothing-owed');
      await tick(tester, 'bulk-statements-duplex');

      await tester.tap(find.byKey(const Key('bulk-statements-build')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bulk-statements-progress')), findsNothing);
      expect(find.text('3 statements, 6 pages'), findsOneWidget);
      expect(find.textContaining('"Oak Storage statements Sep 2026.pdf"'),
          findsOneWidget);
      expect(find.byKey(const Key('bulk-statements-print')), findsOneWidget);
      expect(find.byKey(const Key('bulk-statements-download')), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a failed read says so and offers Close', (tester) async {
      final gate = Completer<void>();
      await open(tester, gate: gate);
      gate.completeError(StateError('permission-denied'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bulk-statements-failed')), findsOneWidget);
      expect(find.textContaining('The ledgers could not be read'), findsOneWidget);
      expect(find.byKey(const Key('bulk-statements-build')), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
