# Storage Facility Creator - Product Capability Audit Report
**Generated:** January 23, 2026  
**Audit Type:** Code-Based Feature Inventory  
**Scope:** Implemented features only (no assumptions)

---

## Executive Summary

Storage Facility Creator is a SaaS platform built with Flutter Web and Firebase, designed for self-storage facility management. The application provides comprehensive tenant management, billing, payments, messaging, document handling, and automation features. It integrates with Stripe (payments/Connect), SendGrid (email), and Twilio (SMS). The platform uses a multi-tenant architecture with facility-scoped data and supports role-based access control (owner, manager, employee, tenant).

**Key Technologies:**
- Frontend: Flutter Web (Dart 3.0+)
- Backend: Firebase (Auth, Firestore, Storage, Cloud Functions, Hosting)
- State Management: Riverpod 2.x
- Routing: go_router
- Integrations: Stripe, SendGrid, Twilio

---

## 1. Repository Map

### App Type
- **Platform:** Flutter Web application
- **Entry Point:** `lib/main.dart` (SFCApp widget)
- **State Management:** Riverpod 2.x with providers
- **Routing:** go_router (declarative routing with guards)
- **Build System:** Flutter build system, outputs to `build/web`
- **Deployment:** Firebase Hosting (configured in `firebase.json`)

### Environment Configuration
- **Firebase Config:** `lib/firebase_options.dart` (auto-generated)
- **Emulator Support:** `lib/config/firebase_emulator_config.dart` (debug mode only)
- **Secrets Management:** Firebase Functions secrets (SENDGRID_API_KEY, STRIPE_SECRET_KEY, TWILIO_AUTH_TOKEN)
- **App Check:** Enabled with reCAPTCHA v3 (`lib/services/app_check_service.dart`)

### Build & Deploy
- **Build Command:** `flutter build web --release`
- **Deploy Script:** `deploy.ps1` (PowerShell)
- **Hosting Config:** `firebase.json` (SPA rewrite rules, security headers, CSP)

**Evidence:**
- `pubspec.yaml` (lines 1-95): Dependencies and Flutter config
- `lib/main.dart` (lines 27-226): Bootstrap and initialization
- `firebase.json`: Hosting, Firestore, Storage, Functions config

---

## 2. UI / Screens Inventory

### Public Routes (No Authentication)
| Screen | Route | Purpose | Evidence |
|--------|-------|---------|----------|
| Marketing Landing | `/` | Public marketing page | `lib/router/app_router.dart:155`, `lib/screens/marketing_landing_page.dart` |
| Login | `/login` | User authentication | `lib/router/app_router.dart:158`, `lib/screens/auth/login_screen.dart` |
| Signup | `/signup` | User registration | `lib/router/app_router.dart:163`, `lib/screens/auth/signup_screen.dart` |
| Forgot Password | `/forgot-password` | Password reset | `lib/router/app_router.dart:168`, `lib/screens/auth/forgot_password_screen.dart` |
| Email Verification | `/verify-email` | Email verification | `lib/router/app_router.dart:173`, `lib/screens/auth/email_verification_screen.dart` |
| Accept Invite | `/accept-invite` | Accept facility invite | `lib/router/app_router.dart:299`, `lib/screens/accept_invite_screen.dart` |
| Tenant Portal Access | `/tenant-portal` | Tenant login portal | `lib/router/app_router.dart:185`, `lib/screens/tenant_portal_access_screen.dart` |
| Contract Signing | `/contracts/sign?token=...` | Public contract signing | `lib/router/app_router.dart:190`, `lib/screens/contract_signing_screen.dart` |
| Public Payment | `/pay?token=...` | Public payment link | `lib/router/app_router.dart:737`, `lib/screens/public_payment_screen.dart` |
| Public Rental Portal | `/rental?facilityId=...` | Public rental inquiry | `lib/router/app_router.dart:201`, `lib/screens/public_rental_portal_screen.dart` |
| Public Move-In | `/public-move-in?token=...` | Public move-in flow | `lib/router/app_router.dart:209`, `lib/screens/public_move_in_screen.dart` |
| Public Facility Page | `/facility/:facilityId` | Public facility info | `lib/router/app_router.dart:220`, `lib/screens/public_facility_page_screen.dart` |

### Authenticated Routes (Main Application)
| Screen | Route | Purpose | User Type | Evidence |
|--------|-------|---------|-----------|----------|
| Dashboard | `/dashboard` | Main dashboard | Owner/Manager/Staff | `lib/router/app_router.dart:317`, `lib/screens/home_screen_modern.dart` |
| Facilities | `/facilities` | Facility list | Owner | `lib/router/app_router.dart:322`, `lib/screens/facility_management_screen.dart` |
| Facility Create | `/facilities/create` | Create facility | Owner | `lib/router/app_router.dart:327`, `lib/screens/facility_creation_wizard.dart` |
| Facility Edit | `/facilities/:id/edit` | Edit facility | Owner | `lib/screens/facility_edit_screen.dart` |
| Tenants | `/tenants` | Tenant list | Owner/Manager/Staff | `lib/router/app_router.dart:337`, `lib/screens/client_list_screen.dart` |
| Tenant Detail | `/tenants/detail` | Tenant details | Owner/Manager/Staff | `lib/router/app_router.dart:359`, `lib/screens/client_detail_screen.dart` |
| Tenant CSV Import | `/tenants/import-csv` | Bulk import | Owner/Manager/Staff | `lib/router/app_router.dart:342`, `lib/screens/tenant_csv_import_wizard_screen.dart` |
| Tenant Ledger | `/tenants/:tenantId/ledger` | Tenant ledger | Owner/Manager/Staff | `lib/router/app_router.dart:370`, `lib/screens/ledger_screen.dart` |
| Contact Logs | `/contact-logs` | Contact history | Owner/Manager/Staff | `lib/router/app_router.dart:409`, `lib/screens/contact_logs_screen.dart` |
| Transfer Workflow | `/transfer` | Unit transfer | Owner/Manager/Staff | `lib/router/app_router.dart:426`, `lib/screens/transfer_workflow_screen.dart` |
| Units | `/units` | Units landing | Owner/Manager/Staff | `lib/router/app_router.dart:443`, `lib/screens/unit_detail_screen.dart` (landing) |
| Units Map | `/units/map` | Visual unit map | Owner/Manager/Staff | `lib/router/app_router.dart:448`, `lib/screens/facility_map_editor_screen.dart` |
| Unit Detail | `/units/detail` | Unit details | Owner/Manager/Staff | `lib/router/app_router.dart:459`, `lib/screens/unit_detail_screen.dart` |
| Contracts | `/contracts` | Contract list | Owner/Manager/Staff | `lib/router/app_router.dart:485`, `lib/screens/contract_list_screen.dart` |
| Contract Detail | `/contracts/detail` | Contract details | Owner/Manager/Staff | `lib/router/app_router.dart:514`, `lib/screens/contract_detail_screen.dart` |
| Contract Create | `/contracts/create` | Create contract | Owner/Manager/Staff | `lib/router/app_router.dart:490`, `lib/screens/contract_creation_screen.dart` |
| Contract Templates | `/contracts/templates` | Template management | Owner/Manager/Staff | `lib/router/app_router.dart:498`, `lib/screens/contract_template_management_screen.dart` |
| Lease Templates | `/lease-templates` | E-sign templates | Owner/Manager/Staff | `lib/router/app_router.dart:503`, `lib/screens/lease_templates_screen.dart` |
| Payments | `/payments` | Payment list | Owner/Manager/Staff | `lib/router/app_router.dart:535`, `lib/screens/payment_list_screen.dart` |
| Payment Detail | `/payments/detail` | Payment details | Owner/Manager/Staff | `lib/router/app_router.dart:540`, `lib/screens/payment_detail_screen.dart` |
| Payment Create | `/payments/create` | Record payment | Owner/Manager/Staff | `lib/router/app_router.dart:551`, `lib/screens/payment_creation_screen.dart` |
| Invoices | `/invoices` | Invoice list | Owner/Manager/Staff | `lib/router/app_router.dart:1031`, `lib/screens/invoice_list_screen.dart` |
| Invoice Detail | `/invoices/detail` | Invoice details | Owner/Manager/Staff | `lib/router/app_router.dart:1036`, `lib/screens/invoice_detail_screen.dart` |
| Deposits | `/deposits` | Deposit list | Owner/Manager/Staff | `lib/router/app_router.dart:1102`, `lib/screens/deposit_list_screen.dart` |
| Deposit Detail | `/deposits/detail` | Deposit details | Owner/Manager/Staff | `lib/router/app_router.dart:1107`, `lib/screens/deposit_detail_screen.dart` |
| Deposit Create | `/deposits/create` | Create deposit | Owner/Manager/Staff | `lib/router/app_router.dart:1124`, `lib/screens/deposit_creation_screen.dart` |
| Liens | `/liens` | Lien list | Owner/Manager/Staff | `lib/router/app_router.dart:1054`, `lib/screens/lien_list_screen.dart` |
| Lien Detail | `/liens/detail` | Lien details | Owner/Manager/Staff | `lib/router/app_router.dart:1059`, `lib/screens/lien_detail_screen.dart` |
| Reminders | `/reminders` | Reminder list | Owner/Manager/Staff | `lib/router/app_router.dart:882`, `lib/screens/reminder_list_screen.dart` |
| Reminder Create | `/reminders/create` | Create reminder | Owner/Manager/Staff | `lib/router/app_router.dart:887`, `lib/screens/reminder_creation_screen.dart` |
| Reminder Detail | `/reminders/detail` | Reminder details | Owner/Manager/Staff | `lib/router/app_router.dart:895`, `lib/screens/reminder_detail_screen.dart` |
| Reminder Schedule | `/reminders/schedule` | Schedule management | Owner/Manager/Staff | `lib/router/app_router.dart:906`, `lib/screens/reminder_schedule_screen.dart` |
| DNR List | `/dnr` | Do Not Rent list | Owner/Manager/Staff | `lib/router/app_router.dart:918`, `lib/screens/dnr_list_screen.dart` |
| Delinquency Dashboard | `/delinquency` | Late payments | Owner/Manager/Staff | `lib/router/app_router.dart:559`, `lib/screens/late_dashboard_screen.dart` |
| Gate Access | `/access` | Gate codes | Owner/Manager/Staff | `lib/router/app_router.dart:564`, `lib/screens/gate_access_screen.dart` |
| Messaging | `/messaging` | Team messaging | Owner/Manager/Staff | `lib/router/app_router.dart:579`, `lib/screens/messaging_screen.dart` |
| SMS Conversations | `/messaging/sms` | SMS threads | Owner/Manager/Staff | `lib/router/app_router.dart:590`, `lib/screens/sms_conversations_screen.dart` |
| Bulk Messaging | `/communications/bulk-messaging` | Bulk send | Owner/Manager/Staff | `lib/router/app_router.dart:710`, `lib/screens/bulk_messaging_screen.dart` |
| Email Templates | `/templates/email` | Email templates | Owner/Manager/Staff | `lib/router/app_router.dart:721`, `lib/screens/email_template_management_screen.dart` |
| SMS Templates | `/templates/sms` | SMS templates | Owner/Manager/Staff | `lib/router/app_router.dart:729`, `lib/screens/sms_template_management_screen.dart` |
| Reports | `/reports` | Financial reports | Owner/Manager/Staff | `lib/router/app_router.dart:803`, `lib/screens/financial_reports_screen.dart` |
| Reports Consolidated | `/reports/consolidated` | All reports | Owner/Manager/Staff | `lib/router/app_router.dart:813`, `lib/screens/reports_consolidated_screen.dart` |
| Communication Analytics | `/analytics/communication` | Communication stats | Owner/Manager/Staff | `lib/router/app_router.dart:818`, `lib/screens/communication_analytics_screen.dart` |
| Documents | `/documents` | Document center | Owner/Manager/Staff | `lib/router/app_router.dart:826`, `lib/screens/document_center_screen.dart` |
| Settings | `/settings` | App settings | Owner/Manager/Staff | `lib/router/app_router.dart:601`, `lib/screens/settings_screen.dart` |
| Profile Edit | `/settings/profile` | User profile | All | `lib/router/app_router.dart:700`, `lib/screens/profile_edit_screen.dart` |
| Appearance Settings | `/settings/appearance` | Theme/locale | All | `lib/router/app_router.dart:705`, `lib/screens/appearance_settings_screen.dart` |
| Notification Settings | `/settings/notifications` | Notifications | Owner/Manager/Staff | `lib/router/app_router.dart:689`, `lib/screens/notification_settings_screen.dart` |
| Permission Management | `/permissions` | Role management | Owner | `lib/router/app_router.dart:606`, `lib/screens/permission_management_screen.dart` |
| Stripe Connect | `/stripe-connect` | Payment setup | Owner | `lib/router/app_router.dart:611`, `lib/screens/stripe_connect_onboarding_screen.dart` |
| Payment Links | `/payment-links` | Payment link mgmt | Owner/Manager/Staff | `lib/router/app_router.dart:745`, `lib/screens/payment_links_management_screen.dart` |
| Coupons | `/coupons` | Coupon management | Owner/Manager/Staff | `lib/router/app_router.dart:756`, `lib/screens/coupon_management_screen.dart` |
| Insurance | `/insurance` | Insurance overview | Owner/Manager/Staff | `lib/router/app_router.dart:525`, `lib/screens/insurance_screen.dart` |
| Insurance Settings | `/settings/insurance` | Insurance config | Owner/Manager/Staff | `lib/router/app_router.dart:667`, `lib/screens/insurance_settings_screen.dart` |
| Insurance Report | `/reports/insurance` | Insurance report | Owner/Manager/Staff | `lib/router/app_router.dart:678`, `lib/screens/insurance_report_screen.dart` |
| Claims | `/claims` | Claims list | Owner/Manager/Staff | `lib/router/app_router.dart:764`, `lib/screens/claims_list_screen.dart` |
| Claim Detail | `/claims/:id` | Claim details | Owner/Manager/Staff | `lib/router/app_router.dart:775`, `lib/screens/claim_detail_screen.dart` |
| Move-In Wizard | `/move-in` | Move-in workflow | Owner/Manager/Staff | `lib/router/app_router.dart:1014`, `lib/screens/move_in_wizard_screen.dart` |
| Move-Out | `/move-out` | Move-out workflow | Owner/Manager/Staff | `lib/router/app_router.dart:999`, `lib/screens/move_out_screen.dart` |
| Recurring Charges | `/recurring-charges` | Recurring items | Owner/Manager/Staff | `lib/router/app_router.dart:1097`, `lib/screens/recurring_charges_screen.dart` |
| Inventory | `/inventory` | Inventory list | Owner/Manager/Staff | `lib/router/app_router.dart:1077`, `lib/screens/inventory_list_screen.dart` |
| POS | `/pos` | Point of sale | Owner/Manager/Staff | `lib/router/app_router.dart:1082`, `lib/screens/pos_screen.dart` |
| Yield Management | `/yield` | Pricing optimization | Owner/Manager/Staff | `lib/router/app_router.dart:877`, `lib/screens/yield_management_screen.dart` |
| API Keys | `/api-keys` | API key management | Owner | `lib/router/app_router.dart:848`, `lib/screens/api_keys_management_screen.dart` |
| Webhooks | `/webhooks` | Webhook management | Owner | `lib/router/app_router.dart:859`, `lib/screens/webhooks_management_screen.dart` |
| Email Sequences | `/email-sequences` | Email automation | Owner/Manager/Staff | `lib/router/app_router.dart:272`, `lib/screens/email_sequence_management_screen.dart` |
| Escalation Workflows | `/automation/escalations` | Escalation rules | Owner/Manager/Staff | `lib/router/app_router.dart:260`, `lib/screens/escalation_workflow_management_screen.dart` |
| Conditional Rules | `/automation/conditional-rules` | Conditional automation | Owner/Manager/Staff | `lib/router/app_router.dart:266`, `lib/screens/conditional_rules_management_screen.dart` |
| Report Scheduling | `/report-scheduling` | Scheduled reports | Owner/Manager/Staff | `lib/router/app_router.dart:232`, `lib/screens/report_scheduling_management_screen.dart` |
| AI Assistant | `/ai-assistant` | AI assistant | Owner/Manager/Staff | `lib/router/app_router.dart:798`, `lib/screens/ai_assistant_screen.dart` |
| Data Integrity | `/data-integrity` | Data validation | Owner | `lib/router/app_router.dart:928`, `lib/screens/data_integrity_screen.dart` |
| Subscription Test | `/subscription` | Subscription testing | Owner | `lib/router/app_router.dart:923`, `lib/screens/subscription_test_screen.dart` |

**Total Screens:** 70+ unique screens/routes

---

## 3. Core Domains & Features

### 3.1 Authentication & Roles/Permissions

**Status:** ✅ **Implemented**

**Features:**
- Firebase Authentication (email/password)
- Email verification
- Password reset
- Role-based access control (Owner, Manager, Employee)
- Super admin support (hardcoded emails)
- Facility-scoped permissions
- Invite system (email-based invites with role assignment)
- User profile management

**Evidence:**
- `lib/services/auth_service.dart`: Authentication logic
- `lib/providers/auth_provider.dart`: Auth state management
- `firestore.rules` (lines 44-57): Super admin check
- `firestore.rules` (lines 533-568): Invite system rules
- `lib/screens/auth/`: Login, signup, forgot password, email verification
- `lib/screens/permission_management_screen.dart`: Role management UI
- `lib/services/permission_service.dart`: Permission checks

**How It Works:**
- Users authenticate via Firebase Auth
- Roles stored in `facilities/{facilityId}` document (`roles` map)
- Firestore security rules enforce access based on `ownerUid`, `managers`, and `roles`
- Invites created in `facilities/{facilityId}/invites` collection

---

### 3.2 Facility Settings & Branding

**Status:** ✅ **Implemented**

**Features:**
- Facility creation wizard
- Facility editing (name, address, phone, email, description)
- Logo upload
- Business hours configuration
- Gate hours configuration
- Billing settings (late fees, tax rate, grace period)
- Insurance settings (TPP defaults, auto-enrollment)
- Timezone configuration
- Default locale/language
- Stripe Connect account linking
- Facility archiving (soft delete)

**Evidence:**
- `lib/models/facility_model.dart`: Facility data model
- `lib/screens/facility_creation_wizard.dart`: Creation flow
- `lib/screens/facility_edit_screen.dart`: Edit UI
- `lib/services/facility_service.dart`: CRUD operations
- `firestore.rules` (lines 192-214): Facility access rules

**How It Works:**
- Facilities stored in `facilities/{facilityId}` collection
- Owner can create/edit facilities
- Settings stored in facility document (`billingSettings`, `insuranceSettings`, etc.)
- Logo stored in Firebase Storage at `facilities/{facilityId}/logo`

---

### 3.3 Tenant Management

**Status:** ✅ **Implemented**

**Features:**
- Create/edit/archive tenants
- Tenant detail view (comprehensive)
- CSV bulk import wizard (5-step process)
- Contact information (emergency contacts)
- Vehicle information
- Occupant management (authorized users)
- Address management (mailing + alternate)
- Government ID tracking
- Portal access (access code-based)
- Portal visit tracking
- Notes and custom fields
- Lead source tracking
- Preferred locale/language
- Insurance status tracking
- Delinquency status tracking
- DNR (Do Not Rent) flag

**Evidence:**
- `lib/models/tenant_model.dart`: Complete tenant model (lines 93-522)
- `lib/screens/client_list_screen.dart`: Tenant list
- `lib/screens/client_detail_screen.dart`: Tenant detail
- `lib/screens/tenant_csv_import_wizard_screen.dart`: CSV import
- `lib/services/tenant_service.dart`: CRUD operations
- `firestore.rules` (lines 216-272): Tenant access rules

**How It Works:**
- Tenants stored in `facilities/{facilityId}/tenants/{tenantId}`
- CSV import parses file, maps columns, validates, handles duplicates
- Portal access via email + access code (stored in tenant document)
- Contact logs stored in `facilities/{facilityId}/tenants/{tenantId}/contactLogs`

---

### 3.4 Units Management

**Status:** ✅ **Implemented**

**Features:**
- Unit list view
- Unit detail view
- Visual map editor (drag-and-drop unit shapes)
- Unit types (size, dimensions, pricing)
- Unit status (available, occupied, reserved, maintenance)
- Unit pricing (monthly rate, dynamic pricing support)
- Unit amenities/features
- Occupancy tracking
- Unit search and filtering

**Evidence:**
- `lib/models/unit_model.dart`: Unit data model
- `lib/screens/facility_map_editor_screen.dart`: Visual map editor
- `lib/screens/unit_detail_screen.dart`: Unit detail
- `lib/services/unit_service.dart`: CRUD operations
- `firestore.rules` (lines 274-276): Unit access rules

**How It Works:**
- Units stored in `facilities/{facilityId}/units/{unitId}`
- Map shapes stored in `facilities/{facilityId}/mapShapes/{shapeId}`
- Map editor allows drawing rectangles, circles, polygons
- Units linked to tenants via contracts

---

### 3.5 Billing & Invoices/Ledger

**Status:** ✅ **Implemented**

**Features:**
- Invoice creation and management
- Invoice PDF generation
- Ledger entries (charges, payments, credits, refunds)
- Recurring charges setup
- Invoice line items
- Payment allocation to invoices
- Ledger balance calculation
- Invoice status tracking (draft, sent, paid, overdue, voided)
- Deposit management (security deposits)
- Deposit refunds

**Evidence:**
- `lib/models/invoice_model.dart`: Invoice model
- `lib/models/ledger_entry_model.dart`: Ledger entry model
- `lib/models/deposit_model.dart`: Deposit model
- `lib/screens/invoice_list_screen.dart`: Invoice list
- `lib/screens/invoice_detail_screen.dart`: Invoice detail
- `lib/screens/ledger_screen.dart`: Ledger view
- `lib/screens/deposit_list_screen.dart`: Deposit list
- `lib/services/invoice_service.dart`: Invoice operations
- `lib/services/ledger_service.dart`: Ledger operations
- `lib/services/deposit_service.dart`: Deposit operations
- `firestore.rules` (lines 671-703): Ledger rules
- `firestore.rules` (lines 705-707): Invoice rules
- `firestore.rules` (lines 709-711): Deposit rules

**How It Works:**
- Invoices stored in `facilities/{facilityId}/invoices/{invoiceId}`
- Ledger entries in `facilities/{facilityId}/ledgers/{ledgerId}`
- Deposits in `facilities/{facilityId}/deposits/{depositId}`
- Payments allocated to invoices via metadata
- Monthly rent charges generated via Cloud Function

---

### 3.6 Payments

**Status:** ✅ **Implemented**

**Features:**
- Payment recording (manual)
- Payment list and detail views
- Stripe integration (checkout sessions, payment intents)
- Stripe Connect (facility-specific payment processing)
- Payment method management (cards, ACH)
- Setup Intents (for saving payment methods)
- Autopay setup and processing
- Public payment links (token-based)
- Tenant portal payments
- Payment allocation to invoices
- Refund processing
- Payment status tracking

**Evidence:**
- `lib/models/payment_model.dart`: Payment model
- `lib/models/payment_method_model.dart`: Payment method model
- `lib/screens/payment_list_screen.dart`: Payment list
- `lib/screens/payment_detail_screen.dart`: Payment detail
- `lib/screens/payment_creation_screen.dart`: Create payment
- `lib/screens/public_payment_screen.dart`: Public payment link
- `lib/services/payment_service.dart`: Payment operations
- `lib/services/stripe_service.dart`: Stripe integration
- `lib/services/setup_intent_service.dart`: Setup Intents
- `lib/services/autopay_service.dart`: Autopay logic
- `functions/src/index.ts`:
  - `processStripePayment` (line 2965): Process payments
  - `createSetupIntent` (line 3155): Setup Intents
  - `attachPaymentMethod` (line 3259): Attach methods
  - `processAutopayPayments` (line 4819): Scheduled autopay
  - `createTenantPaymentCheckout` (line 7781): Tenant checkout
  - `createPublicPaymentCheckout` (line 8386): Public checkout
  - `processRefund` (line 4079): Refunds
- `firestore.rules` (lines 284-286): Payment rules

**How It Works:**
- Payments stored in `facilities/{facilityId}/payments/{paymentId}`
- Payment methods in `facilities/{facilityId}/tenants/{tenantId}/paymentMethods`
- Stripe Connect accounts linked to facilities (`stripeConnectAccountId`)
- Autopay runs daily via scheduled Cloud Function
- Public payment links use secure tokens

---

### 3.7 Messaging

**Status:** ✅ **Implemented**

**Features:**
- SMS sending (via Twilio)
- Email sending (via SendGrid)
- SMS conversation threads
- Team messaging (group and private conversations)
- Bulk messaging (to multiple tenants)
- Email templates (customizable)
- SMS templates (customizable)
- Email sequences (multi-step automation)
- Reminder system (scheduled reminders)
- Reminder schedules (recurring automation)
- Late notices (automated)
- Opt-out handling (DNR list, unsubscribe)
- Message history/logs (per tenant timeline)
- Contact logs (auto-created from communications)
- Communication analytics

**Evidence:**
- `lib/services/sms_service.dart`: SMS sending
- `lib/services/email_service.dart`: Email sending
- `lib/services/messaging_service.dart`: Team messaging
- `lib/services/sms_conversation_service.dart`: SMS threads
- `lib/services/bulk_messaging_service.dart`: Bulk operations
- `lib/services/email_template_service.dart`: Email templates
- `lib/services/sms_template_service.dart`: SMS templates
- `lib/services/email_sequence_service.dart`: Email sequences
- `lib/services/reminder_service.dart`: Reminders
- `lib/services/reminder_automation_service.dart`: Reminder automation
- `lib/services/contact_log_service.dart`: Contact logs
- `lib/services/tenant_message_history_service.dart`: Message history
- `lib/services/communication_analytics_service.dart`: Analytics
- `functions/src/index.ts`:
  - `sendSMS` (line 1697): SMS sending
  - `sendEmail` (line 417): Email sending
  - `handleIncomingSMS` (line 8683): Incoming SMS webhook
  - `processPaymentReminders` (line 5741): Payment reminders
  - `processDelinquencyAutomation` (line 3656): Late notices
- `firestore.rules` (lines 423-482): Reminder rules
- `firestore.rules` (lines 582-626): Messaging rules
- `firestore.rules` (lines 664-669): Message logs rules

**How It Works:**
- SMS sent via Twilio API (Cloud Function)
- Email sent via SendGrid API (Cloud Function)
- Message logs stored in `facilities/{facilityId}/messageLogs`
- SMS conversations in `facilities/{facilityId}/smsConversations`
- Team conversations in `facilities/{facilityId}/conversations`
- Reminders in `facilities/{facilityId}/reminders`
- Reminder schedules in `facilities/{facilityId}/reminderSchedules`
- Contact logs auto-created when sending to tenants
- DNR list prevents messaging to blocked tenants

---

### 3.8 Message History/Logs

**Status:** ✅ **Implemented**

**Features:**
- Per-tenant message timeline
- Message logs (all outbound communications)
- Contact log entries (auto-created)
- SMS conversation history
- Email tracking (opens, clicks - if SendGrid tracking enabled)
- Message status tracking (sent, delivered, failed)

**Evidence:**
- `lib/models/tenant_message_history_model.dart`: Message history model
- `lib/services/tenant_message_history_service.dart`: History service
- `lib/services/contact_log_service.dart`: Contact logs
- `functions/src/index.ts`: `createOrUpdateMessageLog` (line 196): Logging function
- `firestore.rules` (lines 664-669): Message logs rules
- `firestore.rules` (lines 219-243): Contact logs rules

**How It Works:**
- Message logs in `facilities/{facilityId}/messageLogs/{messageLogId}`
- Contact logs in `facilities/{facilityId}/tenants/{tenantId}/contactLogs`
- Tenant message history aggregated from logs
- Only Cloud Functions can write message logs (security)

---

### 3.9 CSV Import/Onboarding Wizard

**Status:** ✅ **Implemented**

**Features:**
- CSV file upload
- Column mapping (auto-detect + manual)
- Data validation
- Duplicate detection
- Preview before import
- Batch import with error handling
- Import results summary

**Evidence:**
- `lib/screens/tenant_csv_import_wizard_screen.dart`: 5-step wizard
- `lib/services/tenant_service.dart`: Import logic
- `pubspec.yaml` (line 37): `csv: ^6.0.0` dependency

**How It Works:**
- Step 1: Upload CSV
- Step 2: Map columns to tenant fields
- Step 3: Preview and validate
- Step 4: Handle duplicates (skip or update)
- Step 5: Import results

---

### 3.10 Documents

**Status:** ✅ **Implemented**

**Features:**
- Document upload (contracts, invoices, attachments)
- Document storage (Firebase Storage)
- Document categorization
- E-signature integration (Dropbox Sign)
- E-sign envelope creation
- E-sign status tracking
- PDF generation (invoices, contracts)
- Document attachments (to tenants, contracts, etc.)
- Document center (centralized view)

**Evidence:**
- `lib/models/document_attachment_model.dart`: Document model
- `lib/models/esign_envelope_model.dart`: E-sign model
- `lib/models/lease_template_model.dart`: Lease template model
- `lib/screens/document_center_screen.dart`: Document center
- `lib/screens/document_attachments_screen.dart`: Attachments
- `lib/services/document_service.dart`: Document operations
- `lib/services/esign_service.dart`: E-sign integration
- `functions/src/index.ts`:
  - `esignCreateEnvelope` (line 9242): Create e-sign envelope
  - `esignWebhookDropboxSign` (line 9370): E-sign webhook
  - `esignResendEnvelope` (line 9503): Resend envelope
  - `esignVoidEnvelope` (line 9561): Void envelope
- `firestore.rules` (lines 349-377): E-sign rules
- `firestore.rules` (lines 772-800): Document rules
- `storage.rules`: Storage access rules

**How It Works:**
- Documents stored in Firebase Storage: `facilities/{facilityId}/documents/{documentId}`
- E-sign envelopes in `facilities/{facilityId}/esignEnvelopes/{envelopeId}`
- Lease templates in `facilities/{facilityId}/leaseTemplates/{templateId}`
- Dropbox Sign API integration for e-signatures
- PDFs generated client-side using `pdf` package

---

### 3.11 Reporting/Analytics/Dashboards

**Status:** ✅ **Implemented**

**Features:**
- Financial reports (revenue, expenses, profit)
- Communication analytics (email/SMS stats)
- Insurance reports
- Lead source analytics
- Delinquency dashboard (late payments)
- Consolidated reports view
- Report scheduling (automated email delivery)
- Yield management (pricing optimization)
- Dashboard widgets (metrics, charts)

**Evidence:**
- `lib/screens/financial_reports_screen.dart`: Financial reports
- `lib/screens/reports_consolidated_screen.dart`: Consolidated view
- `lib/screens/communication_analytics_screen.dart`: Communication stats
- `lib/screens/insurance_report_screen.dart`: Insurance reports
- `lib/screens/lead_source_analytics_screen.dart`: Lead source analytics
- `lib/screens/late_dashboard_screen.dart`: Delinquency dashboard
- `lib/screens/report_scheduling_management_screen.dart`: Report scheduling
- `lib/screens/yield_management_screen.dart`: Yield management
- `lib/services/reports_service.dart`: Report generation
- `lib/services/communication_analytics_service.dart`: Analytics
- `lib/services/facility_stats_service.dart`: Facility statistics
- `lib/widgets/dashboard/`: Dashboard widgets (metric cards, charts)

**How It Works:**
- Reports generated from Firestore queries
- Analytics aggregated from message logs and payment data
- Scheduled reports sent via email (Cloud Function)
- Dashboard data cached for performance

---

### 3.12 Admin Tools, Audit Logs, Activity Logs

**Status:** ✅ **Partially Implemented**

**Features:**
- Audit logs (facility-scoped)
- Data integrity checks
- Super admin tools
- Activity feed (dashboard)
- Migration tools (Phase 2 migrations)

**Evidence:**
- `lib/services/audit_service.dart`: Audit logging
- `lib/screens/data_integrity_screen.dart`: Data validation
- `lib/services/superadmin_service.dart`: Super admin utilities
- `lib/widgets/dashboard/activity_feed.dart`: Activity feed
- `functions/src/index.ts`: `runPhase2Migrations` (line 8594): Migration function
- `firestore.rules` (lines 417-421, 632-657): Audit log rules

**Gaps:**
- Audit logs exist but may not be comprehensive across all operations
- Activity logs may be limited to dashboard feed only

---

## 4. Data Model / Firestore Schema

### Collections Structure

**Root Collections:**
- `users/{uid}` - User profiles
- `facilityCreatorAccounts/{accountId}` - SaaS account records
- `facilities/{facilityId}` - Facility documents
- `configs/{configId}` - System configuration (super admin only)
- `user_roles/{roleId}` - User role assignments

**Facility Subcollections:**
- `facilities/{facilityId}/tenants/{tenantId}` - Tenants
  - `contactLogs/{logId}` - Contact history
  - `paymentMethods/{methodId}` - Payment methods
- `facilities/{facilityId}/units/{unitId}` - Units
- `facilities/{facilityId}/contracts/{contractId}` - Contracts
- `facilities/{facilityId}/leases/{leaseId}` - Leases
- `facilities/{facilityId}/payments/{paymentId}` - Payments
- `facilities/{facilityId}/invoices/{invoiceId}` - Invoices
- `facilities/{facilityId}/ledgers/{ledgerId}` - Ledger entries
- `facilities/{facilityId}/deposits/{depositId}` - Deposits
- `facilities/{facilityId}/liens/{lienId}` - Liens
- `facilities/{facilityId}/claims/{claimId}` - Insurance claims
- `facilities/{facilityId}/reminders/{reminderId}` - Reminders
- `facilities/{facilityId}/reminderSchedules/{scheduleId}` - Reminder schedules
- `facilities/{facilityId}/gateAccess/{accessId}` - Gate access codes
- `facilities/{facilityId}/conversations/{conversationId}` - Team conversations
  - `messages/{messageId}` - Conversation messages
- `facilities/{facilityId}/smsConversations/{conversationId}` - SMS threads
  - `messages/{messageId}` - SMS messages
- `facilities/{facilityId}/messageLogs/{messageLogId}` - Message logs
- `facilities/{facilityId}/mapShapes/{shapeId}` - Map shapes
- `facilities/{facilityId}/auditLogs/{logId}` - Audit logs
- `facilities/{facilityId}/billing/{billingId}` - Billing records
- `facilities/{facilityId}/dnr/{dnrId}` - DNR entries
- `facilities/{facilityId}/invites/{inviteId}` - Facility invites
- `facilities/{facilityId}/digests/{digestId}` - Email digests
  - `items/{itemId}` - Digest items
- `facilities/{facilityId}/documents/{documentId}` - Documents
- `facilities/{facilityId}/leaseTemplates/{templateId}` - E-sign templates
- `facilities/{facilityId}/esignEnvelopes/{envelopeId}` - E-sign envelopes
- `facilities/{facilityId}/contractTemplates/{templateId}` - Contract templates
- `facilities/{facilityId}/products/{productId}` - Products (store)
- `facilities/{facilityId}/sales/{saleId}` - Sales
- `facilities/{facilityId}/transfers/{transferId}` - Transfers
- `facilities/{facilityId}/insurancePlans/{planId}` - Insurance plans
- `facilities/{facilityId}/emailUsage/{usageId}` - Email usage tracking
- `facilities/{facilityId}/rateLimits/{windowId}` - Rate limiting

**Account Subcollections:**
- `facilityCreatorAccounts/{accountId}/security_events/{eventId}` - Security events
- `facilityCreatorAccounts/{accountId}/security_alerts/{alertId}` - Security alerts
- `facilityCreatorAccounts/{accountId}/security_settings/{settingId}` - Security settings

### Key Fields (Inferred from Models)

**Facility Document:**
- `name`, `ownerUid`, `facilityCreatorAccountId`, `createdAt`, `updatedAt`
- `address`, `phone`, `email`, `description`
- `totalUnits`, `occupiedUnits`, `active`
- `timeZone`, `businessHours`, `gateHours`
- `billingSettings`, `insuranceSettings`
- `stripeConnectAccountId`, `stripeConnectOnboardingComplete`
- `defaultLocale`, `logoUrl`
- `roles` (map: `{uid: 'owner'|'manager'|'employee'}`)
- `managers` (map: `{uid: true}`)

**Tenant Document:**
- `facilityId`, `name`, `email`, `phone`, `unitNumber`, `monthlyRate`
- `paidThrough`, `isActive`, `createdAt`, `updatedAt`
- `portalEnabled`, `portalAccessCode`, `portalLastAccessAt`, `portalVisitCount`
- `insuranceStatus`, `delinquencyStatus`
- `emergencyContacts`, `vehicles`, `occupants`, `addresses`
- `governmentIdType`, `governmentIdNumber`
- `leadSource`, `preferredLocale`
- `isOnDNR`, `notes`

**Contract Document:**
- `facilityId`, `facilityOwnerUid`, `tenantId`, `title`, `type`, `status`
- `createdAt`, `sentAt`, `signedAt`, `expiresAt`
- `fileUrl`, `signedFileUrl`
- `moveOutStatus`, `moveOutDate`, `moveOutCharges`, `moveOutRefund`

**Payment Document:**
- `facilityId`, `tenantId`, `amount`, `type`, `status`, `method`
- `stripePaymentIntentId`, `stripeChargeId`
- `createdAt`, `processedAt`

**Evidence:**
- `firestore.rules`: Complete security rules showing collection structure
- `lib/models/`: All model files define Firestore document structure
- `firestore.indexes.json`: Composite indexes for queries

---

## 5. Backend / Cloud Functions / APIs

### Cloud Functions (Exported)

| Function Name | Trigger | Purpose | Evidence |
|--------------|---------|---------|----------|
| `sendEmail` | HTTPS Callable | Send email via SendGrid | `functions/src/index.ts:417` |
| `sendDigest` | HTTPS Callable | Send email digest | `functions/src/index.ts:1121` |
| `sendDailyDigests` | Pub/Sub (scheduled) | Daily email digests | `functions/src/index.ts:1215` |
| `tenantPortalFetch` | HTTPS Callable | Tenant portal data fetch | `functions/src/index.ts:1446` |
| `createTenantPortalPaymentCheckout` | HTTPS Callable | Tenant portal checkout | `functions/src/index.ts:1584` |
| `sendSMS` | HTTPS Callable | Send SMS via Twilio | `functions/src/index.ts:1697` |
| `getSMSUsageStatus` | HTTPS Callable | SMS usage stats | `functions/src/index.ts:2598` |
| `overrideSMSLimit` | HTTPS Callable | Override SMS limit (admin) | `functions/src/index.ts:2708` |
| `generateMonthlyRentCharges` | HTTPS Callable | Generate monthly charges | `functions/src/index.ts:2776` |
| `processStripePayment` | HTTPS Callable | Process Stripe payment | `functions/src/index.ts:2965` |
| `createSetupIntent` | HTTPS Callable | Create Stripe Setup Intent | `functions/src/index.ts:3155` |
| `attachPaymentMethod` | HTTPS Callable | Attach payment method | `functions/src/index.ts:3259` |
| `ensureFacilityStripeCustomer` | HTTPS Callable | Ensure Stripe customer | `functions/src/index.ts:3382` |
| `scheduledGenerateMonthlyRentCharges` | Pub/Sub (scheduled) | Auto-generate monthly charges | `functions/src/index.ts:3471` |
| `processDelinquencyAutomation` | Pub/Sub (scheduled) | Process late fees/notices | `functions/src/index.ts:3656` |
| `processRefund` | HTTPS Callable | Process refund | `functions/src/index.ts:4079` |
| `processMoveOut` | HTTPS Callable | Move-out workflow | `functions/src/index.ts:4202` |
| `completePublicMoveIn` | HTTPS Callable | Complete public move-in | `functions/src/index.ts:4463` |
| `processAutopayPayments` | Pub/Sub (scheduled) | Daily autopay processing | `functions/src/index.ts:4819` |
| `resetMonthlySMSUsage` | Pub/Sub (scheduled) | Reset SMS usage monthly | `functions/src/index.ts:5040` |
| `autoProtectMoveIn` | Pub/Sub (scheduled) | Auto-enroll in insurance | `functions/src/index.ts:5086` |
| `autoProtectAudit` | Pub/Sub (scheduled) | Insurance compliance audit | `functions/src/index.ts:5254` |
| `checkInsuranceCompliance` | Pub/Sub (scheduled) | Insurance compliance check | `functions/src/index.ts:5439` |
| `submitClaim` | HTTPS Callable | Submit insurance claim | `functions/src/index.ts:5565` |
| `processPaymentReminders` | Pub/Sub (scheduled) | Payment reminders | `functions/src/index.ts:5741` |
| `createCheckoutSession` | HTTPS Callable | Create Stripe checkout | `functions/src/index.ts:6114` |
| `createSubscriptionCheckout` | HTTPS Callable | Create subscription checkout | `functions/src/index.ts:6162` |
| `startTrial` | HTTPS Callable | Start trial | `functions/src/index.ts:6346` |
| `createCustomerPortalSession` | HTTPS Callable | Stripe customer portal | `functions/src/index.ts:6454` |
| `updateSubscriptionQuantity` | HTTPS Callable | Update subscription | `functions/src/index.ts:6507` |
| `getSubscriptionStatus` | HTTPS Callable | Get subscription status | `functions/src/index.ts:6618` |
| `stripeWebhook` | HTTPS Request | Stripe webhook handler | `functions/src/index.ts:6661` |
| `createStripeConnectAccount` | HTTPS Callable | Create Connect account | `functions/src/index.ts:7507` |
| `createStripeConnectAccountLink` | HTTPS Callable | Create Connect link | `functions/src/index.ts:7590` |
| `getStripeConnectAccountStatus` | HTTPS Callable | Get Connect status | `functions/src/index.ts:7646` |
| `createStripeConnectLoginLink` | HTTPS Callable | Connect login link | `functions/src/index.ts:7724` |
| `createTenantPaymentCheckout` | HTTPS Callable | Tenant checkout | `functions/src/index.ts:7781` |
| `createTenantSetupIntent` | HTTPS Callable | Tenant setup intent | `functions/src/index.ts:7875` |
| `attachTenantPaymentMethod` | HTTPS Callable | Attach tenant method | `functions/src/index.ts:7993` |
| `chargeTenantOffSession` | HTTPS Callable | Charge tenant (autopay) | `functions/src/index.ts:8135` |
| `createStoreCheckout` | HTTPS Callable | Store checkout | `functions/src/index.ts:8268` |
| `createPublicPaymentCheckout` | HTTPS Callable | Public payment link | `functions/src/index.ts:8386` |
| `lookupUserByEmail` | HTTPS Callable | Secure user lookup | `functions/src/index.ts:8534` |
| `runPhase2Migrations` | HTTPS Callable | Run migrations | `functions/src/index.ts:8594` |
| `handleIncomingSMS` | HTTPS Request | Twilio SMS webhook | `functions/src/index.ts:8683` |
| `redirectToCustomDomain` | HTTPS Request | Custom domain redirect | `functions/src/index.ts:9034` |
| `enableStripeConnectAdmin` | HTTPS Callable | Enable Connect (admin) | `functions/src/index.ts:9157` |
| `esignCreateEnvelope` | HTTPS Callable | Create e-sign envelope | `functions/src/index.ts:9242` |
| `esignWebhookDropboxSign` | HTTPS Request | Dropbox Sign webhook | `functions/src/index.ts:9370` |
| `esignResendEnvelope` | HTTPS Callable | Resend e-sign envelope | `functions/src/index.ts:9503` |
| `esignVoidEnvelope` | HTTPS Callable | Void e-sign envelope | `functions/src/index.ts:9561` |

**Total Functions:** 51 exported functions

**Scheduled Functions:**
- `sendDailyDigests`: Daily at configured time
- `scheduledGenerateMonthlyRentCharges`: Monthly (1st of month)
- `processDelinquencyAutomation`: Daily at 3:00 AM UTC
- `processAutopayPayments`: Daily at 2:00 AM UTC
- `resetMonthlySMSUsage`: Monthly (1st of month at midnight UTC)
- `autoProtectMoveIn`: Daily
- `autoProtectAudit`: Daily
- `checkInsuranceCompliance`: Daily
- `processPaymentReminders`: Daily at 9:00 AM UTC

**Webhook Handlers:**
- `stripeWebhook`: Stripe events (payments, subscriptions, Connect)
- `handleIncomingSMS`: Twilio incoming SMS
- `esignWebhookDropboxSign`: Dropbox Sign e-signature events

---

## 6. Integrations Matrix

### 6.1 Twilio (SMS)

**Status:** ✅ **Implemented**

**Usage:**
- SMS sending via Cloud Function
- Incoming SMS webhook handling
- SMS conversation threading
- SMS usage tracking and limits
- Monthly usage reset

**Endpoints:**
- `sendSMS` (Cloud Function): Send SMS
- `handleIncomingSMS` (Cloud Function): Receive SMS webhook
- `getSMSUsageStatus` (Cloud Function): Usage stats
- `overrideSMSLimit` (Cloud Function): Admin override

**Compliance/Opt-out:**
- DNR (Do Not Rent) list prevents messaging
- SMS usage limits per facility (configurable)
- Message logs track all SMS sent
- Opt-out handling via DNR list

**Evidence:**
- `functions/src/index.ts`:
  - `sendSMS` (line 1697): SMS sending logic
  - `handleIncomingSMS` (line 8683): Webhook handler
  - `getSMSUsageStatus` (line 2598): Usage tracking
  - `resetMonthlySMSUsage` (line 5040): Monthly reset
- `lib/services/sms_service.dart`: Client-side SMS service
- `lib/services/sms_conversation_service.dart`: Conversation management
- `lib/services/sms_usage_service.dart`: Usage tracking
- `lib/models/sms_usage_model.dart`: Usage model

**Configuration:**
- `TWILIO_ACCOUNT_SID` (environment variable)
- `TWILIO_AUTH_TOKEN` (Firebase secret)
- `TWILIO_PHONE_NUMBER` (environment variable)

---

### 6.2 SendGrid (Email)

**Status:** ✅ **Implemented**

**Usage:**
- Email sending via Cloud Function
- Email templates support
- Email digests (daily summaries)
- Email tracking (opens, clicks - if enabled)
- Email usage tracking

**Endpoints:**
- `sendEmail` (Cloud Function): Send email
- `sendDigest` (Cloud Function): Send digest
- `sendDailyDigests` (Cloud Function): Scheduled digests

**Evidence:**
- `functions/src/index.ts`:
  - `sendEmail` (line 417): Email sending logic
  - `sendDigest` (line 1121): Digest sending
  - `sendDailyDigests` (line 1215): Scheduled digests
- `lib/services/email_service.dart`: Client-side email service
- `lib/services/email_template_service.dart`: Template management
- `lib/services/email_usage_service.dart`: Usage tracking
- `lib/services/email_tracking_service.dart`: Email tracking

**Configuration:**
- `SENDGRID_API_KEY` (Firebase secret)
- `SENDGRID_SENDER_EMAIL` (environment variable)
- `SENDGRID_FROM_NAME` (environment variable, default: "Storage Facility Creator")

---

### 6.3 Stripe

**Status:** ✅ **Implemented**

**Usage:**
- Payment processing (checkout sessions, payment intents)
- Subscription management (SaaS model)
- Stripe Connect (facility-specific accounts)
- Payment methods (cards, ACH)
- Setup Intents (save payment methods)
- Autopay processing
- Refunds
- Customer Portal
- Webhooks (payment events, subscription events, Connect events)

**Endpoints:**
- `processStripePayment`: Process payment
- `createSetupIntent`: Setup Intent for saving methods
- `attachPaymentMethod`: Attach method to customer
- `createCheckoutSession`: Create checkout session
- `createSubscriptionCheckout`: Subscription checkout
- `createCustomerPortalSession`: Customer portal
- `createStripeConnectAccount`: Create Connect account
- `createStripeConnectAccountLink`: Connect onboarding link
- `getStripeConnectAccountStatus`: Connect status
- `createStripeConnectLoginLink`: Connect dashboard link
- `createTenantPaymentCheckout`: Tenant checkout
- `createTenantSetupIntent`: Tenant setup intent
- `attachTenantPaymentMethod`: Attach tenant method
- `chargeTenantOffSession`: Charge tenant (autopay)
- `createPublicPaymentCheckout`: Public payment link
- `createStoreCheckout`: Store checkout
- `processRefund`: Process refund
- `stripeWebhook`: Webhook handler
- `updateSubscriptionQuantity`: Update subscription
- `getSubscriptionStatus`: Get subscription status

**Evidence:**
- `functions/src/index.ts`: All Stripe functions (lines 2965-8386)
- `lib/services/stripe_service.dart`: Client-side Stripe service
- `lib/services/setup_intent_service.dart`: Setup Intents
- `lib/services/autopay_service.dart`: Autopay logic
- `lib/screens/stripe_connect_onboarding_screen.dart`: Connect onboarding UI
- `lib/models/payment_method_model.dart`: Payment method model

**Configuration:**
- `STRIPE_SECRET_KEY` (Firebase secret)
- `STRIPE_WEBHOOK_SECRET` (Firebase secret)
- `STRIPE_CONNECT_CLIENT_ID` (environment variable, stored as secret)

**Stripe Connect:**
- Facilities can link Stripe Connect accounts
- Onboarding flow via Stripe Connect
- Payments processed to facility's Connect account
- Connect account status tracking

---

### 6.4 Dropbox Sign (E-Signatures)

**Status:** ✅ **Implemented**

**Usage:**
- E-signature envelope creation
- E-signature status tracking
- E-signature webhook handling
- Envelope resend/void

**Endpoints:**
- `esignCreateEnvelope`: Create envelope
- `esignWebhookDropboxSign`: Webhook handler
- `esignResendEnvelope`: Resend envelope
- `esignVoidEnvelope`: Void envelope

**Evidence:**
- `functions/src/index.ts`:
  - `esignCreateEnvelope` (line 9242)
  - `esignWebhookDropboxSign` (line 9370)
  - `esignResendEnvelope` (line 9503)
  - `esignVoidEnvelope` (line 9561)
- `lib/services/esign_service.dart`: E-sign service
- `lib/models/esign_envelope_model.dart`: E-sign model
- `lib/models/lease_template_model.dart`: Lease template model
- `lib/screens/lease_templates_screen.dart`: Template management

**Configuration:**
- Dropbox Sign API key (configured in Cloud Functions)

---

## 7. Security & Compliance Snapshot

### Firebase Security Rules

**Firestore Rules:**
- ✅ Comprehensive rules in `firestore.rules`
- ✅ Facility-scoped access control
- ✅ Role-based permissions (owner, manager, employee)
- ✅ Super admin support
- ✅ Data validation on create/update
- ✅ Immutable audit logs
- ✅ Message logs write-protected (Cloud Functions only)

**Storage Rules:**
- ✅ User-scoped uploads (`/uploads/{uid}/`)
- ✅ Facility-scoped files (`/facilities/{facilityId}/`)
- ✅ Owner-only access for facility files

**Evidence:**
- `firestore.rules`: 916 lines of security rules
- `storage.rules`: Storage access rules

### PII Handling

**Patterns:**
- Email addresses stored (lowercased for lookups)
- Phone numbers stored
- Government ID information stored (encrypted at rest by Firebase)
- Payment method details stored in Stripe (not Firestore)
- Contact information in tenant documents

**Evidence:**
- `lib/models/tenant_model.dart`: PII fields (email, phone, governmentId)
- `firestore.rules`: Access controls prevent unauthorized PII access

### Secrets Management

**Approach:**
- Firebase Functions secrets (SENDGRID_API_KEY, STRIPE_SECRET_KEY, TWILIO_AUTH_TOKEN)
- Environment variables for non-sensitive config (SENDGRID_SENDER_EMAIL, TWILIO_PHONE_NUMBER)
- Super admin emails hardcoded (also in Firestore rules for consistency)

**Evidence:**
- `functions/src/index.ts` (lines 17-35): Secret definitions
- `functions/package.json`: Dependencies

### Logging Risks

**Sensitive Data:**
- Sentry integration scrubs sensitive data (card numbers, CVV, payment method IDs)
- Request body redacted for payment endpoints
- Email addresses redacted from URLs in Sentry events

**Evidence:**
- `functions/src/index.ts` (lines 99-127): Sentry beforeSend hook

---

## 8. Product Capability Catalog

### ✅ Fully Implemented Capabilities

**Core Management:**
- Multi-facility management (create, edit, archive)
- Tenant management (CRUD, bulk import, portal access)
- Unit management (list, map editor, status tracking)
- Contract/lease management (create, e-sign, move-out)
- Payment processing (Stripe, Connect, autopay, refunds)
- Invoice generation and management
- Ledger/accounting (charges, payments, credits, refunds)
- Deposit management (security deposits, refunds)

**Communication:**
- SMS messaging (Twilio, conversations, templates)
- Email messaging (SendGrid, templates, sequences)
- Bulk messaging (to multiple tenants)
- Reminder system (one-time and scheduled)
- Late notices (automated)
- Team messaging (group and private conversations)
- Contact logs (auto-created from communications)
- Message history (per-tenant timeline)

**Automation:**
- Payment reminders (3 days before due date)
- Delinquency automation (late fees, notices, lockouts)
- Autopay processing (daily scheduled)
- Monthly rent charge generation (scheduled)
- Insurance compliance checks (automated)
- Email digests (daily summaries)
- Report scheduling (automated email delivery)

**Reporting & Analytics:**
- Financial reports (revenue, expenses, profit)
- Communication analytics (email/SMS stats)
- Insurance reports
- Lead source analytics
- Delinquency dashboard
- Yield management (pricing optimization)

**Integrations:**
- Stripe (payments, subscriptions, Connect)
- SendGrid (email)
- Twilio (SMS)
- Dropbox Sign (e-signatures)

**Public Features:**
- Public payment links (token-based)
- Public rental portal (inquiry form)
- Public move-in flow
- Public facility pages
- Tenant portal (access code-based)

**Document Management:**
- Document upload and storage
- PDF generation (invoices, contracts)
- E-signature integration
- Document attachments
- Document center

**Access Control:**
- Role-based permissions (owner, manager, employee)
- Facility-scoped data access
- Invite system
- Super admin support

**Other:**
- Gate access code management
- DNR (Do Not Rent) list
- Insurance management (TPP, claims)
- Lien management
- Inventory management
- POS (Point of Sale)
- Coupon management
- API keys management
- Webhooks management
- Email sequences
- Escalation workflows
- Conditional rules
- Multi-language support (en, es, fr, de, zh, ja)

---

## 9. Gap List

### ⚠️ Partially Implemented / Stubs

1. **AI Assistant** (`lib/screens/ai_assistant_screen.dart:99`)
   - Status: Stub (TODO: Replace with actual LLM API call)
   - Impact: Feature not functional

2. **Reports Consolidated** (stub files exist)
   - Status: May have stub implementations for non-web platforms
   - Impact: Some report features may not work on all platforms

3. **Insurance Report** (stub files exist)
   - Status: May have stub implementations for non-web platforms
   - Impact: Insurance reports may not work on all platforms

4. **Audit Logs**
   - Status: Partially implemented
   - Impact: May not cover all operations comprehensively

### ❌ Missing / Unknown

1. **Tenant-facing mobile app**
   - Status: Unknown (web-only confirmed)
   - Impact: Tenants access via web portal only

2. **Push notifications**
   - Status: Unknown (no evidence found)
   - Impact: No native push notifications

3. **Two-factor authentication (2FA)**
   - Status: Unknown (no evidence found)
   - Impact: Security may rely on email verification only

4. **Backup/restore functionality**
   - Status: Unknown (no evidence found)
   - Impact: No built-in backup/restore

5. **Data export (CSV/Excel)**
   - Status: Unknown (CSV import exists, export not confirmed)
   - Impact: May not be able to export data

6. **Advanced reporting (custom reports)**
   - Status: Unknown (standard reports exist)
   - Impact: May not support custom report creation

7. **Multi-currency support**
   - Status: Unknown (USD assumed)
   - Impact: May not support international currencies

8. **Tax calculation integration**
   - Status: Unknown (tax rate stored, calculation unknown)
   - Impact: Tax calculation may be manual

9. **Accounting software integration (QuickBooks, etc.)**
   - Status: Unknown (no evidence found)
   - Impact: No direct accounting software integration

10. **Credit card processing fees tracking**
    - Status: Unknown (Stripe fees may be tracked, not confirmed)
    - Impact: Fee tracking may be incomplete

---

## 10. Output Formats

### A) Human Report (This Document)

✅ Complete - See above sections.

### B) Machine Report (JSON)

See `PRODUCT_AUDIT_REPORT.json` (generated separately).

---

## Condensed Summary (40 Lines Max)

**Storage Facility Creator** is a Flutter Web SaaS for self-storage facility management. **Core Features:** Multi-facility management, tenant/unit/contract management, billing/invoicing, payment processing (Stripe + Connect), SMS/email messaging (Twilio/SendGrid), e-signatures (Dropbox Sign), automated reminders/late notices/autopay, reporting/analytics, document management, tenant portal, public payment links, gate access codes, insurance management, DNR list, CSV import, yield management. **Integrations:** Stripe (payments, subscriptions, Connect), SendGrid (email), Twilio (SMS), Dropbox Sign (e-signatures). **Architecture:** Firebase (Auth, Firestore, Storage, Functions, Hosting), Riverpod state management, go_router navigation. **Security:** Facility-scoped access control, role-based permissions (owner/manager/employee), Firestore security rules, Firebase Storage rules, App Check enabled. **Cloud Functions:** 51 functions including scheduled jobs (monthly charges, autopay, reminders, delinquency automation, insurance compliance), webhooks (Stripe, Twilio, Dropbox Sign), and callable endpoints. **Data Model:** Facility-scoped collections (tenants, units, contracts, payments, invoices, ledgers, deposits, reminders, messages, documents, etc.). **Gaps:** AI Assistant is a stub, some report stubs for non-web platforms, audit logs may be incomplete, tenant mobile app unknown, 2FA unknown, backup/export unknown, accounting software integration unknown.

---

**Report End**
