/**
 * How a unit is named to people: "12", or "12 (Complex 2)" when the facility
 * numbers units per area (so two areas can each have a unit 12).
 *
 * The app's lib/utils/unit_label.dart does the same; both run the table in
 * src/test/fixtures/unitLabelParity.json, so a tenant sees the same label on
 * a text from here as on a statement printed in the app.
 *
 * Nothing is escaped: a caller writing HTML escapes the label itself.
 */

/** `plain`: "12 (Complex 2)". `withPrefix`: "Unit 12 (Complex 2)". */
export type UnitLabelStyle = 'plain' | 'withPrefix';

export interface UnitLabelOptions {
  /** The unit number: a string, or a number (some imports wrote them as numbers). */
  number: unknown;
  /** The unit's area (free text). Ignored unless [includeArea]. */
  area?: unknown;
  /** Whether the area is part of the label: the facility's `unitNumbersRepeatAcrossAreas`. */
  includeArea: boolean;
  style?: UnitLabelStyle;
}

/**
 * [raw] as label text: a string with each run of whitespace made one space
 * and the ends trimmed, a finite number as its digits, anything else ''.
 */
function labelPart(raw: unknown): string {
  if (typeof raw === 'number') {
    return Number.isFinite(raw) ? String(raw) : '';
  }
  if (typeof raw !== 'string') return '';
  // Collapse first, so trimming is only ever one space off each end. Trimming
  // with String.trim would differ from Dart's trim on a few rare characters.
  return raw.replace(/\s+/g, ' ').replace(/^ | $/g, '');
}

/**
 * The unit's label. '' when there is no number (an area alone names no unit),
 * so callers keep their own "no unit" handling.
 */
export function formatUnitLabel(options: UnitLabelOptions): string {
  const number = labelPart(options.number);
  if (!number) return '';
  const area = options.includeArea === true ? labelPart(options.area) : '';
  const label = area ? `${number} (${area})` : number;
  return options.style === 'withPrefix' ? `Unit ${label}` : label;
}

/**
 * Whether [facility] (a facilities/{id} doc) names units with their area:
 * `unitNumbersRepeatAcrossAreas` exactly true. Off for every facility until
 * an owner turns it on.
 */
export function unitLabelsIncludeArea(facility: Record<string, unknown> | null | undefined): boolean {
  return facility?.unitNumbersRepeatAcrossAreas === true;
}

/**
 * The label of [tenant]'s unit (a tenants/{id} doc: `unitNumber`, and
 * `unitArea`, the area of their `unitId` unit), as [facility] names units.
 *
 * With the setting off, a string unitNumber comes back exactly as stored, so
 * nothing a tenant receives changes until the owner turns it on.
 */
export function tenantUnitLabel(
  tenant: Record<string, unknown> | null | undefined,
  facility: Record<string, unknown> | null | undefined,
): string {
  const raw = tenant?.unitNumber;
  if (!unitLabelsIncludeArea(facility)) {
    return typeof raw === 'string' ? raw : formatUnitLabel({ number: raw, includeArea: false });
  }
  return formatUnitLabel({ number: raw, area: tenant?.unitArea, includeArea: true });
}
