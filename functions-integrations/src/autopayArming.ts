import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { firstAutopayRun } from './stripe/tenant_billing';

/**
 * The single place that decides whether a tenant's card is armed for the
 * nightly autopay job.
 *
 * There are three ways to switch autopay on — the staff tenant screen
 * (setTenantAutopay), the staff billing panel (toggleAutopay), and the tenant
 * portal (setTenantAutopayFromPortal) — and they had drifted apart. Two of
 * them wrote only `tenant.autopay.*`, which is display state driving an ON/OFF
 * chip and nothing else. The scheduled worker reads exclusively
 *
 *     collectionGroup('paymentMethods')
 *       .where('facilityId', ...).where('autopayEnabled', true).where('isActive', true)
 *
 * so those paths showed "Autopay: ON" while no card was armed and no charge
 * was ever attempted. The tenant believes rent is being collected, it silently
 * is not, and they go delinquent through no fault of their own.
 *
 * Keeping this in one module is the point: the bug was not any single wrong
 * line, it was three copies of the same intent disagreeing about where the
 * truth lives.
 */
export async function setTenantAutopayArming(
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
      'Add a payment method first, then turn on autopay.',
    );
  }

  const target = methods.docs.find((d) => d.get('isDefault') === true) ?? methods.docs[0];
  const existingSchedule = (target.get('autopaySchedule') as Record<string, any>) ?? {};
  const dayOfMonth =
    typeof existingSchedule.dayOfMonth === 'number' ? existingSchedule.dayOfMonth : 1;

  await target.ref.update({
    autopayEnabled: true,
    // Clear any prior failure state: switching autopay back on is a fresh
    // start, and a stale count would otherwise disarm it again early.
    autopayConsecutiveFailures: 0,
    autopayDisabledReason: null,
    autopaySchedule: {
      ...existingSchedule,
      frequency: 'monthly',
      dayOfMonth,
      // First run lands in a future month, so switching autopay on cannot
      // trigger a same-night charge for a period already paid.
      autopayNextRun: admin.firestore.Timestamp.fromDate(
        firstAutopayRun(new Date(), dayOfMonth),
      ),
    },
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Exactly one armed card, or the nightly job charges once per card.
  for (const doc of methods.docs) {
    if (doc.id !== target.id && doc.get('autopayEnabled') === true) {
      await doc.ref.update({ autopayEnabled: false });
    }
  }
}
