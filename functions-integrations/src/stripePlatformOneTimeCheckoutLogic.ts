import { getStripeClient } from '@sfc/functions-shared';

export interface CheckoutSessionRequest {
  amount: number;
  currency?: string;
  successUrl: string;
  cancelUrl: string;
  description?: string;
  customerEmail?: string;
}

export async function executeCreateOneTimeCheckoutSession(
  data: CheckoutSessionRequest,
): Promise<{ checkoutUrl: string | null; sessionId: string }> {
  const {
    amount,
    currency = 'usd',
    successUrl,
    cancelUrl,
    description = 'Storage Facility Payment',
    customerEmail,
  } = data;

  const stripe = getStripeClient();
  const session = await stripe.checkout.sessions.create({
    mode: 'payment',
    payment_method_types: ['card'],
    line_items: [
      {
        price_data: {
          currency,
          product_data: { name: description },
          unit_amount: Math.round(amount * 100),
        },
        quantity: 1,
      },
    ],
    customer_email: customerEmail,
    success_url: successUrl,
    cancel_url: cancelUrl,
  });

  return {
    checkoutUrl: session.url,
    sessionId: session.id,
  };
}
