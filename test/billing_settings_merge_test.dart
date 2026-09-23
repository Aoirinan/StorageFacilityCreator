import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_service.dart';

void main() {
  test('billing settings are written as per-key field paths', () {
    // Edit Facility saves only these three; admin fees, reminder settings and
    // delinquency rules in the same map must survive the save.
    final updates = FacilityService.billingSettingsFieldUpdates({
      'gracePeriodDays': 5,
      'lateFeeType': 'flat',
      'lateFeeAmount': 25.0,
    });
    expect(updates, {
      'billingSettings.gracePeriodDays': 5,
      'billingSettings.lateFeeType': 'flat',
      'billingSettings.lateFeeAmount': 25.0,
    });
    expect(updates.containsKey('billingSettings'), isFalse);
  });
}
