import assert from 'node:assert/strict';
import test from 'node:test';
import { tenantUnitLabel } from '@sfc/functions-shared';
import {
  buildRentReminderMessage,
  CalendarDate,
  calendarDateIn,
  claimActionFor,
  clampReminderDays,
  creditCoversRent,
  daysBetween,
  decideRentReminder,
  dueDateKey,
  hasSmsConsent,
  localDateTimeIn,
  MAX_REMINDER_DAYS,
  MIN_REMINDER_DAYS,
  RentReminderTenant,
  runSendAttempt,
  selectReminderFromNumber,
  upcomingDueDate,
} from '../rentReminderHelpers';
import { facilityLocalHour, readReminderSettings, rentReminderTenantFromDoc } from '../rentReminderSms';

const TZ = 'America/Chicago';
const SEP_28: CalendarDate = { year: 2026, month: 9, day: 28 }; // 3 days before 1 Oct

/** An instant that is local midnight on [y-m-d] in Chicago (CDT, UTC-5). */
function chicagoMidnight(y: number, m: number, d: number): Date {
  return new Date(Date.UTC(y, m - 1, d, 5, 0));
}

function tenant(overrides: Partial<RentReminderTenant> = {}): RentReminderTenant {
  return {
    id: 't1',
    name: 'Alexa Rau',
    phone: '406-555-0100',
    isActive: true,
    paidThrough: chicagoMidnight(2026, 9, 30), // paid through 30 Sep: up to date, Oct not paid
    smsOptOut: false,
    smsOptInDate: new Date(2026, 8, 1),
    monthlyRate: 130,
    unitNumber: '2',
    lastSmsPaymentReminderDate: null,
    lastSmsPaymentReminderDueDate: null,
    ...overrides,
  };
}

function decide(t: RentReminderTenant, today: CalendarDate = SEP_28, reminderDays = 3) {
  return decideRentReminder({ tenant: t, reminderDays, today, timeZone: TZ });
}

test('consent is recognised in either recorded shape', () => {
  assert.equal(hasSmsConsent(tenant()), true);
  assert.equal(hasSmsConsent(tenant({ smsOptInDate: null, smsConsentStatus: 'opted_in' })), true);
  assert.equal(hasSmsConsent(tenant({ smsOptInDate: null, smsConsentStatus: null })), false);
});

test('an opt-out beats a recorded consent', () => {
  assert.equal(hasSmsConsent(tenant({ smsOptOut: true, smsConsentStatus: 'opted_in' })), false);
  assert.equal(hasSmsConsent(tenant({ smsConsentStatus: 'opted_out' })), false);
});

test('the due date is the next 1st, or today on the 1st', () => {
  assert.deepEqual(upcomingDueDate(SEP_28), { year: 2026, month: 10, day: 1 });
  assert.deepEqual(upcomingDueDate({ year: 2026, month: 12, day: 20 }), { year: 2027, month: 1, day: 1 });
  assert.deepEqual(upcomingDueDate({ year: 2026, month: 10, day: 1 }), { year: 2026, month: 10, day: 1 });
  assert.equal(dueDateKey({ year: 2026, month: 10, day: 1 }), '2026-10-01');
});

// The bug this fixes: a paid-up tenant owes nothing before the 1st, and the old
// job required a positive balance, so nobody was reminded before rent was due.
test('a paid-up tenant gets the pre-due reminder', () => {
  const decision = decide(tenant());
  assert.equal(decision.send, true);
  assert.deepEqual(decision.dueDate, { year: 2026, month: 10, day: 1 });
  assert.equal(decision.dueKey, '2026-10-01');
});

test('a tenant imported from a rent roll (no paidThrough) is reminded', () => {
  assert.equal(decide(tenant({ paidThrough: null })).send, true);
});

test('a tenant in arrears is still reminded about the coming 1st', () => {
  // Paid through July: the old job computed a due date of 1 Aug, which never
  // matched "3 days from today" again.
  assert.equal(decide(tenant({ paidThrough: chicagoMidnight(2026, 7, 31) })).send, true);
});

test('a tenant paid ahead is skipped', () => {
  for (const paidThrough of [chicagoMidnight(2026, 10, 31), chicagoMidnight(2026, 10, 1), chicagoMidnight(2027, 3, 31)]) {
    const decision = decide(tenant({ paidThrough }));
    assert.equal(decision.send, false, paidThrough.toISOString());
    assert.equal(decision.reason, 'paid-ahead');
  }
});

test('paidThrough is read as a local date, so a UTC timestamp does not tip it over', () => {
  // Written by a client as local midnight 30 Sep: 05:00 UTC. Still Sep 30.
  assert.equal(decide(tenant({ paidThrough: new Date('2026-09-30T05:00:00Z') })).send, true);
  // 31 Oct local, written from a zone ahead of UTC (30 Oct 14:00 UTC).
  assert.equal(decide(tenant({ paidThrough: new Date('2026-10-30T14:00:00Z') })).reason, 'paid-ahead');
});

test('a ledger credit that covers the month counts as paid ahead', () => {
  assert.equal(creditCoversRent(-130, 130), true);
  assert.equal(creditCoversRent(-200, 130), true);
  assert.equal(creditCoversRent(-129.99, 130), false);
  assert.equal(creditCoversRent(0, 130), false);
  assert.equal(creditCoversRent(260, 130), false);
  assert.equal(creditCoversRent(Number.NaN, 130), false);
});

test('sends only on the day that matches the facility lead time', () => {
  assert.equal(decide(tenant(), SEP_28, 3).send, true);
  assert.equal(decide(tenant(), SEP_28, 5).reason, 'not-due');
  assert.equal(decide(tenant(), { year: 2026, month: 9, day: 26 }, 5).send, true);
  // Zero days before: on the 1st itself.
  assert.equal(decide(tenant(), { year: 2026, month: 10, day: 1 }, 0).send, true);
  assert.equal(decide(tenant(), { year: 2026, month: 10, day: 1 }, 3).reason, 'not-due');
});

test('no phone, no consent, opted out, inactive, no rate and no unit are each refused', () => {
  const cases: Array<[Partial<RentReminderTenant>, string]> = [
    [{ phone: '' }, 'no-phone'],
    [{ smsOptInDate: null, smsConsentStatus: null }, 'no-consent'],
    [{ smsOptOut: true }, 'opted-out'],
    [{ isActive: false }, 'inactive'],
    // A doc with no isActive is not an active tenant anywhere else.
    [{ isActive: undefined }, 'inactive'],
    [{ monthlyRate: 0 }, 'no-rate'],
    [{ monthlyRate: null }, 'no-rate'],
    [{ unitNumber: '' }, 'no-unit'],
    [{ unitNumber: '   ' }, 'no-unit'],
    [{ unitNumber: null }, 'no-unit'],
  ];
  for (const [overrides, reason] of cases) {
    const decision = decide(tenant(overrides));
    assert.equal(decision.send, false, reason);
    assert.equal(decision.reason, reason);
  }
});

test('one reminder per tenant per due date', () => {
  const decision = decide(tenant({ lastSmsPaymentReminderDueDate: '2026-10-01' }));
  assert.equal(decision.send, false);
  assert.equal(decision.reason, 'already-reminded');
  // Changing the lead time mid-month does not earn a second text.
  const later = decide(tenant({ lastSmsPaymentReminderDueDate: '2026-10-01' }), { year: 2026, month: 9, day: 30 }, 1);
  assert.equal(later.reason, 'already-reminded');
});

test('a reminder already sent today by the previous version is not repeated', () => {
  const decision = decide(tenant({ lastSmsPaymentReminderDate: new Date('2026-09-28T14:00:00Z') }));
  assert.equal(decision.reason, 'already-reminded');
});

test('a reminder sent for last month does not block this month', () => {
  const decision = decide(
    tenant({
      lastSmsPaymentReminderDueDate: '2026-09-01',
      lastSmsPaymentReminderDate: new Date('2026-08-29T14:00:00Z'),
    }),
  );
  assert.equal(decision.send, true);
});

test('days are counted by calendar date', () => {
  assert.equal(daysBetween(SEP_28, { year: 2026, month: 10, day: 1 }), 3);
  assert.equal(daysBetween({ year: 2026, month: 12, day: 31 }, { year: 2027, month: 1, day: 1 }), 1);
  assert.equal(daysBetween({ year: 2026, month: 3, day: 7 }, { year: 2026, month: 3, day: 9 }), 2); // DST week
});

test('the facility local date, not the UTC date, decides the day', () => {
  // 04:00 UTC on 29 Sep is still 11pm on 28 Sep in Chicago.
  const now = new Date('2026-09-29T04:00:00Z');
  assert.deepEqual(calendarDateIn(TZ, now), SEP_28);
  assert.deepEqual(localDateTimeIn(TZ, now), { ...SEP_28, hour: 23 });
  assert.equal(decide(tenant(), calendarDateIn(TZ, now), 3).send, true);
  // By UTC it would already be 29 Sep, two days out, and no one would be texted.
  assert.equal(decide(tenant(), { year: 2026, month: 9, day: 29 }, 3).reason, 'not-due');
});

test('the message names the facility, the unit, the amount and the date', () => {
  const body = buildRentReminderMessage({
    facilityName: 'Caprock Storage',
    tenantName: 'Doug Devoy',
    amount: 130,
    dueDate: { year: 2026, month: 10, day: 1 },
    unitNumber: '2',
  });
  assert.equal(body, 'Caprock Storage: Hi Doug, a reminder that rent for unit 2 of $130.00 is due Oct 1.');
  assert.ok(body.length < 160 - 40, 'leaves room for the STOP footer in one segment');
});

test('the message still reads well with no name and no unit', () => {
  const body = buildRentReminderMessage({
    tenantName: '',
    amount: 90.5,
    dueDate: new Date(2026, 9, 1),
    unitNumber: null,
  });
  assert.equal(body, 'a reminder that rent of $90.50 is due Oct 1.');
});

test('texting is on only when the operator chose sms or both', () => {
  assert.equal(readReminderSettings({}).enabled, false);
  assert.equal(readReminderSettings({ billingSettings: { paymentReminderChannel: 'email' } }).enabled, false);
  assert.equal(readReminderSettings({ billingSettings: { paymentReminderChannel: 'sms' } }).enabled, true);
  assert.equal(readReminderSettings({ billingSettings: { paymentReminderChannel: 'both' } }).enabled, true);
  assert.equal(
    readReminderSettings({
      billingSettings: { paymentReminderChannel: 'sms', enablePaymentReminders: false },
    }).enabled,
    false,
  );
});

test('lead time and send hour fall back to sane values', () => {
  const defaults = readReminderSettings({ billingSettings: { paymentReminderChannel: 'sms' } });
  assert.equal(defaults.reminderDays, 3);
  assert.equal(defaults.sendHour, 9);

  const configured = readReminderSettings({
    billingSettings: { paymentReminderChannel: 'sms', paymentReminderDays: 5, sendTimeHour: 17 },
  });
  assert.equal(configured.reminderDays, 5);
  assert.equal(configured.sendHour, 17);
});

test('a facility is texted at its own local hour, not the server hour', () => {
  // 15:00 UTC is 9am in Denver and 10am in Chicago.
  const now = new Date(Date.UTC(2026, 8, 28, 15, 0));
  assert.equal(facilityLocalHour('America/Denver', now), 9);
  assert.equal(facilityLocalHour('America/Chicago', now), 10);
  // Midnight is 0, not 24.
  assert.equal(facilityLocalHour('America/Chicago', new Date('2026-09-28T05:00:00Z')), 0);
});

test('an unknown time zone does not throw', () => {
  const now = new Date(Date.UTC(2026, 8, 28, 15, 0));
  assert.equal(typeof facilityLocalHour('Not/AZone', now), 'number');
});

test('a tenant doc is active only when isActive is exactly true', () => {
  const doc = {
    name: 'Alexa Rau',
    phone: '406-555-0100',
    paidThrough: chicagoMidnight(2026, 9, 30),
    smsOptInDate: new Date(2026, 8, 1),
    monthlyRate: 130,
    unitNumber: '2',
  };
  assert.equal(rentReminderTenantFromDoc('t1', { ...doc, isActive: true }).isActive, true);
  assert.equal(decide(rentReminderTenantFromDoc('t1', { ...doc, isActive: true })).send, true);
  for (const isActive of [undefined, false, 'true']) {
    const t = rentReminderTenantFromDoc('t1', { ...doc, isActive });
    assert.equal(t.isActive, false, String(isActive));
    assert.equal(decide(t).reason, 'inactive');
  }
});

test('a tenant doc carries the unit number and the due-date dedupe key', () => {
  const t = rentReminderTenantFromDoc('t1', {
    unitNumber: 12,
    lastSmsPaymentReminderDueDate: '2026-10-01',
  });
  assert.equal(t.unitNumber, '12');
  assert.equal(t.lastSmsPaymentReminderDueDate, '2026-10-01');
  assert.equal(rentReminderTenantFromDoc('t1', {}).unitNumber, null);
});

test('the text keeps the plain unit number until the facility numbers units per area', () => {
  const tenantDoc = { unitNumber: '12', unitArea: 'Complex 2' };
  const message = (facility: Record<string, unknown>) =>
    buildRentReminderMessage({
      tenantName: 'Doug Devoy',
      amount: 130,
      dueDate: new Date(2026, 9, 1),
      unitNumber: tenantUnitLabel(tenantDoc, facility),
    });
  const before = 'Hi Doug, a reminder that rent for unit 12 of $130.00 is due Oct 1.';
  assert.equal(message({}), before);
  assert.equal(message({ unitNumbersRepeatAcrossAreas: false }), before);
  assert.equal(
    message({ unitNumbersRepeatAcrossAreas: true }),
    'Hi Doug, a reminder that rent for unit 12 (Complex 2) of $130.00 is due Oct 1.',
  );
});

test('with the setting on, a tenant with no area still gets the plain number', () => {
  const body = buildRentReminderMessage({
    tenantName: 'Doug Devoy',
    amount: 130,
    dueDate: new Date(2026, 9, 1),
    unitNumber: tenantUnitLabel({ unitNumber: '12', unitArea: null }, { unitNumbersRepeatAcrossAreas: true }),
  });
  assert.equal(body, 'Hi Doug, a reminder that rent for unit 12 of $130.00 is due Oct 1.');
});

test('reminders use the facility number only with the same approvals sendSMS requires', () => {
  const platformNumber = '+18555264544';
  const facilityNumber = '+19035009941';
  const approved = {
    textingOnboardingEnabled: true,
    a2pStatus: 'approved',
    textingPlatformApproved: true,
  };
  const pick = (facilityData: Record<string, unknown>, flag = true, own: string | null = facilityNumber) =>
    selectReminderFromNumber({ platformNumber, facilityNumber: own, textingOnboardingFlag: flag, facilityData });

  assert.equal(pick(approved), facilityNumber);
  // Carrier-approved but not approved by a super admin: shared number.
  assert.equal(pick({ ...approved, textingPlatformApproved: false }), platformNumber);
  assert.equal(pick({ ...approved, textingPlatformApproved: undefined }), platformNumber);
  // Onboarding off for the platform or for the facility: shared number.
  assert.equal(pick(approved, false), platformNumber);
  assert.equal(pick({ ...approved, textingOnboardingEnabled: false }), platformNumber);
  // Not carrier-approved, or no number of its own: shared number.
  assert.equal(pick({ ...approved, a2pStatus: 'draft' }), platformNumber);
  assert.equal(pick(approved, true, null), platformNumber);
  assert.equal(pick(approved, true, '  '), platformNumber);
});

test('a tenant in arrears is told the rent and the current balance', () => {
  const body = buildRentReminderMessage({
    facilityName: 'Caprock Storage',
    tenantName: 'Doug Devoy',
    amount: 130,
    balance: 130,
    dueDate: { year: 2026, month: 10, day: 1 },
    unitNumber: '2',
  });
  assert.equal(
    body,
    'Caprock Storage: Hi Doug, a reminder that rent for unit 2 of $130.00 is due Oct 1. Balance now: $130.00.',
  );
  const footer = '\n\nReply STOP to opt out. Reply HELP for help.';
  assert.ok((body + footer).length <= 306, 'two segments at most');
});

test('no balance line when nothing is owed', () => {
  for (const balance of [0, -50, null, undefined, Number.NaN, 0.001]) {
    const body = buildRentReminderMessage({
      facilityName: 'Caprock Storage',
      tenantName: 'Doug',
      amount: 130,
      balance,
      dueDate: { year: 2026, month: 10, day: 1 },
      unitNumber: '2',
    });
    assert.ok(!body.includes('Balance'), String(balance));
  }
});

test('the longest plausible reminder stays within two segments', () => {
  const body = buildRentReminderMessage({
    facilityName: 'A Very Long Facility Name Self Storage And RV',
    tenantName: 'Bartholomew Longname',
    amount: 1234.56,
    balance: 98765.43,
    dueDate: { year: 2026, month: 12, day: 1 },
    unitNumber: 'B-1024 (Complex 12)',
  });
  assert.ok((body + '\n\nReply STOP to opt out. Reply HELP for help.').length <= 306);
});

test('the lead time is clamped to 1..27 so every month is reachable', () => {
  assert.equal(clampReminderDays(3), 3);
  assert.equal(clampReminderDays(27), 27);
  assert.equal(clampReminderDays(28), 27);
  assert.equal(clampReminderDays(30), 27);
  assert.equal(clampReminderDays(0), 1);
  assert.equal(clampReminderDays(-4), 1);
  assert.equal(clampReminderDays('5'), 5);
  assert.equal(clampReminderDays(undefined), 3);
  assert.equal(clampReminderDays('x'), 3);
  assert.equal(
    readReminderSettings({ billingSettings: { paymentReminderChannel: 'sms', paymentReminderDays: 30 } }).reminderDays,
    27,
  );
});

test('27 days ahead reaches the 1st after even the shortest month', () => {
  // 1 Mar 2027 is 28 days after 1 Feb; 27 days before it is 2 Feb.
  const decision = decide(tenant({ paidThrough: null }), { year: 2027, month: 2, day: 2 }, 27);
  assert.equal(decision.send, true);
  assert.equal(decision.dueKey, '2027-03-01');
  // Every lead time from 1 to 27 lands on exactly one day of February.
  for (let days = MIN_REMINDER_DAYS; days <= MAX_REMINDER_DAYS; days++) {
    let hits = 0;
    for (let d = 1; d <= 28; d++) {
      if (decide(tenant({ paidThrough: null }), { year: 2027, month: 2, day: d }, days).send) hits += 1;
    }
    assert.equal(hits, 1, `days=${days}`);
  }
});

test('the claim is released unless the text may have gone out', () => {
  assert.equal(claimActionFor('sent'), 'mark-sent');
  assert.equal(claimActionFor('blocked'), 'release');
  assert.equal(claimActionFor('failed'), 'release');
  assert.equal(claimActionFor('error-before-request'), 'release');
  assert.equal(claimActionFor('error-after-request'), 'keep');
});

test('a send attempt reports whether it reached the provider before failing', async () => {
  assert.deepEqual(await runSendAttempt(async () => 'sent' as const), { outcome: 'sent' });
  const quota = await runSendAttempt(async () => {
    // reservePlatformOutgoing refusing, before any request is made.
    throw new Error('resource-exhausted');
  });
  assert.equal(quota.outcome, 'error-before-request');
  assert.equal(claimActionFor(quota.outcome), 'release');
  const network = await runSendAttempt(async (markRequestStarted) => {
    markRequestStarted();
    throw new Error('socket hang up');
  });
  assert.equal(network.outcome, 'error-after-request');
  assert.equal(claimActionFor(network.outcome), 'keep');
});
