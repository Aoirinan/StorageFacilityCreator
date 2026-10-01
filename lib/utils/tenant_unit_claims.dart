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

  /// What the tenant docs [tenants] claim, read from the raw fields as the
  /// server reads them. Only a tenant whose `isActive` is exactly true
  /// claims anything. From the raw doc, not a [TenantModel]: parsing one
  /// throws on a unit number stored as a number and on odd fields unrelated
  /// to the claim, and the publish then saw no tenants at all.
  factory TenantUnitClaims.fromTenantDocs(
      Iterable<Map<String, dynamic>> tenants) {
    final unitIds = <String>{};
    final byNumber = <String, Set<String?>>{};
    for (final t in tenants) {
      if (t['isActive'] != true) continue;
      final unitId = TenantModel.textField(t['unitId']);
      if (unitId != null) {
        unitIds.add(unitId);
        continue;
      }
      final number = claimedNumberKey(t);
      if (number == null) continue;
      (byNumber[number] ??= <String?>{}).add(unitAreaKey(t['unitArea']));
    }
    return TenantUnitClaims._(unitIds, byNumber);
  }

  /// No tenant claims anything.
  static final TenantUnitClaims none =
      TenantUnitClaims._(const <String>{}, const <String, Set<String?>>{});

  /// The unit number key a tenant doc's `unitNumber` gives, as the server's
  /// `String(td.unitNumber || '').trim().toLowerCase()` reads it, or null
  /// when it names none (missing, blank, 0, false).
  static String? claimedNumberKey(Map<String, dynamic> tenant) {
    final raw = tenant['unitNumber'];
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is num && raw != 0 && !raw.isNaN) {
      // JavaScript's String() writes 101.0 as '101', as it does 101.
      text = raw is double &&
              raw.isFinite &&
              raw == raw.roundToDouble() &&
              raw.abs() < 1e21
          ? raw.toStringAsFixed(0)
          : raw.toString();
    } else if (raw == true) {
      text = 'true';
    } else {
      text = '';
    }
    final n = unitNumberKey(text);
    return n.isEmpty ? null : n;
  }

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
