/**
 * Local-search structure for the facility website template.
 *
 * A storage facility's website lives or dies on ranking for "self storage
 * <town>". A competitor's cookie-cutter site (Storable) outranks ours in that
 * exact search not because it looks better — its typography is plainer — but
 * because its navigation and headline are made of the words customers type,
 * while ours used internal jargon and a location-free slogan.
 *
 * These helpers are pure so the behaviour applies to every facility
 * automatically, including ones onboarded later, rather than depending on each
 * operator writing good copy.
 */

/** Words that already imply storage, so we do not produce "Storage Self Storage". */
const STORAGE_WORDS = /\bstorage\b/i;

/**
 * Navigation label for a unit category.
 *
 * The nav used the category *slug* run through title case, which produced
 * "Outdoor" and "Standard" — internal names that mean nothing to a stranger and
 * match no search. Prefer the operator's display name, and append the category
 * noun so each link reads as a phrase people actually search
 * ("Climate Controlled Self Storage").
 */
export function categoryNavLabel(
  category: { slug?: string; name?: string } | null | undefined,
  fallbackSlug?: string,
): string {
  const name = String(category?.name || '').trim();
  const slug = String(category?.slug || fallbackSlug || '').trim();
  const base = name || titleCaseSlug(slug);
  if (!base) return '';
  // "Standard Units" -> "Standard Units Self Storage" reads badly; drop a
  // trailing "Units" before appending.
  const trimmed = base.replace(/\s+units?$/i, '').trim() || base;
  if (STORAGE_WORDS.test(trimmed)) return trimmed;
  return `${trimmed} Self Storage`;
}

/** "climate-controlled" -> "Climate Controlled" */
export function titleCaseSlug(slug: string): string {
  return String(slug || '')
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(' ');
}

/** US state names to postal codes, for turning "Texas" into "TX". */
const STATE_ABBR: Record<string, string> = {
  alabama: 'AL', alaska: 'AK', arizona: 'AZ', arkansas: 'AR', california: 'CA',
  colorado: 'CO', connecticut: 'CT', delaware: 'DE', florida: 'FL', georgia: 'GA',
  hawaii: 'HI', idaho: 'ID', illinois: 'IL', indiana: 'IN', iowa: 'IA',
  kansas: 'KS', kentucky: 'KY', louisiana: 'LA', maine: 'ME', maryland: 'MD',
  massachusetts: 'MA', michigan: 'MI', minnesota: 'MN', mississippi: 'MS',
  missouri: 'MO', montana: 'MT', nebraska: 'NE', nevada: 'NV',
  'new hampshire': 'NH', 'new jersey': 'NJ', 'new mexico': 'NM', 'new york': 'NY',
  'north carolina': 'NC', 'north dakota': 'ND', ohio: 'OH', oklahoma: 'OK',
  oregon: 'OR', pennsylvania: 'PA', 'rhode island': 'RI', 'south carolina': 'SC',
  'south dakota': 'SD', tennessee: 'TN', texas: 'TX', utah: 'UT', vermont: 'VT',
  virginia: 'VA', washington: 'WA', 'west virginia': 'WV', wisconsin: 'WI',
  wyoming: 'WY', 'district of columbia': 'DC',
};

export interface LocationSource {
  /** Explicit fields, when an operator has filled them in. */
  city?: unknown;
  state?: unknown;
  /** Free-text address, which is what most facilities actually have. */
  address?: unknown;
}

/**
 * Best available "City, ST" for a facility.
 *
 * Explicit city/state win. Otherwise fall back to reading the tail of the
 * address, because that is where most operators put it and requiring a new
 * field would leave every existing facility without a location.
 *
 * Returns null rather than guessing badly — a wrong town in the H1 is worse
 * than none.
 */
export function resolveLocationLabel(source: LocationSource): string | null {
  const city = String(source.city || '').trim();
  const stateRaw = String(source.state || '').trim();
  if (city && stateRaw) {
    return `${titleCaseSlug(city)}, ${normalizeState(stateRaw)}`;
  }

  const address = String(source.address || '').trim();
  if (!address) return null;

  const withoutZip = address.replace(/\b\d{5}(-\d{4})?\b\s*$/, '').trim();

  // Commas are the reliable signal, and the only way to recover a multi-word
  // city: "123 Main St, Santa Fe, New Mexico" splits cleanly, whereas token
  // counting from the end would read the city as just "Fe".
  if (withoutZip.includes(',')) {
    const parts = withoutZip.split(',').map((p) => p.trim()).filter(Boolean);
    if (parts.length >= 2) {
      const abbr = normalizeState(parts[parts.length - 1]);
      const cityPart = parts[parts.length - 2];
      if (abbr && cityPart && !/\d/.test(cityPart)) {
        return `${titleCaseSlug(cityPart)}, ${abbr}`;
      }
    }
    return null;
  }

  // No commas: fall back to reading the tail. Recovers the common
  // "4180 US Hwy 82 East Paris Texas" shape, at the cost of single-word cities.
  const tokens = withoutZip.split(/\s+/).filter(Boolean);
  if (tokens.length < 2) return null;

  // Try a two-word state first ("New Mexico"), then one word.
  for (const stateWords of [2, 1]) {
    if (tokens.length < stateWords + 1) continue;
    const candidate = tokens.slice(-stateWords).join(' ');
    const abbr = normalizeState(candidate);
    if (abbr) {
      const cityToken = tokens[tokens.length - stateWords - 1];
      // A number is a street fragment, not a town.
      if (!cityToken || /\d/.test(cityToken)) return null;
      return `${titleCaseSlug(cityToken)}, ${abbr}`;
    }
  }
  return null;
}

/** "Texas" or "tx" -> "TX"; returns '' when it is not a US state. */
export function normalizeState(value: string): string {
  const raw = String(value || '').trim();
  if (!raw) return '';
  const lower = raw.toLowerCase();
  if (STATE_ABBR[lower]) return STATE_ABBR[lower];
  const upper = raw.toUpperCase();
  if (/^[A-Z]{2}$/.test(upper) && Object.values(STATE_ABBR).includes(upper)) return upper;
  return '';
}

/**
 * Headlines that shipped as seeded defaults rather than operator-authored copy.
 *
 * Treated as unset so existing facilities pick up a location-aware headline
 * too. Without this, only brand-new facilities would benefit and every site
 * already onboarded would keep a slogan that names no town.
 */
const PLACEHOLDER_HEADLINES = new Set(
  [
    'secure self storage, rented online in minutes',
    'secure self storage rented online in minutes',
    'self storage made easy',
    'welcome',
  ].map((s) => s.toLowerCase()),
);

/**
 * Hero headline for a facility.
 *
 * Prefers genuine operator copy. Otherwise builds "Self Storage in City, ST",
 * which is the phrase the business needs to rank for. Falls back to the
 * facility name when there is no usable location, since a name beats a generic
 * slogan.
 */
export function resolveHeroHeadline(params: {
  configured?: unknown;
  facilityName?: string;
  location?: string | null;
}): string {
  const configured = String(params.configured || '').trim();
  if (configured && !PLACEHOLDER_HEADLINES.has(configured.toLowerCase())) {
    return configured;
  }
  if (params.location) return `Self Storage in ${params.location}`;
  return String(params.facilityName || '').trim() || 'Self Storage';
}

/** True when the hero image is missing, so onboarding can insist on a real photo. */
export function isHeroImagePlaceholder(heroImageUrl: unknown): boolean {
  const url = String(heroImageUrl || '').trim();
  return url.length === 0;
}
