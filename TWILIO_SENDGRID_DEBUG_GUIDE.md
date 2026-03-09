# Twilio & SendGrid Debugging Guide

## Changes Made

### 1. Enhanced Debug Logging in `sendSMS` Function
- Added comprehensive logging at every step of credential retrieval
- Logs credential retrieval success/failure for each secret (Account SID, Auth Token, Phone Number)
- Logs Twilio API request preparation and response status
- Enhanced error logging with masked credentials for 401/500 errors

### 2. Enhanced Debug Logging in `sendEmail` Function
- Added logging for SendGrid initialization
- Logs credential retrieval for SENDGRID_FROM_EMAIL and SENDGRID_FROM_NAME
- Logs SendGrid API request and response
- Enhanced error handling for 401 and 500 errors with proper error conversion

### 3. Error Handling Improvements
- Wrapped secret retrieval in try-catch blocks to identify which secret is missing
- Added specific error messages indicating which secret/environment variable is missing
- Converted SendGrid 401/500 errors to appropriate HttpsError codes

## Verification Steps

### Step 1: Check Firebase Functions Logs

After deploying, check Firebase Functions logs for debug messages:

```bash
firebase functions:log --only sendSMS,sendEmail
```

Look for log entries with `[sendSMS:H6]` and `[sendEmail:H7]` tags.

### Step 2: Verify Twilio Secrets Are Set

Check if Twilio secrets are configured:

```bash
cd functions
firebase functions:secrets:access TWILIO_ACCOUNT_SID
firebase functions:secrets:access TWILIO_AUTH_TOKEN
firebase functions:secrets:access TWILIO_PHONE_NUMBER
```

**Expected:**
- `TWILIO_ACCOUNT_SID`: Should start with `AC` and be ~34 characters (e.g., `ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)
- `TWILIO_AUTH_TOKEN`: Should be ~32 characters
- `TWILIO_PHONE_NUMBER`: Should be in E.164 format (e.g., `+12345678901`)

**If secrets are missing:**
```bash
firebase functions:secrets:set TWILIO_ACCOUNT_SID
firebase functions:secrets:set TWILIO_AUTH_TOKEN
firebase functions:secrets:set TWILIO_PHONE_NUMBER
```

**Note:** `TWILIO_ACCOUNT_SID` and `TWILIO_PHONE_NUMBER` are defined as `defineString()` (not secrets), so they should be set as environment parameters:
```bash
firebase functions:config:set twilio.account_sid="ACxxxxx"
firebase functions:config:set twilio.phone_number="+12345678901"
```

Wait, checking the code - they're defined as `defineString()` which means they should be set as environment variables or parameters. Check the Firebase Console > Functions > Configuration.

### Step 3: Verify SendGrid Secrets Are Set

Check if SendGrid secrets are configured:

```bash
cd functions
firebase functions:secrets:access SENDGRID_API_KEY
firebase functions:secrets:access SENDGRID_SENDER_EMAIL
firebase functions:secrets:access SENDGRID_FROM_NAME
```

**Expected:**
- `SENDGRID_API_KEY`: Should start with `SG.` and be ~69 characters
- `SENDGRID_SENDER_EMAIL`: Should be a valid email address (verified in SendGrid)
- `SENDGRID_FROM_NAME`: Should be a string (e.g., "Storage Facility Creator")

### Step 4: Deploy Functions

Deploy the updated functions:

```bash
cd functions
npm run build
firebase deploy --only functions:sendSMS,functions:sendEmail
```

### Step 5: Test and Monitor Logs

1. Trigger a test SMS send from your app
2. Immediately check logs:
   ```bash
   firebase functions:log --only sendSMS --limit 50
   ```

3. Look for these log entries:
   - `🔍 [sendSMS:H6] Starting credential retrieval` - Function started
   - `🔍 [sendSMS:H6] Account SID retrieved` - Credential retrieval success
   - `🔍 [sendSMS:H6] Auth Token retrieved` - Credential retrieval success
   - `🔍 [sendSMS:H6] Phone Number retrieved` - Credential retrieval success
   - `🔍 [sendSMS:H6] Preparing Twilio API request` - Request preparation
   - `🔍 [sendSMS:H6] Calling Twilio API` - API call initiated
   - `🔍 [sendSMS:H6] Twilio API response received` - Response received

4. If you see errors:
   - `❌ [sendSMS:H6] Failed to retrieve TWILIO_ACCOUNT_SID` - Secret is missing or not accessible
   - `❌ [sendSMS:H6] Twilio API Error` with status 401 - Credentials are incorrect
   - `❌ [sendSMS:H6] Twilio API Error` with status 500 - Twilio server error

## Common Issues and Solutions

### Issue 1: 401 Unauthorized from Twilio

**Possible Causes:**
1. `TWILIO_AUTH_TOKEN` is incorrect or expired
2. `TWILIO_ACCOUNT_SID` doesn't match the Auth Token
3. Secret has extra whitespace or newlines

**Solution:**
1. Check Twilio Console > Account > API Keys & Tokens
2. Verify Account SID matches
3. Generate a new Auth Token if needed
4. Re-set secrets (be careful not to include extra whitespace):
   ```bash
   echo -n "YOUR_AUTH_TOKEN" | firebase functions:secrets:set TWILIO_AUTH_TOKEN
   ```

### Issue 2: 500 Server Error from Firebase Functions

**Possible Causes:**
1. Secrets are not accessible (not deployed)
2. Function timeout (default 60s, may need to increase)
3. Memory/resource limits exceeded

**Solution:**
1. Verify secrets are deployed:
   ```bash
   firebase functions:secrets:list
   ```
2. Check function configuration for resource limits
3. Check Firebase Console > Functions > Logs for detailed error messages

### Issue 3: 401 from SendGrid

**Possible Causes:**
1. `SENDGRID_API_KEY` is incorrect or revoked
2. API key doesn't have mail.send permissions

**Solution:**
1. Check SendGrid Console > Settings > API Keys
2. Verify API key has "Mail Send" permissions
3. Generate a new API key if needed
4. Re-set secret:
   ```bash
   firebase functions:secrets:set SENDGRID_API_KEY
   ```

### Issue 4: sendEmail Returns 500

**Possible Causes:**
1. `SENDGRID_SENDER_EMAIL` not verified in SendGrid
2. Sender email not set in SendGrid domain authentication

**Solution:**
1. Check SendGrid Console > Settings > Sender Authentication
2. Verify the sender email is verified or domain is authenticated
3. Re-set `SENDGRID_SENDER_EMAIL` if needed

## Next Steps

1. Deploy the updated functions
2. Test sending SMS and Email
3. Monitor logs for debug messages
4. Share log output if errors persist
