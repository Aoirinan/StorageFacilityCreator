import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/screens/super_admin/widgets/texting_registrations_section.dart';

void main() {
  test('parses an event from listA2PAdminEvents', () {
    final event = A2PAdminEvent.fromMap({
      'id': 'evt1',
      'facilityId': 'fac1',
      'facilityName': 'Keepsake Self Storage',
      'legalBusinessName': 'Keepsake LLC',
      'alerts': [
        {
          'kind': 'campaign_rejected',
          'headline': 'Carriers rejected the texting registration',
          'detail': ['Reason: EIN does not match IRS records.'],
        },
      ],
      'emailStatus': 'sent',
      'emailError': null,
      'createdAtMs': 1790000000000,
    });
    expect(event.facilityName, 'Keepsake Self Storage');
    expect(event.alerts.single.detail.single, contains('EIN does not match'));
    expect(event.isBad, isTrue);
    expect(event.isGood, isFalse);
    expect(event.createdAt, isNotNull);
  });

  test('tolerates missing fields', () {
    final event = A2PAdminEvent.fromMap({'id': 'evt2'});
    expect(event.alerts, isEmpty);
    expect(event.createdAt, isNull);
    expect(event.isBad, isFalse);
  });
}
