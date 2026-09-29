import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
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

  test('the default security deposit is its own field path, and blank clears it', () {
    // Edit Facility's "Default security deposit ($)": a number saves under
    // billingSettings.securityDeposit (a prefill; see
    // SecurityDeposit.facilityDefault); a blank field deletes it, so the
    // other billing keys are untouched either way.
    expect(
      FacilityService.billingSettingsFieldUpdates({'securityDeposit': 25.0}),
      {'billingSettings.securityDeposit': 25.0},
    );
    final cleared = FacilityService.billingSettingsFieldUpdates(
        {'securityDeposit': FieldValue.delete()});
    expect(cleared, {'billingSettings.securityDeposit': FieldValue.delete()});
    expect(cleared.containsKey('billingSettings'), isFalse);
  });

  test('the facility default reads from billingSettings.securityDeposit', () {
    expect(SecurityDeposit.facilityDefault({'securityDeposit': 25}), 25.0);
    expect(SecurityDeposit.facilityDefault({'securityDeposit': 25.999}), 26.0);
    expect(SecurityDeposit.facilityDefault({'securityDeposit': '25'}), 25.0);
    // Unset, blank, zero or nonsense: nothing to prefill.
    expect(SecurityDeposit.facilityDefault(null), isNull);
    expect(SecurityDeposit.facilityDefault({'gracePeriodDays': 5}), isNull);
    expect(SecurityDeposit.facilityDefault({'securityDeposit': 0}), isNull);
    expect(SecurityDeposit.facilityDefault({'securityDeposit': ''}), isNull);
    expect(SecurityDeposit.facilityDefault({'securityDeposit': true}), isNull);
  });
}
