import test from 'node:test';
import assert from 'node:assert/strict';

import { decideFacilityAccountLink } from '../platform/facilityAccountLink';

const ME = 'owner-uid';
const MY_ACCOUNT = 'acct_mine';

function decide(overrides: Record<string, unknown> = {}) {
  return decideFacilityAccountLink({
    callerUid: ME,
    accountId: MY_ACCOUNT,
    facility: { ownerUid: ME },
    account: { ownerUid: ME },
    ...overrides,
  } as Parameters<typeof decideFacilityAccountLink>[0]);
}

test('an owner may link their own new facility to their own account', () => {
  // The ordinary signup path: this is what broke when the field was locked.
  const d = decide();
  assert.deepEqual(d, { ok: true, alreadyLinked: false });
});

test('re-running the link is fine and reports it was already done', () => {
  const d = decide({ facility: { ownerUid: ME, facilityCreatorAccountId: MY_ACCOUNT } });
  assert.deepEqual(d, { ok: true, alreadyLinked: true });
});

test('an owner cannot attach their facility to somebody else paying account', () => {
  // The entitlement theft the Firestore rule exists to stop: checking only the
  // facility's owner would let this through.
  const d = decide({ account: { ownerUid: 'someone-else' } });
  assert.equal(d.ok, false);
  assert.equal((d as { code: string }).code, 'permission-denied');
});

test('an owner cannot link a facility they do not own', () => {
  const d = decide({ facility: { ownerUid: 'someone-else' } });
  assert.equal(d.ok, false);
  assert.equal((d as { code: string }).code, 'permission-denied');
});

test('a facility already pointed at another account is not re-pointed', () => {
  const d = decide({ facility: { ownerUid: ME, facilityCreatorAccountId: 'acct_someone_paying' } });
  assert.equal(d.ok, false);
  assert.equal((d as { code: string }).code, 'already-linked');
});

test('missing records are refused rather than assumed', () => {
  assert.equal((decide({ facility: null }) as { code: string }).code, 'not-found');
  assert.equal((decide({ account: null }) as { code: string }).code, 'not-found');
  assert.equal((decide({ accountId: '  ' }) as { code: string }).code, 'not-found');
});

test('an unauthenticated caller is refused', () => {
  assert.equal((decide({ callerUid: '' }) as { code: string }).code, 'permission-denied');
});

test('ownership comparison tolerates stored whitespace', () => {
  const d = decide({ facility: { ownerUid: `  ${ME} ` }, account: { ownerUid: `${ME}  ` } });
  assert.equal(d.ok, true);
});
