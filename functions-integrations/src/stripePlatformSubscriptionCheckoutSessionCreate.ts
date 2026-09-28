import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import {
  getOrCreateFirstMonthFreeCouponId,
  platformCheckoutTrialSubscriptionData,
  writeAuditLog,
  type PlatformCheckoutTrialDecision,
} from '@sfc/functions-shared';

/**
 * Pure: the Checkout Session params for an account-level platform subscription.
 * The trial comes from `decidePlatformCheckoutTrial` so an owner already inside the
 * app trial is not handed a second one; the first-month-free coupon is always attached.
 */
export function buildAccountSubscriptionCheckoutParams(options: {
  accountId: string;
  customerId: string;
  facilityCount: number;
  lineItems: Stripe.Checkout.SessionCreateParams.LineItem[];
  firstMonthFreeCouponId: string;
  trial: PlatformCheckoutTrialDecision;
  successUrl?: string;
  cancelUrl?: string;
  ownerUid: string;
}): Stripe.Checkout.SessionCreateParams {
  const { accountId, customerId, facilityCount, lineItems, firstMonthFreeCouponId, trial, successUrl, cancelUrl, ownerUid } =
    options;
  return {
    customer: customerId,
    mode: 'subscription',
    line_items: lineItems,
    discounts: [{ coupon: firstMonthFreeCouponId }],
    success_url: successUrl || 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
    cancel_url: cancelUrl || 'https://app.storagefacilitycreator.com/subscription/cancel',
    metadata: {
      accountId: accountId,
      ownerUid,
      facilityCount: facilityCount.toString(),
    },
    subscription_data: {
      ...platformCheckoutTrialSubscriptionData(trial),
      metadata: {
        accountId: accountId,
        facilityCount: facilityCount.toString(),
        trialDecision: trial.kind,
      },
    },
  };
}

export async function createSubscriptionCheckoutSessionAndAudit(options: {
  stripe: Stripe;
  accountId: string;
  customerId: string;
  facilityCount: number;
  additionalFacilityCount: number;
  basePriceId: string;
  addOnPriceId: string;
  successUrl?: string;
  cancelUrl?: string;
  ownerUid: string;
  /** From `decidePlatformCheckoutTrial` on the account document. */
  trial: PlatformCheckoutTrialDecision;
}): Promise<{ checkoutUrl: string | null; sessionId: string }> {
  const {
    stripe,
    accountId,
    customerId,
    facilityCount,
    additionalFacilityCount,
    basePriceId,
    addOnPriceId,
    successUrl,
    cancelUrl,
    ownerUid,
    trial,
  } = options;

  const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
    {
      price: basePriceId,
      quantity: 1,
    },
  ];

  if (additionalFacilityCount > 0) {
    lineItems.push({
      price: addOnPriceId,
      quantity: additionalFacilityCount,
    });
  }

  try {
    functions.logger.info('Creating Stripe checkout session', {
      accountId,
      customerId,
      facilityCount,
      additionalFacilityCount,
      lineItemsCount: lineItems.length,
      trialDecision: trial.kind,
      trialReason: trial.reason,
    });
    // Public offer: 30-day trial, then the first paid month is free (two months in total).
    const firstMonthFreeCouponId = await getOrCreateFirstMonthFreeCouponId(stripe);
    const session = await stripe.checkout.sessions.create(
      buildAccountSubscriptionCheckoutParams({
        accountId,
        customerId,
        facilityCount,
        lineItems,
        firstMonthFreeCouponId,
        trial,
        successUrl,
        cancelUrl,
        ownerUid,
      }),
    );
    functions.logger.info('Checkout session created successfully', {
      sessionId: session.id,
      checkoutUrl: session.url,
    });

    const result = {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
    await writeAuditLog(accountId, {
      action: 'subscription_checkout_created',
      userId: ownerUid,
      checkoutSessionId: session.id,
      facilityCount,
    });
    return result;
  } catch (stripeError: any) {
    functions.logger.error('Stripe API error creating checkout session', {
      error: stripeError.message,
      type: stripeError.type,
      code: stripeError.code,
      declineCode: stripeError.declineCode,
      accountId,
      customerId,
    });
    throw new functions.https.HttpsError('internal', `Stripe error: ${stripeError.message}`);
  }
}
