# Texting Onboarding (A2P 10DLC) — AUDIT Report

**Date:** 2026-03-02  
**Scope:** Existing Twilio usage, messaging code paths, webhooks, DB models, UI patterns.  
**Goal:** Minimal-change plan for self-serve “Enable Texting” with A2P 10DLC (no porting).

---

## 1. Existing Twilio Usage

### 1.1 Environment / Secrets (Firebase Functions)

| Name | Type | Purpose |
|------|------|---------|
| `TWILIO_ACCOUNT_SID` | `defineString` (env) | Main Twilio account |
| `TWILIO_AUTH_TOKEN` | `defineSecret` | Auth for API calls |
| `TWILIO_PHONE_NUMBER` | `defineString` (env) | **Single shared From number** (no per-facility numbers today) |

**Location:** `functions/src/index.ts` (lines ~51–54, 60).

**Finding:** One account, one phone number for all facilities. No Twilio SDK in `functions/package.json`; all Twilio calls use `fetch()` to REST API.

---

### 1.2 Cloud Functions (Twilio / SMS)

| Function | Trigger | File:Line | Purpose |
|----------|---------|-----------|---------|
| `sendSMS` | `https.onCall` | `index.ts` ~2511–3185 | Send SMS; uses global `TWILIO_PHONE_NUMBER`; checks facility access, compliance, usage limits |
| `handleIncomingSMS` | `https.onRequest` (webhook) | `index.ts` ~12704–12892 | Inbound SMS: STOP/START/HELP, store reply, contact log |
| `handleSMSOptOut` | (internal) | `index.ts` ~13067–13116 | Set tenant `smsOptOut`, optional facility block list |
| `handleSMSOptIn` | (internal) | `index.ts` ~13122–13167 | Clear opt-out, remove from block list |
| `getSMSUsageStatus` | `https.onCall` | (ref PRODUCT_AUDIT) | Usage stats |
| `overrideSMSLimit` | (admin) | (ref PRODUCT_AUDIT) | Override limits |
| `resetMonthlySMSUsage` | scheduled | (ref) | Monthly reset of `smsUsage` |
| `processPaymentReminders` | scheduled | uses sendSMS | Payment reminders |
| `processDelinquencyAutomation` | scheduled | uses sendSMS | Late notices |

**SMS compliance helpers (same file):** `getSMSComplianceConfig()`, `isSMSComplianceFeatureEnabled('enhancedOptOut'|'quietHours'|'rateLimiting', facilityId?)` — read `appConfig/smsCompliance`.

**Risks if we change carelessly:**

- Replacing or renaming `sendSMS` or its request/response shape would break Flutter `SMSService.sendSMS()` and any callers.
- Changing `handleIncomingSMS` URL or request handling would break Twilio webhook configuration.
- Switching to per-facility From number inside `sendSMS` must be additive (e.g. prefer facility’s number when A2P approved, else fall back to global).

---

### 1.3 Webhook Endpoint

- **Current:** Single `handleIncomingSMS` HTTP endpoint; Twilio must be configured to POST to it.
- **Limitation:** One “To” number today, so all inbound SMS hit the same handler. With per-facility numbers, inbound “To” will identify the facility (we can route by number → facility in DB).

---

## 2. Messaging-Related Code Paths

### 2.1 Client (Flutter)

| File | Role |
|------|------|
| `lib/services/sms_service.dart` | Calls `sendSMS` callable with `to`, `message`, `facilityId`, optional `tenantId` / `relatedEntityType` |
| `lib/screens/bulk_messaging_screen.dart` | Bulk email/SMS; uses SMSService |
| `lib/screens/sms_conversations_screen.dart` | SMS threads (facility-scoped) |
| `lib/screens/messaging_screen.dart` | Messaging hub |
| `lib/screens/sms_template_management_screen.dart` | SMS templates |
| `lib/screens/sms_policy_screen.dart` | Static SMS policy (linked from settings / marketing) |

**Router:** `app_route.dart` / `app_router.dart` — `messaging`, `smsConversations`, `bulkMessaging`, `smsTemplates`, `/sms-policy`.

**Finding:** No existing “Texting setup” or “Enable Texting” wizard. Add new route(s) and screen(s); do not rename existing routes or `SMSService` API.

---

### 2.2 Backend SMS Flow (sendSMS)

1. Auth + App Check + rate limit.
2. Load facility, check permission (owner/manager).
3. Resolve `accountId` from `facilityData.facilityCreatorAccountId` if not provided.
4. Compliance (opt-out, block list, quiet hours, rate limit) when `appConfig/smsCompliance` flags allow.
5. Add opt-out footer when compliance enabled.
6. `checkAndIncrementSMSUsage` (facility + optional account).
7. Send via Twilio REST: `From = TWILIO_PHONE_NUMBER` (global).
8. Create/update message log, return usage + status.

**Planned change:** When `TEXTING_ONBOARDING_V1` is on and facility has A2P approved + per-facility number, use that number as `From` and keep existing flow otherwise (global number, same compliance).

---

## 3. DB / Firestore Schema (Relevant)

### 3.1 Collections and Key Fields

- **`facilities/{facilityId}`**  
  - Existing: `name`, `ownerUid`, `facilityCreatorAccountId`, `smsSettings` (e.g. `blockList`, `helpMessage`), `managers`, etc.  
  - **To add (additive):** A2P/Texting onboarding fields (see Design doc): e.g. `a2pStatus`, `twilioPhoneNumberSid`, `twilioPhoneNumberE164`, `twilioMessagingServiceSid`, `twilioTrustProfileSid`, `twilioBrandSid`, `twilioCampaignSid`, `a2pLastError`, `a2pSubmittedAt`, etc. Store only SIDs and status — no EIN/SSN in logs.

- **`facilities/{facilityId}/tenants/{tenantId}`**  
  - Existing SMS: `smsOptOut`, `smsOptOutDate`, `smsOptInDate`, `smsQuietHoursStart/End`, `smsRateLimitPerDay`, `smsMessagesSentToday`, `smsLastResetDate`.  
  - **To add (additive):** `smsConsentStatus` (opted_in | opted_out | unknown), `smsConsentTimestamp`, `smsConsentSource` — optional for consent tracking; existing `smsOptOut` remains source of truth for “can send” until migration.

- **`facilities/{facilityId}/smsUsage/{monthKey}`**  
  - Existing: usage counts, `smsMonthlyLimit`. Leave as-is.

- **`facilityCreatorAccounts/{accountId}`**  
  - Used for account-level SMS caps and subscription; no Twilio SIDs today. Optionally store account-level A2P in future; for Phase 1, per-facility only is enough.

- **`appConfig/smsCompliance`**  
  - Existing: `enhancedOptOutEnabled`, `quietHoursEnabled`, `rateLimitingEnabled`, `allowlistFacilityIds`, `killSwitch`.  
  - **To add (optional):** No change required; new feature gated by `appConfig/featureFlags` (see below).

- **`appConfig/featureFlags`**  
  - Document with keys like `aiAssistant`, `smsMessaging`, `maintenanceMode`. Each key: `{ enabled, updatedAt?, updatedBy? }`.  
  - **To add:** New key `TEXTING_ONBOARDING_V1` with **default `enabled: false`** (prod). Flutter reads via `featureFlagEnabledProvider('TEXTING_ONBOARDING_V1')`; functions read same or a dedicated appConfig doc.

**Finding:** All changes are additive fields or new docs; no renames or deletions of existing fields required.

---

## 4. UI Patterns and Entry Points

- **Settings:** `lib/screens/settings_screen.dart` — tabs “Settings” / “Onboarding”; sections Account, Facility (Permissions, Insurance, Notifications), General (Appearance, AI Assistant), Legal (Terms, Privacy, SMS Terms, Cookies).  
- **Facility-scoped settings:** Notifications and Insurance use “first facility” or a facility picker when multiple.  
- **Feature flags:** `lib/providers/feature_flag_provider.dart` — `featureFlagEnabledProvider(flagKey)`. Defaults for unknown keys are currently “true”; for `TEXTING_ONBOARDING_V1` we need **default false** (add to `kDefaultFeatureFlags` in `lib/models/feature_flag_model.dart` with `enabled: false`).

**Planned UI:** New “Texting” (or “Enable Texting”) entry under Facility (or Communications): only visible when `TEXTING_ONBOARDING_V1` is on. Opens wizard (steps 0–4) then status/dashboard. Reuse facility selector pattern when user has multiple facilities.

---

## 5. Risks and Constraints

| Risk | Mitigation |
|------|------------|
| Breaking existing SMS send | Keep `sendSMS` signature and response shape; add optional “use facility number when approved” branch behind feature flag and A2P status. |
| Breaking inbound SMS | Keep `handleIncomingSMS`; add lookup “To” → facility (from new facility↔number map); keep STOP/HELP behavior; do not log full body (metadata only). |
| Exposing secrets | No new secrets in client; Twilio credentials stay in env/secret manager; no EIN/SSN/Auth Token in logs. |
| Breaking compliance | Keep existing opt-out/block list/quiet hours/rate limits; add A2P approval gate before sending from facility number. |
| Firestore rules | Add rules so only facility owner/manager can write new A2P fields on `facilities/{id}`; keep existing read/write for `tenants`, `smsSettings`. |

---

## 6. Files to Touch (Minimal-Change Plan)

### 6.1 Backend (Functions)

| File | Change |
|------|--------|
| `functions/src/index.ts` | Add: feature-flag check for `TEXTING_ONBOARDING_V1`; helpers for provision number, Messaging Service, Trust Hub/Brand/Campaign (idempotent); new callables (e.g. `provisionTextingNumber`, `submitA2PRegistration`, `getTextingOnboardingStatus`); optional `getTwilioPhoneNumberForFacility`; in `sendSMS`, when flag + facility has approved A2P + number, use facility number as From; extend `handleIncomingSMS` to resolve facility by “To” and retain STOP/HELP behavior. Add dry-run mode (env) that stubs Twilio. |
| `functions/package.json` | Add `twilio` SDK (recommended for Trust Hub / Brand / Campaign APIs) or keep fetch for Messages only and add minimal Twilio REST for A2P resources. |

### 6.2 Firestore

- **Schema:** Additive fields on `facilities` and optionally on `tenants` (consent fields). New doc or subcollection only if needed for onboarding drafts (e.g. `facilities/{id}/textingOnboarding` or fields on facility).

### 6.3 Client (Flutter)

| File | Change |
|------|--------|
| `lib/models/feature_flag_model.dart` | Add `TEXTING_ONBOARDING_V1` to `kDefaultFeatureFlags` with `enabled: false`. |
| `lib/models/facility_model.dart` | Add optional A2P/Texting fields (e.g. `a2pStatus`, `twilioPhoneNumberE164`, …) for read-only status. |
| `lib/models/tenant_model.dart` | Optionally add `smsConsentStatus`, `smsConsentTimestamp`, `smsConsentSource` (additive). |
| `lib/router/app_route.dart` | Add route constant for Texting setup (e.g. `textingSetup`, `textingStatus`). |
| `lib/router/app_router.dart` | Register route(s); optional guard with `featureFlagEnabledProvider('TEXTING_ONBOARDING_V1')`. |
| `lib/screens/settings_screen.dart` | Add “Texting” / “Enable Texting” tile under Facility (or new “Communications” section), visible only when flag on; navigate to wizard or status. |
| **New** `lib/screens/texting_setup_wizard_screen.dart` (or multi-file) | Steps 0–4: intro, business info, use case, phone number, review & submit; call new callables. |
| **New** `lib/screens/texting_status_screen.dart` | Status timeline, last error, Resubmit if rejected. |
| `lib/services/sms_service.dart` | No signature change; optionally pass facilityId so backend can choose From (already passed). |

### 6.4 Config / Docs

| File | Change |
|------|--------|
| `firestore.rules` | Allow owner/manager to update new A2P fields on `facilities/{id}`; no change to tenant or appConfig read unless needed. |
| **New** `docs/TEXTING_ONBOARDING_README.md` | Env vars, local dev, dry-run, how to verify onboarding (and rollback). |

---

## 7. Rollback

- **Feature flag:** Set `TEXTING_ONBOARDING_V1` to `false` in `appConfig/featureFlags` → hide UI and disable new backend branches; `sendSMS` falls back to global number.
- **Backend:** Revert new callables and `sendSMS`/`handleIncomingSMS` changes; redeploy.
- **Client:** Revert new screens and settings tile; remove route(s).
- **Data:** New fields on facilities/tenants can remain; no need to delete unless cleaning up.

---

## 8. Next Step: DESIGN

After your approval of this audit, the next deliverable will be a short **Design** doc covering:

- Exact Firestore field names and types for facility (and optional tenant) A2P/Texting.
- Callable/HTTP function names, request/response shapes, and idempotency.
- State machine for onboarding (Draft → Submitted → Pending → Approved/Rejected) and when SMS is allowed.
- UI route names and which step corresponds to which data.
- Mapping of Twilio ISV APIs (Trust Hub Customer Profile, Trust Product, Brand Registration, Campaign, Messaging Service, number provisioning) to our backend steps and storage.

---

**Summary:** Existing Twilio usage is single-account, single number, with robust compliance and inbound STOP/HELP. The plan is additive only: new feature flag, new facility (and optional tenant) fields, new callables and wizard/status UI, and conditional use of per-facility number in `sendSMS` plus routing by “To” in `handleIncomingSMS`. No renames or breaking changes to existing exports or public APIs.
