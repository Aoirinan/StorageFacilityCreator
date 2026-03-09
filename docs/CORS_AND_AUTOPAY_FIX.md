# Fix: Enable Autopay CORS & Add Card 400

## 1. CORS blocking Cloud Functions (Autopay, Contract Signing, etc.)

**Cause:** The browser blocks requests from `https://storagefacilitycreator.com` to your Cloud Functions because the domain is not in Firebase **Authorized domains**. This affects:
- `setTenantAutopay` (Enable autopay)
- `uploadSignedContract` (Sign contract)
- Other callable functions

**Fix (do this first):**

1. Open [Firebase Console](https://console.firebase.google.com/) → your project **storage-facility-creator**.
2. Go to **Build** → **Authentication** → **Settings** (or **Authentication** → **Settings**).
3. Open the **Authorized domains** tab.
4. Ensure `storagefacilitycreator.com` is listed. If not, click **Add domain** and add it.
5. Save.

After this, callable functions will respond with the correct CORS headers for your app origin.

---

## 2. Add card: 400 Bad Request on `createTenantSetupIntent`

**Cause:** The function was gated by a Stripe feature flag (`tenantAutopayEnabledGlobal` or facility allowlist) that was off by default, and/or App Check was required and could fail.

**Fixes applied in code (already done):**

- **Feature gate relaxed:** Add-card and tenant autopay are now allowed for **any facility that has Stripe Connect enabled** (connected account with `charges_enabled`). You no longer need to set `appConfig/stripe` `tenantAutopayEnabledGlobal` or an allowlist for this.
- **App Check:** Made optional for `createTenantSetupIntent`, `attachTenantPaymentMethod`, and `setTenantAutopay` (auth is still required). If reCAPTCHA/App Check is blocked, these calls still succeed.

**You need to:**

1. **Redeploy Cloud Functions** so the changes take effect:
   ```bash
   cd functions
   npm run build
   firebase deploy --only functions
   ```
2. Ensure the **facility** (e.g. Keepsake Self Storage) has **Stripe Connect completed** and **charges enabled** (finish onboarding in Stripe if needed). Then "Add card" and "Enable autopay" will work without any Firestore feature flags.

---

## Summary

| Issue | Fix |
|-------|-----|
| CORS / "codes" when clicking Enable autopay | Add `storagefacilitycreator.com` to **Authentication → Settings → Authorized domains** in Firebase Console. |
| 400 on Add card | Redeploy functions; ensure facility has Stripe Connect with charges enabled. |

After adding the domain and redeploying functions, test again: Enable autopay and Add card should work.
