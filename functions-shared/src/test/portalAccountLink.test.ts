import test from 'node:test';
import assert from 'node:assert/strict';
import {
  tenantsSharePortalAccount,
  buildTenantPortalPaymentIntentMetadata,
} from '../portal/portalAccountLink';

test('tenantsSharePortalAccount matches portalAccountId when both set', () => {
  const auth = { portalAccountId: 'acct-1', emailLower: 'a@test.com', portalAccessCode: 'ABCD1234' };
  const same = { portalAccountId: 'acct-1', emailLower: 'a@test.com', portalEnabled: true, portalAccessCode: 'ABCD1234' };
  const other = { portalAccountId: 'acct-2', emailLower: 'a@test.com', portalEnabled: true, portalAccessCode: 'ABCD1234' };
  assert.equal(tenantsSharePortalAccount(auth, same, 'a@test.com', 'ABCD1234'), true);
  assert.equal(tenantsSharePortalAccount(auth, other, 'a@test.com', 'ABCD1234'), false);
});

test('tenantsSharePortalAccount falls back to email + access code', () => {
  const auth = { emailLower: 'a@test.com', portalAccessCode: 'ABCD1234' };
  const linked = { emailLower: 'a@test.com', portalEnabled: true, portalAccessCode: 'ABCD1234' };
  const wrongCode = { emailLower: 'a@test.com', portalEnabled: true, portalAccessCode: 'WRONG123' };
  assert.equal(tenantsSharePortalAccount(auth, linked, 'a@test.com', 'ABCD1234'), true);
  assert.equal(tenantsSharePortalAccount(auth, wrongCode, 'a@test.com', 'ABCD1234'), false);
});

test('buildTenantPortalPaymentIntentMetadata includes webhook fields', () => {
  assert.deepEqual(buildTenantPortalPaymentIntentMetadata('fac1', 'ten1'), {
    facilityId: 'fac1',
    tenantId: 'ten1',
    type: 'tenant_portal_payment',
  });
});
