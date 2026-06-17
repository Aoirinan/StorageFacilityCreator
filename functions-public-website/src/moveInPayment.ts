/** Resolve Stripe Connect account for public move-in payment verification. */
export function resolveMoveInPaymentStripeAccountId(
  facilityData: Record<string, unknown>,
): string | undefined {
  const fromFacility = (facilityData.stripeConnectAccountId || '').toString().trim();
  return fromFacility.length > 0 ? fromFacility : undefined;
}
