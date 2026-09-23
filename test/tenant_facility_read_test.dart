// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';

import 'support/fake_facility_collection.dart';

FakeDoc _tenant(String id, {String? name, Object? isActive = true, bool setActive = true}) =>
    FakeDoc(id, {
      'facilityId': 'fac1',
      if (name != null) 'name': name,
      if (setActive) 'isActive': isActive,
    });

/// 300 named tenants, plus one with no name field and one with a blank name.
List<FakeDoc> _bigFacility() => [
      for (var i = 0; i < 300; i++)
        _tenant('t$i', name: 'Tenant ${i.toString().padLeft(3, '0')}'),
      _tenant('no-name'),
      _tenant('blank-name', name: '  '),
    ];

/// Runs TenantService's real reads against [docs] as the facility's tenants.
FakeQueryLog _serveTenants(List<FakeDoc> docs) {
  final log = FakeQueryLog();
  FacilitySubcollections.overrideForTesting((facilityId, name) {
    expect(name, 'tenants');
    return FakeCollection(docs, log: log);
  });
  return log;
}

/// Serves only the top-level `facilities` collection.
class _FakeFirestore extends Fake implements FirebaseFirestore {
  _FakeFirestore(this.facilities);

  final FakeCollection facilities;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    expect(collectionPath, 'facilities');
    return facilities;
  }
}

void main() {
  setUp(() {
    TenantService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    TenantService.authForTesting = null;
    TenantService.firestoreForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  test('getTenantsForFacility reads a facility with more than 250 tenants, some unnamed, in full', () async {
    final log = _serveTenants(_bigFacility());

    final tenants = await TenantService.getTenantsForFacility('fac1');

    // Before: orderBy('name').limit(250) returned the first 250 by name; the
    // other 50 and both unnamed docs were never seen, so their units counted
    // as empty.
    expect(log.orderedBy, isEmpty);
    expect(tenants, hasLength(302));
    expect(tenants.first.name, 'Tenant 000');
    expect(tenants[299].name, 'Tenant 299');
    // Unnamed tenants sort last instead of being dropped.
    expect(tenants.skip(300).map((t) => t.id), unorderedEquals(['no-name', 'blank-name']));
  });

  test('getTenantsForFacilityStream reads the same way', () async {
    final log = _serveTenants(_bigFacility());

    final tenants = await TenantService.getTenantsForFacilityStream('fac1').first;

    expect(log.orderedBy, isEmpty);
    expect(tenants, hasLength(302));
    expect(tenants.skip(300).map((t) => t.id), unorderedEquals(['no-name', 'blank-name']));
  });

  test('getActiveTenantsForFacilityStream reads every active tenant, and only those', () async {
    final log = _serveTenants([
      for (var i = 0; i < 260; i++) _tenant('a$i', name: 'Active $i'),
      _tenant('active-no-name'),
      for (var i = 0; i < 5; i++) _tenant('x$i', name: 'Archived $i', isActive: false),
      // A partial doc, e.g. recreated by a server merge-write.
      _tenant('no-flag', name: 'No flag', setActive: false),
    ]);

    final tenants = await TenantService.getActiveTenantsForFacilityStream('fac1').first;

    expect(log.orderedBy, isEmpty);
    expect(log.equalityFilters, [('isActive', true)]);
    // Before: capped at 250 by name, and the unnamed active tenant was lost.
    expect(tenants, hasLength(261));
    expect(tenants.last.id, 'active-no-name');
    expect(tenants.every((t) => t.isActive), isTrue);
  });

  test('a facility that reaches the read bound is reported, not silently cut', () async {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    const bound = FacilitySubcollections.readLimit;
    final log = _serveTenants([
      for (var i = 0; i < bound + 10; i++) _tenant('t$i', name: 'T$i'),
    ]);

    final tenants = await TenantService.getTenantsForFacility('fac-huge');
    // Read again: reported once per facility, not on every read.
    await TenantService.getTenantsForFacility('fac-huge');

    expect(log.limits.toSet(), {bound});
    expect(tenants, hasLength(bound));
    expect(reported, hasLength(1));
    expect(reported.single.exception.toString(), contains('fac-huge'));
  });

  test('getAllTenants reads every tenant of each owned facility, not 250 per facility', () async {
    TenantService.firestoreForTesting = _FakeFirestore(FakeCollection([
      FakeDoc('fac1', {'ownerUid': 'owner-1'}),
      FakeDoc('fac2', {'ownerUid': 'owner-1'}),
      FakeDoc('not-mine', {'ownerUid': 'someone-else'}),
    ]));
    final tenantsByFacility = {
      'fac1': _bigFacility(),
      'fac2': [for (var i = 0; i < 5; i++) _tenant('f2-$i', name: 'Other $i')],
      'not-mine': [_tenant('stranger', name: 'Stranger')],
    };
    FacilitySubcollections.overrideForTesting((facilityId, name) {
      expect(name, 'tenants');
      return FakeCollection(tenantsByFacility[facilityId]!);
    });

    final tenants = await TenantService.getAllTenants();

    // Before: limit(250) per facility. The tenant limit now counts only
    // active tenants, so a facility can hold more tenant docs than that.
    expect(tenants, hasLength(307));
    expect(tenants.map((t) => t.id), isNot(contains('stranger')));
  });

  group('the active tenant rule', () {
    test('a tenant doc is active only when isActive is exactly true', () {
      expect(TenantModel.isActiveField(true), isTrue);
      expect(TenantModel.isActiveField(false), isFalse);
      expect(TenantModel.isActiveField(null), isFalse);
      expect(TenantModel.isActiveField('true'), isFalse);
    });

    test('a doc without isActive reads as inactive, as every active-tenant query treats it', () async {
      _serveTenants([
        _tenant('active', name: 'A'),
        _tenant('archived', name: 'B', isActive: false),
        _tenant('no-flag', name: 'C', setActive: false),
      ]);

      final tenants = await TenantService.getTenantsForFacility('fac1');

      // Before: TenantModel.fromFirestore defaulted a missing isActive to
      // true, so the dashboard counted this doc as an active tenant while the
      // active-tenant stream and the Cloud Function left it out.
      expect({for (final t in tenants) t.id: t.isActive}, {
        'active': true,
        'archived': false,
        'no-flag': false,
      });
    });
  });
}
