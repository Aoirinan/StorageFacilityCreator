# Stripe Keys the App Needs

All of these are configured in **Firebase** (Cloud Functions). The Flutter app never sees secret keys; it gets the publishable key from the `getStripePublishableKey` (and optionally `createEmbeddedSetupIntent`) Cloud Functions.

---

## Required for core payments (Add card, Pay now, subscriptions)

| Key | Where to set | Type | Description |
|-----|----------------|------|-------------|
| **STRIPE_SECRET_KEY** | Firebase **Secrets** | Secret | Your Stripe **Secret key** (`sk_live_...` or `sk_test_...`). Used by Cloud Functions to create SetupIntents, PaymentIntents, customers, etc. |
| **STRIPE_PUBLISHABLE_KEY** | Firebase **Config** (env/params) | Non-secret | Your Stripe **Publishable key** (`pk_live_...` or `pk_test_...`). Returned to the app so the browser can load Stripe.js and the Payment Element. |
| **STRIPE_WEBHOOK_SECRET** | Firebase **Secrets** | Secret | Webhook signing secret (`whsec_...`) from Stripe Dashboard → Developers → Webhooks, for the endpoint that receives Stripe events. |

**Rule:** `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY` must be from the **same Stripe account** and **same mode** (both live or both test). If they don’t match, Stripe returns 401 and the Add payment method form won’t load.

---

## Optional (feature-specific)

| Key | Where to set | Used for |
|-----|----------------|----------|
| **STRIPE_CONNECT_CLIENT_ID** | Firebase **Config** (e.g. `.env`) | Stripe Connect (facility onboarding, connected accounts). Only needed if you use Connect. |
| **STRIPE_BASE_PRICE_ID** | Firebase **Config** (e.g. `.env`) | SFC app subscription (base plan). If unset, the code can create a default price. |
| **STRIPE_ADDON_PRICE_ID** | Firebase **Config** (e.g. `.env`) | SFC app subscription add-on. If unset, the code can create a default price. |

---

## Where to set them in Firebase

1. **Secrets** (Firebase CLI or Console):
   - `STRIPE_SECRET_KEY`
   - `STRIPE_WEBHOOK_SECRET`  
   Example: `firebase functions:secrets:set STRIPE_SECRET_KEY` then paste the value.

2. **Config / environment** (Firebase Console → Project settings → Environment, or `functions/.env` for local runs):
   - `STRIPE_PUBLISHABLE_KEY` (required for Add card / Payment Element)
   - `STRIPE_CONNECT_CLIENT_ID` (optional)
   - `STRIPE_BASE_PRICE_ID` (optional)
   - `STRIPE_ADDON_PRICE_ID` (optional)

For **Firebase Functions (v2)** with `defineString`, the publishable key is read from **Firebase config / params**, not from Secrets. So set `STRIPE_PUBLISHABLE_KEY` in your project’s environment/config (e.g. Firebase Console → Functions → Environment variables, or `.env` if you use it for deployment).

---

## Getting the values from Stripe

- **Stripe Dashboard** → [Developers → API keys](https://dashboard.stripe.com/apikeys):
  - **Publishable key** → `STRIPE_PUBLISHABLE_KEY` (use **Live** or **Test** consistently).
  - **Secret key** → `STRIPE_SECRET_KEY` (use **Live** if you use the live publishable key, **Test** if you use the test publishable key).
- **Stripe Dashboard** → Developers → Webhooks → your endpoint → “Signing secret” → `STRIPE_WEBHOOK_SECRET`.
- **Stripe Connect**: Developers → Connect → Client ID → `STRIPE_CONNECT_CLIENT_ID`.
