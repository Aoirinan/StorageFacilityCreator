import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/services/tenant_service.dart';

class _FailingBackend extends TenantOperationsBackend {
  const _FailingBackend(this.error);

  final Object error;

  @override
  Future<void> archiveTenant({required String facilityId, required String tenantId}) =>
      Future.error(error);

  @override
  Future<void> deleteTenant({required String facilityId, required String tenantId}) =>
      Future.error(error);

  @override
  Future<void> deleteTenants({required String facilityId, required List<String> tenantIds}) =>
      Future.error(error);
}

class _OkBackend extends TenantOperationsBackend {
  const _OkBackend();

  @override
  Future<void> deleteTenant({required String facilityId, required String tenantId}) async {}
}

/// The notifier used to catch every error and return normally, so the tenant
/// list said "deleted successfully" even when the delete was refused.
void main() {
  const refusal = TenantDeleteRefusedException([
    TenantDeleteBlock(tenantId: 't1', tenantName: 'Ada Park', reasons: ['an invoice']),
  ]);

  test('deleteTenant passes a refusal on to the caller', () async {
    final notifier = TenantOperationsNotifier(const _FailingBackend(refusal));
    addTearDown(notifier.dispose);

    await expectLater(
      notifier.deleteTenant(facilityId: 'f1', tenantId: 't1'),
      throwsA(same(refusal)),
    );
    expect(notifier.state, isA<AsyncError<void>>());
    expect(notifier.state.error, same(refusal));
  });

  test('deleteTenants passes a refusal on to the caller', () async {
    final notifier = TenantOperationsNotifier(const _FailingBackend(refusal));
    addTearDown(notifier.dispose);

    await expectLater(
      notifier.deleteTenants(facilityId: 'f1', tenantIds: ['t1', 't2']),
      throwsA(same(refusal)),
    );
    expect(notifier.state.error, same(refusal));
  });

  test('archiveTenant passes a refusal on to the caller', () async {
    const stillAssigned = TenantStillAssignedToUnitException(
      tenantName: 'Ada Park',
      units: [HeldUnit('101', UnitStatus.occupied)],
    );
    final notifier = TenantOperationsNotifier(const _FailingBackend(stillAssigned));
    addTearDown(notifier.dispose);

    await expectLater(
      notifier.archiveTenant(facilityId: 'f1', tenantId: 't1'),
      throwsA(same(stillAssigned)),
    );
  });

  test('a successful delete completes normally', () async {
    final notifier = TenantOperationsNotifier(const _OkBackend());
    addTearDown(notifier.dispose);

    await notifier.deleteTenant(facilityId: 'f1', tenantId: 't1');
    expect(notifier.state, isA<AsyncData<void>>());
  });
}
