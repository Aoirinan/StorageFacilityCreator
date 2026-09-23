import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';

TenantModel _tenant(String id, String name) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: name,
      email: '',
      phone: '',
      unitNumber: id,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  test('filtered tenants stay loading until the source has data', () async {
    final source = StreamController<List<TenantModel>>();
    final container = ProviderContainer(overrides: [
      facilityTenantsProvider('f1').overrideWith((ref) => source.stream),
    ]);
    addTearDown(container.dispose);
    addTearDown(() => unawaited(source.close()));

    final sub = container.listen(filteredTenantsProvider('f1'), (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    // Before: this reported AsyncData([]), which the tenant list rendered
    // as "No tenants found" after every page reload.
    expect(container.read(filteredTenantsProvider('f1')).isLoading, isTrue);
    expect(container.read(filteredTenantsProvider('f1')).hasValue, isFalse);

    source.add([_tenant('b', 'Bea'), _tenant('a', 'Al')]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final value = container.read(filteredTenantsProvider('f1')).value;
    expect(value?.map((t) => t.name), ['Al', 'Bea']);
  });
}
