# Stage 1 Release Notes: SMS Compliance & Opt-Out Enhancement
**Date:** January 23, 2026  
**Stage:** 1 of 8  
**Status:** ✅ Implementation Complete

---

## Overview

Stage 1 implements TCPA-compliant SMS messaging with enhanced opt-out handling, quiet hours, per-tenant rate limiting, and required opt-out footers. All features are behind feature flags and default to OFF, preserving existing production behavior.

---

## What Changed

### 1. Feature Flag Configuration
- **New Firestore Document:** `appConfig/smsCompliance`
- **Flags:**
  - `enhancedOptOutEnabled` (default: false)
  - `quietHoursEnabled` (default: false)
  - `rateLimitingEnabled` (default: false)
  - `allowlistFacilityIds` (default: [])
  - `killSwitch` (default: false)

### 2. Data Model Additions

#### Tenant Model (`lib/models/tenant_model.dart`)
Added optional fields (backward compatible):
- `smsOptOut: bool` - Tenant opt-out status
- `smsOptOutDate: DateTime?` - When tenant opted out
- `smsOptInDate: DateTime?` - When tenant opted in
- `smsQuietHoursStart: String?` - Quiet hours start (HH:mm format)
- `smsQuietHoursEnd: String?` - Quiet hours end (HH:mm format)
- `smsRateLimitPerDay: int?` - Daily SMS limit (default: 10)
- `smsMessagesSentToday: int` - Messages sent today (reset daily)
- `smsLastResetDate: DateTime?` - Last counter reset

#### Facility Model (`lib/models/facility_model.dart`)
Added optional field (backward compatible):
- `smsSettings: Map<String, dynamic>?` - SMS compliance settings
  - `quietHoursStart: String?` - Facility quiet hours start (HH:mm)
  - `quietHoursEnd: String?` - Facility quiet hours end (HH:mm)
  - `optOutFooter: String?` - Custom opt-out footer text
  - `blockList: String[]` - Facility-level blocked phone numbers
  - `helpMessage: String?` - Custom HELP keyword response

### 3. Cloud Functions Enhancements

#### `sendSMS` Function (`functions/src/index.ts`)
**New Checks (when compliance enabled):**
1. **Opt-Out Check:** Prevents sending to opted-out tenants
2. **Block List Check:** Prevents sending to facility block list numbers
3. **Quiet Hours Check:** Prevents sending during quiet hours (unless `forceSend=true`)
4. **Per-Tenant Rate Limit Check:** Prevents sending if tenant daily limit reached
5. **Opt-Out Footer:** Automatically appends footer to all outbound messages

**New Helper Functions:**
- `checkQuietHours()` - Checks if current time is within quiet hours
- `checkPerTenantRateLimit()` - Checks tenant daily message limit
- `incrementPerTenantRateLimit()` - Increments counter after successful send
- `addOptOutFooter()` - Adds opt-out footer to message

#### `handleIncomingSMS` Function (`functions/src/index.ts`)
**Enhanced Keyword Handling:**
- **STOP/UNSUBSCRIBE/CANCEL/END/QUIT:** Opts out tenant, adds to block list, sends confirmation
- **START/YES/UNSTOP:** Opts in tenant, removes from block list, sends confirmation
- **HELP/INFO:** Sends help message (customizable per facility)

#### `handleSMSOptOut` Function (`functions/src/index.ts`)
**Enhanced:**
- Adds phone number to facility block list (if compliance enabled)
- Returns confirmation message for Twilio response

#### `handleSMSOptIn` Function (`functions/src/index.ts`)
**Enhanced:**
- Removes phone number from facility block list (if compliance enabled)

### 4. Feature Flag Functions
- `getSMSComplianceConfig()` - Gets SMS compliance config from Firestore
- `isSMSComplianceFeatureEnabled()` - Checks if feature is enabled for facility

---

## Safety & Backward Compatibility

### ✅ All Changes Are Additive
- New fields are optional (nullable)
- Existing SMS flows continue to work unchanged
- Feature flags default to OFF

### ✅ Fail-Safe Behavior
- On errors, functions fail open (allow sending) to prevent breaking existing flows
- Quiet hours/rate limits only enforced when feature flags enabled
- Opt-out footer only added when compliance enabled

### ✅ No Breaking Changes
- Existing `smsOptOut` field usage continues to work
- No changes to existing API contracts
- No changes to existing Firestore rules (additive only)

---

## Deployment Steps

### 1. Deploy Cloud Functions
```bash
cd functions
npm run build
firebase deploy --only functions
```

### 2. Deploy Flutter App
```bash
flutter build web --release
firebase deploy --only hosting
```

### 3. Create Feature Flag Document
Create `appConfig/smsCompliance` in Firestore:
```json
{
  "enhancedOptOutEnabled": false,
  "quietHoursEnabled": false,
  "rateLimitingEnabled": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

### 4. Test with Allowlist Facility
1. Add test facility ID to `allowlistFacilityIds`
2. Enable individual flags one by one
3. Test each feature:
   - Send SMS → verify footer added
   - Send STOP → verify opt-out + confirmation
   - Send HELP → verify help message
   - Test quiet hours → verify blocking
   - Test rate limit → verify blocking

### 5. Monitor for 24-48 Hours
- Monitor SMS sending success rate
- Monitor opt-out rate
- Monitor error logs
- Verify no impact on existing flows

### 6. Enable Globally (If Stable)
Update `appConfig/smsCompliance`:
```json
{
  "enhancedOptOutEnabled": true,
  "quietHoursEnabled": true,
  "rateLimitingEnabled": true,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

---

## Rollback Steps

### Quick Rollback (Feature Flags)
Set all flags to `false` in `appConfig/smsCompliance`:
```json
{
  "enhancedOptOutEnabled": false,
  "quietHoursEnabled": false,
  "rateLimitingEnabled": false,
  "killSwitch": false
}
```

### Full Rollback (If Needed)
1. Revert Cloud Functions deployment:
   ```bash
   firebase functions:rollback
   ```
2. Revert Flutter app deployment:
   ```bash
   git revert <commit-hash>
   flutter build web --release
   firebase deploy --only hosting
   ```

**Note:** Data model changes are backward compatible, so no data migration needed.

---

## Testing Checklist

### Manual Testing (UI)
- [ ] Send SMS to tenant → verify footer appears in message
- [ ] Tenant sends STOP → verify opt-out confirmation received
- [ ] Tenant sends HELP → verify help message received
- [ ] Tenant sends START → verify opt-in confirmation received
- [ ] Try sending SMS during quiet hours → verify blocked (if enabled)
- [ ] Send multiple SMS to same tenant → verify rate limit enforced (if enabled)
- [ ] Send SMS to opted-out tenant → verify blocked

### Integration Testing
- [ ] Test opt-out flow end-to-end
- [ ] Test quiet hours enforcement
- [ ] Test rate limit enforcement
- [ ] Test block list functionality
- [ ] Test feature flag enable/disable

### Production Verification
- [ ] Monitor SMS sending success rate (should be unchanged)
- [ ] Monitor opt-out rate (should be normal)
- [ ] Monitor error logs (should be clean)
- [ ] Verify existing SMS flows still work

---

## Configuration Guide

### Setting Up Quiet Hours
1. Enable `quietHoursEnabled` flag
2. Set facility quiet hours:
   ```json
   {
     "smsSettings": {
       "quietHoursStart": "22:00",
       "quietHoursEnd": "08:00"
     }
   }
   ```
3. Or set per-tenant quiet hours:
   ```json
   {
     "smsQuietHoursStart": "22:00",
     "smsQuietHoursEnd": "08:00"
   }
   ```

### Setting Up Rate Limits
1. Enable `rateLimitingEnabled` flag
2. Set per-tenant daily limit:
   ```json
   {
     "smsRateLimitPerDay": 10
   }
   ```
   Default: 10 messages per day per tenant

### Customizing Opt-Out Footer
1. Enable `enhancedOptOutEnabled` flag
2. Set custom footer:
   ```json
   {
     "smsSettings": {
       "optOutFooter": "Reply STOP to unsubscribe. Reply HELP for assistance."
     }
   }
   ```
   Default: "Reply STOP to opt out. Reply HELP for help."

### Customizing HELP Message
1. Set custom help message:
   ```json
   {
     "smsSettings": {
       "helpMessage": "For support, call us at (555) 123-4567 or visit our website."
     }
   }
   ```
   Default: "Reply STOP to opt out of SMS messages. Reply START to opt back in. For support, contact your facility directly."

---

## Known Limitations

1. **Quiet Hours Timezone:** Currently uses UTC. Full timezone support requires timezone library integration.
2. **Rate Limit Reset:** Resets at midnight UTC. Per-timezone reset requires additional logic.
3. **Block List Size:** No hard limit, but very large lists may impact performance.

---

## Next Steps

After Stage 1 is stable:
- Proceed to Stage 2: Comprehensive Audit Logging
- Monitor SMS compliance metrics
- Gather user feedback on opt-out footer

---

## Support

For questions or issues:
- Check feature flag configuration
- Review Cloud Functions logs
- Verify Firestore data structure
- Contact support if issues persist

---

**Status:** ✅ Ready for Testing  
**Next Stage:** Stage 2 (Audit Logging)
