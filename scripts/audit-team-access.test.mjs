// node --test scripts/audit-team-access.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import { auditTeamAccess, parseArgs } from './audit-team-access.mjs';

const facility = (id, data) => ({ id, data: { ownerUid: 'owner', roles: { owner: 'owner' }, ...data } });
const invite = (facilityId, id, data) => ({
  id,
  facilityId,
  data: { facilityId, emailLower: `${id}@example.com`, roleType: 'employee', status: 'accepted', ...data },
});
const row = (id, data) => ({
  id,
  data: { facilityId: 'f1', roleType: 'employee', isActive: true, ...data },
});

const kinds = (result) => result.findings.map((f) => f.kind).sort();

test('a team written the way the app writes it has no findings', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'employee', u2: 'manager' } })],
    invites: [invite('f1', 'i1', { acceptedBy: 'u1' }), invite('f1', 'i2', { status: 'pending' })],
    roleRows: [
      row('r-owner', { userId: 'owner', roleType: 'owner' }),
      row('r1', { userId: 'u1', inviteId: 'i1' }),
      row('r2', { userId: 'u2', roleType: 'manager' }),
      // A removed member: their row is out of use and they are in no map.
      row('r3', { userId: 'u3', isActive: false, inviteId: 'i9' }),
    ],
  });
  assert.deepEqual(result.findings, []);
  assert.deepEqual(result.counts, {});
});

test('an invite stored under one facility that names another', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1')],
    invites: [invite('f1', 'i1', { facilityId: 'theirs', status: 'accepted', acceptedBy: 'u1' })],
    roleRows: [],
  });
  assert.deepEqual(result.findings, [
    {
      kind: 'invite-moved',
      facilityId: 'f1',
      inviteId: 'i1',
      namedFacilityId: 'theirs',
      status: 'accepted',
      roleType: 'employee',
      emailLower: 'i1@example.com',
      acceptedBy: 'u1',
    },
  ]);

  // Moved and then reopened (the owner's removal could not cancel it): both.
  const reopened = auditTeamAccess({
    facilities: [facility('f1')],
    invites: [invite('f1', 'i1', { facilityId: 'theirs', status: 'pending', acceptedBy: 'u1' })],
    roleRows: [],
  });
  assert.deepEqual(kinds(reopened), ['invite-moved', 'invite-reopened']);
});

test('an active row whose invite is still pending, or gone', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'employee', u2: 'employee' } })],
    invites: [invite('f1', 'i1', { status: 'pending' })],
    roleRows: [row('r1', { userId: 'u1', inviteId: 'i1' }), row('r2', { userId: 'u2', inviteId: 'i-deleted' })],
  });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.uid, f.inviteId, f.inviteStatus]),
    [
      ['row-invite-unspent', 'u1', 'i1', 'pending'],
      ['row-invite-unspent', 'u2', 'i-deleted', 'missing'],
    ],
  );
});

test('a map entry with no active row, in either map; the owner needs none', () => {
  const result = auditTeamAccess({
    facilities: [
      facility('f1', { roles: { owner: 'owner', u1: 'viewer' }, managers: { u2: true, u3: false } }),
    ],
    invites: [],
    roleRows: [row('r-old', { userId: 'u1', isActive: false, roleType: 'viewer' })],
  });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.uid, f.role]),
    [
      ['map-entry-without-row', 'u1', 'viewer'],
      ['map-entry-without-row', 'u2', 'manager'],
    ],
  );
});

test('an active row for someone in neither map', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1'), facility('f2')],
    invites: [],
    roleRows: [row('r1', { userId: 'u1', roleType: 'manager' }), row('r-owner', { userId: 'owner', roleType: 'owner' })],
  });
  assert.deepEqual(result.findings, [
    { kind: 'row-without-map-entry', facilityId: 'f1', uid: 'u1', rows: [{ rowId: 'r1', roleType: 'manager', inviteId: null }] },
  ]);
});

test("rows that disagree with each other or with the roles map", () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'viewer', u2: 'viewer' } })],
    invites: [],
    roleRows: [
      row('a', { userId: 'u1', roleType: 'viewer' }),
      row('b', { userId: 'u1', roleType: 'manager' }),
      row('c', { userId: 'u2', roleType: 'manager' }),
    ],
  });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.uid, f.mapRole, f.rows.map((r) => r.roleType)]),
    [
      ['role-mismatch', 'u1', 'viewer', ['viewer', 'manager']],
      ['role-mismatch', 'u2', 'viewer', ['manager']],
    ],
  );
});

test("an owner or admin entry for anyone but the facility's owner", () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'owner', u2: 'admin' } })],
    invites: [],
    roleRows: [row('r1', { userId: 'u1', roleType: 'owner' }), row('r2', { userId: 'u2', roleType: 'admin' })],
  });
  assert.deepEqual(kinds(result), ['owner-or-admin-grant', 'owner-or-admin-grant']);
  assert.deepEqual(result.counts, { 'owner-or-admin-grant': 2 });
});

test('a pending invite that records an acceptance was reopened', () => {
  // Moved back to its own facility after being reopened, it no longer shows
  // as invite-moved; the acceptance it kept is what gives it away.
  const result = auditTeamAccess({
    facilities: [facility('f1')],
    invites: [
      invite('f1', 'i1', { status: 'pending', roleType: 'manager', acceptedBy: 'u1' }),
      invite('f1', 'i2', { status: 'pending', acceptedAt: new Date() }),
      invite('f1', 'i3', { status: 'pending' }),
      invite('f1', 'i4', { status: 'accepted', acceptedBy: 'u4' }),
    ],
    roleRows: [],
  });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.inviteId, f.roleType, f.acceptedBy]),
    [
      ['invite-reopened', 'i1', 'manager', 'u1'],
      ['invite-reopened', 'i2', 'employee', null],
    ],
  );
});

test('one invite behind two role rows, the removed one included', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'manager' } })],
    invites: [invite('f1', 'i1', { acceptedBy: 'u1', roleType: 'manager' }), invite('f1', 'i2', { acceptedBy: 'u2' })],
    roleRows: [
      row('r-removed', { userId: 'u1', roleType: 'viewer', isActive: false, inviteId: 'i1' }),
      row('r-back', { userId: 'u1', roleType: 'manager', inviteId: 'i1' }),
      // The same invite id at another facility is another invite.
      row('r-other', { userId: 'u2', facilityId: 'f2', inviteId: 'i1', isActive: false }),
      row('r2', { userId: 'u2', inviteId: 'i2', isActive: false }),
    ],
  });
  assert.deepEqual(result.findings, [
    {
      kind: 'invite-reused',
      facilityId: 'f1',
      inviteId: 'i1',
      rows: [
        { rowId: 'r-removed', uid: 'u1', roleType: 'viewer', isActive: false },
        { rowId: 'r-back', uid: 'u1', roleType: 'manager', isActive: true },
      ],
    },
  ]);
});

// What the owner's facility looks like once someone has joined by invite,
// written the way the backend writes it.
const invited = (id, data) =>
  facility(id, {
    acceptingInviteId: 'i1',
    facilityCreatorAccountId: 'acct-owner',
    ownerAccountStanding: { accountId: 'acct-owner', subscriptionStatus: 'active', suspended: false },
    platformSubscriptionStatus: 'active',
    stripePlatformSubscriptionId: 'sub_1',
    ...data,
  });
const ownersAccount = { id: 'acct-owner', data: { ownerUid: 'owner', subscriptionStatus: 'active' } };

test('a facility someone joined by invite, as the backend writes it, has no findings', () => {
  const result = auditTeamAccess({
    facilities: [
      invited('f1', {
        websiteSubscriptionStatus: 'active',
        stripeWebsiteSubscriptionId: 'sub_w',
        stripeConnectAccountId: 'acct_1',
      }),
      // A website on an admin trial has no subscription.
      invited('f2', { websiteSubscriptionStatus: 'trialing', websiteAdminTrialEndsAt: new Date() }),
      // The same owner's facilities may share their Connect account.
      facility('f3', { stripeConnectAccountId: 'acct_1' }),
    ],
    invites: [],
    roleRows: [],
    accounts: [ownersAccount],
  });
  assert.deepEqual(result.findings, []);
});

test('a facility whose ownerUid was taken off', () => {
  const result = auditTeamAccess({
    facilities: [{ id: 'f1', data: { roles: { u1: 'employee' }, acceptingInviteId: 'i1' } }],
    invites: [],
    roleRows: [row('r1', { userId: 'u1' })],
  });
  assert.deepEqual(
    result.findings.filter((f) => f.kind === 'facility-without-owner'),
    [{ kind: 'facility-without-owner', facilityId: 'f1', acceptingInviteId: 'i1' }],
  );
  assert.deepEqual(kinds(auditTeamAccess({ facilities: [facility('f2', { ownerUid: '', roles: {} })], invites: [], roleRows: [] })), [
    'facility-without-owner',
  ]);
});

test('what an invitee could add to, or take off, the facility they accepted an invite to', () => {
  const cases = {
    'billing-exempt': { billingExempt: true },
    'platform-active-without-subscription': { stripePlatformSubscriptionId: undefined },
    'website-active-without-subscription': { websiteSubscriptionStatus: 'trialing' },
    'no-owner-account-standing': { ownerAccountStanding: undefined },
    'account-of-another-owner': { facilityCreatorAccountId: 'acct-paying-stranger' },
    'texting-approved': { textingPlatformApproved: true },
  };
  for (const [reason, data] of Object.entries(cases)) {
    const result = auditTeamAccess({
      facilities: [invited('f1', data)],
      invites: [],
      roleRows: [],
      accounts: [ownersAccount, { id: 'acct-paying-stranger', data: { ownerUid: 'stranger' } }],
    });
    assert.deepEqual(
      result.findings.map((f) => [f.kind, f.reasons]),
      [['entitlement-on-invited-facility', [reason]]],
      reason,
    );
  }
  // An account that is not there at all is not the owner's either.
  const missing = auditTeamAccess({
    facilities: [invited('f1', { facilityCreatorAccountId: 'acct-gone' })],
    invites: [],
    roleRows: [],
    accounts: [ownersAccount],
  });
  assert.deepEqual(missing.findings[0].reasons, ['account-of-another-owner']);
  assert.equal(missing.findings[0].fields.facilityCreatorAccountId, 'acct-gone');

  // A facility nobody accepted an invite to could not be changed this way.
  const notInvited = auditTeamAccess({
    facilities: [facility('f1', { billingExempt: true, platformSubscriptionStatus: 'active' })],
    invites: [],
    roleRows: [],
  });
  assert.deepEqual(notInvited.findings, []);
});

test('a Connect account on facilities with different owners, even one outside --facility', () => {
  const all = [
    facility('f1', { stripeConnectAccountId: 'acct_x' }),
    facility('f2', { ownerUid: 'stranger', roles: { stranger: 'owner' }, stripeConnectAccountId: 'acct_x' }),
    facility('f3', { stripeConnectAccountId: 'acct_y' }),
  ];
  const result = auditTeamAccess({ facilities: all, invites: [], roleRows: [] });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.facilityId, f.sharedWith.map((h) => h.facilityId)]),
    [
      ['connect-account-shared', 'f1', ['f2']],
      ['connect-account-shared', 'f2', ['f1']],
    ],
  );
  const narrowed = auditTeamAccess({ facilities: [all[0]], invites: [], roleRows: [], allFacilities: all });
  assert.deepEqual(
    narrowed.findings.map((f) => [f.kind, f.facilityId]),
    [['connect-account-shared', 'f1']],
  );
});

test('a legacy managers entry for someone the roles map gives a lower role', () => {
  const result = auditTeamAccess({
    facilities: [
      facility('f1', {
        roles: { owner: 'owner', u1: 'employee', u2: 'manager', u3: 'viewer' },
        managers: { u1: true, u2: true, u3: false, owner: true },
      }),
    ],
    invites: [],
    roleRows: [
      row('r1', { userId: 'u1' }),
      row('r2', { userId: 'u2', roleType: 'manager' }),
      row('r3', { userId: 'u3', roleType: 'viewer' }),
    ],
  });
  assert.deepEqual(result.findings, [{ kind: 'legacy-manager-grant', facilityId: 'f1', uid: 'u1', mapRole: 'employee' }]);
});

test('a role row whose address is not the one its invite was sent to', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1', { roles: { owner: 'owner', u1: 'employee', u2: 'employee' } })],
    invites: [invite('f1', 'i1', { acceptedBy: 'u1' }), invite('f1', 'i2', { acceptedBy: 'u2' })],
    roleRows: [
      row('r1', { userId: 'u1', inviteId: 'i1', userEmail: 'victim@example.com' }),
      // The invite's own address, in any case, is fine.
      row('r2', { userId: 'u2', inviteId: 'i2', userEmail: 'I2@Example.com' }),
    ],
  });
  assert.deepEqual(result.findings, [
    {
      kind: 'row-email-not-invitee',
      facilityId: 'f1',
      uid: 'u1',
      rowId: 'r1',
      inviteId: 'i1',
      userEmail: 'victim@example.com',
      inviteEmailLower: 'i1@example.com',
    },
  ]);
});

test('an accepted invite that records a cancellation', () => {
  const result = auditTeamAccess({
    facilities: [facility('f1')],
    invites: [
      invite('f1', 'i1', { acceptedBy: 'u1', cancelledReason: 'access_removed', cancelledAt: new Date() }),
      invite('f1', 'i2', { acceptedBy: 'u2', cancelledAt: new Date() }),
      invite('f1', 'i3', { status: 'cancelled', cancelledReason: 'access_removed' }),
    ],
    roleRows: [],
  });
  assert.deepEqual(
    result.findings.map((f) => [f.kind, f.inviteId, f.acceptedBy, f.cancelledReason]),
    [
      ['invite-uncancelled', 'i1', 'u1', 'access_removed'],
      ['invite-uncancelled', 'i2', 'u2', null],
    ],
  );
});

test('arguments: facilities to narrow to, project and out; nothing else', () => {
  assert.deepEqual(parseArgs(['--facility', 'a', '--facility', 'b', '--project', 'p', '--out', 'o']), {
    facilities: ['a', 'b'],
    project: 'p',
    outDir: 'o',
  });
  assert.deepEqual(parseArgs([]), { facilities: [], project: null, outDir: null });
  assert.throws(() => parseArgs(['--apply']), /Unknown argument/);
  assert.throws(() => parseArgs(['--facility']), /needs a value/);
});
