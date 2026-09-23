import assert from 'node:assert/strict';
import test from 'node:test';
import { buildA2PAdminAlertEmail, describeA2PTransition } from '../a2pAdminAlerts';

const kinds = (before: Record<string, unknown>, after: Record<string, unknown>) =>
  describeA2PTransition(before, after).map((a) => a.kind);

test('no alert when nothing registration-related changed', () => {
  const doc = { a2pStatus: 'pending', a2pBundleReady: true, name: 'Keepsake' };
  assert.deepEqual(kinds(doc, { ...doc, occupiedUnits: 73 }), []);
});

test('business details that pass the pre-check alert as submitted', () => {
  assert.deepEqual(kinds({ a2pStatus: 'draft' }, { a2pStatus: 'draft', a2pBundleReady: true }), ['bundle_submitted']);
});

test('re-saving an already submitted profile does not re-alert', () => {
  const doc = { a2pBundleReady: true };
  assert.deepEqual(kinds(doc, { ...doc }), []);
});

test('failed pre-check alerts once per distinct issue', () => {
  const failed = { a2pBundleReady: false, a2pBundleIssues: 'Address invalid' };
  assert.deepEqual(kinds({}, failed), ['bundle_failed_check']);
  assert.deepEqual(kinds(failed, { ...failed }), []);
});

test('bundle approval and rejection from the hourly poll', () => {
  assert.deepEqual(kinds({ a2pBundleReady: true }, { a2pBundleReady: true, a2pBundleApproved: true }), [
    'bundle_approved',
  ]);
  assert.deepEqual(
    kinds(
      { a2pBundleProfileStatus: 'pending-review' },
      { a2pBundleProfileStatus: 'twilio-rejected', a2pBundleReady: false },
    ),
    ['bundle_rejected'],
  );
});

test('campaign status transitions', () => {
  assert.deepEqual(kinds({ a2pStatus: 'draft' }, { a2pStatus: 'submitted' }), ['campaign_submitted']);
  assert.deepEqual(kinds({ a2pStatus: 'pending' }, { a2pStatus: 'approved' }), ['campaign_approved']);
  const rejected = describeA2PTransition(
    { a2pStatus: 'pending' },
    { a2pStatus: 'rejected', a2pRejectionReason: 'EIN does not match IRS records.' },
  );
  assert.deepEqual(rejected.map((a) => a.kind), ['campaign_rejected']);
  assert.ok(rejected[0].detail.some((d) => d.includes('EIN does not match IRS records.')));
  // submitted -> pending is Twilio picking it up, not news.
  assert.deepEqual(kinds({ a2pStatus: 'submitted' }, { a2pStatus: 'pending' }), []);
  // resetting to draft after a rejection is the owner's action, not news.
  assert.deepEqual(kinds({ a2pStatus: 'rejected' }, { a2pStatus: 'draft' }), []);
});

test('email names the facility and never carries tax IDs', () => {
  const facility = {
    name: 'Keepsake Self Storage',
    textingBusinessData: { legalBusinessName: 'Keepsake LLC', einLast4: '6789' },
  };
  const email = buildA2PAdminAlertEmail('fac1', facility, describeA2PTransition({}, { a2pStatus: 'approved' }));
  assert.match(email.subject, /Keepsake Self Storage/);
  assert.match(email.text, /Keepsake LLC/);
  assert.match(email.text, /fac1/);
  assert.doesNotMatch(email.text, /6789/);
});
