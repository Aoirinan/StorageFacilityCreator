# STEP 0: Repository Architecture Audit
**Date:** January 23, 2026  
**Purpose:** Map current architecture to plan safe upgrades

---

## Current Architecture Overview

### Technology Stack
- **Frontend:** Flutter Web (Dart 3.0+), Riverpod 2.x, go_router
- **Backend:** Firebase (Auth, Firestore, Storage, Cloud Functions v1)
- **Integrations:** Stripe (payments/Connect), SendGrid (email), Twilio (SMS)
- **Deployment:** Firebase Hosting + Functions

### Data Model Structure
- **Facilities:** `facilities/{facilityId}` (owner-scoped)
- **Tenants:** `facilities/{facilityId}/tenants/{tenantId}`
- **Ledgers:** `facilities/{facilityId}/ledgers/{ledgerId}`
- **Payments:** `facilities/{facilityId}/payments/{paymentId}`
- **Audit Logs:** `facilities/{facilityId}/auditLogs/{logId}`
- **Message Logs:** `facilities/{facilityId}/messageLogs/{messageLogId}`
- **SMS Conversations:** `facilities/{facilityId}/smsConversations/{conversationId}`
- **User Roles:** `user_roles/{roleId}` (facility-scoped)

---

## Current Implementation Status

### A) SMS Compliance & Opt-Out
**Status:** ⚠️ **PARTIAL** - Basic opt-out exists, needs enhancement

**Current Implementation:**
- ✅ Incoming SMS handler: `handleIncomingSMS` (functions/src/index.ts:8683)
- ✅ Basic STOP/UNSUBSCRIBE handling: `handleSMSOptOut` (functions/src/index.ts:8947)
- ✅ Basic START/UNSTOP handling: `handleSMSOptIn` (functions/src/index.ts:8976)
- ✅ Tenant model has `smsOptOut` field (lib/models/tenant_model.dart)
- ❌ **Missing:** HELP keyword handling
- ❌ **Missing:** Required opt-out footer in outbound messages
- ❌ **Missing:** Quiet hours enforcement
- ❌ **Missing:** Per-tenant rate limiting (only facility-level exists)
- ❌ **Missing:** Facility-level SMS block list

**Files to Modify:**
- `functions/src/index.ts` (sendSMS, handleIncomingSMS)
- `lib/services/sms_service.dart`
- `lib/models/tenant_model.dart` (add quiet hours fields)
- `lib/models/facility_model.dart` (add SMS settings)

---

### B) Audit Logs
**Status:** ⚠️ **PARTIAL** - Inconsistent coverage

**Current Implementation:**
- ✅ Audit service exists: `lib/services/audit_service.dart`
- ✅ Firestore collection: `facilities/{facilityId}/auditLogs`
- ✅ Cloud Function helper: `writeAuditLog` (functions/src/index.ts:7358)
- ✅ Some operations logged: DNR, ledger entries, invoices, documents
- ❌ **Missing:** Standardized event schema (inconsistent fields)
- ❌ **Missing:** Tenant create/edit/archive logging
- ❌ **Missing:** Unit status change logging
- ❌ **Missing:** Payment charge/refund logging
- ❌ **Missing:** Template create/edit logging
- ❌ **Missing:** Reminder run logging
- ❌ **Missing:** Delinquency action logging (late fee/lockout)
- ❌ **Missing:** Portal access logging
- ❌ **Missing:** UI for audit log viewing/searching/exporting

**Files to Modify:**
- `lib/services/audit_service.dart` (standardize schema, add missing events)
- `functions/src/index.ts` (add writeAuditLog calls)
- `lib/services/tenant_service.dart` (add audit logging)
- `lib/services/payment_service.dart` (add audit logging)
- `lib/services/delinquency_automation_service.dart` (add audit logging)
- `lib/screens/audit_log_screen.dart` (NEW - create UI)
- `firestore.rules` (update audit log rules if needed)

---

### C) Payments Safety & Reconciliation
**Status:** ⚠️ **PARTIAL** - Basic idempotency exists, needs enhancement

**Current Implementation:**
- ✅ Stripe webhook idempotency: `stripeWebhookEvents` collection (functions/src/index.ts:6690)
- ✅ Payment processing: `processStripePayment` (functions/src/index.ts:2962)
- ✅ Refund processing: `processRefund` (functions/src/index.ts:4079)
- ❌ **Missing:** Idempotency keys for charge/refund operations
- ❌ **Missing:** Duplicate charge prevention (check before charging)
- ❌ **Missing:** Reconciliation tool (Stripe vs Firestore comparison)
- ❌ **Missing:** Payment record linking to Stripe charge IDs

**Files to Modify:**
- `functions/src/index.ts` (processStripePayment, processRefund - add idempotency)
- `lib/services/payment_service.dart` (add idempotency checks)
- `lib/services/stripe_service.dart` (add reconciliation methods)
- `lib/screens/payment_reconciliation_screen.dart` (NEW - create UI)
- `lib/models/payment_model.dart` (add stripeChargeId, idempotencyKey fields)

---

### D) Automation Guardrails
**Status:** ⚠️ **PARTIAL** - Basic duplicate prevention exists

**Current Implementation:**
- ✅ Monthly charge generation: `generateMonthlyRentCharges` (functions/src/index.ts:2776)
- ✅ Duplicate check: Checks existing charges by month/year (functions/src/index.ts:2851-2876)
- ✅ Scheduled function: `scheduledGenerateMonthlyRentCharges` (functions/src/index.ts:3471)
- ✅ Delinquency automation: `processDelinquencyForFacility` (functions/src/index.ts:3739)
- ❌ **Missing:** Unique constraint strategy (deterministic doc IDs or unique index)
- ❌ **Missing:** Dry-run/preview mode for monthly charges
- ❌ **Missing:** Dry-run/preview mode for delinquency actions
- ❌ **Missing:** Safety checks (skip inactive/moved-out tenants)
- ❌ **Missing:** Confirmation step before executing automation

**Files to Modify:**
- `functions/src/index.ts` (generateMonthlyRentCharges - add dry-run, unique keys)
- `lib/services/delinquency_automation_service.dart` (add dry-run mode)
- `lib/services/recurring_charges_service.dart` (add dry-run mode)
- `lib/screens/automation_preview_screen.dart` (NEW - create UI)

---

### E) CSV Exports
**Status:** ❌ **NOT IMPLEMENTED**

**Current Implementation:**
- ❌ No export functionality exists

**Files to Create/Modify:**
- `lib/services/export_service.dart` (NEW - create export service)
- `functions/src/index.ts` (NEW - add exportCloudFunction for large datasets)
- `lib/screens/exports_screen.dart` (NEW - create UI)
- `lib/models/export_model.dart` (NEW - create export job model)

---

### F) Fine-Grained RBAC
**Status:** ⚠️ **PARTIAL** - Basic roles exist, needs refinement

**Current Implementation:**
- ✅ Permission system: `lib/services/permission_service.dart`
- ✅ Permission model: `lib/models/permission_model.dart`
- ✅ Role types: owner, manager, employee, viewer, admin
- ✅ Firestore rules: Basic role checks (isFacilityOwnerOrManager, isFacilityStaff)
- ❌ **Missing:** Fine-grained permissions (viewTenants vs editTenants, takePayments vs issueRefunds)
- ❌ **Missing:** Permission enforcement in UI (gating buttons/actions)
- ❌ **Missing:** Firestore rules for fine-grained permissions
- ❌ **Missing:** Export permission (manageExports)
- ❌ **Missing:** Template management permission (manageTemplates)
- ❌ **Missing:** Automation management permission (manageAutomation)

**Files to Modify:**
- `lib/models/permission_model.dart` (add fine-grained permissions)
- `lib/services/permission_service.dart` (add permission checks)
- `firestore.rules` (add fine-grained permission checks)
- All screens (add UI gating based on permissions)

---

### G) 2FA
**Status:** ❌ **NOT IMPLEMENTED**

**Current Implementation:**
- ❌ No 2FA functionality exists

**Files to Create/Modify:**
- `lib/services/two_factor_service.dart` (NEW - create 2FA service)
- `functions/src/index.ts` (NEW - add email OTP generation/verification)
- `lib/screens/two_factor_setup_screen.dart` (NEW - create UI)
- `lib/models/user_model.dart` (add 2FA fields)
- `firestore.rules` (add 2FA enforcement for sensitive actions)

---

### H) Lead Pipeline
**Status:** ⚠️ **PARTIAL** - Public rental exists, needs lead tracking

**Current Implementation:**
- ✅ Public rental portal: `lib/screens/public_rental_portal_screen.dart`
- ✅ Public rental service: `lib/services/public_rental_service.dart`
- ✅ Reservation model exists (creates reservations)
- ✅ Tenant model has `leadSource` field
- ❌ **Missing:** Dedicated leads collection
- ❌ **Missing:** Lead stages (inquiry, qualified, converted, lost)
- ❌ **Missing:** Lead detail UI
- ❌ **Missing:** Lead conversion tracking (lead → tenant link)

**Files to Create/Modify:**
- `lib/models/lead_model.dart` (NEW - create lead model)
- `lib/services/lead_service.dart` (NEW - create lead service)
- `lib/screens/lead_list_screen.dart` (NEW - create UI)
- `lib/screens/lead_detail_screen.dart` (NEW - create UI)
- `functions/src/index.ts` (modify completePublicMoveIn to create lead)
- `firestore.rules` (add leads collection rules)

---

### I) Work Orders / Tasks
**Status:** ❌ **NOT IMPLEMENTED**

**Current Implementation:**
- ❌ No work order functionality exists

**Files to Create/Modify:**
- `lib/models/work_order_model.dart` (NEW - create work order model)
- `lib/services/work_order_service.dart` (NEW - create work order service)
- `lib/screens/work_order_list_screen.dart` (NEW - create UI)
- `lib/screens/work_order_detail_screen.dart` (NEW - create UI)
- `firestore.rules` (add work orders collection rules)

---

### J) Tenant Portal Upgrades
**Status:** ⚠️ **PARTIAL** - Basic portal exists, needs enhancements

**Current Implementation:**
- ✅ Tenant portal: `lib/screens/tenant_portal_screen.dart`
- ✅ Portal service: `lib/services/tenant_portal_service.dart`
- ✅ Portal fetch function: `tenantPortalFetch` (functions/src/index.ts:1446)
- ✅ Portal access via email + access code
- ❌ **Missing:** Invoice/receipt download
- ❌ **Missing:** Payment method update (Setup Intent)
- ❌ **Missing:** Autopay toggle
- ❌ **Missing:** Document signing (e-sign flow)
- ❌ **Missing:** Profile update (limited fields)

**Files to Modify:**
- `lib/screens/tenant_portal_screen.dart` (add new features)
- `lib/services/tenant_portal_service.dart` (add new methods)
- `functions/src/index.ts` (add portal functions for payment method update, autopay toggle)
- `lib/services/stripe_service.dart` (add Setup Intent for portal)

---

### K) AI Assistant
**Status:** ⚠️ **PARTIAL** - UI exists, needs action-based implementation

**Current Implementation:**
- ✅ AI Assistant screen: `lib/screens/ai_assistant_screen.dart`
- ❌ **Missing:** Action-based implementation (currently placeholder)
- ❌ **Missing:** Permission checks
- ❌ **Missing:** Audit logging
- ❌ **Missing:** User confirmation for actions

**Files to Modify:**
- `lib/screens/ai_assistant_screen.dart` (implement action-based flow)
- `lib/services/ai_assistant_service.dart` (NEW - create service)
- `functions/src/index.ts` (NEW - add AI assistant callable function)

---

## Feature Flags System

**Current Implementation:**
- ✅ Feature flags exist for Stripe features: `appConfig/stripe` (functions/src/index.ts:7404)
- ✅ Pattern: `getStripeConfig()`, `isStripeFeatureEnabled()`
- ✅ Default: All features OFF (production-safe)

**Pattern to Follow:**
- Store flags in `appConfig/{featureName}` Firestore document
- Default all flags to `false`
- Support global flags + facility allowlist
- Include kill switch for emergency disable

---

## Critical Files Reference

### Core Services
- `lib/services/sms_service.dart` - SMS sending
- `lib/services/audit_service.dart` - Audit logging
- `lib/services/payment_service.dart` - Payment processing
- `lib/services/stripe_service.dart` - Stripe integration
- `lib/services/delinquency_automation_service.dart` - Delinquency automation
- `lib/services/recurring_charges_service.dart` - Monthly charges
- `lib/services/permission_service.dart` - RBAC
- `lib/services/tenant_portal_service.dart` - Portal functionality

### Cloud Functions
- `functions/src/index.ts` - All Cloud Functions (9600+ lines)
  - `sendSMS` (line 1697)
  - `handleIncomingSMS` (line 8683)
  - `processStripePayment` (line 2962)
  - `processRefund` (line 4079)
  - `generateMonthlyRentCharges` (line 2776)
  - `processDelinquencyForFacility` (line 3739)
  - `writeAuditLog` (line 7358)
  - `tenantPortalFetch` (line 1446)

### Models
- `lib/models/tenant_model.dart` - Tenant data model
- `lib/models/payment_model.dart` - Payment data model
- `lib/models/facility_model.dart` - Facility data model
- `lib/models/permission_model.dart` - Permission/RBAC model

### Security Rules
- `firestore.rules` - All Firestore security rules (915 lines)

---

## Where Changes Will Happen

### High-Impact Areas (Require Careful Testing)
1. **SMS Service** - Compliance changes affect all outbound SMS
2. **Payment Processing** - Idempotency changes affect money flows
3. **Monthly Charge Generation** - Automation changes affect billing
4. **Delinquency Automation** - Automation changes affect late fees/lockouts
5. **Firestore Rules** - Security rule changes affect all data access

### Medium-Impact Areas
1. **Audit Logging** - Additive only, but touches many services
2. **RBAC** - Permission checks added throughout UI
3. **Tenant Portal** - New features added to existing portal

### Low-Impact Areas (New Features)
1. **CSV Exports** - New functionality, no existing code touched
2. **Lead Pipeline** - New collection, minimal existing code changes
3. **Work Orders** - New collection, no existing code touched
4. **2FA** - New functionality, opt-in only
5. **AI Assistant** - New functionality, replaces placeholder

---

## Safety Considerations

### Existing Production Flows (DO NOT BREAK)
1. **SMS Sending** - Currently works, add compliance without breaking
2. **Payment Processing** - Currently works, add idempotency without breaking
3. **Monthly Charges** - Currently works, add guardrails without breaking
4. **Delinquency Automation** - Currently works, add preview without breaking
5. **Tenant Portal** - Currently works, add features without breaking

### Migration Strategy
- All changes must be **additive only**
- Use feature flags for all new functionality
- Default flags to OFF (preserve production behavior)
- Add new fields as optional (backward compatible)
- Never modify existing field types or required fields

---

**END OF STEP 0 AUDIT**
