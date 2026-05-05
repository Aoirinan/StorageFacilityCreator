/** Stripe rejects Checkout when `customer_email` is blank or malformed; omit the field instead. */
export function optionalStripeCheckoutCustomerEmail(email: unknown): string | undefined {
  if (typeof email !== 'string') return undefined;
  const t = email.trim();
  if (!t || t.length > 320) return undefined;
  if (!t.includes('@')) return undefined;
  return t;
}
