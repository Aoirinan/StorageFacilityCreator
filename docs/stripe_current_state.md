# Stripe Current State Inventory Report

**Generated:** 2024-12-XX  
**Purpose:** Safe discovery of existing Stripe implementation before making improvements  
**Status:** Phase 0 - No functional changes

---

## Executive Summary

The Storage Facility Creator (SFC) application has a **substantial existing Stripe implementation** with:
- ✅ Platform billing (facilities paying SFC $75/mo subscription)
- ✅ Stripe Connect onboarding (Standard accounts)
- ✅ Tenant payment processing (via Connect accounts)
- ✅ PCI-safe card capture (Stripe Elements)
- ✅ Webhook handling with idempotency
- ⚠️ **No feature flags** - all features are always enabled
- ⚠️ **No centralized config** - hardcoded behavior

**Production-Critical Paths Identified:**
1. Facility subscription billing (`createSubscriptionCheckout`, `stripeWebhook` → subscription events)
2. Tenant payment processing (`processStripePayment`, `createTenantPaymentCheckout`)
3. Webhook processing (`stripeWebhook` with idempotency)
4. Payment method capture (`createSetupIntent`, `attachPaymentMethod`)

---

## 1. Existing Stripe-Related Cloud Functions

### Platform Billing (Facilities → SFC)

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `createSubscriptionCheckout` | `https.onCall` | Creates Stripe Checkout session for facility subscription ($75/mo base + $75/mo per additional facility) | ✅ Active |
| `createCustomerPortalSession` | `https.onCall` | Creates Stripe Customer Portal session for subscription management | ✅ Active |
| `updateSubscriptionQuantity` | `https.onCall` | Updates subscription quantity when facilities are added/removed | ✅ Active |
| `ensureFacilityStripeCustomer` | `https.onCall` | Creates/retrieves Stripe Customer for facility (SaaS billing) | ✅ Active |

**Storage:**
- `facilityCreatorAccounts/{accountId}` → `stripeCustomerId`, `stripeSubscriptionId`, `subscriptionStatus`
- Uses lookup keys: `sfc_base_monthly_75`, `sfc_addon_monthly_75`

### Stripe Connect (Facilities → Tenant Payments)

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `createStripeConnectAccount` | `https.onCall` | Creates Standard Connect account for facility | ✅ Active |
| `createStripeConnectAccountLink` | `https.onCall` | Creates onboarding link URL for Connect account | ✅ Active |
| `getStripeConnectAccountStatus` | `https.onCall` | Returns Connect account status (charges_enabled, payouts_enabled, etc.) | ✅ Active |

**Storage:**
- `facilities/{facilityId}` → `stripeConnectAccountId`, `stripeConnectOnboardingComplete`

**Missing:**
- ❌ `createStripeConnectLoginLink` (dashboard login link) - NOT IMPLEMENTED

### Tenant Payment Processing

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `createSetupIntent` | `https.onCall` | Creates SetupIntent for saving payment method (PCI-safe) | ✅ Active |
| `attachPaymentMethod` | `https.onCall` | Attaches PaymentMethod to customer after SetupIntent confirmation | ✅ Active |
| `processStripePayment` | `https.onCall` | Creates PaymentIntent for one-time or autopay charges | ✅ Active |
| `createTenantPaymentCheckout` | `https.onCall` | Creates Checkout session on connected account (0% platform fee) | ✅ Active |
| `createTenantPortalPaymentCheckout` | `https.onCall` | Creates Checkout session for tenant portal (public access) | ✅ Active |
| `createPublicPaymentCheckout` | `https.onCall` | Creates Checkout session for public payment links (token-based) | ✅ Active |
| `processAutopayPayments` | `pubsub.schedule` | Scheduled function for processing autopay charges | ✅ Active |

**Storage:**
- `facilities/{facilityId}/tenants/{tenantId}` → `stripeCustomerId`
- `facilities/{facilityId}/tenants/{tenantId}/paymentMethods/{pmId}` → `stripePaymentMethodId`, `last4`, `brand`, `expiryMonth`, `expiryYear`, `autopayEnabled`
- `facilities/{facilityId}/payments/{paymentId}` → `externalPaymentId` (Stripe PaymentIntent ID)

**Missing:**
- ❌ `createTenantSetupIntent` (on connected account) - Currently uses platform account
- ❌ `attachTenantPaymentMethod` (on connected account) - Currently uses platform account
- ❌ `chargeTenantOffSession` (on connected account) - Currently uses `processStripePayment` on platform account

### Refunds & Disputes

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `processRefund` | `https.onCall` | Processes refund for a payment | ✅ Active |

**Note:** Refund function exists but needs verification for Connect account support.

### Webhooks

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `stripeWebhook` | `https.onRequest` | Handles all Stripe webhook events | ✅ Active |

**Idempotency:** ✅ Implemented
- Collection: `stripeWebhookEvents/{eventId}`
- Functions: `isStripeEventProcessed()`, `markStripeEventProcessed()`
- **Note:** Uses `stripeWebhookEvents` collection, NOT `processedStripeEvents` as specified in requirements

**Events Handled:**
- ✅ `checkout.session.completed`
- ✅ `customer.subscription.created`
- ✅ `customer.subscription.updated`
- ✅ `customer.subscription.deleted`
- ✅ `invoice.payment_succeeded`
- ✅ `invoice.payment_failed`
- ✅ `account.updated` (Connect account updates)
- ✅ `payment_intent.succeeded`
- ✅ `payment_intent.payment_failed`
- ✅ `setup_intent.succeeded`

**Missing Events (from requirements):**
- ❌ `charge.refunded` - NOT HANDLED
- ❌ `charge.dispute.created` - NOT HANDLED

### Generic/Utility

| Function Name | Type | Purpose | Status |
|--------------|------|---------|--------|
| `createCheckoutSession` | `https.onCall` | Generic one-time payment checkout session | ✅ Active |

---

## 2. Flutter Screens / Routes / Components

### Payment-Related Screens

| Screen/Route | Purpose | Status |
|-------------|---------|--------|
| `StripeConnectOnboardingScreen` | Connect account onboarding UI | ✅ Active |
| `SubscriptionTestScreen` | Test subscription checkout flow | ✅ Active (likely dev/test) |
| `PublicPaymentScreen` | Public payment link handler (`/pay?token=...`) | ✅ Active |
| `TenantPortalScreen` | Tenant self-service portal with payment options | ✅ Active |

### Services

| Service | Purpose | Status |
|---------|---------|--------|
| `StripeService` | Main Stripe service wrapper for Cloud Functions | ✅ Active |
| `SetupIntentService` | SetupIntent creation and payment method attachment | ✅ Active |
| `StripeElementsService` | Stripe Elements integration (if used) | ✅ Active |
| `PaymentMethodService` | Payment method CRUD operations | ✅ Active |
| `AutopayService` | Autopay scheduling and processing | ✅ Active |
| `PaymentService` | General payment operations | ✅ Active |

### Hosted Card Capture

| File | Purpose | Status |
|------|---------|--------|
| `web/stripe_card_capture.html` | PCI-safe card capture page using Stripe Elements | ✅ Active |
| Uses: Stripe Elements `card` component, `confirmCardSetup()` | | |

---

## 3. Firestore Billing Schema

### Facility-Level Billing

**Collection:** `facilityCreatorAccounts/{accountId}`

```typescript
{
  stripeCustomerId: string;           // Stripe customer ID (for SaaS billing)
  stripeSubscriptionId: string;       // Stripe subscription ID
  subscriptionStatus: 'active' | 'past_due' | 'cancelled' | 'trialing' | ...
  subscriptionCurrentPeriodStart: Timestamp;
  subscriptionCurrentPeriodEnd: Timestamp;
  subscriptionCancelAtPeriodEnd: boolean;
  subscriptionCanceledAt: Timestamp | null;
  subscriptionTrialEnd: Timestamp | null;
}
```

**Collection:** `facilities/{facilityId}`

```typescript
{
  stripeConnectAccountId: string;              // Connected account ID (acct_xxx)
  stripeConnectOnboardingComplete: boolean;   // Onboarding status
  // Note: Missing fields from requirements:
  // - stripeConnectStatus (pending/active/needs_action)
  // - chargesEnabled (boolean)
  // - payoutsEnabled (boolean)
  // - updatedAt (timestamp for Connect status)
}
```

### Tenant-Level Billing

**Collection:** `facilities/{facilityId}/tenants/{tenantId}`

```typescript
{
  stripeCustomerId: string;           // Stripe customer ID (on platform account, NOT connected)
  // Note: Should be on connected account for tenant payments
}
```

**Collection:** `facilities/{facilityId}/tenants/{tenantId}/paymentMethods/{pmId}`

```typescript
{
  stripePaymentMethodId: string;      // Tokenized payment method ID (pm_xxx)
  stripeCustomerId: string;           // Customer ID
  last4: string;                      // Last 4 digits
  brand: string;                      // Card brand (visa, mastercard, etc.)
  expiryMonth: number;                // 1-12
  expiryYear: number;                  // YYYY
  isDefault: boolean;
  autopayEnabled: boolean;
  autopaySchedule: {
    frequency: 'monthly' | 'weekly' | 'quarterly' | 'annually';
    dayOfMonth?: number;
    dayOfWeek?: number;
    amount?: number;
    includeInsurance: boolean;
  };
  autopayNextRun: Timestamp | null;
  autopayLastRun: Timestamp | null;
  autopayLastResult: 'success' | 'failed' | 'skipped' | null;
  autopayLastError: string | null;
  createdAt: Timestamp;
  createdBy: string;                   // User UID
  isActive: boolean;
}
```

**Collection:** `facilities/{facilityId}/payments/{paymentId}`

```typescript
{
  tenantId: string;
  facilityId: string;
  contractId: string;
  amount: number;
  status: 'pending' | 'paid' | 'completed' | 'failed' | 'refunded' | 'cancelled';
  method: 'creditCard' | 'debitCard' | 'bankTransfer' | 'check' | 'cash' | 'square' | 'stripe';
  dueDate: Timestamp;
  paidDate: Timestamp | null;
  transactionId: string | null;
  externalPaymentId: string;          // Stripe PaymentIntent ID (pi_xxx)
  notes: string | null;
  receiptUrl: string | null;
  depositId: string | null;
  metadata: Map<string, dynamic> | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  createdBy: string;
  isActive: boolean;
}
```

**Collection:** `facilities/{facilityId}/ledgers/{entryId}`

```typescript
{
  tenantId: string;
  facilityId: string;
  type: 'payment' | 'charge' | 'refund' | 'fee' | ...
  amount: number;                     // Negative for payments, positive for charges
  description: string;
  referenceId: string | null;         // Link to payment/invoice
  entryDate: Timestamp;
  status: 'posted' | 'pending' | 'void';
  createdAt: Timestamp;
  createdBy: string;
  metadata: Map<string, dynamic> | null;
}
```

### Webhook Idempotency

**Collection:** `stripeWebhookEvents/{eventId}`

```typescript
{
  eventType: string;                  // e.g., 'payment_intent.succeeded'
  processedAt: Timestamp;
}
```

**Note:** Uses `stripeWebhookEvents` collection. Requirements specify `processedStripeEvents/{eventId}` with additional fields:
- `createdAt` (should be `processedAt`)
- `type` (same as `eventType`)
- `account` (Stripe account ID - missing)
- `facilityId` (derived - missing)
- `tenantId` (derived - missing)

### Missing Collections (from requirements)

- ❌ `tenantCharges` collection - NOT IMPLEMENTED (should store tenant charges on connected accounts)
- ❌ `appConfig/stripe` - NOT IMPLEMENTED (feature flags/config)

---

## 4. Webhook Assumptions & Implementation

### Current Implementation

**Endpoint:** `stripeWebhook` (Cloud Function `https.onRequest`)

**Signature Verification:** ✅ Implemented
- Uses `STRIPE_WEBHOOK_SECRET` from Firebase Secrets
- Verifies `stripe-signature` header
- Uses `stripe.webhooks.constructEvent()`

**Idempotency:** ✅ Implemented
- Checks `stripeWebhookEvents/{eventId}` before processing
- Returns `{ received: true, duplicate: true }` if already processed
- Marks event as processed after successful handling

**Logging:** ✅ Safe
- Does NOT log full payload
- Does NOT log request body
- Logs only: `event.id`, `event.type`, derived `facilityId`/`tenantId` from metadata
- Error logs scrubbed (no sensitive data)

**Duplicate Endpoints:** ❌ **POTENTIAL ISSUE**
- Only one webhook endpoint found: `stripeWebhook`
- Need to verify Stripe Dashboard has only one webhook endpoint configured
- If multiple endpoints exist, could cause duplicate processing (even with idempotency)

**Connect Account Support:** ⚠️ **PARTIAL**
- Handles `account.updated` event
- Webhook handlers check metadata for `facilityId`/`tenantId`
- **Issue:** Webhook events from connected accounts may not include `Stripe-Account` header context
- **Issue:** Some handlers may not support `stripeAccount` parameter for Connect events

### Event Handlers

| Event Type | Handler | Connects Account Aware? | Notes |
|-----------|---------|------------------------|-------|
| `checkout.session.completed` | `handleCheckoutCompleted()` | ❌ No | Uses `session.metadata.accountId` (platform billing) |
| `customer.subscription.*` | `handleSubscriptionUpdate()` / `handleSubscriptionDeleted()` | ❌ No | Platform billing only |
| `invoice.payment_*` | `handleInvoicePaymentSucceeded()` / `handleInvoicePaymentFailed()` | ❌ No | Platform billing only |
| `account.updated` | `handleConnectAccountUpdated()` | ✅ Yes | Updates facility Connect status |
| `payment_intent.succeeded` | `handlePaymentIntentSucceeded()` | ⚠️ Partial | Uses metadata, but may not handle Connect account context |
| `payment_intent.payment_failed` | `handlePaymentIntentFailed()` | ⚠️ Partial | Uses metadata, but may not handle Connect account context |
| `setup_intent.succeeded` | `handleSetupIntentSucceeded()` | ⚠️ Partial | Logs only, no Connect account handling |

**Missing Handlers:**
- ❌ `charge.refunded` - NOT HANDLED
- ❌ `charge.dispute.created` - NOT HANDLED

---

## 5. Payment Methods & PCI Safety

### Current Implementation

**Card Capture:** ✅ PCI-Safe
- Uses Stripe Elements in `web/stripe_card_capture.html`
- Client only receives `clientSecret` and `paymentMethodId`
- Never handles raw card data

**Storage:** ✅ Safe
- Only stores: `stripePaymentMethodId`, `last4`, `brand`, `expiryMonth`, `expiryYear`
- Never stores: card number, CVV/CVC, PAN

**Logging:** ✅ Safe
- Sensitive keys scrubbed: `['cardNumber', 'cvv', 'cvc', 'pan', 'paymentMethodId', 'clientSecret']`
- Error logs exclude request bodies
- Sentry events scrubbed

### Payment Element vs Checkout vs PaymentIntents

| Method | Usage | Status |
|--------|-------|--------|
| **Stripe Checkout** | Platform billing subscriptions, tenant payment links | ✅ Active |
| **Stripe Elements** | Card capture (`stripe_card_capture.html`) | ✅ Active |
| **PaymentIntents** | One-time charges, autopay (`processStripePayment`) | ✅ Active |
| **SetupIntents** | Saving payment methods (`createSetupIntent`) | ✅ Active |

**Note:** No Payment Element usage found (newer Stripe UI component). Current implementation uses legacy Elements.

---

## 6. Stripe Connect Presence

### Current Implementation

**Account Creation:** ✅ Implemented
- `createStripeConnectAccount` creates Standard Connect accounts
- Stores `stripeConnectAccountId` on facility doc

**Onboarding:** ✅ Implemented
- `createStripeConnectAccountLink` creates onboarding links
- UI: `StripeConnectOnboardingScreen`
- Stores `stripeConnectOnboardingComplete` flag

**Status Checking:** ✅ Implemented
- `getStripeConnectAccountStatus` retrieves account status
- Returns: `chargesEnabled`, `payoutsEnabled`, `detailsSubmitted`

**Missing:**
- ❌ `createStripeConnectLoginLink` - Dashboard login link NOT IMPLEMENTED
- ❌ Connect account status not persisted to Firestore (only returned in API call)
- ❌ Missing fields: `stripeConnectStatus`, `chargesEnabled`, `payoutsEnabled`, `updatedAt` on facility doc

### Payment Routing

**Current:** ⚠️ **MIXED**
- `processStripePayment` supports Connect accounts via `on_behalf_of` and `transfer_data`
- `createTenantPaymentCheckout` creates Checkout sessions on connected account (✅ correct)
- `createSetupIntent` creates SetupIntents on **platform account** (❌ should be connected account)
- `attachPaymentMethod` attaches to **platform account customer** (❌ should be connected account)

**Issue:** Tenant payment methods are stored on platform account, not connected account. This means:
- Tenant payments may not route correctly to facility owner
- Autopay charges may not use connected account

---

## 7. Risky Patterns Found

### ✅ Safe Patterns (No Issues)

1. **No raw card data in codebase**
   - Searched for: `cardNumber`, `cvv`, `cvc`, `pan`, `expiry`
   - Only found in: error handling (`incorrect_cvc`), documentation, test data
   - ✅ No actual card data fields in UI or storage

2. **Secrets properly managed**
   - All Stripe secrets in Firebase Secret Manager
   - `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` defined as secrets
   - ✅ No secrets in client code

3. **Logging is safe**
   - Sensitive keys scrubbed in audit logs
   - Webhook errors don't log request bodies
   - ✅ No card data in logs

### ⚠️ Potential Issues

1. **Webhook endpoint duplication**
   - Need to verify only one webhook endpoint in Stripe Dashboard
   - If multiple endpoints exist, idempotency prevents double-processing but wastes resources

2. **Connect account context missing**
   - Some webhook handlers may not handle `Stripe-Account` header
   - Payment intents created on connected accounts may not be properly routed in webhooks

3. **Idempotency collection name mismatch**
   - Uses `stripeWebhookEvents` instead of `processedStripeEvents` (per requirements)
   - Missing fields: `account`, `facilityId`, `tenantId` (derived from event)

4. **Feature flags missing**
   - All features always enabled
   - No way to disable Connect, tenant payments, or store checkout
   - No `killSwitch` for emergency shutdown

---

## 8. Production-Critical Paths

### MUST NOT BREAK

1. **Facility Subscription Billing**
   - Functions: `createSubscriptionCheckout`, `createCustomerPortalSession`, `updateSubscriptionQuantity`
   - Webhooks: `checkout.session.completed`, `customer.subscription.*`, `invoice.payment_*`
   - Storage: `facilityCreatorAccounts/{accountId}` → subscription status
   - **Impact:** Facilities lose access if billing breaks
   - **Access Control:** Subscription status checked in app (likely)

2. **Tenant Payment Processing (Existing)**
   - Functions: `processStripePayment`, `createTenantPaymentCheckout`, `createPublicPaymentCheckout`
   - Webhooks: `payment_intent.succeeded`, `payment_intent.payment_failed`
   - Storage: `facilities/{facilityId}/payments/{paymentId}`
   - **Impact:** Tenants cannot pay rent
   - **Note:** Currently uses platform account, not connected account (may need migration)

3. **Webhook Processing**
   - Function: `stripeWebhook`
   - Idempotency: `stripeWebhookEvents/{eventId}`
   - **Impact:** Payment state updates fail, subscriptions not updated
   - **Critical:** Must remain idempotent and safe

4. **Payment Method Capture**
   - Functions: `createSetupIntent`, `attachPaymentMethod`
   - UI: `web/stripe_card_capture.html`
   - Storage: `facilities/{facilityId}/tenants/{tenantId}/paymentMethods/{pmId}`
   - **Impact:** Cannot save cards for autopay
   - **Note:** Currently on platform account, should be on connected account

### CAN BE ENHANCED (Additive Only)

1. **Stripe Connect Onboarding**
   - Functions: `createStripeConnectAccount`, `createStripeConnectAccountLink`, `getStripeConnectAccountStatus`
   - UI: `StripeConnectOnboardingScreen`
   - **Status:** Can be enhanced with feature flags, but must not break existing onboarding

2. **Autopay Processing**
   - Function: `processAutopayPayments` (scheduled)
   - **Status:** Can be enhanced to use connected accounts, but must not break existing autopay

---

## 9. Recommendations for Phase 1

### Safe Additions (No Breaking Changes)

1. **Feature Flags System**
   - Create `appConfig/stripe` document
   - Add flags: `connectEnabledGlobal`, `tenantAutopayEnabledGlobal`, `storeEnabledGlobal`, `checkoutEnabledGlobal`, `allowlistFacilityIds`, `killSwitch`
   - Wrap new behavior behind flags (default OFF)

2. **Connect Account Enhancements**
   - Add `createStripeConnectLoginLink` function
   - Persist Connect status to Firestore: `stripeConnectStatus`, `chargesEnabled`, `payoutsEnabled`, `updatedAt`
   - Add UI status indicators

3. **Tenant Payments on Connected Accounts**
   - Add `createTenantSetupIntent` (on connected account)
   - Add `attachTenantPaymentMethod` (on connected account)
   - Add `chargeTenantOffSession` (on connected account)
   - Create `tenantCharges` collection for ledger

4. **Store Checkout**
   - Add one-time PaymentIntent creation on connected accounts
   - Store line items in Firestore
   - Support refunds on connected accounts

5. **Webhook Enhancements**
   - Add handlers for `charge.refunded`, `charge.dispute.created`
   - Enhance idempotency collection with `account`, `facilityId`, `tenantId` fields
   - Ensure Connect account context handling

### Must Preserve (Do Not Change)

1. **Existing subscription billing flow**
2. **Existing webhook idempotency** (can enhance, but don't break)
3. **Existing payment method storage schema** (can add fields, but don't remove)
4. **Existing function names and signatures** (add new functions, don't modify existing)

---

## 10. Manual Stripe Dashboard Steps Required

### Current State (Assumed)

1. **Webhook Endpoint**
   - URL: `https://[region]-[project].cloudfunctions.net/stripeWebhook`
   - Events subscribed: (need to verify in Stripe Dashboard)
   - Secret: Stored in Firebase Secrets as `STRIPE_WEBHOOK_SECRET`

2. **Products & Prices**
   - Base subscription: `sfc_base_monthly_75` ($75/month)
   - Add-on facility: `sfc_addon_monthly_75` ($75/month)
   - **Note:** Functions have fallback to create these if missing

3. **Connect Settings**
   - Connect Client ID: `ca_TWVomtZkyvI6Ie1ZLDJhjLiWHIwjtAwB` (stored as secret/env)
   - Account type: Standard

### Required for Phase 1

1. **Verify webhook endpoint**
   - Check only one endpoint exists
   - Verify all required events are subscribed
   - Test webhook delivery

2. **Create/verify products**
   - Ensure `sfc_base_monthly_75` and `sfc_addon_monthly_75` exist
   - Verify prices are active

3. **Connect configuration**
   - Verify Connect is enabled in Stripe Dashboard
   - Test Connect account creation flow

---

## Summary

**Existing Implementation:** ✅ **Strong foundation**
- PCI-safe architecture
- Webhook idempotency
- Connect onboarding
- Payment processing

**Gaps to Address:**
- ❌ Feature flags/config system
- ❌ Tenant payments on connected accounts (currently on platform)
- ❌ Store checkout (one-time charges)
- ❌ Missing webhook handlers (refunds, disputes)
- ❌ Connect account status persistence
- ❌ Login link for Connect dashboard

**Risk Level:** 🟢 **LOW**
- No risky patterns found (card data, secrets, logging)
- Existing flows are production-ready
- Additive changes can be made safely with feature flags

**Next Steps:**
1. Implement feature flags system (Phase 1A)
2. Enhance Connect functionality (Phase 1B)
3. Add tenant payments on connected accounts (Phase 1C)
4. Add store checkout (Phase 1D)
5. Enhance webhooks (Phase 2)
