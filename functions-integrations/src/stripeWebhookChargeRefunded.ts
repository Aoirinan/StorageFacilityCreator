import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { eventAccountMatchesFacility } from './connectedAccountGuard';
import { isAlreadyExistsError } from './firestoreErrors';
import { isMoveInPaymentIntent, resolveMoveInTenantOrRecord } from './moveInPaymentTenant';

/**
 * Who a refund row belongs to once this event is merged into it: the
 * tenant and reference the event names, else what the row already holds.
 *
 * processRefund (the app's card refund, the move-out screen's included)
 * writes `refund_<id>` first, with the tenant it refunded. An online
 * move-in's PaymentIntent carries no tenantId, so this merge wrote
 * tenantId null over it: the refund dropped off the tenant's ledger while
 * the credit it paid out stayed, and the tenant looked owed money already
 * handed back, which invites a second refund. Its createdBy (the staff
 * member who refunded) and referenceId (the PaymentIntent) are kept too.
 */
export function refundRowOwner(
  existing: Record<string, unknown> | undefined,
  fromEvent: { tenantId: string | null | undefined; referenceId: string | null },
): { tenantId: string | null; referenceId: string | null; createdBy: string } {
  const text = (value: unknown): string | null =>
    typeof value === 'string' && value.trim().length > 0 ? value : null;
  return {
    tenantId: text(fromEvent.tenantId) ?? text(existing?.tenantId),
    referenceId: fromEvent.referenceId ?? text(existing?.referenceId),
    createdBy: text(existing?.createdBy) ?? 'system@stripe-webhook',
  };
}

function hasText(value: unknown): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

/**
 * Record a refund against the tenant's ledger.
 *
 * Two things this has to get right, both of which it previously did not:
 *
 * 1. Tenant charges live on the facility's *connected* account, so retrieving
 *    the PaymentIntent without `stripeAccount` looks it up on the platform and
 *    fails with "no such payment_intent". The handler then warned and returned,
 *    so refunds were never recorded. That was invisible until now only because
 *    connected-account events were not being delivered at all; now that they
 *    are, this would have failed on every real refund.
 *
 * 2. `charge.amount_refunded` is the cumulative total refunded so far, not the
 *    amount of this refund. Posting it on each event means two partial refunds
 *    of $10 record $10 and then $20 — crediting $30 against $20 actually
 *    returned. Each individual refund is recorded once instead, keyed by its
 *    own id so redelivery and partial refunds are both safe.
 *
 * Errors propagate: the webhook returns 500 and Stripe redelivers. Swallowing
 * them marked the event processed with the refund never on the ledger, so the
 * tenant kept a credit for money already handed back and autopay and the
 * delinquency job under-collected by that much. Every write is keyed on the
 * refund, so a retry converges.
 */
export async function handleChargeRefunded(
  charge: Stripe.Charge,
  connectedAccountId?: string,
  eventId?: string,
) {
  try {
    const paymentIntentId = charge.payment_intent as string;
    if (!paymentIntentId) {
      functions.logger.warn('Charge refunded but no payment intent ID');
      return;
    }

    const stripe = getStripeClient();
    const requestOptions = connectedAccountId ? { stripeAccount: connectedAccountId } : {};
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, requestOptions);

    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId: string | null = paymentIntent.metadata?.tenantId || null;
    // A refund of a payment staff took for a card dispute (the charge or
    // link carried the dispute's id) reopens that dispute, not rent. Untagged,
    // its +amount landed in what autopay collects, and autopay charged the
    // refunded money straight back to the card.
    const disputeId = paymentIntent.metadata?.disputeId || null;

    if (!facilityId) {
      functions.logger.warn('Charge refunded but missing facilityId metadata');
      return;
    }

    // A refund posts a charge (+amount) to the tenant: only the facility's own
    // account may do that, whatever facilityId the PaymentIntent carries.
    const accountMatches = await eventAccountMatchesFacility({
      facilityId,
      connectedAccountId,
      eventType: 'charge.refunded',
      objectId: charge.id,
      eventId,
      tenantId,
      amount: charge.amount_refunded / 100,
    });
    if (!accountMatches) return;

    // Refund objects may not be expanded on the event payload; fetch them so
    // each one can be recorded individually.
    const refunds =
      charge.refunds?.data && charge.refunds.data.length > 0
        ? charge.refunds.data
        : (await stripe.refunds.list({ charge: charge.id, limit: 100 }, requestOptions)).data;
    const succeeded = refunds.filter((refund) => !refund.status || refund.status === 'succeeded');

    // An online move-in's PaymentIntent names no tenant. Its refund used to
    // go on the ledger with tenantId null: on nobody's ledger, while the
    // tenant it moved in kept the credit for money handed back. Found through
    // the move-in's records instead; with no tenant (refunded before the
    // move-in was completed) it goes on no ledger at all, and is recorded on
    // the move-in payment for the owner (moveInPaymentTenant.ts).
    // Each refund is resolved on its own: one recorded before the move-in
    // completed has no tenant, and a later one may.
    const tenantByRefund = new Map<string, string | null>();
    if (!tenantId && isMoveInPaymentIntent(paymentIntent)) {
      for (const refund of succeeded) {
        const resolved = await resolveMoveInTenantOrRecord({
          facilityId,
          paymentIntent,
          connectedAccountId,
          money: { kind: 'refund', id: refund.id, amountCents: refund.amount, status: refund.status ?? null },
        });
        tenantByRefund.set(refund.id, resolved.tenantId);
      }
      if (![...tenantByRefund.values()].some((id) => id !== null)) return;
    }
    // A move-in refund with no tenant was recorded on the move-in payment
    // instead, and goes on no ledger.
    const refundsToPost = succeeded.flatMap((refund) => {
      if (!tenantByRefund.has(refund.id)) return [{ refund, tenantId }];
      const resolved = tenantByRefund.get(refund.id) ?? null;
      return resolved ? [{ refund, tenantId: resolved }] : [];
    });

    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const paymentsRef = facilityRef.collection('payments');
    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntentId)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        // Stripe allows refunding part of a charge; only call it fully refunded
        // when it actually is.
        status: charge.amount_refunded >= charge.amount ? 'refunded' : 'partially_refunded',
        amountRefunded: charge.amount_refunded / 100,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const referenceId = existingPayments.empty ? null : existingPayments.docs[0].id;
    for (const { refund, tenantId: refundTenantId } of refundsToPost) {
      // Deterministic id per refund: redelivery of the same event, or a later
      // event listing this refund again, updates one entry instead of adding
      // another. A ledger that double-counts refunds understates what a tenant
      // owes, which is money the facility never collects.
      const ledgerRef = facilityRef.collection('ledgers').doc(`refund_${refund.id}`);
      const metadata: Record<string, unknown> = {
        chargeId: charge.id,
        paymentIntentId,
        refundId: refund.id,
        connectedAccountId: connectedAccountId || null,
        ...(disputeId ? { disputeId } : {}),
      };
      try {
        await ledgerRef.create({
          tenantId: refundTenantId || null,
          facilityId,
          type: 'refund',
          // Positive: a refund reverses a payment, so what the tenant owes goes
          // back up. Payments are stored negative, charges positive.
          amount: refund.amount / 100,
          description: `Refund for charge ${charge.id}`,
          referenceId,
          entryDate: admin.firestore.FieldValue.serverTimestamp(),
          status: 'posted',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdBy: 'system@stripe-webhook',
          metadata,
        });
      } catch (error) {
        if (!isAlreadyExistsError(error)) throw error;
        // processRefund (the app's card refund, the move-out screen's
        // included) or an earlier delivery wrote it. A merge over the whole
        // row replaced processRefund's createdBy (the staff member who
        // refunded) with this webhook, and its date and description too, and
        // for a PaymentIntent that names no tenant wrote tenantId null over
        // the tenant processRefund refunded. Only what the row lacks is filled
        // in: the metadata this event adds, and its tenant, reference and
        // author (refundRowOwner) when it has none. An existing tenantId is
        // never replaced or nulled.
        const existing = await ledgerRef.get();
        const existingData = (existing.data() ?? {}) as Record<string, unknown>;
        const existingMetadata = (existingData.metadata as Record<string, unknown> | undefined) ?? {};
        const update: Record<string, unknown> = {};
        for (const [key, value] of Object.entries(metadata)) {
          if (value !== null && existingMetadata[key] === undefined) update[`metadata.${key}`] = value;
        }
        const owner = refundRowOwner(existingData, { tenantId: refundTenantId, referenceId });
        for (const key of ['tenantId', 'referenceId', 'createdBy'] as const) {
          if (!hasText(existingData[key]) && owner[key] !== null) update[key] = owner[key];
        }
        if (Object.keys(update).length > 0) await ledgerRef.update(update);
      }
    }

    functions.logger.info(
      `Charge refunded: ${charge.id} (${refunds.length} refund(s)) for payment intent ${paymentIntentId}` +
        (connectedAccountId ? ' on connected account' : ''),
    );
  } catch (error: any) {
    functions.logger.error('Error handling charge refunded:', error);
    throw error;
  }
}
