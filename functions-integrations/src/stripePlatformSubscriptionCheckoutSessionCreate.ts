import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import {
  FIRST_MONTH_FREE_METADATA_KEY,
  getOrCreateFirstMonthFreeCouponId,
  platformCheckoutTrialSubscriptionData,
  writeAuditLog,
  type PlatformCheckoutTrialDecision,
} from '@sfc/functions-shared';

/**
 * Pure: the Checkout Session params for an account-level platform subscription.
 * Trial and coupon come from `decidePlatformCheckoutOffer`: one trial and one free
 * month per owner, ever. `firstMonthFreeCouponId` is null when the coupon is not offered.
 */
export function buildAccountSubscriptionCheckoutParams(options: {
  accountId: string;
  customerId: string;
  facilityCount: number;
  lineItems: Stripe.Checkout.SessionCreateParams.LineItem[];
  firstMonthFreeCouponId: string | null;
  trial: PlatformCheckoutTrialDecision;
  successUrl?: string;
  cancelUrl?: string;
  ownerUid: string;
}): Stripe.Checkout.SessionCreateParams {
  const { accountId, customerId, facilityCount, lineItems, firstMonthFreeCouponId, trial, successUrl, cancelUrl, ownerUid } =
    options;
  const params: Stripe.Checkout.SessionCreateParams = {
    customer: customerId,
    mode: 'subscription',
    line_items: lineItems,
    success_url: successUrl || 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
    cancel_url: cancelUrl || 'https://app.storagefacilitycreator.com/subscription/cancel',
    metadata: {
      accountId: accountId,
      ownerUid,
      facilityCount: facilityCount.toString(),
      [FIRST_MONTH_FREE_METADATA_KEY]: String(!!firstMonthFreeCouponId),
    },
    subscription_data: {
      ...platformCheckoutTrialSubscriptionData(trial),
      metadata: {
        accountId: accountId,
        facilityCount: facilityCount.toString(),
        trialDecision: trial.kind,
        [FIRST_MONTH_FREE_METADATA_KEY]: String(!!firstMonthFreeCouponId),
      },
    },
  };
  if (firstMonthFreeCouponId) params.discounts = [{ coupon: firstMonthFreeCouponId }];
  return params;
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
  /** From `decidePlatformCheckoutOffer`. */
  trial: PlatformCheckoutTrialDecision;
  attachFirstMonthFree: boolean;
  auditLog?: typeof writeAuditLog;
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
    attachFirstMonthFree,
  } = options;
  const auditLog = options.auditLog ?? writeAuditLog;

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
      attachFirstMonthFree,
    });
    // Public offer: 30-day trial, then the first paid month is free, once per owner.
    const firstMonthFreeCouponId = attachFirstMonthFree ? await getOrCreateFirstMonthFreeCouponId(stripe) : null;
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
    await auditLog(accountId, {
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
