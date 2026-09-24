import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION,
  PUBLIC_PAYMENT_LINKS_COLLECTION,
} from '@sfc/functions-shared/stripe/completePublicLinkPayment';
import { PURGE_ROOT_COLLECTIONS } from '../superAdminPlatformPurge';

// The ops script is plain CommonJS outside src/; load it the way `npm run security:cleanup` does.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const cleanup = require('../../scripts/security-hardening-cleanup.cjs') as {
  rotatedLinkData: (
    current: Record<string, unknown>,
    replacementToken: string,
    rotatedFrom: string,
    rotatedAt: unknown,
  ) => Record<string, unknown>;
};

test('platform purge deletes payment links and their exception records', () => {
  const purged: readonly string[] = PURGE_ROOT_COLLECTIONS;
  assert.ok(purged.includes(PUBLIC_PAYMENT_LINKS_COLLECTION));
  // Tenant ids, amounts and connected-account ids: customer data like the links.
  assert.ok(purged.includes(PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION));
});

test('a rotated payment link keeps the link but not the old token\'s checkout session', () => {
  const current = {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    description: 'October rent',
    token: 'legacy-token',
    status: 'pending',
    expiresAt: 'later',
    checkoutSessionId: 'cs_live_old',
    checkoutSessionIds: ['cs_live_old'],
    checkoutAttempt: 2,
    checkoutExpiresAt: 'soon',
  };

  const rotated = cleanup.rotatedLinkData(current, 'a'.repeat(48), 'legacy-token', 'now');

  assert.deepEqual(rotated, {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    description: 'October rent',
    token: 'a'.repeat(48),
    status: 'pending',
    expiresAt: 'later',
    rotatedFrom: 'legacy-token',
    rotatedAt: 'now',
  });
  // The source document is left as it was (it is revoked separately).
  assert.equal(current.checkoutSessionId, 'cs_live_old');
});
