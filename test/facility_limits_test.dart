import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_limits_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';

import 'support/fake_facility_collection.dart';

List<FakeDoc> _tenants({required int active, int archived = 0, int noFlag = 0}) => [
      for (var i = 0; i < active; i++) FakeDoc('a$i', {'isActive': true}),
      for (var i = 0; i < archived; i++) FakeDoc('x$i', {'isActive': false}),
      // Partial docs without the field are not active tenants anywhere.
      for (var i = 0; i < noFlag; i++) FakeDoc('n$i', {'name': 'N$i'}),
    ];

void _serveTenants(List<FakeDoc> docs) {
  FacilitySubcollections.overrideForTesting((facilityId, name) {
    expect(name, 'tenants');
    return FakeCollection(docs);
  });
}

void main() {
  tearDown(() => FacilitySubcollections.overrideForTesting(null));

  test('archived tenants do not count toward the tenant limit', () async {
    // 300 tenant docs in the facility's lifetime, 249 of them still active.
    _serveTenants(_tenants(active: 249, archived: 46, noFlag: 5));

    // Before: count() over every tenant doc gave 300, so this facility could
    // never add another tenant however many had moved out.
    expect(await FacilityLimitsService.getTenantCount('fac1'), 249);
    expect(await FacilityLimitsService.canAddTenant('fac1'), isTrue);
  });

  test('a facility at the limit of active tenants cannot add another', () async {
    _serveTenants(_tenants(active: FacilityLimitsService.maxTenantsPerFacility, archived: 10));

    expect(await FacilityLimitsService.canAddTenant('fac1'), isFalse);
  });
}
