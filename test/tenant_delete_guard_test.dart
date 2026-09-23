import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/unit_detail_screen.dart';
import 'package:sfcapp/services/tenant_service.dart';

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
  Future<List<String>> activeGateAccessIds(String tenantId) =>
      _read('gateAccess', () => this[tenantId].gateIds);

  @override
  Future<void> transaction(
      Future<void> Function(TenantRecordsTransaction txn) body) async {
    final txn = _FakeTransaction(unitHolders);
    await body(txn);
    transactions.add(txn.writes);
  }

  List<String> get writtenPaths =>
      [for (final t in transactions) ...t.map((w) => '$w')];
}

class _FakeTransaction implements TenantRecordsTransaction {
  _FakeTransaction(this.holders);

  final Map<String, String?> holders;
  final writes = <_Write>[];

  @override
  Future<String?> unitTenantId(String unitId) async {
    // Firestore refuses a read after a write in the same transaction.
    if (writes.isNotEmpty) throw StateError('read after write');
    return holders[unitId];
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

    test('a tenant who holds a unit is blocked even with no history', () async {
      final store = _FakeRecords();
      store['t1'].units = [
        unit('101', UnitStatus.occupied, 't1'),
        // A stale link on an available unit is unlinked, not held.
        unit('103', UnitStatus.available, 't1'),
      ];
      final p = await TenantService.loadDeletePlan(store, 't1');
      expect(p.blockers, isEmpty);
      expect(p.heldUnits, [const HeldUnit('101', UnitStatus.occupied)]);
      expect(p.isBlocked, isTrue);
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

    Future<({int unitsUnlinked, int gateCodesOff})> run(
      _FakeRecords store,
      List<String> ids, {
      Object? answer = deletedNothing,
      List<List<String>>? calls,
    }) {
      return TenantService.permanentlyDelete(
        store,
        ids,
        deleteOnServer: (sent) async {
          calls?.add(sent);
          return answer;
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

    test('an occupant with no history is told to unassign the unit first', () async {
      final store = _FakeRecords();
      store['t1'].units = [unit('101', UnitStatus.occupied, 't1')];
      final calls = <List<String>>[];
      final error = await run(store, ['t1'], calls: calls)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<TenantDeleteRefusedException>());
      final refusal = error! as TenantDeleteRefusedException;
      expect(refusal.blocked.single.canArchiveInstead, isFalse);
      expect(refusal.message, 'Nothing was deleted. Ada Park is still assigned to unit 101.');
      expect(refusal.details,
          contains('Unassign the unit first (Units > unit 101 > Unassign Tenant). Then you can delete them.'));
      expect(calls, isEmpty);
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
      expect(result.unitsUnlinked, 1);
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
        expect(TenantService.hasAutopaySubscription(billing), c['has'], reason: '$billing');
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

    test('plans give the same reasons and held units as the server', () async {
      expect(parity['scanLimit'], 10, reason: 'TenantService._deleteCheckScanLimit');
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
      }
    });
  });

  group('runPermanentDelete', () {
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

    test('freeing by number only touches a unit linked to this tenant', () {
      expect(TenantService.isUnitLinkedTo('t1', {'tenantId': 't1'}), isTrue);
      // A stale tenant.unitNumber pointing at someone else's unit.
      expect(TenantService.isUnitLinkedTo('t1', {'tenantId': 't2'}), isFalse);
      expect(TenantService.isUnitLinkedTo('t1', {'tenantId': null}), isFalse);
      expect(TenantService.isUnitLinkedTo('t1', null), isFalse);
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
          heldUnits: [HeldUnit('7', UnitStatus.lockout)],
        ),
      ]);
      expect(refusal.details, contains('• Ada Park: has an invoice.'));
      expect(
          refusal.details,
          contains('• Bo Diaz: is still assigned to unit 7. Unassign the unit first '
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
