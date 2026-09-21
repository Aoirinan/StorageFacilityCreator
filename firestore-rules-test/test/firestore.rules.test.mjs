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
import { serverTimestamp } from 'firebase/firestore';
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
