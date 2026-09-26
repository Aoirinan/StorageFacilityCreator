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
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/callable_failure.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/unit_number.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

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
    // Committed: a tenant read afterwards sees it, as in Firestore.
    for (final w in txn.writes) {
      if (w.collection == 'tenants') {
        this[w.docId].doc = {...?this[w.docId].doc, ...?w.fields};
      }
    }
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
              if (unitNumberKey(u.unitNumber) == unitNumberKey(unitNumber)) u
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

  UnitModel unit(String number, UnitStatus status, String? tenantId,
          {double rate = 100}) =>
      UnitModel(
        id: 'u$number',
        facilityId: 'f1',
        unitNumber: number,
        unitType: 'standard',
        status: status,
        tenantId: tenantId,
        monthlyRate: rate,
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
      // The tenant's fields commit with the link, in one transaction.
      expect(store.directWrites, isEmpty);
      expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
      final linked = store.transactions.single.first.fields!;
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
      expect(store.writtenPaths, ['update units/u9', 'update tenants/t1']);
      expect(store['t1'].doc!['unitNumber'], '9');
    });

    test('a unit taken by someone else after the check is not overwritten', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': ''};
      store.facilityUnits.add(unit('9', UnitStatus.available, null));
      store.unitHolders['u9'] = 't2';
      await expectLater(update(store, unitNumber: '9'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      // Nor the tenant: their fields used to be written before the link.
      expect(store.allWrites, isEmpty);
      expect(store['t1'].doc!['unitNumber'], '');
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
      // Unit 102 rents at 120. The picker fills in its number and rate; a
      // typed number leaves the form's rate at their total.
      Future<String?> pick(
        _FakeRecords store, {
        ConfirmFreeUnit? confirm,
        _FakeEffects? effects,
        double monthlyRate = 120,
      }) =>
          TenantService.updateTenant(
            facilityId: 'f1',
            tenantId: 't1',
            unitNumber: '102',
            monthlyRate: monthlyRate,
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
          unit('102', UnitStatus.available, null, rate: 120),
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
        // One transaction: the old unit freed, the new one linked, the tenant.
        expect(store.directWrites, isEmpty);
        expect(store.writtenPaths,
            ['update units/u101', 'update units/u102', 'update tenants/t1']);
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
        expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
        expect(store['t1'].doc!['monthlyRate'], 220);
        expect(notice, r'Monthly rent is now $220.00 for units 101 and 102.');
      });

      test("a typed unit number adds the unit's own rate, not the form's total", () async {
        // The form's Monthly Rate holds their total (100) unless the picker
        // is used. Added, keeping both came to 200, not 220.
        final store = holding101();
        final notice =
            await pick(store, monthlyRate: 100, confirm: (_) async => false);
        expect(store['t1'].doc!['monthlyRate'], 220);
        expect(notice, r'Monthly rent is now $220.00 for units 101 and 102.');
      });

      test('with no way to ask, nothing is freed: both kept, rate summed', () async {
        final store = holding101();
        await pick(store);
        expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
        expect(store['t1'].doc!['monthlyRate'], 220);
      });

      test('freeing one of two units keeps the other in the rate', () async {
        final store = holding101();
        store['t1']
          ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}
          ..units = [
            unit('101', UnitStatus.occupied, 't1'),
            unit('103', UnitStatus.occupied, 't1', rate: 150),
          ];
        final notice = await pick(store, confirm: (_) async => true);
        // 250 - 100 (unit 101) + 120 (unit 102).
        expect(store['t1'].doc!['monthlyRate'], 270);
        expect(notice, r'Monthly rent is now $270.00 for units 103 and 102.');
      });

      test('switching to a unit they already hold and freeing the old one lowers the rent', () async {
        // The dialog says the freed unit's rent comes off theirs; it stayed
        // at 250 after unit 101 was freed.
        final store = holding101();
        store['t1']
          ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}
          ..units = [
            unit('101', UnitStatus.occupied, 't1'),
            unit('102', UnitStatus.occupied, 't1', rate: 150),
          ];
        store.facilityUnits
          ..removeWhere((u) => u.id == 'u102')
          ..add(unit('102', UnitStatus.occupied, 't1', rate: 150));
        final notice =
            await pick(store, monthlyRate: 250, confirm: (_) async => true);
        expect(store.writtenPaths, ['update units/u101', 'update tenants/t1']);
        expect(store['t1'].doc!['monthlyRate'], 150);
        expect(store['t1'].doc!['unitNumber'], '102');
        expect(notice, r'Monthly rent is now $150.00 for unit 102.');
      });

      test('a rate that is not the sum of their units is left alone, and the owner asked to check it', () async {
        // One rate for two units, from before the rule: adding or freeing
        // by arithmetic on it is a guess.
        final store = holding101();
        store['t1']
          ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100}
          ..units = [
            unit('101', UnitStatus.occupied, 't1'),
            unit('103', UnitStatus.occupied, 't1', rate: 150),
          ];
        final notice = await pick(store, confirm: (_) async => false);
        expect(store['t1'].doc!['monthlyRate'], 100);
        expect(notice,
            r"Check Ada Park's rent: they now hold units 101, 103 and 102; their rent is $100.00.");
      });

      test('a unit 101 given to someone else meanwhile is not freed', () async {
        final store = holding101();
        store.unitHolders['u101'] = 't2';
        await pick(store, confirm: (_) async => true);
        expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
      });
    });
  });

  group('Unassign Tenant takes the unit off its tenant too', () {
    setUp(() => UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner')));
    tearDown(() => UnitService.authForTesting = null);

    Future<String?> unassign(_FakeRecords store, String unitId) =>
        UnitService.removeTenantFromUnit(
            facilityId: 'f1', unitId: unitId, records: store);

    _FakeRecords holdingTwo() {
      final store = _FakeRecords();
      final u101 = unit('101', UnitStatus.occupied, 't1');
      final u102 = unit('102', UnitStatus.lockout, 't1', rate: 150);
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}
        ..units = [u101, u102]
        ..gateIds = ['g1'];
      store.facilityUnits.addAll([u101, u102]);
      store.unitHolders.addAll({'u101': 't1', 'u102': 't1'});
      return store;
    }

    test('its rate comes off theirs and their unit number moves to the unit they keep', () async {
      // It only freed the unit: the tenant kept '101' (so once 101 went to
      // someone else, saving either tenant failed) and kept paying for it.
      final store = holdingTwo();
      final notice = await unassign(store, 'u101');
      expect(store.writtenPaths, ['update units/u101', 'update tenants/t1']);
      final unitWrite = store.transactions.single.first.fields!;
      expect(unitWrite['status'], 'available');
      expect(unitWrite['updatedBy'], 'owner');
      final tenantWrite = store.transactions.single.last.fields!;
      expect(tenantWrite['monthlyRate'], 150);
      expect(tenantWrite['unitNumber'], '102');
      expect(tenantWrite.containsKey('isActive'), isFalse);
      expect(notice, r'Monthly rent is now $150.00 for unit 102.');
    });

    test('their last unit ends the tenancy as a move-out does: rate kept, switched off, gate codes off', () async {
      // It set the rate to 0 and left them active, holding nothing.
      final store = holdingTwo();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 60}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      expect(await unassign(store, 'u101'), isNull);
      expect(store.transactions, hasLength(1));
      expect(store.writtenPaths,
          ['update units/u101', 'update tenants/t1', 'update gateAccess/g1']);
      final tenantWrite = store.transactions.single[1].fields!;
      expect(tenantWrite['isActive'], isFalse);
      expect(tenantWrite['unitNumber'], '');
      expect(tenantWrite.containsKey('monthlyRate'), isFalse);
      expect(store.transactions.single.last.fields!['isActive'], isFalse);
      expect(store.transactions.single.last.fields!['updatedBy'], 'owner');
    });

    test('a unit number naming another unit is left alone', () async {
      final store = holdingTwo();
      await unassign(store, 'u102');
      final tenantWrite = store.transactions.single.last.fields!;
      expect(tenantWrite['monthlyRate'], 100);
      expect(tenantWrite.containsKey('unitNumber'), isFalse);
      expect(store.transactions.single.map((w) => '$w'),
          isNot(contains('update gateAccess/g1')));
    });

    test('one rate for two units (from before the rule) is never taken to 0: left, and flagged', () async {
      // 100 - 150 was clamped to 0 while they still held unit 101.
      final store = holdingTwo();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100};
      final notice = await unassign(store, 'u102');
      expect(store.writtenPaths, ['update units/u102']);
      expect(store['t1'].doc!['monthlyRate'], 100);
      expect(notice, isNull, reason: '100 is already unit 101 alone');

      final other = holdingTwo();
      other['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '102', 'monthlyRate': 100};
      expect(await unassign(other, 'u101'),
          r"Check Ada Park's rent: they now hold unit 102; their rent is $100.00.");
      expect(other['t1'].doc!['monthlyRate'], 100);
    });

    test('a unit that changed hands meanwhile is freed, and nobody else is touched', () async {
      final store = holdingTwo();
      store.unitHolders['u101'] = 't2';
      await unassign(store, 'u101');
      expect(store.writtenPaths, ['update units/u101']);
    });
  });

  group('Units > Assign Tenant gives the tenant the unit too', () {
    setUp(() => UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner')));
    tearDown(() => UnitService.authForTesting = null);

    Future<String?> assign(_FakeRecords store, String unitId,
            {_FakeEffects? effects, UnitStatus status = UnitStatus.occupied}) =>
        UnitService.assignTenantToUnit(
          facilityId: 'f1',
          unitId: unitId,
          tenantId: 't1',
          tenantName: 'Ada Park',
          status: status,
          records: store,
          effects: effects ?? _FakeEffects(),
        );

    _FakeRecords holding101() {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.available, null, rate: 150),
      ]);
      return store;
    }

    test("the unit's rate is added to theirs, in the same transaction as the link", () async {
      // It wrote the unit only: never billed, and freeing it later took 150
      // off a rent that never had it.
      final store = holding101();
      final effects = _FakeEffects();
      final notice = await assign(store, 'u102', effects: effects);
      expect(store.directWrites, isEmpty);
      expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
      final linked = store.transactions.single.first.fields!;
      expect(linked['status'], 'occupied');
      expect(linked['tenantId'], 't1');
      expect(linked['tenantName'], 'Ada Park');
      expect(linked['updatedBy'], 'owner');
      expect(store['t1'].doc!['monthlyRate'], 250);
      // Their unit number still names a unit they hold.
      expect(store['t1'].doc!['unitNumber'], '101');
      expect(notice, r'Monthly rent is now $250.00 for units 101 and 102.');
      expect(effects.audits.single['unitAssigned'], '102');
    });

    test('a first unit sets the unit number and, from 0, the rate', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '', 'monthlyRate': 0};
      store.facilityUnits.add(unit('102', UnitStatus.available, null, rate: 150));
      expect(await assign(store, 'u102'), r'Monthly rent is now $150.00 for unit 102.');
      expect(store['t1'].doc!['unitNumber'], '102');
      expect(store['t1'].doc!['monthlyRate'], 150);
    });

    test('a rate that is not the sum of their units is left alone and flagged', () async {
      final store = holding101();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 35};
      expect(await assign(store, 'u102'),
          r"Check Ada Park's rent: they now hold units 101 and 102; their rent is $35.00.");
      expect(store['t1'].doc!['monthlyRate'], 35);
    });

    test('an archived tenant given a unit is made active: rent skips inactive tenants', () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': false, 'unitNumber': '', 'monthlyRate': 0};
      store.facilityUnits.add(unit('102', UnitStatus.available, null, rate: 150));
      await assign(store, 'u102', status: UnitStatus.reserved);
      expect(store['t1'].doc!['isActive'], isTrue);
      expect(store.transactions.single.first.fields!['status'], 'reserved');
    });

    test("another tenant's unit is refused before anything is written", () async {
      final store = holding101();
      store.facilityUnits.add(unit('7', UnitStatus.occupied, 't2'));
      await expectLater(assign(store, 'u7'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
    });

    test('a unit taken meanwhile: neither the unit nor the tenant is written', () async {
      final store = holding101();
      store.unitHolders['u102'] = 't2';
      await expectLater(assign(store, 'u102'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
      expect(store['t1'].doc!['monthlyRate'], 100);
    });
  });

  group("the app's own Firestore store (TenantService.recordsFor)", () {
    // Every other test here hands in a fake store, so the store the app
    // uses when none is given was never run.
    late FakeFacilityFirestore db;

    setUp(() {
      db = FakeFacilityFirestore('f1', {
        'tenants': [
          FakeDoc('t1', {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 250}),
        ],
        'units': [
          FakeDoc('u101', {'unitNumber': '101', 'status': 'occupied', 'tenantId': 't1', 'monthlyRate': 100}),
          FakeDoc('u102', {'unitNumber': '102', 'status': 'lockout', 'tenantId': 't1', 'monthlyRate': 150}),
          FakeDoc('u103', {'unitNumber': '103', 'status': 'available', 'monthlyRate': 80}),
        ],
        'gateAccess': [
          FakeDoc('g1', {'tenantId': 't1', 'accessCode': '1234', 'isActive': true}),
        ],
      });
      TenantService.firestoreForTesting = db;
      UnitService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
    });
    tearDown(() {
      TenantService.firestoreForTesting = null;
      UnitService.authForTesting = null;
    });

    test('Unassign Tenant takes the unit and its rent off the tenant, in one transaction', () async {
      final notice = await UnitService.removeTenantFromUnit(facilityId: 'f1', unitId: 'u101');
      expect(db.commits, 1);
      expect(db.data('units', 'u101')!['status'], 'available');
      expect(db.data('units', 'u101')!['tenantId'], isA<FieldValue>());
      expect(db.data('tenants', 't1')!['monthlyRate'], 150);
      expect(db.data('tenants', 't1')!['unitNumber'], '102');
      expect(notice, r'Monthly rent is now $150.00 for unit 102.');

      // Their last unit: switched off, gate code off, rate kept.
      await UnitService.removeTenantFromUnit(facilityId: 'f1', unitId: 'u102');
      expect(db.data('tenants', 't1')!['isActive'], isFalse);
      expect(db.data('tenants', 't1')!['monthlyRate'], 150);
      expect(db.data('gateAccess', 'g1')!['isActive'], isFalse);
    });

    test('Assign Tenant adds the unit and its rent, in one transaction', () async {
      final notice = await UnitService.assignTenantToUnit(
        facilityId: 'f1',
        unitId: 'u103',
        tenantId: 't1',
        tenantName: 'Ada Park',
      );
      expect(db.commits, 1);
      expect(db.data('units', 'u103')!['tenantId'], 't1');
      expect(db.data('units', 'u103')!['status'], 'occupied');
      expect(db.data('tenants', 't1')!['monthlyRate'], 330);
      expect(notice, r'Monthly rent is now $330.00 for units 101, 102 and 103.');
    });

    test('unitsNumbered matches trimmed and ignoring case, live units before archived ones', () async {
      final units = db.sub('units');
      await units.doc('u104').set({'unitNumber': ' 104A', 'status': 'available'});
      // Archived as UnitService.archiveUnit writes it: switched off too.
      await units.doc('u105old').set({'unitNumber': '105', 'archived': true, 'isActive': false});
      await units.doc('u105').set({'unitNumber': '105', 'status': 'available'});
      await units.doc('u106').set({'unitNumber': '106', 'archived': true, 'isActive': false});
      // An archived flag with no isActive (older docs): found only when no
      // live unit has the number, as the exact query found it before.
      await units.doc('u108old').set({'unitNumber': '108', 'archived': true});
      await units.doc('u108').set({'unitNumber': '108', 'status': 'available'});
      await units.doc('u109').set({'unitNumber': '109', 'archived': true});
      final store = TenantService.recordsFor('f1');
      List<String> ids(List<UnitModel> units) => [for (final u in units) u.id];
      expect(ids(await store.unitsNumbered('104a')), ['u104']);
      expect(ids(await store.unitsNumbered('105')), ['u105']);
      expect(await store.unitsNumbered('106'), isEmpty);
      // An archived unit with the number no longer makes it ambiguous.
      expect(ids(await store.unitsNumbered('108')), ['u108']);
      expect(ids(await store.unitsNumbered('109')), ['u109']);
    });

    group('createTenant', () {
      setUp(() {
        TenantService.authForTesting =
            MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
        FacilitySubcollections.overrideForTesting((facilityId, name) => db.sub(name));
      });
      tearDown(() {
        TenantService.authForTesting = null;
        FacilitySubcollections.overrideForTesting(null);
      });

      Future<String> create(String unitNumber) => TenantService.createTenant(
            facilityId: 'f1',
            name: 'Bo Diaz',
            email: '',
            phone: '',
            unitNumber: unitNumber,
            monthlyRate: 60,
          );

      test("a number an archived unit keeps is refused before the tenant is saved", () async {
        // The unit was made after the tenant was saved, so the refusal said
        // "Nothing was saved" over a saved tenant, and a retry (or the CSV
        // import's next run) saved them twice.
        await db.sub('units').doc('u12').set(
            {'unitNumber': '12', 'archived': true, 'isActive': false, 'status': 'available'});
        final tenantsBefore = db.sub('tenants').stored.length;
        await expectLater(
          create('12'),
          throwsA(isA<DuplicateUnitNumberException>().having((e) => e.message, 'message',
              startsWith('Unit number 12 belongs to an archived unit. Nothing was saved.'))),
        );
        expect(db.sub('tenants').stored, hasLength(tenantsBefore));
        expect(db.sub('units').log.writes.map((w) => w.$2), ['u12']);
      });

      test('a number no unit has makes the unit and links it', () async {
        final id = await create('14');
        final made = db.sub('units').stored.where((d) => d.data()['unitNumber'] == '14').single;
        expect(made.data()['tenantId'], id);
        expect(db.data('tenants', id)!['unitNumber'], '14');
      });
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

    _FakeRecords holding101({double monthlyRate = 100}) {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': monthlyRate}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.occupied, 't1'),
        unit('102', UnitStatus.available, null, rate: 150),
      ]);
      return store;
    }

    test("the first unit is kept, and the new unit's rate is added to theirs", () async {
      // The rent job bills one monthlyRate per tenant. It was left at the
      // first unit's rate, so the second unit was never billed.
      final store = holding101();
      // 35 is the prorated first month; the unit's full rate (150) is added.
      final notice = await moveIn(store, '102', 35);
      expect(store['t1'].doc!['unitNumber'], '101');
      expect(store['t1'].doc!['monthlyRate'], 250);
      expect(store['t1'].doc!['isActive'], isTrue);
      expect(notice, r'Monthly rent is now $250.00 for units 101 and 102.');
    });

    test('the tenant and the unit link commit in one transaction', () async {
      // The raised rate was written first, then the link.
      final store = holding101();
      await moveIn(store, '102', 35);
      expect(store.directWrites, isEmpty);
      expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
    });

    test('a unit taken meanwhile: nothing is saved, so a retry adds its rate once', () async {
      // The error said "Nothing was saved" while the rate had gone 100 to
      // 250; the retry added 150 again.
      final store = holding101();
      store.unitHolders['u102'] = 't2';
      await expectLater(moveIn(store, '102', 35),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
      expect(store['t1'].doc!['monthlyRate'], 100);

      store.unitHolders['u102'] = null;
      await moveIn(store, '102', 35);
      expect(store['t1'].doc!['monthlyRate'], 250);
    });

    test('a rate that is not the sum of their units is left alone and flagged', () async {
      final store = holding101(monthlyRate: 35);
      expect(await moveIn(store, '102', 35),
          r"Check Ada Park's rent: they now hold units 101 and 102; their rent is $35.00.");
      expect(store['t1'].doc!['monthlyRate'], 35);
      // The unit is still theirs, and they are active.
      expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
    });

    test("a tenant's first unit becomes their unit number and rate, as before", () async {
      final store = _FakeRecords();
      store['t1'].doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '', 'monthlyRate': 0};
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      expect(await moveIn(store, '102', 80), isNull);
      expect(store.allWrites, ['update units/u102', 'update tenants/t1']);
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

    test('a stale link on an available unit is not a held unit either', () async {
      // Unit 101 still names them but is available (freed with a stale
      // link). Counted as held, the move-in added to the old rate.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 100}
        ..units = [unit('101', UnitStatus.available, 't1')];
      store.facilityUnits.addAll([
        unit('101', UnitStatus.available, 't1'),
        unit('102', UnitStatus.available, null),
      ]);
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
      expect(store.allWrites, ['update units/u102', 'update tenants/t1']);
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

  group('units linked by id, and unit numbers that more than one unit has', () {
    // Two units numbered 12 (Complex 2 and Complex 3). By number alone the
    // link took whichever came first.
    UnitModel unitAt(String id, String number, UnitStatus status, String? tenantId,
            {double rate = 100, String? area}) =>
        UnitModel(
          id: id,
          facilityId: 'f1',
          unitNumber: number,
          unitType: 'standard',
          status: status,
          tenantId: tenantId,
          monthlyRate: rate,
          createdAt: day,
          updatedAt: day,
          createdBy: 'owner',
          area: area,
        );

    _FakeRecords tenantWith({String label = '', List<UnitModel> held = const []}) {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': label, 'monthlyRate': 100}
        ..units = held;
      return store;
    }

    Future<String?> update(_FakeRecords store,
            {String? unitNumber, String? unitId, String? phone, bool? isActive, ConfirmFreeUnit? confirmFree}) =>
        TenantService.updateTenant(
          facilityId: 'f1',
          tenantId: 't1',
          unitNumber: unitNumber,
          unitId: unitId,
          phone: phone,
          isActive: isActive,
          confirmFreeOldUnit: confirmFree,
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );

    Future<String?> moveIn(_FakeRecords store, {required String unitNumber, String? unitId, double rate = 35}) =>
        TenantService.recordMoveInUnit(
          facilityId: 'f1',
          tenantId: 't1',
          unitNumber: unitNumber,
          unitId: unitId,
          monthlyRate: rate,
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );

    test('Edit Tenant: the unit picked from the list is the one linked', () async {
      final store = tenantWith();
      store.facilityUnits.addAll([
        unitAt('c2-12', '12', UnitStatus.available, null, area: 'Complex 2'),
        unitAt('c3-12', '12', UnitStatus.available, null, area: 'Complex 3'),
      ]);
      await update(store, unitNumber: '12', unitId: 'c3-12');
      expect(store.writtenPaths, ['update units/c3-12', 'update tenants/t1']);
      expect(store['t1'].doc!['unitNumber'], '12');
    });

    test('the number comes from the picked unit, not the typed field', () async {
      final store = tenantWith();
      store.facilityUnits.add(unitAt('c3-12', '12', UnitStatus.available, null));
      await update(store, unitNumber: 'stale text', unitId: 'c3-12');
      expect(store['t1'].doc!['unitNumber'], '12');
      expect(store.allWrites, ['update units/c3-12', 'update tenants/t1']);
    });

    test('by number alone, a number two units have is refused before anything is written', () async {
      final store = tenantWith();
      store.facilityUnits.addAll([
        unitAt('c2-12', '12', UnitStatus.available, null),
        unitAt('c3-12', '12', UnitStatus.available, null),
      ]);
      await expectLater(
        update(store, unitNumber: '12'),
        throwsA(isA<AmbiguousUnitNumberException>().having((e) => e.message, 'message',
            'More than one unit is numbered 12. Nothing was saved. Pick the unit from the list '
            "instead of typing its number: the list shows each unit's area.")),
      );
      expect(store.allWrites, isEmpty);
      // The screens show it as written, not as a generic error.
      expect(
          ErrorMessageHelper.getUserFriendlyMessage(
              const AmbiguousUnitNumberException(unitNumber: '12', count: 2)),
          startsWith('More than one unit is numbered 12.'));
    });

    test('by number, the one of them the tenant holds is theirs: saving other fields still works', () async {
      final c2 = unitAt('c2-12', '12', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12', held: [c2]);
      store.facilityUnits.addAll([c2, unitAt('c3-12', '12', UnitStatus.available, null)]);
      store.unitHolders['c2-12'] = 't1';
      await update(store, unitNumber: '12', phone: '555-0100');
      expect(store.allWrites, ['update tenants/t1']);
      expect(store['t1'].doc!['phone'], '555-0100');
    });

    test('by number, case and spaces do not matter: an existing unit is linked, not a second one made', () async {
      final store = tenantWith();
      store.facilityUnits.add(unitAt('u12A', '12A', UnitStatus.available, null));
      await update(store, unitNumber: ' 12a ');
      expect(store.allWrites, ['update units/u12A', 'update tenants/t1']);
      expect(store['t1'].doc!['unitNumber'], '12A');
    });

    test('by number, a unit spelled exactly as typed wins over one that differs only in case', () async {
      // Facilities may already have both: the duplicate check was exact.
      final store = tenantWith();
      store.facilityUnits.addAll([
        unitAt('u12a', '12a', UnitStatus.available, null),
        unitAt('u12A', '12A', UnitStatus.available, null),
      ]);
      await update(store, unitNumber: '12A');
      expect(store.writtenPaths, ['update units/u12A', 'update tenants/t1']);
    });

    test('a picked unit that is gone is refused before anything is written', () async {
      final store = tenantWith();
      await expectLater(update(store, unitNumber: '12', unitId: 'gone'),
          throwsA(isA<PickedUnitNotFoundException>()));
      expect(store.allWrites, isEmpty);
    });

    test('a picked unit in another facility is refused', () async {
      final store = tenantWith();
      store.facilityUnits.add(UnitModel(
        id: 'x12',
        facilityId: 'f2',
        unitNumber: '12',
        unitType: 'standard',
        status: UnitStatus.available,
        monthlyRate: 100,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
      ));
      await expectLater(update(store, unitNumber: '12', unitId: 'x12'),
          throwsA(isA<PickedUnitNotFoundException>()));
      expect(store.allWrites, isEmpty);
    });

    test('a picked unit another tenant holds is refused even when the number is unchanged', () async {
      // By number, an unchanged number someone else holds saves the rest
      // with a notice; a unit picked from the list is a choice, and refused.
      final store = tenantWith(label: '12');
      store.facilityUnits.add(unitAt('c3-12', '12', UnitStatus.occupied, 't2'));
      await expectLater(update(store, unitNumber: '12', unitId: 'c3-12'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
    });

    test('picking the other unit with the number they hold is a change of unit: the rent follows', () async {
      final c2 = unitAt('c2-12', '12', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12', held: [c2, unitAt('u7', '7', UnitStatus.occupied, 't1', rate: 50)]);
      store['t1'].doc!['monthlyRate'] = 150;
      store.facilityUnits.addAll([c2, unitAt('c3-12', '12', UnitStatus.available, null, rate: 80)]);
      store.unitHolders['c2-12'] = 't1';
      final notice = await update(store, unitNumber: '12', unitId: 'c3-12');
      // No one said to free Complex 2's 12, so both are kept and the new
      // one's rate is added to theirs.
      expect(store.writtenPaths, ['update units/c3-12', 'update tenants/t1']);
      expect(store['t1'].doc!['monthlyRate'], 230);
      expect(notice, contains(r'$230.00'));
    });

    test('move-in by id: a second unit numbered like the one they hold is linked and billed', () async {
      // The held-units filter compared numbers, so this read as already
      // theirs: nothing was linked and nothing billed.
      final c2 = unitAt('c2-12', '12', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12', held: [c2]);
      store.facilityUnits.addAll([c2, unitAt('c3-12', '12', UnitStatus.available, null, rate: 150)]);
      final notice = await moveIn(store, unitNumber: '12', unitId: 'c3-12');
      expect(store.writtenPaths, ['update units/c3-12', 'update tenants/t1']);
      expect(store['t1'].doc!['monthlyRate'], 250);
      expect(notice, contains(r'$250.00'));
    });

    test('move-in by id when they already hold another unit adds it, as by number', () async {
      final held = unitAt('u101', '101', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '101', held: [held]);
      store.facilityUnits.addAll([held, unitAt('u102', '102', UnitStatus.available, null, rate: 150)]);
      final notice = await moveIn(store, unitNumber: '102', unitId: 'u102');
      expect(store.writtenPaths, ['update units/u102', 'update tenants/t1']);
      expect(store['t1'].doc!['unitNumber'], '101');
      expect(notice, r'Monthly rent is now $250.00 for units 101 and 102.');
    });

    test('move-in by number into a number two units have is refused', () async {
      final held = unitAt('u101', '101', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '101', held: [held]);
      store.facilityUnits.addAll([
        held,
        unitAt('c2-12', '12', UnitStatus.available, null),
        unitAt('c3-12', '12', UnitStatus.available, null),
      ]);
      await expectLater(moveIn(store, unitNumber: '12'),
          throwsA(isA<AmbiguousUnitNumberException>()));
      expect(store.allWrites, isEmpty);
    });

    test("typing \"12A\" over \"12a\" names 12A: another tenant's 12A is refused, not saved with a notice", () async {
      // Compared ignoring case, the number read as unchanged, so the
      // refusal became "not linked" and the label moved to 12A anyway.
      final mine = unitAt('u12a', '12a', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12a', held: [mine]);
      store.facilityUnits.addAll([
        mine,
        unitAt('u12A', '12A', UnitStatus.occupied, 't2'),
      ]);
      await expectLater(update(store, unitNumber: '12A'),
          throwsA(isA<UnitHeldByAnotherTenantException>()));
      expect(store.allWrites, isEmpty);
      expect(store['t1'].doc!['unitNumber'], '12a');
    });

    test('typing "12A" over "12a" when 12A is free is a change of unit: asked, and the rent follows', () async {
      // It linked 12A with no question and no rent change: they held both
      // and were billed for one.
      final mine = unitAt('u12a', '12a', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12a', held: [mine]);
      store.facilityUnits.addAll([
        mine,
        unitAt('u12A', '12A', UnitStatus.available, null, rate: 80),
      ]);
      String? asked;
      final notice = await update(store, unitNumber: '12A', confirmFree: (n) async {
        asked = n;
        return false;
      });
      expect(asked, '12a');
      expect(store.writtenPaths, ['update units/u12A', 'update tenants/t1']);
      expect(store['t1'].doc!['monthlyRate'], 180);
      expect(store['t1'].doc!['unitNumber'], '12A');
      expect(notice, contains(r'$180.00'));
    });

    test('a case-only change of the number of the unit they hold changes nothing else', () async {
      final mine = unitAt('u12a', '12a', UnitStatus.occupied, 't1');
      final store = tenantWith(label: '12a', held: [mine]);
      store.facilityUnits.add(mine);
      store.unitHolders['u12a'] = 't1';
      String? asked;
      await update(store, unitNumber: '12A', confirmFree: (n) async {
        asked = n;
        return true;
      });
      expect(asked, isNull);
      expect(store.allWrites, ['update tenants/t1']);
      // The unit's own spelling.
      expect(store['t1'].doc!['unitNumber'], '12a');
    });

    test('an unchanged number several units have: other fields are saved, with a notice', () async {
      // Edit Tenant and the contact dialog always send the number, so a
      // phone change was refused for a tenant whose number two units have.
      final store = tenantWith(label: '12');
      store.facilityUnits.addAll([
        unitAt('c2-12', '12', UnitStatus.available, null),
        unitAt('c3-12', '12', UnitStatus.available, null),
      ]);
      final notice = await update(store, unitNumber: '12', phone: '555-0100');
      expect(store.allWrites, ['update tenants/t1']);
      expect(store['t1'].doc!['phone'], '555-0100');
      expect(notice,
          'More than one unit is numbered 12, so none was linked to Ada Park. Pick their unit from the list to link it.');
    });

    test('reactivating onto a number several units have is still refused', () async {
      final store = tenantWith(label: '12');
      store['t1'].doc!['isActive'] = false;
      store.facilityUnits.addAll([
        unitAt('c2-12', '12', UnitStatus.available, null),
        unitAt('c3-12', '12', UnitStatus.available, null),
      ]);
      await expectLater(update(store, unitNumber: '12', isActive: true),
          throwsA(isA<AmbiguousUnitNumberException>()));
      expect(store.allWrites, isEmpty);
    });

    test("the CSV import's row line says how to add a tenant whose number several units have", () {
      expect(
        TenantService.csvImportRowError(
            4, const AmbiguousUnitNumberException(unitNumber: '12', count: 2)),
        'Row 4: More than one unit is numbered 12, so this tenant was not imported. '
        "Put the unit's area in an Area column, or add them with Add Tenant and pick "
        'their unit from the list.',
      );
      // With areas, it names them.
      expect(
        TenantService.csvImportRowError(
            4,
            const AmbiguousUnitNumberException(
                unitNumber: '12', count: 2, areas: ['Complex 2', 'Complex 3'])),
        startsWith('Row 4: More than one unit is numbered 12 (in Complex 2, Complex 3), '
            'so this tenant was not imported.'),
      );
      expect(
        TenantService.csvImportRowError(5, const DuplicateUnitNumberException(
            unitNumber: '9', existingNumber: '9', archived: true)),
        startsWith('Row 5: Unit number 9 belongs to an archived unit.'),
      );
      expect(TenantService.csvImportRowError(6, Exception('x')), 'Row 6: Exception: x');
    });

    group('unitForNumber', () {
      UnitModel? pick(List<UnitModel> units, String number) =>
          TenantService.unitForNumber(units, number, tenantId: 't1');

      test('none, one, trimmed and ignoring case', () {
        final a = unitAt('a', '12A', UnitStatus.available, null);
        expect(pick([], '12'), isNull);
        expect(pick([a], '12'), isNull);
        expect(pick([a], ' 12a '), same(a));
        expect(pick([a], ''), isNull);
      });

      test("several: the tenant's, else refused", () {
        final a = unitAt('a', '12', UnitStatus.available, null);
        final b = unitAt('b', '12', UnitStatus.occupied, 't1');
        expect(pick([a, b], '12'), same(b));
        expect(() => pick([a, unitAt('c', '12', UnitStatus.available, null)], '12'),
            throwsA(isA<AmbiguousUnitNumberException>().having((e) => e.count, 'count', 2)));
      });
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
        // The unit moved out of, already freed; 150 a month.
        unit('102', UnitStatus.available, null, rate: 150),
      ]);
      expect(await settle(store), r'Monthly rent is now $100.00 for unit 101.');
      final fields = store.directWrites.single.fields!;
      expect(fields['monthlyRate'], 100);
      expect(fields['unitNumber'], '101');
      expect(store['t1'].doc!['isActive'], isTrue);
    });

    test('one rate for two units (from before the rule) is never taken to 0: left, and flagged', () async {
      // 60 - 100 was clamped to 0 while they still held unit 101.
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 60}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.add(unit('102', UnitStatus.available, null));
      expect(await settle(store),
          r"Check Ada Park's rent: they now hold unit 101; their rent is $60.00.");
      expect(store.allWrites, isEmpty);
      expect(store['t1'].doc!['monthlyRate'], 60);
      expect(store['t1'].doc!['unitNumber'], '101');
    });

    test('a unit someone else holds takes nothing off their rate', () async {
      final store = _FakeRecords();
      store['t1']
        ..doc = {'name': 'Ada Park', 'isActive': true, 'unitNumber': '101', 'monthlyRate': 200}
        ..units = [unit('101', UnitStatus.occupied, 't1')];
      store.facilityUnits.add(unit('102', UnitStatus.occupied, 't2'));
      expect(await settle(store), isNull);
      expect(store.allWrites, isEmpty);
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

  group("processMoveOut's answer, for the move-out screen", () {
    final calculation = MoveOutCalculation(
      lineItems: const [],
      currentBalance: 0,
      newCharges: 40,
      finalBalance: 40,
      refundAmount: 0,
    );

    test("the tenant's new rent, or a request to check it, is shown", () {
      final done = MoveOutService.moveOutResultFromServer({
        'success': true,
        'rentNotice': r'Monthly rent is now $150.00 for unit 102.',
        'rentWarning': null,
      }, calculation);
      expect(done.success, isTrue);
      expect(done.charges, 40);
      expect(done.notice, r'Monthly rent is now $150.00 for unit 102.');
      expect(done.warning, isNull);

      final check = MoveOutService.moveOutResultFromServer({
        'success': true,
        'rentNotice': null,
        'rentWarning': r"Check Ada Park's rent: they now hold unit 102; their rent is $100.00.",
      }, calculation);
      expect(check.warning, startsWith("Check Ada Park's rent"));
    });

    test('a retry of a finished move-out says so, and shows no charges as posted again', () {
      final again = MoveOutService.moveOutResultFromServer({
        'success': true,
        'alreadyCompleted': true,
        'message': 'This move-out was already completed, so nothing was charged or changed again.',
      }, calculation);
      expect(again.success, isTrue);
      expect(again.charges, isNull);
      expect(again.refund, isNull);
      expect(again.warning, contains('already completed'));
    });
  });

  group('rentAfterUnitChange', () {
    test('matches the shared table processMoveOut runs, word for word', () {
      final fixture = jsonDecode(File(
              'functions-tenant-lifecycle/src/test/fixtures/rentAfterUnitChange.json')
          .readAsStringSync()) as Map<String, dynamic>;
      List<UnitRent> units(Object? rows) => [
            for (final row in rows as List)
              (
                unitNumber: (row as List)[0] as String,
                rate: (row[1] as num).toDouble(),
              ),
          ];
      final cases = fixture['cases'] as List;
      expect(cases.length, greaterThan(5));
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final change = TenantService.rentAfterUnitChange(
          tenantName: 'Ada Park',
          current: (c['current'] as num).toDouble(),
          heldBefore: units(c['heldBefore']),
          released: units(c['released']),
          added: c['added'] == null ? null : units([c['added']]).single,
        );
        expect(change.monthlyRate, (c['monthlyRate'] as num?)?.toDouble(),
            reason: c['name'] as String);
        expect(change.notice, c['notice'], reason: c['name'] as String);
      }
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

  group("the tenant's primary unit by id (unitId, unitArea)", () {
    // Every write of tenant.unitNumber also names the unit by id and copies
    // its area, or deletes both when the number is cleared, so unit numbers
    // can later repeat across areas.
    final deleted = FieldValue.delete();

    UnitModel unitAt(String id, String number, UnitStatus status, String? tenantId,
            {double rate = 100, String? area}) =>
        UnitModel(
          id: id,
          facilityId: 'f1',
          unitNumber: number,
          unitType: 'standard',
          status: status,
          tenantId: tenantId,
          monthlyRate: rate,
          createdAt: day,
          updatedAt: day,
          createdBy: 'owner',
          area: area,
        );

    _FakeRecords tenantWith({
      String label = '',
      List<UnitModel> held = const [],
      double rate = 100,
      bool isActive = true,
      Map<String, dynamic> extra = const {},
    }) {
      final store = _FakeRecords();
      store['t1']
        ..doc = {
          'name': 'Ada Park',
          'isActive': isActive,
          'unitNumber': label,
          'monthlyRate': rate,
          ...extra,
        }
        ..units = held;
      for (final u in held) {
        store.unitHolders[u.id] = u.tenantId;
      }
      return store;
    }

    Future<String?> update(_FakeRecords store,
            {String? unitNumber, String? unitId, String? phone, bool? isActive}) =>
        TenantService.updateTenant(
          facilityId: 'f1',
          tenantId: 't1',
          unitNumber: unitNumber,
          unitId: unitId,
          phone: phone,
          isActive: isActive,
          records: store,
          effects: _FakeEffects(),
          actingUid: 'owner',
        );

    Map<String, dynamic> tenantDoc(_FakeRecords store) => store['t1'].doc!;

    group('Edit Tenant (updateTenant)', () {
      test('a unit picked from the list is their unitId, and its area their unitArea', () async {
        final store = tenantWith();
        store.facilityUnits.addAll([
          unitAt('c2-12', 'C2-12', UnitStatus.available, null, area: 'Complex 2'),
          unitAt('c3-14', 'C3-14', UnitStatus.available, null, area: ' Complex 3 '),
        ]);
        await update(store, unitNumber: 'C3-14', unitId: 'c3-14');
        expect(tenantDoc(store)['unitNumber'], 'C3-14');
        expect(tenantDoc(store)['unitId'], 'c3-14');
        expect(tenantDoc(store)['unitArea'], 'Complex 3');
      });

      test('a unit found by number is linked by id too; a unit with no area deletes unitArea', () async {
        final store = tenantWith(extra: {'unitArea': 'Old area'});
        store.facilityUnits.add(unitAt('u14', '14', UnitStatus.available, null));
        await update(store, unitNumber: '14');
        expect(tenantDoc(store)['unitId'], 'u14');
        expect(tenantDoc(store)['unitArea'], deleted);
      });

      test('a number no unit has: the unit made for it is their unitId', () async {
        final store = tenantWith();
        await update(store, unitNumber: '14');
        expect(store.directWrites.map((w) => '$w'), ['create units/new-14']);
        expect(tenantDoc(store)['unitNumber'], '14');
        expect(tenantDoc(store)['unitId'], 'new-14');
        expect(tenantDoc(store)['unitArea'], deleted);
      });

      test('an edit of other fields writes the unitId of the unit they hold (a tenant from before it was kept)', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1', area: 'Complex 2');
        final store = tenantWith(label: '12', held: [u12]);
        store.facilityUnits.add(u12);
        await update(store, unitNumber: '12', phone: '555-0100');
        expect(store.allWrites, ['update tenants/t1']);
        expect(tenantDoc(store)['unitId'], 'u12');
        expect(tenantDoc(store)['unitArea'], 'Complex 2');
      });

      test('clearing the unit number deletes unitId and unitArea', () async {
        final store = tenantWith(label: '12', extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        await update(store, unitNumber: '');
        final fields = store.directWrites.single.fields!;
        expect(fields['unitNumber'], '');
        expect(fields['unitId'], deleted);
        expect(fields['unitArea'], deleted);
      });

      test("an inactive tenant's new number names no unit by id: the old unitId goes", () async {
        final store = tenantWith(
            label: '12', isActive: false, extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        await update(store, unitNumber: '14');
        final fields = store.directWrites.single.fields!;
        expect(fields['unitNumber'], '14');
        expect(fields['unitId'], deleted);
        expect(fields['unitArea'], deleted);
      });

      test("an inactive tenant's unchanged number keeps its unitId", () async {
        final store = tenantWith(
            label: '12', isActive: false, extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        await update(store, unitNumber: '12', phone: '555-0100');
        final fields = store.directWrites.single.fields!;
        expect(fields.containsKey('unitId'), isFalse);
        expect(fields.containsKey('unitArea'), isFalse);
      });

      test('no unit number in the call leaves unitId alone', () async {
        final store = tenantWith(label: '12', extra: {'unitId': 'u12'});
        await update(store, phone: '555-0100');
        final fields = store.directWrites.single.fields!;
        expect(fields.containsKey('unitId'), isFalse);
        expect(fields.containsKey('unitArea'), isFalse);
      });

      test('switching off with the unit number cleared deletes them with it', () async {
        final store = tenantWith(label: '', extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        await update(store, unitNumber: '', isActive: false);
        final fields = store.transactions.single.first.fields!;
        expect(fields['isActive'], isFalse);
        expect(fields['unitId'], deleted);
        expect(fields['unitArea'], deleted);
      });

      test('a changed unit that keeps the old one: the new unit is the primary one', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1', area: 'Complex 2');
        final store = tenantWith(label: '12', held: [u12], extra: {'unitId': 'u12'});
        store.facilityUnits.addAll([u12, unitAt('u14', '14', UnitStatus.available, null, area: 'Complex 3')]);
        await update(store, unitNumber: '14');
        expect(store.writtenPaths, ['update units/u14', 'update tenants/t1']);
        final fields = store.transactions.single.last.fields!;
        expect(fields['unitNumber'], '14');
        expect(fields['unitId'], 'u14');
        expect(fields['unitArea'], 'Complex 3');
      });
    });

    group('move-in (recordMoveInUnit)', () {
      Future<String?> moveIn(_FakeRecords store, {required String unitNumber, String? unitId}) =>
          TenantService.recordMoveInUnit(
            facilityId: 'f1',
            tenantId: 't1',
            unitNumber: unitNumber,
            unitId: unitId,
            monthlyRate: 35,
            records: store,
            effects: _FakeEffects(),
            actingUid: 'owner',
          );

      test('a first unit is their unitId and unitArea', () async {
        final store = tenantWith(isActive: false, rate: 0);
        store.facilityUnits.add(unitAt('c3-14', '14', UnitStatus.available, null, area: 'Complex 3'));
        await moveIn(store, unitNumber: '14', unitId: 'c3-14');
        expect(tenantDoc(store)['unitNumber'], '14');
        expect(tenantDoc(store)['unitId'], 'c3-14');
        expect(tenantDoc(store)['unitArea'], 'Complex 3');
      });

      test('another unit leaves unitId on the unit their label names', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1', area: 'Complex 2');
        final store = tenantWith(label: '12', held: [u12], extra: {'unitId': 'u12'});
        store.facilityUnits.addAll([u12, unitAt('u14', '14', UnitStatus.available, null, area: 'Complex 3')]);
        await moveIn(store, unitNumber: '14', unitId: 'u14');
        final fields = store.transactions.single.last.fields!;
        expect(fields.containsKey('unitNumber'), isFalse);
        expect(fields.containsKey('unitId'), isFalse);
        expect(tenantDoc(store)['unitId'], 'u12');
      });

      test('another unit, when the label names none they hold: the label and unitId move to it', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1');
        final store = tenantWith(label: 'stale', held: [u12]);
        store.facilityUnits.addAll([u12, unitAt('u14', '14', UnitStatus.available, null, area: 'Complex 3')]);
        await moveIn(store, unitNumber: '14', unitId: 'u14');
        expect(tenantDoc(store)['unitNumber'], '14');
        expect(tenantDoc(store)['unitId'], 'u14');
        expect(tenantDoc(store)['unitArea'], 'Complex 3');
      });

      test('another unit made for its number: its new id', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1');
        final store = tenantWith(label: '', held: [u12]);
        store.facilityUnits.add(u12);
        await moveIn(store, unitNumber: '14');
        expect(tenantDoc(store)['unitNumber'], '14');
        expect(tenantDoc(store)['unitId'], 'new-14');
        expect(tenantDoc(store)['unitArea'], deleted);
      });
    });

    group('Units > Assign Tenant (assignUnit)', () {
      Future<String?> assign(_FakeRecords store, String unitId) => TenantService.assignUnit(
            store,
            facilityId: 'f1',
            unitId: unitId,
            tenantId: 't1',
            uid: 'owner',
            effects: _FakeEffects(),
          );

      test('a first unit sets unitNumber, unitId and unitArea together', () async {
        final store = tenantWith(rate: 0);
        store.facilityUnits.add(unitAt('c3-14', '14', UnitStatus.available, null, area: 'Complex 3'));
        await assign(store, 'c3-14');
        final fields = store.transactions.single.last.fields!;
        expect(fields['unitNumber'], '14');
        expect(fields['unitId'], 'c3-14');
        expect(fields['unitArea'], 'Complex 3');
      });

      test('a second unit leaves their unitId alone', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1');
        final store = tenantWith(label: '12', held: [u12], extra: {'unitId': 'u12'});
        store.facilityUnits.addAll([u12, unitAt('u14', '14', UnitStatus.available, null)]);
        await assign(store, 'u14');
        final fields = store.transactions.single.last.fields!;
        expect(fields.containsKey('unitNumber'), isFalse);
        expect(fields.containsKey('unitId'), isFalse);
      });
    });

    group('Unassign Tenant (unassignUnit)', () {
      Future<String?> unassign(_FakeRecords store, String unitId) =>
          TenantService.unassignUnit(store, unitId: unitId, uid: 'owner');

      _FakeRecords holdingTwo() {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1', area: 'Complex 2');
        final u14 = unitAt('u14', '14', UnitStatus.occupied, 't1', rate: 150, area: 'Complex 3');
        final store = tenantWith(label: '12', held: [u12, u14], rate: 250,
            extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        store.facilityUnits.addAll([u12, u14]);
        return store;
      }

      test('the label moves to the unit they keep, and unitId and unitArea with it', () async {
        final store = holdingTwo();
        await unassign(store, 'u12');
        final fields = store.transactions.single.last.fields!;
        expect(fields['unitNumber'], '14');
        expect(fields['unitId'], 'u14');
        expect(fields['unitArea'], 'Complex 3');
      });

      test('another unit freed leaves unitId alone', () async {
        final store = holdingTwo();
        await unassign(store, 'u14');
        final fields = store.transactions.single.last.fields!;
        expect(fields.containsKey('unitId'), isFalse);
        expect(fields.containsKey('unitArea'), isFalse);
      });

      test('their last unit clears unitNumber, unitId and unitArea', () async {
        final u12 = unitAt('u12', '12', UnitStatus.occupied, 't1', area: 'Complex 2');
        final store = tenantWith(label: '12', held: [u12], extra: {'unitId': 'u12'});
        store.facilityUnits.add(u12);
        await unassign(store, 'u12');
        final fields = store.transactions.single[1].fields!;
        expect(fields['unitNumber'], '');
        expect(fields['unitId'], deleted);
        expect(fields['unitArea'], deleted);
      });
    });

    group('move-out (recordMoveOut)', () {
      Future<String?> settle(_FakeRecords store, String unitId) => TenantService.recordMoveOut(
            facilityId: 'f1',
            tenantId: 't1',
            movedOutUnitId: unitId,
            records: store,
            effects: _FakeEffects(),
            actingUid: 'owner',
          );

      test('the label moves to the unit they keep, linked by id', () async {
        final u14 = unitAt('u14', '14', UnitStatus.occupied, 't1', area: 'Complex 3');
        final store = tenantWith(label: '12', held: [u14], extra: {'unitId': 'u12'});
        store.facilityUnits.addAll([u14, unitAt('u12', '12', UnitStatus.available, null)]);
        await settle(store, 'u12');
        expect(tenantDoc(store)['unitNumber'], '14');
        expect(tenantDoc(store)['unitId'], 'u14');
        expect(tenantDoc(store)['unitArea'], 'Complex 3');
      });

      test('their last unit deletes unitId and unitArea', () async {
        final store = tenantWith(label: '12', extra: {'unitId': 'u12', 'unitArea': 'Complex 2'});
        await settle(store, 'u12');
        final fields = store.transactions.single.first.fields!;
        expect(fields['unitNumber'], '');
        expect(fields['isActive'], isFalse);
        expect(fields['unitId'], deleted);
        expect(fields['unitArea'], deleted);
      });
    });

    group('createTenant', () {
      late FakeFacilityFirestore db;

      setUp(() {
        db = FakeFacilityFirestore('f1', {
          'tenants': <FakeDoc>[],
          'units': [
            FakeDoc('c3-14', {'unitNumber': '14', 'status': 'available', 'monthlyRate': 80, 'area': 'Complex 3'}),
            FakeDoc('u15', {'unitNumber': '15', 'status': 'available', 'monthlyRate': 80}),
          ],
        });
        TenantService.firestoreForTesting = db;
        TenantService.authForTesting =
            MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
        UnitService.authForTesting =
            MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
        FacilitySubcollections.overrideForTesting((facilityId, name) => db.sub(name));
      });
      tearDown(() {
        TenantService.firestoreForTesting = null;
        TenantService.authForTesting = null;
        UnitService.authForTesting = null;
        FacilitySubcollections.overrideForTesting(null);
      });

      Future<String> create(String unitNumber, {String? unitId}) => TenantService.createTenant(
            facilityId: 'f1',
            name: 'Bo Diaz',
            email: '',
            phone: '',
            unitNumber: unitNumber,
            unitId: unitId,
            monthlyRate: 80,
          );

      test('a picked unit is saved with the tenant as unitId and unitArea', () async {
        final id = await create('', unitId: 'c3-14');
        final saved = db.sub('tenants').log.writes.firstWhere((w) => w.$2 == id);
        expect(saved.$1, 'set');
        expect(saved.$3['unitNumber'], '14');
        expect(saved.$3['unitId'], 'c3-14');
        expect(saved.$3['unitArea'], 'Complex 3');
      });

      test('a unit found by number with no area: unitId only (a set has nothing to delete)', () async {
        final id = await create('15');
        final saved = db.sub('tenants').log.writes.firstWhere((w) => w.$2 == id);
        expect(saved.$3['unitId'], 'u15');
        expect(saved.$3.containsKey('unitArea'), isFalse);
      });

      test('a unit made for the number is their unitId once it exists', () async {
        final id = await create('16');
        final made = db.sub('units').stored.where((d) => d.data()['unitNumber'] == '16').single;
        expect(db.data('tenants', id)!['unitId'], made.id);
        expect(db.data('tenants', id)!['unitNumber'], '16');
      });

      test('no unit number: no unitId', () async {
        final id = await create('');
        expect(db.data('tenants', id)!.containsKey('unitId'), isFalse);
      });
    });
  });

  group('a tenant holding two units with the same number keeps the primary one', () {
    // Not possible while unit numbers are unique per facility, but what
    // later phases allow: "12" in Complex 2 (c2-12) and in Complex 3
    // (c3-12), both held by t1. Their unitId says which is the primary one.
    final deleted = FieldValue.delete();

    UnitModel unitAt(String id, String number, {String? area, double rate = 100}) => UnitModel(
          id: id,
          facilityId: 'f1',
          unitNumber: number,
          unitType: 'standard',
          status: UnitStatus.occupied,
          tenantId: 't1',
          monthlyRate: rate,
          createdAt: day,
          updatedAt: day,
          createdBy: 'owner',
          area: area,
        );

    final c2 = unitAt('c2-12', '12', area: 'Complex 2');
    final c3 = unitAt('c3-12', '12', area: 'Complex 3', rate: 150);
    final u14 = unitAt('u14', '14', area: 'Outdoor', rate: 50);

    _FakeRecords holding(List<UnitModel> held, {required String primary, double rate = 250}) {
      final store = _FakeRecords();
      store['t1']
        ..doc = {
          'name': 'Ada Park',
          'isActive': true,
          'unitNumber': '12',
          'unitId': primary,
          'monthlyRate': rate,
        }
        ..units = held;
      store.facilityUnits.addAll(held);
      for (final u in held) {
        store.unitHolders[u.id] = 't1';
      }
      return store;
    }

    test('saving other fields keeps unitId on their primary unit, not the first match', () async {
      // unitForNumber took the first held unit numbered 12, so a phone
      // change flipped unitId to c2-12.
      final store = holding([c2, c3], primary: 'c3-12');
      await TenantService.updateTenant(
        facilityId: 'f1',
        tenantId: 't1',
        unitNumber: '12',
        phone: '555-0100',
        records: store,
        effects: _FakeEffects(),
        actingUid: 'owner',
      );
      expect(store.allWrites, ['update tenants/t1']);
      expect(store['t1'].doc!['unitId'], 'c3-12');
      expect(store['t1'].doc!['unitArea'], 'Complex 3');
    });

    test('unitForNumber: their primary unit first among the ones they hold', () {
      expect(
          TenantService.unitForNumber([c2, c3], '12', tenantId: 't1', currentUnitId: 'c3-12')?.id,
          'c3-12');
      expect(TenantService.unitForNumber([c2, c3], '12', tenantId: 't1')?.id, 'c2-12');
      // A unitId they don't hold is no reason to pick it.
      final other = UnitModel.fromFirestore(FakeDoc('x-12', {'unitNumber': '12', 'tenantId': 't2', 'status': 'occupied'}));
      expect(
          TenantService.unitForNumber([c2, other], '12', tenantId: 't1', currentUnitId: 'x-12')?.id,
          'c2-12');
    });

    group('move-out (recordMoveOut)', () {
      Future<String?> settle(_FakeRecords store, String unitId) => TenantService.recordMoveOut(
            facilityId: 'f1',
            tenantId: 't1',
            movedOutUnitId: unitId,
            records: store,
            effects: _FakeEffects(),
            actingUid: 'owner',
          );

      test('leaving their primary unit moves unitId and unitArea to the kept unit numbered alike', () async {
        // The label still named a kept unit ("12"), so nothing was written
        // and unitId stayed on the freed unit; processMoveOut moved it.
        final store = holding([u14, c3], primary: 'c2-12');
        store.facilityUnits.add(c2);
        await settle(store, 'c2-12');
        expect(store['t1'].doc!['unitNumber'], '12');
        expect(store['t1'].doc!['unitId'], 'c3-12');
        expect(store['t1'].doc!['unitArea'], 'Complex 3');
      });

      test('leaving the other unit numbered alike leaves the primary alone', () async {
        final store = holding([u14, c3], primary: 'c3-12', rate: 35);
        store.facilityUnits.add(c2);
        await settle(store, 'c2-12');
        expect(store['t1'].doc!['unitId'], 'c3-12');
        for (final w in store.directWrites) {
          expect(w.fields!.containsKey('unitId'), isFalse);
          expect(w.fields!.containsKey('unitNumber'), isFalse);
        }
      });
    });

    group('Unassign Tenant (unassignUnit)', () {
      Future<String?> unassign(_FakeRecords store, String unitId) =>
          TenantService.unassignUnit(store, unitId: unitId, uid: 'owner');

      test('freeing the other unit numbered alike leaves the primary alone', () async {
        // The label named the freed unit's number, so it moved to
        // others.first (unit 14) and took unitId with it.
        final store = holding([c2, u14, c3], primary: 'c3-12', rate: 300);
        await unassign(store, 'c2-12');
        final fields = store.transactions.single.last.fields!;
        expect(fields.containsKey('unitNumber'), isFalse);
        expect(fields.containsKey('unitId'), isFalse);
        expect(fields.containsKey('unitArea'), isFalse);
      });

      test('freeing the primary moves it to the kept unit numbered alike before any other', () async {
        final store = holding([c2, u14, c3], primary: 'c2-12', rate: 300);
        await unassign(store, 'c2-12');
        final fields = store.transactions.single.last.fields!;
        expect(fields['unitNumber'], '12');
        expect(fields['unitId'], 'c3-12');
        expect(fields['unitArea'], 'Complex 3');
      });

      test('freeing a unit that is not the primary, with a different number, changes nothing', () async {
        final store = holding([c2, u14], primary: 'c2-12', rate: 150);
        await unassign(store, 'u14');
        final fields = store.transactions.single.last.fields!;
        expect(fields.containsKey('unitId'), isFalse);
        expect(fields['unitArea'], isNot(deleted));
      });
    });
  });

  test('primaryMovesOnRelease and primaryUnitAfterRelease match the table processMoveOut runs', () {
    final fixture = jsonDecode(File(
            'functions-tenant-lifecycle/src/test/fixtures/primaryUnitAfterRelease.json')
        .readAsStringSync()) as Map<String, dynamic>;
    final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThan(5));
    for (final c in cases) {
      final stillHeld = [
        for (final row in (c['stillHeld'] as List).cast<List<dynamic>>())
          UnitModel(
            id: row[0] as String,
            facilityId: 'f1',
            unitNumber: row[1] as String,
            unitType: 'standard',
            status: UnitStatus.occupied,
            tenantId: 't1',
            monthlyRate: 100,
            createdAt: day,
            updatedAt: day,
            createdBy: 'owner',
          ),
      ];
      final vacated = (c['vacated'] as List).cast<String>();
      final moves = TenantService.primaryMovesOnRelease(
        label: c['label'] as String,
        unitId: c['unitId'] as String?,
        vacatedId: vacated[0],
        vacatedNumber: vacated[1],
        stillHeld: stillHeld,
      );
      final name = c['name'] as String;
      expect(moves, c['moves'], reason: name);
      final to = moves
          ? TenantService.primaryUnitAfterRelease(
              label: c['label'] as String,
              unitId: c['unitId'] as String?,
              stillHeld: stillHeld,
            )
          : null;
      expect(to?.id, c['to'], reason: name);
    }
  });
}
