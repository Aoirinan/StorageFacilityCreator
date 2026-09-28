import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/contact_log_model.dart';
import 'package:sfcapp/router/app_route.dart';

void main() {
  test('a mailed final notice can be logged as a letter', () {
    final log = ContactLog(
      id: 'l1',
      tenantId: 't1',
      facilityId: 'f1',
      type: ContactLogType.letter,
      direction: ContactLogDirection.outbound,
      subject: 'Final notice letter mailed',
      contactDate: DateTime(2026, 9, 20),
      contactedBy: 'owner-1',
      createdAt: DateTime(2026, 9, 27),
    );
    final doc = log.toFirestore();
    expect(doc['type'], 'letter');
    expect(doc['direction'], 'outbound');
    expect(log.typeDisplayName, 'Letter / final notice');
  });

  test("the tenant page links to the tenant's contact log", () {
    expect(
      AppRoute.contactLogsFor(tenantId: 't1', facilityId: 'f1'),
      '/contact-logs?tenantId=t1&facilityId=f1',
    );
  });
}
