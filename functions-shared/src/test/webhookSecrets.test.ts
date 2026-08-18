import test from 'node:test';
import assert from 'node:assert/strict';
import { parseWebhookSecrets, verifyWithAnySecret } from '../stripe/webhookSecrets';

const A = 'whsec_aaaaaaaaaaaaaaaa';
const B = 'whsec_bbbbbbbbbbbbbbbb';

// --- parsing ----------------------------------------------------------------

test('parseWebhookSecrets reads one secret', () => {
  assert.deepEqual(parseWebhookSecrets(A), [A]);
});

test('parseWebhookSecrets reads several from one value or several values', () => {
  assert.deepEqual(parseWebhookSecrets(`${A},${B}`), [A, B]);
  assert.deepEqual(parseWebhookSecrets(`${A} ${B}`), [A, B]);
  assert.deepEqual(parseWebhookSecrets(A, B), [A, B]);
});

test('parseWebhookSecrets ignores anything that is not a signing secret', () => {
  // An unset or placeholder env var must not become a candidate secret.
  assert.deepEqual(parseWebhookSecrets('', undefined, null, 'changeme', 'sk_live_x'), []);
  assert.deepEqual(parseWebhookSecrets(`${A},not-a-secret`), [A]);
});

test('parseWebhookSecrets de-duplicates', () => {
  // Both destinations configured with the same secret should not double the work.
  assert.deepEqual(parseWebhookSecrets(A, A), [A]);
});

// --- verification -----------------------------------------------------------

test('verifyWithAnySecret returns the event from the matching secret', () => {
  const construct = (secret: string) => {
    if (secret !== B) throw new Error('bad signature');
    return { id: 'evt_1' };
  };
  const result = verifyWithAnySecret(construct, [A, B]);
  assert.deepEqual(result.event, { id: 'evt_1' });
  assert.equal(result.secretIndex, 1);
});

test('verifyWithAnySecret stops at the first match', () => {
  let calls = 0;
  const construct = () => {
    calls += 1;
    return { id: 'evt_1' };
  };
  verifyWithAnySecret(construct, [A, B]);
  assert.equal(calls, 1, 'must not keep trying after a secret verifies');
});

test('verifyWithAnySecret rethrows the real Stripe error when none match', () => {
  const construct = () => {
    throw new Error('No signatures found matching the expected signature');
  };
  assert.throws(
    () => verifyWithAnySecret(construct, [A, B]),
    /No signatures found matching/,
    'the caller should still see a real Stripe message, not a generic one',
  );
});

test('verifyWithAnySecret refuses when nothing is configured', () => {
  // Failing loudly beats treating "no secrets" as "nothing to check".
  assert.throws(
    () => verifyWithAnySecret(() => ({ id: 'evt' }), []),
    /No Stripe webhook signing secret is configured/,
  );
});
