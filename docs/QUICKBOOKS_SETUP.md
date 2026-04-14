# QuickBooks Integration Setup

This project now includes Firebase Callable Functions for QuickBooks Online accounting sync.

## What Is Included

- OAuth connect flow for a facility QuickBooks company.
- Stored QuickBooks connection per facility at:
  - `facilities/{facilityId}/integrations/quickbooks`
- Manual sync endpoints:
  - `syncInvoiceToQuickBooks`
  - `syncPaymentToQuickBooks`
- Automatic sync triggers:
  - `autoSyncInvoiceToQuickBooks`
  - `autoSyncPaymentToQuickBooks`

## Required Firebase Config

Set these before deploy:

- Secret: `QUICKBOOKS_CLIENT_ID`
- Secret: `QUICKBOOKS_CLIENT_SECRET`
- Param: `QUICKBOOKS_REDIRECT_URI`
- Param: `QUICKBOOKS_ENV` (`sandbox` or `production`, default `sandbox`)

### If Intuit shows `undefined` as the app name or `clientId 'undefined'` in the browser console

The authorize URL was built with a missing Client ID. `URLSearchParams` turns a missing value into the literal string `undefined`, which Intuit then receives as `client_id=undefined`.

1. Set or rotate both secrets (use the real values from Intuit, not the word “undefined”):

   `npx firebase-tools@latest functions:secrets:set QUICKBOOKS_CLIENT_ID`  
   `npx firebase-tools@latest functions:secrets:set QUICKBOOKS_CLIENT_SECRET`

2. **Redeploy** every function that references those secrets (at minimum `getQuickBooksConnectUrl` and `completeQuickBooksConnect`). New secret versions are not picked up until redeploy.

3. Confirm the secret exists:  
   `npx firebase-tools@latest functions:secrets:access QUICKBOOKS_CLIENT_ID`

4. In Google Cloud Console → **Secret Manager**, ensure the Cloud Functions runtime service account has **Secret Manager Secret Accessor** on these secrets (Firebase CLI normally grants this on deploy).

### Redirect URI must match Intuit exactly

The value of `QUICKBOOKS_REDIRECT_URI` is sent as the OAuth `redirect_uri` query parameter. Intuit returns **“redirect_uri query parameter value is invalid”** if it is not **byte-for-byte identical** to one of the URIs under **Keys & credentials → Redirect URIs** for the same key set (Development vs Production) you are using.

Use the URI that your backend expects and that is guaranteed to reach your OAuth completion flow. In this project, prefer the dedicated callback function URL:

`https://us-central1-storage-facility-creator.cloudfunctions.net/quickBooksOAuthCallback`

This callback forwards users into the Flutter route `#/subscription?tab=accounting` with `code`, `realmId`, and `state` preserved.

After changing `.env.storage-<project>`, redeploy functions.

### Still seeing “redirect_uri … is invalid”?

1. **Development vs Production keys** — In [developer.intuit.com](https://developer.intuit.com) → your app → **Keys & credentials**, redirect URIs are separate for **Development** (sandbox) and **Production**. The **Client ID** in the browser error URL must be from the same tab where you added the redirect. Match **`QUICKBOOKS_ENV`**: `sandbox` → Development keys + Development redirect list; `production` → Production keys + Production redirect list.

2. **No `#` in the registered URI** — Register a normal HTTPS URL (path + query). Do **not** use `/#/subscription` as the redirect in Intuit; the backend sends a path-style URL (e.g. `/subscription?tab=accounting`). The value shown as **OAuth redirect (Intuit)** on the in-app Accounting screen is exactly what functions send.

3. **Stale Cloud config** — If `QUICKBOOKS_REDIRECT_URI` was set in **Google Cloud Console** → Cloud Functions → environment variables, it can override the value from `.env` at deploy. Check the **OAuth redirect (Intuit)** line after **Refresh Status** in the app and compare to Intuit’s list.

4. **Whitespace** — Copy/paste into Intuit or `.env` can include trailing spaces; the backend now trims `QUICKBOOKS_REDIRECT_URI` when building OAuth URLs.

## New Callable Functions

- `getQuickBooksConnectionStatus`
- `getQuickBooksConnectUrl`
- `completeQuickBooksConnect`
- `disconnectQuickBooks`
- `syncInvoiceToQuickBooks`
- `syncPaymentToQuickBooks`
- `setQuickBooksAutoSync`

## Basic Flow

1. Call `getQuickBooksConnectUrl({ facilityId })` and redirect the user to `authUrl`.
2. QuickBooks returns `code`, `realmId`, `state` to your redirect URI.
3. Call `completeQuickBooksConnect({ facilityId, code, realmId, state })`.
4. Auto-sync runs in the background for invoice and payment writes.
5. Manual sync is still available as fallback:
   - `syncInvoiceToQuickBooks({ facilityId, invoiceId })`
   - `syncPaymentToQuickBooks({ facilityId, paymentId, invoiceId? })`

## Notes

- Access is restricted to facility owner/manager users.
- Tokens are stored in Firestore integration doc. For stronger security, migrate to Secret Manager/KMS envelope encryption in a follow-up.
- The first sync creates/fetches:
  - Customer in QuickBooks (mapped to tenant)
  - Service item in QuickBooks for invoice lines
- `autoSyncEnabled` defaults to `true` on connect and can be toggled with `setQuickBooksAutoSync`.

---

## Switching from Sandbox to Production

If the app shows **Environment: sandbox**, you are using Intuit’s sandbox (test) environment. To use **production** QuickBooks (real books):

### 1. Create / use a Production app in Intuit Developer

- Go to [developer.intuit.com](https://developer.intuit.com) → your app.
- Sandbox and **Production** use different credentials. In the app dashboard, switch to **Production** and note:
  - **Client ID** (production)
  - **Client Secret** (production)
- Add your **production** redirect URI (e.g. `https://storagefacilitycreator.com/#/subscription` or your app’s OAuth callback) in the production app settings.

### 2. Set Firebase Functions config to production

- **QUICKBOOKS_ENV** – must be `production` (default is `sandbox`).
- **QUICKBOOKS_CLIENT_ID** / **QUICKBOOKS_CLIENT_SECRET** – must be the **production** app’s credentials (from step 1).
- **QUICKBOOKS_REDIRECT_URI** – must match the redirect URI configured in the **production** app.

Set the env param and redeploy. For example, if you use a `.env` file in `functions/`:

```bash
# functions/.env (or set in Google Cloud Console → Functions → your project → Environment variables)
QUICKBOOKS_ENV=production
```

Then set the secrets to your **production** app values:

```bash
firebase functions:secrets:set QUICKBOOKS_CLIENT_ID
firebase functions:secrets:set QUICKBOOKS_CLIENT_SECRET
```

Set the redirect URI (Firebase params / env):

```bash
# e.g. in .env or Cloud Console
QUICKBOOKS_REDIRECT_URI=https://storagefacilitycreator.com/#/subscription
```

Redeploy functions:

```bash
cd functions && npm run build && cd .. && firebase deploy --only functions
```

### 3. Disconnect and reconnect in the app

- Sandbox tokens and realm IDs **do not** work in production.
- In the app: **Accounting** tab → **Disconnect**.
- Then **Connect QuickBooks** again. The OAuth flow will use production (if step 2 is correct), and the UI will show **Environment: production** after you reconnect.
