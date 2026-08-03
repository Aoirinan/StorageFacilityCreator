# 2FA Email OTP Implementation Guide
**Date:** January 24, 2026  
**Status:** ✅ Complete - Ready for Deployment

---

## Overview

Two-factor authentication (2FA) via email OTP has been fully implemented. This guide walks you through:
1. What was implemented
2. How to deploy it
3. How to use it in your app
4. Testing steps

---

## What Was Implemented

### ✅ Backend (Cloud Functions)

1. **`generateOTP` Function**
   - Generates a 6-digit OTP code
   - Stores it in Firestore with 10-minute expiration
   - Sends it via SendGrid email
   - Rate limiting: Max 1 OTP per minute per user
   - Updates user's `lastOTPSentAt` timestamp

2. **`verifyOTP` Function**
   - Verifies the OTP code against stored value
   - Checks expiration
   - Marks code as used after verification
   - Automatically cleans up old OTP codes (older than 1 hour)

### ✅ Frontend (Dart Service)

**`lib/services/two_factor_service.dart`** - Complete 2FA service with:
- `requestOTP()` - Request an OTP code
- `verifyOTP()` - Verify an OTP code
- `is2FAEnabled()` - Check if 2FA is enabled for user
- `enable2FA()` - Enable 2FA for user
- `disable2FA()` - Disable 2FA and clean up codes

### ✅ Data Model

**`lib/models/user_model.dart`** - Updated with:
- `twoFactorEnabled` (bool) - Whether 2FA is enabled
- `lastOTPSentAt` (DateTime?) - Last time OTP was sent (for rate limiting)

### ✅ Firestore Structure

OTP codes are stored in:
```
users/{userId}/otpCodes/{otpId}
```

Each OTP document contains:
- `code` (string) - The 6-digit OTP code
- `purpose` (string) - Purpose of the OTP (e.g., 'sensitive_action')
- `expiresAt` (Timestamp) - Expiration time (10 minutes from creation)
- `createdAt` (Timestamp) - Creation time
- `used` (boolean) - Whether the code has been used

---

## Step-by-Step Deployment

### Step 1: Install Dependencies

```bash
cd functions
npm install
```

No new dependencies needed - uses existing SendGrid integration.

### Step 2: Build TypeScript

```bash
npm run build
```

This compiles the TypeScript code to JavaScript.

### Step 3: Deploy Cloud Functions

Deploy the two new functions:

```bash
firebase deploy --only functions:generateOTP,functions:verifyOTP
```

Or deploy all functions:

```bash
firebase deploy --only functions
```

### Step 4: Verify Deployment

Check that the functions are deployed:

```bash
firebase functions:list
```

You should see:
- `generateOTP` (callable)
- `verifyOTP` (callable)

---

## How to Use in Your App

### Example 1: Request OTP Code

```dart
import 'package:your_app/services/two_factor_service.dart';

// Request an OTP code
final result = await TwoFactorService.requestOTP(
  purpose: 'sensitive_action', // Optional
);

if (result.success) {
  print('OTP sent! Expires in ${result.expiresIn} seconds');
  // Show UI: "Check your email for a 6-digit code"
} else {
  print('Error: ${result.error}');
  // Show error to user
}
```

### Example 2: Verify OTP Code

```dart
// User enters the code from their email
final code = '123456'; // From user input

final result = await TwoFactorService.verifyOTP(
  code: code,
  purpose: 'sensitive_action', // Must match the purpose used in requestOTP
);

if (result.success) {
  print('OTP verified! Proceed with sensitive action');
  // Allow user to proceed
} else {
  print('Error: ${result.error}');
  // Show error: "Invalid code" or "Code expired"
}
```

### Example 3: Check if 2FA is Enabled

```dart
final isEnabled = await TwoFactorService.is2FAEnabled();
if (isEnabled) {
  // Require OTP before sensitive actions
}
```

### Example 4: Enable/Disable 2FA

```dart
// Enable 2FA for current user
final enabled = await TwoFactorService.enable2FA();

// Disable 2FA for current user
final disabled = await TwoFactorService.disable2FA();
```

### Example 5: Complete Flow (Sensitive Action)

```dart
// 1. Check if 2FA is required
final is2FAEnabled = await TwoFactorService.is2FAEnabled();

if (is2FAEnabled) {
  // 2. Request OTP
  final requestResult = await TwoFactorService.requestOTP(
    purpose: 'delete_facility',
  );
  
  if (!requestResult.success) {
    // Handle error (rate limit, etc.)
    return;
  }
  
  // 3. Show UI for user to enter code
  // (You'll need to create a dialog/input field)
  final userEnteredCode = await showOTPInputDialog();
  
  // 4. Verify OTP
  final verifyResult = await TwoFactorService.verifyOTP(
    code: userEnteredCode,
    purpose: 'delete_facility',
  );
  
  if (!verifyResult.success) {
    // Handle error (invalid code, expired, etc.)
    return;
  }
  
  // 5. Proceed with sensitive action
  await deleteFacility();
}
```

---

## Testing Checklist

### ✅ Basic Functionality

- [ ] **Request OTP**
  - Call `TwoFactorService.requestOTP()`
  - Check email for 6-digit code
  - Verify code is received within 30 seconds

- [ ] **Verify Valid OTP**
  - Request OTP
  - Use the code from email
  - Call `TwoFactorService.verifyOTP(code: '123456')`
  - Should return success

- [ ] **Verify Invalid OTP**
  - Request OTP
  - Use wrong code (e.g., '000000')
  - Should return error: "Invalid OTP code"

- [ ] **Verify Expired OTP**
  - Request OTP
  - Wait 11 minutes (past 10-minute expiration)
  - Try to verify
  - Should return error: "OTP code has expired"

### ✅ Rate Limiting

- [ ] **Rate Limit Test**
  - Request OTP
  - Immediately request another OTP (< 1 minute)
  - Should return error: "Please wait X seconds before requesting another OTP code"
  - Wait 60+ seconds
  - Request again - should succeed

### ✅ Edge Cases

- [ ] **Verify Used OTP**
  - Request OTP
  - Verify it successfully
  - Try to verify the same code again
  - Should return error: "No valid OTP code found"

- [ ] **Multiple OTPs**
  - Request OTP (purpose: 'action1')
  - Request another OTP (purpose: 'action2')
  - Verify first OTP with correct purpose
  - Should work independently

- [ ] **Cleanup Test**
  - Request multiple OTPs
  - Wait 1+ hour
  - Check Firestore - old OTPs should be cleaned up automatically

### ✅ User Management

- [ ] **Enable 2FA**
  - Call `TwoFactorService.enable2FA()`
  - Check Firestore: `users/{userId}/twoFactorEnabled` should be `true`

- [ ] **Disable 2FA**
  - Call `TwoFactorService.disable2FA()`
  - Check Firestore: `users/{userId}/twoFactorEnabled` should be `false`
  - Check Firestore: All OTP codes for user should be deleted

---

## Email Template

The OTP email sent via SendGrid includes:
- **Subject:** "Your Verification Code"
- **HTML:** Formatted email with large, easy-to-read code
- **Text:** Plain text version
- **Expiration:** "This code will expire in 10 minutes"

You can customize the email template in `functions/src/index.ts` in the `generateOTP` function (look for the `emailHtml` and `emailText` variables).

---

## Security Features

✅ **Rate Limiting:** Max 1 OTP per minute per user  
✅ **Expiration:** OTPs expire after 10 minutes  
✅ **One-Time Use:** OTPs are marked as used after verification  
✅ **Automatic Cleanup:** Old OTPs (>1 hour) are automatically deleted  
✅ **Purpose-Based:** OTPs can be scoped to specific purposes  
✅ **App Check:** Functions require App Check verification  

---

## Error Handling

The service handles these error cases:

| Error Code | Description | User Message |
|------------|-------------|--------------|
| `unauthenticated` | User not logged in | "You must be logged in to use 2FA" |
| `invalid-argument` | Invalid code format | "OTP code must be a 6-digit number" |
| `not-found` | No valid OTP found | "No valid OTP code found. Please request a new code." |
| `deadline-exceeded` | OTP expired | "OTP code has expired. Please request a new code." |
| `permission-denied` | Invalid code | "Invalid OTP code. Please try again." |
| `resource-exhausted` | Rate limit exceeded | "Please wait X seconds before requesting another OTP code." |

---

## Integration with Existing Features

### Where to Use 2FA

Consider requiring 2FA for:
- ✅ Deleting facilities
- ✅ Changing facility ownership
- ✅ Bulk operations (bulk delete tenants, etc.)
- ✅ Financial operations (refunds, voiding payments)
- ✅ Changing user roles/permissions
- ✅ Exporting sensitive data

### Example: Protect Delete Facility

```dart
Future<void> deleteFacility(String facilityId) async {
  // Check if 2FA is enabled
  final is2FAEnabled = await TwoFactorService.is2FAEnabled();
  
  if (is2FAEnabled) {
    // Request OTP
    final otpResult = await TwoFactorService.requestOTP(
      purpose: 'delete_facility',
    );
    
    if (!otpResult.success) {
      throw Exception(otpResult.error);
    }
    
    // Show dialog for user to enter code
    final code = await showDialog<String>(
      context: context,
      builder: (context) => OTPInputDialog(),
    );
    
    if (code == null) return;
    
    // Verify OTP
    final verifyResult = await TwoFactorService.verifyOTP(
      code: code,
      purpose: 'delete_facility',
    );
    
    if (!verifyResult.success) {
      throw Exception(verifyResult.error);
    }
  }
  
  // Proceed with deletion
  await facilityService.deleteFacility(facilityId);
}
```

---

## Troubleshooting

### OTP Not Received

1. **Check SendGrid Configuration**
   - Verify `SENDGRID_API_KEY` is set in Firebase Secrets
   - Verify `SENDGRID_SENDER_EMAIL` is configured
   - Check SendGrid dashboard for email delivery status

2. **Check Spam Folder**
   - OTP emails might go to spam
   - Check email subject: "Your Verification Code"

3. **Check Rate Limiting**
   - If you requested multiple OTPs, you might be rate-limited
   - Wait 60 seconds between requests

### Functions Not Deploying

1. **Check TypeScript Errors**
   ```bash
   cd functions
   npm run build
   ```
   Fix any TypeScript errors before deploying

2. **Check Firebase CLI**
   ```bash
   firebase login
   firebase use <your-project>
   ```

### App Check Errors

If you see App Check errors:
- Ensure App Check is enabled in your Flutter app
- Check `lib/services/app_check_service.dart` is properly configured

---

## Next Steps

1. ✅ **Deploy Functions** - Follow Step 3 above
2. ✅ **Test Basic Flow** - Use the testing checklist
3. ✅ **Integrate into UI** - Add 2FA prompts for sensitive actions
4. ✅ **Enable for Users** - Allow users to enable 2FA in settings
5. ✅ **Monitor Usage** - Check Firestore for OTP generation/verification

---

## Files Modified

- ✅ `functions/src/index.ts` - Added `generateOTP()` and `verifyOTP()` functions
- ✅ `lib/services/two_factor_service.dart` - NEW - Complete 2FA service
- ✅ `lib/models/user_model.dart` - Added `twoFactorEnabled` and `lastOTPSentAt` fields

---

## Support

If you encounter issues:
1. Check Firebase Functions logs: `firebase functions:log`
2. Check Firestore for OTP documents
3. Verify SendGrid email delivery in SendGrid dashboard
4. Review error messages in `TwoFactorResult.error`

---

**Status:** ✅ Ready for deployment and testing!
