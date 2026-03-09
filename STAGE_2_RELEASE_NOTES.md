# Stage 2 Release Notes: Comprehensive Audit Logging
**Date:** January 23, 2026  
**Stage:** 2 of 8  
**Status:** ✅ Implementation Complete

---

## Overview

Stage 2 standardizes audit logging across the entire application and adds comprehensive event tracking for all critical operations. All new logging is behind a feature flag and defaults to OFF, preserving existing production behavior.

---

## What Changed

### 1. Standardized Audit Log Schema
- **New Schema:** `AuditLogEntry` class with standardized fields
- **Fields:**
  - `eventType` - Standardized event type (e.g., "tenant.created", "payment.charged")
  - `actorUid` - User who performed the action
  - `actorEmail` - User email (optional)
  - `actorRole` - User role (owner, manager, employee, system, tenant)
  - `targetType` - Type of entity affected (tenant, payment, invoice, etc.)
  - `targetId` - ID of the affected entity
  - `facilityId` - Facility where action occurred
  - `tenantId` - Tenant ID if applicable
  - `before` - Snapshot of data before change (for edits)
  - `after` - Snapshot of data after change
  - `timestamp` - When the action occurred
  - `ipAddress` - IP address (optional, privacy-controlled)
  - `userAgent` - User agent (optional)
  - `metadata` - Additional context

### 2. Feature Flag Configuration
- **New Firestore Document:** `appConfig/auditLogging`
- **Flags:**
  - `enhancedLoggingEnabled` (default: false)
  - `logIpAddress` (default: false) - Privacy consideration
  - `allowlistFacilityIds` (default: [])
  - `killSwitch` (default: false)

### 3. New Audit Log Events Added

#### Tenant Operations
- ✅ `tenant.created` - When tenant is created
- ✅ `tenant.edited` - When tenant is updated (with before/after snapshots)
- ✅ `tenant.archived` - When tenant is archived

#### Unit Operations
- ✅ `unit.statusChanged` - When unit status changes (available/occupied/maintenance)

#### Payment Operations
- ✅ `payment.created` - When payment record is created
- ✅ `payment.charged` - When payment is successfully charged via Stripe
- ✅ `payment.refunded` - When refund is processed
- ✅ `payment.refundRequested` - When refund is requested (manual processing)

#### Invoice Operations
- ✅ `invoice.created` - When invoice is created (already existed)
- ✅ `invoice.voided` - When invoice is voided (enhanced with before/after)

#### Template Operations
- ✅ `template.created` - When email/SMS template is created
- ✅ `template.edited` - When template is edited (with before/after)

#### Reminder Operations
- ✅ `reminder.sent` - When reminder is sent to tenant

#### Delinquency Operations
- ✅ `delinquency.lateFeeApplied` - When late fee is automatically applied
- ✅ `delinquency.lockoutTriggered` - When tenant is locked out (gate access disabled)
- ✅ `delinquency.unlocked` - When tenant is manually unlocked (gate access restored)

#### Portal Operations
- ✅ `portal.accessed` - When tenant accesses portal (email+code authentication)

### 4. Enhanced Cloud Functions
- **`writeAuditLog` Function:** Updated to use standardized schema
  - Automatically normalizes legacy fields to new schema
  - Determines user role from facility data
  - Handles both new and legacy audit log formats (backward compatible)

### 5. New Audit Log UI Screen
- **Location:** `lib/screens/audit_log_screen.dart`
- **Route:** `/audit-logs`
- **Features:**
  - Searchable by event type, actor, target
  - Filterable by event type, target type, actor role
  - Date range filtering
  - Expandable cards showing full details
  - Before/after snapshots for edits
  - Metadata display
  - Export button (placeholder for Stage 5)

---

## Files Modified

### Services
- `lib/services/audit_service.dart`
  - Added `AuditLogEntry` class (standardized schema)
  - Added `logEvent()` method (standardized logging)
  - Updated existing methods to use new schema (backward compatible)

- `lib/services/tenant_service.dart`
  - Added audit logging to `createTenant()`
  - Added audit logging to `updateTenant()` (with before/after snapshots)
  - Added audit logging to `archiveTenant()`

- `lib/services/unit_service.dart`
  - Added audit logging to `updateUnit()` (when status changes)

- `lib/services/payment_service.dart`
  - Added audit logging to `createPayment()`

- `lib/services/template_service.dart`
  - Added audit logging to `saveEmailTemplate()` (create/edit)
  - Added audit logging to `saveSMSTemplate()` (create/edit)

- `lib/services/reminder_service.dart`
  - Added audit logging to `sendReminder()`

- `lib/services/delinquency_automation_service.dart`
  - Added audit logging to `_applyLateFeeIfNeeded()`
  - Added audit logging to `_triggerLockout()`

- `lib/services/gate_access_service.dart`
  - Added audit logging to `updateGateAccess()` (when isActive changes)

### Cloud Functions
- `functions/src/index.ts`
  - Enhanced `writeAuditLog()` to use standardized schema
  - Added audit logging to `processStripePayment()` (payment.charged)
  - Added audit logging to `processRefund()` (payment.refunded, payment.refundRequested)
  - Added audit logging to `tenantPortalFetch()` (portal.accessed)
  - Added audit logging to `createTenantPortalPaymentCheckout()` (portal.accessed)
  - Added audit logging to delinquency automation (lateFeeApplied, lockoutTriggered)
  - Added feature flag system for audit logging

### UI
- `lib/screens/audit_log_screen.dart` - NEW
  - Comprehensive audit log viewer
  - Search, filter, and date range functionality
  - Expandable cards with full details

- `lib/router/app_route.dart`
  - Added `auditLogs` route constant

- `lib/router/app_router.dart`
  - Added audit log route definition

---

## Safety & Backward Compatibility

### ✅ All Changes Are Additive
- New audit log entries use standardized schema
- Existing audit logs continue to work (legacy format supported)
- Feature flag defaults to OFF

### ✅ Backward Compatible
- `writeAuditLog()` accepts both new and legacy formats
- Automatically converts legacy fields to new schema
- Existing audit log queries continue to work

### ✅ Privacy-Conscious
- IP address logging is optional (default: OFF)
- Email addresses redacted in portal access logs
- No PII logged in metadata

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
Create `appConfig/auditLogging` in Firestore:
```json
{
  "enhancedLoggingEnabled": false,
  "logIpAddress": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

### 4. Test with Allowlist Facility
1. Add test facility ID to `allowlistFacilityIds`
2. Enable `enhancedLoggingEnabled` flag
3. Perform various operations:
   - Create/edit tenant → verify audit log created
   - Process payment → verify audit log created
   - Apply late fee → verify audit log created
   - Access portal → verify audit log created
4. View audit logs in UI → verify display and filtering

### 5. Monitor for 24-48 Hours
- Monitor audit log creation rate
- Verify no performance impact
- Check Firestore read/write costs
- Verify existing flows still work

### 6. Enable Globally (If Stable)
Update `appConfig/auditLogging`:
```json
{
  "enhancedLoggingEnabled": true,
  "logIpAddress": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

---

## Rollback Steps

### Quick Rollback (Feature Flags)
Set `enhancedLoggingEnabled: false` in `appConfig/auditLogging`:
```json
{
  "enhancedLoggingEnabled": false,
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

**Note:** Audit logs are additive only, so no data cleanup needed.

---

## Testing Checklist

### Manual Testing (UI)
- [ ] Navigate to Audit Logs screen → verify loads
- [ ] Create tenant → verify `tenant.created` log appears
- [ ] Edit tenant → verify `tenant.edited` log with before/after
- [ ] Process payment → verify `payment.charged` log
- [ ] Apply late fee → verify `delinquency.lateFeeApplied` log
- [ ] Trigger lockout → verify `delinquency.lockoutTriggered` log
- [ ] Unlock tenant → verify `delinquency.unlocked` log
- [ ] Access tenant portal → verify `portal.accessed` log
- [ ] Test search functionality → verify filters work
- [ ] Test date range filter → verify date filtering works
- [ ] Expand audit log card → verify before/after/metadata display

### Integration Testing
- [ ] Verify all event types are logged correctly
- [ ] Verify before/after snapshots for edits
- [ ] Verify metadata is captured
- [ ] Verify feature flag enable/disable works

### Production Verification
- [ ] Monitor audit log creation rate (should be normal)
- [ ] Monitor Firestore costs (should be minimal increase)
- [ ] Verify no performance impact on operations
- [ ] Verify existing audit logs still display correctly

---

## Event Type Reference

### Tenant Events
- `tenant.created` - Tenant created
- `tenant.edited` - Tenant updated
- `tenant.archived` - Tenant archived

### Unit Events
- `unit.statusChanged` - Unit status changed

### Payment Events
- `payment.created` - Payment record created
- `payment.charged` - Payment successfully charged
- `payment.refunded` - Refund processed
- `payment.refundRequested` - Refund requested (manual)

### Invoice Events
- `invoice.created` - Invoice created
- `invoice.voided` - Invoice voided

### Template Events
- `template.created` - Template created
- `template.edited` - Template edited

### Reminder Events
- `reminder.sent` - Reminder sent to tenant

### Delinquency Events
- `delinquency.lateFeeApplied` - Late fee automatically applied
- `delinquency.lockoutTriggered` - Tenant locked out
- `delinquency.unlocked` - Tenant unlocked

### Portal Events
- `portal.accessed` - Tenant accessed portal

---

## Configuration Guide

### Enabling Enhanced Audit Logging
1. Set `enhancedLoggingEnabled: true` in `appConfig/auditLogging`
2. New operations will be logged with standardized schema
3. Existing audit logs continue to work (backward compatible)

### Enabling IP Address Logging
1. Set `logIpAddress: true` in `appConfig/auditLogging`
2. IP addresses will be captured for audit logs
3. **Privacy Note:** Only enable if required for compliance

### Per-Facility Enablement
1. Add facility ID to `allowlistFacilityIds` array
2. Enhanced logging will be enabled for that facility only
3. Useful for gradual rollout

---

## Known Limitations

1. **IP Address Capture:** Currently not implemented in client-side operations (Cloud Functions only)
2. **Export Functionality:** CSV export will be added in Stage 5
3. **Large Datasets:** UI limits to 1000 most recent entries (pagination can be added later)

---

## Next Steps

After Stage 2 is stable:
- Proceed to Stage 3: Payments Safety & Reconciliation
- Monitor audit log volume and costs
- Gather user feedback on audit log UI

---

## Support

For questions or issues:
- Check feature flag configuration
- Review Cloud Functions logs
- Verify Firestore audit logs collection
- Contact support if issues persist

---

**Status:** ✅ Ready for Testing  
**Next Stage:** Stage 3 (Payments Safety)
