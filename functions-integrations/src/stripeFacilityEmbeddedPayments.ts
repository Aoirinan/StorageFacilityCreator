/**
 * Embedded Stripe payments and refunds.
 *
 * Tenant card capture and charging run on the facility's CONNECTED Stripe
 * account (see stripeFacilityConnectCheckout). The platform-account variants
 * that used to be exported here — processStripePayment, createSetupIntent and
 * attachPaymentMethod — had no caller and would have moved money into the
 * platform balance instead of the facility owner's, so they are no longer
 * exported.
 */
export { toggleAutopay } from './stripeFacilityTenantBillingCallables';
export {
  ensureFacilityStripeCustomer,
  processRefund,
} from './stripeFacilityRefundsAndCustomers';
