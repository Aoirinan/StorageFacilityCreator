import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/security_deposit_service.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

// A made-up tenant ("Pat Example", Unit 12) whose $25 move-in deposit the
// facility holds. Settling it is the only time the deposit touches the
// ledger, and only by the part applied to the balance.

final _received = SecurityDeposit.noonUtc(DateTime(2026, 9, 1));

SecurityDeposit _held() => SecurityDeposit(
      amount: 25,
      receivedDate: _received,
      method: PaymentMethod.check,
      reference: '1234',
      recordedAt: DateTime.utc(2026, 9, 1, 15),
      recordedBy: 'owner-1',
    );

SecurityDeposit _settled() => _held().copyWith(
      status: SecurityDepositStatus.settled,
      settledAt: DateTime.utc(2026, 10, 3, 12),
      settledBy: 'owner-1',
      appliedAmount: 25,
      refundedAmount: 0,
      appliedLedgerEntryId: 'ledger-old',
    );

Map<String, dynamic> _tenantDoc({SecurityDeposit? deposit}) => {
      'facilityId': 'f1',
      'name': 'Pat Example',
      'unitNumber': '12',
      'monthlyRate': 80.0,
      'isActive': true,
      if (deposit != null) 'securityDeposit': deposit.toMap(),
    };

void main() {
  group('planDepositSettlement', () {
    final now = DateTime.utc(2026, 10, 3, 12);

    DepositSettlementPlan plan(double applied, double refunded,
            {SecurityDeposit? deposit}) =>
        planDepositSettlement(
          deposit: deposit ?? _held(),
          appliedAmount: applied,
          refundedAmount: refunded,
          refundMethod: PaymentMethod.cash,
          refundReference: 'refund-1',
          tenantId: 't1',
          facilityId: 'f1',
          uid: 'owner-1',
          now: now,
          ledgerEntryId: 'ledger-1',
        );

    test('applying it all posts one negative credit and no refund', () {
      final p = plan(25, 0);
      final row = p.ledgerEntry!;
      expect(row['type'], 'credit');
      expect(row['amount'], -25.0);
      expect(row['description'], 'Security deposit applied');
      expect(row['status'], 'posted');
      expect(row['createdBy'], 'owner-1');
      expect(row['tenantId'], 't1');
      expect(row['facilityId'], 'f1');
      // The shape the ledgers rules require of a client create.
      expect(row.keys, containsAll(['tenantId', 'facilityId', 'type', 'amount', 'entryDate', 'status', 'createdAt', 'createdBy']));
      expect(row['metadata']['securityDepositApplied'], isTrue);
      expect(row['metadata']['depositAmount'], 25.0);
      expect(row['metadata']['depositMethod'], 'check');
      expect(row['metadata']['depositReference'], '1234');

      final settled = SecurityDeposit.fromMap(p.deposit);
      expect(settled.isHeld, isFalse);
      expect(settled.appliedAmount, 25);
      expect(settled.refundedAmount, 0);
      expect(settled.appliedLedgerEntryId, 'ledger-1');
      // Nothing was refunded, so no refund method is kept.
      expect(settled.refundMethod, isNull);
      expect(settled.refundReference, isNull);
      expect(settled.settledBy, 'owner-1');
      // What was recorded about the deposit itself is kept.
      expect(settled.amount, 25);
      expect(settled.reference, '1234');
      expect(settled.recordedBy, 'owner-1');
    });

    test('refunding it all writes nothing to the ledger', () {
      final p = plan(0, 25);
      expect(p.ledgerEntry, isNull);
      final settled = SecurityDeposit.fromMap(p.deposit);
      expect(settled.isHeld, isFalse);
      expect(settled.appliedAmount, 0);
      expect(settled.refundedAmount, 25);
      expect(settled.refundMethod, PaymentMethod.cash);
      expect(settled.refundReference, 'refund-1');
      expect(settled.appliedLedgerEntryId, isNull);
    });

    test('a split posts a credit for the applied part only', () {
      final p = plan(10, 15);
      expect(p.ledgerEntry!['amount'], -10.0);
      expect(p.ledgerEntry!['type'], 'credit');
      final settled = SecurityDeposit.fromMap(p.deposit);
      expect(settled.appliedAmount, 10);
      expect(settled.refundedAmount, 15);
      expect(settled.refundMethod, PaymentMethod.cash);
    });

    test('the split is checked in cents, so float sums do not refuse', () {
      // 12.34 + 12.66 is 25.000000000000004 as doubles.
      final p = plan(12.34, 12.66);
      expect(p.ledgerEntry!['amount'], -12.34);
      expect(p.refundedAmount, 12.66);
    });

    test('refused when already settled', () {
      expect(
        () => plan(25, 0, deposit: _settled()),
        throwsA(isA<SecurityDepositException>().having((e) => e.message, 'message', contains('already been settled'))),
      );
    });

    test('refused when the split does not add up, or goes negative', () {
      expect(() => plan(10, 10), throwsA(isA<SecurityDepositException>()));
      expect(() => plan(30, 0), throwsA(isA<SecurityDepositException>()));
      expect(() => plan(25.01, 0), throwsA(isA<SecurityDepositException>()));
      expect(() => plan(30, -5), throwsA(isA<SecurityDepositException>()));
      expect(() => plan(-5, 30), throwsA(isA<SecurityDepositException>()));
    });
  });

  group('SecurityDepositService', () {
    late FakeFacilityFirestore db;
    late List<AuditLogEntry> logged;

    void seed(Map<String, dynamic> tenant) {
      db = FakeFacilityFirestore('f1', {
        'tenants': [FakeDoc('t1', tenant)],
        'ledgers': <FakeDoc>[],
      });
      SecurityDepositService.firestoreForTesting = db;
    }

    Map<String, dynamic> storedDeposit() =>
        Map<String, dynamic>.from(db.data('tenants', 't1')!['securityDeposit'] as Map);

    setUp(() {
      logged = [];
      AuditService.recordForTesting = logged.add;
      SecurityDepositService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
    });

    tearDown(() {
      AuditService.recordForTesting = null;
      SecurityDepositService.firestoreForTesting = null;
      SecurityDepositService.authForTesting = null;
    });

    test('settle applies part to the ledger and records the rest as refunded', () async {
      seed(_tenantDoc(deposit: _held()));

      final after = await SecurityDepositService.settle(
        facilityId: 'f1',
        tenantId: 't1',
        appliedAmount: 10,
        refundedAmount: 15,
        refundMethod: PaymentMethod.check,
        refundReference: '5678',
      );

      expect(db.commits, 1);
      final rows = db.sub('ledgers').stored;
      expect(rows, hasLength(1));
      final row = rows.single.data();
      expect(row['type'], 'credit');
      expect(row['amount'], -10.0);
      expect(row['description'], 'Security deposit applied');
      expect(row['status'], 'posted');
      expect(row['createdBy'], 'owner-1');
      expect(row['metadata']['securityDepositApplied'], isTrue);

      final stored = SecurityDeposit.fromMap(storedDeposit());
      expect(stored.isHeld, isFalse);
      expect(stored.appliedAmount, 10);
      expect(stored.refundedAmount, 15);
      expect(stored.refundMethod, PaymentMethod.check);
      expect(stored.refundReference, '5678');
      expect(stored.appliedLedgerEntryId, rows.single.id);
      expect(after.appliedLedgerEntryId, rows.single.id);

      expect(logged.map((e) => e.eventType), ['tenant.securityDeposit.settled']);
      expect(logged.single.tenantId, 't1');
      expect(logged.single.before!['status'], 'held');
      expect(logged.single.after!['status'], 'settled');
      expect(logged.single.metadata!['appliedAmount'], 10.0);
      expect(logged.single.metadata!['refundedAmount'], 15.0);
    });

    test('settle with a full refund leaves the ledger alone', () async {
      seed(_tenantDoc(deposit: _held()));

      await SecurityDepositService.settle(
        facilityId: 'f1',
        tenantId: 't1',
        appliedAmount: 0,
        refundedAmount: 25,
        refundMethod: PaymentMethod.cash,
      );

      expect(db.sub('ledgers').stored, isEmpty);
      final stored = SecurityDeposit.fromMap(storedDeposit());
      expect(stored.isHeld, isFalse);
      expect(stored.refundedAmount, 25);
      expect(stored.appliedLedgerEntryId, isNull);
    });

    test('settle is refused once settled, and writes nothing', () async {
      seed(_tenantDoc(deposit: _settled()));

      await expectLater(
        SecurityDepositService.settle(
          facilityId: 'f1',
          tenantId: 't1',
          appliedAmount: 25,
          refundedAmount: 0,
        ),
        throwsA(isA<SecurityDepositException>()),
      );

      expect(db.commits, 0);
      expect(db.sub('ledgers').stored, isEmpty);
      expect(db.sub('tenants').log.writes, isEmpty);
      expect(logged, isEmpty);
    });

    test('settle is refused when the split does not add up, and writes nothing', () async {
      seed(_tenantDoc(deposit: _held()));

      await expectLater(
        SecurityDepositService.settle(
          facilityId: 'f1',
          tenantId: 't1',
          appliedAmount: 10,
          refundedAmount: 10,
        ),
        throwsA(isA<SecurityDepositException>()),
      );

      expect(db.commits, 0);
      expect(db.sub('ledgers').stored, isEmpty);
      expect(storedDeposit()['status'], 'held');
      expect(logged, isEmpty);
    });

    test('settle is refused when no deposit is on file', () async {
      seed(_tenantDoc());
      await expectLater(
        SecurityDepositService.settle(
          facilityId: 'f1',
          tenantId: 't1',
          appliedAmount: 0,
          refundedAmount: 0,
        ),
        throwsA(isA<SecurityDepositException>()),
      );
      expect(db.sub('ledgers').stored, isEmpty);
    });

    test('record writes a held deposit with the date at noon UTC', () async {
      seed(_tenantDoc());

      final saved = await SecurityDepositService.record(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 25,
        receivedDate: DateTime(2026, 9, 1, 16, 45),
        method: PaymentMethod.check,
        reference: '1234',
        note: 'Covers Unit 12',
      );

      final stored = storedDeposit();
      expect(stored['status'], 'held');
      expect(stored['amount'], 25.0);
      expect(stored['method'], 'check');
      expect(stored['reference'], '1234');
      expect(stored['note'], 'Covers Unit 12');
      expect(stored['recordedBy'], 'owner-1');
      expect((stored['receivedDate'] as Timestamp).toDate().toUtc(), DateTime.utc(2026, 9, 1, 12));
      expect(saved.isHeld, isTrue);
      // Recording a deposit never touches the ledger.
      expect(db.sub('ledgers').stored, isEmpty);
      expect(logged.map((e) => e.eventType), ['tenant.securityDeposit.recorded']);
      expect(logged.single.before, isNull);
      expect(logged.single.after!['amount'], 25.0);
    });

    test('record with no date stores the date as unknown', () async {
      seed(_tenantDoc());
      await SecurityDepositService.record(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 25,
        method: PaymentMethod.cash,
      );
      final stored = storedDeposit();
      expect(stored.containsKey('receivedDate'), isTrue);
      expect(stored['receivedDate'], isNull);
    });

    test('record corrects a held deposit and keeps who first recorded it', () async {
      seed(_tenantDoc(deposit: _held().copyWith(recordedBy: 'manager-2')));

      await SecurityDepositService.record(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 50,
        receivedDate: DateTime(2026, 9, 2),
        method: PaymentMethod.cash,
      );

      final stored = SecurityDeposit.fromMap(storedDeposit());
      expect(stored.amount, 50);
      expect(stored.method, PaymentMethod.cash);
      expect(stored.reference, isNull);
      expect(stored.recordedBy, 'manager-2');
      expect(stored.recordedAt!.toUtc(), DateTime.utc(2026, 9, 1, 15));
      expect(logged.map((e) => e.eventType), ['tenant.securityDeposit.updated']);
      expect(logged.single.before!['amount'], 25.0);
      expect(logged.single.after!['amount'], 50.0);
    });

    test('record is refused once settled, and for a zero amount', () async {
      seed(_tenantDoc(deposit: _settled()));
      await expectLater(
        SecurityDepositService.record(
          facilityId: 'f1',
          tenantId: 't1',
          amount: 25,
          method: PaymentMethod.cash,
        ),
        throwsA(isA<SecurityDepositException>()),
      );
      expect(db.sub('tenants').log.writes, isEmpty);

      seed(_tenantDoc());
      await expectLater(
        SecurityDepositService.record(
          facilityId: 'f1',
          tenantId: 't1',
          amount: 0,
          method: PaymentMethod.cash,
        ),
        throwsA(isA<SecurityDepositException>()),
      );
      expect(db.sub('tenants').log.writes, isEmpty);
      expect(logged, isEmpty);
    });

    test('remove takes a held deposit off the tenant; a settled one stays', () async {
      seed(_tenantDoc(deposit: _held()));
      expect(await SecurityDepositService.remove(facilityId: 'f1', tenantId: 't1'), isTrue);
      expect(db.data('tenants', 't1')!['securityDeposit'], FieldValue.delete());
      expect(logged.map((e) => e.eventType), ['tenant.securityDeposit.removed']);
      expect(logged.single.before!['amount'], 25.0);

      seed(_tenantDoc(deposit: _settled()));
      await expectLater(
        SecurityDepositService.remove(facilityId: 'f1', tenantId: 't1'),
        throwsA(isA<SecurityDepositException>()),
      );
      expect(storedDeposit()['status'], 'settled');

      seed(_tenantDoc());
      expect(await SecurityDepositService.remove(facilityId: 'f1', tenantId: 't1'), isFalse);
      expect(db.sub('tenants').log.writes, isEmpty);
    });
  });
}
