import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildAccountApprovedEmail,
  buildAccountUnderReviewEmail,
  buildNewAccountAdminAlertEmail,
} from '../email/ownerOnboardingEmails';

const base = {
  ownerName: 'Alexa Rau',
  appUrl: 'https://app.storagefacilitycreator.com',
  supportEmail: 'support@storagefacilitycreator.com',
  supportPhone: '855-526-4544',
};

const approved = {
  ...base,
  trialEndDate: new Date('2026-10-21T03:30:06Z'),
  priceMonthly: 75,
  onlineRentalsAddonMonthly: 25,
};

test('under-review email tells the owner what happens next', () => {
  const m = buildAccountUnderReviewEmail(base);
  assert.equal(m.subject, 'We got your Storage Facility Creator signup');
  assert.match(m.text, /Hi Alexa,/);
  assert.match(m.text, /under review/);
  assert.match(m.text, /one business day/);
  // The pending-approval screen promises this next step; the copy must honour it.
  assert.match(m.text, /the moment it is approved/);
  assert.match(m.html, /support@storagefacilitycreator\.com/);
  assert.match(m.text, /855-526-4544/);
});

test('greeting uses the first name only, and degrades without one', () => {
  assert.match(buildAccountUnderReviewEmail(base).text, /^Hi Alexa,/);
  assert.match(buildAccountUnderReviewEmail({ ...base, ownerName: null }).text, /^Hi,/);
  assert.match(buildAccountUnderReviewEmail({ ...base, ownerName: '   ' }).text, /^Hi,/);
});

test('approved email carries the trial end, sign-in link and all three steps', () => {
  const m = buildAccountApprovedEmail(approved);
  assert.equal(m.subject, 'Your account is approved, here is how to get set up');
  assert.match(m.text, /October 21, 2026/);
  assert.match(m.text, /do not need to enter a card/);
  assert.match(m.text, /https:\/\/app\.storagefacilitycreator\.com/);
  assert.match(m.text, /1\. Create your facility/);
  assert.match(m.text, /2\. Add your units/);
  assert.match(m.text, /3\. Bring your tenants over/);
  // The bulk-unit toggle and the CSV import are the two things that save an
  // owner a whole evening; both must survive a copy edit.
  assert.match(m.text, /Create multiple units/);
  assert.match(m.text, /Import CSV/);
});

test('approved email states the price, the free first month and the add-on', () => {
  const m = buildAccountApprovedEmail(approved);
  assert.match(m.text, /\$75 per facility per month/);
  assert.match(m.text, /your first month is free/);
  assert.match(m.text, /\$25 per month/);
  assert.match(m.html, /\$75 per facility per month/);
});

test('approved email never promises that balances import', () => {
  const m = buildAccountApprovedEmail(approved);
  assert.match(m.text, /balances are entered after the import rather than imported/i);
  assert.equal(/import .{0,20}balances/i.test(m.text), false);
});

test('admin alert names the account and links to Platform Control', () => {
  const m = buildNewAccountAdminAlertEmail({
    ownerName: 'Alexa Rau',
    ownerEmail: 'caprockstorage@gmail.com',
    accountId: 'lWTHn3AYXiIVwv7nizPK',
    signedUpAt: new Date('2026-09-20T22:21:47Z'),
    superAdminUrl: 'https://app.storagefacilitycreator.com/#/super-admin',
  });
  assert.equal(m.subject, 'New account pending approval: caprockstorage@gmail.com');
  assert.match(m.text, /Alexa Rau signed up at/);
  assert.match(m.text, /lWTHn3AYXiIVwv7nizPK/);
  assert.match(m.text, /super-admin/);
});

test('admin alert falls back to the email when no name was given', () => {
  const m = buildNewAccountAdminAlertEmail({
    ownerName: null,
    ownerEmail: 'someone@example.com',
    accountId: 'acct1',
    signedUpAt: new Date('2026-09-20T22:21:47Z'),
    superAdminUrl: 'https://example.com/#/super-admin',
  });
  assert.match(m.text, /^someone@example\.com signed up at/);
});

test('owner-supplied names are escaped, so a name cannot inject markup', () => {
  const m = buildAccountApprovedEmail({ ...approved, ownerName: '<script>alert(1)</script> Bob' });
  assert.equal(m.html.includes('<script>'), false);
  assert.match(m.html, /&lt;script&gt;/);
});

test('these are platform emails: no facility unsubscribe furniture', () => {
  for (const m of [buildAccountUnderReviewEmail(base), buildAccountApprovedEmail(approved)]) {
    assert.equal(/unsubscribe/i.test(m.html), false);
    assert.equal(/unsubscribe/i.test(m.text), false);
  }
});
