# Payment Architecture Documentation

**Last Updated:** 2024-12-XX  
**Version:** 2.0 (Enhanced with Connect + Feature Flags)

## Overview

Storage Facility Creator uses a **Stripe-first, PCI-safer payment architecture** where:
- Clients NEVER handle raw PAN/CVV
- Servers NEVER see/store card numbers
- All payment writes happen server-side using Stripe APIs
- Webhooks are the source of truth for payment state transitions
- **NEW:** Stripe Connect for tenant payments (0% platform fee)
- **NEW:** Feature flags for safe, gradual rollout

## Architecture Principles

### Non-Negotiable Rules

1. **No raw card data in client code**
   - No `cardNumber`, `cvv`, `cvc`, or `pan` fields in UI
   - Card data only enters Stripe Elements/hosted fields
   - Client only receives PaymentMethod IDs

2. **No Stripe secret keys in client**
   - All secrets stored in Firebase Secret Manager
   - Only publishable keys in client code

3. **All payment writes server-side**
   - PaymentIntent creation: Cloud Functions only
   - SetupIntent creation: Cloud Functions only
   - Payment method attachment: Cloud Functions only

4. **Webhooks as source of truth**
   - Payment state transitions driven by Stripe webhooks
   - Idempotent webhook processing
   - Firestore updated via webhook handlers

5. **Feature flags for safe rollout**
   - All new features behind feature flags (default OFF)
   - Gradual enablement via allowlist or global flags
   - Emergency kill switch for all payment actions

6. **Stripe Connect for tenant payments**
   - Tenant payments route to facility owner's connected account
   - 0% platform fee for Connect payments
   - Platform billing (facilities → SFC) remains on platform account

## Payment Flows

### 1. Customer Setup

When a facility admin enables billing or a tenant needs to save a payment method:

**Server-side (Cloud Function): `ensureFacilityStripeCustomer` / `createSetupIntent`**
- Creates/retrieves Stripe Customer
- Stores only `stripeCustomerId` in Firestore
- Never stores full card details

**Firestore Storage:**
```typescript
{
  stripeCustomerId: "cus_xxx",
  defaultPaymentMethodId: "pm_xxx", // optional
  subscriptionId: "sub_xxx" // optional, for SaaS billing
}
```

### 2. Card Capture (Web)

**Flow:**
1. Client calls `createSetupIntent` (Cloud Function)
2. Server creates SetupIntent, returns `clientSecret`
3. Client opens `/stripe_card_capture.html` with `clientSecret`
4. Stripe Elements captures card data (never touches our servers)
5. Client confirms SetupIntent with Stripe
6. Stripe returns PaymentMethod ID to client
7. Client calls `attachPaymentMethod` (Cloud Function)
8. Server attaches PaymentMethod to Customer, stores safe metadata

**Client receives:**
- `clientSecret` (for SetupIntent confirmation)
- `paymentMethodId` (tokenized, safe to store)
- Display info: `last4`, `brand`, `expMonth`, `expYear`

**Client NEVER receives:**
- Full card number
- CVV/CVC
- Any raw card data

**Implementation:**
- `web/stripe_card_capture.html` - Isolated Stripe Elements page
- `lib/services/setup_intent_service.dart` - Flutter service
- `functions/src/index.ts` - `createSetupIntent`, `attachPaymentMethod`

### 3. Autopay Setup

**Flow:**
1. Tenant saves payment method via SetupIntent (see Card Capture)
2. Payment method stored with `autopayEnabled: true`
3. Scheduled function `processAutopayPayments` runs monthly
4. For each enabled payment method:
   - Server creates PaymentIntent with stored `stripePaymentMethodId`
   - Charges customer off-session
   - Updates Firestore with payment result

**Storage:**
```typescript
{
  stripePaymentMethodId: "pm_xxx", // tokenized, safe
  stripeCustomerId: "cus_xxx",
  last4: "4242",
  brand: "visa",
  expiryMonth: 12,
  expiryYear: 2025,
  autopayEnabled: true,
  autopaySchedule: { frequency: "monthly", dayOfMonth: 1 }
}
```

### 4. One-Time Charges

**Flow:**
1. Client calls `processStripePayment` (Cloud Function)
2. Server creates PaymentIntent with `paymentMethodId`
3. If 3DS required, returns `clientSecret` to client
4. Client confirms with Stripe Elements
5. Webhook updates Firestore when payment succeeds

**Server-side only:**
- PaymentIntent creation
- Payment confirmation (if off-session)
- Error handling

### 5. Webhooks

**Endpoint:** `stripeWebhook` (Cloud Function)

**Events Handled:**
- `payment_intent.succeeded` → Update payment status in Firestore
- `payment_intent.payment_failed` → Log failure, update status
- `setup_intent.succeeded` → Log success (payment method already attached)
- `invoice.payment_succeeded` → Update subscription status
- `invoice.payment_failed` → Mark subscription as past_due
- `customer.subscription.updated` → Update subscription metadata
- `customer.subscription.deleted` → Mark subscription as cancelled

**Idempotency:**
- Events tracked by `event.id` in Firestore
- Duplicate events are acknowledged but not reprocessed

**Security:**
- Webhook signature verification using `STRIPE_WEBHOOK_SECRET`
- Invalid signatures rejected with 400

## Data Storage

### What We Store ✅

**Safe to store:**
- `stripeCustomerId` - Stripe customer identifier
- `stripePaymentMethodId` - Tokenized payment method ID
- `last4` - Last 4 digits of card
- `brand` - Card brand (visa, mastercard, etc.)
- `expiryMonth` - Expiration month (1-12)
- `expiryYear` - Expiration year
- `subscriptionId` - Stripe subscription ID (for SaaS billing)

### What We Never Store ❌

**Never stored:**
- Full card number (PAN)
- CVV/CVC
- Cardholder name (unless provided separately for display)
- Any raw card data

## Error Handling

### User-Friendly Error Messages

Stripe error codes are mapped to actionable user messages:

- `card_declined` → "Your card was declined. Please try another card or contact your bank."
- `insufficient_funds` → "Insufficient funds. Please use a different payment method."
- `expired_card` → "Your card has expired. Please use a different card."
- `incorrect_cvc` → "The security code is incorrect. Please check and try again."
- `processing_error` → "An error occurred while processing your card. Please try again."

**Implementation:**
- `mapStripeErrorToUserMessage()` in `functions/src/index.ts`
- `SetupIntentService.getErrorMessage()` in Flutter

### Error Monitoring

**Sentry Integration:**
- Errors captured with scrubbed data
- Payment endpoints exclude request bodies
- Sensitive fields redacted before sending to Sentry

**Log Scrubbing:**
- Sensitive keys automatically redacted: `cardNumber`, `cvv`, `cvc`, `pan`, `paymentMethodId`, `clientSecret`
- Request bodies excluded from payment endpoint logs
- Webhook payloads never logged (only event.id, type, metadata)

## Feature Flags System

### Configuration

**Firestore Document:** `appConfig/stripe`

```typescript
{
  connectEnabledGlobal: boolean;           // Global flag for Connect onboarding
  tenantAutopayEnabledGlobal: boolean;     // Global flag for tenant autopay
  storeEnabledGlobal: boolean;             // Global flag for store checkout
  checkoutEnabledGlobal: boolean;          // Global flag for checkout sessions
  allowlistFacilityIds: string[];         // Facility IDs with features enabled
  killSwitch: boolean;                     // Emergency brake (disables ALL)
}
```

### Feature Enablement Logic

A feature is enabled if:
1. `killSwitch` is `false` (emergency brake)
2. AND (`globalFlag` is `true` OR `facilityId` is in `allowlistFacilityIds`)

**Default State (Production-Safe):**
- All flags: `false`
- `allowlistFacilityIds`: `[]`
- `killSwitch`: `false`
- **Result:** All new features disabled, existing flows unchanged

### Feature Flag Checks

All new functions check feature flags before processing:
- `createStripeConnectAccount` → checks `connectEnabledGlobal` or allowlist
- `createTenantSetupIntent` → checks `tenantAutopayEnabledGlobal` or allowlist
- `chargeTenantOffSession` → checks `tenantAutopayEnabledGlobal` or allowlist
- `createStoreCheckout` → checks `storeEnabledGlobal` or allowlist

**Existing functions (platform billing) are NOT feature-flagged** to preserve production behavior.

## Stripe Connect Architecture

### Account Types

1. **Platform Account (SFC)**
   - Used for: Facility subscription billing ($75/mo)
   - Payments: Facilities paying SFC
   - Webhooks: Subscription events

2. **Connected Accounts (Facilities)**
   - Used for: Tenant rent payments, store checkout
   - Payments: Tenants paying facilities (0% platform fee)
   - Webhooks: Payment events on connected accounts

### Connect Onboarding Flow

1. Facility owner calls `createStripeConnectAccount`
2. System creates Standard Connect account
3. Facility owner completes onboarding via `createStripeConnectAccountLink`
4. System stores Connect status: `stripeConnectAccountId`, `stripeConnectStatus`, `chargesEnabled`, `payoutsEnabled`
5. Facility owner can access dashboard via `createStripeConnectLoginLink`

### Tenant Payments on Connected Accounts

**Flow:**
1. Tenant saves payment method via `createTenantSetupIntent` (on connected account)
2. Payment method attached via `attachTenantPaymentMethod` (on connected account)
3. Autopay charges via `chargeTenantOffSession` (on connected account)
4. All funds go directly to facility owner (0% platform fee)

**Storage:**
- `facilities/{facilityId}/tenants/{tenantId}` → `stripeConnectedCustomerId` (on connected account)
- `facilities/{facilityId}/tenants/{tenantId}/paymentMethods/{pmId}` → `stripeConnectedAccountId` (tracks which account)
- `tenantCharges/{chargeId}` → Charges on connected accounts

## Store Checkout

**Flow:**
1. Customer selects items (locks/boxes)
2. System calls `createStoreCheckout` (on connected account)
3. Customer completes payment via Stripe Elements
4. Sale recorded in `facilities/{facilityId}/sales/{saleId}`
5. Webhook updates sale status

**Storage:**
```typescript
{
  facilityId: string;
  stripePaymentIntentId: string;
  stripeConnectedAccountId: string;
  lineItems: Array<{
    sku: string;
    name: string;
    description: string;
    quantity: number;
    price: number;
  }>;
  totalAmount: number;
  currency: 'usd';
  customerEmail: string | null;
  customerName: string | null;
  status: 'pending' | 'completed' | 'failed';
  createdAt: Timestamp;
  updatedAt: Timestamp;
}
```

## Enhanced Webhook Handlers

### New Event Handlers

- `charge.refunded` → Updates payment status, creates ledger entry
- `charge.dispute.created` → Updates payment status, creates ledger entry

### Enhanced Idempotency

**Collection:** `stripeWebhookEvents/{eventId}`

```typescript
{
  eventType: string;
  account: string | null;        // Stripe account ID (platform or connected)
  facilityId: string | null;     // Derived from event metadata
  tenantId: string | null;       // Derived from event metadata
  processedAt: Timestamp;
  createdAt: Timestamp;
}
```

**Benefits:**
- Track which account events came from
- Track which facility/tenant events relate to
- Better debugging and audit trail

## Data Storage

### What We Store ✅

**Safe to store:**
- `stripeCustomerId` - Stripe customer identifier
- `stripePaymentMethodId` - Tokenized payment method ID
- `stripeConnectedCustomerId` - Customer ID on connected account
- `stripeConnectedAccountId` - Connected account ID
- `last4` - Last 4 digits of card
- `brand` - Card brand (visa, mastercard, etc.)
- `expiryMonth` - Expiration month (1-12)
- `expiryYear` - Expiration year
- `subscriptionId` - Stripe subscription ID (for SaaS billing)
- `stripePaymentIntentId` - PaymentIntent ID
- `stripeChargeId` - Charge ID (for refunds/disputes)

### What We Never Store ❌

**Never stored:**
- Full card number (PAN)
- CVV/CVC
- Cardholder name (unless provided separately for display)
- Any raw card data
- Webhook payloads (only event IDs and metadata)

## Error Handling

### User-Friendly Error Messages

Stripe error codes are mapped to actionable user messages:

- `card_declined` → "Your card was declined. Please try another card or contact your bank."
- `insufficient_funds` → "Insufficient funds. Please use a different payment method."
- `expired_card` → "Your card has expired. Please use a different card."
- `incorrect_cvc` → "The security code is incorrect. Please check and try again."
- `processing_error` → "An error occurred while processing your card. Please try again."

**Implementation:**
- `mapStripeErrorToUserMessage()` in `functions/src/index.ts`
- `SetupIntentService.getErrorMessage()` in Flutter

### Error Monitoring

**Sentry Integration:**
- Errors captured with scrubbed data
- Payment endpoints exclude request bodies
- Sensitive fields redacted before sending to Sentry

**Log Scrubbing:**
- Payment-related logs exclude sensitive data
- No card numbers, CVV, or payment method IDs in logs
- Only safe metadata logged (facilityId, tenantId, error messages)

## Security Headers & CSP

### Content Security Policy

**Enforced CSP (not report-only):**
```
default-src 'self';
script-src 'self' https://js.stripe.com 'unsafe-inline';
style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
font-src 'self' https://fonts.gstatic.com data:;
img-src 'self' data: https:;
connect-src 'self' https://api.stripe.com https://*.firebaseio.com https://*.googleapis.com wss://*.firebaseio.com;
frame-src 'self' https://js.stripe.com https://hooks.stripe.com;
frame-ancestors 'none';
base-uri 'self';
form-action 'self';
upgrade-insecure-requests;
```

**Key Points:**
- Stripe.js allowed from `https://js.stripe.com`
- Stripe iframes allowed in `frame-src`
- No `unsafe-eval` (unless absolutely required)
- `unsafe-inline` for styles (try to remove if possible)

### Security Headers

**Firebase Hosting Headers:**
- `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: geolocation=(), microphone=(), camera=()`

## Migration Notes

### For Existing Facilities

- Existing payment methods using `stripePaymentMethodId` are safe and continue to work
- New card capture flow is opt-in for new payment methods
- No breaking changes to existing autopay functionality
- Existing Stripe Customers remain valid

### Setup Requirements

1. **Firebase Secret Manager:**
   - `STRIPE_SECRET_KEY` - Stripe secret key
   - `STRIPE_WEBHOOK_SECRET` - Webhook signing secret
   - `SENTRY_DSN` - (optional) Sentry DSN for error monitoring

2. **Stripe Dashboard:**
   - Configure webhook endpoint: `https://[region]-[project].cloudfunctions.net/stripeWebhook`
   - Subscribe to events: `payment_intent.*`, `setup_intent.succeeded`, `invoice.*`, `customer.subscription.*`

3. **Firebase Hosting:**
   - Deploy `web/stripe_card_capture.html` to hosting
   - Ensure CSP headers allow Stripe domains

## Testing Checklist

### Local Testing

1. **Verify no card data in codebase:**
   ```bash
   grep -r "cardNumber\|cvv\|cvc\|pan" lib/ functions/src/
   # Should return no matches
   ```

2. **Test SetupIntent flow:**
   - Create SetupIntent via Cloud Function
   - Open card capture page with clientSecret
   - Confirm SetupIntent with test card
   - Verify PaymentMethod attached to Customer

3. **Test PaymentIntent flow:**
   - Create PaymentIntent with saved PaymentMethod
   - Verify payment succeeds
   - Check webhook updates Firestore

4. **Test error handling:**
   - Use declined test card (4000 0000 0000 0002)
   - Verify user-friendly error message
   - Check Sentry receives error (with scrubbed data)

5. **Test CSP:**
   - Verify Stripe.js loads correctly
   - Check browser console for CSP violations
   - Ensure payment forms work

6. **Test webhooks:**
   - Send test webhook from Stripe Dashboard
   - Verify signature validation
   - Check idempotency (duplicate events)

### Production Verification

1. ✅ No raw card fields in UI or API payloads (grep test)
2. ✅ Payment capture uses Stripe Elements and only returns PaymentMethod IDs
3. ✅ Webhooks update billing state correctly
4. ✅ Error monitoring enabled and receives test exceptions
5. ✅ CSP + headers don't break app, Stripe still works
6. ✅ Marketing copy visible on site

## Files Reference

### Server-Side (Cloud Functions)
- `functions/src/index.ts`
  - `createSetupIntent` - Create SetupIntent for card capture
  - `attachPaymentMethod` - Attach PaymentMethod to Customer
  - `ensureFacilityStripeCustomer` - Create/get Stripe Customer
  - `processStripePayment` - Process one-time payments
  - `stripeWebhook` - Webhook handler
  - `mapStripeErrorToUserMessage` - Error message mapping

### Client-Side (Flutter Web)
- `lib/services/setup_intent_service.dart` - SetupIntent service
- `lib/services/stripe_service.dart` - Stripe service (existing)
- `lib/models/payment_method_model.dart` - Payment method model
- `lib/services/payment_method_service.dart` - Payment method service

### Web Assets
- `web/stripe_card_capture.html` - Isolated Stripe Elements page
- `web/index.html` - Main HTML with CSP meta tag
- `firebase.json` - Security headers and CSP configuration

### Marketing
- `lib/screens/marketing_landing_page.dart` - Security pitch section

### Documentation
- `docs/payments_audit.md` - Initial audit report
- `docs/payments_architecture.md` - This file

## Support

For questions or issues:
1. Check Stripe Dashboard for payment status
2. Review Cloud Functions logs (with scrubbed data)
3. Check Sentry for error tracking
4. Verify webhook events in Stripe Dashboard
