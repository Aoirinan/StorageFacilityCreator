/**
 * Deciding who gets a rent reminder text, and what it says.
 *
 * Kept free of the Admin SDK and Twilio so the rules can be tested directly:
 * everything here takes plain values and returns a decision.
 */

export interface RentReminderTenant {
  /** Firestore id, used only for logging by the caller. */
  id: string;
  name?: string | null;
  phone?: string | null;
  isActive?: boolean;
  /** Last month fully paid. Unset for a tenant imported from a rent roll. */
  paidThrough?: Date | null;
  smsOptOut?: boolean;
  smsOptInDate?: Date | null;
  /** Written by the operator screens as an alternative to smsOptInDate. */
  smsConsentStatus?: string | null;
  monthlyRate?: number | null;
  lastSmsPaymentReminderDate?: Date | null;
}

export type SkipReason =
  | 'inactive'
  | 'no-phone'
  | 'no-consent'
  | 'opted-out'
  | 'not-due'
  | 'nothing-owed'
  | 'already-reminded';

export interface ReminderDecision {
  send: boolean;
  reason?: SkipReason;
  dueDate?: Date;
}

/**
 * A tenant has consented if either shape of the record says so. The operator
 * screens write `smsOptInDate` plus `smsOptOut: false`; the older flow wrote
 * `smsConsentStatus: 'opted_in'`. Reading only one of them left tenants who
 * had signed the consent box untextable.
 */
export function hasSmsConsent(tenant: RentReminderTenant): boolean {
  if (tenant.smsOptOut === true) return false;
  if (tenant.smsConsentStatus && tenant.smsConsentStatus.toLowerCase() === 'opted_in') return true;
  return tenant.smsOptInDate instanceof Date;
}

/**
 * The first of the month after the last one they have paid for.
 *
 * A tenant with no `paidThrough` — every tenant imported from a rent roll —
 * is billed from the first of the coming month rather than skipped. The email
 * reminder skips them, which is why a freshly imported rent roll never
 * produced a single reminder.
 */
export function nextRentDueDate(paidThrough: Date | null | undefined, now: Date): Date {
  if (!paidThrough) {
    const firstOfNextMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    return firstOfNextMonth;
  }
  return new Date(paidThrough.getFullYear(), paidThrough.getMonth() + 1, 1);
}

/** Whole days from [now] to [due], counting only the calendar date. */
export function daysUntil(due: Date, now: Date): number {
  const dueMidnight = Date.UTC(due.getFullYear(), due.getMonth(), due.getDate());
  const nowMidnight = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  return Math.round((dueMidnight - nowMidnight) / (24 * 60 * 60 * 1000));
}

/**
 * Whether this tenant should get a text today.
 *
 * [balance] is what they owe; zero or less means the month is settled and no
 * reminder goes out. [reminderDays] is how many days ahead of the due date the
 * facility wants the nudge.
 */
export function decideRentReminder(params: {
  tenant: RentReminderTenant;
  balance: number;
  reminderDays: number;
  now: Date;
}): ReminderDecision {
  const { tenant, balance, reminderDays, now } = params;

  // Exactly true, as the app and every server job read a tenant's isActive.
  if (tenant.isActive !== true) return { send: false, reason: 'inactive' };
  if (!tenant.phone || !tenant.phone.trim()) return { send: false, reason: 'no-phone' };
  if (tenant.smsOptOut === true) return { send: false, reason: 'opted-out' };
  if (!hasSmsConsent(tenant)) return { send: false, reason: 'no-consent' };

  const dueDate = nextRentDueDate(tenant.paidThrough ?? null, now);
  if (daysUntil(dueDate, now) !== reminderDays) {
    return { send: false, reason: 'not-due', dueDate };
  }

  if (balance <= 0) return { send: false, reason: 'nothing-owed', dueDate };

  // One reminder per due date, so a retry or a second run of the job cannot
  // text the same tenant twice about the same rent.
  const lastSent = tenant.lastSmsPaymentReminderDate;
  if (lastSent && daysUntil(dueDate, lastSent) === reminderDays) {
    return { send: false, reason: 'already-reminded', dueDate };
  }

  return { send: true, dueDate };
}

/** Formats a due date the way a tenant reads it: "Oct 1". */
export function formatDueDate(due: Date): string {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${months[due.getMonth()]} ${due.getDate()}`;
}

/**
 * The reminder text itself. The facility name is prefixed by the send path
 * when the shared number is used, and the STOP/HELP footer is appended there
 * too, so neither belongs here.
 */
export function buildRentReminderMessage(params: {
  tenantName?: string | null;
  amount: number;
  dueDate: Date;
  unitNumber?: string | null;
}): string {
  const { tenantName, amount, dueDate, unitNumber } = params;
  const firstName = (tenantName || '').trim().split(/\s+/)[0];
  const greeting = firstName ? `Hi ${firstName}, ` : '';
  const unit = unitNumber && unitNumber.trim() ? ` for unit ${unitNumber.trim()}` : '';
  return (
    `${greeting}a reminder that rent${unit} of $${amount.toFixed(2)} ` +
    `is due ${formatDueDate(dueDate)}.`
  );
}
