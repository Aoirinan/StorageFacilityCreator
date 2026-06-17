/**
 * Regression tests for portalAuth client IP extraction and failure lockout buckets.
 *
 * Skipped (already covered elsewhere):
 * - tenantsSharePortalAccount — portalAccountLink.test.ts
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import { extractCallableClientIp } from '../portal/portalAuth';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

function loadPortalAuthModule() {
  const inMemory = new InMemoryFirestore();
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const portalAuth = require('../portal/portalAuth') as typeof import('../portal/portalAuth');
  return { inMemory, portalAuth };
}

test('extractCallableClientIp prefers rawRequest.ip over X-Forwarded-For', () => {
  const rawRequest = {
    ip: '10.0.0.1',
    headers: { 'x-forwarded-for': '203.0.113.99' },
    connection: { remoteAddress: '127.0.0.1' },
  };

  assert.equal(
    extractCallableClientIp(rawRequest as unknown as functions.https.Request),
    '10.0.0.1',
  );
});

test('recordPortalAuthFailure accumulates one bucket per email+IP and locks out after five failures', async () => {
  const { inMemory, portalAuth } = loadPortalAuthModule();
  const email = 'tenant@example.com';
  const ip = '192.168.1.10';

  for (let i = 0; i < 5; i += 1) {
    await portalAuth.recordPortalAuthFailure(email, ip);
  }

  const lockoutDocs = [...inMemory.getStore().keys()].filter((key) =>
    key.startsWith('rateLimits/portalAuth_'),
  );
  const lockoutData = [...inMemory.getStore().entries()].find(
    ([, value]) => typeof value.lockedUntil === 'number' && (value.lockedUntil as number) > Date.now(),
  );
  assert.ok(lockoutData, 'expected a lockout document after five failures');

  await assert.rejects(
    () => portalAuth.enforcePortalAuthRateLimit(email, ip),
    (err: unknown) => {
      assert.ok(err instanceof functions.https.HttpsError);
      assert.equal(err.code, 'resource-exhausted');
      assert.match(err.message, /too many failed attempts/i);
      return true;
    },
  );

  assert.ok(lockoutDocs.length >= 1);
});

test('recordPortalAuthFailure uses separate buckets per client IP', async () => {
  const { portalAuth } = loadPortalAuthModule();
  const email = 'tenant@example.com';
  const ipA = '192.168.1.10';
  const ipB = '192.168.1.20';

  for (let i = 0; i < 5; i += 1) {
    await portalAuth.recordPortalAuthFailure(email, ipA);
  }

  await assert.rejects(
    () => portalAuth.enforcePortalAuthRateLimit(email, ipA),
    (err: unknown) => err instanceof functions.https.HttpsError,
  );

  await portalAuth.recordPortalAuthFailure(email, ipB);
  await portalAuth.enforcePortalAuthRateLimit(email, ipB);
});
