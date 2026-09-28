import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/paid_through_bulk_service.dart';
import 'package:sfcapp/utils/paid_through.dart';
import 'package:sfcapp/widgets/paid_through_bulk_dialog.dart';

TenantModel tenant(String id, {DateTime? paidThrough, String? name}) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: name ?? 'Tenant $id',
      email: '$id@example.com',
      phone: '(555) 555-0101',
      unitNumber: id,
      monthlyRate: 50,
      isActive: true,
      createdAt: DateTime(2026, 9, 21),
      paidThrough: paidThrough,
    );

/// Stands in for the fresh read: the tenants as stored now.
class _Reader implements PaidThroughTenantReader {
  final Map<String, TenantModel> stored;
  List<String>? asked;
  _Reader(Iterable<TenantModel> tenants) : stored = {for (final t in tenants) t.id: t};

  @override
  Future<List<TenantModel>> read(String facilityId, List<String> tenantIds) async {
    asked = tenantIds;
    return [for (final id in tenantIds) if (stored[id] != null) stored[id]!];
  }
}

class _RecordingWriter implements PaidThroughWriter {
  String? facilityId;
  List<PaidThroughWrite> writes = [];

  @override
  Future<void> commit(String facilityId, List<PaidThroughWrite> writes) async {
    this.facilityId = facilityId;
    this.writes = writes;
  }
}

class _FailingWriter implements PaidThroughWriter {
  @override
  Future<void> commit(String facilityId, List<PaidThroughWrite> writes) async {
    throw PaidThroughPartialFailure(committed: 200, total: writes.length, cause: 'unavailable');
  }
}

class _DialogResult {
  bool done = false;
  PaidThroughMonth? picked;
}

void main() {
  final today = DateTime(2026, 9, 27, 10);

  group('month end', () {
    test('"paid through July" is July 31, not July 1', () {
      expect(paidThroughMonthEnd(2026, 7), DateTime(2026, 7, 31));
      expect(paidThroughMonthEnd(2026, 9), DateTime(2026, 9, 30));
      expect(paidThroughMonthEnd(2026, 12), DateTime(2026, 12, 31));
      expect(paidThroughMonthEnd(2026, 2), DateTime(2026, 2, 28));
      expect(paidThroughMonthEnd(2028, 2), DateTime(2028, 2, 29), reason: 'leap year');
    });

    test('labels say the end of the month', () {
      expect(paidThroughEndLabel(2026, 7), 'Paid through the end of July 2026');
      expect(paidThroughMonthLabel(2026, 12), 'December 2026');
    });
  });

  group('bulk plan', () {
    test('skips only tenants already paid through a later date', () {
      final plan = planPaidThroughBulk([
        tenant('never'),
        tenant('behind', paidThrough: DateTime(2026, 6, 30)),
        tenant('same', paidThrough: DateTime(2026, 9, 30)),
        // Written by the server: same day, a later hour. Not later.
        tenant('sameUtc', paidThrough: DateTime(2026, 9, 30, 5)),
        tenant('ahead', paidThrough: DateTime(2026, 12, 31)),
      ], year: 2026, month: 9);
      expect(plan.paidThrough, DateTime(2026, 9, 30));
      expect(plan.toUpdate.map((t) => t.id), ['never', 'behind', 'same', 'sameUtc']);
      expect(plan.alreadyLater.map((t) => t.id), ['ahead']);
    });
  });

  group('PaidThroughBulkService.applyBulk', () {
    test('writes paidThrough as the month end, each with an audit row', () async {
      final writer = _RecordingWriter();
      final stored = [
        tenant('a'),
        tenant('b', paidThrough: DateTime(2026, 8, 31)),
        tenant('c', paidThrough: DateTime(2027, 1, 31)),
      ];
      final plan = await PaidThroughBulkService.applyBulk(
        facilityId: 'f1',
        tenants: stored,
        year: 2026,
        month: 9,
        writer: writer,
        reader: _Reader(stored),
        actingUid: 'owner-1',
        actingEmail: 'owner@example.com',
      );
      expect(plan.toUpdate.map((t) => t.id), ['a', 'b']);
      expect(plan.alreadyLater.map((t) => t.id), ['c']);
      expect(writer.facilityId, 'f1');
      expect(writer.writes.map((w) => w.tenantId), ['a', 'b']);
      for (final w in writer.writes) {
        // The fields the single Set Paid Through dialog writes (the writer
        // adds updatedAt, as TenantService.updateTenant does).
        expect(w.fields, {'paidThrough': Timestamp.fromDate(DateTime(2026, 9, 30))});
        expect(w.audit.eventType, 'tenant.edited');
        expect(w.audit.actorUid, 'owner-1');
        expect(w.audit.metadata!['bulk'], isTrue);
        final doc = w.audit.toFirestore();
        for (final key in ['facilityId', 'action', 'entityType', 'entityId', 'userId', 'userEmail', 'timestamp', 'changes', 'metadata']) {
          expect(doc.containsKey(key), isTrue, reason: key);
        }
      }
    });

    test('plans from a fresh read: a payment recorded meanwhile is not walked back', () async {
      final writer = _RecordingWriter();
      // The list showed 'b' unpaid; a payment has since moved it to November.
      final reader = _Reader([tenant('a'), tenant('b', paidThrough: DateTime(2026, 11, 30))]);
      final plan = await PaidThroughBulkService.applyBulk(
        facilityId: 'f1',
        tenants: [tenant('a'), tenant('b')],
        year: 2026,
        month: 9,
        writer: writer,
        reader: reader,
        actingUid: 'owner-1',
      );
      expect(reader.asked, ['a', 'b']);
      expect(writer.writes.map((w) => w.tenantId), ['a']);
      expect(plan.alreadyLater.map((t) => t.id), ['b']);
    });

    test('writes nothing when everyone is already later', () async {
      final writer = _RecordingWriter();
      final ahead = tenant('a', paidThrough: DateTime(2026, 12, 31));
      final plan = await PaidThroughBulkService.applyBulk(
        facilityId: 'f1',
        tenants: [ahead],
        year: 2026,
        month: 9,
        writer: writer,
        reader: _Reader([ahead]),
        actingUid: 'owner-1',
      );
      expect(plan.toUpdate, isEmpty);
      expect(writer.facilityId, isNull);
    });

    test('a failure part way reports how many were saved', () async {
      final many = [for (var i = 0; i < 250; i++) tenant('t$i')];
      await expectLater(
        PaidThroughBulkService.applyBulk(
          facilityId: 'f1',
          tenants: many,
          year: 2026,
          month: 9,
          writer: _FailingWriter(),
          reader: _Reader(many),
          actingUid: 'owner-1',
        ),
        throwsA(isA<PaidThroughPartialFailure>()
            .having((e) => e.committed, 'committed', 200)
            .having((e) => e.total, 'total', 250)),
      );
      expect(
          paidThroughBulkFailureMessage(
              const PaidThroughPartialFailure(committed: 200, total: 250, cause: 'x'), 'Try again.'),
          '200 of 250 saved; the rest were not. Try again.');
      expect(paidThroughBulkFailureMessage(Exception('x'), 'Try again.'),
          'Nothing was changed: Try again.');
    });

    test('the done message names the month and the skipped', () {
      final plan = planPaidThroughBulk([
        tenant('a'),
        tenant('b'),
        tenant('c', paidThrough: DateTime(2026, 12, 31)),
      ], year: 2026, month: 9);
      expect(paidThroughBulkDoneMessage(plan),
          'Marked 2 tenants paid through the end of September 2026. '
          '1 tenant already paid through a later date was left as they are.');
    });
  });

  group('Paid through dialog', () {
    Future<_DialogResult> open(WidgetTester tester, List<TenantModel> tenants) async {
      final holder = _DialogResult();
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                holder.picked = await showPaidThroughBulkDialog(context,
                    tenants: tenants, today: today);
                holder.done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return holder;
    }

    FilledButton save(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('bulk-paid-through-save')));

    testWidgets('defaults to this month, lists the skipped, and saves once confirmed',
        (tester) async {
      final result = await open(tester, [
        tenant('a'),
        tenant('b', paidThrough: DateTime(2026, 7, 31)),
        tenant('c', name: 'Pat Example', paidThrough: DateTime(2026, 12, 31)),
      ]);

      expect(
          find.text('2 tenants will be marked paid through the end of September 2026 (09/30/2026).'),
          findsOneWidget);
      expect(find.textContaining('Skipped 1 tenant already paid through a later date'),
          findsOneWidget);
      expect(find.text('• Pat Example (12/31/2026)'), findsOneWidget);
      expect(save(tester).onPressed, isNull, reason: 'not yet confirmed');

      await tester.tap(find.byKey(const Key('bulk-paid-through-confirm')));
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);
      expect(find.text('Mark 2 tenants paid'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-paid-through-save')));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      expect(result.picked, (year: 2026, month: 9));
    });

    testWidgets('picking another month recounts and asks to confirm again', (tester) async {
      final result = await open(tester, [
        tenant('a'),
        tenant('b', paidThrough: DateTime(2026, 8, 31)),
      ]);
      await tester.tap(find.byKey(const Key('bulk-paid-through-confirm')));
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);

      // August: 'b' is already paid through August 31, which is not later.
      // July: 'b' is later, so skipped.
      await tester.tap(find.byKey(const Key('bulk-paid-through-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jul').last);
      await tester.pumpAndSettle();

      expect(
          find.text('1 tenant will be marked paid through the end of July 2026 (07/31/2026).'),
          findsOneWidget);
      expect(find.textContaining('Skipped 1 tenant'), findsOneWidget);
      expect(save(tester).onPressed, isNull, reason: 'a new month is confirmed again');

      await tester.tap(find.byKey(const Key('bulk-paid-through-confirm')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-paid-through-save')));
      await tester.pumpAndSettle();
      expect(result.picked, (year: 2026, month: 7));
    });

    testWidgets('nobody to mark: only Close', (tester) async {
      final result = await open(tester, [tenant('a', paidThrough: DateTime(2027, 3, 31))]);
      expect(find.textContaining('None of the selected tenants can be marked'), findsOneWidget);
      expect(find.byKey(const Key('bulk-paid-through-save')), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      expect(result.picked, isNull);
    });

    testWidgets('cancel marks nothing', (tester) async {
      final result = await open(tester, [tenant('a')]);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      expect(result.picked, isNull);
    });
  });
}
