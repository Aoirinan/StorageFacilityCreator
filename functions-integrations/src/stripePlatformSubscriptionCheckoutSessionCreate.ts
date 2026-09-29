import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import {
  platformCheckoutOfferMetadata,
  platformCheckoutTrialSubscriptionData,
  writeAuditLog,
  type PlatformCheckoutTrialDecision,
} from '@sfc/functions-shared';

/**
 * Pure: the Checkout Session params for an account-level platform subscription.
 * The trial comes from `decidePlatformCheckoutOffer`: one trial and one free month per
 * owner, ever. The free month is trial time (`trial_end`); no coupon or discount is sent.
 */
export function buildAccountSubscriptionCheckoutParams(options: {
  accountId: string;
  customerId: string;
  facilityCount: number;
  lineItems: Stripe.Checkout.SessionCreateParams.LineItem[];
  trial: PlatformCheckoutTrialDecision;
  successUrl?: string;
  cancelUrl?: string;
  ownerUid: string;
}): Stripe.Checkout.SessionCreateParams {
  const { accountId, customerId, facilityCount, lineItems, trial, successUrl, cancelUrl, ownerUid } = options;
  const offerMetadata = platformCheckoutOfferMetadata(trial);
  return {
    customer: customerId,
    mode: 'subscription',
    line_items: lineItems,
    success_url: successUrl || 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
    cancel_url: cancelUrl || 'https://app.storagefacilitycreator.com/subscription/cancel',
    metadata: {
      accountId: accountId,
      ownerUid,
      facilityCount: facilityCount.toString(),
      ...offerMetadata,
    },
    subscription_data: {
      ...platformCheckoutTrialSubscriptionData(trial),
      metadata: {
        accountId: accountId,
        facilityCount: facilityCount.toString(),
        ...offerMetadata,
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
  /** From `decidePlatformCheckoutOffer`. */
  trial: PlatformCheckoutTrialDecision;
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
      firstMonthFree: trial.kind === 'free_month',
    });
    // Public offer: 30-day trial, then the first month free, once per owner; the free
    // month is extra trial time, so the first invoice after it is the full price.
    const session = await stripe.checkout.sessions.create(
      buildAccountSubscriptionCheckoutParams({
        accountId,
        customerId,
        facilityCount,
        lineItems,
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
