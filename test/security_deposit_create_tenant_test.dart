import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

// Create Tenant with "Security deposit received" ticked: the deposit is
// saved on the new tenant as held, off the ledger, recorded by whoever
// created the tenant. A made-up tenant ("Pat Example", Unit 12).

void main() {
  group('TenantService.createTenant with a security deposit', () {
    late FakeFacilityFirestore db;
    late List<AuditLogEntry> logged;

    setUp(() {
      db = FakeFacilityFirestore('f1', {
        'tenants': <FakeDoc>[],
        'units': [
          FakeDoc('u12', {'unitNumber': '12', 'status': 'available', 'monthlyRate': 80}),
        ],
      });
      logged = [];
      AuditService.recordForTesting = logged.add;
      TenantService.firestoreForTesting = db;
      TenantService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
      UnitService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
      FacilitySubcollections.overrideForTesting((facilityId, name) => db.sub(name));
    });

    tearDown(() {
      AuditService.recordForTesting = null;
      TenantService.firestoreForTesting = null;
      TenantService.authForTesting = null;
      UnitService.authForTesting = null;
      FacilitySubcollections.overrideForTesting(null);
    });

    Future<String> create(SecurityDeposit deposit) => TenantService.createTenant(
          facilityId: 'f1',
          name: 'Pat Example',
          email: '',
          phone: '',
          unitNumber: '12',
          unitId: 'u12',
          monthlyRate: 80,
          securityDeposit: deposit,
        );

    test('the deposit is saved held, to the cent, recorded by the creator', () async {
      // As the Create Tenant screen builds it: the day at noon UTC, no status
      // or recorder (createTenant sets those). Typed with three decimals.
      final id = await create(SecurityDeposit(
        amount: 24.999,
        receivedDate: SecurityDeposit.noonUtc(DateTime(2026, 1, 15)),
        method: PaymentMethod.check,
        reference: '1234',
      ));

      final stored = Map<String, dynamic>.from(db.data('tenants', id)!['securityDeposit'] as Map);
      expect(stored['status'], 'held');
      expect(stored['amount'], 25.0);
      expect(stored['method'], 'check');
      expect(stored['reference'], '1234');
      expect(stored['recordedBy'], 'owner-1');
      expect(stored['recordedAt'], isA<Timestamp>());
      expect((stored['receivedDate'] as Timestamp).toDate().toUtc(), DateTime.utc(2026, 1, 15, 12));
      // Nothing settlement-related yet, and nothing on the ledger.
      expect(stored.containsKey('settledAt'), isFalse);
      expect(stored.containsKey('appliedAmount'), isFalse);
      expect(db.sub('ledgers').stored, isEmpty);
      // What the tenant page reads back.
      final deposit = SecurityDeposit.fromMap(stored);
      expect(deposit.isHeld, isTrue);
      expect(deposit.summary, '\$25.00 held · received 1/15/2026 · Check #1234');
      expect(logged.map((e) => e.eventType), contains('tenant.created'));
    });

    test('a zero deposit is refused before anything is saved', () async {
      await expectLater(
        create(SecurityDeposit(amount: 0, method: PaymentMethod.cash)),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('above \$0'))),
      );
      expect(db.sub('tenants').stored, isEmpty);
      expect(db.sub('units').log.writes, isEmpty);
      expect(logged, isEmpty);
    });
  });
}
