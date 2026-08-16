import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildA2PRejectionReason,
  parseA2PErrors,
} from '../twilio/a2pFailureDetails';

// --- parsing ----------------------------------------------------------------

test('parseA2PErrors reads Twilio\'s error_code/description shape', () => {
  const errors = [
    {
      error_code: 30909,
      description:
        'Campaign Verification: CTA/message flow could not be verified. Provide the exact URL where users sign up.',
    },
  ];
  assert.deepEqual(parseA2PErrors(errors), [
    {
      code: '30909',
      description:
        'Campaign Verification: CTA/message flow could not be verified. Provide the exact URL where users sign up.',
    },
  ]);
});

test('parseA2PErrors tolerates the alternate field names Twilio uses', () => {
  assert.deepEqual(parseA2PErrors([{ code: '30907', message: 'Website URL validation issue' }]), [
    { code: '30907', description: 'Website URL validation issue' },
  ]);
});

test('parseA2PErrors ignores junk without throwing', () => {
  assert.deepEqual(parseA2PErrors(undefined), []);
  assert.deepEqual(parseA2PErrors(null), []);
  assert.deepEqual(parseA2PErrors('nope'), []);
  assert.deepEqual(parseA2PErrors([null, 'x', 42, {}]), []);
});

// --- reason building --------------------------------------------------------

test('buildA2PRejectionReason surfaces the real carrier error, not just the status', () => {
  const reason = buildA2PRejectionReason({
    campaignStatus: 'FAILED',
    campaignErrors: [
      { error_code: 30909, description: 'CTA/message flow could not be verified.' },
    ],
  });
  assert.ok(reason);
  assert.match(reason!, /30909/);
  assert.match(reason!, /CTA\/message flow/);
});

test('buildA2PRejectionReason joins multiple carrier errors', () => {
  const reason = buildA2PRejectionReason({
    campaignStatus: 'FAILED',
    campaignErrors: [
      { error_code: 30909, description: 'CTA could not be verified.' },
      { error_code: 30933, description: 'Privacy Policy URL is required.' },
    ],
  });
  assert.match(reason!, /30909/);
  assert.match(reason!, /30933/);
});

test('buildA2PRejectionReason falls back to the brand failureReason', () => {
  const reason = buildA2PRejectionReason({
    brandStatus: 'FAILED',
    brandFailureReason: 'EIN does not match IRS records.',
  });
  assert.equal(reason, 'EIN does not match IRS records.');
});

test('buildA2PRejectionReason falls back to the status when Twilio gives nothing else', () => {
  const reason = buildA2PRejectionReason({ campaignStatus: 'FAILED' });
  assert.ok(reason);
  assert.match(reason!, /FAILED/);
  assert.match(reason!, /Twilio Console/);
});

test('buildA2PRejectionReason returns null when nothing failed', () => {
  // So a recovered facility gets the stale reason cleared rather than keeping
  // an old rejection on screen forever.
  assert.equal(buildA2PRejectionReason({ campaignStatus: 'APPROVED' }), null);
  assert.equal(buildA2PRejectionReason({ brandStatus: 'PENDING' }), null);
  assert.equal(buildA2PRejectionReason({}), null);
});

test('buildA2PRejectionReason truncates pathological payloads', () => {
  const reason = buildA2PRejectionReason({
    campaignStatus: 'FAILED',
    campaignErrors: [{ error_code: 1, description: 'x'.repeat(5000) }],
  });
  assert.ok(reason!.length <= 1500, `reason was ${reason!.length} chars`);
  assert.ok(reason!.endsWith('…'));
});
