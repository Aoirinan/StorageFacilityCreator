import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/tenant_service.dart';

/// Permanent tenant delete used to remove the tenant doc and leave their
/// ledger, invoices and payments behind: the balance vanished from AR and the
/// history could no longer be opened. These pin the guard that refuses it.
void main() {
  final day = DateTime(2026, 9, 1);

  LedgerEntry entry(double amount, LedgerEntryStatus status) => LedgerEntry(
        id: 'e$amount$status',
        tenantId: 't1',
        facilityId: 'f1',
        type: amount < 0 ? LedgerEntryType.payment : LedgerEntryType.rentCharge,
        amount: amount,
        entryDate: day,
        status: status,
        createdAt: day,
        createdBy: 'owner',
      );

  InvoiceModel invoice(InvoiceStatus status) => InvoiceModel(
        id: 'i1',
        tenantId: 't1',
        facilityId: 'f1',
        invoiceNumber: 'INV-1',
        status: status,
        issueDate: day,
        dueDate: day,
        subtotal: 150,
        total: 150,
        balance: 150,
        lineItems: const [],
        ledgerEntryIds: const [],
        paymentIds: const [],
        createdAt: day,
        createdBy: 'owner',
      );

  PaymentModel payment(PaymentStatus status, {bool isActive = true}) =>
      PaymentModel(
        id: 'p1',
        tenantId: 't1',
        facilityId: 'f1',
        contractId: '',
        amount: 150,
        status: status,
        method: PaymentMethod.cash,
        dueDate: day,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
        isActive: isActive,
      );

  UnitModel unit(String number, UnitStatus status, String? tenantId) =>
      UnitModel(
        id: 'u$number',
        facilityId: 'f1',
        unitNumber: number,
        unitType: 'standard',
        status: status,
        tenantId: tenantId,
        monthlyRate: 100,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
      );

  int liveLedger(List<LedgerEntry> entries) => TenantService.liveCountFromScan(
        entries,
        TenantService.isLiveLedgerEntry,
        scanLimit: 10,
      );

  List<String> blockers({
    int ledger = 0,
    int invoices = 0,
    int payments = 0,
    int contracts = 0,
    int cards = 0,
    int liens = 0,
  }) =>
      TenantService.permanentDeleteBlockers(
        liveLedgerEntries: ledger,
        liveInvoices: invoices,
        livePayments: payments,
        activeContracts: contracts,
        activeSavedCards: cards,
        activeLiens: liens,
      );

  TenantDeletePlan plan(String id, String name, {List<String> reasons = const []}) =>
      TenantDeletePlan(tenantId: id, tenantName: name, blockers: reasons);

  group('permanentDeleteBlockers', () {
    test('one posted rent charge blocks the delete', () {
      final live = liveLedger([entry(150, LedgerEntryStatus.posted)]);
      expect(blockers(ledger: live), ['charges or payments on the ledger']);
    });

    test('a zero balance still blocks: history, not balance, is what counts', () {
      // +150 charged and -150 paid owes nothing, but deleting this real
      // customer would orphan real revenue records.
      final live = liveLedger([
        entry(150, LedgerEntryStatus.posted),
        entry(-150, LedgerEntryStatus.posted),
      ]);
      expect(live, 2);
      expect(blockers(ledger: live), isNotEmpty);
    });

    test('a tenant whose only entries are voided can be deleted', () {
      final live = liveLedger([
        entry(150, LedgerEntryStatus.voided),
        entry(25, LedgerEntryStatus.voided),
      ]);
      expect(live, 0);
      expect(blockers(ledger: live), isEmpty);
    });

    test('an active contract or a saved card each block on their own', () {
      expect(blockers(contracts: 1), ['an active contract']);
      expect(blockers(cards: 1), ['a saved card']);
      expect(blockers(liens: 1), ['an active lien']);
      expect(blockers(invoices: 2), ['invoices']);
      expect(blockers(payments: 1), ['a payment record']);
    });

    test('a tenant with no records at all has no blockers', () {
      expect(blockers(), isEmpty);
    });
  });

  group('live-record predicates', () {
    test('ledger: posted and pending are live, voided is not', () {
      expect(TenantService.isLiveLedgerEntry(entry(1, LedgerEntryStatus.posted)), isTrue);
      expect(TenantService.isLiveLedgerEntry(entry(1, LedgerEntryStatus.pending)), isTrue);
      expect(TenantService.isLiveLedgerEntry(entry(1, LedgerEntryStatus.voided)), isFalse);
    });

    test('invoice: only voided is not live', () {
      for (final s in [
        InvoiceStatus.draft,
        InvoiceStatus.sent,
        InvoiceStatus.paid,
        InvoiceStatus.overdue,
      ]) {
        expect(TenantService.isLiveInvoice(invoice(s)), isTrue, reason: s.name);
      }
      expect(TenantService.isLiveInvoice(invoice(InvoiceStatus.voided)), isFalse);
    });

    test('payment: failed, cancelled and archived are not live', () {
      for (final s in [
        PaymentStatus.completed,
        PaymentStatus.paid,
        PaymentStatus.pending,
        PaymentStatus.refunded,
      ]) {
        expect(TenantService.isLivePayment(payment(s)), isTrue, reason: s.name);
      }
      expect(TenantService.isLivePayment(payment(PaymentStatus.failed)), isFalse);
      expect(TenantService.isLivePayment(payment(PaymentStatus.cancelled)), isFalse);
      expect(
        TenantService.isLivePayment(payment(PaymentStatus.completed, isActive: false)),
        isFalse,
      );
    });

    test('contracts and cards are active unless switched off', () {
      expect(TenantService.isActiveFlagSet({'isActive': true}), isTrue);
      expect(TenantService.isActiveFlagSet(const {}), isTrue);
      expect(TenantService.isActiveFlagSet({'isActive': false}), isFalse);
    });
  });

  group('liveCountFromScan fails closed', () {
    test('a full page with nothing live still counts, rows past the cap may be live', () {
      final voided = List.generate(10, (_) => entry(1, LedgerEntryStatus.voided));
      expect(liveLedger(voided), 1);
      expect(liveLedger(voided.take(9).toList()), 0);
    });

    test('a row that cannot be read counts as live', () {
      final count = TenantService.liveCountFromScan<int>(
        [1, 2],
        (row) => row == 1 ? throw const FormatException('bad row') : false,
        scanLimit: 10,
      );
      expect(count, 1);
    });
  });

  group('runPermanentDelete', () {
    test('a failed check refuses the delete and writes nothing', () async {
      var committed = false;
      final future = TenantService.runPermanentDelete(
        tenantIds: ['a', 'b'],
        loadPlan: (id) async {
          if (id == 'b') throw Exception('permission-denied');
          return plan(id, 'Tenant $id');
        },
        commit: (_) async => committed = true,
      );
      await expectLater(
        future,
        throwsA(isA<TenantDeleteCheckFailedException>().having(
          (e) => e.message,
          'message',
          contains("Couldn't verify this tenant's billing records; nothing was deleted"),
        )),
      );
      expect(committed, isFalse);
    });

    test('the refusal says why the check failed', () {
      expect(
        TenantDeleteCheckFailedException(Exception('permission-denied')).message,
        contains('ask the facility owner'),
      );
      expect(
        TenantDeleteCheckFailedException(Exception('unavailable')).message,
        contains('Check your connection'),
      );
    });

    test('bulk is all or nothing and names every blocked tenant', () async {
      var committed = false;
      final future = TenantService.runPermanentDelete(
        tenantIds: ['a', 'b', 'c'],
        loadPlan: (id) async => switch (id) {
          'a' => plan('a', 'Ada Park', reasons: ['charges or payments on the ledger']),
          'b' => plan('b', 'Clean Entry'),
          _ => plan('c', 'Cy Lee', reasons: ['a saved card']),
        },
        commit: (_) async => committed = true,
      );
      final error = await future.then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<TenantHasFinancialRecordsException>());
      final refusal = error! as TenantHasFinancialRecordsException;
      expect(refusal.blocked.map((b) => b.tenantId), ['a', 'c']);
      expect(refusal.message, contains('Ada Park'));
      expect(refusal.message, contains('Cy Lee'));
      expect(refusal.message, isNot(contains('Clean Entry')));
      expect(refusal.blockersByTenantName['Cy Lee'], ['a saved card']);
      expect(committed, isFalse);
    });

    test('clean tenants are committed together, in order', () async {
      List<TenantDeletePlan>? committed;
      await TenantService.runPermanentDelete(
        tenantIds: ['a', 'b'],
        loadPlan: (id) async => plan(id, 'Tenant $id'),
        commit: (plans) async => committed = plans,
      );
      expect(committed!.map((p) => p.tenantId), ['a', 'b']);
    });
  });

  group('offer Archive instead', () {
    test('not offered while a unit still shows the tenant as occupant', () {
      final held = TenantService.unitNumbersHeldByTenant('t1', [
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.occupied, 't2'),
      ]);
      expect(held, ['101']);
      final block = TenantDeleteBlock(
        tenantId: 't1',
        tenantName: 'Ada Park',
        reasons: const ['an invoice'],
        heldUnitNumbers: held,
      );
      expect(block.canArchiveInstead, isFalse);
      final refusal = TenantHasFinancialRecordsException([block]);
      expect(refusal.details, contains('unit 101'));
      expect(refusal.details, contains('Unassign Tenant'));
      expect(refusal.details, isNot(contains('archive Ada Park instead')));
    });

    test('an overlocked unit counts as held too', () {
      expect(
        TenantService.unitNumbersHeldByTenant('t1', [unit('7', UnitStatus.overlocked, 't1')]),
        ['7'],
      );
    });

    test('offered when no unit holds the tenant', () {
      final held = TenantService.unitNumbersHeldByTenant('t1', [
        unit('102', UnitStatus.occupied, 't2'),
        // A stale link on an available unit has no Unassign button to clear it.
        unit('103', UnitStatus.available, 't1'),
      ]);
      expect(held, isEmpty);
      final block = TenantDeleteBlock(
        tenantId: 't1',
        tenantName: 'Ada Park',
        reasons: const ['an invoice'],
        heldUnitNumbers: held,
      );
      expect(block.canArchiveInstead, isTrue);
      expect(
        TenantHasFinancialRecordsException([block]).details,
        contains('archive Ada Park instead'),
      );
    });
  });

  test('archive refusal names the units and the way out', () {
    const e = TenantStillAssignedToUnitException(
      tenantName: 'Ada Park',
      unitNumbers: ['101', '102'],
    );
    expect(e.message, contains('units 101, 102'));
    expect(e.message, contains('Units > unit > Unassign Tenant'));
    expect(e.toString(), e.message);
  });

  group('packWriteGroups', () {
    test("keeps one tenant's writes in one batch and stays under the cap", () {
      final groups = [
        [1, 1, 1],
        [2, 2, 2],
        [3, 3],
      ];
      final chunks = TenantService.packWriteGroups(groups, maxPerChunk: 5);
      expect(chunks, [
        [1, 1, 1],
        [2, 2, 2, 3, 3],
      ]);
    });

    test('splits only a group that could never fit', () {
      final chunks = TenantService.packWriteGroups([
        [1],
        [2, 2, 2, 2, 2, 2, 2],
      ], maxPerChunk: 3);
      expect(chunks.every((c) => c.length <= 3), isTrue);
      expect(chunks.expand((c) => c).toList(), [1, 2, 2, 2, 2, 2, 2, 2]);
    });
  });

  test('loadAllForDelete runs a bounded number of checks at once, in order', () async {
    var inFlight = 0;
    var peak = 0;
    final ids = List.generate(20, (i) => 't$i');
    final results = await TenantService.loadAllForDelete<String>(
      ids,
      (id) async {
        inFlight++;
        peak = inFlight > peak ? inFlight : peak;
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        return id;
      },
      concurrency: 4,
    );
    expect(results, ids);
    expect(peak, lessThanOrEqualTo(4));
  });
}
