import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildOffboardedEmail,
  buildOffboardingAdminSummaryEmail,
  buildOffboardingNoticeEmail,
  sweepSummaryHasActivity,
} from '../stripe/offboardingEmails';

const base = {
  facilityName: 'Keepsake <Self> Storage',
  ownerName: 'Dana',
  offboardingDate: new Date('2026-10-14T06:00:00Z'),
  appUrl: 'https://app.storagefacilitycreator.com',
  supportEmail: 'support@storagefacilitycreator.com',
};

test('offboarding notice says when, what is removed, and what stays yours', () => {
  const m = buildOffboardingNoticeEmail(base);
  assert.match(m.subject, /Keepsake <Self> Storage/);
  assert.match(m.text, /October 14, 2026/);
  assert.match(m.text, /Nothing has been removed yet/);
  assert.match(m.text, /Your Stripe account, your balance and your payouts are yours/);
  assert.match(m.text, /reactivate your subscription/);
  assert.match(m.text, /^Hi Dana,/);
  // HTML escapes the facility name, so the raw angle brackets never appear as tags.
  assert.equal(m.html.includes('<Self>'), false);
  assert.match(m.html, /&lt;Self&gt;/);
});

test('offboarded email states the removal is done and irreversible', () => {
  const m = buildOffboardedEmail({ ...base, ownerName: null });
  assert.match(m.subject, /tenant data removed and Stripe disconnected/);
  assert.match(m.text, /^Hi,/);
  assert.match(m.text, /completed on October 14, 2026/);
  assert.match(m.text, /cannot be restored/);
});

test('admin summary is only sent when something happened, and lists it', () => {
  const quiet = {
    runAt: new Date('2026-09-15T06:00:00Z'),
    noticesSent: [],
    offboarded: [],
    orphansDetached: [],
    waiting: 2,
    errors: [],
  };
  assert.equal(sweepSummaryHasActivity(quiet), false);

  const busy = {
    ...quiet,
    noticesSent: [{ facilityId: 'f1', facilityName: 'North Lot', offboardingDate: new Date('2026-10-15T06:00:00Z') }],
    offboarded: [{ facilityId: 'f2', facilityName: 'South Lot', tenantsRedacted: 12, stripe: 'deauthorized' }],
    orphansDetached: [{ accountId: 'acct_1', facilityId: 'gone' }],
    errors: [{ where: 'offboard f3', message: 'Rate limited' }],
  };
  assert.equal(sweepSummaryHasActivity(busy), true);
  const m = buildOffboardingAdminSummaryEmail(busy);
  assert.equal(m.subject, '[SFC] Facility offboarding: 1 offboarded, 1 notice sent, 1 orphan detached, 1 error');
  assert.match(m.text, /North Lot \(f1\), removal on October 15, 2026/);
  assert.match(m.text, /South Lot \(f2\): 12 tenants redacted, Stripe deauthorized/);
  assert.match(m.text, /acct_1 \(was facility gone\)/);
  assert.match(m.text, /offboard f3: Rate limited/);
  assert.match(m.text, /Still in grace period: 2/);
});
