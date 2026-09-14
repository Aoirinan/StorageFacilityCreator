import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_creation_policy.dart';

void main() {
  test('an owner with any per-facility subscription is on the per-facility model', () {
    expect(usesPerFacilityBilling(['sub_123']), isTrue);
    expect(usesPerFacilityBilling([null, '', 'sub_123']), isTrue);
  });

  test('no per-facility subscription anywhere means legacy account rules apply', () {
    expect(usesPerFacilityBilling([]), isFalse);
    expect(usesPerFacilityBilling([null, '', '   ']), isFalse);
  });
}
