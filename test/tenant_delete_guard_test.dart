import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/unit_detail_screen.dart';
import 'package:sfcapp/services/move_out_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/callable_failure.dart';

/// One write a guard made, as the fake store saw it.
class _Write {
  _Write(this.op, this.collection, this.docId, [this.fields]);

  final String op;
  final String collection;
  final String docId;
  final Map<String, dynamic>? fields;

  @override
  String toString() => '$op $collection/$docId';
}

/// One tenant's records in the fake store.
class _FakeTenant {
  Map<String, dynamic>? doc = {'name': 'Ada Park', 'isActive': true};

  /// Facility collections (ledgers, invoices, ...) by name, this tenant's rows.
  final facilityRows = <String, List<Map<String, dynamic>>>{};

  /// The tenant's own subcollections (paymentMethods, payments) by name.
  final ownRows = <String, List<Map<String, dynamic>>>{};

  /// The tenant's own docs by 'subcollection/docId'.
  final subdocs = <String, Map<String, dynamic>>{};
  List<UnitModel> units = [];
  List<String> gateIds = [];
}

class _FakeRecords implements TenantRecordsStore {
  final tenants = <String, _FakeTenant>{};

  /// What a transaction reads as each unit's tenantId now.
  final unitHolders = <String, String?>{};

  /// Reads that fail, by source ('tenant', a collection name, 'units', ...).
  final failing = <String, Object>{};

  /// The writes of each committed transaction.
  final transactions = <List<_Write>>[];

  _FakeTenant operator [](String tenantId) =>
      tenants.putIfAbsent(tenantId, _FakeTenant.new);

  Future<T> _read<T>(String source, T Function() value) async {
    final error = failing[source];
    if (error != null) throw error;
    return value();
  }

  @override
  Future<Map<String, dynamic>?> tenant(String tenantId) =>
      _read('tenant', () => this[tenantId].doc);

  @override
  Future<List<Map<String, dynamic>>> facilityRows(
          String collection, String tenantId, int limit) =>
      _read(
          collection,
          () => (this[tenantId].facilityRows[collection] ?? const [])
              .take(limit)
              .toList());

  @override
  Future<List<Map<String, dynamic>>> tenantRows(
          String tenantId, String subcollection, int limit) =>
      _read(
          'tenant/$subcollection',
          () => (this[tenantId].ownRows[subcollection] ?? const [])
              .take(limit)
              .toList());

  @override
  Future<Map<String, dynamic>?> tenantSubdoc(
          String tenantId, String subcollection, String docId) =>
      _read('tenant/$subcollection/$docId',
          () => this[tenantId].subdocs['$subcollection/$docId']);

  @override
  Future<List<UnitModel>> linkedUnits(String tenantId) =>
      _read('units', () => this[tenantId].units);

  @override
  Future<UnitModel?> unit(String unitId) => _read('unit',
      () => facilityUnits.where((u) => u.id == unitId).firstOrNull);

  @override
  Future<List<String>> activeGateAccessIds(String tenantId) =>
      _read('gateAccess', () => this[tenantId].gateIds);

  @override
  Future<void> transaction(
      Future<void> Function(TenantRecordsTransaction txn) body) async {
    final txn = _FakeTransaction(unitHolders, (id) => this[id].doc);
    await body(txn);
    transactions.add(txn.writes);
  }

  List<String> get writtenPaths =>
      [for (final t in transactions) ...t.map((w) => '$w')];

  /// Writes made outside a transaction, in order.
  final directWrites = <_Write>[];

  /// Every unit in the facility, for lookups by number.
  final facilityUnits = <UnitModel>[];

  @override
  Future<void> updateTenant(String tenantId, Map<String, dynamic> fields) async {
    final error = failing['tenant.update'];
    if (error != null) throw error;
    directWrites.add(_Write('update', 'tenants', tenantId, fields));
    this[tenantId].doc = {...?this[tenantId].doc, ...fields};
  }

  @override
  Future<List<UnitModel>> unitsNumbered(String unitNumber) => _read(
      'unitsNumbered',
      () => [
            for (final u in facilityUnits)
              if (u.unitNumber == unitNumber) u
          ]);

  @override
  Future<String> createUnit(String unitNumber, double monthlyRate) async {
    directWrites.add(_Write('create', 'units', 'new-$unitNumber'));
    return 'new-$unitNumber';
  }

  /// Every write, transactional or not, as 'op collection/id'.
  List<String> get allWrites => [
        ...directWrites.map((w) => '$w'),
        ...writtenPaths,
      ];
}

/// A callable error as the plugin raises it.
class _CallableError extends FirebaseFunctionsException {
  _CallableError(String code, String message)
      : super(code: code, message: message);
}

/// Records what updateTenant would audit and refresh.
class _FakeEffects extends TenantUpdateEffects {
  final audits = <Map<String, dynamic>>[];
  var statsRefreshes = 0;
  var mapSyncs = 0;

  @override
  Future<void> audit({
    required String facilityId,
    required String tenantId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    required Map<String, dynamic> metadata,
  }) async =>
      audits.add(metadata);

  @override
  Future<void> refreshFacilityStats(String facilityId) async => statsRefreshes++;

  @override
  void syncPublicMap(String facilityId) => mapSyncs++;
}

class _FakeTransaction implements TenantRecordsTransaction {
  _FakeTransaction(this.holders, this.tenantDoc);

  final Map<String, String?> holders;
  final Map<String, dynamic>? Function(String tenantId) tenantDoc;
  final writes = <_Write>[];

  @override
  Future<String?> unitTenantId(String unitId) async {
    // Firestore refuses a read after a write in the same transaction.
    if (writes.isNotEmpty) throw StateError('read after write');
    return holders[unitId];
  }

  @override
  Future<Map<String, dynamic>?> tenant(String tenantId) async {
    if (writes.isNotEmpty) throw StateError('read after write');
    return tenantDoc(tenantId);
  }

  @override
  void update(String collection, String docId, Map<String, dynamic> fields) =>
      writes.add(_Write('update', collection, docId, fields));
}

/// Permanent tenant delete used to remove the tenant doc and leave their
/// ledger, invoices and payments behind: the balance vanished from AR and the
/// history could no longer be opened. Archive and the Active switch stopped
/// rent on units the tenant still held. These pin the guards.
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

  Map<String, dynamic> ledgerRow(LedgerEntryStatus s) =>
      entry(150, s).toFirestore();

  TenantDeletePlan plan(String id, String name,
          {List<String> reasons = const []}) =>
      TenantDeletePlan(tenantId: id, tenantName: name, blockers: reasons);

  group('live-row predicates read what the app stores', () {
    test('ledger: posted and pending are live, voided is not', () {
      expect(TenantService.isLiveLedgerRow(ledgerRow(LedgerEntryStatus.posted)), isTrue);
      expect(TenantService.isLiveLedgerRow(ledgerRow(LedgerEntryStatus.pending)), isTrue);
      expect(TenantService.isLiveLedgerRow(ledgerRow(LedgerEntryStatus.voided)), isFalse);
    });

    test('invoice: only voided is not live', () {
      for (final s in [
        InvoiceStatus.draft,
        InvoiceStatus.sent,
        InvoiceStatus.paid,
        InvoiceStatus.overdue,
      ]) {
        expect(TenantService.isLiveInvoiceRow(invoice(s).toFirestore()), isTrue,
            reason: s.name);
      }
      expect(
          TenantService.isLiveInvoiceRow(invoice(InvoiceStatus.voided).toFirestore()),
          isFalse);
    });

    test('payment: failed, cancelled and archived are not live', () {
      for (final s in [
        PaymentStatus.completed,
        PaymentStatus.paid,
        PaymentStatus.pending,
        PaymentStatus.refunded,
      ]) {
        expect(TenantService.isLivePaymentRow(payment(s).toFirestore()), isTrue,
            reason: s.name);
      }
      expect(TenantService.isLivePaymentRow({'status': 'disputed'}), isTrue);
      expect(TenantService.isLivePaymentRow(payment(PaymentStatus.failed).toFirestore()),
          isFalse);
      expect(
          TenantService.isLivePaymentRow(payment(PaymentStatus.cancelled).toFirestore()),
          isFalse);
      expect(
        TenantService.isLivePaymentRow(
            payment(PaymentStatus.completed, isActive: false).toFirestore()),
        isFalse,
      );
    });

    test('card payment rows: in flight or settled are live, failed or canceled are not', () {
      // What stripeFacilityOneTimeConnectedPayment writes before the charge.
      expect(TenantService.isLiveCardPaymentRow({'status': 'processing'}), isTrue);
      expect(TenantService.isLiveCardPaymentRow({'status': 'succeeded'}), isTrue);
      expect(TenantService.isLiveCardPaymentRow(const {}), isTrue);
      expect(TenantService.isLiveCardPaymentRow({'status': 'failed'}), isFalse);
      expect(TenantService.isLiveCardPaymentRow({'status': 'canceled'}), isFalse);
      expect(TenantService.isLiveCardPaymentRow({'status': 'cancelled'}), isFalse);
    });

    test('autopay: only a real subscription id counts', () {
      expect(TenantService.hasAutopaySubscription({'stripeSubscriptionId': 'sub_1'}), isTrue);
      expect(TenantService.hasAutopaySubscription({'stripeSubscriptionId': null}), isFalse);
      expect(TenantService.hasAutopaySubscription({'stripeSubscriptionId': ' '}), isFalse);
      expect(TenantService.hasAutopaySubscription({'autopayEnabled': false}), isFalse);
      expect(TenantService.hasAutopaySubscription(null), isFalse);
      // What arms autopay today: the flag, on billing/default or on a card.
      expect(TenantService.hasAutopaySubscription({'autopayEnabled': true}), isTrue);
      expect(
          TenantService.hasAutopaySubscription(null, [
            {'isActive': false, 'autopayEnabled': true}
          ]),
          isTrue);
      expect(
          TenantService.hasAutopaySubscription({'autopayEnabled': false}, [
            {'autopayEnabled': false}
          ]),
          isFalse);
    });

    test('cards and gate codes are on unless switched off', () {
      expect(TenantService.isActiveFlagSet({'isActive': true}), isTrue);
      expect(TenantService.isActiveFlagSet(const {}), isTrue);
      expect(TenantService.isActiveFlagSet({'isActive': false}), isFalse);
    });
  });

  group('scanLiveRows fails closed', () {
    test('a full page with nothing live is inconclusive; rows past the cap may be live', () {
      final voided = List.generate(10, (_) => ledgerRow(LedgerEntryStatus.voided));
      final full = TenantService.scanLiveRows(voided, TenantService.isLiveLedgerRow,
          scanLimit: 10);
      expect(full.live, 0);
      expect(full.inconclusive, isTrue);
      final partial = TenantService.scanLiveRows(
          voided.take(9), TenantService.isLiveLedgerRow,
          scanLimit: 10);
      expect(partial.inconclusive, isFalse);
    });

    test('a row that cannot be read counts as live', () {
      final scan = TenantService.scanLiveRows<int>(
        [1, 2],
        (row) => row == 1 ? throw const FormatException('bad row') : false,
        scanLimit: 10,
      );
      expect(scan.live, 1);
    });
  });

  group('permanentDeleteBlockers', () {
    test('a zero balance still blocks: history, not balance, is what counts', () {
      expect(TenantService.permanentDeleteBlockers(liveLedgerEntries: 2),
          ['charges or payments on the ledger']);
    });

    test('each kind of history names itself', () {
      expect(TenantService.permanentDeleteBlockers(contracts: 1), ['a contract']);
      expect(TenantService.permanentDeleteBlockers(liens: 2), ['liens']);
      expect(TenantService.permanentDeleteBlockers(activeSavedCards: 1), ['a saved card']);
      expect(TenantService.permanentDeleteBlockers(liveInvoices: 2), ['invoices']);
      expect(TenantService.permanentDeleteBlockers(livePayments: 1), ['a payment record']);
      expect(TenantService.permanentDeleteBlockers(liveCardPayments: 1),
          ['a card payment in progress or payment history']);
      expect(TenantService.permanentDeleteBlockers(hasAutopaySubscription: true),
          ['an autopay subscription']);
    });

    test('an unchecked full page gets its own reason, not "charges on the ledger"', () {
      expect(TenantService.permanentDeleteBlockers(moreThanChecked: true),
          ['more records than could be checked here']);
      expect(
        TenantService.permanentDeleteBlockers(liveInvoices: 1, moreThanChecked: true),
        ['an invoice'],
      );
    });

    test('a tenant with no records at all has no blockers', () {
      expect(TenantService.permanentDeleteBlockers(), isEmpty);
    });
  });

  group('loadDeletePlan maps each source to its own reason', () {
    // One live row in one place at a time: a result matched to the wrong
    // source (the old code read a list by index) names the wrong reason.
    final cases = <String, (void Function(_FakeTenant t), String)>{
      'ledgers': (
        (t) => t.facilityRows['ledgers'] = [ledgerRow(LedgerEntryStatus.posted)],
        'charges or payments on the ledger',
      ),
      'invoices': (
        (t) => t.facilityRows['invoices'] = [invoice(InvoiceStatus.sent).toFirestore()],
        'an invoice',
      ),
      'payments': (
        (t) => t.facilityRows['payments'] = [payment(PaymentStatus.completed).toFirestore()],
        'a payment record',
      ),
      'contracts, even an ended one': (
        (t) => t.facilityRows['contracts'] = [
              {'isActive': false, 'status': 'terminated'}
            ],
        'a contract',
      ),
      'liens, even a released one': (
        (t) => t.facilityRows['liens'] = [
              {'isActive': false, 'status': 'released'}
            ],
        'a lien',
      ),
      'saved cards': (
        (t) => t.ownRows['paymentMethods'] = [
              {'isActive': true}
            ],
        'a saved card',
      ),
      'card payments under the tenant': (
        (t) => t.ownRows['payments'] = [
              {'status': 'processing'}
            ],
        'a card payment in progress or payment history',
      ),
      'billing/default subscription': (
        (t) => t.subdocs['billing/default'] = {'stripeSubscriptionId': 'sub_1'},
        'an autopay subscription',
      ),
    };
    for (final c in cases.entries) {
      test(c.key, () async {
        final store = _FakeRecords();
        c.value.$1(store['t1']);
        final p = await TenantService.loadDeletePlan(store, 't1');
        expect(p.blockers, [c.value.$2]);
        expect(p.isBlocked, isTrue);
      });
    }

    test('rows that never became history do not block', () async {
      final store = _FakeRecords();
      store['t1']
        ..facilityRows['ledgers'] = [ledgerRow(LedgerEntryStatus.voided)]
        ..facilityRows['invoices'] = [invoice(InvoiceStatus.voided).toFirestore()]
        ..facilityRows['payments'] = [payment(PaymentStatus.failed).toFirestore()]
        ..ownRows['paymentMethods'] = [
          {'isActive': false}
        ]
        ..ownRows['payments'] = [
          {'status': 'canceled'}
        ]
        ..subdocs['billing/default'] = {'stripeSubscriptionId': null};
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.blockers, isEmpty);
      expect(p.isBlocked, isFalse);
    });

    test('a full page of voided rows is "more records than could be checked here"', () async {
      final store = _FakeRecords();
      store['t1'].facilityRows['ledgers'] =
          List.generate(10, (_) => ledgerRow(LedgerEntryStatus.voided));
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.blockers, ['more records than could be checked here']);
    });

    test('a unit alone does not block: it is reported to be freed', () async {
      final store = _FakeRecords();
      store['t1'].units = [
        unit('101', UnitStatus.occupied, 't1'),
        // A stale link on an available unit is unlinked, not held.
        unit('103', UnitStatus.available, 't1'),
      ];
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.blockers, isEmpty);
      expect(p.heldUnits, [const HeldUnit('101', UnitStatus.occupied)]);
      expect(p.isBlocked, isFalse);
    });

    test('autopay armed on a switched-off card blocks, with no subscription id', () async {
      final store = _FakeRecords();
      store['t1'].ownRows['paymentMethods'] = [
        {'isActive': false, 'autopayEnabled': true}
      ];
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.blockers, ['an autopay subscription']);
    });

    test('names the tenant from its doc, trimmed', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': ' Bo Diaz ', 'phone': '555'}
        ..units = [unit('9', UnitStatus.available, 't1')];
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.tenantName, 'Bo Diaz');
      expect(p.isBlocked, isFalse);
    });
  });

  group('permanentlyDelete: the pre-check, then the server decides', () {
    const deletedNothing = {
      'status': 'deleted',
      'unitsUnlinked': 0,
      'gateAccessDeactivated': 0,
    };

    Future<({int unitsUnlinked, int gateCodesOff})?> run(
      _FakeRecords store,
      List<String> ids, {
      Object? answer = deletedNothing,
      List<List<String>>? calls,
      bool confirm = true,
      List<List<TenantDeletePlan>>? asked,
    }) {
      return TenantService.permanentlyDelete(
        store,
        ids,
        deleteOnServer: (sent) async {
          calls?.add(sent);
          if (answer is Exception) throw answer;
          return answer;
        },
        confirmUnitsFreed: (freeing) async {
          asked?.add(freeing);
          return confirm;
        },
      );
    }

    test('a blocked tenant is refused without calling the server', () async {
      final store = _FakeRecords();
      store['t1'].facilityRows['ledgers'] = [ledgerRow(LedgerEntryStatus.posted)];
      final calls = <List<String>>[];
      await expectLater(run(store, ['t1'], calls: calls),
          throwsA(isA<TenantDeleteRefusedException>()));
      expect(calls, isEmpty);
      expect(store.transactions, isEmpty);
    });

    test('an occupant with no history: the owner is shown the unit, and "no" deletes nothing', () async {
      // A held unit used to refuse the delete outright, so a bad CSV import
      // could only be cleaned up by unassigning each unit by hand.
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      final calls = <List<String>>[];
      final asked = <List<TenantDeletePlan>>[];
      expect(await run(store, ['t1'], calls: calls, asked: asked, confirm: false), isNull);
      expect(asked.single.single.heldUnits, [const HeldUnit('101', UnitStatus.occupied)]);
      expect(calls, isEmpty);
    });

    test('an occupant with no history: "yes" sends the delete, which frees the unit', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      final calls = <List<String>>[];
      final result = await run(store, ['t1'],
          calls: calls,
          answer: {'status': 'deleted', 'unitsUnlinked': 1, 'gateAccessDeactivated': 0});
      expect(calls, [
        ['t1']
      ]);
      expect(result!.unitsUnlinked, 1);
    });

    test('nobody holding a unit: nothing to confirm', () async {
      final store = _FakeRecords();
      final asked = <List<TenantDeletePlan>>[];
      await run(store, ['t1'], asked: asked, confirm: false);
      expect(asked, isEmpty);
    });

    test('history is refused before the owner is asked about units', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      store['t2'].facilityRows['invoices'] = [invoice(InvoiceStatus.sent).toFirestore()];
      final asked = <List<TenantDeletePlan>>[];
      await expectLater(run(store, ['t1', 't2'], asked: asked),
          throwsA(isA<TenantDeleteRefusedException>()));
      expect(asked, isEmpty);
    });

    test('more than 100 is refused before any record is read', () async {
      // The callable refuses them, after the pre-check had read ~10 docs a
      // tenant, and the raw "[firebase_functions/invalid-argument]" reached
      // the screen.
      final store = _FakeRecords();
      store.failing['tenant'] = StateError('read');
      final calls = <List<String>>[];
      final ids = [for (var i = 0; i < 101; i++) 't$i'];
      await expectLater(
        run(store, ids, calls: calls),
        throwsA(isA<TenantDeleteTooManyException>().having((e) => e.message, 'message',
            'You selected 101 tenants. Permanent delete takes at most 100 at a time, '
            'so nothing was deleted. Select fewer and try again.')),
      );
      expect(calls, isEmpty);
      // Exactly 100 goes ahead.
      store.failing.clear();
      await run(store, ids.take(100).toList(), calls: calls);
      expect(calls.single, hasLength(100));
    });

    test("the callable's failures are worded for the owner, not '[firebase_functions/...]'", () async {
      Future<CallableFailureException> failure(Exception e) async {
        try {
          await run(_FakeRecords(), ['t1'], answer: e);
        } on CallableFailureException catch (f) {
          return f;
        }
        fail('expected a CallableFailureException');
      }

      expect((await failure(_CallableError('permission-denied', 'x'))).message,
          'Only the facility owner or a manager can permanently delete tenants. Nothing was deleted.');
      expect((await failure(_CallableError('not-found', 'NOT_FOUND'))).message,
          contains("Couldn't find this facility on the server, so nothing was deleted."));
      for (final code in ['unavailable', 'deadline-exceeded']) {
        expect((await failure(_CallableError(code, 'x'))).message,
            contains('the delete may not have gone through'),
            reason: code);
      }
      // Our callable's own words for what it refuses.
      expect(
          (await failure(_CallableError('failed-precondition',
                  'Nothing was deleted: too many records to change in one go.')))
              .message,
          'Nothing was deleted: too many records to change in one go.');
      // A bare internal error, in any case, may be a dropped connection
      // (the web SDK's 'internal'/'internal'): the delete may have happened.
      for (final bare in ['INTERNAL', 'internal']) {
        expect((await failure(_CallableError('internal', bare))).message,
            contains('the delete may not have gone through'),
            reason: bare);
      }
      expect(
          (await failure(_CallableError('internal',
                  "Couldn't delete. Refresh the tenant list to see what changed, then try again.")))
              .message,
          startsWith("Couldn't delete."));
      expect((await failure(_CallableError('unknown', 'UNKNOWN'))).message,
          contains('Something went wrong on our side'));
    });

    test('an unreadable record refuses the whole bulk delete before the server', () async {
      final store = _FakeRecords();
      store.failing['tenant/billing/default'] = FirebaseException(
          plugin: 'cloud_firestore', code: 'permission-denied');
      final calls = <List<String>>[];
      await expectLater(
        run(store, ['t1', 't2'], calls: calls),
        throwsA(isA<TenantDeleteCheckFailedException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains("Couldn't check the 2 selected tenants' records, so nothing was deleted."),
            contains('ask the facility owner'),
          ),
        )),
      );
      expect(calls, isEmpty);
    });

    test('a clean pre-check sends every id to the server once; the app writes nothing itself', () async {
      // The rules no longer let the app delete a tenant doc: the callable
      // unlinks the units, turns the gate codes off, deletes and audits.
      final store = _FakeRecords();
      store['t1'].units = [unit('9', UnitStatus.available, 't1')];
      store['t2'].doc = {'name': 'Bo Diaz'};
      final calls = <List<String>>[];
      final result = await run(
        store,
        ['t1', 't2'],
        calls: calls,
        answer: {'status': 'deleted', 'unitsUnlinked': 1, 'gateAccessDeactivated': 2},
      );
      expect(calls, [
        ['t1', 't2']
      ]);
      expect(result!.unitsUnlinked, 1);
      expect(result.gateCodesOff, 2);
      expect(store.transactions, isEmpty);
    });

    test("the server's refusal reads like the pre-check's", () async {
      // A charge or unit assignment made after the pre-check: the callable
      // reads again inside the transaction that deletes, and refuses.
      final store = _FakeRecords();
      final error = await run(store, ['t1', 't2'], answer: {
        'status': 'refused',
        'blocked': [
          {
            'tenantId': 't2',
            'tenantName': 'Bo Diaz',
            'reasons': ['an invoice'],
            'heldUnits': [
              {'unitNumber': '7', 'status': 'lockout'}
            ],
          },
        ],
      }).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<TenantDeleteRefusedException>());
      final refusal = error! as TenantDeleteRefusedException;
      expect(refusal.blocked.single.tenantId, 't2');
      expect(refusal.blocked.single.heldUnits, [const HeldUnit('7', UnitStatus.lockout)]);
      expect(refusal.message,
          'Nothing was deleted. Bo Diaz has an invoice and is still assigned to unit 7.');
      expect(refusal.details, contains('Units > unit 7 > Remove Lockout, then Unassign Tenant'));
    });
  });

  group('parseServerDeleteResult', () {
    test('reads the counts of a delete', () {
      final result = TenantService.parseServerDeleteResult(
          {'status': 'deleted', 'unitsUnlinked': 2, 'gateAccessDeactivated': 3});
      expect(result.unitsUnlinked, 2);
      expect(result.gateCodesOff, 3);
    });

    test('reads maps as the platform channel delivers them', () {
      final data = <Object?, Object?>{
        'status': 'refused',
        'blocked': <Object?>[
          <Object?, Object?>{
            'tenantId': 't1',
            'tenantName': 'Ada Park',
            'reasons': <Object?>['a saved card'],
            'heldUnits': <Object?>[
              <Object?, Object?>{'unitNumber': '101', 'status': 'occupied'},
              // Not a status the app knows: the plain Unassign step.
              <Object?, Object?>{'unitNumber': '102', 'status': 'somethingNew'},
            ],
          },
        ],
      };
      final refusal = (() {
        try {
          TenantService.parseServerDeleteResult(data);
        } on TenantDeleteRefusedException catch (e) {
          return e;
        }
        return null;
      })();
      expect(refusal, isNotNull);
      expect(refusal!.blockersByTenantName, {
        'Ada Park': ['a saved card']
      });
      expect(refusal.blocked.single.heldUnits, const [
        HeldUnit('101', UnitStatus.occupied),
        HeldUnit('102', UnitStatus.occupied),
      ]);
    });

    test('anything else is not taken as a delete', () {
      for (final data in <Object?>[
        null,
        'ok',
        const <String, Object?>{},
        const {'status': 'refused', 'blocked': <Object?>[]},
        const {'status': 'maybe'},
      ]) {
        expect(
          () => TenantService.parseServerDeleteResult(data),
          throwsA(isA<Exception>()
              .having((e) => '$e', 'text', contains("Couldn't confirm the delete"))),
          reason: '$data',
        );
      }
    });
  });

  group('parity with the deleteTenantsPermanently callable', () {
    // The same table functions-shared runs against the server's rules.
    final parity = jsonDecode(File(
            'functions-shared/src/test/fixtures/tenantDeleteParity.json')
        .readAsStringSync()) as Map<String, dynamic>;
    List<Map<String, dynamic>> maps(Object? list) => [
          for (final m in list as List? ?? const []) Map<String, dynamic>.from(m as Map)
        ];

    test('each row predicate matches the shared table', () {
      final predicates = <String, bool Function(Map<String, dynamic>)>{
        'ledger': TenantService.isLiveLedgerRow,
        'invoice': TenantService.isLiveInvoiceRow,
        'payment': TenantService.isLivePaymentRow,
        'cardPayment': TenantService.isLiveCardPaymentRow,
        'activeFlag': TenantService.isActiveFlagSet,
      };
      for (final c in maps(parity['rows'])) {
        final row = Map<String, dynamic>.from(c['row'] as Map);
        expect(predicates[c['kind']]!(row), c['live'], reason: '${c['kind']} $row');
      }
    });

    test('autopay subscription matches the shared table', () {
      for (final c in maps(parity['autopay'])) {
        final billing = c['billing'] == null
            ? null
            : Map<String, dynamic>.from(c['billing'] as Map);
        expect(TenantService.hasAutopaySubscription(billing, maps(c['paymentMethods'])),
            c['has'],
            reason: '$c');
      }
    });

    test('blocker wording matches the shared table word for word', () {
      for (final c in maps(parity['blockers'])) {
        final n = Map<String, dynamic>.from(c['counts'] as Map);
        final reasons = TenantService.permanentDeleteBlockers(
          liveLedgerEntries: n['liveLedgerEntries'] as int? ?? 0,
          liveInvoices: n['liveInvoices'] as int? ?? 0,
          livePayments: n['livePayments'] as int? ?? 0,
          liveCardPayments: n['liveCardPayments'] as int? ?? 0,
          contracts: n['contracts'] as int? ?? 0,
          liens: n['liens'] as int? ?? 0,
          activeSavedCards: n['activeSavedCards'] as int? ?? 0,
          hasAutopaySubscription: n['hasAutopaySubscription'] as bool? ?? false,
          moreThanChecked: n['moreThanChecked'] as bool? ?? false,
        );
        expect(reasons, c['reasons'], reason: '$n');
      }
    });

    test('plans give the same reasons, held units and verdict as the server', () async {
      expect(parity['scanLimit'], 10, reason: 'TenantService._deleteCheckScanLimit');
      expect(parity['maxTenantsPerDelete'], TenantService.maxTenantsPerDelete);
      for (final c in maps(parity['plans'])) {
        final records = Map<String, dynamic>.from(c['records'] as Map);
        final store = _FakeRecords();
        final t = store['t1'];
        if (records['tenant'] != null) {
          t.doc = Map<String, dynamic>.from(records['tenant'] as Map);
        }
        for (final name in ['ledgers', 'invoices', 'payments', 'contracts', 'liens']) {
          t.facilityRows[name] = maps(records[name]);
        }
        t.ownRows['paymentMethods'] = maps(records['paymentMethods']);
        t.ownRows['payments'] = maps(records['tenantPayments']);
        if (records['billing'] != null) {
          t.subdocs['billing/default'] = Map<String, dynamic>.from(records['billing'] as Map);
        }
        t.units = [
          for (final u in maps(records['units']))
            // As UnitModel.fromFirestore reads the status: unknown is available.
            unit(
              '${u['unitNumber']}',
              UnitStatus.values.firstWhere((s) => s.name == u['status'],
                  orElse: () => UnitStatus.available),
              u['tenantId'] as String? ?? 't1',
            ),
        ];

        final p = await TenantService.loadDeletePlan(store, 't1');
        expect(p.blockers, c['reasons'], reason: '${c['name']}');
        expect(
          [
            for (final h in p.heldUnits)
              {'unitNumber': h.unitNumber, 'status': h.status.name}
          ],
          c['heldUnits'],
          reason: '${c['name']}',
        );
        // Only history blocks; held units are freed by the delete.
        expect(p.isBlocked, c['blocked'], reason: '${c['name']}');
      }
    });
  });

  group('runPermanentDelete', () {
    test('with no way to ask about held units, nothing is freed or deleted', () async {
      final committed = <List<TenantDeletePlan>>[];
      final result = await TenantService.runPermanentDelete(
        tenantIds: ['t1'],
        loadPlan: (id) async => const TenantDeletePlan(
          tenantId: 't1',
          tenantName: 'Ada Park',
          heldUnits: [HeldUnit('101', UnitStatus.occupied)],
        ),
        commit: (plans) async => committed.add(plans),
      );
      expect(result, isNull);
      expect(committed, isEmpty);
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
      expect(error, isA<TenantDeleteRefusedException>());
      final refusal = error! as TenantDeleteRefusedException;
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

  group('archive guard', () {
    test('refuses while an occupied unit shows the tenant, and writes nothing', () async {
      final store = _FakeRecords();
      store['t1']
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      await expectLater(
        TenantService.archiveWith(store, 't1', uid: 'owner'),
        throwsA(isA<TenantStillAssignedToUnitException>()
            .having((e) => e.units, 'units', [const HeldUnit('101', UnitStatus.occupied)])),
      );
      expect(store.transactions, isEmpty);
    });

    test('names the step that frees a locked-out unit', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('7', UnitStatus.lockout, 't1')];
      await expectLater(
        TenantService.archiveWith(store, 't1', uid: 'owner'),
        throwsA(isA<TenantStillAssignedToUnitException>().having((e) => e.message,
            'message', contains('Units > unit 7 > Remove Lockout, then Unassign Tenant'))),
      );
    });

    test('archives and turns the gate codes off in the same transaction', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true}
        // A stale link on an available unit does not block and is left alone.
        ..units = [unit('103', UnitStatus.available, 't1')]
        ..gateIds = ['g1', 'g2'];
      final result = await TenantService.archiveWith(store, 't1', uid: 'owner');
      expect(store.transactions, hasLength(1));
      expect(store.writtenPaths, [
        'update tenants/t1',
        'update gateAccess/g1',
        'update gateAccess/g2',
      ]);
      expect(store.transactions.single.first.fields!['isActive'], isFalse);
      expect(result.gateCodesOff, 2);
      expect(result.before, {'name': 'Ada Park', 'isActive': true});
    });
  });

  group('updateTenant deactivation guard', () {
    test('releasing: a call that sets a unit frees the old and new numbers', () {
      expect(TenantService.unitNumbersReleasedByUpdate(previous: '101', requested: '101'),
          {'101'});
      expect(TenantService.unitNumbersReleasedByUpdate(previous: '101', requested: ''),
          {'101'});
      expect(TenantService.unitNumbersReleasedByUpdate(previous: '101', requested: '102'),
          {'101', '102'});
      expect(TenantService.unitNumbersReleasedByUpdate(previous: '', requested: ' '), isEmpty);
      // The Active switch passes no unit number and frees nothing.
      expect(TenantService.unitNumbersReleasedByUpdate(previous: '101'), isEmpty);
    });

    test("held minus released: a tenant assigned from the Units screen keeps unitNumber ''", () {
      final held = TenantService.unitsHeldByTenant(
        't1',
        [unit('101', UnitStatus.occupied, 't1')],
        releasing: TenantService.unitNumbersReleasedByUpdate(previous: '', requested: ''),
      );
      expect(held, [const HeldUnit('101', UnitStatus.occupied)]);
    });

    test('held minus released: the second of two units is still held', () {
      final held = TenantService.unitsHeldByTenant(
        't1',
        [
          unit('101', UnitStatus.occupied, 't1'),
          unit('102', UnitStatus.occupied, 't1'),
          unit('103', UnitStatus.occupied, 't2'),
        ],
        releasing: {'101'},
      );
      expect(held, [const HeldUnit('102', UnitStatus.occupied)]);
    });

    Future<({int unitsFreed, int gateCodesOff})> deactivate(
      _FakeRecords store, {
      required String previousUnit,
      required String? requestedUnit,
    }) {
      return TenantService.deactivateForUpdate(
        store,
        tenantId: 't1',
        before: {'name': 'Ada Park', 'unitNumber': previousUnit, 'isActive': true},
        requestedUnitNumber: requestedUnit,
        updateData: {'isActive': false, 'unitNumber': requestedUnit},
        uid: 'owner',
      );
    }

    test("Edit Tenant with unitNumber '' is refused while the tenant holds a unit", () async {
      // The repro: assigned from Units > Assign Tenant, so tenant.unitNumber
      // stayed ''. The edit screen passes '' and the old guard never ran,
      // then turned off this paying occupant's gate code.
      final store = _FakeRecords();
      store['t1']
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      await expectLater(
        deactivate(store, previousUnit: '', requestedUnit: ''),
        throwsA(isA<TenantStillAssignedToUnitException>()),
      );
      expect(store.transactions, isEmpty);
    });

    test('a tenant with two units is refused for the one this edit does not free', () async {
      final store = _FakeRecords();
      store['t1'].units = [
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.occupied, 't1'),
      ];
      await expectLater(
        deactivate(store, previousUnit: '101', requestedUnit: '101'),
        throwsA(isA<TenantStillAssignedToUnitException>()
            .having((e) => e.units, 'units', [const HeldUnit('102', UnitStatus.occupied)])),
      );
      expect(store.transactions, isEmpty);
    });

    test('the Active switch is refused while any unit is held', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      await expectLater(
        deactivate(store, previousUnit: '101', requestedUnit: null),
        throwsA(isA<TenantStillAssignedToUnitException>()),
      );
    });

    test('frees the unit and turns the gate code off with the tenant update', () async {
      final store = _FakeRecords();
      store['t1']
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      store.unitHolders['u101'] = 't1';
      final result = await deactivate(store, previousUnit: '101', requestedUnit: '101');
      expect(store.transactions, hasLength(1));
      expect(store.writtenPaths, [
        'update tenants/t1',
        'update units/u101',
        'update gateAccess/g1',
      ]);
      expect(store.transactions.single.first.fields,
          {'isActive': false, 'unitNumber': '101'});
      expect(result.unitsFreed, 1);
      expect(result.gateCodesOff, 1);
    });

    test('a unit reassigned since the check is not freed', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      store.unitHolders['u101'] = 't2';
      final result = await deactivate(store, previousUnit: '101', requestedUnit: '');
      expect(store.writtenPaths, ['update tenants/t1']);
      expect(result.unitsFreed, 0);
    });

  });

  group('updateTenant, through the service', () {
    // updateTenant itself, with its reads and writes on the fake store: the
    // guards used to be tested only as helpers, so putting the old checks
    // back in updateTenant left every test passing.
    Future<void> update(
      _FakeRecords store, {
      _FakeEffects? effects,
      String? unitNumber,
      bool? isActive,
      String? phone,
    }) {
      return TenantService.updateTenant(
        facilityId: 'f1',
        tenantId: 't1',
        unitNumber: unitNumber,
        isActive: isActive,
        phone: phone,
        records: store,
        effects: effects ?? _FakeEffects(),
        actingUid: 'owner',
      );
    }

    test("Edit Tenant switching off with unitNumber '' is refused while a unit is held", () async {
      // Assigned from Units > Assign Tenant, so tenant.unitNumber stayed ''.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': ''}
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      await expectLater(update(store, unitNumber: '', isActive: false),
          throwsA(isA<TenantStillAssignedToUnitException>()));
      expect(store.allWrites, isEmpty);
    });

    test('the Active switch is refused while a unit is held', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      await expectLater(update(store, isActive: false),
          throwsA(isA<TenantStillAssignedToUnitException>()));
      expect(store.allWrites, isEmpty);
    });

    test('switching off frees the released unit and the gate code with the tenant, then refreshes', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      store.unitHolders['u101'] = 't1';
      final effects = _FakeEffects();
      await update(store, effects: effects, unitNumber: '101', isActive: false);
      expect(store.transactions, hasLength(1));
      expect(store.writtenPaths,
          ['update tenants/t1', 'update units/u101', 'update gateAccess/g1']);
      expect(store.directWrites, isEmpty);
      expect(effects.audits.single['unitsFreed'], 1);
      expect(effects.audits.single['gateAccessDeactivated'], 1);
      expect(effects.statsRefreshes, 1);
      expect(effects.mapSyncs, 1);
    });

    test('a changed unit number adds the new unit and never frees the one still held', () async {
      // Move-in of a second unit went through here and freed the first,
      // listing a unit the tenant still rented as available.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.available, null),
      ]);
      await update(store, unitNumber: '102');
      expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
      final linked = store.transactions.single.single.fields!;
      expect(linked['tenantId'], 't1');
      expect(linked['tenantName'], 'Ada Park');
      expect(linked['status'], 'occupied');
    });

    test('reactivating onto a unit another tenant holds is refused before anything is written', () async {
      // A stale unitNumber from an old deactivation used to take the unit.
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': false, 'unitNumber': '101'};
      store.facilityUnits.add(UnitModel(
        id: 'u101',
        facilityId: 'f1',
        unitNumber: '101',
        unitType: 'standard',
        status: UnitStatus.occupied,
        tenantId: 't2',
        tenantName: 'Bo Diaz',
        monthlyRate: 100,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
      ));
      await expectLater(
        update(store, unitNumber: '101', isActive: true),
        throwsA(isA<UnitHeldByAnotherTenantException>().having((e) => e.message,
            'message', startsWith('Unit 101 is assigned to Bo Diaz. Nothing was saved.'))),
      );
      expect(store.allWrites, isEmpty);
    });

    test('a stale link on an available unit is not a holder: the unit is assigned', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': ''};
      store.facilityUnits.add(unit('9', UnitStatus.available, 't2'));
      store.unitHolders['u9'] = 't2';
      await update(store, unitNumber: '9');
      expect(store.writtenPaths, ['update units/u9']);
    });

    test('a unit taken by someone else after the check is not overwritten', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': ''};
      store.facilityUnits.add(unit('9', UnitStatus.available, null));
      store.unitHolders['u9'] = 't2';
      await expectLater(update(store, unitNumber: '9'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.writtenPaths, isEmpty);
    });

    test('saving a locked-out tenant leaves the lockout alone', () async {
      // Saving any field used to "heal" the unit back to occupied.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '7'}
        ..units = [unit('7', UnitStatus.lockout, 't1')];
      store.facilityUnits.add(unit('7', UnitStatus.lockout, 't1'));
      final effects = _FakeEffects();
      await update(store, effects: effects, unitNumber: '7', phone: '555');
      expect(store.allWrites, ['update tenants/t1']);
      expect(effects.statsRefreshes, 0);
    });

    test('clearing the number of a unit still held is refused: it would stop their rent', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      await expectLater(
        update(store, unitNumber: ''),
        throwsA(isA<TenantStillAssignedToUnitException>().having((e) => e.message,
            'message', contains("Clearing the unit number doesn't free it"))),
      );
      expect(store.allWrites, isEmpty);
    });

    test('a unit number that no longer names a held unit can be cleared', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'};
      await update(store, unitNumber: '');
      expect(store.allWrites, ['update tenants/t1']);
      expect(store['t1'].doc!['unitNumber'], '');
    });

    test('an inactive tenant is never given a unit by an edit', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': false, 'unitNumber': ''};
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      await update(store, unitNumber: '102', phone: '555');
      expect(store.allWrites, ['update tenants/t1']);
    });

    group('a doc with no isActive is inactive, as TenantModel reads it', () {
      test('switching it off is a plain save, not a refused deactivation', () async {
        // `?? true` ran the deactivation guard on it and refused the save.
        final store = _FakeRecords();
        store['t1']
          ..doc = {'name': 'Ada Park', 'unitNumber': '101'}
          ..units = [unit('101', UnitStatus.occupied, 't1')];
        await update(store, isActive: false);
        expect(store.allWrites, ['update tenants/t1']);
        expect(store['t1'].doc!['isActive'], isFalse);
      });

      test('an edit does not link a unit to it', () async {
        final store = _FakeRecords();
        store['t1'].doc = {'name': 'Ada Park', 'unitNumber': ''};
        store.facilityUnits.add(unit('102', UnitStatus.available, null));
        await update(store, unitNumber: '102');
        expect(store.allWrites, ['update tenants/t1']);
      });
    });

    group('an unchanged unit number another tenant now holds', () {
      UnitModel bosUnit() => UnitModel(
            id: 'u101',
            facilityId: 'f1',
            unitNumber: '101',
            unitType: 'standard',
            status: UnitStatus.occupied,
            tenantId: 't2',
            tenantName: 'Bo Diaz',
            monthlyRate: 100,
            createdAt: day,
            updatedAt: day,
            createdBy: 'owner',
          );

      test('saves the other fields, links nothing, and says why', () async {
        // After Unassign Tenant left '101' on Ada and the unit went to Bo, a
        // phone change for Ada failed with "Nothing was saved".
        final store = _FakeRecords();
        store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'};
        store.facilityUnits.add(bosUnit());
        final notice = await TenantService.updateTenant(
          facilityId: 'f1',
          tenantId: 't1',
          unitNumber: '101',
          phone: '555',
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );
        expect(store.allWrites, ['update tenants/t1']);
        expect(store['t1'].doc!['phone'], '555');
        expect(
          notice,
          'Unit 101 is now assigned to Bo Diaz, so it was not linked to Ada '
          "Park. Update Ada Park's unit number if they moved.",
        );
      });

      test('a changed number another tenant holds is still refused', () async {
        final store = _FakeRecords();
        store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '100'};
        store.facilityUnits.add(bosUnit());
        await expectLater(update(store, unitNumber: '101', phone: '555'),
            throwsA(isA<UnitHeldByAnotherTenantException>()));
        expect(store.allWrites, isEmpty);
      });
    });

    group('Edit Tenant giving a tenant a different unit', () {
      // The picker fills in the new unit's number and rate (120 here).
      Future<String?> pick(
        _FakeRecords store, {
        ConfirmFreeUnit? confirm,
        _FakeEffects? effects,
      }) =>
          TenantService.updateTenant(
            facilityId: 'f1',
            tenantId: 't1',
            unitNumber: '102',
            monthlyRate: 120,
            confirmFreeOldUnit: confirm,
            records: store,
            effects: effects ?? _FakeEffects(),
            actingUid: 'owner',
          );

      _FakeRecords holding101() {
        final store = _FakeRecords();
        store['t1']
          ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100}
          ..units = [unit('101', UnitStatus.occupied, 't1')];
        store.facilityUnits.addAll([
          unit('101', UnitStatus.occupied, 't1'),
          unit('102', UnitStatus.available, null),
        ]);
        store.unitHolders['u101'] = 't1';
        return store;
      }

      test('asks "Also free unit 101?"; yes frees it with the link, rate the new unit\'s', () async {
        final store = holding101();
        final asked = <String>[];
        final effects = _FakeEffects();
        final notice = await pick(store, effects: effects, confirm: (n) async {
          asked.add(n);
          return true;
        });
        expect(asked, ['101']);
        expect(store.allWrites,
            ['update tenants/t1', 'update units/u101', 'update units/u102']);
        final freed = store.transactions.single.first.fields!;
        expect(freed['status'], 'available');
        expect(freed['updatedBy'], 'owner');
        expect(store['t1'].doc!['monthlyRate'], 120);
        expect(store['t1'].doc!['unitNumber'], '102');
        expect(notice, isNull);
        expect(effects.audits.single['unitsReleased'], ['101']);
        expect(effects.mapSyncs, 1);
      });

      test('no keeps both, and the rate becomes the sum of the two', () async {
        final store = holding101();
        final notice = await pick(store, confirm: (_) async => false);
        expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
        expect(store['t1'].doc!['monthlyRate'], 220);
        expect(notice, r'Monthly rent is now $220.00 for units 101 and 102.');
      });

      test('with no way to ask, nothing is freed: both kept, rate summed', () async {
        final store = holding101();
        await pick(store);
        expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
        expect(store['t1'].doc!['monthlyRate'], 220);
      });

      test('freeing one of two units keeps the other in the rate', () async {
        final store = holding101();
        store['t1']
          ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}
          ..units = [unit('101', UnitStatus.occupied, 't1'), unit('103', UnitStatus.occupied, 't1')];
        final notice = await pick(store, confirm: (_) async => true);
        // 250 - 100 (unit 101) + 120 (unit 102).
        expect(store['t1'].doc!['monthlyRate'], 270);
        expect(notice, r'Monthly rent is now $270.00 for units 103 and 102.');
      });

      test('a unit 101 given to someone else meanwhile is not freed', () async {
        final store = holding101();
        store.unitHolders['u101'] = 't2';
        await pick(store, confirm: (_) async => true);
        expect(store.writtenPaths, ['update units/u102']);
      });
    });
  });

  group('Unassign Tenant takes the unit off its tenant too', () {
    setUp(() => UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner')));
    tearDown(() => UnitService.authForTesting = null);

    Future<void> unassign(_FakeRecords store, String unitId) =>
        UnitService.removeTenantFromUnit(
            facilityId: 'f1', unitId: unitId, records: store);

    _FakeRecords holdingTwo() {
      final store = _FakeRecords();
      final u101 = unit('101', UnitStatus.occupied, 't1');
      final u102 = unit('102', UnitStatus.lockout, 't1');
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}
        ..units = [u101, u102];
      store.facilityUnits.addAll([u101, u102]);
      store.unitHolders.addAll({'u101': 't1', 'u102': 't1'});
      return store;
    }

    test('its rate comes off theirs and their unit number moves to the unit they keep', () async {
      // It only freed the unit: the tenant kept '101' (so once 101 went to
      // someone else, saving either tenant failed) and kept paying for it.
      final store = holdingTwo();
      await unassign(store, 'u101');
      expect(store.writtenPaths, ['update units/u101', 'update tenants/t1']);
      final unitWrite = store.transactions.single.first.fields!;
      expect(unitWrite['status'], 'available');
      expect(unitWrite['updatedBy'], 'owner');
      final tenantWrite = store.transactions.single.last.fields!;
      expect(tenantWrite['monthlyRate'], 150);
      expect(tenantWrite['unitNumber'], '102');
    });

    test('their last unit: the unit number is cleared and the rate never goes below 0', () async {
      final store = holdingTwo();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 60}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      await unassign(store, 'u101');
      final tenantWrite = store.transactions.single.last.fields!;
      expect(tenantWrite['monthlyRate'], 0);
      expect(tenantWrite['unitNumber'], '');
    });

    test('a unit number naming another unit is left alone', () async {
      final store = holdingTwo();
      await unassign(store, 'u102');
      final tenantWrite = store.transactions.single.last.fields!;
      expect(tenantWrite['monthlyRate'], 150);
      expect(tenantWrite.containsKey('unitNumber'), isFalse);
    });

    test('a unit that changed hands meanwhile is freed, and nobody else is touched', () async {
      final store = holdingTwo();
      store.unitHolders['u101'] = 't2';
      await unassign(store, 'u101');
      expect(store.writtenPaths, ['update units/u101']);
    });
  });

  group('move-in of an additional unit', () {
    Future<String?> moveIn(_FakeRecords store, String unitNumber, double rate) =>
        TenantService.recordMoveInUnit(
          facilityId: 'f1',
          tenantId: 't1',
          unitNumber: unitNumber,
          monthlyRate: rate,
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );

    test("the first unit is kept, and the new unit's rate is added to theirs", () async {
      // The rent job bills one monthlyRate per tenant. It was left at the
      // first unit's rate, so the second unit was never billed.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.available, null),
      ]);
      // 35 is the prorated first month; the unit's full rate (100) is added.
      final notice = await moveIn(store, '102', 35);
      expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
      expect(store['t1'].doc!['unitNumber'], '101');
      expect(store['t1'].doc!['monthlyRate'], 200);
      expect(store['t1'].doc!['isActive'], isTrue);
      expect(notice, r'Monthly rent is now $200.00 for units 101 and 102.');
    });

    test("a tenant's first unit becomes their unit number and rate, as before", () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '', 'monthlyRate': 0};
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      expect(await moveIn(store, '102', 80), isNull);
      expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
      expect(store['t1'].doc!['unitNumber'], '102');
      expect(store['t1'].doc!['monthlyRate'], 80);
    });

    test('a stale unit number is not a held unit: it is a first unit, prorated rate and all', () async {
      // Their unitNumber names a unit they no longer hold. Counting it as
      // held kept the stale number and added to the old rate.
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100};
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      expect(await moveIn(store, '102', 35), isNull);
      expect(store['t1'].doc!['unitNumber'], '102');
      expect(store['t1'].doc!['monthlyRate'], 35);
    });

    test('a returning archived tenant is made active again, and their unit linked', () async {
      // Move-in never passed isActive, so they stayed inactive: rent,
      // autopay and lockout all skip inactive tenants.
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': false, 'unitNumber': '', 'monthlyRate': 0};
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      await moveIn(store, '102', 80);
      expect(store['t1'].doc!['isActive'], isTrue);
      expect(store.allWrites, ['update tenants/t1', 'update units/u102']);
    });

    test("a returning archived tenant can't be moved into a unit someone else holds", () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': false, 'unitNumber': '101'};
      store.facilityUnits.add(unit('102', UnitStatus.occupied, 't2'));
      await expectLater(
          moveIn(store, '102', 80), throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
    });

    test("another tenant's unit is refused before anything is written", () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.add(unit('102', UnitStatus.occupied, 't2'));
      await expectLater(
          moveIn(store, '102', 35), throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
    });
  });

  group('move-out: the tenant step', () {
    Future<String?> settle(_FakeRecords store, {String unitId = 'u102'}) =>
        MoveOutService.settleTenantAfterMoveOut(
          facilityId: 'f1',
          tenantId: 't1',
          unitId: unitId,
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );

    test('a tenant who still rents another unit stays active, gate code on', () async {
      // Moving out of one of two units set the tenant inactive (rent and
      // autopay stopped on the other), then, with the guard, failed with
      // "Error completing move-out" after the fees were posted.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '102'}
        ..units = [unit('101', UnitStatus.occupied, 't1')]
        ..gateIds = ['g1'];
      store.facilityUnits.add(unit('101', UnitStatus.occupied, 't1'));
      expect(await settle(store), isNull);
      expect(store.allWrites, ['update tenants/t1']);
      final fields = store.directWrites.single.fields!;
      expect(fields['unitNumber'], '101');
      expect(fields.containsKey('isActive'), isFalse);
      expect(store['t1'].doc!['isActive'], isTrue);
    });

    test('their unit number is left alone when it names a unit they still hold', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101'}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      expect(await settle(store), isNull);
      expect(store.allWrites, isEmpty);
    });

    test("the unit they left comes off their rate, which is the sum of their units'", () async {
      // It used to stay, so they went on paying for the unit they gave up.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '102', 'monthlyRate': 250}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.occupied, 't1'),
        // The unit moved out of, already freed; 100 a month.
        unit('102', UnitStatus.available, null),
      ]);
      expect(await settle(store), isNull);
      final fields = store.directWrites.single.fields!;
      expect(fields['monthlyRate'], 150);
      expect(fields['unitNumber'], '101');
      expect(store['t1'].doc!['isActive'], isTrue);
    });

    test('with the unit number still naming a unit they hold, only the rate changes', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 60}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      expect(await settle(store), isNull);
      expect(store.allWrites, ['update tenants/t1']);
      // Never below 0.
      expect(store['t1'].doc!['monthlyRate'], 0);
      expect(store['t1'].doc!['unitNumber'], '101');
    });

    test('their last unit: switched off, gate codes with it, in one transaction', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '102'}
        ..gateIds = ['g1'];
      expect(await settle(store), isNull);
      expect(store.writtenPaths, ['update tenants/t1', 'update gateAccess/g1']);
      expect(store.transactions.single.first.fields!['isActive'], isFalse);
      expect(store.transactions.single.first.fields!['unitNumber'], '');
    });

    test('a failure after the money is posted is a warning, not a failed move-out', () async {
      final store = _FakeRecords();
      store.failing['tenant'] =
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      final warning = await settle(store);
      expect(warning, contains('The move-out, charges and refund are recorded'));
      expect(warning, contains('gate access'));
    });
  });

  group('the units-freed confirmation names every unit', () {
    test('one tenant, one unit', () {
      final text = TenantService.unitsFreedMessage([
        const TenantDeletePlan(
            tenantId: 't1',
            tenantName: 'Ada Park',
            heldUnits: [HeldUnit('101', UnitStatus.occupied)]),
      ]);
      expect(
          text,
          'This unit is still assigned to the tenant you are deleting:\n'
          '• Ada Park: unit 101\n\n'
          'It will be unassigned and listed as available to rent. Only go ahead '
          'if they never actually rented it.');
    });

    test('several tenants and units, with any status that is not plain occupied', () {
      final text = TenantService.unitsFreedMessage([
        const TenantDeletePlan(tenantId: 't1', tenantName: 'Ada Park', heldUnits: [
          HeldUnit('101', UnitStatus.occupied),
          HeldUnit('7', UnitStatus.lockout),
        ]),
        const TenantDeletePlan(
            tenantId: 't2',
            tenantName: 'Bo Diaz',
            heldUnits: [HeldUnit('9', UnitStatus.outOfOrder)]),
      ]);
      expect(text, startsWith('These units are still assigned to the tenants you are deleting:'));
      expect(text, contains('• Ada Park: unit 101, unit 7 (lockout)'));
      expect(text, contains('• Bo Diaz: unit 9 (out of order)'));
      expect(text, contains('Each will be unassigned and listed as available to rent.'));
    });
  });

  group('refusal copy leads somewhere', () {
    test('each unit status gets the step that frees it', () {
      expect(const HeldUnit('1', UnitStatus.occupied).freeingSteps,
          'Units > unit 1 > Unassign Tenant');
      for (final s in [UnitStatus.lockout, UnitStatus.overlocked]) {
        expect(HeldUnit('1', s).freeingSteps,
            'Units > unit 1 > Remove Lockout, then Unassign Tenant');
      }
      for (final s in [
        UnitStatus.reserved,
        UnitStatus.maintenance,
        UnitStatus.outOfOrder,
        UnitStatus.auction,
      ]) {
        expect(HeldUnit('1', s).freeingSteps,
            'Units > unit 1 > Edit Unit, set Status to Occupied, then Unassign Tenant');
      }
    });

    test('unit detail offers Remove Lockout on a locked-out unit', () {
      // Before, it was only offered on occupied units, and Set Lockout moves
      // the unit to lockout, so the step above led nowhere.
      expect(unitOffersRemoveLockout(unit('1', UnitStatus.lockout, 't1')), isTrue);
      expect(unitOffersRemoveLockout(unit('1', UnitStatus.overlocked, 't1')), isTrue);
      expect(unitOffersRemoveLockout(unit('1', UnitStatus.occupied, 't1')), isFalse);
      expect(unitOffersRemoveLockout(unit('1', UnitStatus.auction, 't1')), isFalse);
    });

    test('the still-assigned refusal is neutral between Archive and the Active switch', () {
      const e = TenantStillAssignedToUnitException(
        tenantName: 'Ada Park',
        units: [
          HeldUnit('101', UnitStatus.occupied),
          HeldUnit('102', UnitStatus.reserved),
        ],
      );
      expect(e.message, contains('Ada Park is still assigned to units 101 and 102.'));
      expect(e.message, contains('Unassign the units first'));
      expect(e.message, contains("can't be archived or set inactive"));
      expect(e.message, isNot(contains('then archive')));
      expect(e.toString(), e.message);
    });

    test('a single refusal offers Archive only to a tenant who holds no unit', () {
      const historyOnly = TenantDeleteBlock(
          tenantId: 't1', tenantName: 'Ada Park', reasons: ['an invoice']);
      expect(historyOnly.canArchiveInstead, isTrue);
      expect(const TenantDeleteRefusedException([historyOnly]).details,
          contains('You can archive Ada Park instead'));

      const both = TenantDeleteBlock(
        tenantId: 't1',
        tenantName: 'Ada Park',
        reasons: ['an invoice'],
        heldUnits: [HeldUnit('101', UnitStatus.occupied)],
      );
      final details = const TenantDeleteRefusedException([both]).details;
      expect(details, startsWith('Ada Park has an invoice and is still assigned to unit 101.'));
      expect(details, contains('Then archive them.'));
      expect(details, isNot(contains('archive Ada Park instead')));
    });

    test('a bulk refusal lists each tenant and counts those who can be archived', () {
      const refusal = TenantDeleteRefusedException([
        TenantDeleteBlock(tenantId: 'a', tenantName: 'Ada Park', reasons: ['an invoice']),
        TenantDeleteBlock(
          tenantId: 'b',
          tenantName: 'Bo Diaz',
          reasons: ['a lien'],
          heldUnits: [HeldUnit('7', UnitStatus.lockout)],
        ),
      ]);
      expect(refusal.details, startsWith('Nothing was deleted. These tenants have history that has to be kept:'));
      expect(refusal.details, contains('• Ada Park: has an invoice.'));
      expect(
          refusal.details,
          contains('• Bo Diaz: has a lien and is still assigned to unit 7. Unassign the unit first '
              '(Units > unit 7 > Remove Lockout, then Unassign Tenant).'));
      expect(refusal.details, contains('archive the 1 tenant who holds no unit'));
    });

    test('a failed check says why, by cause', () {
      String message(Object cause, {int count = 1}) =>
          TenantDeleteCheckFailedException(cause, tenantCount: count).message;

      final denied = message(
          FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'));
      expect(denied, startsWith("Couldn't check this tenant's records, so nothing was deleted."));
      expect(denied, contains('ask the facility owner'));

      expect(message(FirebaseException(plugin: 'cloud_firestore', code: 'unavailable')),
          contains('Check your connection'));
      expect(message(TimeoutException('slow')), contains('Check your connection'));

      // A programming error is not a connection problem.
      final bug = message(const FormatException('bad cast'), count: 3);
      expect(bug, startsWith("Couldn't check the 3 selected tenants' records"));
      expect(bug, isNot(contains('connection')));
      expect(bug, contains('contact support'));
      // Tests run in debug mode, where the cause is shown.
      expect(bug, contains('bad cast'));
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
