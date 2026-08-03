# Enable Stripe Connect Feature Flag

## Quick Method: Firebase Console (Recommended)

1. Go to: https://console.firebase.google.com/project/storage-facility-creator/firestore/data
2. Navigate to the `appConfig` collection
3. Find or create a document with ID: `stripe`
4. Set the field `connectEnabledGlobal` to `true` (boolean)

If the document doesn't exist, create it with these fields:
- `connectEnabledGlobal`: `true` (boolean)
- `tenantAutopayEnabledGlobal`: `false` (boolean)
- `storeEnabledGlobal`: `false` (boolean)
- `checkoutEnabledGlobal`: `false` (boolean)
- `allowlistFacilityIds`: `[]` (array)
- `killSwitch`: `false` (boolean)

## Alternative: Use Deployed Cloud Function

A Cloud Function `enableStripeConnectAdmin` exists for one-time setup. It is **disabled by default** until you set a runtime environment variable on that function:

1. In Google Cloud Console (or Firebase Console → Functions → your function → **Environment variables**), set:
   - `ENABLE_STRIPE_CONNECT_ADMIN_CALLABLE` = `true`
2. Call it while signed in as a super admin:

```dart
// In your Flutter app
final callable = FirebaseFunctions.instance.httpsCallable('enableStripeConnectAdmin');
final result = await callable.call();
print(result.data);
```

**Note:** Requires super-admin email (same list as `SuperAdminService`) **and** `ENABLE_STRIPE_CONNECT_ADMIN_CALLABLE=true`. Remove or unset the env var after use.

## After Enabling

Once `connectEnabledGlobal` is set to `true`, the Stripe Connect functionality will be available and the 400 Bad Request error will be resolved.
