import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { resolvePortalTenantSession, extractCallableClientIp, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { createAutopayNotificationAndEvent } from './stripeAutopayEvents';
import { firstAutopayRun } from './stripe/tenant_billing';

/**
 * Arm or disarm the tenant's saved card for the nightly autopay job.
 *
 * The `tenant.autopay.*` fields this callable used to write are display state:
 * they drive the portal's ON/OFF chip and nothing else. The scheduled worker
 * only ever looks at
 *
 *     collectionGroup('paymentMethods')
 *       .where('facilityId', ...).where('autopayEnabled', true).where('isActive', true)
 *
 * so writing the tenant fields alone left the portal showing "Autopay: ON"
 * while no card was armed and no charge was ever attempted. The tenant
 * believes their rent is being collected, it silently is not, and they go
 * delinquent through no fault of their own. Autopay enabled from the portal
 * had therefore never worked.
 *
 * Mirrors the staff-side toggleAutopay so both entry points leave the same
 * state behind.
 */
async function setPaymentMethodArming(
  facilityId: string,
  tenantId: string,
  enable: boolean,
): Promise<void> {
  const methods = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .collection('paymentMethods')
    .where('isActive', '==', true)
    .get();

  if (!enable) {
    for (const doc of methods.docs) {
      if (doc.get('autopayEnabled') === true) {
        await doc.ref.update({
          autopayEnabled: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
    return;
  }

  if (methods.empty) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Add a payment method first. Use "Add card" to save your card, then turn on autopay.',
    );
  }

  const target = methods.docs.find((d) => d.get('isDefault') === true) ?? methods.docs[0];
  const existingSchedule = (target.get('autopaySchedule') as Record<string, any>) ?? {};
  const dayOfMonth =
    typeof existingSchedule.dayOfMonth === 'number' ? existingSchedule.dayOfMonth : 1;

  await target.ref.update({
    autopayEnabled: true,
    autopaySchedule: {
      ...existingSchedule,
      frequency: 'monthly',
      dayOfMonth,
      // First run lands in a future month so switching autopay on cannot
      // trigger a same-night charge for a period already paid.
      autopayNextRun: admin.firestore.Timestamp.fromDate(
        firstAutopayRun(new Date(), dayOfMonth),
      ),
    },
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Only one card may be armed, or the nightly job charges once per card.
  for (const doc of methods.docs) {
    if (doc.id !== target.id && doc.get('autopayEnabled') === true) {
      await doc.ref.update({ autopayEnabled: false });
    }
  }
}

/**
 * setTenantAutopayFromPortal — For tenant portal (no Firebase Auth). Uses email + accessCode to identify tenant.
 */
export const setTenantAutopayFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const enabled = data.enabled === true;
  const requestedTenantId = (data.tenantId || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  const session = await resolvePortalTenantSession(
    email,
    accessCode,
    clientIp,
    requestedTenantId || undefined,
  );
  const tenantDoc = session.tenantDoc;
  const facilityId = session.facilityId;
  const tenantId = session.tenantId;
  const tenantData = session.tenantData as Record<string, any>;
  const tenantName = tenantData.name || 'Tenant';
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data()!;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  let chargesEnabled = false;
  if (connectAccountId) {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    chargesEnabled = !!account.charges_enabled;
  }
  const stripe = tenantData.stripe as { defaultPaymentMethodId?: string } | undefined;
  const hasPm = !!(stripe?.defaultPaymentMethodId);
  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const now = admin.firestore.FieldValue.serverTimestamp();

  if (enabled) {
    if (!chargesEnabled || !connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet. The facility must complete Stripe setup first.');
    }
    if (!hasPm) {
      throw new functions.https.HttpsError('failed-precondition', 'Add a payment method first. Use "Add card" to save your card, then turn on autopay.');
    }
    // Arm the card first: if this fails, the tenant must not be shown "ON".
    await setPaymentMethodArming(facilityId, tenantId, true);
    await tenantRef.update({
      'autopay.requested': true,
      'autopay.enabled': true,
      'autopay.status': 'ON',
      'autopay.enabledAt': now,
      'autopay.disabledAt': null,
      'autopay.disabledReason': null,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_ENABLED', 'ENABLED', 'TENANT', `${tenantName} enabled autopay from portal.`, null);
    return { enabled: true, status: 'ON' };
  } else {
    const disabledReason = 'Tenant disabled in portal';
    // Disarm first, so a failure here cannot leave a card charging after the
    // tenant has been told autopay is off.
    await setPaymentMethodArming(facilityId, tenantId, false);
    await tenantRef.update({
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': now,
      'autopay.disabledReason': disabledReason,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_DISABLED', 'DISABLED', 'TENANT', `${tenantName} turned off autopay.`, disabledReason);
    return { enabled: false, status: 'OFF' };
  }
});
