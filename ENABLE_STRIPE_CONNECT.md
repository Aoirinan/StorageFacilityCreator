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

A Cloud Function `enableStripeConnectAdmin` has been deployed. You can call it from your authenticated app:

```dart
// In your Flutter app
final callable = FirebaseFunctions.instance.httpsCallable('enableStripeConnectAdmin');
final result = await callable.call();
print(result.data);
```

**Note:** This function requires super admin authentication (your email must be in the super admin list).

## After Enabling

Once `connectEnabledGlobal` is set to `true`, the Stripe Connect functionality will be available and the 400 Bad Request error will be resolved.
