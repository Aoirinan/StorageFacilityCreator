import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/utils/unit_areas.dart';
import 'package:sfcapp/utils/unit_number.dart';

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

/// How an operator's unit list or picker names [unit]: "Unit 12 (Complex 2)"
/// (or "12 (Complex 2)" with [UnitLabelStyle.plain]) whenever the unit has an
/// area, whatever the facility setting, so two units with one number can be
/// told apart before one is picked. Tenant-facing text follows the setting
/// ([tenantUnitLabel]) instead.
String unitPickerLabel(
  UnitModel unit, {
  UnitLabelStyle style = UnitLabelStyle.withPrefix,
}) {
  final label = formatUnitLabel(
    number: unit.unitNumber,
    area: unit.area,
    includeArea: true,
    style: style,
  );
  if (label.isNotEmpty) return label;
  // A unit with no number still needs a row in the list.
  return style == UnitLabelStyle.withPrefix ? 'Unit' : '';
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

/// One of the units a tenant holds, as a screen that lists every one names
/// it. [unit] is the unit doc, for a link to its page; null when the label
/// is the record's `unitNumber` with no unit doc found behind it (the
/// facility's units not loaded, or a tenant imported with a number and never
/// assigned through a unit).
typedef HeldUnitLabel = ({String label, UnitModel? unit});

/// The units [tenant] holds, labelled ("C2-6, C2-7"): the unit their record
/// names first, as [tenantUnitLabel] (so a tenant with one unit reads as
/// before), then [TenantUnitAreaIndex.otherUnitsFor]. A record's
/// `unitNumber` names one unit however many it holds; the others are only
/// found through `units.tenantId`. With [units] null (the facility's units
/// not loaded) it is the record's unit alone. Empty for a record with no
/// unit number and no units: callers keep their own "no unit" wording.
List<HeldUnitLabel> tenantHeldUnitLabels(
  TenantModel tenant, {
  required TenantUnitAreaIndex? units,
  required bool includeArea,
}) {
  final named = units?.namedUnit(tenant);
  final others = units?.otherUnitsFor(tenant) ?? const <UnitModel>[];
  // A record with no unitId holding two units numbered alike (one per
  // area) names neither, so both are "other" units; its bare number would
  // then read as a third unit. The held units carry that number already.
  final bareNumberIsHeld = named == null &&
      others.any((u) => sameUnitNumber(u.unitNumber, tenant.unitNumber));
  final first = bareNumberIsHeld
      ? ''
      : tenantUnitLabel(tenant,
          includeArea: includeArea, fallbackArea: named?.area);
  final labels = <HeldUnitLabel>[
    if (first.isNotEmpty) (label: first, unit: named),
  ];
  for (final u in others) {
    final label = formatUnitLabel(
        number: u.unitNumber, area: u.area, includeArea: includeArea);
    // With the setting off, two units numbered alike would read as one.
    if (label.isEmpty || labels.any((l) => l.label == label)) continue;
    labels.add((label: label, unit: u));
  }
  return labels;
}

/// The Assign Tenant picker's line for a tenant's current units: "Unit 12
/// (Complex 2)", "Units C2-6, C2-7", or "No unit". Always with the area, as
/// the picker names the unit being assigned ([unitPickerLabel]), so two
/// records with one name and one phone can be told apart by what they hold.
String tenantPickerUnitsText(TenantModel tenant, TenantUnitAreaIndex units) {
  final labels = tenantHeldUnitLabels(tenant, units: units, includeArea: true);
  if (labels.isEmpty) return 'No unit';
  return '${labels.length == 1 ? 'Unit' : 'Units'} '
      '${labels.map((l) => l.label).join(', ')}';
}

/// The Tenants list card's unit line. [areas] are the areas of every unit
/// the tenant holds ([TenantUnitAreaIndex.areasFor]); [labelUnit] is the
/// unit their label names ([TenantUnitAreaIndex.namedUnit]), when the list
/// has it, for its area; [otherUnits] are the rest of the units they hold
/// ([TenantUnitAreaIndex.otherUnitsFor]), listed after it: "Unit: C2-6,
/// C2-7". A record with no unitId holding two units numbered alike names
/// neither ([labelUnit] null), and its bare number is left out rather than
/// read as a third unit, as [tenantHeldUnitLabels] leaves it out.
///
/// Off: "Unit: 12", or "Unit: 12 · Complex 2, Outdoor" when the tenant's
/// units have areas, as before the setting existed. On: the area moves into
/// the label, "Unit: 12 (Complex 2)", and only areas of units not listed
/// follow the dot.
String tenantListUnitLine(
  TenantModel tenant, {
  required bool includeArea,
  List<String> areas = const [],
  UnitModel? labelUnit,
  List<UnitModel> otherUnits = const [],
}) {
  final bareNumberIsHeld = labelUnit == null &&
      otherUnits.any((u) => sameUnitNumber(u.unitNumber, tenant.unitNumber));
  if (!includeArea) {
    final numbers = [
      if (tenant.unitNumber.isNotEmpty && !bareNumberIsHeld) tenant.unitNumber,
      for (final u in otherUnits) u.unitNumber,
    ].join(', ');
    return areas.isEmpty
        ? 'Unit: $numbers'
        : 'Unit: $numbers · ${areas.join(', ')}';
  }
  final labelArea = tenantLabelArea(tenant, fallbackArea: labelUnit?.area);
  final label = bareNumberIsHeld
      ? ''
      : tenantUnitLabel(tenant,
          includeArea: true, fallbackArea: labelUnit?.area);
  final labels = [
    if (label.isNotEmpty) label,
    for (final u in otherUnits)
      formatUnitLabel(number: u.unitNumber, area: u.area, includeArea: true),
  ].join(', ');
  // Areas already in a listed label do not follow the dot. A label with no
  // area carries none (a null key, which no area has).
  final carried = {
    if (label.isNotEmpty) unitAreaKey(labelArea),
    for (final u in otherUnits) unitAreaKey(u.area),
  };
  final others = [
    for (final a in areas)
      if (!carried.contains(unitAreaKey(a))) a,
  ];
  return others.isEmpty
      ? 'Unit: $labels'
      : 'Unit: $labels · ${others.join(', ')}';
}
