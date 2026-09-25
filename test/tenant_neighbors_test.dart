import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_navigation_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/utils/unit_number_sort.dart';

TenantModel _t(
  String id,
  String unit, {
  String name = '',
  String facilityId = 'f1',
  bool isActive = true,
  double rate = 50,
}) =>
    TenantModel(
      id: id,
      facilityId: facilityId,
      name: name.isEmpty ? 'Tenant $id' : name,
      email: '',
      phone: '',
      unitNumber: unit,
      monthlyRate: rate,
      createdAt: DateTime(2026, 1, 1),
      isActive: isActive,
    );

List<String> _ids(Iterable<TenantModel> tenants) =>
    tenants.map((t) => t.id).toList();

void main() {
  group('compareUnitNumbersNatural', () {
    List<String> sorted(List<String> units) =>
        [...units]..sort(compareUnitNumbersNatural);

    test('numbers inside a unit compare as numbers', () {
      expect(sorted(['C2-10', 'C2-2', 'C10-1', 'C2-1']),
          ['C2-1', 'C2-2', 'C2-10', 'C10-1']);
      expect(sorted(['10', '9', '100', '1']), ['1', '9', '10', '100']);
    });

    test('building letters come first', () {
      // The list's Unit sort used to join all the digits: B3 (3) came
      // before A5 (5).
      expect(sorted(['B3', 'A5', 'A10', 'b1']), ['A5', 'A10', 'b1', 'B3']);
    });
  });

  group('tenant list Unit sort', () {
    final tenants = [
      _t('x', 'C2-10'),
      _t('y', 'C10-1'),
      _t('z', 'C2-2'),
      _t('w', 'B3'),
      _t('v', 'A5'),
    ];

    test('ascending is natural order', () {
      expect(
        _ids(filterAndSortTenantsForDisplay(
            tenants, '', TenantSortOption.unitNumberAsc)),
        ['v', 'w', 'z', 'x', 'y'],
      );
    });

    test('descending is the reverse', () {
      expect(
        _ids(filterAndSortTenantsForDisplay(
            tenants, '', TenantSortOption.unitNumberDesc)),
        ['y', 'x', 'z', 'w', 'v'],
      );
    });
  });

  group('tenantNeighbors', () {
    final facility = [
      _t('c210', 'C2-10'),
      _t('gone', 'A1', isActive: false),
      _t('c22', 'C2-2'),
      _t('a5', 'A5'),
      _t('c101', 'C10-1'),
    ];

    test('walks the list order when the tenant is in it', () {
      // As the list showed them, sorted by rate say: not unit order.
      final listOrder = [
        _t('c101', 'C10-1'),
        _t('gone', 'A1', isActive: false),
        _t('a5', 'A5'),
      ];
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'gone',
        listOrder: listOrder,
        facilityTenants: facility,
      )!;
      expect(n.positionLabel, '2 of 3');
      expect(n.previous?.id, 'c101');
      expect(n.next?.id, 'a5');
    });

    test('keeps the list search: only the tenants it showed', () {
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'c22',
        listOrder: [_t('c22', 'C2-2'), _t('c210', 'C2-10')],
        facilityTenants: facility,
      )!;
      expect(n.positionLabel, '1 of 2');
      expect(n.previous, isNull);
      expect(n.next?.id, 'c210');
    });

    test('falls back to active tenants by unit without the list', () {
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'c22',
        facilityTenants: facility,
      )!;
      // A5, C2-2, C2-10, C10-1; the archived tenant is left out.
      expect(n.positionLabel, '2 of 4');
      expect(n.previous?.id, 'a5');
      expect(n.next?.id, 'c210');
    });

    test('falls back when the list does not have the tenant', () {
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'c101',
        listOrder: [_t('a5', 'A5')],
        facilityTenants: facility,
      )!;
      expect(n.positionLabel, '4 of 4');
      expect(n.previous?.id, 'c210');
      expect(n.next, isNull);
    });

    test('no wraparound at either end', () {
      final first = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'a5',
        facilityTenants: facility,
      )!;
      expect(first.previous, isNull);
      expect(first.next?.id, 'c22');

      final last = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'c101',
        facilityTenants: facility,
      )!;
      expect(last.next, isNull);
      expect(last.previous?.id, 'c210');
    });

    test('one tenant: both ends', () {
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'a5',
        facilityTenants: [_t('a5', 'A5')],
      )!;
      expect(n.positionLabel, '1 of 1');
      expect(n.previous, isNull);
      expect(n.next, isNull);
    });

    test('none for an archived tenant opened from outside the list', () {
      expect(
        tenantNeighbors(
          facilityId: 'f1',
          tenantId: 'gone',
          facilityTenants: facility,
        ),
        isNull,
      );
    });

    test('none until the facility tenants have loaded', () {
      expect(tenantNeighbors(facilityId: 'f1', tenantId: 'a5'), isNull);
    });

    test('a same id in another facility is another tenant', () {
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'a5',
        listOrder: [_t('a5', 'A5', facilityId: 'f2'), _t('x', 'B1')],
        facilityTenants: facility,
      )!;
      // Not in the list as f1's a5: the fallback.
      expect(n.positionLabel, '1 of 4');
    });

    test('opens the neighbour as the facility has it now', () {
      final listOrder = [_t('a5', 'A5', rate: 50), _t('c22', 'C2-2', rate: 50)];
      final n = tenantNeighbors(
        facilityId: 'f1',
        tenantId: 'a5',
        listOrder: listOrder,
        facilityTenants: [_t('a5', 'A5'), _t('c22', 'C2-2', rate: 75)],
      )!;
      expect(n.next?.monthlyRate, 75);
    });

    test('tenants sharing a unit are ordered by name', () {
      final order = activeTenantsByUnit([
        _t('2', 'A1', name: 'Zed'),
        _t('1', 'A1', name: 'Amy'),
      ]);
      expect(_ids(order), ['1', '2']);
    });
  });
}
