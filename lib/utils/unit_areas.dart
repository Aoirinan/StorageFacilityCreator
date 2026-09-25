import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';

/// Longest area name the unit editor and "Set area" accept.
const int unitAreaMaxLength = 60;

/// The Area filter value that picks units (and tenants) with no area set.
/// Any other non-null value is an area name; null is "All areas".
const String noUnitAreaFilter = '\u0000no-area';

/// [raw] trimmed, or null when it is not a string or is blank. Area is how an
/// owner groups units (Complex 2, Outdoor storage, Rental house); it is free
/// text on the unit doc (`area`).
String? normalizeUnitArea(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _areaKey(String area) => area.trim().toLowerCase();

/// The facility's areas, one per name ignoring case (the first spelling
/// seen), sorted A-Z ignoring case.
List<String> distinctUnitAreas(Iterable<UnitModel> units) {
  final byKey = <String, String>{};
  for (final unit in units) {
    final area = normalizeUnitArea(unit.area);
    if (area == null) continue;
    byKey.putIfAbsent(_areaKey(area), () => area);
  }
  final areas = byKey.values.toList()
    ..sort((a, b) {
      final c = a.toLowerCase().compareTo(b.toLowerCase());
      return c != 0 ? c : a.compareTo(b);
    });
  return areas;
}

/// [typed] trimmed, spelled as an existing area when it matches one ignoring
/// case, so "complex 2" joins "Complex 2" rather than making a second area.
/// Null when blank.
String? canonicalUnitArea(String? typed, Iterable<String> existingAreas) {
  final area = normalizeUnitArea(typed);
  if (area == null) return null;
  final key = _areaKey(area);
  for (final existing in existingAreas) {
    if (_areaKey(existing) == key) return existing;
  }
  return area;
}

/// What the Area dropdown offers for [units]: each area, then "No area" when
/// some unit has none. Empty when no unit has an area, and the dropdown is
/// then hidden.
List<String> unitAreaFilterOptions(Iterable<UnitModel> units) {
  final areas = distinctUnitAreas(units);
  if (areas.isEmpty) return const [];
  final anyWithout = units.any((u) => normalizeUnitArea(u.area) == null);
  return [...areas, if (anyWithout) noUnitAreaFilter];
}

/// [selected] when the dropdown can show it for [options], else null (All
/// areas): an area that no unit has any more would otherwise leave the list
/// filtered to nothing with no way to see why.
String? effectiveUnitAreaFilter(String? selected, List<String> options) {
  if (selected == null) return null;
  return options.contains(selected) ? selected : null;
}

/// The dropdown label for an option from [unitAreaFilterOptions].
String unitAreaFilterLabel(String option) =>
    option == noUnitAreaFilter ? 'No area' : option;

bool _areaMatches(String? area, String filter) {
  final normalized = normalizeUnitArea(area);
  if (filter == noUnitAreaFilter) return normalized == null;
  return normalized != null && _areaKey(normalized) == _areaKey(filter);
}

/// Whether [unit] passes the Area filter [filter] (null: every unit).
bool unitMatchesAreaFilter(UnitModel unit, String? filter) =>
    filter == null || _areaMatches(unit.area, filter);

String _unitNumberKey(String unitNumber) => unitNumber.trim().toLowerCase();

/// A facility's units looked up the ways a tenant points at them: by the
/// unit's `tenantId` (how move-out and unit changes find a tenant's units)
/// and by the tenant's `unitNumber`, trimmed and ignoring case (tenants
/// imported or created with a unit number and never assigned through the
/// unit carry only that).
class TenantUnitAreaIndex {
  TenantUnitAreaIndex(Iterable<UnitModel> units) {
    for (final unit in units) {
      final tenantId = unit.tenantId?.trim() ?? '';
      if (tenantId.isNotEmpty) {
        (_byTenantId[tenantId] ??= []).add(unit);
      }
      final number = _unitNumberKey(unit.unitNumber);
      if (number.isNotEmpty) _byNumber.putIfAbsent(number, () => unit);
    }
  }

  final Map<String, List<UnitModel>> _byTenantId = {};
  final Map<String, UnitModel> _byNumber = {};

  /// The units [tenant] holds or names, each once.
  List<UnitModel> unitsFor(TenantModel tenant) {
    final units = <UnitModel>[...?_byTenantId[tenant.id]];
    final named = _byNumber[_unitNumberKey(tenant.unitNumber)];
    if (named != null && !units.any((u) => u.id == named.id)) {
      units.add(named);
    }
    return units;
  }

  /// The areas of [tenant]'s units, distinct and sorted; empty when none of
  /// them has one.
  List<String> areasFor(TenantModel tenant) =>
      distinctUnitAreas(unitsFor(tenant));

  /// Whether [tenant] passes the Area filter [filter] (null: every tenant).
  /// A tenant with units in two areas shows under both. "No area" is a
  /// tenant with no unit that has an area, including one with no unit found.
  bool matches(TenantModel tenant, String? filter) {
    if (filter == null) return true;
    final units = unitsFor(tenant);
    if (filter == noUnitAreaFilter) {
      return units.every((u) => normalizeUnitArea(u.area) == null);
    }
    return units.any((u) => _areaMatches(u.area, filter));
  }
}

/// [tenants] in [filter]'s area, in the order given (null: all of them).
List<TenantModel> filterTenantsByUnitArea(
  List<TenantModel> tenants,
  Iterable<UnitModel> units,
  String? filter,
) {
  if (filter == null) return tenants;
  final index = TenantUnitAreaIndex(units);
  return tenants.where((t) => index.matches(t, filter)).toList();
}
