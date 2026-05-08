import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import * as Sentry from '@sentry/node';
import { getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS, STRIPE_WEBHOOK_SECRET } from './secrets';
import { isStripeEventProcessed, markStripeEventProcessed } from './stripeWebhookIdempotency';
import {
  handleChargeRefunded,
  handleDisputeCreated,
  handlePaymentIntentFailed,
  handlePaymentIntentSucceeded,
  handleSetupIntentSucceeded,
} from './stripeWebhookPaymentHandlers';
import {
  handleCheckoutCompleted,
  handleConnectAccountUpdated,
  handleInvoicePaymentFailed,
  handleInvoicePaymentSucceeded,
  handleSubscriptionDeleted,
  handleSubscriptionUpdate,
} from './stripeWebhookSubscriptionHandlers';

async function dispatchStripeWebhookEvent(event: Stripe.Event): Promise<void> {
  switch (event.type) {
    case 'checkout.session.completed': {
      const session = event.data.object as Stripe.Checkout.Session;
      await handleCheckoutCompleted(session);
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated': {
      const subscription = event.data.object as Stripe.Subscription;
      await handleSubscriptionUpdate(subscription);
      break;
    }
    case 'customer.subscription.deleted': {
      const subscription = event.data.object as Stripe.Subscription;
      await handleSubscriptionDeleted(subscription);
      break;
    }
    case 'invoice.payment_succeeded': {
      const invoice = event.data.object as Stripe.Invoice;
      await handleInvoicePaymentSucceeded(invoice);
      break;
    }
    case 'invoice.payment_failed': {
      const invoice = event.data.object as Stripe.Invoice;
      await handleInvoicePaymentFailed(invoice);
      break;
    }
    case 'account.updated': {
      const account = event.data.object as Stripe.Account;
      await handleConnectAccountUpdated(account);
      break;
    }
    case 'payment_intent.succeeded': {
      const paymentIntent = event.data.object as Stripe.PaymentIntent;
      await handlePaymentIntentSucceeded(paymentIntent);
      break;
    }
    case 'payment_intent.payment_failed': {
      const paymentIntent = event.data.object as Stripe.PaymentIntent;
      await handlePaymentIntentFailed(paymentIntent);
      break;
    }
    case 'setup_intent.succeeded': {
      const setupIntent = event.data.object as Stripe.SetupIntent;
      const connectedAccountId = (event as any).account as string | undefined;
      await handleSetupIntentSucceeded(setupIntent, connectedAccountId);
      break;
    }
    case 'charge.refunded': {
      const charge = event.data.object as Stripe.Charge;
      await handleChargeRefunded(charge);
      break;
    }
    case 'charge.dispute.created': {
      const dispute = event.data.object as Stripe.Dispute;
      await handleDisputeCreated(dispute);
      break;
    }
    default:
      functions.logger.info(`Unhandled event type: ${event.type}`);
  }
}

/**
 * Stripe webhook handler for subscription and Connect events (exported name must stay `stripeWebhook`).
 */
export const stripeWebhook = functions.runWith({ secrets: STRIPE_SECRETS }).https.onRequest(async (req, res) => {
  const sig = req.headers['stripe-signature'] as string;

  if (!sig) {
    functions.logger.error('Missing stripe-signature header');
    res.status(400).send('Missing signature');
    return;
  }

  try {
    const webhookSecret = STRIPE_WEBHOOK_SECRET.value();
    const stripe = getStripeClient();

    let event: Stripe.Event;
    try {
      const rawBody = (req as any).rawBody as Buffer | undefined;
      const payload =
        rawBody ??
        (typeof req.body === 'string' ? Buffer.from(req.body) : Buffer.from(JSON.stringify(req.body || {})));

      event = stripe.webhooks.constructEvent(payload, sig, webhookSecret);
    } catch (err: any) {
      functions.logger.error('Webhook signature verification failed', err);
      res.status(400).send(`Webhook Error: ${err.message}`);
      return;
    }

    const alreadyProcessed = await isStripeEventProcessed(event.id);
    if (alreadyProcessed) {
      functions.logger.info(`Stripe webhook event ${event.id} already processed, acking`);
      res.json({ received: true, duplicate: true });
      return;
    }

    await dispatchStripeWebhookEvent(event);

    const account = (event as any).account || null;
    let facilityId: string | undefined;
    let tenantId: string | undefined;

    const eventData = event.data.object as any;
    if (eventData.metadata) {
      facilityId = eventData.metadata.facilityId;
      tenantId = eventData.metadata.tenantId;
    }

    await markStripeEventProcessed(event.id, event.type, account, facilityId, tenantId);
    res.json({ received: true });
  } catch (error: any) {
    const safeError = error?.message || 'Webhook processing error';
    functions.logger.error('Webhook error', {
      error: safeError,
    });

    const sentryDsn = process.env.SENTRY_DSN;
    if (sentryDsn) {
      Sentry.captureException(error, {
        tags: {
          function: 'stripeWebhook',
        },
      });
    }

    res.status(500).send('Webhook Error: Internal server error');
  }
});
