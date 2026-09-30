import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteField, serverTimestamp } from 'firebase/firestore';
import { getBytes, ref as storageRef, uploadBytes } from 'firebase/storage';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rulesPath = join(__dirname, '..', '..', 'firestore.rules');
const rules = readFileSync(rulesPath, 'utf8');
const storageRulesPath = join(__dirname, '..', '..', 'storage.rules');
const storageRules = readFileSync(storageRulesPath, 'utf8');

const PROJECT_ID = 'sfc-rules-test';
const OWNER_UID = 'owner-user';
const STAFF_UID = 'staff-user';
const OUTSIDER_UID = 'outsider-user';
const FACILITY_ID = 'fac-test-1';
const TENANT_ID = 'tenant-test-1';

function firestoreEmulatorConfig() {
  const raw = process.env.FIRESTORE_EMULATOR_HOST || 'localhost:8080';
  const [host, portString] = raw.split(':');
  return { host, port: Number(portString) };
}

function storageEmulatorConfig() {
  const raw = process.env.FIREBASE_STORAGE_EMULATOR_HOST || 'localhost:9199';
  const [host, portString] = raw.split(':');
  return { host, port: Number(portString) };
}

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment | null} */
let testEnv = null;

test.before(async () => {
  const firestore = firestoreEmulatorConfig();
  const storage = storageEmulatorConfig();
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules, host: firestore.host, port: firestore.port },
    storage: { rules: storageRules, host: storage.host, port: storage.port },
  });
});

test.after(async () => {
  await testEnv?.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

async function seedFacility() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      roles: {
        [OWNER_UID]: 'owner',
        [STAFF_UID]: 'employee',
      },
    });
    await db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).set({
      facilityId: FACILITY_ID,
      name: 'Test Tenant',
      isActive: true,
    });
  });
}

test('rateLimits collection denies all client access', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  await assertFails(authed.firestore().collection('rateLimits').doc('global').get());
  await assertFails(
    authed.firestore().collection('rateLimits').doc('global').set({ count: 1 }),
  );
});

test('cancellationEvents denies client write and non-superadmin read', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  const ref = authed.firestore().collection('cancellationEvents').doc('evt1');
  await assertFails(ref.get());
  await assertFails(ref.set({ outcome: 'cancelled' }));
});

test('platformEmailLogs: superadmin reads, everyone else is shut out', async () => {
  // Automated owner onboarding mail. Written only by the trigger via the Admin
  // SDK, so no client may write, and only a super admin may look.
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const ownerRef = owner.collection('platformEmailLogs').doc('log1');
  await assertFails(ownerRef.get());
  await assertFails(ownerRef.set({ type: 'account_approved', to: 'a@b.com' }));

  const admin = testEnv.authenticatedContext('admin-user', { superadmin: true }).firestore();
  await assertSucceeds(admin.collection('platformEmailLogs').doc('log1').get());
  await assertSucceeds(admin.collection('platformEmailLogs').limit(5).get());
  // Even a super admin must not forge a send record; the audit trail is
  // only worth reading if nothing but the trigger can write it.
  await assertFails(admin.collection('platformEmailLogs').doc('log2').set({ status: 'sent' }));
});

test('user-scoped rateLimits denies client read and write', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  const ref = authed.firestore().collection('users').doc(OWNER_UID).collection('rateLimits').doc('otp');
  await assertFails(ref.get());
  await assertFails(ref.set({ count: 1 }));
});

test('facility rateLimits denies client access', async () => {
  await seedFacility();
  const authed = testEnv.authenticatedContext(OWNER_UID);
  const ref = authed
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('rateLimits')
    .doc('window-1');
  await assertFails(ref.get());
  await assertFails(ref.set({ count: 1 }));
});

test('facility staff can create valid manual tenant payment rows only', async () => {
  await seedFacility();
  const staff = testEnv.authenticatedContext(STAFF_UID);
  const payments = staff
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('tenants')
    .doc(TENANT_ID)
    .collection('payments');

  await assertSucceeds(
    payments.doc('manual-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'manual',
      amountCents: 5000,
      currency: 'usd',
      chargeType: 'manual_cash',
      status: 'succeeded',
      description: 'Cash payment',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      createdBy: STAFF_UID,
      failureCode: null,
      failureMessage: null,
    }),
  );

  await assertFails(
    payments.doc('stripe-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'stripe',
      amountCents: 5000,
      currency: 'usd',
      chargeType: 'manual_cash',
      status: 'succeeded',
      description: 'Should be blocked',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      createdBy: STAFF_UID,
      failureCode: null,
      failureMessage: null,
    }),
  );
});

/** The facility payment PaymentService.recordManualPayment writes (Record payment dialog, Create Payment screen). */
function receivedPayment(uid, extra = {}) {
  return {
    tenantId: TENANT_ID,
    facilityId: FACILITY_ID,
    contractId: '',
    tenantName: 'Test Tenant',
    unitNumber: 'A1',
    amount: 80,
    status: 'completed',
    method: 'venmo',
    paidAt: serverTimestamp(),
    paidDate: serverTimestamp(),
    dueDate: serverTimestamp(),
    notes: 'June rent',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    createdBy: uid,
    isActive: true,
    ...extra,
  };
}

test('an owner records a received payment by Venmo, Zelle or Other, with a check # / reference', async () => {
  await seedFacility();
  const payments = testEnv
    .authenticatedContext(OWNER_UID)
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('payments');

  await assertSucceeds(payments.doc('p-venmo').set(receivedPayment(OWNER_UID, { reference: 'VEN-3345' })));
  await assertSucceeds(payments.doc('p-zelle').set(receivedPayment(OWNER_UID, { method: 'zelle' })));
  await assertSucceeds(payments.doc('p-other').set(receivedPayment(OWNER_UID, { method: 'other' })));
  await assertSucceeds(
    payments.doc('p-check').set(receivedPayment(OWNER_UID, { method: 'check', reference: '1234' })),
  );
  // No tenant name or unit, no contract (imported tenants have none), no notes.
  const bare = receivedPayment(OWNER_UID, { method: 'cash' });
  delete bare.tenantName;
  delete bare.unitNumber;
  delete bare.notes;
  await assertSucceeds(payments.doc('p-bare').set(bare));

  await assertFails(payments.doc('p-bad-method').set(receivedPayment(OWNER_UID, { method: 'bitcoin' })));
  await assertFails(payments.doc('p-long-ref').set(receivedPayment(OWNER_UID, { reference: 'x'.repeat(101) })));
  await assertFails(payments.doc('p-num-ref').set(receivedPayment(OWNER_UID, { reference: 1234 })));
  // Received money is dated now; past dates go through recordTenantPastHistory.
  await assertFails(
    payments.doc('p-backdated').set(receivedPayment(OWNER_UID, { paidAt: new Date('2026-02-10T12:00:00Z') })),
  );
});

test('the old Create Payment "payment request" payload is refused, which is why the screen now records a received payment', async () => {
  await seedFacility();
  const now = new Date();
  await assertFails(
    testEnv
      .authenticatedContext(OWNER_UID)
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('payments')
      .doc('p-request')
      .set({
        tenantId: TENANT_ID,
        facilityId: FACILITY_ID,
        contractId: '',
        tenantName: 'Test Tenant',
        amount: 80,
        status: 'pending',
        method: 'cash',
        dueDate: now,
        paidAt: null,
        notes: null,
        metadata: null,
        createdAt: now,
        updatedAt: now,
        createdBy: OWNER_UID,
        isActive: true,
      }),
  );
});

test('the old Mark Paid (markTenantAsPaid) payload is refused for an owner, which is why it now records a received payment', async () => {
  await seedFacility();
  const now = new Date();
  const endOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  await assertFails(
    testEnv
      .authenticatedContext(OWNER_UID)
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('payments')
      .doc('p-mark-paid')
      .set({
        tenantId: TENANT_ID,
        facilityId: FACILITY_ID,
        tenantName: 'Test Tenant',
        unitNumber: 'A1',
        amount: 80,
        status: 'paid',
        paidAt: serverTimestamp(),
        paidDate: serverTimestamp(),
        dueDate: endOfMonth,
        method: 'cash',
        notes: 'Marked as paid manually',
        contractId: '',
        createdByUid: OWNER_UID,
        createdBy: OWNER_UID,
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        isActive: true,
      }),
  );
});

test('every other client write to a facility payment works for an owner and a manager', async () => {
  await seedFacility();
  const MANAGER = 'manager-user';
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).update({ [`roles.${MANAGER}`]: 'manager' });
    for (const id of ['p-pending', 'p-pending-2', 'p-done', 'p-done-2']) {
      await db.collection('facilities').doc(FACILITY_ID).collection('payments').doc(id).set({
        tenantId: TENANT_ID,
        facilityId: FACILITY_ID,
        contractId: '',
        amount: 80,
        status: id.startsWith('p-pending') ? 'pending' : 'completed',
        method: 'venmo',
        isActive: true,
      });
    }
  });
  const payments = (uid) =>
    testEnv.authenticatedContext(uid).firestore().collection('facilities').doc(FACILITY_ID).collection('payments');
  const markPaid = (uid) => ({
    status: 'paid',
    method: 'venmo',
    transactionId: null,
    paidDate: new Date(),
    paidAt: new Date(),
    paidBy: uid,
    notes: null,
    updatedAt: new Date(),
  });

  // Process (markPaymentAsPaid, from the payment list and detail pages).
  await assertSucceeds(payments(OWNER_UID).doc('p-pending').update(markPaid(OWNER_UID)));
  await assertSucceeds(payments(MANAGER).doc('p-pending-2').update(markPaid(MANAGER)));
  // Edit Payment (updatePayment), link to a deposit, archive, delete.
  await assertSucceeds(payments(OWNER_UID).doc('p-done').update({ amount: 85, method: 'zelle', notes: 'x', updatedAt: serverTimestamp() }));
  await assertSucceeds(payments(MANAGER).doc('p-done').update({ depositId: 'dep-1', updatedAt: serverTimestamp() }));
  await assertSucceeds(
    payments(OWNER_UID).doc('p-done').update({ isActive: false, archivedAt: new Date(), archivedByUid: OWNER_UID, updatedAt: new Date() }),
  );
  await assertSucceeds(payments(MANAGER).doc('p-done-2').delete());
  // Record payment (recordManualPayment) as a manager.
  await assertSucceeds(payments(MANAGER).doc('p-mgr').set(receivedPayment(MANAGER, { reference: '77' })));
  // Employees record payments but may not process, edit or delete them.
  await assertSucceeds(payments(STAFF_UID).doc('p-emp').set(receivedPayment(STAFF_UID)));
  await assertFails(payments(STAFF_UID).doc('p-emp').update(markPaid(STAFF_UID)));
});

test('the ledger line and tenant payment row Record payment writes are allowed', async () => {
  await seedFacility();
  const db = testEnv.authenticatedContext(OWNER_UID).firestore();
  await assertSucceeds(
    db.collection('facilities').doc(FACILITY_ID).collection('ledgers').doc('l-pay').set({
      tenantId: TENANT_ID,
      facilityId: FACILITY_ID,
      type: 'payment',
      amount: -80,
      description: 'Payment - Venmo #VEN-1',
      referenceId: 'p-venmo',
      entryDate: new Date(),
      status: 'posted',
      metadata: { paymentMethod: 'venmo', paymentId: 'p-venmo', reference: 'VEN-1' },
      createdAt: new Date(),
      createdBy: OWNER_UID,
    }),
  );
  await assertSucceeds(
    db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).collection('payments').doc('tp-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'manual',
      amountCents: 8000,
      currency: 'usd',
      chargeType: 'manual_venmo',
      status: 'succeeded',
      description: 'Venmo payment #VEN-1',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      createdBy: OWNER_UID,
      failureCode: null,
      failureMessage: null,
      facilityPaymentId: 'p-venmo',
    }),
  );
  await assertFails(
    db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).collection('payments').doc('tp-2').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'manual',
      amountCents: 8000,
      currency: 'usd',
      chargeType: 'manual_cash',
      status: 'succeeded',
      description: 'Cash payment',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      createdBy: OWNER_UID,
      failureCode: null,
      failureMessage: null,
      facilityPaymentId: 42,
    }),
  );
});

test('past-history batches are server-only', async () => {
  await seedFacility();
  const ref = (uid) =>
    testEnv
      .authenticatedContext(uid)
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('tenantPastHistory')
      .doc('req-00000001');
  await assertFails(ref(OWNER_UID).set({ tenantId: TENANT_ID, status: 'applied' }));
  await assertFails(ref(OWNER_UID).get());
});

test('outsider cannot create manual tenant payments', async () => {
  await seedFacility();
  const outsider = testEnv.authenticatedContext(OUTSIDER_UID);
  await assertFails(
    outsider
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('tenants')
      .doc(TENANT_ID)
      .collection('payments')
      .doc('manual-outsider')
      .set({
        facilityId: FACILITY_ID,
        tenantId: TENANT_ID,
        type: 'manual',
        amountCents: 1000,
        currency: 'usd',
        chargeType: 'manual_check',
        status: 'succeeded',
        description: 'Blocked',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        createdBy: OUTSIDER_UID,
        failureCode: null,
        failureMessage: null,
      }),
  );
});

test('tenant docs: only a super admin deletes directly; owners and managers use the callable', async () => {
  // A paid facility, so the old rule (owner or manager on a paid or trialing
  // facility) would have allowed these deletes. They skipped the history
  // check and orphaned the tenant's ledger, invoices and payments; now only
  // the deleteTenantsPermanently callable deletes for owners and managers.
  const MANAGER_UID = 'manager-user';
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      managers: { [MANAGER_UID]: true },
      roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee' },
      platformSubscriptionStatus: 'active',
    });
    await db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).set({
      facilityId: FACILITY_ID,
      name: 'Test Tenant',
      isActive: true,
    });
  });
  const tenantAs = (context) =>
    context.firestore().collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID);

  await assertFails(tenantAs(testEnv.authenticatedContext(OWNER_UID)).delete());
  await assertFails(tenantAs(testEnv.authenticatedContext(MANAGER_UID)).delete());
  await assertFails(tenantAs(testEnv.authenticatedContext(STAFF_UID)).delete());
  await assertFails(tenantAs(testEnv.authenticatedContext(OUTSIDER_UID)).delete());

  // Archive (an update) is unchanged for the owner.
  await assertSucceeds(tenantAs(testEnv.authenticatedContext(OWNER_UID)).update({ isActive: false }));

  await assertSucceeds(
    tenantAs(testEnv.authenticatedContext('admin-user', { superadmin: true })).delete(),
  );
});

async function seedTenantSms(fields) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee' },
    });
    await db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).set({
      facilityId: FACILITY_ID,
      name: 'Test Tenant',
      isActive: true,
      ...fields,
    });
  });
}

const ownerTenant = () =>
  testEnv
    .authenticatedContext(OWNER_UID)
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('tenants')
    .doc(TENANT_ID);

// What the app writes when staff record consent (SmsConsentUpdate.grant).
const staffGrant = {
  smsOptOut: false,
  smsOptOutDate: deleteField(),
  smsOptInDate: new Date(),
  smsConsentStatus: 'opted_in',
  smsConsentSource: 'staff_recorded',
};

test("tenant SMS: staff cannot reverse a tenant's own opt-out", async () => {
  // A save built from a copy of the tenant read before their STOP arrived
  // must not opt them back in. The server's START handler uses the Admin SDK.
  const tenantOptOuts = [
    { smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: 'inbound_stop' },
    // An online move-in that declined texts: no source, no status.
    { smsOptOut: true },
    { smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: 'csv_opt_out' },
    { smsOptOut: false, smsConsentStatus: 'opted_out', smsConsentSource: 'inbound_stop' },
  ];
  for (const stored of tenantOptOuts) {
    await testEnv.clearFirestore();
    await seedTenantSms(stored);
    await assertFails(ownerTenant().update(staffGrant));
    if (stored.smsOptOut) await assertFails(ownerTenant().update({ smsOptOut: false }));
    if (stored.smsConsentStatus === 'opted_out') {
      await assertFails(ownerTenant().update({ smsConsentStatus: deleteField() }));
    }
    await assertFails(ownerTenant().update({ smsConsentStatus: 'opted_in' }));
    await assertFails(ownerTenant().update({ smsConsentSource: 'staff_removed' }));
    if (stored.smsOptOut) await assertFails(ownerTenant().update({ smsOptOut: deleteField() }));
    // Other edits to the tenant still save.
    await assertSucceeds(ownerTenant().update({ name: 'Renamed', phone: '9035550100' }));
  }

  // A super admin can.
  await testEnv.clearFirestore();
  await seedTenantSms(tenantOptOuts[0]);
  await assertSucceeds(
    testEnv
      .authenticatedContext('admin-user', { superadmin: true })
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('tenants')
      .doc(TENANT_ID)
      .update(staffGrant),
  );
});

test('tenant SMS: staff can record consent, remove it, and record it again', async () => {
  await seedTenantSms({});
  await assertSucceeds(ownerTenant().update(staffGrant));
  // Staff removal (SmsConsentUpdate.remove).
  await assertSucceeds(
    ownerTenant().update({
      smsOptOut: true,
      smsOptOutDate: new Date(),
      smsConsentStatus: 'opted_out',
      smsConsentSource: 'staff_removed',
    }),
  );
  // Their own removal is theirs to reverse.
  await assertSucceeds(ownerTenant().update(staffGrant));
});

test('facility docs: only a super admin deletes directly; owners use the callable', async () => {
  // The app's own facility delete skipped subcollections it couldn't delete
  // (tenants, now super-admin only) and then deleted the facility doc,
  // leaving the tenant records behind. The deleteFacilityPermanently
  // callable removes the whole subtree instead.
  await seedFacility();
  const facilityAs = (context) => context.firestore().collection('facilities').doc(FACILITY_ID);

  await assertFails(facilityAs(testEnv.authenticatedContext(OWNER_UID)).delete());
  await assertFails(facilityAs(testEnv.authenticatedContext(STAFF_UID)).delete());
  await assertFails(facilityAs(testEnv.authenticatedContext(OUTSIDER_UID)).delete());
  // The owner can still edit it.
  await assertSucceeds(facilityAs(testEnv.authenticatedContext(OWNER_UID)).update({ name: 'Renamed' }));

  await assertSucceeds(
    facilityAs(testEnv.authenticatedContext('admin-user', { superadmin: true })).delete(),
  );
});

test('facility owners save their printed-document branding (logo and its layout)', async () => {
  // Edit Facility → Statements & Invoices writes these with Update Facility.
  // The facility rule is a deny-list (facilityEntitlementWriteForbiddenKeys),
  // so they need no rule of their own; this keeps it that way.
  await seedFacility();
  const facilityAs = (context) => context.firestore().collection('facilities').doc(FACILITY_ID);
  const branding = {
    logoUrl: 'https://firebasestorage.googleapis.com/v0/b/x/o/logo.png?alt=media',
    documentLogo: { height: 120, position: 'center', showName: false },
    updatedAt: serverTimestamp(),
  };

  await assertSucceeds(facilityAs(testEnv.authenticatedContext(OWNER_UID)).update(branding));
  await assertSucceeds(
    facilityAs(testEnv.authenticatedContext(OWNER_UID)).update({ documentLogo: deleteField() }),
  );
  await assertFails(facilityAs(testEnv.authenticatedContext(STAFF_UID)).update(branding));
  await assertFails(facilityAs(testEnv.authenticatedContext(OUTSIDER_UID)).update(branding));
});

test('unmatched collections like stripeWebhookEvents deny client access', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  await assertFails(
    authed.firestore().collection('stripeWebhookEvents').doc('evt_123').get(),
  );
});

test('account owners cannot write subscription entitlements', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilityCreatorAccounts').doc('account-1').set({
      ownerUid: OWNER_UID,
      ownerEmail: 'owner@example.com',
      ownerName: 'Owner',
      subscriptionStatus: 'pendingApproval',
      facilityIds: [],
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID);
  const accountRef = owner.firestore().collection('facilityCreatorAccounts').doc('account-1');
  await assertFails(accountRef.update({ subscriptionStatus: 'active' }));
  await assertSucceeds(accountRef.update({ facilityIds: [FACILITY_ID] }));
});

test('account owners cannot clear or forge the once-per-owner offer markers', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilityCreatorAccounts').doc('account-markers').set({
      ownerUid: OWNER_UID,
      ownerEmail: 'owner@example.com',
      ownerName: 'Owner',
      subscriptionStatus: 'cancelled',
      facilityIds: [],
      platformTrialUsedAt: serverTimestamp(),
      platformFirstMonthFreeUsedAt: serverTimestamp(),
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID);
  const accountRef = owner.firestore().collection('facilityCreatorAccounts').doc('account-markers');
  await assertFails(accountRef.update({ platformTrialUsedAt: null }));
  await assertFails(accountRef.update({ platformFirstMonthFreeUsedAt: deleteField() }));
  await assertSucceeds(accountRef.update({ facilityIds: [FACILITY_ID] }));
});

test('new accounts must start pending approval without server-owned billing fields', async () => {
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const accounts = owner.firestore().collection('facilityCreatorAccounts');
  const base = {
    ownerUid: OWNER_UID,
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };

  await assertFails(accounts.doc('forged-active').set({
    ...base,
    subscriptionStatus: 'active',
  }));
  await assertFails(accounts.doc('forged-stripe').set({
    ...base,
    subscriptionStatus: 'pendingApproval',
    stripeSubscriptionId: 'sub_forged',
  }));
  await assertSucceeds(accounts.doc('pending').set({
    ...base,
    subscriptionStatus: 'pendingApproval',
  }));
});

test('facility owners cannot write platform or website subscription entitlements', async () => {
  await seedFacility();
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const facilityRef = owner.firestore().collection('facilities').doc(FACILITY_ID);

  await assertFails(facilityRef.update({ platformSubscriptionStatus: 'active' }));
  await assertFails(facilityRef.update({ websiteSubscriptionStatus: 'active' }));
  await assertFails(facilityRef.update({ stripeWebsiteSubscriptionId: 'sub_forged' }));
  await assertFails(facilityRef.update({ websiteCheckoutSessionId: 'cs_forged' }));
  await assertFails(
    facilityRef.update({ websiteAdminTrialEndsAt: serverTimestamp() }),
  );
  await assertFails(
    facilityRef.update({ websiteAdminTrialGrantedByEmail: 'owner@example.com' }),
  );
  // Entitlement is resolved by reading this id and checking that the named
  // account's subscription is 'active', with no check that the caller owns that
  // account. A writable link therefore lets a non-paying operator inherit a
  // paying one's premium entitlements, so it is backend-only.
  await assertFails(facilityRef.update({ facilityCreatorAccountId: 'account-1' }));
});

test("facility owners cannot write the owner account standing their staff are let in on", async () => {
  // Invited staff cannot read the owner's account, so the app decides from
  // this backend-written copy whether the owner's billing still covers them.
  // An owner who could write it could keep staff working after a lapse or a
  // suspension.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      name: 'Keepsake',
      roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee' },
      ownerAccountStanding: { accountId: 'account-1', subscriptionStatus: 'cancelled', suspended: true },
    });
  });
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const facilityRef = owner.firestore().collection('facilities').doc(FACILITY_ID);

  await assertFails(
    facilityRef.update({
      ownerAccountStanding: { accountId: 'account-1', subscriptionStatus: 'active', suspended: false },
    }),
  );
  await assertFails(facilityRef.update({ 'ownerAccountStanding.suspended': false }));
  await assertFails(facilityRef.update({ ownerAccountStanding: deleteField() }));
  // Other edits still go through with the copy in place.
  await assertSucceeds(facilityRef.update({ name: 'Keepsake Storage' }));

  // Nor can a new facility start out with one.
  await assertFails(
    owner.firestore().collection('facilities').doc('facility-new').set({
      name: 'New',
      ownerUid: OWNER_UID,
      createdAt: serverTimestamp(),
      active: true,
      ownerAccountStanding: { accountId: 'account-1', subscriptionStatus: 'active' },
    }),
  );
  // Staff read it (that is what it is for).
  const staff = testEnv.authenticatedContext(STAFF_UID);
  await assertSucceeds(staff.firestore().collection('facilities').doc(FACILITY_ID).get());
});

test('facility owners cannot forge A2P texting approval state', async () => {
  // The SMS send path reads these straight off the facility document. If an
  // owner could write them they could mark themselves carrier-approved, or
  // switch the gate off entirely with textingOnboardingEnabled:false, and push
  // unregistered 10DLC traffic through the platform's Twilio account.
  await seedFacility();
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const facilityRef = owner.firestore().collection('facilities').doc(FACILITY_ID);

  await assertFails(facilityRef.update({ a2pStatus: 'approved' }));
  await assertFails(facilityRef.update({ textingPlatformApproved: true }));
  await assertFails(facilityRef.update({ textingOnboardingEnabled: false }));
  await assertFails(facilityRef.update({ a2pBundleReady: true }));
  await assertFails(facilityRef.update({ twilioBrandSid: 'BN_forged' }));
  await assertFails(facilityRef.update({ twilioCampaignSid: 'CM_forged' }));
  await assertFails(facilityRef.update({ twilioMessagingServiceSid: 'MG_forged' }));
  await assertFails(facilityRef.update({ twilioTrustProfileSid: 'BU_forged' }));
  await assertFails(
    facilityRef.update({ textingPlatformApprovedBy: 'owner@example.com' }),
  );
});

test('facility owners cannot write A2P paid-step state or the filed campaign inputs', async () => {
  // a2pSubmitLease serialises number purchases and campaign filing; the
  // pending flag makes the hourly poll file a campaign; the E164 number is
  // what sendSMS sends from and inbound replies route by; the consent methods
  // and samples are what the poll files with the carriers. All server-written.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      roles: { [OWNER_UID]: 'owner' },
      name: 'Example Self Storage',
      twilioPhoneNumberE164: '+15125550100',
      textingConsentMethods: ['online_form'],
    });
  });
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const facilityRef = owner.firestore().collection('facilities').doc(FACILITY_ID);

  await assertFails(facilityRef.update({ a2pSubmitLease: null }));
  await assertFails(facilityRef.update({ a2pSubmitLease: { holder: 'me', expiresAtMs: 1 } }));
  await assertFails(facilityRef.update({ twilioPhoneNumberE164: '+15125550199' }));
  await assertFails(facilityRef.update({ a2pCampaignPending: true }));
  await assertFails(facilityRef.update({ a2pRejectedAt: null }));
  await assertFails(facilityRef.update({ a2pBrandResubmitRequired: true }));
  await assertFails(facilityRef.update({ textingConsentMethods: ['lease_clause'] }));
  await assertFails(facilityRef.update({ textingSampleMessages: ['a', 'b'] }));
  await assertFails(facilityRef.update({ twilioCampaignId: 'CM_forged' }));

  // Re-saving the unchanged number with an ordinary edit (what the app's
  // facility form does) is still allowed.
  await assertSucceeds(
    facilityRef.update({ name: 'Example Self Storage East', twilioPhoneNumberE164: '+15125550100' }),
  );
});

test('superadmin custom claim can write website entitlements; others cannot', async () => {
  await seedFacility();
  // Superadmin access is granted by a server-set custom claim, not by email, so
  // an unverified account matching an allowlisted email cannot impersonate.
  const admin = testEnv.authenticatedContext('admin-user', {
    superadmin: true,
  });
  const nonAdmin = testEnv.authenticatedContext('non-admin', {
    email: 'russell_forsyth_1992@outlook.com',
    email_verified: false,
  });

  await assertSucceeds(
    admin
        .firestore()
        .collection('facilities')
        .doc(FACILITY_ID)
        .update({ websiteAdminTrialReason: 'admin grant' }),
  );
  await assertFails(
    nonAdmin
        .firestore()
        .collection('facilities')
        .doc(FACILITY_ID)
        .update({ websiteAdminTrialReason: 'forged' }),
  );
});

test('superadmin can run the website settings collection group query', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db
        .collection('facilities')
        .doc(FACILITY_ID)
        .collection('settings')
        .doc('public')
        .set({ enabled: true, customDomain: 'example.com' });
  });

  const admin = testEnv.authenticatedContext('admin-user', { superadmin: true });
  const owner = testEnv.authenticatedContext(OWNER_UID);

  await assertSucceeds(admin.firestore().collectionGroup('settings').get());
  await assertFails(owner.firestore().collectionGroup('settings').get());
});

test('customDomainClaims: owner can create a claim for their own facility, not for someone else\'s', async () => {
  const secondFacilityId = 'fac-domain-2';
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(secondFacilityId).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();

  await assertSucceeds(
    owner.collection('customDomainClaims').doc('owner-claim.com').set({
      facilityId: FACILITY_ID,
      claimedAt: serverTimestamp(),
    }),
  );

  await assertFails(
    owner.collection('customDomainClaims').doc('other-claim.com').set({
      facilityId: secondFacilityId,
      claimedAt: serverTimestamp(),
    }),
  );
});

test('customDomainClaims: a second facility cannot claim a hostname already claimed by the first', async () => {
  const secondFacilityId = 'fac-domain-2';
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(secondFacilityId).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const outsider = testEnv.authenticatedContext(OUTSIDER_UID).firestore();

  await assertSucceeds(
    owner.collection('customDomainClaims').doc('shared.com').set({
      facilityId: FACILITY_ID,
      claimedAt: serverTimestamp(),
    }),
  );

  // Doc already exists, so this hits `allow update: if false` regardless of caller.
  await assertFails(
    outsider.collection('customDomainClaims').doc('shared.com').set({
      facilityId: secondFacilityId,
      claimedAt: serverTimestamp(),
    }),
  );
});

test('settings/public: customDomain writes are gated on holding the matching claim', async () => {
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('settings')
      .doc('public')
      .set({ enabled: true, customDomain: 'old.example.com' });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const settingsRef = owner
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('settings')
    .doc('public');

  // Unchanged value: allowed even without a claim.
  await assertSucceeds(
    settingsRef.set({ enabled: true, customDomain: 'old.example.com' }, { merge: true }),
  );

  // Unclaimed new value: denied.
  await assertFails(
    settingsRef.set({ customDomain: 'unclaimed.example.com' }, { merge: true }),
  );

  // Claim the new value, then the same write is allowed.
  await assertSucceeds(
    owner.collection('customDomainClaims').doc('new.example.com').set({
      facilityId: FACILITY_ID,
      claimedAt: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    settingsRef.set({ customDomain: 'new.example.com' }, { merge: true }),
  );
});

test('customDomainClaims: only the owning facility or superadmin can delete a claim', async () => {
  const secondFacilityId = 'fac-domain-2';
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(secondFacilityId).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
    await db.collection('customDomainClaims').doc('delete-test.com').set({
      facilityId: FACILITY_ID,
      claimedAt: serverTimestamp(),
    });
  });

  const outsider = testEnv.authenticatedContext(OUTSIDER_UID).firestore();
  const admin = testEnv.authenticatedContext('admin-user', { superadmin: true }).firestore();
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();

  await assertFails(outsider.collection('customDomainClaims').doc('delete-test.com').delete());
  await assertSucceeds(owner.collection('customDomainClaims').doc('delete-test.com').delete());

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('customDomainClaims').doc('delete-test-2.com').set({
      facilityId: FACILITY_ID,
      claimedAt: serverTimestamp(),
    });
  });
  await assertSucceeds(admin.collection('customDomainClaims').doc('delete-test-2.com').delete());
});

test('role assigners cannot retarget an existing role to another facility or user', async () => {
  const secondFacilityId = 'fac-test-2';
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      managers: { [OWNER_UID]: true },
      roles: { [OWNER_UID]: 'owner' },
    });
    await db.collection('facilities').doc(secondFacilityId).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
    await db.collection('user_roles').doc('role-1').set({
      userId: STAFF_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
    });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID);
  const roleRef = owner.firestore().collection('user_roles').doc('role-1');
  await assertFails(roleRef.update({
    facilityId: secondFacilityId,
    roleType: 'manager',
  }));
  await assertFails(roleRef.update({ userId: OWNER_UID }));
  await assertSucceeds(roleRef.update({
    roleType: 'manager',
    isActive: true,
  }));
});

test('public payment links and reservations deny anonymous direct access', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('publicPaymentLinks').doc('token-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      token: 'token-1',
      amount: 50,
      status: 'pending',
    });
    await db.collection('publicReservations').doc('reservation-1').set({
      facilityId: FACILITY_ID,
      email: 'tenant@example.com',
      status: 'pending',
      reservedAt: serverTimestamp(),
      moveInToken: '0123456789abcdef0123456789abcdef',
    });
  });

  const anonymous = testEnv.unauthenticatedContext().firestore();
  await assertFails(anonymous.collection('publicPaymentLinks').doc('token-1').get());
  const reservationRef = anonymous.collection('publicReservations').doc('reservation-1');
  await assertFails(reservationRef.get());
  await assertFails(reservationRef.update({ status: 'cancelled' }));
});

test('public payment-link creation and reservation writes are callable-only', async () => {
  await seedFacility();
  const staff = testEnv.authenticatedContext(STAFF_UID).firestore();
  await assertFails(
    staff.collection('publicPaymentLinks').doc('client-token').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      token: 'client-token',
      amount: 25,
      status: 'pending',
      createdBy: STAFF_UID,
    }),
  );
  await assertFails(
    testEnv.unauthenticatedContext().firestore().collection('publicReservations').add({
      facilityId: FACILITY_ID,
      email: 'tenant@example.com',
      status: 'pending',
      reservedAt: serverTimestamp(),
      moveInToken: '0123456789abcdef0123456789abcdef',
    }),
  );
});

test('export jobs are owner-managed but server-updated', async () => {
  await seedFacility();
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const outsider = testEnv.authenticatedContext(OUTSIDER_UID).firestore();
  const jobRef = owner
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('exportJobs')
    .doc('job-1');

  await assertSucceeds(jobRef.set({
    facilityId: FACILITY_ID,
    type: 'tenants',
    status: 'pending',
    createdBy: OWNER_UID,
    createdAt: serverTimestamp(),
  }));
  await assertSucceeds(jobRef.get());
  await assertFails(jobRef.update({ status: 'completed' }));
  await assertFails(
    outsider
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('exportJobs')
      .doc('job-1')
      .get(),
  );
});

test('DNR evidence storage reads require current premium entitlement', async () => {
  const activeUid = 'dnr-active';
  const lapsedUid = 'dnr-lapsed';
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilityCreatorAccounts').doc('dnr-active-account').set({
      ownerUid: activeUid,
      subscriptionStatus: 'active',
    });
    await db.collection('facilityCreatorAccounts').doc('dnr-lapsed-account').set({
      ownerUid: lapsedUid,
      subscriptionStatus: 'cancelled',
    });
    await db.collection('dnr_participants').doc(activeUid).set({
      accepted: true,
      accountId: 'dnr-active-account',
    });
    await db.collection('dnr_participants').doc(lapsedUid).set({
      accepted: true,
      accountId: 'dnr-lapsed-account',
    });
    await uploadBytes(
      storageRef(context.storage(), 'dnrEvidence/entry-1/evidence.txt'),
      new TextEncoder().encode('evidence'),
    );
  });

  await assertSucceeds(
    getBytes(storageRef(testEnv.authenticatedContext(activeUid).storage(), 'dnrEvidence/entry-1/evidence.txt')),
  );
  await assertFails(
    getBytes(storageRef(testEnv.authenticatedContext(lapsedUid).storage(), 'dnrEvidence/entry-1/evidence.txt')),
  );
});

// The first free month is Stripe trial time: an owner who subscribed with a
// card reads 'trialing' with a Stripe subscription id until the first charge,
// and that counts as paid until its recorded trial end plus 3 days (webhook
// lag). A 'trialing' record with an id and a trial end long past, or none, is
// stale and does not count. The unpaid app trial ('trialing', no id) does not.
const DNR_DAY_MS = 24 * 60 * 60 * 1000;
const dnrDaysFromNow = (days) => new Date(Date.now() + days * DNR_DAY_MS);

async function seedPaidTrialDnrFixtures() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilityCreatorAccounts').doc('acct-card-trial').set({
      ownerUid: 'dnr-card-trial',
      subscriptionStatus: 'trialing',
      stripeSubscriptionId: 'sub_test_account',
      subscriptionTrialEnd: dnrDaysFromNow(20),
    });
    await db.collection('facilityCreatorAccounts').doc('acct-app-trial').set({
      ownerUid: 'dnr-app-trial',
      subscriptionStatus: 'trialing',
      stripeSubscriptionId: null,
      subscriptionTrialEnd: dnrDaysFromNow(20),
    });
    // Per-facility billing: the account only rolls the facility up as trialing.
    await db.collection('facilityCreatorAccounts').doc('acct-rollup').set({
      ownerUid: 'dnr-facility-trial',
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: dnrDaysFromNow(-2),
    });
    await db.collection('facilities').doc('fac-card-trial').set({
      ownerUid: 'dnr-facility-trial',
      facilityCreatorAccountId: 'acct-rollup',
      platformSubscriptionStatus: 'trialing',
      stripePlatformSubscriptionId: 'sub_test_facility',
      platformSubscriptionTrialEnd: dnrDaysFromNow(20),
    });
    await db.collection('facilities').doc('fac-app-trial').set({
      ownerUid: 'dnr-app-trial',
      facilityCreatorAccountId: 'acct-app-trial',
      platformSubscriptionStatus: 'trialing',
      platformSubscriptionTrialEnd: dnrDaysFromNow(20),
    });
    // Card-backed trials past their trial end: inside the 3-day grace, long past it,
    // and with no trial end recorded at all.
    await db.collection('facilityCreatorAccounts').doc('acct-card-grace').set({
      ownerUid: 'dnr-card-grace',
      subscriptionStatus: 'trialing',
      stripeSubscriptionId: 'sub_test_grace',
      subscriptionTrialEnd: dnrDaysFromNow(-1),
    });
    await db.collection('facilityCreatorAccounts').doc('acct-card-stale').set({
      ownerUid: 'dnr-card-stale',
      subscriptionStatus: 'trialing',
      stripeSubscriptionId: 'sub_test_stale',
      subscriptionTrialEnd: dnrDaysFromNow(-10),
    });
    await db.collection('facilityCreatorAccounts').doc('acct-card-no-end').set({
      ownerUid: 'dnr-card-no-end',
      subscriptionStatus: 'trialing',
      stripeSubscriptionId: 'sub_test_no_end',
    });
    await db.collection('facilityCreatorAccounts').doc('acct-rollup-stale').set({
      ownerUid: 'dnr-facility-stale',
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: dnrDaysFromNow(-40),
    });
    await db.collection('facilities').doc('fac-card-stale').set({
      ownerUid: 'dnr-facility-stale',
      facilityCreatorAccountId: 'acct-rollup-stale',
      platformSubscriptionStatus: 'trialing',
      stripePlatformSubscriptionId: 'sub_test_facility_stale',
      platformSubscriptionTrialEnd: dnrDaysFromNow(-10),
    });
    await db.collection('facilities').doc('fac-card-no-end').set({
      ownerUid: 'dnr-facility-stale',
      facilityCreatorAccountId: 'acct-rollup-stale',
      platformSubscriptionStatus: 'trialing',
      stripePlatformSubscriptionId: 'sub_test_facility_no_end',
    });
    await db.collection('global_dnr_entries').doc('entry-1').set({
      createdByUserId: 'someone-else',
      createdByFacilityId: 'fac-elsewhere',
    });
  });
}

test('DNR acceptance: the card-backed free month counts as paid, the unpaid app trial does not', async () => {
  await seedPaidTrialDnrFixtures();
  const accept = (uid, fields) =>
    testEnv
      .authenticatedContext(uid)
      .firestore()
      .collection('dnr_participants')
      .doc(uid)
      .set({ accepted: true, termsVersion: '1.0', ...fields });

  // Account-level subscription in its free month.
  await assertSucceeds(accept('dnr-card-trial', { accountId: 'acct-card-trial' }));
  // Facility subscription in its free month: named on the acceptance.
  await assertFails(accept('dnr-facility-trial', { accountId: 'acct-rollup' }));
  await assertSucceeds(accept('dnr-facility-trial', { accountId: 'acct-rollup', facilityId: 'fac-card-trial' }));
  // The unpaid app trial, on the account or the facility.
  await assertFails(accept('dnr-app-trial', { accountId: 'acct-app-trial' }));
  await assertFails(accept('dnr-app-trial', { accountId: 'acct-app-trial', facilityId: 'fac-app-trial' }));
});

test('DNR acceptance: a card-backed trial counts until its trial end plus 3 days, never with no trial end', async () => {
  await seedPaidTrialDnrFixtures();
  const accept = (uid, fields) =>
    testEnv
      .authenticatedContext(uid)
      .firestore()
      .collection('dnr_participants')
      .doc(uid)
      .set({ accepted: true, termsVersion: '1.0', ...fields });

  // Account: a day past the trial end (webhook late) still counts; ten days past, or none, does not.
  await assertSucceeds(accept('dnr-card-grace', { accountId: 'acct-card-grace' }));
  await assertFails(accept('dnr-card-stale', { accountId: 'acct-card-stale' }));
  await assertFails(accept('dnr-card-no-end', { accountId: 'acct-card-no-end' }));
  // Facility: the same bound on platformSubscriptionTrialEnd.
  await assertFails(accept('dnr-facility-stale', { accountId: 'acct-rollup-stale', facilityId: 'fac-card-stale' }));
  await assertFails(accept('dnr-facility-stale', { accountId: 'acct-rollup-stale', facilityId: 'fac-card-no-end' }));
});

test('DNR reads: the card-backed free month keeps participants in, the unpaid app trial is shut out', async () => {
  await seedPaidTrialDnrFixtures();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('dnr_participants').doc('dnr-card-trial').set({ accepted: true, accountId: 'acct-card-trial' });
    await db
      .collection('dnr_participants')
      .doc('dnr-facility-trial')
      .set({ accepted: true, accountId: 'acct-rollup', facilityId: 'fac-card-trial' });
    // Accepted earlier, now on the unpaid app trial.
    await db
      .collection('dnr_participants')
      .doc('dnr-app-trial')
      .set({ accepted: true, accountId: 'acct-app-trial', facilityId: 'fac-app-trial' });
  });
  const read = (uid) =>
    testEnv.authenticatedContext(uid).firestore().collection('global_dnr_entries').doc('entry-1').get();
  await assertSucceeds(read('dnr-card-trial'));
  await assertSucceeds(read('dnr-facility-trial'));
  await assertFails(read('dnr-app-trial'));
});

test('DNR reads: a stale card-backed trial (trial end long past, or none) shuts the participant out', async () => {
  await seedPaidTrialDnrFixtures();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    // All accepted while they were paid.
    await db.collection('dnr_participants').doc('dnr-card-grace').set({ accepted: true, accountId: 'acct-card-grace' });
    await db.collection('dnr_participants').doc('dnr-card-stale').set({ accepted: true, accountId: 'acct-card-stale' });
    await db.collection('dnr_participants').doc('dnr-card-no-end').set({ accepted: true, accountId: 'acct-card-no-end' });
    await db
      .collection('dnr_participants')
      .doc('dnr-facility-stale')
      .set({ accepted: true, accountId: 'acct-rollup-stale', facilityId: 'fac-card-stale' });
  });
  const read = (uid) =>
    testEnv.authenticatedContext(uid).firestore().collection('global_dnr_entries').doc('entry-1').get();
  await assertSucceeds(read('dnr-card-grace'));
  await assertFails(read('dnr-card-stale'));
  await assertFails(read('dnr-card-no-end'));
  await assertFails(read('dnr-facility-stale'));
});

test('DNR evidence storage: the card-backed free month counts as premium', async () => {
  await seedPaidTrialDnrFixtures();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('dnr_participants').doc('dnr-card-trial').set({ accepted: true, accountId: 'acct-card-trial' });
    await db
      .collection('dnr_participants')
      .doc('dnr-facility-trial')
      .set({ accepted: true, accountId: 'acct-rollup', facilityId: 'fac-card-trial' });
    await db
      .collection('dnr_participants')
      .doc('dnr-app-trial')
      .set({ accepted: true, accountId: 'acct-app-trial', facilityId: 'fac-app-trial' });
    await uploadBytes(
      storageRef(context.storage(), 'dnrEvidence/entry-2/evidence.txt'),
      new TextEncoder().encode('evidence'),
    );
  });
  const read = (uid) =>
    getBytes(storageRef(testEnv.authenticatedContext(uid).storage(), 'dnrEvidence/entry-2/evidence.txt'));
  await assertSucceeds(read('dnr-card-trial'));
  await assertSucceeds(read('dnr-facility-trial'));
  await assertFails(read('dnr-app-trial'));
});

test('DNR evidence storage: a stale card-backed trial is not premium', async () => {
  await seedPaidTrialDnrFixtures();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('dnr_participants').doc('dnr-card-grace').set({ accepted: true, accountId: 'acct-card-grace' });
    await db.collection('dnr_participants').doc('dnr-card-stale').set({ accepted: true, accountId: 'acct-card-stale' });
    await db.collection('dnr_participants').doc('dnr-card-no-end').set({ accepted: true, accountId: 'acct-card-no-end' });
    await db
      .collection('dnr_participants')
      .doc('dnr-facility-stale')
      .set({ accepted: true, accountId: 'acct-rollup-stale', facilityId: 'fac-card-no-end' });
    await uploadBytes(
      storageRef(context.storage(), 'dnrEvidence/entry-3/evidence.txt'),
      new TextEncoder().encode('evidence'),
    );
  });
  const read = (uid) =>
    getBytes(storageRef(testEnv.authenticatedContext(uid).storage(), 'dnrEvidence/entry-3/evidence.txt'));
  await assertSucceeds(read('dnr-card-grace'));
  await assertFails(read('dnr-card-stale'));
  await assertFails(read('dnr-card-no-end'));
  await assertFails(read('dnr-facility-stale'));
});

test('an operator cannot seize another operator’s public storefront slug', async () => {
  // Slugs are the public storefront URL, so they are discoverable by design.
  // The update rule used to accept the INCOMING payload's facilityId, which let
  // any operator PUT their own facilityId over someone else's slug and either
  // disable that storefront or repoint its rent/pay links at their own site.
  const RIVAL_FACILITY = 'fac-rival-1';
  const SLUG = 'keepsake-self-storage';
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    // A rival facility that OUTSIDER_UID legitimately owns.
    await db.collection('facilities').doc(RIVAL_FACILITY).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
    // The victim's slug, owned by FACILITY_ID.
    await db.collection('publicFacilityMaps').doc(SLUG).set({
      facilityId: FACILITY_ID,
      publicSettings: { enabled: true },
    });
  });

  const rival = testEnv.authenticatedContext(OUTSIDER_UID);
  const slugRef = rival.firestore().collection('publicFacilityMaps').doc(SLUG);

  // Repointing the slug at the rival's own facility must fail.
  await assertFails(slugRef.update({ facilityId: RIVAL_FACILITY }));
  // So must simply switching the victim's storefront off.
  await assertFails(slugRef.update({ publicSettings: { enabled: false } }));

  // The real owner can still edit their own slug, without changing the link.
  const owner = testEnv.authenticatedContext(OWNER_UID);
  await assertSucceeds(
    owner
      .firestore()
      .collection('publicFacilityMaps')
      .doc(SLUG)
      .update({ publicSettings: { enabled: false } }),
  );
});

test("a slug change's one batch passes, and the old slug's pointer stays the owner's", async () => {
  // FacilityMapV2Service.setPublicSlug writes the meta, the map carried to the
  // new slug, a pointer over the old one and the earlier pointers repointed,
  // in a single batch: if the rules refused any of them, no slug could change.
  const RIVAL_FACILITY = 'fac-rival-1';
  const OLDER_SLUGS = Array.from({ length: 15 }, (_, i) => `older-${i + 1}`);
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(RIVAL_FACILITY).set({
      ownerUid: OUTSIDER_UID,
      roles: { [OUTSIDER_UID]: 'owner' },
    });
    await db.collection('publicFacilityMaps').doc('old-slug').set({
      facilityId: FACILITY_ID,
      facilitySlug: 'old-slug',
      publicSettings: { enabled: true },
      units: [{ unitId: 'u1', isRentable: true }],
    });
    // Pointers from earlier changes, repointed in the same batch. Fifteen:
    // each write's rule reads facilities/{id}, and a batch may make only 20
    // such reads unless repeats of one doc are cached.
    for (const slug of OLDER_SLUGS) {
      await db.collection('publicFacilityMaps').doc(slug).set({
        facilityId: FACILITY_ID,
        movedToSlug: 'old-slug',
        movedAt: new Date(),
      });
    }
  });

  const ownerDb = testEnv.authenticatedContext(OWNER_UID).firestore();
  const batch = ownerDb.batch();
  batch.set(
    ownerDb.doc(`facilities/${FACILITY_ID}/mapEngine/meta`),
    { facilityId: FACILITY_ID, publicSlug: 'new-slug', updatedAt: serverTimestamp(), updatedBy: OWNER_UID },
    { merge: true },
  );
  batch.set(ownerDb.collection('publicFacilityMaps').doc('new-slug'), {
    facilityId: FACILITY_ID,
    facilitySlug: 'new-slug',
    publicSettings: { enabled: true },
    units: [{ unitId: 'u1', isRentable: true }],
  });
  for (const slug of ['old-slug', ...OLDER_SLUGS]) {
    batch.set(ownerDb.collection('publicFacilityMaps').doc(slug), {
      facilityId: FACILITY_ID,
      movedToSlug: 'new-slug',
      movedAt: serverTimestamp(),
    });
  }
  await assertSucceeds(batch.commit());

  // The pointer keeps the old slug reserved: another operator can neither
  // take it over nor delete it, and anyone can read it (it is a public link).
  const rivalDb = testEnv.authenticatedContext(OUTSIDER_UID).firestore();
  const pointer = rivalDb.collection('publicFacilityMaps').doc('old-slug');
  await assertFails(pointer.set({ facilityId: RIVAL_FACILITY, units: [] }));
  await assertFails(pointer.update({ movedToSlug: 'rival-slug' }));
  await assertFails(pointer.delete());
  await assertSucceeds(testEnv.unauthenticatedContext().firestore().collection('publicFacilityMaps').doc('old-slug').get());

  // Staff cannot move the storefront (owners and managers only).
  const staffDb = testEnv.authenticatedContext(STAFF_UID).firestore();
  await assertFails(
    staffDb.collection('publicFacilityMaps').doc('new-slug').set({
      facilityId: FACILITY_ID,
      movedToSlug: 'elsewhere',
      movedAt: serverTimestamp(),
    }),
  );
});

test('audit logs are immutable once written', async () => {
  // Two rule blocks used to match this path: a broad `allow write` for
  // owners/managers, and the intended immutable block. Rules OR together, so the
  // broad one won and an owner could rewrite or delete their own audit trail —
  // the one record that exists to survive them.
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('auditLogs')
      .doc('log-1')
      .set({
        facilityId: FACILITY_ID,
        action: 'tenant_deleted',
        entityType: 'tenant',
        entityId: TENANT_ID,
        userId: OWNER_UID,
        userEmail: 'owner@example.com',
        timestamp: new Date(),
        changes: {},
        metadata: {},
      });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID);
  const logRef = owner.firestore().collection('facilities').doc(FACILITY_ID).collection('auditLogs').doc('log-1');

  await assertSucceeds(logRef.get());
  await assertFails(logRef.update({ action: 'nothing_happened' }));
  await assertFails(logRef.delete());
});

test("audit logs: the old action/at rows are refused, AuditLogEntry.toFirestore's row is not", async () => {
  // AuditService's DNR, ledger, move-in/out, invoice, autopay, contact-log,
  // payment-method, transfer, document and lien writers used to add these
  // rows directly and swallow the error, so none of those events ever landed.
  await seedFacility();
  const logs = (uid) =>
    testEnv.authenticatedContext(uid).firestore().collection('facilities').doc(FACILITY_ID).collection('auditLogs');

  // logDNRAction
  await assertFails(
    logs(OWNER_UID).add({
      action: 'dnr.create',
      actorUid: OWNER_UID,
      actorEmail: 'owner@example.com',
      targetId: 'dnr-1',
      details: { name: 'Someone' },
      at: serverTimestamp(),
    }),
  );
  // logLedgerEntryCreated and the rest: entityType/entityId/tenantId, still no
  // facilityId, userId, userEmail, timestamp, changes or metadata.
  await assertFails(
    logs(OWNER_UID).add({
      action: 'ledger.entry.created',
      actorUid: OWNER_UID,
      actorEmail: 'owner@example.com',
      targetId: 'entry-1',
      entityType: 'ledgerEntry',
      entityId: 'entry-1',
      tenantId: TENANT_ID,
      details: { type: 'charge', amount: 40 },
      at: serverTimestamp(),
    }),
  );

  // What AuditService.logEvent writes (AuditLogEntry.toFirestore), for an owner
  // and for an employee.
  const entry = (uid, email, role) => ({
    eventType: 'ledger.entry.created',
    actorUid: uid,
    actorEmail: email,
    actorRole: role,
    targetType: 'ledgerEntry',
    targetId: 'entry-1',
    facilityId: FACILITY_ID,
    tenantId: TENANT_ID,
    after: { type: 'charge', amount: 40 },
    timestamp: new Date(),
    metadata: { description: 'Rent', actorRole: role },
    action: 'ledger.entry.created',
    entityType: 'ledgerEntry',
    entityId: 'entry-1',
    userId: uid,
    userEmail: email,
    changes: { after: { type: 'charge', amount: 40 } },
  });
  await assertSucceeds(logs(OWNER_UID).add(entry(OWNER_UID, 'owner@example.com', 'owner')));
  await assertSucceeds(logs(STAFF_UID).add(entry(STAFF_UID, 'staff@example.com', 'employee')));
  // Nobody signs a row as somebody else.
  await assertFails(logs(STAFF_UID).add(entry(OWNER_UID, 'owner@example.com', 'owner')));
});

test('email usage counters cannot be reset or deleted by the facility', async () => {
  // The outbound path increments emailMonthlyCount in a transaction and refuses
  // to send past the limit. A client able to rewrite or delete the month
  // document could zero its own counter and keep sending.
  await seedFacility();
  const usagePath = (ctx) =>
    ctx.firestore().collection('facilities').doc(FACILITY_ID).collection('emailUsage').doc('2026-09');

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await usagePath(context).set({ emailMonth: '2026-09', emailMonthlyCount: 480, emailMonthlyLimit: 500 });
  });

  const owner = testEnv.authenticatedContext(OWNER_UID);
  await assertSucceeds(usagePath(owner).get());
  await assertFails(usagePath(owner).update({ emailMonthlyCount: 0 }));
  await assertFails(usagePath(owner).delete());
  // A non-counter field is still editable, which is what the creation wizard needs.
  await assertSucceeds(usagePath(owner).update({ emailMonthlyLimit: 400 }));

  // Staff below manager cannot write at all.
  const staff = testEnv.authenticatedContext(STAFF_UID);
  await assertFails(usagePath(staff).update({ emailMonthlyLimit: 900 }));
});

test('the facility creation wizard can still set an email limit on a fresh facility', async () => {
  // EmailUsageService.setEmailLimit does a merge set on a month document that
  // usually does not exist yet, so it takes the create path. The counter rules
  // must not break new facility setup.
  await seedFacility();
  const owner = testEnv.authenticatedContext(OWNER_UID);
  const fresh = owner
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('emailUsage')
    .doc('2026-10');

  await assertSucceeds(
    fresh.set(
      { emailMonthlyLimit: 500, emailMonth: '2026-10', lastUpdated: serverTimestamp() },
      { merge: true },
    ),
  );

  // But it may not seed a counter on the way in.
  const sneaky = owner
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('emailUsage')
    .doc('2026-11');
  await assertFails(
    sneaky.set({ emailMonthlyLimit: 500, emailMonthlyCount: 0 }, { merge: true }),
  );
});

test('an invitee can list the pending invites addressed to their own verified email, and nothing else', async () => {
  // PermissionService.fulfillPendingInvitesForUser and the account service's
  // pending-invite check query collectionGroup('invites') by emailLower. With
  // only the facility-scoped rule (owner/manager list) that was refused, so a
  // fresh invited signup got no role and was taken for a new owner.
  const OTHER_FACILITY_ID = 'fac-test-2';
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const invite = (facilityId, id, emailLower) =>
      db.collection('facilities').doc(facilityId).collection('invites').doc(id).set({
        facilityId,
        email: emailLower,
        emailLower,
        roleType: 'employee',
        status: 'pending',
        invitedBy: OWNER_UID,
      });
    await db.collection('facilities').doc(OTHER_FACILITY_ID).set({ ownerUid: OUTSIDER_UID });
    await invite(FACILITY_ID, 'inv-mine-1', 'invitee@example.com');
    await invite(OTHER_FACILITY_ID, 'inv-mine-2', 'invitee@example.com');
    await invite(FACILITY_ID, 'inv-theirs', 'someone@example.com');
  });

  const pendingFor = (db, emailLower) =>
    db.collectionGroup('invites').where('emailLower', '==', emailLower).where('status', '==', 'pending');

  // The signed-in address is mixed case; the rule and the app lower-case it.
  const invitee = testEnv
    .authenticatedContext('invitee-user', { email: 'Invitee@Example.com', email_verified: true })
    .firestore();
  const mine = await assertSucceeds(pendingFor(invitee, 'invitee@example.com').get());
  assert.deepEqual(mine.docs.map((d) => d.id).sort(), ['inv-mine-1', 'inv-mine-2']);
  await assertSucceeds(pendingFor(invitee, 'invitee@example.com').limit(1).get());

  // Someone else's invites, or every invite, stay hidden.
  await assertFails(pendingFor(invitee, 'someone@example.com').get());
  await assertFails(invitee.collectionGroup('invites').get());

  // Signed out, or an address the user has not verified (anyone can sign up
  // with any address), lists nothing.
  await assertFails(pendingFor(testEnv.unauthenticatedContext().firestore(), 'invitee@example.com').get());
  const unverified = testEnv
    .authenticatedContext('squatter-user', { email: 'invitee@example.com', email_verified: false })
    .firestore();
  await assertFails(pendingFor(unverified, 'invitee@example.com').get());

  // The facility rule is unchanged: its owner lists its invites, its staff do not.
  const facilityInvites = (db) => db.collection('facilities').doc(FACILITY_ID).collection('invites').get();
  const ownerList = await assertSucceeds(facilityInvites(testEnv.authenticatedContext(OWNER_UID).firestore()));
  assert.equal(ownerList.size, 2);
  await assertFails(facilityInvites(testEnv.authenticatedContext(STAFF_UID).firestore()));
});

const INVITEE_UID = 'invitee-user';

async function seedPendingInvite(facilityDoc) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set(facilityDoc);
    await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').set({
      facilityId: FACILITY_ID,
      email: 'invitee@example.com',
      emailLower: 'invitee@example.com',
      roleType: 'employee',
      status: 'pending',
      invitedAt: new Date(),
      invitedBy: OWNER_UID,
    });
  });
}

function inviteeFacilityRef() {
  return testEnv
    .authenticatedContext(INVITEE_UID, { email: 'Invitee@Example.com', email_verified: true })
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID);
}

// PermissionService.assignRole's facility write when accepting an invite.
function acceptWrite(extra = {}, extraRoles = {}) {
  return inviteeFacilityRef().set(
    { roles: { [INVITEE_UID]: 'employee', ...extraRoles }, acceptingInviteId: 'inv-1', ...extra },
    { merge: true },
  );
}

test('invite accept: the invitee adds their own role and the invite id, and nothing else', async () => {
  // The rule checked changed keys, which leave out keys that are added or
  // removed. Added fields the facility doc did not have yet, and other
  // users' roles, went through.
  await seedPendingInvite({
    ownerUid: OWNER_UID,
    name: 'Test Storage',
    roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee' },
  });

  // Fields the facility doc does not have yet.
  await assertFails(
    acceptWrite({ platformSubscriptionStatus: 'trialing', stripePlatformSubscriptionId: 'sub_x' }),
  );
  await assertFails(acceptWrite({ platformSubscriptionStatus: 'trialing' }));
  await assertFails(acceptWrite({ stripePlatformSubscriptionId: 'sub_x' }));
  await assertFails(acceptWrite({ billingExempt: true }));
  await assertFails(acceptWrite({ facilityCreatorAccountId: 'account-1' }));
  await assertFails(acceptWrite({ someNewField: 'x' }));
  // Removing a field, or changing one that is there (already refused).
  await assertFails(acceptWrite({ name: deleteField() }));
  await assertFails(acceptWrite({ name: 'Renamed' }));
  // Another user's role: added, changed or removed.
  await assertFails(acceptWrite({}, { 'other-user': 'manager' }));
  await assertFails(acceptWrite({}, { [STAFF_UID]: 'manager' }));
  await assertFails(acceptWrite({}, { [STAFF_UID]: deleteField() }));
  // A role the invite does not grant (already refused).
  await assertFails(
    inviteeFacilityRef().set(
      { roles: { [INVITEE_UID]: 'manager' }, acceptingInviteId: 'inv-1' },
      { merge: true },
    ),
  );

  await assertSucceeds(acceptWrite());
  let after;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    after = (await context.firestore().collection('facilities').doc(FACILITY_ID).get()).data();
  });
  assert.deepEqual(after, {
    ownerUid: OWNER_UID,
    name: 'Test Storage',
    roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee', [INVITEE_UID]: 'employee' },
    acceptingInviteId: 'inv-1',
  });
});

test('invite accept: with no roles map yet, the new one holds only the invitee', async () => {
  await seedPendingInvite({ ownerUid: OWNER_UID, name: 'Test Storage' });

  await assertFails(acceptWrite({}, { 'other-user': 'manager' }));
  await assertFails(acceptWrite({}, { [OWNER_UID]: 'owner' }));
  await assertFails(acceptWrite({ billingExempt: true }));
  await assertSucceeds(acceptWrite());
});

test('invite accept: a later invitee overwrites acceptingInviteId and adds only their role', async () => {
  // acceptingInviteId is left on the facility by the previous accept, so a
  // second accept changes it rather than adding it.
  await seedPendingInvite({
    ownerUid: OWNER_UID,
    roles: { [OWNER_UID]: 'owner', [STAFF_UID]: 'employee' },
    acceptingInviteId: 'inv-earlier',
  });

  await assertFails(acceptWrite({ billingExempt: true }));
  await assertSucceeds(acceptWrite());
});

test('staff revoke a pending payment link and change nothing else', async () => {
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('publicPaymentLinks').doc('token-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      token: 'token-1',
      amount: 50,
      status: 'pending',
      expiresAt: new Date(Date.now() + 86400000),
    });
  });
  const linkAs = (uid) =>
    testEnv.authenticatedContext(uid).firestore().collection('publicPaymentLinks').doc('token-1');
  const revoke = { status: 'revoked', revokedAt: serverTimestamp() };

  // Fields the link does not have yet, or removing one.
  await assertFails(linkAs(STAFF_UID).update({ ...revoke, paidAt: serverTimestamp() }));
  await assertFails(linkAs(STAFF_UID).update({ ...revoke, stripePaymentIntentId: 'pi_x' }));
  await assertFails(linkAs(STAFF_UID).update({ ...revoke, expiresAt: deleteField() }));
  // Not a revoke, or not staff (already refused).
  await assertFails(linkAs(STAFF_UID).update({ status: 'paid' }));
  await assertFails(linkAs(OUTSIDER_UID).update(revoke));

  // PublicPaymentLinkService.revokePaymentLink's write.
  await assertSucceeds(linkAs(STAFF_UID).update(revoke));
});

test('facility notifications: staff may mark one read and change nothing else', async () => {
  // Written only by Cloud Functions (autopay events, and a paid online
  // move-in into a unit taken off online rental). Every client write was
  // refused, so the app's "Mark read" failed and no alert could be cleared.
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('Notifications')
      .doc('n1')
      .set({
        type: 'ONLINE_MOVE_IN_REVIEW',
        facilityId: FACILITY_ID,
        tenantId: TENANT_ID,
        message: 'Rita Renter paid online and was moved into unit L1.',
        createdAt: new Date(),
        readAt: null,
      });
  });
  const notifications = (db) =>
    db.collection('facilities').doc(FACILITY_ID).collection('Notifications');
  const staff = notifications(testEnv.authenticatedContext(STAFF_UID).firestore());
  const outsider = notifications(testEnv.authenticatedContext(OUTSIDER_UID).firestore());

  // The banner's query, as staff.
  await assertSucceeds(staff.where('type', '==', 'ONLINE_MOVE_IN_REVIEW').get());
  await assertFails(outsider.doc('n1').update({ readAt: serverTimestamp() }));
  await assertFails(staff.doc('n1').update({ readAt: 'yesterday' }));
  await assertFails(staff.doc('n1').update({ readAt: serverTimestamp(), message: 'nothing to see' }));
  await assertSucceeds(staff.doc('n1').update({ readAt: serverTimestamp() }));
  await assertFails(staff.doc('n1').update({ type: 'AUTOPAY_ENABLED' }));
  await assertFails(staff.doc('n1').delete());
  await assertFails(staff.doc('n2').set({ type: 'ONLINE_MOVE_IN_REVIEW', message: 'forged', readAt: null }));
});
