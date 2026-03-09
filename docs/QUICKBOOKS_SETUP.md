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
