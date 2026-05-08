import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { writeAuditLog } from '@sfc/functions-shared';

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
    });
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: lineItems,
      success_url: successUrl || 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: cancelUrl || 'https://app.storagefacilitycreator.com/subscription/cancel',
      metadata: {
        accountId: accountId,
        ownerUid,
        facilityCount: facilityCount.toString(),
      },
      subscription_data: {
        trial_period_days: 30,
        metadata: {
          accountId: accountId,
          facilityCount: facilityCount.toString(),
        },
      },
    });
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
