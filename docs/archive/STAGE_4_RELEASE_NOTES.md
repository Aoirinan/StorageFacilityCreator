# Stage 4 Release Notes: Automation Guardrails
**Date:** January 23, 2026  
**Stage:** 4 of 8  
**Status:** ✅ Implementation Complete

---

## Overview

Stage 4 adds dry-run/preview modes and safety checks to automation functions (monthly charge generation and delinquency processing). All new features are behind feature flags and default to OFF, preserving existing production behavior.

---

## What Changed

### 1. Dry-Run Mode for Monthly Charges
- **New Parameter:** `dryRun` in `generateMonthlyRentCharges()`
- **Behavior:** When enabled, previews charges without creating them
- **Returns:** Preview data with total charges and total amount
- **UI Support:** Recurring charges screen now has "Dry Run" checkbox

### 2. Dry-Run Mode for Delinquency Automation
- **New Parameter:** `dryRun` in `processDelinquencyForFacility()`
- **Behavior:** When enabled, previews actions without executing them
- **Returns:** Preview data with estimated late fees, notices, and lockouts
- **New Callable Function:** `processDelinquencyForFacilityCallable` for manual execution

### 3. Safety Checks
- **Monthly Charges:**
  - Skips inactive tenants
  - Skips tenants without unit numbers
  - Skips moved-out tenants (checks `moveOutDate`)
- **Delinquency Automation:**
  - Skips inactive tenants
  - Skips moved-out tenants (checks `moveOutDate`)
  - Only processes tenants with positive balance

### 4. Confirmation Step
- **Automation Preview Screen:** New UI for previewing and confirming automation
- **Confirmation Dialog:** Required before executing automation
- **Route:** `/automation-preview?type=monthlyCharges` or `/automation-preview?type=delinquency`

### 5. Feature Flag Configuration
- **New Firestore Document:** `appConfig/automationGuardrails`
- **Flags:**
  - `dryRunEnabled` (default: false)
  - `safetyChecksEnabled` (default: false)
  - `confirmationRequired` (default: false)
  - `allowlistFacilityIds` (default: [])
  - `killSwitch` (default: false)

### 6. Enhanced Unique Constraint Strategy
- **Idempotency Keys:** Already implemented in Stage 3
- **Transaction Safety:** Uses Firestore transactions for atomic charge creation
- **Backward Compatible:** Falls back to existing logic if idempotency disabled

---

## Files Modified

### Services
- `lib/services/recurring_charges_service.dart`
  - Added `dryRun` parameter to `generateMonthlyRentCharges()`
  - Added safety checks (skip inactive/moved-out tenants)
  - Skips actual charge creation in dry-run mode

- `lib/services/delinquency_automation_service.dart`
  - Added `dryRun` parameter to `processDelinquency()`
  - Added `dryRun` parameter to `_processDelinquencyStage()`
  - Added safety checks (skip inactive/moved-out tenants)
  - Skips actual actions in dry-run mode (late fees, notices, lockouts)

### Cloud Functions
- `functions/src/index.ts`
  - Added `dryRun` parameter to `generateMonthlyRentCharges()` (~20 lines)
  - Added `dryRun` parameter to `processDelinquencyForFacility()` (~50 lines)
  - Added `processDelinquencyForFacilityCallable()` function (~40 lines)
  - Added safety checks to filter tenants (~30 lines)
  - Added preview data to return values
  - Added feature flag system (~80 lines)

### UI
- `lib/screens/recurring_charges_screen.dart`
  - Added "Dry Run" checkbox to generation dialog
  - Updated to pass `dryRun` parameter
  - Shows preview message when dry-run completes

- `lib/screens/automation_preview_screen.dart` - NEW (~400 lines)
  - Comprehensive automation preview UI
  - Supports both monthly charges and delinquency
  - Shows preview results with statistics
  - Confirmation dialog before execution

- `lib/router/app_route.dart`
  - Added `automationPreview` route constant

- `lib/router/app_router.dart`
  - Added automation preview route definition

---

## Safety & Backward Compatibility

### ✅ All Changes Are Additive
- New parameters are optional (default: false)
- Existing automation flows continue to work unchanged
- Safety checks only active when feature enabled

### ✅ Fail-Safe Behavior
- Dry-run mode never modifies data
- Safety checks prevent processing wrong tenants
- Confirmation required before execution (when enabled)

### ✅ No Breaking Changes
- Existing automation continues to work
- No changes to existing API contracts
- Scheduled functions never use dry-run (always execute)

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
Create `appConfig/automationGuardrails` in Firestore:
```json
{
  "dryRunEnabled": false,
  "safetyChecksEnabled": false,
  "confirmationRequired": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

### 4. Test with Allowlist Facility
1. Add test facility ID to `allowlistFacilityIds`
2. Enable individual flags one by one:
   - `dryRunEnabled: true` → Test preview mode
   - `safetyChecksEnabled: true` → Test safety checks
   - `confirmationRequired: true` → Test confirmation
3. Test each feature:
   - Run monthly charges preview → verify preview data
   - Run delinquency preview → verify preview data
   - Execute automation → verify confirmation dialog
   - Verify safety checks skip inactive/moved-out tenants

### 5. Monitor for 24-48 Hours
- Monitor automation execution success rate
- Verify safety checks working correctly
- Check that moved-out tenants are skipped
- Verify no impact on existing scheduled automation

### 6. Enable Globally (If Stable)
Update `appConfig/automationGuardrails`:
```json
{
  "dryRunEnabled": true,
  "safetyChecksEnabled": true,
  "confirmationRequired": true,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

---

## Rollback Steps

### Quick Rollback (Feature Flags)
Set all flags to `false` in `appConfig/automationGuardrails`:
```json
{
  "dryRunEnabled": false,
  "safetyChecksEnabled": false,
  "confirmationRequired": false,
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

**Note:** Dry-run mode is read-only, so no data cleanup needed.

---

## Testing Checklist

### Manual Testing (UI)
- [ ] Navigate to Recurring Charges screen → verify dry-run checkbox
- [ ] Run monthly charges preview → verify preview data displayed
- [ ] Execute monthly charges → verify charges created
- [ ] Navigate to Automation Preview → verify loads
- [ ] Run delinquency preview → verify preview data displayed
- [ ] Execute delinquency automation → verify confirmation dialog
- [ ] Verify safety checks skip inactive tenants
- [ ] Verify safety checks skip moved-out tenants

### Integration Testing
- [ ] Verify dry-run mode doesn't create charges
- [ ] Verify dry-run mode doesn't apply late fees
- [ ] Verify dry-run mode doesn't send notices
- [ ] Verify dry-run mode doesn't trigger lockouts
- [ ] Verify safety checks filter correctly
- [ ] Verify confirmation dialog appears (when enabled)

### Production Verification
- [ ] Monitor automation execution success rate (should be unchanged)
- [ ] Verify scheduled automation still works (never uses dry-run)
- [ ] Verify safety checks prevent processing wrong tenants
- [ ] Verify existing automation flows still work

---

## Configuration Guide

### Enabling Dry-Run Mode
1. Set `dryRunEnabled: true` in `appConfig/automationGuardrails`
2. UI will show "Dry Run" checkbox
3. Preview mode will be available for manual executions

### Enabling Safety Checks
1. Set `safetyChecksEnabled: true` in `appConfig/automationGuardrails`
2. System will automatically skip inactive/moved-out tenants
3. Applies to both monthly charges and delinquency automation

### Enabling Confirmation Required
1. Set `confirmationRequired: true` in `appConfig/automationGuardrails`
2. Confirmation dialog will appear before executing automation
3. Users must confirm before automation runs

### Per-Facility Enablement
1. Add facility ID to `allowlistFacilityIds` array
2. Automation guardrails will be enabled for that facility only
3. Useful for gradual rollout

---

## Known Limitations

1. **Scheduled Automation:** Never uses dry-run (always executes)
2. **Preview Data:** Limited to summary statistics (detailed per-tenant preview can be added later)
3. **Move-Out Detection:** Relies on `isActive` flag and `moveOutDate` field (may need enhancement)

---

## Next Steps

After Stage 4 is stable:
- Proceed to Stage 5: CSV Exports
- Monitor automation safety metrics
- Gather user feedback on preview UI

---

## Support

For questions or issues:
- Check feature flag configuration
- Review Cloud Functions logs
- Verify tenant filtering logic
- Contact support if issues persist

---

**Status:** ✅ Ready for Testing  
**Next Stage:** Stage 5 (CSV Exports)
