import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_GRACE_PERIOD_DAYS,
  DEFAULT_LATE_FEE_AMOUNT,
  DEFAULT_TIME_ZONE,
  FacilityForOwnerError,
  buildFacilityForOwner,
  buildOwnerRoleRow,
} from '../platform/facilityForOwner';

const SUPER = 'super-admin-uid';
const OWNER = 'owner-uid';

test('the facility belongs to the owner, never to the super admin who made it', () => {
  const doc = buildFacilityForOwner({ ownerUid: OWNER, name: 'Caprock Storage' }, SUPER);
  assert.equal(doc.ownerUid, OWNER);
  // The creator is recorded, but gets no role from this write.
  assert.equal(doc.createdBySuperAdminUid, SUPER);
  assert.equal(Object.keys(doc.roles).includes(SUPER), false);
  assert.deepEqual(doc.roles, { [OWNER]: 'owner' });
});

test('a name and an owner are enough; everything else defaults', () => {
  const doc = buildFacilityForOwner({ ownerUid: OWNER, name: 'Caprock Storage' }, SUPER);
  assert.equal(doc.active, true);
  assert.equal(doc.totalUnits, 0);
  assert.equal(doc.occupiedUnits, 0);
  assert.equal(doc.timeZone, DEFAULT_TIME_ZONE);
  assert.deepEqual(doc.billingSettings, {
    gracePeriodDays: DEFAULT_GRACE_PERIOD_DAYS,
    lateFeeAmount: DEFAULT_LATE_FEE_AMOUNT,
    lateFeeType: 'flat',
  });
});

test('supplied details are carried through and trimmed', () => {
  const doc = buildFacilityForOwner(
    {
      ownerUid: `  ${OWNER} `,
      name: '  Caprock Storage  ',
      address: ' 820 N Sargent Ave ',
      phone: ' 406-939-1228 ',
      email: ' caprockstorage@gmail.com ',
      timeZone: 'America/Denver',
      totalUnits: 86,
      gracePeriodDays: 10,
      lateFeeAmount: 20,
    },
    SUPER,
  );
  assert.equal(doc.ownerUid, OWNER);
  assert.equal(doc.name, 'Caprock Storage');
  assert.equal(doc.address, '820 N Sargent Ave');
  assert.equal(doc.phone, '406-939-1228');
  assert.equal(doc.email, 'caprockstorage@gmail.com');
  assert.equal(doc.timeZone, 'America/Denver');
  assert.equal(doc.totalUnits, 86);
  assert.equal(doc.billingSettings?.gracePeriodDays, 10);
  assert.equal(doc.billingSettings?.lateFeeAmount, 20);
});

test('blank optional fields are omitted rather than written empty', () => {
  const doc = buildFacilityForOwner(
    { ownerUid: OWNER, name: 'X', address: '   ', phone: '', email: null },
    SUPER,
  );
  assert.equal('address' in doc, false);
  assert.equal('phone' in doc, false);
  assert.equal('email' in doc, false);
});

test('nonsense numbers fall back instead of corrupting billing', () => {
  const doc = buildFacilityForOwner(
    { ownerUid: OWNER, name: 'X', totalUnits: -5, gracePeriodDays: NaN, lateFeeAmount: -1 },
    SUPER,
  );
  assert.equal(doc.totalUnits, 0);
  assert.equal(doc.billingSettings?.gracePeriodDays, DEFAULT_GRACE_PERIOD_DAYS);
  assert.equal(doc.billingSettings?.lateFeeAmount, DEFAULT_LATE_FEE_AMOUNT);
});

test('unit counts are whole units', () => {
  const doc = buildFacilityForOwner({ ownerUid: OWNER, name: 'X', totalUnits: 86.7 }, SUPER);
  assert.equal(doc.totalUnits, 86);
});

test('the three things that cannot be guessed are required', () => {
  assert.throws(() => buildFacilityForOwner({ ownerUid: '', name: 'X' }, SUPER), FacilityForOwnerError);
  assert.throws(() => buildFacilityForOwner({ ownerUid: OWNER, name: '  ' }, SUPER), FacilityForOwnerError);
  assert.throws(() => buildFacilityForOwner({ ownerUid: OWNER, name: 'X' }, ''), FacilityForOwnerError);
});

test('the owner role row names the owner, not the creator', () => {
  const row = buildOwnerRoleRow(OWNER, 'fac1', SUPER);
  assert.equal(row.userId, OWNER);
  assert.equal(row.facilityId, 'fac1');
  assert.equal(row.roleType, 'owner');
  assert.equal(row.assignedBy, SUPER);
  assert.equal(row.isActive, true);
});
