# Stripe Embedded Payments – Implementation Summary

## Overview

Stripe-based payments are now embedded inside the SaaS UI. Tenants can save a card, toggle AutoPay, make one-time payments, and view payment history—all without leaving the app.

---

## New/Changed Files

### Cloud Functions (Firebase)

| File | Purpose |
|------|---------|
| `functions/src/stripe/tenant_billing.ts` | **NEW** – Tenant billing handlers (getOrCreateStripeCustomer, createSetupIntent, createOneTimePaymentIntent, toggleAutopay, listSavedPaymentMethods, detachPaymentMethod) |
| `functions/src/index.ts` | **MODIFIED** – Imports tenant billing module, exports 6 new callables, extends webhook handlers for setup_intent, payment_intent, invoice, subscription |

### Flutter (lib/)

| File | Purpose |
|------|---------|
| `lib/models/tenant_billing_model.dart` | **NEW** – Tenant Stripe billing state |
| `lib/models/tenant_stripe_payment_model.dart` | **NEW** – Stripe payment record (one_time, invoice) |
| `lib/models/saved_payment_method_model.dart` | **NEW** – Saved payment method from listSavedPaymentMethods |
| `lib/services/stripe_payments_service.dart` | **NEW** – Wraps Cloud Functions + provides streams |
| `lib/services/stripe_web_bridge.dart` | **NEW** – Conditional export (web/stub) |
| `lib/services/stripe_web_bridge_web.dart` | **NEW** – JS interop for Payment Element (web) |
| `lib/services/stripe_web_bridge_stub.dart` | **NEW** – Stub for non-web platforms |
| `lib/widgets/stripe_payment_element_host.dart` | **NEW** – Conditional export |
| `lib/widgets/stripe_payment_element_host_web.dart` | **NEW** – IFrame host for Stripe Payment Element |
| `lib/widgets/stripe_payment_element_host_stub.dart` | **NEW** – Stub for non-web |
| `lib/ui/payments/stripe_embedded_payment_dialog.dart` | **NEW** – Main dialog export |
| `lib/ui/payments/stripe_embedded_payment_dialog_web.dart` | **NEW** – Web implementation (postMessage) |
| `lib/ui/payments/stripe_embedded_payment_dialog_stub.dart` | **NEW** – Stub for non-web |
| `lib/ui/payments/tenant_billing_panel.dart` | **NEW** – Add Card, AutoPay toggle, One-Time, History |
| `lib/screens/client_detail_screen.dart` | **MODIFIED** – Adds TenantBillingPanel |

### Web

| File | Purpose |
|------|---------|
| `web/stripe_embedded.html` | **NEW** – Payment Element iframe (receives config via postMessage) |

### Config

| File | Purpose |
|------|---------|
| `firestore.rules` | **MODIFIED** – Rules for `tenants/{id}/billing` and `tenants/{id}/payments` (server-only writes) |

---

## Deploy Steps

### 1. Set secrets (if not already set)

```powershell
firebase functions:secrets:set STRIPE_SECRET_KEY
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET
firebase functions:config:set stripe.publishable_key="pk_test_..."
```

Or use existing values. `STRIPE_PUBLISHABLE_KEY` must be set (via Firebase config or env).

### 2. Deploy functions

```powershell
cd functions
npm run build
firebase deploy --only functions:getOrCreateStripeCustomer,functions:createEmbeddedSetupIntent,functions:createOneTimePaymentIntent,functions:toggleAutopay,functions:listSavedPaymentMethods,functions:detachPaymentMethod
```

Or deploy all:

```powershell
firebase deploy --only functions
```

### 3. Configure webhook

In Stripe Dashboard → Developers → Webhooks:

1. Add endpoint: `https://YOUR_REGION-YOUR_PROJECT.cloudfunctions.net/stripeWebhook`
2. Select events: `setup_intent.succeeded`, `payment_intent.succeeded`, `payment_intent.payment_failed`, `invoice.payment_succeeded`, `invoice.payment_failed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`
3. Copy the webhook signing secret and set `STRIPE_WEBHOOK_SECRET` if not already set

### 4. Deploy Firestore rules and hosting

```powershell
firebase deploy --only firestore:rules
flutter build web
firebase deploy --only hosting
```

---

## Data Model

### `facilities/{facilityId}/tenants/{tenantId}/billing/default`

- `stripeCustomerId`
- `defaultPaymentMethodId`
- `autopayEnabled`
- `stripeSubscriptionId`
- `lastPaymentStatus`, `lastPaymentAt`, `lastFailureCode`, `lastFailureMessage`
- `nextDueAt`, `updatedAt`

### `facilities/{facilityId}/tenants/{tenantId}/payments/{paymentId}`

- `type`: `"one_time"` | `"invoice"`
- `amountCents`, `currency`, `stripeObjectId`, `status`
- `createdAt`, `updatedAt`, `failureCode`, `failureMessage`

---

## How It Works

1. **Add/Update Card** – User taps “Add card” → `createEmbeddedSetupIntent` → clientSecret → iframe loads Stripe Payment Element → user enters card → `confirmSetup` → webhook `setup_intent.succeeded` updates billing doc with `defaultPaymentMethodId`.

2. **AutoPay Toggle** – Reads `billing.autopayEnabled` from Firestore. Toggle calls `toggleAutopay`. If enabling, creates a Stripe Subscription for tenant’s `monthlyRate`. If disabling, cancels at period end.

3. **One-Time Payment** – User enters amount → `createOneTimePaymentIntent` → creates payment doc (status=processing) → clientSecret → Payment Element → `confirmPayment` → webhook updates payment doc and billing.

4. **Payment History** – Streams `tenants/{id}/payments` subcollection.

5. **Webhook source of truth** – UI never assumes success until webhook updates Firestore. Declined payments show `lastFailureMessage` in the panel.

---

## Rollback

To disable Stripe embedded payments:

1. Remove or hide the `TenantBillingPanel` from `client_detail_screen.dart`.
2. Optionally: do not deploy the new functions, or remove their exports from `index.ts`.

Existing flows (tenant onboarding, facility admin, messaging, auth, other Cloud Functions) are unchanged.

---

## Test Cards (Stripe test mode)

- Success: `4242 4242 4242 4242`
- Decline: `4000 0000 0000 0002`
- 3DS: `4000 0025 0000 3155`
