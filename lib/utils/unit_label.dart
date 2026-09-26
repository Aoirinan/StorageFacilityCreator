import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/utils/unit_areas.dart';

/// [UnitLabelStyle.plain]: "12 (Complex 2)". [UnitLabelStyle.withPrefix]:
/// "Unit 12 (Complex 2)".
enum UnitLabelStyle { plain, withPrefix }

final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _endSpace = RegExp(r'^ | $');

/// [raw] as label text: a string with each run of whitespace made one space
/// and the ends trimmed, a number as its digits, anything else ''.
///
/// Collapses before trimming, so the trim is only ever one space off each
/// end: String.trim here and in JavaScript disagree on a few rare
/// characters, and functions-shared must give the same label.
String _labelPart(Object? raw) {
  if (raw is num) {
    if (!raw.isFinite) return '';
    return raw == raw.truncateToDouble() ? raw.toInt().toString() : raw.toString();
  }
  if (raw is! String) return '';
  return raw.replaceAll(_whitespaceRun, ' ').replaceAll(_endSpace, '');
}

/// How a unit is named to people: "12", or "12 (Complex 2)" when
/// [includeArea] (the facility numbers units per area, so two areas can each
/// have a unit 12) and the unit has an area.
///
/// '' when there is no number: an area alone names no unit, and callers keep
/// their own "no unit" wording. Nothing is escaped; a caller writing HTML
/// escapes the label.
///
/// functions-shared's formatUnitLabel is the same function; both run
/// functions-shared/src/test/fixtures/unitLabelParity.json.
String formatUnitLabel({
  required Object? number,
  Object? area,
  required bool includeArea,
  UnitLabelStyle style = UnitLabelStyle.plain,
}) {
  final n = _labelPart(number);
  if (n.isEmpty) return '';
  final a = includeArea ? _labelPart(area) : '';
  final label = a.isEmpty ? n : '$n ($a)';
  return style == UnitLabelStyle.withPrefix ? 'Unit $label' : label;
}

/// Whether [facility] names units with their area
/// (`unitNumbersRepeatAcrossAreas`). False for a facility not loaded.
bool unitLabelsIncludeArea(FacilityModel? facility) =>
    facility?.unitNumbersRepeatAcrossAreas == true;

/// The area [tenant]'s label shows: their `unitArea` (the area of their
/// `unitId` unit), else [fallbackArea] (the area of the unit the caller
/// already has for them), else null.
String? tenantLabelArea(TenantModel tenant, {Object? fallbackArea}) =>
    normalizeUnitArea(tenant.unitArea) ?? normalizeUnitArea(fallbackArea);

/// The label of [tenant]'s unit, without "Unit ": callers keep their own
/// wording around it ("Unit: 12", "Unit 12").
///
/// With [includeArea] false (the facility setting off) this is
/// `tenant.unitNumber` exactly as stored, so no document or message changes
/// for a facility until its owner turns the setting on. On, it is
/// [formatUnitLabel] with [tenantLabelArea].
String tenantUnitLabel(
  TenantModel tenant, {
  required bool includeArea,
  Object? fallbackArea,
}) {
  if (!includeArea) return tenant.unitNumber;
  return formatUnitLabel(
    number: tenant.unitNumber,
    area: tenantLabelArea(tenant, fallbackArea: fallbackArea),
    includeArea: true,
  );
}

/// Template variables for [tenant]'s unit: `unitNumber` is the label
/// ([tenantUnitLabel]; the variable keeps its name so saved templates keep
/// working) and `unitArea` the area alone ('' when none), for templates that
/// place it themselves.
Map<String, String> tenantUnitTemplateVars(
  TenantModel tenant, {
  required bool includeArea,
}) =>
    {
      'unitNumber': tenantUnitLabel(tenant, includeArea: includeArea),
      'unitArea': tenantLabelArea(tenant) ?? '',
    };

/// Fills the quick-message placeholders ({{tenant_name}}, {{name}},
/// {{first_name}}, {{unit}}, {{email}}, {{phone}}) for [tenant], as the
/// Messaging and Bulk messaging screens do. {{unit}} is [tenantUnitLabel].
String fillTenantQuickMessage(
  String template,
  TenantModel tenant, {
  required bool includeArea,
}) {
  final n = tenant.name.trim();
  final first = n.isEmpty ? 'there' : n.split(RegExp(r'\s+')).first;
  return template
      .replaceAll('{{tenant_name}}', tenant.name)
      .replaceAll('{{name}}', tenant.name)
      .replaceAll('{{first_name}}', first)
      .replaceAll('{{unit}}', tenantUnitLabel(tenant, includeArea: includeArea))
      .replaceAll('{{email}}', tenant.email)
      .replaceAll('{{phone}}', tenant.phone);
}

/// The Tenants list card's unit line. [areas] are the areas of every unit
/// the tenant holds ([TenantUnitAreaIndex.areasFor]); [labelUnitArea] is the
/// area of the unit their label names, when the list has it.
///
/// Off: "Unit: 12", or "Unit: 12 · Complex 2, Outdoor" when the tenant's
/// units have areas, as before the setting existed. On: the area moves into
/// the label, "Unit: 12 (Complex 2)", and only areas of their other units
/// follow the dot.
String tenantListUnitLine(
  TenantModel tenant, {
  required bool includeArea,
  List<String> areas = const [],
  String? labelUnitArea,
}) {
  if (!includeArea) {
    return areas.isEmpty
        ? 'Unit: ${tenant.unitNumber}'
        : 'Unit: ${tenant.unitNumber} · ${areas.join(', ')}';
  }
  final labelArea = tenantLabelArea(tenant, fallbackArea: labelUnitArea);
  final label = tenantUnitLabel(tenant,
      includeArea: true, fallbackArea: labelUnitArea);
  final labelKey = label.isEmpty ? null : labelArea?.toLowerCase();
  final others = [
    for (final a in areas)
      if (a.trim().toLowerCase() != labelKey) a,
  ];
  return others.isEmpty
      ? 'Unit: $label'
      : 'Unit: $label · ${others.join(', ')}';
}
