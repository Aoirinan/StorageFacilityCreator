# ✅ Deployment Complete!

**Date:** 2024-12-XX  
**Status:** Cloud Functions deployed successfully  
**Action Required:** Create Firestore config document

---

## ✅ What Was Deployed

### New Cloud Functions Created:
- ✅ `createStripeConnectLoginLink` - Connect dashboard login link
- ✅ `createTenantSetupIntent` - Tenant SetupIntent on connected account
- ✅ `attachTenantPaymentMethod` - Attach PM to connected account
- ✅ `chargeTenantOffSession` - Off-session charges on connected account
- ✅ `createStoreCheckout` - Store checkout on connected account

### Updated Functions:
- ✅ `stripeWebhook` - Enhanced with refund/dispute handlers
- ✅ `createStripeConnectAccount` - Now feature-flagged
- ✅ `getStripeConnectAccountStatus` - Now persists status to Firestore
- ✅ All other existing functions - Updated with feature flag checks

---

## ⚠️ REQUIRED: Create Firestore Config Document

**You MUST create this document before features will work:**

### Option 1: Firebase Console (Easiest)

1. Go to: https://console.firebase.google.com/project/storage-facility-creator/firestore
2. Click "Start collection" (if no collections exist) or navigate to `appConfig` collection
3. Create document with ID: `stripe`
4. Add these fields:

```json
{
  "connectEnabledGlobal": false,
  "tenantAutopayEnabledGlobal": false,
  "storeEnabledGlobal": false,
  "checkoutEnabledGlobal": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

### Option 2: Firebase CLI (Alternative)

```bash
# Create a temporary JSON file
echo {"connectEnabledGlobal":false,"tenantAutopayEnabledGlobal":false,"storeEnabledGlobal":false,"checkoutEnabledGlobal":false,"allowlistFacilityIds":[],"killSwitch":false} > stripe_config.json

# Import using Firestore import (if you have export/import set up)
# Or use a Node.js script with Firebase Admin SDK
```

### Option 3: Quick Node.js Script

Create `create_config.js`:
```javascript
const admin = require('firebase-admin');
admin.initializeApp();
const db = admin.firestore();

db.collection('appConfig').doc('stripe').set({
  connectEnabledGlobal: false,
  tenantAutopayEnabledGlobal: false,
  storeEnabledGlobal: false,
  checkoutEnabledGlobal: false,
  allowlistFacilityIds: [],
  killSwitch: false,
}).then(() => {
  console.log('✅ Config created!');
  process.exit(0);
});
```

Run: `node create_config.js` (from functions directory with Firebase Admin SDK)

---

## ✅ Verification Steps

### 1. Verify Functions Deployed

Check Firebase Console:
- https://console.firebase.google.com/project/storage-facility-creator/functions

You should see:
- ✅ `createStripeConnectLoginLink` (NEW)
- ✅ `createTenantSetupIntent` (NEW)
- ✅ `attachTenantPaymentMethod` (NEW)
- ✅ `chargeTenantOffSession` (NEW)
- ✅ `createStoreCheckout` (NEW)

### 2. Verify Config Document Exists

Check Firestore:
- https://console.firebase.google.com/project/storage-facility-creator/firestore/data/~2FappConfig~2Fstripe

Should contain all 6 fields with default values (all `false`).

### 3. Test Existing Flows (Critical)

**MUST VERIFY THESE STILL WORK:**
- ✅ Facility subscription checkout
- ✅ Subscription webhook processing
- ✅ Existing tenant payments (if any)

### 4. Verify Webhook Endpoint

Check Stripe Dashboard:
- Webhook URL: `https://us-central1-storage-facility-creator.cloudfunctions.net/stripeWebhook`
- Subscribe to NEW events: `charge.refunded`, `charge.dispute.created`

---

## 🚀 Current Status

**All Features:** ✅ **DEPLOYED** (but disabled by default)

**Default State:**
- All global flags: `false`
- Allowlist: `[]` (empty)
- Kill switch: `false`

**Result:** All new features are **OFF** - production behavior preserved exactly.

---

## 📋 Next Steps (When Ready)

### To Enable for One Facility:

1. Go to Firestore: `appConfig/stripe`
2. Add facility ID to `allowlistFacilityIds` array:
   ```json
   {
     "allowlistFacilityIds": ["your-facility-id-here"]
   }
   ```

### To Enable Globally:

1. Go to Firestore: `appConfig/stripe`
2. Set desired global flag to `true`:
   ```json
   {
     "connectEnabledGlobal": true,
     "tenantAutopayEnabledGlobal": true,
     "storeEnabledGlobal": true
   }
   ```

### Emergency Kill Switch:

If issues occur, set:
```json
{
  "killSwitch": true
}
```

This disables ALL new payment features immediately.

---

## 📊 Monitoring

### Check Function Logs:
```bash
firebase functions:log
```

### Check for Errors:
- Firebase Console > Functions > Logs
- Look for any errors related to Stripe functions

### Monitor Webhooks:
- Stripe Dashboard > Webhooks
- Check delivery success rate

---

## ✅ Deployment Summary

- ✅ **5 new functions** deployed
- ✅ **All existing functions** updated
- ✅ **Webhook handlers** enhanced
- ✅ **Feature flags** system active
- ⚠️ **Config document** - REQUIRES MANUAL CREATION (see above)

**Status:** Ready for production use (with config document)

---

## 🆘 If Issues Occur

1. **Check function logs:** `firebase functions:log`
2. **Verify config exists:** Firestore `appConfig/stripe`
3. **Enable kill switch:** Set `killSwitch: true` in config
4. **Check Stripe Dashboard:** Verify webhook endpoint active

---

**Deployment completed successfully!** 🎉
