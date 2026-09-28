import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:sfcapp/models/provider_params.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';

// Previous / next tenant on the tenant's page and ledger, so an owner posting
// charges or payments down the rent roll need not go back to the list and
// find the next tenant each time.

/// The tenants as the tenant list showed them (its facility, search and sort)
/// when the owner opened one of them. The list sets it on each open and
/// clears it when it closes, so a tenant opened from anywhere else while the
/// list is gone (the Dashboard, a unit, a link) uses the fallback order.
final tenantListOrderProvider = StateProvider<List<TenantModel>?>((ref) => null);

/// Where a tenant sits in the order previous / next walk.
@immutable
class TenantNeighbors {
  const TenantNeighbors({
    required this.index,
    required this.total,
    this.previous,
    this.next,
  });

  /// 0-based.
  final int index;
  final int total;

  /// Null at the start of the order: no wraparound.
  final TenantModel? previous;

  /// Null at the end of the order.
  final TenantModel? next;

  /// "12 of 77".
  String get positionLabel => '${index + 1} of $total';
}

bool _isTenant(TenantModel t, String facilityId, String tenantId) =>
    t.id == tenantId && t.facilityId == facilityId;

/// The fallback order: the facility's active tenants by unit, as the tenant
/// list's Unit sort shows them.
List<TenantModel> activeTenantsByUnit(Iterable<TenantModel> facilityTenants) =>
    facilityTenants.where((t) => t.isActive).toList()
      ..sort(compareTenantsByUnit);

/// The tenant's place in [listOrder] (the tenant list's order) when it is
/// there, else in [facilityTenants]' active tenants by unit. Null when the
/// tenant is in neither (an archived tenant opened from outside the list),
/// or the facility's tenants have not loaded yet.
///
/// Neighbours come from [facilityTenants] when it has them, so the page
/// opens on the tenant as they are now, not as the list last read them.
TenantNeighbors? tenantNeighbors({
  required String facilityId,
  required String tenantId,
  List<TenantModel>? listOrder,
  List<TenantModel>? facilityTenants,
}) {
  var order = listOrder;
  var index =
      order?.indexWhere((t) => _isTenant(t, facilityId, tenantId)) ?? -1;
  if (index < 0) {
    if (facilityTenants == null) return null;
    order = activeTenantsByUnit(facilityTenants);
    index = order.indexWhere((t) => _isTenant(t, facilityId, tenantId));
    if (index < 0) return null;
  }
  final ordered = order!;

  TenantModel fresh(TenantModel t) {
    if (facilityTenants == null || t.facilityId != facilityId) return t;
    for (final current in facilityTenants) {
      if (current.id == t.id) return current;
    }
    return t;
  }

  return TenantNeighbors(
    index: index,
    total: ordered.length,
    previous: index > 0 ? fresh(ordered[index - 1]) : null,
    next: index < ordered.length - 1 ? fresh(ordered[index + 1]) : null,
  );
}

/// [tenantNeighbors] for one tenant, from the list's order and the
/// facility's live tenants.
final tenantNeighborsProvider =
    Provider.family<TenantNeighbors?, FacilityTenantParams>((ref, params) {
  if (!params.isValid) return null;
  final listOrder = ref.watch(tenantListOrderProvider);
  final facilityTenants =
      ref.watch(facilityTenantsProvider(params.facilityId)).value;
  return tenantNeighbors(
    facilityId: params.facilityId,
    tenantId: params.tenantId,
    listOrder: listOrder,
    facilityTenants: facilityTenants,
  );
});
