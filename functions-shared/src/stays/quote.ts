/**
 * The price of a stay (spec §6.2): folio lines, tax lines and totals, in
 * integer cents.
 *
 * Each night's rate, first match wins:
 *   1. a season covering the night (its weekend rate on Fri/Sat nights, when set);
 *   2. the weekend rate, on Fri/Sat nights;
 *   3. the weekly rate, when the stay is 7 nights or more;
 *   4. the nightly rate.
 * Extra guests are charged per guest per night after `extraGuestAfter`
 * guests (adults and children); the pet fee and the cleaning fee once per
 * stay. A manager adjustment is its own line and is not taxed (tax lines
 * apply only to lodging, cleaning, pet and extra-guest charges).
 *
 * Tax, only when the facility has lodging tax turned on: per tax line,
 * floor((base × rateBps + 5000) / 10000), i.e. half-up to the cent, where
 * base is the sum of the lines the tax applies to. No rate is built in; the
 * owner enters every one.
 *
 * The listing's rates, seasons and tax lines are re-validated here, because
 * this reads a stored doc and a bad list must not turn into a wrong price.
 */
import type {
  FolioLineCode,
  StayControlsDoc,
  StayFolioLine,
  StayFolioTaxLine,
  StayListingInput,
  StayQuote,
  StaySeasonalRate,
  StayListingRates,
  Ymd,
} from './contracts';
import { diffDays, enumerateNights, isValidYmd, weekdayOfYmd } from './dates';
import {
  MAX_RATE_CENTS,
  StayValidationError,
  mmddInSeason,
  validateRates,
  validateSeasonalRates,
  validateTaxLines,
} from './validation';

export type QuoteListing = Pick<StayListingInput, 'ratesCents' | 'seasonalRates' | 'taxLines'>;

export interface QuoteParams {
  checkIn: Ymd;
  checkOut: Ymd;
  adults: number;
  children: number;
  pets: number;
  /** A manager's adjustment, positive or negative; 0 or absent adds no line. */
  adjustmentCents?: number | null;
}

/** Longer than any bookable stay; only a guard against runaway loops. */
const MAX_QUOTE_NIGHTS = 366;

/**
 * The most one stay may total ($500,000). Far above any real booking, and
 * inside the range folio.ts splits exactly.
 */
export const MAX_FOLIO_TOTAL_CENTS = 50_000_000;

/** Friday and Saturday nights. */
export function isWeekendNight(night: Ymd): boolean {
  const day = weekdayOfYmd(night);
  return day === 5 || day === 6;
}

export interface NightRate {
  /** Groups nights into one folio line. */
  key: string;
  label: string;
  cents: number;
}

/** The rate for one night of a stay that is `stayNights` long (see the header). */
export function nightRateFor(night: Ymd, stayNights: number, rates: StayListingRates, seasons: StaySeasonalRate[]): NightRate {
  const weekend = isWeekendNight(night);
  const mmdd = night.slice(5);
  const season = seasons.find((s) => mmddInSeason(mmdd, s.startMmdd, s.endMmdd));
  if (season) {
    if (weekend && season.weekendNightlyCents !== null) {
      return { key: `season_weekend:${season.id}`, label: `${season.name}, weekend nights`, cents: season.weekendNightlyCents };
    }
    return { key: `season:${season.id}`, label: season.name, cents: season.nightlyCents };
  }
  if (weekend && rates.weekendNightly !== null) {
    return { key: 'weekend', label: 'Weekend nights (Fri/Sat)', cents: rates.weekendNightly };
  }
  if (stayNights >= 7 && rates.weeklyNightly !== null) {
    return { key: 'weekly', label: 'Weekly rate (7+ nights)', cents: rates.weeklyNightly };
  }
  return { key: 'nightly', label: 'Nightly rate', cents: rates.nightly };
}

function count(value: unknown, field: string, max: number): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > max) {
    throw new StayValidationError(field, `${field} must be a whole number from 0 to ${max}.`);
  }
  return value;
}

/** Half-up tax on a non-negative base, in whole cents. */
export function taxOn(baseCents: number, rateBps: number): number {
  return Math.floor((baseCents * rateBps + 5000) / 10000);
}

export function quoteStay(
  listing: QuoteListing,
  controls: Pick<StayControlsDoc, 'lodgingTaxEnabled'>,
  params: QuoteParams,
): StayQuote {
  const rates = validateRates(listing.ratesCents);
  const seasons = validateSeasonalRates(listing.seasonalRates ?? []);
  const taxLines = validateTaxLines(listing.taxLines ?? []);

  if (!isValidYmd(params.checkIn) || !isValidYmd(params.checkOut) || params.checkIn >= params.checkOut) {
    throw new StayValidationError('checkOut', 'Check-out must be a date after check-in.');
  }
  const nights = diffDays(params.checkIn, params.checkOut);
  if (nights > MAX_QUOTE_NIGHTS) {
    throw new StayValidationError('checkOut', `A quote covers at most ${MAX_QUOTE_NIGHTS} nights.`);
  }
  const adults = count(params.adults, 'adults', 50);
  const children = count(params.children, 'children', 50);
  const pets = count(params.pets, 'pets', 20);
  const adjustment = params.adjustmentCents ?? 0;
  if (!Number.isInteger(adjustment) || Math.abs(adjustment) > MAX_RATE_CENTS) {
    throw new StayValidationError('adjustmentCents', 'The adjustment must be a whole number of cents.');
  }

  const lines: StayFolioLine[] = [];
  const line = (code: FolioLineCode, label: string, qty: number, unitCents: number) =>
    lines.push({ code, label, qty, unitCents, amountCents: qty * unitCents });

  // Lodging: one line per distinct rate, in the order the rates first occur.
  const lodging = new Map<string, NightRate & { qty: number }>();
  for (const night of enumerateNights(params.checkIn, params.checkOut)) {
    const rate = nightRateFor(night, nights, rates, seasons);
    const key = `${rate.key}@${rate.cents}`;
    const existing = lodging.get(key);
    if (existing) existing.qty++;
    else lodging.set(key, { ...rate, qty: 1 });
  }
  for (const rate of lodging.values()) line('lodging', rate.label, rate.qty, rate.cents);

  const guests = adults + children;
  if (rates.extraGuestFee > 0 && rates.extraGuestAfter >= 1 && guests > rates.extraGuestAfter) {
    const extra = guests - rates.extraGuestAfter;
    const plural = extra === 1 ? 'guest' : 'guests';
    line('extra_guest', `Extra ${plural} (${extra} × ${nights} ${nights === 1 ? 'night' : 'nights'})`, extra * nights, rates.extraGuestFee);
  }
  if (rates.cleaningFee > 0) line('cleaning', 'Cleaning fee', 1, rates.cleaningFee);
  if (pets > 0 && rates.petFee > 0) line('pet', 'Pet fee', 1, rates.petFee);
  if (adjustment !== 0) line('adjustment', 'Adjustment', 1, adjustment);

  const subtotalCents = lines.reduce((sum, l) => sum + l.amountCents, 0);
  if (subtotalCents < 0) {
    throw new StayValidationError('adjustmentCents', 'The adjustment is larger than the stay itself.');
  }

  const folioTaxLines: StayFolioTaxLine[] =
    controls.lodgingTaxEnabled === true
      ? taxLines.map((t) => {
          const applies = new Set<string>(t.appliesTo);
          const base = lines.filter((l) => applies.has(l.code)).reduce((sum, l) => sum + l.amountCents, 0);
          return { code: t.code, label: t.label, rateBps: t.rateBps, amountCents: taxOn(base, t.rateBps), remittedBy: 'owner' };
        })
      : [];
  const taxCents = folioTaxLines.reduce((sum, t) => sum + t.amountCents, 0);
  if (subtotalCents + taxCents > MAX_FOLIO_TOTAL_CENTS) {
    throw new StayValidationError('ratesCents', 'The total for this stay is too large to record. Check the rates.');
  }

  return {
    currency: 'usd',
    nights,
    lines,
    taxLines: folioTaxLines,
    subtotalCents,
    taxCents,
    totalCents: subtotalCents + taxCents,
  };
}
