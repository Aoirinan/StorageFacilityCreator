import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/portal_invite_summary.dart';

void main() {
  test('parses the callable result and describes it plainly', () {
    final s = PortalInviteSummary.fromMap({
      'requested': 77,
      'sent': 1,
      'blockedPrelaunch': 70,
      'skippedNoEmail': 5,
      'unsubscribed': 0,
      'failed': 1,
      'codesGenerated': 12,
    });
    expect(
      s.describe(),
      'Sent 1 of 77. 70 held by the pre-launch gate. 5 with no email on file. 1 failed. 12 new access codes created.',
    );
    expect(s.anythingWentWrong, isTrue);
  });

  test('a clean full send reads simply', () {
    final s = PortalInviteSummary.fromMap({'requested': 3, 'sent': 3});
    expect(s.describe(), 'Sent 3 of 3.');
    expect(s.anythingWentWrong, isFalse);
  });
}
