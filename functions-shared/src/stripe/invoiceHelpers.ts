import type Stripe from 'stripe';

type SubscriptionWithPeriod = Stripe.Subscription & {
  current_period_end?: number;
  current_period_start?: number;
};

export function subPeriodEnd(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_end;
}

export function subPeriodStart(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_start;
}

export function invoiceSubscriptionId(inv: Stripe.Invoice): string | null {
  const sub = (inv as Stripe.Invoice & { subscription?: string | Stripe.Subscription | null }).subscription;
  return typeof sub === 'string' ? sub : (sub as Stripe.Subscription)?.id ?? null;
}
