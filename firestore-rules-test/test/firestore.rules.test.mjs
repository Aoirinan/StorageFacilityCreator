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
      name: 'Pinewood',
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
  await assertSucceeds(facilityRef.update({ name: 'Pinewood Storage' }));

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
  const SLUG = 'pinewood-self-storage';
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

/** [facilityDoc] as the facility, with a pending employee invite 'inv-1'. */
async function seedPendingInviteOn(facilityDoc) {
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

function inviteeAcceptDb() {
  return testEnv
    .authenticatedContext(INVITEE_UID, { email: 'Invitee@Example.com', email_verified: true })
    .firestore();
}

// PermissionService.assignRole's facility write when accepting an invite,
// in the batch that also marks the invite accepted by the invitee (the
// rules take the roles entry only from the write that spends the invite;
// see acceptanceBatch below for the role row too). [spend]: false sends the
// facility write alone.
function acceptWrite(extra = {}, extraRoles = {}, { role = 'employee', spend = true } = {}) {
  const db = inviteeAcceptDb();
  const facilityRef = db.collection('facilities').doc(FACILITY_ID);
  const batch = db.batch();
  batch.set(
    facilityRef,
    { roles: { [INVITEE_UID]: role, ...extraRoles }, acceptingInviteId: 'inv-1', ...extra },
    { merge: true },
  );
  if (spend) {
    batch.update(facilityRef.collection('invites').doc('inv-1'), {
      status: 'accepted',
      acceptedAt: new Date(),
      acceptedBy: INVITEE_UID,
    });
  }
  return batch.commit();
}

test('invite accept: the invitee adds their own role and the invite id, and nothing else', async () => {
  // The rule checked changed keys, which leave out keys that are added or
  // removed. Added fields the facility doc did not have yet, and other
  // users' roles, went through.
  await seedPendingInviteOn({
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
  await assertFails(acceptWrite({}, {}, { role: 'manager' }));
  // The right write, but not in the batch that spends the invite.
  await assertFails(acceptWrite({}, {}, { spend: false }));

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
  await seedPendingInviteOn({ ownerUid: OWNER_UID, name: 'Test Storage' });

  await assertFails(acceptWrite({}, { 'other-user': 'manager' }));
  await assertFails(acceptWrite({}, { [OWNER_UID]: 'owner' }));
  await assertFails(acceptWrite({ billingExempt: true }));
  await assertSucceeds(acceptWrite());
});

test('invite accept: a later invitee overwrites acceptingInviteId and adds only their role', async () => {
  // acceptingInviteId is left on the facility by the previous accept, so a
  // second accept changes it rather than adding it.
  await seedPendingInviteOn({
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

test("gate codes: a super admin with no role can read a tenant's and switch it off, as Unassign Tenant does", async () => {
  // Unassign Tenant of a tenant's only unit (and archive, and switching them
  // off) turns their gate codes off in the same transaction. For a super
  // admin with no role at the facility the gateAccess read and update were
  // refused, so the whole unassign failed where it used to succeed.
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('gateAccess').doc('g1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      accessCode: '1234',
      isActive: true,
      createdAt: new Date(),
      updatedAt: new Date(),
      createdBy: OWNER_UID,
    });
  });
  const gates = (context) => context.firestore().collection('facilities').doc(FACILITY_ID).collection('gateAccess');
  const off = (uid) => ({ isActive: false, updatedAt: serverTimestamp(), updatedBy: uid });

  const outsider = gates(testEnv.authenticatedContext(OUTSIDER_UID));
  await assertFails(outsider.where('tenantId', '==', TENANT_ID).get());
  await assertFails(outsider.doc('g1').update(off(OUTSIDER_UID)));

  const admin = gates(testEnv.authenticatedContext('admin-user', { superadmin: true }));
  await assertSucceeds(admin.where('tenantId', '==', TENANT_ID).get());
  // Still stamped with the caller, as for staff.
  await assertFails(admin.doc('g1').update(off(OWNER_UID)));
  await assertSucceeds(admin.doc('g1').update(off('admin-user')));
  await assertSucceeds(gates(testEnv.authenticatedContext(STAFF_UID)).doc('g1').update(off(STAFF_UID)));
});

test('gate codes: a super admin with no role can only switch one off, nothing else', async () => {
  // Least privilege: Unassign Tenant needs isActive false stamped with the
  // caller, no more. Staff keep their wider update.
  await seedFacility();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('gateAccess').doc('g2').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      accessCode: '5678',
      isActive: true,
      createdAt: new Date(),
      updatedAt: new Date(),
      createdBy: OWNER_UID,
    });
  });
  const gates = (context) => context.firestore().collection('facilities').doc(FACILITY_ID).collection('gateAccess');
  const admin = gates(testEnv.authenticatedContext('admin-user', { superadmin: true }));
  const stamp = { updatedAt: serverTimestamp(), updatedBy: 'admin-user' };

  // Not on, not a new code, hours or tenant, even alongside switching it off.
  await assertFails(admin.doc('g2').update({ ...stamp, isActive: true }));
  await assertFails(admin.doc('g2').update({ ...stamp, isActive: false, accessCode: '0000' }));
  await assertFails(admin.doc('g2').update({ ...stamp, isActive: false, tenantId: 'someone-else' }));
  await assertFails(admin.doc('g2').update({ ...stamp, isActive: false, allowedDays: ['Mon'] }));
  await assertFails(admin.doc('g2').update({ ...stamp, accessCode: '0000' }));
  // Off, stamped with the caller: allowed; again once off (the same write) too.
  await assertSucceeds(admin.doc('g2').update({ ...stamp, isActive: false }));
  await assertSucceeds(admin.doc('g2').update({ ...stamp, isActive: false }));
  // Switched off, a super admin cannot switch it back on; staff can.
  await assertFails(admin.doc('g2').update({ ...stamp, isActive: true }));
  const staff = gates(testEnv.authenticatedContext(STAFF_UID));
  await assertSucceeds(staff.doc('g2').update({ isActive: true, accessCode: '9999', updatedAt: serverTimestamp(), updatedBy: STAFF_UID }));
  // A super admin still cannot create or delete one.
  await assertFails(admin.doc('g3').set({
    facilityId: FACILITY_ID,
    accessCode: '1111',
    isActive: true,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    createdBy: 'admin-user',
  }));
  await assertFails(admin.doc('g2').delete());
});

// ---- Invite acceptance, team removal and invite records (PermissionService) ----

// INVITEE_UID is declared with the invite-accept tests above.
const INVITEE_EMAIL = 'invitee@example.com';
const MANAGER_UID = 'manager-user';
const COOWNER_UID = 'coowner-user';
const ADMIN_UID = 'admin-user';

function inviteeDb(uid = INVITEE_UID, email = INVITEE_EMAIL) {
  return testEnv.authenticatedContext(uid, { email, email_verified: true }).firestore();
}

/** A facility with its owner, and a pending invite for INVITEE_EMAIL. */
async function seedPendingInvite({ status = 'pending', facility = {} } = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      name: 'Maple Storage',
      roles: { [OWNER_UID]: 'owner' },
      ...facility,
    });
    await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').set({
      facilityId: FACILITY_ID,
      email: INVITEE_EMAIL,
      emailLower: INVITEE_EMAIL,
      roleType: 'employee',
      status,
      invitedBy: OWNER_UID,
      invitedByEmail: 'owner@example.com',
      invitedAt: new Date('2026-09-20T12:00:00Z'),
    });
  });
}

/** The role row id an acceptance of [inviteId] writes (PermissionService.inviteRoleDocId). */
function inviteRoleDocId(inviteId, facilityId = FACILITY_ID) {
  return `${facilityId}_${inviteId}`;
}

/**
 * PermissionService.assignRole's acceptance batch, as the invitee sends it,
 * for invite [inviteId]: the role row at the invite's own id (a plain set,
 * so it creates the row or, for an invite the owner reopened, rewrites it),
 * the roles-map entry, and the invite marked accepted. [roleDocId] writes the
 * row at another id. [writeRow], [writeRoles] and [markAccepted]: false
 * leaves out the role row, the roles-map entry or marking the invite accepted.
 */
function acceptanceBatch(
  db,
  {
    inviteId = 'inv-1',
    roleDocId = inviteRoleDocId(inviteId),
    roles,
    roleType = 'employee',
    facilityExtra = {},
    inviteExtra = {},
    writeRow = true,
    writeRoles = true,
    markAccepted = true,
  } = {},
) {
  const batch = db.batch();
  const roleRef = db.collection('user_roles').doc(roleDocId);
  const row = {
    userId: INVITEE_UID,
    facilityId: FACILITY_ID,
    roleType,
    assignedBy: OWNER_UID,
    assignedAt: new Date(),
    expiresAt: null,
    isActive: true,
    updatedAt: new Date(),
    userEmail: INVITEE_EMAIL,
    inviteId,
  };
  if (writeRow) {
    batch.set(roleRef, { ...row, createdAt: new Date() });
  }
  if (writeRoles) {
    batch.set(
      db.collection('facilities').doc(FACILITY_ID),
      { roles: roles ?? { [INVITEE_UID]: roleType }, acceptingInviteId: inviteId, ...facilityExtra },
      { merge: true },
    );
  }
  if (markAccepted) {
    batch.update(db.collection('facilities').doc(FACILITY_ID).collection('invites').doc(inviteId), {
      status: 'accepted',
      acceptedAt: new Date(),
      acceptedBy: INVITEE_UID,
      ...inviteExtra,
    });
  }
  return batch;
}

test('an invitee accepts a pending invite in one batch: role row, roles map and invite', async () => {
  // Written one after another, an acceptance that failed after the role row
  // left an active row the rules ignore and the invite pending. As one batch
  // each write is checked against the invite as it was before the batch, so
  // marking it accepted in the same commit still lets the other two through.
  await seedPendingInvite();
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const facility = (await db.collection('facilities').doc(FACILITY_ID).get()).data();
    assert.equal(facility.roles[INVITEE_UID], 'employee');
    const invite = (await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').get()).data();
    assert.equal(invite.status, 'accepted');
    assert.equal(invite.acceptedBy, INVITEE_UID);
    assert.equal((await db.collection('user_roles').doc(inviteRoleDocId('inv-1')).get()).data().isActive, true);
  });

  // Their facility is readable now, and the invite, once accepted, is spent.
  await assertSucceeds(inviteeDb().collection('facilities').doc(FACILITY_ID).get());
  await assertFails(acceptanceBatch(inviteeDb()).commit());
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'role-again' }).commit());
});

test('an acceptance that stopped part-way is finished by the same batch, beside the row it left', async () => {
  // What the old two-write acceptance left: an active row for the invite (at
  // an id of any shape), no roles-map entry, the invite still pending. The
  // invitee may not write that row now (it is not the invite's own id); the
  // batch writes the invite's row, and the old one stays as it was.
  await seedPendingInvite();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('user_roles').doc('role-half').set({
      userId: INVITEE_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      assignedAt: new Date('2026-09-21T12:00:00Z'),
      isActive: true,
      inviteId: 'inv-1',
    });
  });
  // Their own rows are readable for PermissionService._isNewInvitee.
  await assertSucceeds(inviteeDb().collection('user_roles').where('userId', '==', INVITEE_UID).limit(20).get());
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'role-half' }).commit());
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = await context.firestore().collection('user_roles').where('userId', '==', INVITEE_UID).get();
    assert.deepEqual(rows.docs.map((d) => d.id).sort(), [inviteRoleDocId('inv-1'), 'role-half'].sort());
  });
});

test("one acceptance writes one role row: the invite's own", async () => {
  // Every write in the batch sees the invite pending before it and spent
  // after it, so with any id allowed one acceptance could write several
  // active rows for the one invite, and the callables that charge cards take
  // any one active row as access.
  const row = (inviteId = 'inv-1') => ({
    userId: INVITEE_UID,
    facilityId: FACILITY_ID,
    roleType: 'employee',
    assignedBy: OWNER_UID,
    assignedAt: new Date(),
    isActive: true,
    userEmail: INVITEE_EMAIL,
    inviteId,
  });
  const attempts = {
    'a second row at another id': (db, batch) => batch.set(db.collection('user_roles').doc('role-extra'), row()),
    'a second row at a made-up id': (db, batch) =>
      batch.set(db.collection('user_roles').doc(`${FACILITY_ID}_inv-1_2`), row()),
    'their old row switched back on for the same invite': (db, batch) =>
      batch.set(db.collection('user_roles').doc('role-old'), row()),
    "the row at another facility's id for it": (db, batch) =>
      batch.set(db.collection('user_roles').doc(inviteRoleDocId('inv-1', 'fac-other')), row()),
  };
  for (const [label, addRow] of Object.entries(attempts)) {
    await testEnv.clearFirestore();
    await seedPendingInvite();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      // A row of theirs from before, taken out of use by a removal.
      await context.firestore().collection('user_roles').doc('role-old').set({ ...row('inv-0'), isActive: false });
    });
    const db = inviteeDb();
    const batch = acceptanceBatch(db);
    addRow(db, batch);
    await assertFails(batch.commit()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  // Nor the one row alone at any other id.
  await testEnv.clearFirestore();
  await seedPendingInvite();
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'role-new' }).commit());
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'inv-1' }).commit());

  // The app's batch passes, and writes that one row.
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = await context.firestore().collection('user_roles').get();
    assert.deepEqual(rows.docs.map((d) => d.id), [inviteRoleDocId('inv-1')]);
  });
});

test('an invite the owner reopened is accepted again into its own row, and only that row', async () => {
  // The only way the invite's row is there already while the invite is pending.
  await seedPendingInvite();
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = context.firestore().collection('user_roles');
    await rows.doc(inviteRoleDocId('inv-1')).update({ isActive: false });
    await rows.doc('role-other').set({
      userId: INVITEE_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: false,
      inviteId: 'inv-0',
    });
  });
  const owner = testEnv
    .authenticatedContext(OWNER_UID, { email: 'owner@example.com', email_verified: true })
    .firestore();
  await assertSucceeds(
    owner.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').update({ status: 'pending' }),
  );
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'role-other' }).commit());
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = context.firestore().collection('user_roles');
    assert.equal((await rows.doc(inviteRoleDocId('inv-1')).get()).data().isActive, true);
    assert.equal((await rows.doc('role-other').get()).data().isActive, false);
  });
});

test('role rows written before invites fixed their ids keep working', async () => {
  // The rows in production are owners' rows, with ids of any shape
  // (owner-<facility> from the app, generated ones from the create-for-owner
  // callable).
  await seedPendingInvite();
  const legacyIds = [`owner-${FACILITY_ID}`, 'Xy7Qk2mZ9aB4cD6eF8gH'];
  await testEnv.withSecurityRulesDisabled(async (context) => {
    for (const id of legacyIds) {
      await context.firestore().collection('user_roles').doc(id).set({
        userId: OWNER_UID,
        facilityId: FACILITY_ID,
        roleType: 'owner',
        assignedBy: OWNER_UID,
        isActive: true,
      });
    }
  });
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const mine = await assertSucceeds(
    owner.collection('user_roles').where('userId', '==', OWNER_UID).where('isActive', '==', true).get(),
  );
  assert.deepEqual(mine.docs.map((d) => d.id).sort(), [...legacyIds].sort());
  await assertSucceeds(
    owner.collection('user_roles').where('facilityId', '==', FACILITY_ID).where('isActive', '==', true).get(),
  );
  for (const id of legacyIds) {
    await assertSucceeds(owner.collection('user_roles').doc(id).get());
    await assertSucceeds(owner.collection('user_roles').doc(id).set({ updatedAt: new Date() }, { merge: true }));
  }
  // The owner still writes a row for someone at an id of any shape (Change
  // Role for someone with none), and support its own manager row.
  await assertSucceeds(
    owner.collection('user_roles').doc('role-direct').set({
      userId: STAFF_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
    }),
  );
  const support = testEnv
    .authenticatedContext('support-user', { email: 'support@example.com', email_verified: true, superadmin: true })
    .firestore();
  await assertSucceeds(
    support.collection('user_roles').doc('role-support').set({
      userId: 'support-user',
      facilityId: FACILITY_ID,
      roleType: 'manager',
      assignedBy: 'support-user',
      isActive: true,
    }),
  );
});

test('an invitee writes only their own roles entry: no one else, no other field', async () => {
  // The merge rule used changedKeys, which leaves out added keys: an
  // invitee could add another user as 'owner', a legacy managers map naming
  // themselves, or billing fields the facility did not have yet.
  const attempts = {
    'another user as owner': { roles: { [INVITEE_UID]: 'employee', [OUTSIDER_UID]: 'owner' } },
    'a higher role for themselves': { roles: { [INVITEE_UID]: 'manager' } },
    'a legacy managers map': { facilityExtra: { managers: { [INVITEE_UID]: true } } },
    'a billing field': { facilityExtra: { platformSubscriptionStatus: 'active' } },
    'a new field': { facilityExtra: { name2: 'mine' } },
  };
  for (const [label, attempt] of Object.entries(attempts)) {
    await testEnv.clearFirestore();
    await seedPendingInvite();
    await assertFails(acceptanceBatch(inviteeDb(), attempt).commit()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }

  // Nor on a facility with no roles map yet.
  await testEnv.clearFirestore();
  await seedPendingInvite({ facility: { roles: null } });
  await assertFails(
    acceptanceBatch(inviteeDb(), { roles: { [INVITEE_UID]: 'employee', [OUTSIDER_UID]: 'owner' } }).commit(),
  );
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
});

test('an invite gives a role once: its role row and roles entry only in the batch that accepts it', async () => {
  // Left pending, the invite could be used again. An invitee who joined
  // with a role row carrying no address of theirs (userEmail is theirs to
  // write), or with a roles-map entry alone, gave removeRole nothing to find
  // the invite by: it stayed pending and let them back in after every
  // removal. A row written while the invite said manager also stayed active
  // after the owner changed it to viewer, and the callables that charge
  // cards take an active manager row as access.
  const unspent = {
    'a role row and roles entry': {},
    'a roles entry alone': { writeRow: false },
    'a role row alone': { writeRoles: false },
    'finishing a part-way acceptance': { roleDocId: 'role-half' },
  };
  for (const [label, options] of Object.entries(unspent)) {
    await testEnv.clearFirestore();
    await seedPendingInvite();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await context.firestore().collection('user_roles').doc('role-half').set({
        userId: INVITEE_UID,
        facilityId: FACILITY_ID,
        roleType: 'employee',
        assignedBy: OWNER_UID,
        isActive: true,
        inviteId: 'inv-1',
      });
    });
    await assertFails(acceptanceBatch(inviteeDb(), { ...options, markAccepted: false }).commit()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }

  // Nor a row planted while the invite was a manager's, before the owner
  // lowered it: the acceptance that follows gives the lower role only.
  await testEnv.clearFirestore();
  await seedPendingInvite();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').update({
      roleType: 'manager',
    });
  });
  await assertFails(
    acceptanceBatch(inviteeDb(), { roleDocId: 'role-plant', roleType: 'manager', writeRoles: false, markAccepted: false })
      .commit(),
  );
  await assertSucceeds(
    testEnv
      .authenticatedContext(OWNER_UID)
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('invites')
      .doc('inv-1')
      .update({ roleType: 'employee' }),
  );
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = await context.firestore().collection('user_roles').where('userId', '==', INVITEE_UID).get();
    assert.deepEqual(rows.docs.map((d) => [d.id, d.data().roleType]), [[inviteRoleDocId('inv-1'), 'employee']]);
  });

  // Spent, it gives nothing more: not its row again, not another row, not the roles entry again.
  await assertFails(acceptanceBatch(inviteeDb(), { markAccepted: false }).commit());
  await assertFails(acceptanceBatch(inviteeDb(), { roleDocId: 'role-again', markAccepted: false }).commit());
  await assertFails(acceptanceBatch(inviteeDb(), { writeRow: false, markAccepted: false }).commit());
});

test('a removed team member cannot mark their cancelled invite accepted', async () => {
  // It gave no access back, but it overwrote the record of the cancellation.
  await seedPendingInvite({ status: 'cancelled' });
  const invite = inviteeDb().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1');
  await assertSucceeds(invite.get());
  await assertFails(invite.update({ status: 'accepted', acceptedAt: new Date(), acceptedBy: INVITEE_UID }));
  await assertFails(acceptanceBatch(inviteeDb()).commit());

  // A pending one they may still accept.
  await testEnv.clearFirestore();
  await seedPendingInvite();
  await assertSucceeds(
    inviteeDb()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('invites')
      .doc('inv-1')
      .update({ status: 'accepted', acceptedAt: new Date(), acceptedBy: INVITEE_UID }),
  );
});

/** A team: the owner, a manager who joined by invite, and an employee. */
async function seedTeam({ facility = {} } = {}) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      name: 'Maple Storage',
      roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager', [STAFF_UID]: 'employee' },
      ...facility,
    });
    await db.collection('user_roles').doc('role-staff').set({
      userId: STAFF_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
      userEmail: 'staff@example.com',
    });
    await db.collection('user_roles').doc('role-owner').set({
      userId: OWNER_UID,
      facilityId: FACILITY_ID,
      roleType: 'owner',
      assignedBy: 'system',
      isActive: true,
    });
    const invites = db.collection('facilities').doc(FACILITY_ID).collection('invites');
    await invites.doc('inv-staff-old').set({
      facilityId: FACILITY_ID,
      email: 'staff@example.com',
      emailLower: 'staff@example.com',
      roleType: 'employee',
      status: 'accepted',
      acceptedBy: STAFF_UID,
      invitedBy: OWNER_UID,
      invitedAt: new Date('2026-09-01T12:00:00Z'),
    });
    await invites.doc('inv-staff-new').set({
      facilityId: FACILITY_ID,
      email: 'staff@example.com',
      emailLower: 'staff@example.com',
      roleType: 'manager',
      status: 'pending',
      invitedBy: OWNER_UID,
      invitedAt: new Date('2026-09-20T12:00:00Z'),
    });
  });
}

/**
 * PermissionService.removeRole, as [actorUid] runs it for [uid] (known here
 * by [emailLower], an address the app takes as theirs: an invite they
 * accepted, say), with its reads: the facility, the user's active rows, the
 * invites they accepted, and the facility's pending invites (listed, never
 * read by id; those to [emailLower], to the address on an invite a row names,
 * or sent by [uid] are cancelled). The same batch logs the removal in the
 * facility's auditLogs, as the app writes it (AuditLogEntry). [healFacilityId]:
 * false leaves out the facilityId the app writes on each cancelled invite.
 */
async function removeMember(actorUid, uid, emailLower, { healFacilityId = true } = {}) {
  const actorEmail = `${actorUid}@example.com`;
  const db = testEnv.authenticatedContext(actorUid, { email: actorEmail, email_verified: true }).firestore();
  const facilityData = (await db.collection('facilities').doc(FACILITY_ID).get()).data();
  const roles = await db
    .collection('user_roles')
    .where('userId', '==', uid)
    .where('facilityId', '==', FACILITY_ID)
    .where('isActive', '==', true)
    .get();
  const invites = db.collection('facilities').doc(FACILITY_ID).collection('invites');
  await invites.where('acceptedBy', '==', uid).get();
  const rowInviteIds = new Set(roles.docs.map((doc) => doc.data().inviteId));
  const listed = (await invites.where('status', '==', 'pending').get()).docs;
  const emails = new Set([
    emailLower,
    ...listed.filter((doc) => rowInviteIds.has(doc.id)).map((doc) => doc.data().emailLower),
  ]);
  const pending = listed.filter((doc) => emails.has(doc.data().emailLower) || doc.data().invitedBy === uid);
  const batch = db.batch();
  const actorRole = facilityData.ownerUid === actorUid ? 'owner' : facilityData.roles?.[actorUid] ?? 'manager';
  const removedRole = facilityData.roles?.[uid] ?? (facilityData.managers?.[uid] === true ? 'manager' : null);
  const now = new Date();
  batch.set(db.collection('facilities').doc(FACILITY_ID).collection('auditLogs').doc(), {
    eventType: 'team.memberRemoved',
    actorUid,
    actorEmail,
    actorRole,
    targetType: 'user',
    targetId: uid,
    facilityId: FACILITY_ID,
    before: { role: removedRole },
    after: { role: null },
    timestamp: now,
    metadata: { removedUserId: uid, removedRole, invitesCancelled: pending.length, actorRole },
    action: 'team.memberRemoved',
    entityType: 'user',
    entityId: uid,
    userId: actorUid,
    userEmail: actorEmail,
    changes: { before: { role: removedRole }, after: { role: null } },
  });
  for (const doc of pending) {
    batch.update(doc.ref, {
      status: 'cancelled',
      cancelledAt: new Date(),
      cancelledReason: 'access_removed',
      ...(healFacilityId ? { facilityId: FACILITY_ID } : {}),
    });
  }
  for (const doc of roles.docs) {
    batch.set(doc.ref, { isActive: false, updatedAt: new Date() }, { merge: true });
  }
  batch.set(
    db.collection('facilities').doc(FACILITY_ID),
    { roles: { [uid]: deleteField() }, managers: { [uid]: deleteField() } },
    { merge: true },
  );
  await batch.commit();
}

const removeStaff = (actorUid) => removeMember(actorUid, STAFF_UID, 'staff@example.com');

test('a manager who joined by invite can remove a team member, in one batch', async () => {
  // The user_roles read rule knew only the owner and the legacy managers map,
  // and only the owner could write the facility: a manager's removal was
  // refused at its first read.
  await seedTeam();
  const manager = testEnv.authenticatedContext(MANAGER_UID).firestore();
  await assertSucceeds(
    manager.collection('user_roles').where('facilityId', '==', FACILITY_ID).where('isActive', '==', true).get(),
  );
  await assertSucceeds(removeStaff(MANAGER_UID));

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const facility = (await db.collection('facilities').doc(FACILITY_ID).get()).data();
    assert.deepEqual(Object.keys(facility.roles).sort(), [MANAGER_UID, OWNER_UID].sort());
    assert.equal((await db.collection('user_roles').doc('role-staff').get()).data().isActive, false);
    const invites = db.collection('facilities').doc(FACILITY_ID).collection('invites');
    assert.equal((await invites.doc('inv-staff-new').get()).data().status, 'cancelled');
    assert.equal((await invites.doc('inv-staff-old').get()).data().status, 'accepted');
    // Logged in the same batch, so the owner sees which manager removed whom.
    const logs = (await db.collection('facilities').doc(FACILITY_ID).collection('auditLogs').get()).docs;
    assert.deepEqual(
      logs.map((d) => [d.data().eventType, d.data().actorUid, d.data().targetId]),
      [['team.memberRemoved', MANAGER_UID, STAFF_UID]],
    );
  });
});

test('a removal also cancels the invites the removed member sent', async () => {
  // A manager could invite a second login of their own as manager; once the
  // owner removed them, that login accepted and they were back. Managers no
  // longer invite, but one sent before that is still pending.
  await seedTeam();
  const altInvite = {
    facilityId: FACILITY_ID,
    email: 'mgr-alt@example.com',
    emailLower: 'mgr-alt@example.com',
    roleType: 'manager',
    status: 'pending',
    invitedBy: MANAGER_UID,
    invitedAt: new Date(),
  };
  await assertFails(invitesAs(MANAGER_UID, 'manager@example.com').doc('inv-alt').set(altInvite));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-alt').set(altInvite);
  });
  await assertSucceeds(removeMember(OWNER_UID, MANAGER_UID, 'manager@example.com'));

  const alt = testEnv.authenticatedContext('mgr-alt-user', { email: 'mgr-alt@example.com', email_verified: true }).firestore();
  const altAcceptance = alt.batch();
  altAcceptance.set(alt.collection('user_roles').doc(inviteRoleDocId('inv-alt')), {
    userId: 'mgr-alt-user',
    facilityId: FACILITY_ID,
    roleType: 'manager',
    assignedBy: MANAGER_UID,
    isActive: true,
    inviteId: 'inv-alt',
  });
  altAcceptance.set(
    alt.collection('facilities').doc(FACILITY_ID),
    { roles: { 'mgr-alt-user': 'manager' }, acceptingInviteId: 'inv-alt' },
    { merge: true },
  );
  altAcceptance.update(alt.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-alt'), {
    status: 'accepted',
    acceptedAt: new Date(),
    acceptedBy: 'mgr-alt-user',
  });
  await assertFails(altAcceptance.commit());

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const invites = context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites');
    assert.equal((await invites.doc('inv-alt').get()).data().status, 'cancelled');
    // Not the owner's invite to someone else.
    assert.equal((await invites.doc('inv-staff-new').get()).data().status, 'pending');
  });
});

test("a row naming a cancelled invite does not stop its user's removal", async () => {
  // Cancel Invite deletes the invite, and a get of an invite that is not
  // there is refused even to the owner, so removeRole lists the facility's
  // pending invites rather than reading each row's invite by id: that one
  // refused read failed the whole removal.
  await seedTeam();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('user_roles').doc('role-staff').set({ inviteId: 'inv-deleted' }, { merge: true });
  });
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  const manager = testEnv.authenticatedContext(MANAGER_UID).firestore();
  const deleted = (db) => db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-deleted');
  await assertFails(deleted(owner).get());
  await assertFails(deleted(manager).get());

  await assertSucceeds(removeStaff(MANAGER_UID));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal((await db.collection('user_roles').doc('role-staff').get()).data().isActive, false);
    const facility = (await db.collection('facilities').doc(FACILITY_ID).get()).data();
    assert.equal(facility.roles[STAFF_UID], undefined);
    const invite = await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-staff-new').get();
    assert.equal(invite.data().status, 'cancelled');
  });
});

test('the owner removes a legacy manager from both maps', async () => {
  // removeRole left managers.<uid>, which isFacilityOwnerOrManager still
  // reads, so a removed legacy manager kept their access.
  await seedTeam({ facility: { managers: { [STAFF_UID]: true } } });
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  await assertSucceeds(removeStaff(OWNER_UID));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const facility = (await context.firestore().collection('facilities').doc(FACILITY_ID).get()).data();
    assert.equal(facility.managers[STAFF_UID], undefined);
    assert.equal(facility.roles[STAFF_UID], undefined);
  });
  await assertFails(
    testEnv.authenticatedContext(STAFF_UID).firestore().collection('facilities').doc(FACILITY_ID).get(),
  );
});

test("a manager's facility write may only take team members out", async () => {
  await seedTeam({
    facility: {
      managers: { [OUTSIDER_UID]: true, [OWNER_UID]: true },
      roles: {
        [OWNER_UID]: 'owner',
        [MANAGER_UID]: 'manager',
        [STAFF_UID]: 'employee',
        [COOWNER_UID]: 'owner',
        [ADMIN_UID]: 'admin',
      },
    },
  });
  const facility = testEnv.authenticatedContext(MANAGER_UID).firestore().collection('facilities').doc(FACILITY_ID);
  // Never the owner.
  await assertFails(facility.set({ roles: { [OWNER_UID]: deleteField() } }, { merge: true }));
  await assertFails(facility.set({ managers: { [OWNER_UID]: deleteField() } }, { merge: true }));
  // Nor anyone the roles map names owner or admin, alone or with someone
  // else: only ownerUid was protected, so a manager could take a co-owner off
  // the team.
  await assertFails(facility.set({ roles: { [COOWNER_UID]: deleteField() } }, { merge: true }));
  await assertFails(facility.set({ roles: { [ADMIN_UID]: deleteField() } }, { merge: true }));
  await assertFails(
    facility.set({ roles: { [STAFF_UID]: deleteField(), [COOWNER_UID]: deleteField() } }, { merge: true }),
  );
  // Nobody added or promoted, in either map.
  await assertFails(facility.set({ roles: { [OUTSIDER_UID]: 'owner' } }, { merge: true }));
  await assertFails(facility.set({ roles: { [STAFF_UID]: 'manager' } }, { merge: true }));
  await assertFails(facility.set({ managers: { [STAFF_UID]: true } }, { merge: true }));
  // Nothing else on the facility, even alongside a removal.
  await assertFails(facility.set({ roles: { [STAFF_UID]: deleteField() }, name: 'Mine now' }, { merge: true }));
  await assertFails(facility.update({ name: 'Mine now' }));
  // A removal from either map is fine.
  await assertSucceeds(facility.set({ managers: { [OUTSIDER_UID]: deleteField() } }, { merge: true }));
  await assertSucceeds(facility.set({ roles: { [STAFF_UID]: deleteField() } }, { merge: true }));
  // The owner takes out a co-owner and an admin.
  const asOwner = testEnv.authenticatedContext(OWNER_UID).firestore().collection('facilities').doc(FACILITY_ID);
  await assertSucceeds(
    asOwner.set({ roles: { [COOWNER_UID]: deleteField(), [ADMIN_UID]: deleteField() } }, { merge: true }),
  );
});

test('an employee can neither read the team rows nor remove anyone', async () => {
  await seedTeam();
  const employee = testEnv.authenticatedContext(STAFF_UID).firestore();
  await assertFails(
    employee.collection('user_roles').where('facilityId', '==', FACILITY_ID).where('isActive', '==', true).get(),
  );
  await assertFails(
    employee.collection('facilities').doc(FACILITY_ID).set({ roles: { [MANAGER_UID]: deleteField() } }, { merge: true }),
  );
  await assertFails(
    employee.collection('user_roles').doc('role-owner').set({ isActive: false }, { merge: true }),
  );
});

test("a manager may only take a team member's row out of use, never an owner's or admin's", async () => {
  // The row is what the app reads for someone's role, and the callables that
  // charge cards take an active one as access. A manager could make a removed
  // team member an active manager again, or demote a co-owner.
  const EX_MANAGER_UID = 'ex-manager-user';
  await seedTeam();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const rows = context.firestore().collection('user_roles');
    await rows.doc('role-removed').set({
      userId: 'removed-user',
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: EX_MANAGER_UID,
      isActive: false,
    });
    await rows.doc('role-coowner').set({
      userId: COOWNER_UID,
      facilityId: FACILITY_ID,
      roleType: 'owner',
      assignedBy: OWNER_UID,
      isActive: true,
    });
    await rows.doc('role-admin').set({
      userId: ADMIN_UID,
      facilityId: FACILITY_ID,
      roleType: 'admin',
      assignedBy: OWNER_UID,
      isActive: true,
    });
  });
  const rows = testEnv.authenticatedContext(MANAGER_UID).firestore().collection('user_roles');
  const off = { isActive: false, updatedAt: new Date() };

  await assertFails(rows.doc('role-removed').update({ isActive: true, roleType: 'manager' }));
  await assertFails(rows.doc('role-removed').update({ isActive: true }));
  await assertFails(rows.doc('role-staff').update({ roleType: 'owner' }));
  await assertFails(rows.doc('role-staff').update({ roleType: 'viewer' }));
  await assertFails(rows.doc('role-staff').update({ ...off, roleType: 'viewer' }));
  await assertFails(rows.doc('role-owner').update(off));
  await assertFails(rows.doc('role-owner').update({ roleType: 'viewer' }));
  await assertFails(rows.doc('role-coowner').update(off));
  await assertFails(rows.doc('role-admin').update(off));
  await assertFails(rows.doc('role-staff').delete());
  // removeRole's write.
  await assertSucceeds(rows.doc('role-staff').set(off, { merge: true }));

  // Whoever assigned a row, once off the team, has no say over it.
  const exManager = testEnv.authenticatedContext(EX_MANAGER_UID).firestore().collection('user_roles');
  await assertFails(exManager.doc('role-removed').update({ isActive: true, roleType: 'manager' }));
  await assertFails(exManager.doc('role-removed').delete());

  // A legacy manager may not assign a role directly or delete a row either;
  // managers invite.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).set({ managers: { legacy: true } }, { merge: true });
  });
  const legacy = testEnv.authenticatedContext('legacy').firestore().collection('user_roles');
  await assertFails(
    legacy.doc('role-new').set({
      userId: OUTSIDER_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: 'legacy',
      isActive: true,
    }),
  );
  await assertFails(legacy.doc('role-coowner').delete());

  // The owner still may do all of it, as before.
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore().collection('user_roles');
  await assertSucceeds(owner.doc('role-removed').update({ isActive: true, roleType: 'manager' }));
  await assertSucceeds(owner.doc('role-coowner').update(off));
  await assertSucceeds(
    owner.doc('role-new').set({
      userId: OUTSIDER_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
    }),
  );
  await assertSucceeds(owner.doc('role-admin').delete());
});

test('a manager cannot take a co-owner off the team through removeRole', async () => {
  await seedTeam({ facility: { roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager', [COOWNER_UID]: 'owner' } } });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('user_roles').doc('role-coowner').set({
      userId: COOWNER_UID,
      facilityId: FACILITY_ID,
      roleType: 'owner',
      assignedBy: OWNER_UID,
      isActive: true,
      userEmail: 'coowner@example.com',
    });
  });
  const manager = testEnv.authenticatedContext(MANAGER_UID).firestore();
  await assertFails(removeMember(MANAGER_UID, COOWNER_UID, 'coowner@example.com'));
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  await assertSucceeds(removeMember(OWNER_UID, COOWNER_UID, 'coowner@example.com'));
});

test('a team member who joined by invite and was removed cannot come back through it', async () => {
  // The whole round trip, through the app's own batches: accepted, then
  // removed by a manager. Each piece is tested alone above; this checks they
  // hold together, since a removal only sticks if every way back is shut.
  await seedPendingInvite({ facility: { roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager' } } });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    // A second invite to them, sent before the removal.
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-2').set({
      facilityId: FACILITY_ID,
      email: INVITEE_EMAIL,
      emailLower: INVITEE_EMAIL,
      roleType: 'manager',
      status: 'pending',
      invitedBy: OWNER_UID,
      invitedAt: new Date('2026-09-21T12:00:00Z'),
    });
  });
  const invitee = inviteeDb();
  const facility = invitee.collection('facilities').doc(FACILITY_ID);
  await assertSucceeds(acceptanceBatch(invitee).commit());
  await assertSucceeds(facility.get());

  const manager = testEnv.authenticatedContext(MANAGER_UID).firestore();
  await assertSucceeds(removeMember(MANAGER_UID, INVITEE_UID, INVITEE_EMAIL));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal((await db.collection('facilities').doc(FACILITY_ID).get()).data().roles[INVITEE_UID], undefined);
    assert.equal((await db.collection('user_roles').doc(inviteRoleDocId('inv-1')).get()).data().isActive, false);
    const invites = db.collection('facilities').doc(FACILITY_ID).collection('invites');
    assert.equal((await invites.doc('inv-1').get()).data().status, 'accepted');
    assert.equal((await invites.doc('inv-2').get()).data().status, 'cancelled');
  });
  await assertFails(facility.get());

  const ways = {
    'their old row switched back on': () =>
      invitee.collection('user_roles').doc(inviteRoleDocId('inv-1')).set({ isActive: true, updatedAt: new Date() }, { merge: true }),
    'the acceptance sent again': () => acceptanceBatch(invitee).commit(),
    'a new row for the spent invite': () => acceptanceBatch(invitee, { roleDocId: 'role-again', markAccepted: false }).commit(),
    'the roles entry alone': () => acceptanceBatch(invitee, { writeRow: false, markAccepted: false }).commit(),
    'the spent invite reopened': () => facility.collection('invites').doc('inv-1').update({ status: 'pending' }),
    'the second invite': () =>
      acceptanceBatch(invitee, { inviteId: 'inv-2', roleType: 'manager' }).commit(),
  };
  for (const [label, attempt] of Object.entries(ways)) {
    await assertFails(attempt()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  await assertFails(facility.get());

  // A fresh invite from the facility still brings them back.
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  await assertSucceeds(
    owner.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-3').set({
      facilityId: FACILITY_ID,
      email: INVITEE_EMAIL,
      emailLower: INVITEE_EMAIL,
      roleType: 'employee',
      status: 'pending',
      invitedBy: OWNER_UID,
      invitedAt: new Date(),
    }),
  );
  await assertSucceeds(acceptanceBatch(invitee, { inviteId: 'inv-3' }).commit());
  await assertSucceeds(facility.get());
});

test('an invitee cannot move their invite to a facility of their own, reopen it and come back', async () => {
  // Owners and managers were checked against the invite's own facilityId,
  // which the invitee could change as they accepted: pointed at a facility
  // they had just created, the invite was theirs to reopen at the real
  // facility as a manager invite and accept again after every removal.
  const OWN_FACILITY_ID = 'fac-invitee-own';
  await seedPendingInvite();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(OWN_FACILITY_ID).set({
      ownerUid: INVITEE_UID,
      name: 'Mine',
      roles: { [INVITEE_UID]: 'owner' },
    });
  });
  const invitee = inviteeDb();

  // The acceptance may change nothing on the invite but its status and who
  // accepted it, and when.
  const extras = {
    'moving it to their own facility': { facilityId: OWN_FACILITY_ID },
    'another role': { roleType: 'manager' },
    'another address': { emailLower: 'second-login@example.com', email: 'second-login@example.com' },
    'the name shown': { facilityName: 'Hijacked' },
    'the cancellation record': { cancelledReason: 'none' },
    'when it was sent': { lastSentAt: new Date(0) },
  };
  for (const [label, inviteExtra] of Object.entries(extras)) {
    await assertFails(acceptanceBatch(invitee, { inviteExtra }).commit()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  await assertSucceeds(acceptanceBatch(invitee).commit());

  // Owning a facility gives no say over another facility's invites, even one
  // whose facilityId names theirs (one moved before this rule).
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').update({
      facilityId: OWN_FACILITY_ID,
      status: 'accepted',
    });
  });
  const invite = invitee.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1');
  await assertFails(invite.update({ status: 'pending', roleType: 'manager', facilityId: FACILITY_ID }));
  await assertFails(invite.update({ status: 'pending' }));
  await assertFails(invite.delete());
});

test("an invite moved to another facility is still the real owner's to cancel with a removal, or delete", async () => {
  // Left pending with another facility's id, the owner's removeRole batch
  // (which cancels it) was refused as a whole: the team member could not be
  // removed, and the owner could not delete the invite either.
  const OWN_FACILITY_ID = 'fac-invitee-own';
  await seedPendingInvite({ facility: { roles: { [OWNER_UID]: 'owner', [INVITEE_UID]: 'employee' } } });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(OWN_FACILITY_ID).set({ ownerUid: INVITEE_UID, name: 'Mine' });
    await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').update({
      facilityId: OWN_FACILITY_ID,
    });
    await db.collection('user_roles').doc('role-invitee').set({
      userId: INVITEE_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
      userEmail: INVITEE_EMAIL,
    });
  });
  const owner = testEnv.authenticatedContext(OWNER_UID).firestore();
  // The cancel must name this facility again (removeRole writes it).
  await assertFails(removeMember(OWNER_UID, INVITEE_UID, INVITEE_EMAIL, { healFacilityId: false }));
  await assertSucceeds(removeMember(OWNER_UID, INVITEE_UID, INVITEE_EMAIL));

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const invite = (await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').get()).data();
    assert.equal(invite.status, 'cancelled');
    assert.equal(invite.facilityId, FACILITY_ID);
    const facility = (await db.collection('facilities').doc(FACILITY_ID).get()).data();
    assert.equal(facility.roles[INVITEE_UID], undefined);
    await db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').update({
      facilityId: OWN_FACILITY_ID,
    });
  });
  // Nor can they keep it for themselves: the removed member cannot accept it,
  // and the owner can delete it.
  await assertFails(acceptanceBatch(inviteeDb()).commit());
  await assertSucceeds(owner.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1').delete());
});

/** [uid]'s view of the facility's invites, signed in with a verified [email]. */
function invitesAs(uid, email = `${uid}@example.com`, claims = {}) {
  return testEnv
    .authenticatedContext(uid, { email, email_verified: true, ...claims })
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('invites');
}

/** An invite from [uid] for [roleType], as createFacilityInvite writes it. */
function newInviteFrom(uid, roleType, email = 'alt@example.com') {
  return {
    facilityId: FACILITY_ID,
    email,
    emailLower: email,
    roleType,
    status: 'pending',
    invitedBy: uid,
    invitedAt: new Date(),
    lastSentAt: new Date(),
  };
}

test('only the owner or a co-owner invites; only the owner invites someone as owner or admin', async () => {
  // The app lets only those who may manage the team (the owner, and a
  // co-owner the owner invited as owner) invite. A manager could invite a
  // second login of their own as manager, or, before that, as owner.
  await seedTeam({
    facility: {
      roles: {
        [OWNER_UID]: 'owner',
        [MANAGER_UID]: 'manager',
        [STAFF_UID]: 'employee',
        [COOWNER_UID]: 'owner',
        [ADMIN_UID]: 'admin',
      },
      managers: { 'legacy-manager': true },
    },
  });
  const refused = {
    'a manager, as employee': [MANAGER_UID, 'employee'],
    'a manager, as manager': [MANAGER_UID, 'manager'],
    'a manager, as owner': [MANAGER_UID, 'owner'],
    'an admin': [ADMIN_UID, 'employee'],
    'a legacy manager': ['legacy-manager', 'viewer'],
    'an employee': [STAFF_UID, 'viewer'],
    'an outsider': [OUTSIDER_UID, 'viewer'],
    'a co-owner, as owner': [COOWNER_UID, 'owner'],
    'a co-owner, as admin': [COOWNER_UID, 'admin'],
  };
  for (const [label, [uid, roleType]] of Object.entries(refused)) {
    await assertFails(invitesAs(uid).doc(`inv-${uid}-${roleType}`).set(newInviteFrom(uid, roleType))).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  await assertSucceeds(invitesAs(OWNER_UID).doc('inv-o').set(newInviteFrom(OWNER_UID, 'owner')));
  await assertSucceeds(invitesAs(OWNER_UID).doc('inv-e').set(newInviteFrom(OWNER_UID, 'employee', 'e@example.com')));
  await assertSucceeds(invitesAs(COOWNER_UID).doc('inv-c').set(newInviteFrom(COOWNER_UID, 'manager', 'c@example.com')));
  const support = invitesAs('support-user', 'support@example.com', { superadmin: true });
  await assertSucceeds(support.doc('inv-s').set(newInviteFrom('support-user', 'viewer', 's@example.com')));
});

test('a manager may only cancel a pending invite; resending and changing one is the owner\'s', async () => {
  await seedTeam({
    facility: { roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager', [COOWNER_UID]: 'owner' } },
  });
  const manager = invitesAs(MANAGER_UID);
  const coOwner = invitesAs(COOWNER_UID);
  const owner = invitesAs(OWNER_UID);

  // inv-staff-new is the owner's pending manager invite; inv-staff-old an accepted one.
  const managerRefused = {
    'resend': { lastSentAt: new Date() },
    'resend, as createFacilityInvite does for an address already invited': {
      roleType: 'manager',
      updatedAt: new Date(),
      lastSentAt: new Date(),
      facilityId: FACILITY_ID,
    },
    'a lower role': { roleType: 'viewer' },
    'a higher role': { roleType: 'owner' },
    'the name shown': { facilityName: 'Renamed' },
    'a cancel that also resends': { status: 'cancelled', cancelledAt: new Date(), lastSentAt: new Date() },
    'a cancel that also changes the role': { status: 'cancelled', cancelledAt: new Date(), roleType: 'viewer' },
    'marking it accepted': { status: 'accepted', acceptedAt: new Date(), acceptedBy: MANAGER_UID },
  };
  for (const [label, change] of Object.entries(managerRefused)) {
    await assertFails(manager.doc('inv-staff-new').update(change)).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  // Nor cancel one that is not pending, or delete an accepted one: it is
  // what ties a team member's address to them.
  await assertFails(manager.doc('inv-staff-old').update({ status: 'cancelled', cancelledAt: new Date() }));
  await assertFails(manager.doc('inv-staff-old').delete());
  // Nor does the owner readdress one or change who sent it.
  await assertFails(owner.doc('inv-staff-new').update({ email: 'alt@example.com', emailLower: 'alt@example.com' }));
  await assertFails(coOwner.doc('inv-staff-new').update({ emailLower: 'alt@example.com' }));
  await assertFails(coOwner.doc('inv-staff-new').update({ invitedBy: COOWNER_UID }));

  // The owner and a co-owner resend and change the role.
  await assertSucceeds(owner.doc('inv-staff-new').update({ lastSentAt: new Date() }));
  await assertSucceeds(coOwner.doc('inv-staff-new').update({ lastSentAt: new Date() }));
  await assertSucceeds(
    coOwner.doc('inv-staff-new').update({
      roleType: 'viewer',
      updatedAt: new Date(),
      lastSentAt: new Date(),
      facilityId: FACILITY_ID,
    }),
  );
  await assertFails(coOwner.doc('inv-staff-new').update({ roleType: 'owner' }));
  await assertSucceeds(owner.doc('inv-staff-new').update({ roleType: 'owner' }));
  await assertSucceeds(owner.doc('inv-staff-new').update({ roleType: 'manager' }));

  // A manager cancels a pending invite with removeRole's fields, including
  // one it puts back under this facility.
  await assertSucceeds(
    manager.doc('inv-staff-new').update({
      status: 'cancelled',
      cancelledAt: new Date(),
      cancelledReason: 'access_removed',
      facilityId: FACILITY_ID,
    }),
  );
  // And deletes a pending one (Cancel Invite).
  await assertSucceeds(invitesAs(OWNER_UID).doc('inv-pending-2').set(newInviteFrom(OWNER_UID, 'viewer', 'p2@example.com')));
  await assertSucceeds(manager.doc('inv-pending-2').delete());
  // The owner deletes any.
  await assertSucceeds(owner.doc('inv-staff-old').delete());
});

test('only the invitee records an acceptance, not the owner or a manager', async () => {
  // Who accepted an invite is what removeRole and the "already on the team"
  // check tie an address to a user by. The owner could mark an invite
  // accepted by anyone.
  await seedTeam({
    facility: { roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager', [COOWNER_UID]: 'owner' } },
  });
  const accept = (by) => ({ status: 'accepted', acceptedAt: new Date(), acceptedBy: by });
  for (const [label, invites] of Object.entries({
    owner: invitesAs(OWNER_UID),
    'co-owner': invitesAs(COOWNER_UID),
    manager: invitesAs(MANAGER_UID),
  })) {
    const attempts = {
      'marked accepted by the staff member': accept(STAFF_UID),
      'marked accepted by an outsider': accept(OUTSIDER_UID),
      'acceptedBy alone': { acceptedBy: STAFF_UID },
      'acceptedAt alone': { acceptedAt: new Date() },
    };
    for (const [what, change] of Object.entries(attempts)) {
      await assertFails(invites.doc('inv-staff-new').update(change)).catch((e) => {
        throw new Error(`${label}, ${what}: ${e.message}`);
      });
    }
    // Nor rewrite who accepted a spent one.
    await assertFails(invites.doc('inv-staff-old').update({ acceptedBy: OUTSIDER_UID })).catch((e) => {
      throw new Error(`${label}, rewriting acceptedBy: ${e.message}`);
    });
  }
  // The invitee's own acceptance still records it.
  await assertSucceeds(invitesAs(STAFF_UID, 'staff@example.com').doc('inv-staff-new').update(accept(STAFF_UID)));
});

test('only the owner sets a spent or cancelled invite back to pending', async () => {
  // A manager could reopen a co-owner's accepted owner invite, and a
  // co-owner the owner had demoted to manager could reopen their own and
  // accept it again, as owner, where the other managers could not remove
  // them. The app never reopens an invite.
  await seedTeam({
    facility: { roles: { [OWNER_UID]: 'owner', [MANAGER_UID]: 'manager', [COOWNER_UID]: 'manager' } },
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const invites = context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites');
    await invites.doc('inv-co').set({
      facilityId: FACILITY_ID,
      email: 'coowner@example.com',
      emailLower: 'coowner@example.com',
      roleType: 'owner',
      status: 'accepted',
      acceptedBy: COOWNER_UID,
      acceptedAt: new Date('2026-09-02T12:00:00Z'),
      invitedBy: OWNER_UID,
      invitedAt: new Date('2026-09-01T12:00:00Z'),
    });
    await invites.doc('inv-cancelled').set({
      facilityId: FACILITY_ID,
      email: 'gone@example.com',
      emailLower: 'gone@example.com',
      roleType: 'employee',
      status: 'cancelled',
      cancelledReason: 'access_removed',
      invitedBy: MANAGER_UID,
      invitedAt: new Date('2026-09-01T12:00:00Z'),
    });
  });
  const manager = invitesAs(MANAGER_UID, 'manager@example.com');
  const demoted = invitesAs(COOWNER_UID, 'coowner@example.com');

  const reopenings = {
    "a manager, a co-owner's accepted owner invite": () => manager.doc('inv-co').update({ status: 'pending' }),
    'a manager, with a merge': () => manager.doc('inv-co').set({ status: 'pending', lastSentAt: new Date() }, { merge: true }),
    'the demoted co-owner, their own': () => demoted.doc('inv-co').update({ status: 'pending' }),
    'a manager, an accepted employee invite': () => manager.doc('inv-staff-old').update({ status: 'pending' }),
    'a manager, a cancelled invite they sent': () => manager.doc('inv-cancelled').update({ status: 'pending' }),
  };
  for (const [label, attempt] of Object.entries(reopenings)) {
    await assertFails(attempt()).catch((e) => {
      throw new Error(`${label}: ${e.message}`);
    });
  }
  // A manager still cancels a pending one (removeRole), and nothing else.
  await assertFails(manager.doc('inv-co').update({ status: 'cancelled' }));
  await assertSucceeds(manager.doc('inv-staff-new').update({ status: 'cancelled', cancelledAt: new Date() }));
  // Nor does a co-owner reopen one; the owner may.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).set(
      { roles: { [COOWNER_UID]: 'owner' } },
      { merge: true },
    );
  });
  await assertFails(demoted.doc('inv-staff-old').update({ status: 'pending' }));
  await assertSucceeds(invitesAs(OWNER_UID, 'owner@example.com').doc('inv-staff-old').update({ status: 'pending' }));
});

test('an invite is accepted only by a verified address', async () => {
  // An unverified account can carry anyone's address: with the link, it
  // could accept an invite it never received.
  await seedPendingInvite();
  const unverified = testEnv
    .authenticatedContext(INVITEE_UID, { email: INVITEE_EMAIL, email_verified: false })
    .firestore();
  const invite = (db) => db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-1');
  // Pending, it can still be read (the link opens it before sign-in).
  await assertSucceeds(invite(unverified).get());
  await assertFails(acceptanceBatch(unverified).commit());
  await assertFails(invite(unverified).update({ status: 'accepted', acceptedAt: new Date(), acceptedBy: INVITEE_UID }));
  await assertSucceeds(acceptanceBatch(inviteeDb()).commit());
});

test("a manager's own invite gives them a row only when it records them as accepting it", async () => {
  // A manager may edit the facility's invites, so one addressed to their own
  // address they could mark accepted (by anyone) and write their row off it
  // in the same batch. The row's invite must name them as its acceptor, and
  // their address must be verified, as for any other invitee.
  await seedTeam();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await context.firestore().collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-m').set({
      facilityId: FACILITY_ID,
      email: 'manager@example.com',
      emailLower: 'manager@example.com',
      roleType: 'employee',
      status: 'pending',
      invitedBy: OWNER_UID,
      invitedAt: new Date('2026-09-20T12:00:00Z'),
    });
  });
  const managerAcceptance = (verified, acceptedBy) => {
    const db = testEnv
      .authenticatedContext(MANAGER_UID, { email: 'manager@example.com', email_verified: verified })
      .firestore();
    const batch = db.batch();
    batch.update(db.collection('facilities').doc(FACILITY_ID).collection('invites').doc('inv-m'), {
      status: 'accepted',
      acceptedAt: new Date(),
      acceptedBy,
    });
    batch.set(db.collection('user_roles').doc(inviteRoleDocId('inv-m')), {
      userId: MANAGER_UID,
      facilityId: FACILITY_ID,
      roleType: 'employee',
      assignedBy: OWNER_UID,
      isActive: true,
      inviteId: 'inv-m',
    });
    return batch.commit();
  };
  await assertFails(managerAcceptance(true, OUTSIDER_UID));
  await assertFails(managerAcceptance(false, MANAGER_UID));
  await assertSucceeds(managerAcceptance(true, MANAGER_UID));
});

test('an invite names its sender by their own verified address, or not at all', async () => {
  // The invitee is shown who sent it. Anyone can create a facility and
  // invite any address, and could sign the invite as the platform's support.
  await seedTeam();
  const invites = (claims) =>
    testEnv
      .authenticatedContext(OWNER_UID, claims)
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('invites');
  const invite = (invitedByEmail) => ({
    facilityId: FACILITY_ID,
    email: 'new@example.com',
    emailLower: 'new@example.com',
    roleType: 'employee',
    status: 'pending',
    invitedBy: OWNER_UID,
    invitedAt: new Date(),
    ...(invitedByEmail === undefined ? {} : { invitedByEmail }),
  });
  const verified = invites({ email: 'Owner@Example.com', email_verified: true });
  const unverified = invites({ email: 'Owner@Example.com', email_verified: false });

  await assertFails(verified.doc('inv-a').set(invite('support@storagefacilitycreator.com')));
  await assertFails(unverified.doc('inv-a').set(invite('Owner@Example.com')));
  await assertSucceeds(verified.doc('inv-a').set(invite('Owner@Example.com')));
  await assertSucceeds(unverified.doc('inv-b').set(invite(null)));
  await assertSucceeds(unverified.doc('inv-c').set(invite(undefined)));

  // Nor can it be changed afterwards, by the owner or a manager.
  await assertFails(verified.doc('inv-a').update({ invitedByEmail: 'support@storagefacilitycreator.com' }));
  await assertFails(verified.doc('inv-b').update({ invitedByEmail: 'Owner@Example.com' }));
  const manager = testEnv
    .authenticatedContext(MANAGER_UID, { email: 'manager@example.com', email_verified: true })
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('invites');
  await assertFails(manager.doc('inv-a').update({ invitedByEmail: 'manager@example.com' }));
  await assertFails(manager.doc('inv-a').update({ invitedBy: MANAGER_UID }));
  await assertSucceeds(verified.doc('inv-a').update({ lastSentAt: new Date() }));
});
