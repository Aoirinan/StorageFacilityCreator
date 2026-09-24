import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildRentReminderMessage,
  daysUntil,
  decideRentReminder,
  hasSmsConsent,
  nextRentDueDate,
  RentReminderTenant,
} from '../rentReminderHelpers';
import { facilityLocalHour, readReminderSettings, rentReminderTenantFromDoc } from '../rentReminderSms';

function tenant(overrides: Partial<RentReminderTenant> = {}): RentReminderTenant {
  return {
    id: 't1',
    name: 'Alexa Rau',
    phone: '406-555-0100',
    isActive: true,
    paidThrough: new Date(2026, 8, 30), // 30 Sep 2026
    smsOptOut: false,
    smsOptInDate: new Date(2026, 8, 1),
    monthlyRate: 130,
    lastSmsPaymentReminderDate: null,
    ...overrides,
  };
}

test('consent is recognised in either recorded shape', () => {
  assert.equal(hasSmsConsent(tenant()), true);
  assert.equal(
    hasSmsConsent(tenant({ smsOptInDate: null, smsConsentStatus: 'opted_in' })),
    true,
  );
  assert.equal(hasSmsConsent(tenant({ smsOptInDate: null, smsConsentStatus: null })), false);
});

test('an opt-out beats a recorded consent', () => {
  assert.equal(hasSmsConsent(tenant({ smsOptOut: true, smsConsentStatus: 'opted_in' })), false);
});

test('rent is due the first of the month after the one paid through', () => {
  const due = nextRentDueDate(new Date(2026, 8, 30), new Date(2026, 8, 28));
  assert.equal(due.getFullYear(), 2026);
  assert.equal(due.getMonth(), 9); // October
  assert.equal(due.getDate(), 1);
});

test('December rolls into January of the next year', () => {
  const due = nextRentDueDate(new Date(2026, 11, 31), new Date(2026, 11, 20));
  assert.equal(due.getFullYear(), 2027);
  assert.equal(due.getMonth(), 0);
});

test('a tenant imported from a rent roll is billed from the coming month, not skipped', () => {
  // The email reminder skips anyone without paidThrough, which is every row of
  // an imported rent roll, so those tenants never heard from us at all.
  const due = nextRentDueDate(null, new Date(2026, 8, 21));
  assert.equal(due.getMonth(), 9);
  assert.equal(due.getDate(), 1);

  const decision = decideRentReminder({
    tenant: tenant({ paidThrough: null }),
    balance: 130,
    reminderDays: 10,
    now: new Date(2026, 8, 21),
  });
  assert.equal(decision.send, true);
});

test('sends only on the day that matches the facility lead time', () => {
  const now = new Date(2026, 8, 28); // 3 days before 1 Oct
  assert.equal(
    decideRentReminder({ tenant: tenant(), balance: 130, reminderDays: 3, now }).send,
    true,
  );
  assert.equal(
    decideRentReminder({ tenant: tenant(), balance: 130, reminderDays: 5, now }).send,
    false,
  );
});

test('a settled account gets no reminder', () => {
  const decision = decideRentReminder({
    tenant: tenant(),
    balance: 0,
    reminderDays: 3,
    now: new Date(2026, 8, 28),
  });
  assert.equal(decision.send, false);
  assert.equal(decision.reason, 'nothing-owed');
});

test('no phone, no consent and inactive are each refused', () => {
  const now = new Date(2026, 8, 28);
  const cases: Array<[Partial<RentReminderTenant>, string]> = [
    [{ phone: '' }, 'no-phone'],
    [{ smsOptInDate: null, smsConsentStatus: null }, 'no-consent'],
    [{ smsOptOut: true }, 'opted-out'],
    [{ isActive: false }, 'inactive'],
    // A doc with no isActive is not an active tenant anywhere else.
    [{ isActive: undefined }, 'inactive'],
  ];
  for (const [overrides, reason] of cases) {
    const decision = decideRentReminder({
      tenant: tenant(overrides),
      balance: 130,
      reminderDays: 3,
      now,
    });
    assert.equal(decision.send, false, reason);
    assert.equal(decision.reason, reason);
  }
});

test('the same rent is never texted about twice', () => {
  const now = new Date(2026, 8, 28);
  const decision = decideRentReminder({
    tenant: tenant({ lastSmsPaymentReminderDate: now }),
    balance: 130,
    reminderDays: 3,
    now,
  });
  assert.equal(decision.send, false);
  assert.equal(decision.reason, 'already-reminded');
});

test('a reminder sent for last month does not block this month', () => {
  const now = new Date(2026, 8, 28);
  const decision = decideRentReminder({
    tenant: tenant({ lastSmsPaymentReminderDate: new Date(2026, 7, 29) }),
    balance: 130,
    reminderDays: 3,
    now,
  });
  assert.equal(decision.send, true);
});

test('days are counted by calendar date, not by elapsed hours', () => {
  // 11pm to 1am is two hours but one day, and the job runs hourly.
  const due = new Date(2026, 9, 1, 1, 0);
  const now = new Date(2026, 8, 28, 23, 0);
  assert.equal(daysUntil(due, now), 3);
});

test('the message names the unit, the amount and the date', () => {
  const body = buildRentReminderMessage({
    tenantName: 'Doug Devoy',
    amount: 130,
    dueDate: new Date(2026, 9, 1),
    unitNumber: '2',
  });
  assert.equal(body, 'Hi Doug, a reminder that rent for unit 2 of $130.00 is due Oct 1.');
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
  assert.equal(
    readReminderSettings({ billingSettings: { paymentReminderChannel: 'email' } }).enabled,
    false,
  );
  assert.equal(
    readReminderSettings({ billingSettings: { paymentReminderChannel: 'sms' } }).enabled,
    true,
  );
  assert.equal(
    readReminderSettings({ billingSettings: { paymentReminderChannel: 'both' } }).enabled,
    true,
  );
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
});

test('an unknown time zone does not throw', () => {
  const now = new Date(Date.UTC(2026, 8, 28, 15, 0));
  assert.equal(typeof facilityLocalHour('Not/AZone', now), 'number');
});

test('a tenant doc is active only when isActive is exactly true', () => {
  const now = new Date(2026, 8, 28);
  const doc = {
    name: 'Alexa Rau',
    phone: '406-555-0100',
    paidThrough: new Date(2026, 8, 30),
    smsOptInDate: new Date(2026, 8, 1),
    monthlyRate: 130,
  };
  assert.equal(rentReminderTenantFromDoc('t1', { ...doc, isActive: true }).isActive, true);
  // Before: `data.isActive !== false`, so a partial doc read as active here
  // and as inactive in the app and every other job.
  for (const isActive of [undefined, false, 'true']) {
    const tenant = rentReminderTenantFromDoc('t1', { ...doc, isActive });
    assert.equal(tenant.isActive, false, String(isActive));
    assert.equal(
      decideRentReminder({ tenant, balance: 130, reminderDays: 3, now }).reason,
      'inactive',
    );
  }
});
