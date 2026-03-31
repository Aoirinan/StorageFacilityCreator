# Fix: Stripe 401 Unauthorized on Add Payment Method

## How we know the keys don’t match

We don’t read your Firebase secrets. We infer from **Stripe’s behavior**: Stripe returns **401 Unauthorized** on `GET /v1/elements/sessions?client_secret=...&key=...` when the **publishable key** in the request (`key=`) and the **SetupIntent** that produced `client_secret` are not from the same Stripe account and mode. So a 401 means Stripe is treating them as mismatched (e.g. different account, or one test and one live). Fixing the 401 means making the key and secret match in Stripe’s eyes (same account, same mode).

## Stripe Connect (tenant "Add card" / facility billing)

When the app uses **Stripe Connect** (facility connected accounts), the backend creates SetupIntents **on the connected account** but uses your **platform** Stripe keys. In Firebase you must set:

- **STRIPE_PUBLISHABLE_KEY** = your **platform** publishable key (`pk_live_...` or `pk_test_...` from the same Dashboard as the secret).
- **STRIPE_SECRET_KEY** = your **platform** secret key (`sk_live_...` or `sk_test_...` from that same account).

Do **not** use a connected account's publishable key. The frontend receives the platform key from the backend and passes `stripeAccount: connectedAccountId` when loading Stripe.js; the SetupIntent's `client_secret` is for the connected account. Stripe accepts this only when the **key** is the platform key. If you accidentally set `STRIPE_PUBLISHABLE_KEY` to a connected account's key, you will get 401.

---

When you see:

```
GET https://api.stripe.com/v1/elements/sessions?client_secret=seti_...&key=pk_live_... 401 (Unauthorized)
```

Stripe is rejecting the request because the **publishable key** (`key=`) and the **SetupIntent** (`client_secret=`) do not belong to the same Stripe account and mode.

## Rule

- **Publishable key** and **secret key** must be from the **same Stripe account** (same Dashboard).
- **Mode must match**: both **test** OR both **live**.
  - If the app uses `pk_live_...`, the backend must use `sk_live_...` from that same account.
  - If the app uses `pk_test_...`, the backend must use `sk_test_...` from that same account.

## What to set in Firebase

1. **Firebase Console** → your project → **Functions** (or **Build** → **Environment** / **Secrets**).
2. Set **both** of these from the **same** Stripe account and **same** mode (test or live):

   - **STRIPE_PUBLISHABLE_KEY**  
     From Stripe Dashboard → **Developers** → **API keys** → **Publishable key** (use **Live** or **Test** consistently).
   - **STRIPE_SECRET_KEY** (as a **secret**)  
     From the same page → **Secret key** (use **Live** if you use the live publishable key, **Test** if you use the test publishable key).

3. **Redeploy** the Cloud Function so it picks up the new secret:

   ```bash
   firebase deploy --only functions:createEmbeddedSetupIntent
   ```

## Check your current keys

- If the failing request shows `key=pk_live_...`, you are using a **live** publishable key for some Stripe account (the prefix after `pk_live_` identifies which account).
- In Firebase, **STRIPE_SECRET_KEY** must be the **live** secret key (`sk_live_...`) for that **same** Stripe account and mode.
- If **STRIPE_SECRET_KEY** is `sk_test_...` while the client uses `pk_live_...`, Stripe returns **401**. Fix: use **live** secret + **live** publishable from the same Dashboard account, or switch both to test.

## After changing the secret

1. Redeploy the functions that return the publishable key:
   - For **tenant Add card** (facility billing panel):  
     `firebase deploy --only functions:createTenantSetupIntent,functions:attachTenantPaymentMethod`
   - Or deploy all:  
     `firebase deploy --only functions`
2. Hard refresh the app (Ctrl+Shift+R) and try **Add card** again.

The Google Pay manifest messages in the console are unrelated and can be ignored for card-only flows.
