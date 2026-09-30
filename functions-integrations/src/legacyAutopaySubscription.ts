/**
 * Wording for the AutoPay switches (setTenantAutopay through
 * setTenantAutopayArming, and the billing panel's toggleAutopay) when a
 * tenant's legacy platform subscription could not be cancelled. The cancel
 * itself is cancelLegacyAutopaySubscription in functions-shared.
 */

/** Why a switch that had to cancel the legacy subscription stopped. */
export function legacyNotCancelledMessage(turningOn: boolean): string {
  return turningOn
    ? "Autopay was not turned on: their older autopay subscription in Stripe couldn't be cancelled, " +
        'and with both running they would be charged twice. Try again, and contact support if it keeps happening.'
    : "Autopay is off for their saved card, but their older autopay subscription in Stripe couldn't be " +
        'cancelled, so it may still charge them. Try again, and contact support if it keeps happening.';
}
