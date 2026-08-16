// Tenant billing callables.
//
// getOrCreateStripeCustomer / createEmbeddedSetupIntent /
// createOneTimePaymentIntent / listSavedPaymentMethods / detachPaymentMethod
// used to be exported from here. They operated on the PLATFORM Stripe account
// while tenant cards live on the facility's CONNECTED account, so money they
// moved would have landed in the platform's balance rather than the owner's.
// Nothing in the app called them, and connected-account equivalents already
// exist (createTenantSetupIntent, attachTenantPaymentMethod,
// createOneTimePaymentIntentOnConnectedAccount, chargeTenantOffSession).
// They are no longer exported so they cannot be reached or wired up by mistake.
export { toggleAutopay } from './stripeFacilityTenantBillingToggleAutopay';
