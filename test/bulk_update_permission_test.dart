import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/providers/permission_provider.dart';

void main() {
  test('bulk Paid through is for owners and managers, as the tenants rule allows', () {
    expect(canBulkUpdateTenantsForRole(RoleType.owner), isTrue);
    expect(canBulkUpdateTenantsForRole(RoleType.manager), isTrue);
    expect(canBulkUpdateTenantsForRole(RoleType.employee), isFalse);
    expect(canBulkUpdateTenantsForRole(RoleType.viewer), isFalse);
    expect(canBulkUpdateTenantsForRole(null), isFalse);
  });
}
