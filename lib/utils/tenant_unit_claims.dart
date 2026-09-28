import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/utils/unit_areas.dart';
import 'package:sfcapp/utils/unit_number.dart';

/// The units a facility's active tenants have by their own records, as the
/// public map reads them: a unit one of them claims is published as rented
/// and not rentable online, even with status available and no tenant link
/// (an owner can add a tenant with a unit number and never link the unit).
///
/// By `unitId` when the tenant has one: that is the unit their label names.
/// Matching their number instead, where numbers repeat across areas, took
/// "12" in Complex 2 off the market for a tenant in "12" in Complex 3. A
/// tenant with no `unitId` claims by number ([unitNumberKey]), in their
/// `unitArea` when they have one and in every area when not, since nothing
/// then says which "12" they are in; the unit's number from before a
/// renumbering (`legacyUnitNumber`) counts as its number.
///
/// PARITY: activeTenantUnitClaims and isUnitClaimedByActiveTenant in
/// functions-shared/src/units/onlineRental.ts, which the inventory sync and
/// the online rental callables use. Both run
/// test/fixtures/public_map_units.json.
class TenantUnitClaims {
  TenantUnitClaims._(this._unitIds, this._byNumber);

  /// What [tenants] claim. Only an active tenant ([TenantModel.isActive])
  /// claims anything.
  factory TenantUnitClaims.fromTenants(Iterable<TenantModel> tenants) {
    final unitIds = <String>{};
    final byNumber = <String, Set<String?>>{};
    for (final t in tenants) {
      if (!t.isActive) continue;
      final unitId = TenantModel.textField(t.unitId);
      if (unitId != null) {
        unitIds.add(unitId);
        continue;
      }
      final number = unitNumberKey(t.unitNumber);
      if (number.isEmpty) continue;
      (byNumber[number] ??= <String?>{}).add(unitAreaKey(t.unitArea));
    }
    return TenantUnitClaims._(unitIds, byNumber);
  }

  /// No tenant claims anything.
  static final TenantUnitClaims none =
      TenantUnitClaims._(const <String>{}, const <String, Set<String?>>{});

  final Set<String> _unitIds;

  /// Id-less tenants' number keys, each with the area keys it is claimed in
  /// (null: no area, so every area).
  final Map<String, Set<String?>> _byNumber;

  /// Whether an active tenant claims [unit].
  bool claims(UnitModel unit) {
    if (_unitIds.contains(unit.id.trim())) return true;
    final area = unitAreaKey(unit.area);
    for (final number in [
      unitNumberKey(unit.unitNumber),
      unitNumberKey(unit.legacyUnitNumber ?? ''),
    ]) {
      if (number.isEmpty) continue;
      final areas = _byNumber[number];
      if (areas != null &&
          (areas.contains(null) || (area != null && areas.contains(area)))) {
        return true;
      }
    }
    return false;
  }
}
