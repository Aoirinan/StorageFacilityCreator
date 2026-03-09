# STEP 1: Staged Implementation Plan
**Date:** January 23, 2026  
**Purpose:** Safe, incremental rollout of all upgrades  
**Principle:** Each stage is independently deployable and rollback-safe

---

## Overview

This plan breaks down 11 upgrade areas (A-K) into **8 safe stages**. Each stage:
- ✅ Is independently deployable
- ✅ Has feature flags (default OFF)
- ✅ Includes rollback steps
- ✅ Preserves existing production behavior
- ✅ Can be tested in isolation

---

## Stage 1: SMS Compliance & Opt-Out Enhancement
**Priority:** HIGH (Legal/Compliance)  
**Risk:** MEDIUM (Affects all SMS sending)  
**Estimated Effort:** 2-3 days

### Scope
Enhance existing SMS opt-out handling to be fully TCPA compliant:
- Add HELP keyword handling
- Add required opt-out footer to all outbound SMS
- Add quiet hours enforcement
- Add per-tenant rate limiting
- Add facility-level SMS block list

### Files to Modify
- `functions/src/index.ts`
  - `sendSMS` function (add footer, quiet hours check, rate limit check)
  - `handleIncomingSMS` function (add HELP keyword)
  - `handleSMSOptOut` function (add facility block list entry)
- `lib/services/sms_service.dart` - Add quiet hours/rate limit checks
- `lib/models/tenant_model.dart` - Add `smsOptOutDate`, `smsOptInDate` (already exists), `smsQuietHoursStart`, `smsQuietHoursEnd`, `smsRateLimitPerDay`
- `lib/models/facility_model.dart` - Add `smsSettings` (quiet hours, opt-out footer template, block list)
- `firestore.rules` - Add validation for SMS settings

### Data Model Additions
```typescript
// Tenant model additions (optional fields, backward compatible)
{
  smsOptOutDate?: Timestamp;
  smsOptInDate?: Timestamp;
  smsQuietHoursStart?: string; // "HH:mm" format
  smsQuietHoursEnd?: string; // "HH:mm" format
  smsRateLimitPerDay?: number; // Default: 10
  smsMessagesSentToday?: number; // Reset daily
  smsLastResetDate?: Timestamp;
}

// Facility model additions
{
  smsSettings?: {
    quietHoursStart?: string; // "HH:mm"
    quietHoursEnd?: string; // "HH:mm"
    optOutFooter?: string; // Default: "Reply STOP to opt out"
    blockList?: string[]; // Phone numbers blocked facility-wide
  }
}
```

### Feature Flags
- **Flag:** `appConfig/smsCompliance`
  - `enhancedOptOutEnabled: boolean` (default: false)
  - `quietHoursEnabled: boolean` (default: false)
  - `rateLimitingEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: SMS footer injection
- Unit tests: Quiet hours check logic
- Unit tests: Rate limit check logic
- Integration tests: HELP keyword response
- Integration tests: STOP/UNSUBSCRIBE opt-out flow

### Deploy Steps
1. Deploy Firestore rules (additive only)
2. Deploy Cloud Functions (backward compatible)
3. Deploy Flutter app (new fields optional)
4. Create `appConfig/smsCompliance` document (all flags OFF)
5. Test with allowlist facility
6. Monitor for 24 hours
7. Enable globally if stable

### Rollback Steps
1. Set `enhancedOptOutEnabled: false` in `appConfig/smsCompliance`
2. Revert Cloud Functions deployment (if needed)
3. Old SMS flow continues to work (footer/quiet hours skipped when flag OFF)

---

## Stage 2: Comprehensive Audit Logging
**Priority:** HIGH (Compliance/Accountability)  
**Risk:** LOW (Additive only, doesn't affect business logic)  
**Estimated Effort:** 3-4 days

### Scope
Standardize audit logging schema and add missing event types:
- Standardize event schema (eventType, actorUid, actorRole, targetType, targetId, before, after, timestamp, ip/userAgent)
- Add tenant create/edit/archive logging
- Add unit status change logging
- Add payment charge/refund logging
- Add template create/edit logging
- Add reminder run logging
- Add delinquency action logging
- Add portal access logging
- Create audit log UI (searchable, filterable, exportable)

### Files to Modify
- `lib/services/audit_service.dart` - Standardize schema, add missing event methods
- `functions/src/index.ts` - Add `writeAuditLog` calls throughout
- `lib/services/tenant_service.dart` - Add audit logging to create/edit/archive
- `lib/services/unit_service.dart` - Add audit logging to status changes
- `lib/services/payment_service.dart` - Add audit logging to charges/refunds
- `lib/services/email_template_service.dart` - Add audit logging to template operations
- `lib/services/reminder_service.dart` - Add audit logging to reminder runs
- `lib/services/delinquency_automation_service.dart` - Add audit logging to delinquency actions
- `lib/services/tenant_portal_service.dart` - Add audit logging to portal access
- `lib/screens/audit_log_screen.dart` - NEW - Create UI
- `firestore.rules` - Update audit log rules (if needed)

### Data Model Additions
```typescript
// Standardized audit log schema
{
  eventType: string; // e.g., "tenant.created", "payment.charged", "delinquency.lateFeeApplied"
  actorUid: string;
  actorRole: string; // "owner", "manager", "employee"
  actorEmail?: string;
  targetType: string; // "tenant", "payment", "invoice", etc.
  targetId: string;
  facilityId: string;
  tenantId?: string; // If applicable
  before?: Record<string, any>; // Snapshot before change
  after?: Record<string, any>; // Snapshot after change
  timestamp: Timestamp;
  ipAddress?: string;
  userAgent?: string;
  metadata?: Record<string, any>; // Additional context
}
```

### Feature Flags
- **Flag:** `appConfig/auditLogging`
  - `enhancedLoggingEnabled: boolean` (default: false)
  - `logIpAddress: boolean` (default: false) - Privacy consideration
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: Audit log schema validation
- Unit tests: Audit log creation for each event type
- Integration tests: Audit log retrieval and filtering
- UI tests: Audit log screen functionality

### Deploy Steps
1. Deploy Firestore rules (additive only)
2. Deploy Cloud Functions (add writeAuditLog calls)
3. Deploy Flutter app (add audit service calls, new UI)
4. Create `appConfig/auditLogging` document (flag OFF)
5. Test with allowlist facility
6. Monitor audit log creation
7. Enable globally if stable

### Rollback Steps
1. Set `enhancedLoggingEnabled: false` in `appConfig/auditLogging`
2. Audit logging stops (existing logs remain, new logs not created)
3. No impact on business logic (logging is non-blocking)

---

## Stage 3: Payments Safety & Reconciliation
**Priority:** HIGH (Financial Safety)  
**Risk:** MEDIUM (Affects payment processing)  
**Estimated Effort:** 4-5 days

### Scope
Add idempotency and reconciliation for Stripe payments:
- Add idempotency keys to all charge/refund operations
- Prevent duplicate charges (check before charging)
- Create reconciliation tool (Stripe vs Firestore comparison)
- Link payment records to Stripe charge IDs

### Files to Modify
- `functions/src/index.ts`
  - `processStripePayment` - Add idempotency key, duplicate check
  - `processRefund` - Add idempotency key, duplicate check
  - NEW: `reconcilePayments` - Reconciliation function
- `lib/services/payment_service.dart` - Add idempotency checks
- `lib/services/stripe_service.dart` - Add reconciliation methods
- `lib/models/payment_model.dart` - Add `stripeChargeId`, `stripeRefundId`, `idempotencyKey` fields
- `lib/screens/payment_reconciliation_screen.dart` - NEW - Create UI
- `firestore.rules` - Add payment idempotency collection rules

### Data Model Additions
```typescript
// Payment model additions
{
  stripeChargeId?: string;
  stripeRefundId?: string;
  idempotencyKey?: string; // Format: "charge-{facilityId}-{tenantId}-{timestamp}-{hash}"
  reconciliationStatus?: "pending" | "matched" | "mismatch" | "missing";
  lastReconciledAt?: Timestamp;
}

// New collection: paymentIdempotency
// facilities/{facilityId}/paymentIdempotency/{idempotencyKey}
{
  idempotencyKey: string;
  paymentId: string;
  operation: "charge" | "refund";
  amount: number;
  status: "pending" | "completed" | "failed";
  createdAt: Timestamp;
  expiresAt: Timestamp; // TTL: 24 hours
}
```

### Feature Flags
- **Flag:** `appConfig/paymentSafety`
  - `idempotencyEnabled: boolean` (default: false)
  - `reconciliationEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: Idempotency key generation
- Unit tests: Duplicate charge prevention
- Integration tests: Reconciliation logic
- Integration tests: Stripe API idempotency
- UI tests: Reconciliation screen

### Deploy Steps
1. Deploy Firestore rules (add paymentIdempotency collection)
2. Deploy Cloud Functions (add idempotency checks)
3. Deploy Flutter app (add reconciliation UI)
4. Create `appConfig/paymentSafety` document (flags OFF)
5. Test with allowlist facility
6. Monitor payment processing
7. Enable globally if stable

### Rollback Steps
1. Set `idempotencyEnabled: false` in `appConfig/paymentSafety`
2. Payment processing continues without idempotency (existing behavior)
3. Reconciliation tool remains available (read-only)

---

## Stage 4: Automation Guardrails
**Priority:** HIGH (Prevent Duplicate Charges)  
**Risk:** MEDIUM (Affects monthly billing)  
**Estimated Effort:** 3-4 days

### Scope
Add safety guardrails for automation:
- Add unique constraint for monthly charges (deterministic doc IDs)
- Add dry-run/preview mode for monthly charges
- Add dry-run/preview mode for delinquency actions
- Add safety checks (skip inactive/moved-out tenants)
- Add confirmation step before executing automation

### Files to Modify
- `functions/src/index.ts`
  - `generateMonthlyRentCharges` - Add dry-run mode, unique keys, safety checks
  - `processDelinquencyForFacility` - Add dry-run mode, safety checks
- `lib/services/recurring_charges_service.dart` - Add dry-run mode
- `lib/services/delinquency_automation_service.dart` - Add dry-run mode
- `lib/screens/automation_preview_screen.dart` - NEW - Create UI
- `firestore.rules` - Add unique constraint validation (if possible)

### Data Model Additions
```typescript
// Monthly charge unique key strategy
// Use deterministic doc ID: `rent-{facilityId}-{tenantId}-{year}-{month}`
// This prevents duplicates at the document level

// New collection: automationRuns
// facilities/{facilityId}/automationRuns/{runId}
{
  runId: string;
  type: "monthlyCharges" | "delinquency";
  mode: "dryRun" | "execute";
  facilityId: string;
  targetDate: Timestamp;
  preview: {
    affectedTenants: number;
    totalCharges: number;
    totalLateFees: number;
    totalLockouts: number;
    skippedTenants: number;
    errors: string[];
  };
  executed: boolean;
  executedAt?: Timestamp;
  executedBy?: string;
  createdAt: Timestamp;
}
```

### Feature Flags
- **Flag:** `appConfig/automationGuardrails`
  - `dryRunEnabled: boolean` (default: false)
  - `uniqueKeysEnabled: boolean` (default: false)
  - `safetyChecksEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: Unique key generation
- Unit tests: Dry-run mode logic
- Unit tests: Safety check logic (skip inactive tenants)
- Integration tests: Monthly charge generation with unique keys
- Integration tests: Delinquency automation with safety checks

### Deploy Steps
1. Deploy Firestore rules (add automationRuns collection)
2. Deploy Cloud Functions (add dry-run mode, unique keys)
3. Deploy Flutter app (add preview UI)
4. Create `appConfig/automationGuardrails` document (flags OFF)
5. Test with allowlist facility
6. Monitor automation runs
7. Enable globally if stable

### Rollback Steps
1. Set all flags to `false` in `appConfig/automationGuardrails`
2. Automation continues with existing behavior (no dry-run, no unique keys)
3. Existing duplicate prevention logic remains (month/year check)

---

## Stage 5: CSV Exports
**Priority:** MEDIUM (Data Portability)  
**Risk:** LOW (Read-only operation)  
**Estimated Effort:** 3-4 days

### Scope
Add CSV export functionality for all major data types:
- Export tenants, units, invoices, payments, delinquency, message logs, audit logs
- Support filters (date range, status)
- Respect permissions (owner/manager only)
- Handle large datasets (use Cloud Function for >1000 records)

### Files to Create/Modify
- `lib/services/export_service.dart` - NEW - Create export service
- `functions/src/index.ts` - NEW: `exportData` callable function
- `lib/screens/exports_screen.dart` - NEW - Create UI
- `lib/models/export_model.dart` - NEW - Create export job model
- `firestore.rules` - Add export permission checks

### Data Model Additions
```typescript
// New collection: exportJobs
// facilities/{facilityId}/exportJobs/{jobId}
{
  jobId: string;
  facilityId: string;
  exportType: "tenants" | "units" | "invoices" | "payments" | "delinquency" | "messageLogs" | "auditLogs";
  filters?: {
    dateRange?: { start: Timestamp; end: Timestamp };
    status?: string;
    tenantId?: string;
  };
  status: "pending" | "processing" | "completed" | "failed";
  fileUrl?: string; // Signed URL to CSV file in Storage
  recordCount?: number;
  createdAt: Timestamp;
  completedAt?: Timestamp;
  createdBy: string;
  error?: string;
}
```

### Feature Flags
- **Flag:** `appConfig/exports`
  - `exportsEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: CSV generation for each export type
- Unit tests: Filter application
- Integration tests: Export job creation and processing
- Integration tests: Permission checks
- UI tests: Export screen functionality

### Deploy Steps
1. Deploy Firestore rules (add exportJobs collection)
2. Deploy Cloud Functions (add exportData function)
3. Deploy Flutter app (add export UI)
4. Create `appConfig/exports` document (flag OFF)
5. Test with allowlist facility
6. Monitor export jobs
7. Enable globally if stable

### Rollback Steps
1. Set `exportsEnabled: false` in `appConfig/exports`
2. Export UI hidden, export function returns error
3. No impact on existing functionality

---

## Stage 6: Fine-Grained RBAC
**Priority:** MEDIUM (Security Enhancement)  
**Risk:** MEDIUM (Affects all UI access)  
**Estimated Effort:** 4-5 days

### Scope
Implement fine-grained permissions:
- Add permission types: viewTenants, editTenants, viewBilling, editBilling, takePayments, issueRefunds, manageExports, manageTemplates, manageAutomation, manageSettings
- Update role definitions (owner/manager/employee)
- Add UI gating (hide/disable buttons based on permissions)
- Add Firestore rules for fine-grained permissions
- Update permission service to check fine-grained permissions

### Files to Modify
- `lib/models/permission_model.dart` - Add fine-grained permission types
- `lib/services/permission_service.dart` - Add fine-grained permission checks
- `firestore.rules` - Add fine-grained permission checks
- All screens - Add UI gating (extensive changes)
  - Payment screens: Check `takePayments` for charges, `issueRefunds` for refunds
  - Tenant screens: Check `viewTenants` for read, `editTenants` for write
  - Billing screens: Check `viewBilling` for read, `editBilling` for write
  - Export screens: Check `manageExports`
  - Template screens: Check `manageTemplates`
  - Automation screens: Check `manageAutomation`
  - Settings screens: Check `manageSettings`

### Data Model Additions
```typescript
// Permission model additions (additive only)
enum PermissionType {
  // ... existing permissions ...
  // New fine-grained permissions
  viewTenants,
  editTenants,
  viewBilling,
  editBilling,
  takePayments,
  issueRefunds,
  manageExports,
  manageTemplates,
  manageAutomation,
  manageSettings,
}

// Role definitions updated (additive only)
RoleType.owner: [all permissions]
RoleType.manager: [viewTenants, editTenants, viewBilling, editBilling, takePayments, issueRefunds, manageExports, manageTemplates, manageAutomation]
RoleType.employee: [viewTenants, editTenants, viewBilling, takePayments]
```

### Feature Flags
- **Flag:** `appConfig/fineGrainedRBAC`
  - `fineGrainedRBACEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: Permission checks for each permission type
- Unit tests: Role permission matrix
- Integration tests: Firestore rules enforcement
- UI tests: Button gating based on permissions

### Deploy Steps
1. Deploy Firestore rules (add fine-grained checks, backward compatible)
2. Deploy Flutter app (add UI gating, permission checks)
3. Create `appConfig/fineGrainedRBAC` document (flag OFF)
4. Test with allowlist facility
5. Verify existing users still have access (backward compatible)
6. Enable globally if stable

### Rollback Steps
1. Set `fineGrainedRBACEnabled: false` in `appConfig/fineGrainedRBAC`
2. UI falls back to existing role checks (owner/manager/employee)
3. Firestore rules fall back to existing checks

---

## Stage 7: 2FA, Lead Pipeline, Work Orders, Portal Upgrades
**Priority:** MEDIUM (Feature Additions)  
**Risk:** LOW (New features, opt-in)  
**Estimated Effort:** 6-7 days

### Scope
Implement four new features:
1. **2FA:** Email OTP for owner/manager accounts (sensitive actions)
2. **Lead Pipeline:** Public rental inquiry → lead records with stages
3. **Work Orders:** Facility tasks/work orders with assignee, due dates, status
4. **Portal Upgrades:** Invoice/receipt download, payment method update, autopay toggle, document signing, profile update

### Files to Create/Modify

#### 2FA
- `lib/services/two_factor_service.dart` - NEW
- `functions/src/index.ts` - NEW: `generateOTP`, `verifyOTP`
- `lib/screens/two_factor_setup_screen.dart` - NEW
- `lib/models/user_model.dart` - Add `twoFactorEnabled`, `twoFactorMethod` fields
- `firestore.rules` - Add 2FA enforcement for sensitive actions

#### Lead Pipeline
- `lib/models/lead_model.dart` - NEW
- `lib/services/lead_service.dart` - NEW
- `lib/screens/lead_list_screen.dart` - NEW
- `lib/screens/lead_detail_screen.dart` - NEW
- `functions/src/index.ts` - Modify `completePublicMoveIn` to create lead
- `firestore.rules` - Add leads collection rules

#### Work Orders
- `lib/models/work_order_model.dart` - NEW
- `lib/services/work_order_service.dart` - NEW
- `lib/screens/work_order_list_screen.dart` - NEW
- `lib/screens/work_order_detail_screen.dart` - NEW
- `firestore.rules` - Add work orders collection rules

#### Portal Upgrades
- `lib/screens/tenant_portal_screen.dart` - Add new features
- `lib/services/tenant_portal_service.dart` - Add new methods
- `functions/src/index.ts` - Add portal functions
- `lib/services/stripe_service.dart` - Add Setup Intent for portal

### Data Model Additions
```typescript
// 2FA
{
  twoFactorEnabled: boolean;
  twoFactorMethod: "email" | "totp";
  otpSecret?: string; // For TOTP
  lastOTPSentAt?: Timestamp;
}

// Leads
// facilities/{facilityId}/leads/{leadId}
{
  leadId: string;
  facilityId: string;
  source: string; // "publicRental", "walkIn", "phone", etc.
  contactInfo: {
    name: string;
    email: string;
    phone?: string;
  };
  desiredUnit?: string;
  stage: "inquiry" | "qualified" | "converted" | "lost";
  notes?: string;
  convertedToTenantId?: string; // Link to tenant if converted
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

// Work Orders
// facilities/{facilityId}/workOrders/{workOrderId}
{
  workOrderId: string;
  facilityId: string;
  title: string;
  description?: string;
  unitId?: string;
  tenantId?: string;
  assignedTo?: string; // User UID
  status: "open" | "inProgress" | "completed" | "cancelled";
  priority: "low" | "medium" | "high" | "urgent";
  dueDate?: Timestamp;
  comments: Array<{
    text: string;
    authorUid: string;
    authorName: string;
    createdAt: Timestamp;
  }>;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  createdBy: string;
}
```

### Feature Flags
- **Flag:** `appConfig/newFeatures`
  - `twoFactorEnabled: boolean` (default: false)
  - `leadPipelineEnabled: boolean` (default: false)
  - `workOrdersEnabled: boolean` (default: false)
  - `portalUpgradesEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: 2FA OTP generation/verification
- Unit tests: Lead stage transitions
- Unit tests: Work order status transitions
- Integration tests: Portal payment method update
- Integration tests: Portal autopay toggle

### Deploy Steps
1. Deploy Firestore rules (add new collections)
2. Deploy Cloud Functions (add new functions)
3. Deploy Flutter app (add new screens/services)
4. Create `appConfig/newFeatures` document (all flags OFF)
5. Test each feature with allowlist facility
6. Enable features one by one
7. Monitor each feature independently

### Rollback Steps
1. Set individual feature flags to `false` in `appConfig/newFeatures`
2. Each feature can be disabled independently
3. No impact on existing functionality

---

## Stage 8: AI Assistant (Action-Based)
**Priority:** LOW (Nice-to-Have)  
**Risk:** LOW (New feature, opt-in)  
**Estimated Effort:** 4-5 days

### Scope
Implement action-based AI assistant:
- Replace placeholder with real implementation
- Action-based flow (propose actions, require confirmation)
- Permission checks before actions
- Audit logging for all actions
- Safe provider integration (no secrets in client)

### Files to Modify
- `lib/screens/ai_assistant_screen.dart` - Implement action-based flow
- `lib/services/ai_assistant_service.dart` - NEW - Create service
- `functions/src/index.ts` - NEW: `aiAssistant` callable function
- `lib/services/permission_service.dart` - Add AI assistant permission checks

### Data Model Additions
```typescript
// AI Assistant actions
interface AIAction {
  type: "createTenant" | "createPayment" | "sendMessage" | "createReminder" | etc.;
  description: string;
  parameters: Record<string, any>;
  estimatedImpact: string;
  requiresConfirmation: boolean;
}

// AI Assistant conversation
// facilities/{facilityId}/aiConversations/{conversationId}
{
  conversationId: string;
  facilityId: string;
  messages: Array<{
    role: "user" | "assistant";
    content: string;
    actions?: AIAction[];
    confirmedAction?: AIAction;
    executedAt?: Timestamp;
  }>;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}
```

### Feature Flags
- **Flag:** `appConfig/aiAssistant`
  - `aiAssistantEnabled: boolean` (default: false)
  - `allowlistFacilityIds: string[]` (default: [])

### Tests to Add
- Unit tests: AI action proposal
- Unit tests: Permission checks for actions
- Integration tests: AI action execution
- Integration tests: Audit logging for AI actions

### Deploy Steps
1. Deploy Firestore rules (add aiConversations collection)
2. Deploy Cloud Functions (add aiAssistant function)
3. Deploy Flutter app (implement AI assistant screen)
4. Create `appConfig/aiAssistant` document (flag OFF)
5. Test with allowlist facility
6. Monitor AI actions and audit logs
7. Enable globally if stable

### Rollback Steps
1. Set `aiAssistantEnabled: false` in `appConfig/aiAssistant`
2. AI assistant screen hidden/disabled
3. No impact on existing functionality

---

## Deployment Timeline

### Recommended Schedule
- **Week 1:** Stage 1 (SMS Compliance)
- **Week 2:** Stage 2 (Audit Logging)
- **Week 3:** Stage 3 (Payments Safety)
- **Week 4:** Stage 4 (Automation Guardrails)
- **Week 5:** Stage 5 (CSV Exports)
- **Week 6:** Stage 6 (Fine-Grained RBAC)
- **Week 7:** Stage 7 (2FA, Leads, Work Orders, Portal)
- **Week 8:** Stage 8 (AI Assistant)

**Total Estimated Time:** 8 weeks (with testing and monitoring between stages)

### Parallel Work (If Resources Available)
- Stages 5, 7, 8 can be worked on in parallel (low risk, independent features)
- Stages 1-4 should be sequential (higher risk, affect core flows)

---

## Testing Strategy

### Per-Stage Testing
1. **Unit Tests:** Pure logic, no Firebase dependencies
2. **Integration Tests:** Firestore emulator, test security rules
3. **Manual Testing:** Test in staging environment with allowlist facility
4. **Production Testing:** Enable for allowlist facility, monitor for 24-48 hours
5. **Global Rollout:** Enable globally if no issues

### Regression Testing
- Test existing flows after each stage
- Verify feature flags work correctly
- Verify rollback steps work

---

## Monitoring & Alerts

### Key Metrics to Monitor
- **SMS:** Opt-out rate, quiet hours violations, rate limit hits
- **Audit Logs:** Log creation rate, errors
- **Payments:** Idempotency key usage, duplicate charge attempts
- **Automation:** Dry-run vs execute ratio, skipped tenants
- **Exports:** Export job success rate, processing time
- **RBAC:** Permission check failures
- **2FA:** OTP generation/verification rate
- **AI Assistant:** Action execution rate, errors

### Alert Thresholds
- SMS opt-out rate > 5%
- Payment duplicate charge attempts > 0
- Automation errors > 1%
- Export job failures > 5%
- Permission check failures > 1%

---

## Success Criteria

### Stage 1 (SMS Compliance)
- ✅ All outbound SMS include opt-out footer
- ✅ STOP/HELP keywords handled correctly
- ✅ Quiet hours enforced
- ✅ Rate limiting working

### Stage 2 (Audit Logging)
- ✅ All critical operations logged
- ✅ Audit log UI functional
- ✅ Export working

### Stage 3 (Payments Safety)
- ✅ No duplicate charges
- ✅ Reconciliation tool functional
- ✅ Idempotency keys used

### Stage 4 (Automation Guardrails)
- ✅ No duplicate monthly charges
- ✅ Dry-run mode working
- ✅ Safety checks skip inactive tenants

### Stage 5 (CSV Exports)
- ✅ All export types working
- ✅ Permissions enforced
- ✅ Large datasets handled

### Stage 6 (Fine-Grained RBAC)
- ✅ UI gating working
- ✅ Firestore rules enforced
- ✅ Existing users still have access

### Stage 7 (New Features)
- ✅ 2FA working for sensitive actions
- ✅ Lead pipeline functional
- ✅ Work orders functional
- ✅ Portal upgrades working

### Stage 8 (AI Assistant)
- ✅ Action-based flow working
- ✅ Permissions enforced
- ✅ Audit logging working

---

## Risk Mitigation

### High-Risk Stages (1, 3, 4)
- Deploy during low-traffic hours
- Have rollback plan ready
- Monitor closely for 48 hours
- Keep feature flags OFF until confident

### Medium-Risk Stages (2, 6)
- Deploy during business hours
- Monitor for 24 hours
- Gradual rollout (allowlist → global)

### Low-Risk Stages (5, 7, 8)
- Deploy anytime
- Monitor for 24 hours
- Can enable immediately if stable

---

**END OF STEP 1 PLAN**

**Next Step:** Review this plan, then proceed with Stage 1 implementation.
