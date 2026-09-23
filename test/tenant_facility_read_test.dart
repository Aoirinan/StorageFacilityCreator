// The fakes below implement cloud_firestore's @sealed Query and snapshot
// classes so the tests drive TenantService's real query code; nothing
// outside this file sees them.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/tenant_service.dart';

/// A tenants query that records how it was shaped and returns [docs], cut
/// to the limit the way Firestore would.
class _FakeTenantsQuery extends Fake implements Query<Map<String, dynamic>> {
  _FakeTenantsQuery(this.docs);

  final List<_FakeDoc> docs;
  final List<int> limits = [];
  final List<Object> orderedBy = [];

  int? get limitApplied => limits.isEmpty ? null : limits.last;

  List<_FakeDoc> get _served =>
      limitApplied == null ? docs : docs.take(limitApplied!).toList();

  @override
  Query<Map<String, dynamic>> limit(int limit) {
    limits.add(limit);
    return this;
  }

  @override
  Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    orderedBy.add(field);
    return this;
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async =>
      _FakeSnapshot(_served);

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      Stream.value(_FakeSnapshot(_served));
}

class _FakeSnapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _FakeSnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _FakeDoc extends Fake implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, String? name)
      : _data = {
          'facilityId': 'fac1',
          if (name != null) 'name': name,
          'isActive': true,
        };

  @override
  final String id;
  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;
}

void main() {
  test('a facility with more than 250 tenants, some unnamed, is read in full', () async {
    final query = _FakeTenantsQuery([
      for (var i = 0; i < 300; i++) _FakeDoc('t$i', 'Tenant ${i.toString().padLeft(3, '0')}'),
      _FakeDoc('no-name', null),
      _FakeDoc('blank-name', '  '),
    ]);

    final tenants = await TenantService.readFacilityTenants(query, 'fac1');

    // Before: limit(250) + orderBy('name') returned the first 250 by name;
    // the other 50 and both unnamed docs were never seen, so their units
    // counted as empty.
    expect(query.orderedBy, isEmpty);
    expect(tenants, hasLength(302));
    expect(tenants.first.name, 'Tenant 000');
    expect(tenants[299].name, 'Tenant 299');
    // Unnamed tenants sort last instead of being dropped.
    expect(tenants.skip(300).map((t) => t.id), unorderedEquals(['no-name', 'blank-name']));
  });

  test('the live stream reads the same way', () async {
    final query = _FakeTenantsQuery([
      _FakeDoc('b', 'Bea'),
      _FakeDoc('x', null),
      _FakeDoc('a', 'Al'),
    ]);

    final tenants = await TenantService.watchFacilityTenants(query, 'fac1').first;

    expect(query.orderedBy, isEmpty);
    expect(tenants.map((t) => t.id), ['a', 'b', 'x']);
  });

  test('a facility that reaches the read bound is reported, not silently cut', () async {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    const bound = TenantService.facilityTenantReadLimit;
    final query = _FakeTenantsQuery([
      for (var i = 0; i < bound + 10; i++) _FakeDoc('t$i', 'T$i'),
    ]);

    final tenants = await TenantService.readFacilityTenants(query, 'fac-huge');
    // Read again: reported once per facility, not on every read.
    await TenantService.readFacilityTenants(query, 'fac-huge');

    expect(query.limitApplied, bound);
    expect(tenants, hasLength(bound));
    expect(reported, hasLength(1));
    expect(reported.single.exception.toString(), contains('fac-huge'));
  });
}
