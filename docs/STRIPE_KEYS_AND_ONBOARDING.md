# Stripe Keys – Your 6 Questions Answered + Onboarding Checklist

---

## 1. “Can you tell me if we have one in for this?” (STRIPE_SECRET_KEY)

**I can’t see your Firebase Secrets or .env.** The code **requires** `STRIPE_SECRET_KEY`: if it’s missing, functions that use Stripe throw *“STRIPE_SECRET_KEY environment variable is not set”*.

**How to check:** In Firebase Console → your project → **Build** → **Functions** → **Secrets** (or **Environment**), confirm `STRIPE_SECRET_KEY` is set. Or try **Add payment method** in the app: if you get a 401 from Stripe, the secret and publishable key don’t match (see [STRIPE_401_FIX.md](STRIPE_401_FIX.md)).

---

## 2. “Can you see what this one says?” (STRIPE_WEBHOOK_SECRET)

**I can’t see the value** of your webhook secret. The code uses it here:

- **What it does:** Verifies that incoming webhook requests really come from Stripe:  
  `stripe.webhooks.constructEvent(payload, sig, webhookSecret)`  
  So it must be the **Signing secret** from Stripe Dashboard for your webhook endpoint.

**What “this one” is:**  
- **STRIPE_WEBHOOK_SECRET** = the **Signing secret** (starts with `whsec_...`) from Stripe Dashboard → **Developers** → **Webhooks** → your endpoint → **Signing secret**.  
- You get that secret **after** you add the webhook endpoint in Stripe (see “Webhook URL” below).

---

## 3. “What the code is or if we have one in for this one?” (Webhook endpoint)

**We do have a webhook handler in code.** It’s the Cloud Function **`stripeWebhook`** (HTTPS request handler). Stripe calls this URL when events happen (e.g. subscription created, payment succeeded).

**Webhook URL (the “code” / endpoint):**

- After you deploy functions, the URL is:  
  **`https://<region>-<project-id>.cloudfunctions.net/stripeWebhook`**  
  Example: `https://us-central1-storage-facility-creator.cloudfunctions.net/stripeWebhook`  
  (Use your actual Firebase project ID and region.)

**Do you have one “in” for this?**

1. In **Stripe Dashboard** → **Developers** → **Webhooks** → **Add endpoint**.
2. **Endpoint URL:** paste the `stripeWebhook` URL above.
3. **Events to send:** at least `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted` (and any others your app uses).
4. After saving, Stripe shows the **Signing secret** (`whsec_...`) → set that as **STRIPE_WEBHOOK_SECRET** in Firebase Secrets.

So: **code** = the `stripeWebhook` function and its URL; **“one in”** = you add that URL in Stripe and set the signing secret in Firebase.

---

## 4. “We use Stripe Connect for onboarding new facilities. Will each new facility need this?” (STRIPE_CONNECT_CLIENT_ID)

**No.** Each facility does **not** get its own Stripe key.

- **You (the platform)** have **one** set of Stripe keys (secret, publishable, webhook secret).
- **STRIPE_CONNECT_CLIENT_ID** is **one** value for your whole Stripe Connect app (Dashboard → Connect → Client ID). The code currently uses it only for logging / “future use”; **Connect accounts are created with the API** (`stripe.accounts.create`), not by each facility entering a key.
- **Each new facility** gets a **Stripe Connect account** (connected account) created by the backend when they onboard; the facility document gets a `stripeConnectAccountId`. No per-facility Stripe keys are required.

So: **one** STRIPE_CONNECT_CLIENT_ID for the app; each facility gets a connected account ID stored in Firestore, not a key.

---

## 5. “I only have SFC app subscriptions – facility owners pay $75/month”

That’s the **base subscription** the code is built for.

- **STRIPE_BASE_PRICE_ID** = the Stripe Price ID for **“first facility, $75/month.”**
- You **don’t have to set** `STRIPE_BASE_PRICE_ID` if you’re okay with the code creating/finding the price: it looks up a price with `lookup_key: 'sfc_base_monthly_75'` or creates a **$75/month** recurring price (“SFC Base Plan - First Facility”).
- If you prefer to use a price you created in the Stripe Dashboard, create a $75/month product/price, copy the **Price ID** (e.g. `price_...`), and set **STRIPE_BASE_PRICE_ID** in Firebase config.

So for “facility owners pay $75 a month,” that’s the **base** price. You only need to set **STRIPE_BASE_PRICE_ID** if you want to use a specific price you created; otherwise the code can create/use the $75 base for you.

---

## 6. “Not sure if I use this or number 5 or what the difference is.” (STRIPE_BASE vs STRIPE_ADDON)

- **STRIPE_BASE_PRICE_ID (number 5)**  
  - **First facility** – $75/month.  
  - One base subscription item per customer.

- **STRIPE_ADDON_PRICE_ID (this one)**  
  - **Each additional facility** after the first – also $75/month per facility.  
  - Used when a customer has 2+ facilities: 1 base + (N−1) add-ons.

**If every customer only ever has one facility:** you only “use” the **base** ($75/month). The add-on is for **multi-facility** customers; you can ignore **STRIPE_ADDON_PRICE_ID** until you need that.

**Difference in short:**  
- **Base** = first facility, $75/month.  
- **Add-on** = each extra facility, $75/month.  
- You only need add-on if you sell multiple facilities per account.

---

## Start-to-finish: what you need to do to onboard someone

High-level: **you** configure Stripe and Firebase once; **each new facility owner** goes through app signup → (optional) trial → subscription → create facility → Stripe Connect onboarding. You don’t give them Stripe keys.

### One-time setup (you)

1. **Stripe account**  
   - Create/live Stripe account.  
   - Get **Publishable key** and **Secret key** (same mode: both test or both live).

2. **Firebase – Stripe keys**  
   - **Secrets:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`.  
   - **Config:** `STRIPE_PUBLISHABLE_KEY`.  
   - (Optional) `STRIPE_CONNECT_CLIENT_ID`; (optional) `STRIPE_BASE_PRICE_ID` / `STRIPE_ADDON_PRICE_ID` if you want to pin specific prices.)

3. **Stripe webhook**  
   - **Developers** → **Webhooks** → **Add endpoint**.  
   - URL: `https://<region>-<project-id>.cloudfunctions.net/stripeWebhook`.  
   - Subscribe events (e.g. `checkout.session.completed`, `customer.subscription.*`).  
   - Copy **Signing secret** → set as **STRIPE_WEBHOOK_SECRET** in Firebase.

4. **Deploy**  
   - Deploy Cloud Functions (so `stripeWebhook`, `createEmbeddedSetupIntent`, subscription/checkout functions exist).  
   - Deploy app (hosting) so users can sign up and pay.

### Per new facility owner (them)

1. **Sign up** – Create account (email/password or your auth method).
2. **Subscription** – Start subscription ($75/month):
   - Either **upgrade from trial** (if you use trials), or  
   - **Subscribe** from the app (checkout uses your base price / `STRIPE_BASE_PRICE_ID` or auto-created $75 price).
3. **Create facility** – In the app: create their first facility (name, address, etc.).
4. **Stripe Connect onboarding** – So the facility can receive tenant payments:
   - In the app, open **Stripe Connect** / Connect onboarding for that facility.  
   - Backend creates a Connect account for the facility and returns an account link.  
   - Owner completes Stripe’s onboarding (bank details, identity if required).  
   - When done, `stripeConnectOnboardingComplete` is set; that facility can then accept payments (e.g. tenant “Add payment method” and payments go to the facility’s Connect account).

### Summary

- **You:** Set 3 Stripe keys (secret, publishable, webhook secret), add webhook URL in Stripe, deploy. Optionally set base/addon price IDs and Connect client ID.  
- **Them:** Sign up → pay $75/month (base) → create facility → complete Stripe Connect onboarding for that facility.  
- **No** per-facility Stripe keys; each facility gets one Connect account created and stored by the app.

For the “do we have one in” / “what this one says” / “what the code is” parts: the code is in place (webhook, Connect, subscription); **you** add the webhook URL in Stripe and set the three keys (and optionally the price IDs and Connect client ID) in Firebase. I can’t see your live config, so use the checks above to confirm they’re set and matching.
