# Storage Facility Creator - Finish Line Checklist

**Last Updated:** January 28, 2026  
**Purpose:** Prioritized checklist of remaining work to complete before public launch

---

## Priority 1: Critical Path (Must Complete Before Launch)

### Auth & Security

- [ ] **Verify App Check Configuration**
  - **Why:** App Check prevents unauthorized API access but must not block legitimate users
  - **Where:** `lib/services/app_check_service.dart`, Firebase Console (reCAPTCHA v3 setup)
  - **Done:** App Check enabled, reCAPTCHA secret configured, no false positives in production

- [ ] **Review Firestore Security Rules**
  - **Why:** Security rules are the last line of defense against unauthorized data access
  - **Where:** `firestore.rules` (916 lines), audit against `PRODUCT_AUDIT_REPORT.md`
  - **Done:** All collections have proper facility-scoped access, role-based permissions enforced, super admin access verified

- [ ] **Verify Firebase Storage Rules**
  - **Why:** Prevent unauthorized file access/downloads
  - **Where:** `storage.rules`
  - **Done:** User-scoped uploads protected, facility-scoped files require owner access, no public read access to sensitive files

- [ ] **Test 2FA OTP Flow End-to-End**
  - **Why:** 2FA is implemented but needs verification it works correctly
  - **Where:** `functions/src/index.ts` (generateOTP, verifyOTP), `lib/services/two_factor_service.dart`
  - **Done:** OTP generation works, email delivery works, verification works, rate limiting prevents abuse, expiration works (10 minutes)

- [ ] **Confirm Super Admin Access**
  - **Why:** Super admin must be able to access all facilities for support/debugging
  - **Where:** `firestore.rules` (lines 44-57), `functions/src/index.ts` (getSuperAdminEmails)
  - **Done:** Super admin emails hardcoded correctly, Firestore rules allow access, Cloud Functions respect super admin status

---

### Multi-Facility Selector

- [ ] **Verify Facility Selector on All Screens**
  - **Why:** Users with multiple facilities must be able to switch context consistently
  - **Where:** `lib/widgets/facility_switcher.dart`, all authenticated screen files
  - **Done:** Facility selector appears on dashboard, tenant list, payment list, and all other authenticated screens

- [ ] **Test Facility Switching**
  - **Why:** Switching facilities must not break state or leak data between facilities
  - **Where:** `lib/providers/active_facility_provider.dart`, all screens that use facility-scoped data
  - **Done:** Switching facilities updates all queries correctly, no data from previous facility visible, state resets properly

- [ ] **Verify Facility-Scoped Queries**
  - **Why:** All data queries must filter by facilityId to prevent cross-facility data leaks
  - **Where:** All service files (`tenant_service.dart`, `payment_service.dart`, `unit_service.dart`, etc.)
  - **Done:** All Firestore queries include `where('facilityId', isEqualTo: facilityId)`, no queries return data from wrong facility

- [ ] **Test Multi-Facility User Access**
  - **Why:** Users with access to multiple facilities must see correct data for each
  - **Where:** Test with user who has owner role in Facility A and manager role in Facility B
  - **Done:** User sees only facilities they have access to, switching works, permissions enforced per facility

---

### Core Tenant Lifecycle

- [ ] **Test Tenant Creation**
  - **Why:** Tenant creation is the foundation of all operations
  - **Where:** `lib/screens/tenant_creation_screen.dart`
  - **Done:** All fields save correctly (basic info, contacts, vehicles, portal access, e-sign), validation works, required fields enforced

- [ ] **Verify CSV Import Wizard**
  - **Why:** Bulk import is critical for onboarding existing facilities
  - **Where:** `lib/screens/tenant_csv_import_wizard_screen.dart`
  - **Done:** All 5 steps work (upload, map, preview, duplicates, results), auto-mapping works, validation catches errors, duplicates handled correctly

- [ ] **Test Tenant Editing**
  - **Why:** Tenant data changes frequently, editing must preserve all fields
  - **Where:** `lib/screens/tenant_edit_screen.dart`, `lib/services/tenant_service.dart` (updateTenant)
  - **Done:** All fields editable, changes save correctly, audit log created, no data loss

- [ ] **Verify Move-In Workflow**
  - **Why:** Move-in creates contract and updates unit status - critical workflow
  - **Where:** `lib/screens/move_in_wizard_screen.dart`, `functions/src/index.ts` (completePublicMoveIn)
  - **Done:** Move-in creates tenant, creates contract, assigns unit, updates unit status to occupied, generates initial charges

- [ ] **Test Move-Out Workflow**
  - **Why:** Move-out calculates final charges and refunds - must be accurate
  - **Where:** `lib/screens/move_out_screen.dart`, `functions/src/index.ts` (processMoveOut)
  - **Done:** Move-out calculates charges correctly, processes refunds, updates unit status to available, creates final invoice

- [ ] **Confirm Tenant Archiving**
  - **Why:** Archiving must preserve historical data for reporting/audit
  - **Where:** `lib/services/tenant_service.dart` (archiveTenant or similar)
  - **Done:** Archiving sets isActive=false, historical payments/contracts remain linked, reports still include archived tenants where appropriate

---

### Billing & Payments

- [ ] **Test Stripe Connect Onboarding**
  - **Why:** Facilities need Stripe Connect to process payments
  - **Where:** `lib/screens/stripe_connect_onboarding_screen.dart`, `functions/src/index.ts` (createStripeConnectAccount, createStripeConnectAccountLink)
  - **Done:** Onboarding flow works, account link generated, facility can complete Stripe onboarding, account status tracked correctly

- [ ] **Verify Payment Recording**
  - **Why:** Manual payment recording must create correct ledger entries
  - **Where:** `lib/screens/payment_creation_screen.dart`, `lib/services/payment_service.dart`, `lib/services/ledger_service.dart`
  - **Done:** Payment creates ledger entry, balance updates correctly, payment linked to tenant, allocation to invoices works

- [ ] **Test Autopay Processing**
  - **Why:** Autopay runs daily via scheduled function - must work reliably
  - **Where:** `functions/src/index.ts` (processAutopayPayments, scheduled daily at 2 AM UTC)
  - **Done:** Scheduled function runs, processes autopay payments, charges payment methods, creates payment records, sends receipts

- [ ] **Verify Payment Allocation**
  - **Why:** Payments must be allocated to invoices correctly for accounting
  - **Where:** `lib/services/payment_service.dart`, `lib/services/invoice_service.dart`
  - **Done:** Payment allocation works, invoice status updates to paid, ledger entries linked correctly

- [ ] **Test Refund Processing**
  - **Why:** Refunds must process through Stripe and update records correctly
  - **Where:** `lib/screens/payment_detail_screen.dart`, `functions/src/index.ts` (processRefund)
  - **Done:** Refund creates Stripe refund, updates payment status, creates ledger entry, updates tenant balance

- [ ] **Confirm Invoice PDF Generation**
  - **Why:** Invoices must generate PDFs for download/email
  - **Where:** `lib/services/invoice_service.dart` or similar, check for PDF generation
  - **Done:** Invoice PDFs generate correctly, include all line items, facility branding, download works

- [ ] **Test Receipt Download**
  - **Why:** Receipts must be downloadable for tenant records
  - **Where:** `lib/screens/payment_detail_screen.dart` (_downloadReceipt method)
  - **Done:** Receipt download works, opens PDF/URL correctly, receiptUrl field populated for Stripe payments

---

### Messaging (Twilio SMS)

- [ ] **Verify SMS Sending**
  - **Why:** SMS is core communication channel - must work reliably
  - **Where:** `functions/src/index.ts` (sendSMS), `lib/services/sms_service.dart`
  - **Done:** SMS sends via Cloud Function, Twilio API called correctly, message delivered, message log created

- [ ] **Test STOP/HELP Keywords**
  - **Why:** STOP/HELP handling is required for Twilio A2P compliance
  - **Where:** `functions/src/index.ts` (handleIncomingSMS, around line 8683)
  - **Done:** STOP keyword opts tenant out (sets smsOptOut=true), HELP keyword sends help message, opt-out persists, no SMS sent after STOP

- [ ] **Confirm Opt-Out Enforcement**
  - **Why:** Opted-out tenants must not receive SMS
  - **Where:** `functions/src/index.ts` (sendSMS function checks smsOptOut), `lib/models/tenant_model.dart` (smsOptOut field)
  - **Done:** SMS sending checks smsOptOut before sending, throws error if opted out, bulk messaging respects opt-outs

- [ ] **Test SMS Conversation Threading**
  - **Why:** SMS conversations must thread correctly for context
  - **Where:** `lib/services/sms_conversation_service.dart`, `lib/screens/sms_conversations_screen.dart`
  - **Done:** Conversations thread by phone number, messages ordered correctly, conversation list shows latest message

- [ ] **Verify SMS Usage Limits**
  - **Why:** Usage limits prevent overage charges
  - **Where:** `functions/src/index.ts` (getSMSUsageStatus, resetMonthlySMSUsage), `lib/services/sms_usage_service.dart`
  - **Done:** Usage tracked per facility, limits enforced, monthly reset works (scheduled function), usage warnings shown

- [ ] **Test Bulk Messaging Opt-Outs**
  - **Why:** Bulk messaging must respect individual opt-outs
  - **Where:** `lib/screens/bulk_messaging_screen.dart`, `lib/services/bulk_messaging_service.dart`
  - **Done:** Bulk messaging skips opted-out tenants, shows count of skipped tenants, only sends to opted-in tenants

- [ ] **Confirm Message Logs**
  - **Why:** Message logs provide audit trail and per-tenant history
  - **Where:** `functions/src/index.ts` (createOrUpdateMessageLog), `lib/services/tenant_message_history_service.dart`
  - **Done:** All SMS creates message log, logs stored in Firestore, per-tenant history aggregates correctly, logs visible in UI

---

### Email (SendGrid)

- [ ] **Test Email Sending**
  - **Why:** Email is primary communication channel
  - **Where:** `functions/src/index.ts` (sendEmail), `lib/services/email_service.dart`
  - **Done:** Email sends via Cloud Function, SendGrid API called correctly, email delivered, message log created

- [ ] **Verify Facility Branding**
  - **Why:** Emails must appear from facility, not generic platform
  - **Where:** `functions/src/index.ts` (sendEmail uses facility data), facility model (fromName, replyTo fields)
  - **Done:** From name uses facility name, reply-to uses facility email, branding consistent across all emails

- [ ] **Test Email Templates**
  - **Why:** Templates with variables enable personalized bulk emails
  - **Where:** `lib/services/email_template_service.dart`, `lib/services/template_renderer.dart`
  - **Done:** Templates render variables correctly ({{tenantName}}, {{amount}}, etc.), HTML and text versions work, preview shows rendered content

- [ ] **Confirm Email Sequences**
  - **Why:** Email sequences automate multi-step communications
  - **Where:** `lib/services/email_sequence_service.dart`, `lib/screens/email_sequence_management_screen.dart`
  - **Done:** Sequences send steps in order, delays work correctly, sequences complete, can be triggered manually or automatically

- [ ] **Verify Email Usage Tracking**
  - **Why:** Usage tracking prevents overage and shows facility usage
  - **Where:** `lib/services/email_usage_service.dart`, `lib/widgets/email_usage_card.dart`
  - **Done:** Usage tracked per facility per month, usage cards show current usage, limits visible, warnings shown when approaching limits

- [ ] **Test Email Digests**
  - **Why:** Daily digests summarize activity for facility managers
  - **Where:** `functions/src/index.ts` (sendDigest, sendDailyDigests scheduled function)
  - **Done:** Digests generate correctly, include recent activity, send at configured time, recipients configurable

---

## Priority 2: Important Polish (Complete Before Public Launch)

### Documents

- [ ] **Test Document Upload**
  - **Why:** Documents (contracts, invoices, attachments) must upload correctly
  - **Where:** `lib/services/document_service.dart`, Firebase Storage
  - **Done:** Documents upload to Storage, progress shown, file size limits enforced, file types validated

- [ ] **Verify Document Permissions**
  - **Why:** Documents must be facility-scoped and access-controlled
  - **Where:** `storage.rules`, `lib/services/document_service.dart`
  - **Done:** Documents stored in facility-scoped paths, only facility owners/managers can upload, tenants can view their own documents

- [ ] **Test Document Download/View**
  - **Why:** Documents must be viewable/downloadable in tenant portal
  - **Where:** `lib/screens/tenant_portal_screen.dart`, `lib/services/document_service.dart`
  - **Done:** Tenants can view/download their documents, signed URLs work, access restricted to tenant's own documents

- [ ] **Confirm Document Retention**
  - **Why:** Document retention policies must be clear and enforced
  - **Where:** Document service, check for deletion/archival logic
  - **Done:** Retention policies documented, documents archived (not deleted) when tenant archived, historical documents preserved

---

### Admin Settings

- [ ] **Test Facility Profile Editing**
  - **Why:** Facility settings control branding, billing, and operations
  - **Where:** `lib/screens/facility_edit_screen.dart`, `lib/services/facility_service.dart`
  - **Done:** All fields editable (name, address, logo, business hours, gate hours), logo upload works, changes save correctly

- [ ] **Verify Staff Management**
  - **Why:** Staff invites and role management enable team collaboration
  - **Where:** `lib/screens/permission_management_screen.dart`, `lib/services/permission_service.dart`
  - **Done:** Invites sent via email, roles assigned correctly (owner/manager/employee), permissions enforced, invites can be accepted

- [ ] **Test Billing Settings**
  - **Why:** Billing settings control late fees, tax, grace periods
  - **Where:** `lib/screens/facility_edit_screen.dart` (billing settings section)
  - **Done:** Late fee settings save, tax rate configurable, grace period works, settings applied to new charges

- [ ] **Confirm Insurance Settings**
  - **Why:** Insurance settings control TPP defaults and auto-enrollment
  - **Where:** `lib/screens/insurance_settings_screen.dart`, `lib/services/insurance_service.dart`
  - **Done:** TPP defaults configurable, auto-enrollment works, compliance checks run, settings applied to new tenants

---

### UX Polish

- [ ] **Add Loading States**
  - **Why:** Users need feedback during async operations
  - **Where:** All screen files with async operations
  - **Done:** Loading indicators shown during API calls, buttons disabled during submission, progress shown for long operations

- [ ] **Add Empty States**
  - **Why:** Empty lists need helpful messaging, not blank screens
  - **Where:** All list screens (tenants, payments, units, contracts, etc.)
  - **Done:** Empty states show helpful message and CTA (e.g., "No tenants yet. Create your first tenant."), icons/graphics included

- [ ] **Improve Error Messages**
  - **Why:** Error messages must be user-friendly and actionable
  - **Where:** `lib/utils/error_message_helper.dart`, all error handling
  - **Done:** ErrorMessageHelper used consistently, messages are clear and actionable, technical errors translated to user-friendly text

- [ ] **Test Mobile Responsiveness**
  - **Why:** App must work on tablets and mobile devices
  - **Where:** All screen files, test on various screen sizes
  - **Done:** Layouts adapt to screen size, navigation works on mobile, forms usable on small screens, no horizontal scrolling

- [ ] **Verify Keyboard Navigation**
  - **Why:** Keyboard navigation improves accessibility and power-user experience
  - **Where:** All forms and interactive elements
  - **Done:** Tab order logical, Enter submits forms, Escape closes dialogs, focus indicators visible

---

### Observability

- [ ] **Verify Audit Logs**
  - **Why:** Audit logs provide compliance and debugging capability
  - **Where:** `lib/services/audit_service.dart`, `lib/screens/audit_log_screen.dart`
  - **Done:** Critical operations logged (tenant CRUD, payment creation, settings changes), logs include before/after data, logs searchable/filterable

- [ ] **Test Error Reporting**
  - **Why:** Error reporting helps identify and fix issues quickly
  - **Where:** `functions/src/index.ts` (Sentry setup), check Sentry dashboard
  - **Done:** Sentry initialized, errors captured, sensitive data scrubbed, error alerts configured

- [ ] **Confirm Rate Limiting**
  - **Why:** Rate limiting prevents abuse and controls costs
  - **Where:** `functions/src/index.ts` (enforceRateLimit, enforceUserRateLimit), SMS/email usage services
  - **Done:** Rate limits enforced for SMS, email, API calls, limits configurable, users see rate limit errors clearly

- [ ] **Test Retry Logic**
  - **Why:** Retries handle transient failures gracefully
  - **Where:** Cloud Functions, check for retry logic in critical operations
  - **Done:** Failed Cloud Function calls retry appropriately, exponential backoff used, retry limits prevent infinite loops

---

## Priority 3: Nice-to-Have (Can Complete Post-Launch)

### Advanced Features

- [ ] **Portal Setup Intent for Payment Methods**
  - **Why:** Allows tenants to add/update payment methods from portal
  - **Where:** Tenant portal, requires Cloud Function + Stripe Elements integration
  - **Status:** Low priority, marked pending in existing todos

- [ ] **Portal Invoice/Receipt Download**
  - **Why:** Tenants need access to invoices/receipts from portal
  - **Where:** Tenant portal, can reuse existing receipt download logic
  - **Status:** Low priority, marked pending in existing todos

- [ ] **Advanced Reporting Customizations**
  - **Why:** Custom reports enable facility-specific analytics
  - **Where:** Reports service, would require report builder UI
  - **Status:** Post-launch feature

- [ ] **Multi-Currency Support**
  - **Why:** International facilities need currency support
  - **Where:** Payment models, invoice generation, would require currency conversion
  - **Status:** Post-launch feature

- [ ] **Accounting Software Integration**
  - **Why:** Integration with QuickBooks/Xero enables automated accounting
  - **Where:** Would require new integration service and API
  - **Status:** Post-launch feature

---

## Testing Checklist

### Critical Path Testing

1. **Auth & Security:**
   - [ ] Sign up new user
   - [ ] Sign in existing user
   - [ ] Test 2FA OTP flow
   - [ ] Verify super admin access
   - [ ] Test facility-scoped data access (try accessing wrong facility's data)

2. **Multi-Facility:**
   - [ ] Create user with access to 2+ facilities
   - [ ] Switch between facilities
   - [ ] Verify data changes with facility switch
   - [ ] Test facility selector on all screens

3. **Tenant Lifecycle:**
   - [ ] Create tenant with all fields
   - [ ] Import tenants via CSV
   - [ ] Edit tenant
   - [ ] Complete move-in workflow
   - [ ] Complete move-out workflow
   - [ ] Archive tenant

4. **Payments:**
   - [ ] Complete Stripe Connect onboarding
   - [ ] Record manual payment
   - [ ] Verify autopay processes (or test manually)
   - [ ] Process refund
   - [ ] Download receipt

5. **Messaging:**
   - [ ] Send SMS to tenant
   - [ ] Test STOP keyword (opt-out)
   - [ ] Test HELP keyword
   - [ ] Verify opted-out tenant cannot receive SMS
   - [ ] Send bulk SMS (verify opt-outs respected)
   - [ ] Send email
   - [ ] Use email template with variables

### Polish Testing

1. **Documents:**
   - [ ] Upload document
   - [ ] View document in tenant portal
   - [ ] Verify document permissions

2. **Settings:**
   - [ ] Edit facility profile
   - [ ] Invite staff member
   - [ ] Configure billing settings
   - [ ] Configure insurance settings

3. **UX:**
   - [ ] Test loading states (slow network)
   - [ ] Test empty states (new facility)
   - [ ] Test error handling (invalid input, network errors)
   - [ ] Test mobile responsiveness
   - [ ] Test keyboard navigation

---

## Acceptance Criteria Summary

**Ready for Launch When:**
- All Priority 1 items completed and tested
- All Priority 2 items completed and tested
- No critical bugs or security issues
- Performance acceptable (page loads < 3s, operations < 1s)
- Mobile experience functional
- Compliance pages published (Privacy, Terms, SMS Policy, Contact)
- SMS consent checkbox in tenant creation/edit
- STOP/HELP keywords working

**Can Launch Without:**
- Priority 3 items (nice-to-have features)
- Advanced reporting customizations
- Multi-currency support
- Accounting software integration
- Portal payment method management (can add post-launch)

---

## Notes

- This checklist is based on `PRODUCT_AUDIT_REPORT.md` and codebase analysis
- Items marked with "Done:" criteria should be verified through testing
- Some items may already be complete - verify before marking done
- Focus on Priority 1 items first, then Priority 2
- Priority 3 items can be added post-launch based on customer feedback
