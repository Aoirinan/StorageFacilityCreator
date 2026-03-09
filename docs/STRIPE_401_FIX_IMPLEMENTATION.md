# Stripe 401/400 Fix – Implementation Summary

## Diagnosis (Root Causes)

- **Wrong key used for tenant Add Card:** Tenant “Add Card” and SetupIntent flows must use the **platform** Stripe keys (the $75/mo account: russell_forsyth_1992@outlook.com), not facility-specific keys. If the backend or frontend used a facility’s `pk_`/`sk_` or keys from Firestore, Stripe returns 401 (unauthorized) or 400 (e.g. wrong account).
- **Key source inconsistency:** Some code paths used `STRIPE_PUBLISHABLE_KEY.value()` directly without validating that it matched the secret key mode (test vs live). Mismatched test/live keys cause 401 when confirming SetupIntents.
- **Publishable key not from backend:** If the Flutter app used a hardcoded or env publishable key that didn’t match the backend’s secret key (or account), confirmation would fail with 401.
- **Missing `stripeAccount` for Connect:** SetupIntents are created on the **connected** account (`stripeAccount: connectAccountId`). The frontend must confirm with the **platform** publishable key and pass the same `stripeAccount` so Stripe.js operates on the correct connected account. Omitting `stripeAccount` on confirm causes 401/400.

## What Was Done (PR-Style Change Set)

### Firebase Cloud Functions (`functions/src/index.ts`)

1. **Standardized Stripe keys to Firebase Secrets**
   - All Stripe-using callables use `defineSecret('STRIPE_SECRET_KEY')` and `defineSecret('STRIPE_PUBLISHABLE_KEY')` and declare them in `secrets: STRIPE_SECRETS`.
   - `getStripePublishableKey` now uses `runWith({ secrets: STRIPE_SECRETS })` and returns the validated platform key via `getPlatformPublishableKey()` (no Firestore fallback).

2. **Mode consistency (TEST vs LIVE)**
   - `validateStripeKeyMode(secretKey, publishableKey)` ensures both platform keys are either test or live; throws if mismatch. Logs only `"Stripe mode: LIVE"` or `"Stripe mode: TEST"` (never key values).
   - `getPlatformPublishableKey()` caches the validated platform publishable key and is used everywhere the backend returns a publishable key to the client.

3. **Connect scoping**
   - Backend already creates SetupIntents/PaymentMethods on the connected account with `stripeAccount: connectAccountId`. No change needed; verified for:
     - `createTenantSetupIntent`, `createTenantSetupIntentFromPortal`
     - `attachTenantPaymentMethod`, `attachTenantPaymentMethodFromPortal`
   - All return `publishableKey` from `getPlatformPublishableKey()` and `connectedAccountId` so the frontend can use platform key + `stripeAccount`.

4. **“Do not use connected keys” guardrail**
   - `rejectClientSuppliedStripeKeys(data)` rejects any request that includes `stripeSecretKey`, `stripePublishableKey`, `secretKey`, `apiKey`, or `STRIPE_*` in the payload. Prevents client from ever sending keys; backend uses only Firebase secrets.

5. **Callables updated to use platform publishable key and guardrail**
   - `createTenantSetupIntent`: uses `getPlatformPublishableKey()`, calls `rejectClientSuppliedStripeKeys(data)`.
   - `createTenantSetupIntentFromPortal`: same.
   - `attachTenantPaymentMethod` / `attachTenantPaymentMethodFromPortal`: call `rejectClientSuppliedStripeKeys(data)`; already use `getStripeClient()` and `stripeAccount`.
   - `createEmbeddedSetupIntent`: returns `getPlatformPublishableKey()` instead of raw `STRIPE_PUBLISHABLE_KEY.value()`.
   - `getStripePublishableKey`: now `runWith({ secrets: STRIPE_SECRETS })`, returns `getPlatformPublishableKey()` only (no Firestore fallback).

### Flutter (lib)

1. **No secret keys**
   - Confirmed: no `sk_` or secret keys in repo; Add Card uses callables that return `publishableKey` and `connectedAccountId`.

2. **Platform publishable key and stripeAccount**
   - `StripeService.createTenantSetupIntent` / `createTenantSetupIntentFromPortal` use the returned `publishableKey` and `connectedAccountId`.
   - `tenant_billing_panel.dart` and `tenant_portal_screen.dart` pass `publishableKeyFromBackend` and `stripeAccount: connectedAccountId` into the Stripe dialog. No change needed.

3. **No logging of key material**
   - `stripe_elements_service.dart`: removed log that printed first 12 characters of the key; now logs only `"Initialized with platform key (mode: LIVE)"` or `"TEST"` based on prefix.

### Version

- **App version:** `lib/constants/app_version.dart` set to **2.2.3** with feature tag for this fix.

---

## Deploy Instructions

Run these in order (do **not** paste real key values into the CLI; use prompts or a secure method).

1. **Select Firebase project**
   ```bash
   firebase use <your-project-id>
   ```

2. **Set Stripe secrets (if not already set)**  
   You will be prompted to enter the value; use your **platform** Stripe keys (same account as the $75/mo subscription).
   ```bash
   firebase functions:secrets:set STRIPE_SECRET_KEY
   firebase functions:secrets:set STRIPE_PUBLISHABLE_KEY
   ```
   Use **platform** keys only (e.g. from https://dashboard.stripe.com/apikey). Both must be same mode (both test or both live).

3. **Deploy Cloud Functions**
   ```bash
   firebase deploy --only functions
   ```

4. **Deploy Flutter web (optional, if you want the version bump and log fix live)**
   ```bash
   flutter build web
   firebase deploy --only hosting
   ```
   Or your existing script (e.g. `deploy.ps1`) if it builds and deploys hosting.

---

## Files Changed

| File | Change |
|------|--------|
| `functions/src/index.ts` | Stripe keys from secrets only; `validateStripeKeyMode`; `getPlatformPublishableKey()`; `rejectClientSuppliedStripeKeys()`; all createTenantSetupIntent/attach/getStripePublishableKey/createEmbeddedSetupIntent use platform key + guardrail where applicable. |
| `lib/constants/app_version.dart` | Version 2.2.3; feature tag for Stripe 401 fix. |
| `lib/services/stripe_elements_service.dart` | Log mode (TEST/LIVE) only; no key substring in logs. |
| `docs/STRIPE_401_FIX_IMPLEMENTATION.md` | This document. |

---

## How to Verify

1. **Add Card flow (staff side)**
   - Log in as staff, open a facility, go to a tenant, open Add Card / Autopay.
   - Complete card entry and confirm. You should see success and no 401 in the browser console or Network tab.

2. **Add Card flow (tenant portal)**
   - Use tenant portal (email + access code), add card. Same: no 401, SetupIntent confirms successfully.

3. **Firebase logs**
   - In Firebase Console → Functions → Logs, trigger Add Card and confirm. You should see only:
     - `Stripe mode: LIVE` or `Stripe mode: TEST` (once per cold start).
     - No `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, or any `pk_`/`sk_` values.

4. **401 / 400**
   - If 401/400 persist, check: (1) Both secrets are set and match mode. (2) Frontend uses the `publishableKey` and `connectedAccountId` returned by the callable. (3) No facility or client-supplied keys are used anywhere.

---

## Summary

- **Backend:** All Stripe usage uses the **platform** secret key from Firebase Secrets; SetupIntents/PMs are created on the connected account via `stripeAccount`; publishable key returned to clients is always the validated platform key; client-supplied keys are rejected.
- **Frontend:** Uses only the publishable key and `connectedAccountId` returned by the backend; passes `stripeAccount` when confirming; no secret keys; logs only TEST/LIVE mode.
- **Deploy:** Set `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY` (platform, same mode), then `firebase deploy --only functions`, then build and deploy hosting if desired. Version 2.2.3 reflects this fix.
