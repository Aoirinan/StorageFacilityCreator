/**
 * Deciding who gets a rent reminder text, and what it says.
 *
 * Kept free of the Admin SDK and Twilio so the rules can be tested directly:
 * everything here takes plain values and returns a decision.
 *
 * Rent is charged on the 1st. The reminder goes out [reminderDays] before the
 * next 1st, at the facility's own hour, to every active, consenting tenant
 * with a rent and a unit who has not already paid for that month.
 *
 * The first version worked out the due date from `paidThrough` and then only
 * texted tenants with a positive posted balance. Before the 1st a paid-up
 * tenant owes nothing (the charge has not posted yet), and a tenant in arrears
 * has a due date in the past that never matches "N days from today", so in
 * practice the reminder reached nobody before rent was due.
 */

export interface RentReminderTenant {
  /** Firestore id, used only for logging by the caller. */
  id: string;
  name?: string | null;
  phone?: string | null;
  isActive?: boolean;
  /** Last day paid for (end of the last paid month). Unset for a rent-roll import. */
  paidThrough?: Date | null;
  smsOptOut?: boolean;
  smsOptInDate?: Date | null;
  /** Written by the operator screens as an alternative to smsOptInDate. */
  smsConsentStatus?: string | null;
  monthlyRate?: number | null;
  unitNumber?: string | null;
  /** When the last reminder text went out (legacy dedupe). */
  lastSmsPaymentReminderDate?: Date | null;
  /** The due date ("YYYY-MM-DD") the last reminder text was about. */
  lastSmsPaymentReminderDueDate?: string | null;
}

export type SkipReason =
  | 'inactive'
  | 'no-phone'
  | 'no-consent'
  | 'opted-out'
  | 'no-rate'
  | 'no-unit'
  | 'not-due'
  | 'paid-ahead'
  | 'already-reminded';

/** A date on the calendar, with no time and no zone. month is 1-12. */
export interface CalendarDate {
  year: number;
  month: number;
  day: number;
}

export interface ReminderDecision {
  send: boolean;
  reason?: SkipReason;
  dueDate?: CalendarDate;
  /** "YYYY-MM-DD" of dueDate, the idempotency key for one month's reminder. */
  dueKey?: string;
}

export const DEFAULT_TIME_ZONE = 'America/Chicago';

/**
 * A tenant has consented if either shape of the record says so. The operator
 * screens write `smsOptInDate` plus `smsOptOut: false`; the older flow wrote
 * `smsConsentStatus: 'opted_in'`. Reading only one of them left tenants who
 * had signed the consent box untextable.
 */
export function hasSmsConsent(tenant: RentReminderTenant): boolean {
  if (tenant.smsOptOut === true) return false;
  if (tenant.smsConsentStatus && tenant.smsConsentStatus.toLowerCase() === 'opted_out') return false;
  if (tenant.smsConsentStatus && tenant.smsConsentStatus.toLowerCase() === 'opted_in') return true;
  return tenant.smsOptInDate instanceof Date;
}

function zoneOrDefault(timeZone: string | null | undefined): string {
  return timeZone && timeZone.trim() ? timeZone.trim() : DEFAULT_TIME_ZONE;
}

/** Calendar date and hour of [instant] at the facility, from its IANA zone. */
export function localDateTimeIn(
  timeZone: string | null | undefined,
  instant: Date,
): CalendarDate & { hour: number } {
  const read = (zone: string) => {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: zone,
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      hourCycle: 'h23',
    }).formatToParts(instant);
    const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
    return { year: get('year'), month: get('month'), day: get('day'), hour: get('hour') % 24 };
  };
  try {
    return read(zoneOrDefault(timeZone));
  } catch {
    // An unknown zone string falls back to the platform default rather than
    // UTC: every facility today is in the US.
    return read(DEFAULT_TIME_ZONE);
  }
}

/** Calendar date of [instant] at the facility. */
export function calendarDateIn(timeZone: string | null | undefined, instant: Date): CalendarDate {
  const { year, month, day } = localDateTimeIn(timeZone, instant);
  return { year, month, day };
}

function toUtcMillis(d: CalendarDate): number {
  return Date.UTC(d.year, d.month - 1, d.day);
}

/** Whole days from [from] to [to]; positive when [to] is later. */
export function daysBetween(from: CalendarDate, to: CalendarDate): number {
  return Math.round((toUtcMillis(to) - toUtcMillis(from)) / (24 * 60 * 60 * 1000));
}

/**
 * The next 1st of the month on or after [today]. On the 1st itself that is
 * today, so a facility that reminds "0 days before" texts on the due date.
 */
export function upcomingDueDate(today: CalendarDate): CalendarDate {
  if (today.day === 1) return { ...today };
  return today.month === 12
    ? { year: today.year + 1, month: 1, day: 1 }
    : { year: today.year, month: today.month + 1, day: 1 };
}

export function dueDateKey(d: CalendarDate): string {
  return `${d.year}-${String(d.month).padStart(2, '0')}-${String(d.day).padStart(2, '0')}`;
}

/**
 * Whether this tenant should get a pre-due reminder today.
 *
 * [today] is the facility's local calendar date and [timeZone] its zone (used
 * to read paidThrough as a local date). [reminderDays] is how many days
 * ahead of the 1st the facility wants the nudge.
 */
export function decideRentReminder(params: {
  tenant: RentReminderTenant;
  reminderDays: number;
  today: CalendarDate;
  timeZone?: string | null;
}): ReminderDecision {
  const { tenant, reminderDays, today, timeZone } = params;

  // Exactly true, as the app and every server job read a tenant's isActive.
  if (tenant.isActive !== true) return { send: false, reason: 'inactive' };
  if (!tenant.phone || !tenant.phone.trim()) return { send: false, reason: 'no-phone' };
  if (tenant.smsOptOut === true) return { send: false, reason: 'opted-out' };
  if (!hasSmsConsent(tenant)) return { send: false, reason: 'no-consent' };
  if (!(Number(tenant.monthlyRate) > 0)) return { send: false, reason: 'no-rate' };
  if (!tenant.unitNumber || !String(tenant.unitNumber).trim()) return { send: false, reason: 'no-unit' };

  const dueDate = upcomingDueDate(today);
  const dueKey = dueDateKey(dueDate);
  if (daysBetween(today, dueDate) !== reminderDays) {
    return { send: false, reason: 'not-due', dueDate, dueKey };
  }

  // Paid ahead: paidThrough already reaches the due date (it is the last day
  // paid for, so paid through Oct 31 covers an Oct 1 due date; paid through
  // Sep 30 does not).
  if (tenant.paidThrough instanceof Date && !Number.isNaN(tenant.paidThrough.getTime())) {
    const paidThroughLocal = calendarDateIn(timeZone, tenant.paidThrough);
    if (daysBetween(dueDate, paidThroughLocal) >= 0) {
      return { send: false, reason: 'paid-ahead', dueDate, dueKey };
    }
  }

  // One reminder per due date, so a retry or a second run of the job cannot
  // text the same tenant twice about the same rent.
  if (tenant.lastSmsPaymentReminderDueDate === dueKey) {
    return { send: false, reason: 'already-reminded', dueDate, dueKey };
  }
  // Written by the previous version of this job, which kept only the send time.
  const lastSent = tenant.lastSmsPaymentReminderDate;
  if (lastSent instanceof Date && daysBetween(calendarDateIn(timeZone, lastSent), today) === 0) {
    return { send: false, reason: 'already-reminded', dueDate, dueKey };
  }

  return { send: true, dueDate, dueKey };
}

/**
 * Whether a credit on the tenant's ledger already covers the coming month.
 *
 * Online payments post a ledger credit without moving paidThrough, so a
 * tenant who paid ahead through the portal shows up here rather than in
 * [decideRentReminder]. [balance] is the posted balance, positive when owed.
 */
export function creditCoversRent(balance: number, monthlyRate: number): boolean {
  if (!Number.isFinite(balance) || !(monthlyRate > 0)) return false;
  return balance + monthlyRate <= 0;
}

/** Formats a due date the way a tenant reads it: "Oct 1". */
export function formatDueDate(due: CalendarDate | Date): string {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (due instanceof Date) return `${months[due.getMonth()]} ${due.getDate()}`;
  return `${months[due.month - 1]} ${due.day}`;
}

/**
 * The reminder text itself. It starts with the facility name, as the samples
 * registered with carriers do (the shared-number send path adds the name only
 * when it is missing, so it is never doubled). The STOP/HELP footer is
 * appended by the send path, so it does not belong here.
 *
 * [amount] is the month's rent. A tenant who already owes money is told the
 * current posted balance as well, so the text is not read as "$130 settles
 * it" by someone who is $260 behind.
 */
export function buildRentReminderMessage(params: {
  facilityName?: string | null;
  tenantName?: string | null;
  amount: number;
  dueDate: CalendarDate | Date;
  unitNumber?: string | null;
  balance?: number | null;
}): string {
  const { facilityName, tenantName, amount, dueDate, unitNumber, balance } = params;
  const prefix = facilityName && facilityName.trim() ? `${facilityName.trim()}: ` : '';
  const firstName = (tenantName || '').trim().split(/\s+/)[0];
  const greeting = firstName ? `Hi ${firstName}, ` : '';
  const unit = unitNumber && unitNumber.trim() ? ` for unit ${unitNumber.trim()}` : '';
  const owing =
    typeof balance === 'number' && Number.isFinite(balance) && balance >= 0.005
      ? ` Balance now: $${balance.toFixed(2)}.`
      : '';
  return (
    `${prefix}${greeting}a reminder that rent${unit} of $${amount.toFixed(2)} ` +
    `is due ${formatDueDate(dueDate)}.${owing}`
  );
}

/**
 * The lead time the job can honour. The reminder is for the next 1st, and
 * every month has at least 28 days, so 1..27 days ahead always lands in the
 * month before that 1st. 28 or more would, in short months, fall before the
 * previous 1st and never match. Out-of-range values are clamped rather than
 * dropped, so an old setting of 30 becomes 27 instead of switching reminders
 * off.
 */
export const MIN_REMINDER_DAYS = 1;
export const MAX_REMINDER_DAYS = 27;

export function clampReminderDays(value: unknown, fallback = 3): number {
  const n = Number(value);
  if (value === null || value === undefined || value === '' || !Number.isFinite(n)) return fallback;
  return Math.min(MAX_REMINDER_DAYS, Math.max(MIN_REMINDER_DAYS, Math.round(n)));
}

/**
 * What to do with a reminder's claim once the send attempt is over.
 *
 * The claim exists so a text is never sent twice. Holding it is only right
 * when the text may have gone out. An error before the Twilio request was
 * made (a Firestore read, the platform quota refusing) means nothing went
 * out, so the claim is released; otherwise that tenant silently gets no
 * reminder this month.
 */
export type ReminderAttemptOutcome =
  | 'sent'
  | 'blocked'
  | 'failed'
  | 'error-before-request'
  | 'error-after-request';

export function claimActionFor(outcome: ReminderAttemptOutcome): 'mark-sent' | 'release' | 'keep' {
  if (outcome === 'sent') return 'mark-sent';
  if (outcome === 'error-after-request') return 'keep';
  return 'release';
}

/**
 * Runs [fn], recording whether it reached the provider request (fn calls
 * markRequestStarted() just before it). Errors are returned, not thrown, with
 * that flag, so the caller can tell "certainly not sent" from "maybe sent".
 */
export async function runSendAttempt<T extends 'sent' | 'blocked' | 'failed'>(
  fn: (markRequestStarted: () => void) => Promise<T>,
): Promise<{ outcome: ReminderAttemptOutcome; error?: unknown }> {
  let requestStarted = false;
  try {
    const result = await fn(() => {
      requestStarted = true;
    });
    return { outcome: result };
  } catch (error) {
    return { outcome: requestStarted ? 'error-after-request' : 'error-before-request', error };
  }
}

/**
 * Which number an automated reminder goes out on.
 *
 * The facility's own number only when sendSMS would use it without an
 * override: texting onboarding on (platform flag and facility), the carrier
 * registration approved, and a super admin's platform approval recorded.
 * This used to switch to the facility's number as soon as a2pStatus read
 * 'approved', ignoring platform approval and the onboarding flag, so the
 * automated path could send from a number the operator's own Send button
 * refuses. Anything short of that uses the shared platform number.
 */
export function selectReminderFromNumber(params: {
  platformNumber: string;
  facilityNumber?: string | null;
  textingOnboardingFlag: boolean;
  facilityData: Record<string, unknown>;
}): string {
  const { platformNumber, textingOnboardingFlag, facilityData } = params;
  const facilityNumber = String(params.facilityNumber ?? '').trim();
  const onboardingEnabled = textingOnboardingFlag && facilityData?.textingOnboardingEnabled === true;
  const a2pApproved = String(facilityData?.a2pStatus ?? 'draft').toLowerCase() === 'approved';
  const platformApproved = facilityData?.textingPlatformApproved === true;
  if (onboardingEnabled && a2pApproved && platformApproved && facilityNumber) return facilityNumber;
  return platformNumber;
}
