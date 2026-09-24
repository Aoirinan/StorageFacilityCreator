import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/lead_source_service.dart';

void main() {
  test('a lead converts only when its tenant is active (isActive exactly true)',
      () {
    final tally = LeadSourceService.tallyLeadSources([
      {'leadSource': 'google', 'isActive': true},
      {'leadSource': 'google', 'isActive': false},
      // A partial doc with no isActive: inactive, as on the dashboard and in
      // every server job. It used to count as a conversion here.
      {'leadSource': 'google'},
      {'leadSource': 'referral', 'isActive': 'true'},
      {'isActive': true},
      {'leadSource': '', 'isActive': true},
    ]);

    expect(tally.total, {'google': 3, 'referral': 1});
    expect(tally.converted, {'google': 1});
  });
}
