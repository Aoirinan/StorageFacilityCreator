# Contract E-Signing Compliance Implementation

**Date:** January 27, 2026  
**Purpose:** Implement comprehensive compliance and risk controls for customer-uploaded contract e-signing

## Overview

This implementation adds legal risk-minimization controls for contract uploads and e-signing, including rights attestation, terms acceptance, document integrity tracking, and takedown workflows.

## What Was Changed

### A) Upload Rights Attestation (Required)

**Files Modified:**
- `lib/models/rights_attestation_model.dart` (NEW)
- `lib/services/compliance_service.dart` (NEW)
- `lib/screens/contract_creation_screen.dart`

**Changes:**
1. Added required checkbox on contract upload: "I confirm I have the legal right to upload and use this document..."
2. Created `RightsAttestationModel` to store attestation records in Firestore
3. Attestations stored at: `facilities/{facilityId}/rightsAttestations/{attestationId}`
4. Records include: facilityId, uploaderUserId, uploaderEmail, timestamp (server), tosVersion, attestationText, documentId, documentSha256, userAgent

### B) Facility-Scoped Docs / No Cross-Facility Sharing

**Files Modified:**
- `firestore.rules`

**Changes:**
1. Contracts and templates already stored under `facilities/{facilityId}/contracts/{contractId}` and `facilities/{facilityId}/contractTemplates/{templateId}`
2. Updated security rules to enforce facility-scoped access
3. Only facility staff can read/write their facility's contracts/templates
4. Tenants can only access envelope/signing artifacts explicitly granted to them

### C) Licensed/Association Tag + Reconfirmation

**Files Modified:**
- `lib/models/contract_model.dart`
- `lib/models/contract_template_model.dart`
- `lib/services/compliance_service.dart`
- `lib/screens/contract_creation_screen.dart`
- `lib/screens/contract_list_screen.dart`

**Changes:**
1. Added optional checkbox: "This is an association/licensed form (e.g., TSSA)"
2. Shows inline note: "You are responsible for maintaining any required membership/license to use this form"
3. Added `isLicensedForm` field to ContractModel and ContractTemplateModel
4. Added `lastReconfirmedAt` field for tracking reconfirmation dates
5. `ComplianceService.needsReconfirmation()` checks if licensed form is older than 12 months
6. Reconfirmation banner shown in ContractListScreen for forms needing reconfirmation

### D) Terms Acceptance Record (Versioned)

**Files Modified:**
- `lib/models/terms_acceptance_model.dart` (NEW)
- `lib/services/compliance_service.dart`
- `lib/screens/contract_creation_screen.dart`

**Changes:**
1. Created `TermsAcceptanceModel` for facility-level terms acceptance
2. Terms stored at: `facilities/{facilityId}/compliance/termsAcceptance`
3. Terms acceptance required on first use of contract upload/e-sign features
4. Modal shown with terms text including:
   - Customer warrants rights to uploaded docs
   - Customer indemnifies SFC for misuse
   - SFC may disable documents upon complaint
   - SFC provides tooling only disclaimer
5. Versioned terms (current version: '1.0') with text hash for verification

### E) Audit Logging (High Priority)

**Files Modified:**
- `lib/services/audit_service.dart`

**Changes:**
1. Added audit log methods for contract compliance events:
   - `logContractUploaded()` - CONTRACT_UPLOADED
   - `logRightsAttested()` - RIGHTS_ATTESTED
   - `logContractDisabled()` - CONTRACT_DISABLED
   - `logTemplateCreated()` - TEMPLATE_CREATED
   - `logTemplateUpdated()` - TEMPLATE_UPDATED
   - `logTermsAccepted()` - TERMS_ACCEPTED
   - `logRightsReconfirmed()` - RIGHTS_RECONFIRMED
2. All events logged to: `facilities/{facilityId}/auditLogs/{logId}`
3. Includes actor userId/email, timestamp (server), relatedIds, summary

### F) Admin "Disable Contract" + Takedown Workflow

**Files Modified:**
- `lib/services/contract_service.dart`
- `lib/screens/contract_list_screen.dart`
- `firestore.rules`

**Changes:**
1. Added `disableContract()` and `enableContract()` methods to ContractService
2. Added `disableContractTemplate()` and `enableContractTemplate()` methods
3. Disabled contracts/templates cannot be used for new envelopes
4. UI shows "Disabled — cannot be used for new signatures" message
5. Facility admins can disable their own contracts/templates
6. Super admins can disable any contract/template
7. Disable action requires reason (optional but logged)
8. Disable/enable actions logged to audit log

### G) Document Integrity

**Files Modified:**
- `lib/services/contract_service.dart`
- `functions/src/index.ts`

**Changes:**
1. Added Cloud Function `computeDocumentHash` to compute SHA-256 hash
2. Hash computed server-side for security
3. Contract upload stores: documentSha256, fileSize, contentType, uploadedAt, storagePath
4. Hash stored in contract document and rights attestation record

### H) Minimal UI Changes

**Files Modified:**
- `lib/screens/contract_creation_screen.dart`
- `lib/screens/contract_list_screen.dart`

**Changes:**
1. **Contract Creation Screen:**
   - Terms acceptance modal (shown on first use)
   - Rights attestation checkbox (required when uploading file)
   - Licensed form checkbox (optional)
   - Legal disclaimer shown

2. **Contract List Screen:**
   - Shows compliance status (ACTIVE/DISABLED) chip
   - Shows licensed form flag
   - Shows reconfirmation banner for licensed forms older than 12 months
   - Shows disabled message for disabled contracts
   - Disable/Enable button in contract menu

### I) Do Not Claim Legal Advice

**Files Modified:**
- `lib/screens/contract_creation_screen.dart`
- `lib/services/compliance_service.dart`

**Changes:**
1. Added disclaimer in terms acceptance modal
2. Added small UI disclaimer: "SFC provides tooling only; you are responsible for the documents you upload and use."
3. Internal comments added to code

## Security Rules Updates

**File:** `firestore.rules`

**Changes:**
1. Added rules for `rightsAttestations` collection (facility-scoped, immutable)
2. Added rules for `compliance/termsAcceptance` (facility-level, immutable)
3. Updated contract rules to include compliance status validation
4. Added super admin override for disable operations
5. Ensured facility-scoped access for all contract/template operations

## Data Model Changes

### ContractModel
- Added: `complianceStatus` (enum: active, disabled)
- Added: `isLicensedForm` (bool)
- Added: `lastReconfirmedAt` (DateTime?)
- Added: `documentSha256` (String?)
- Added: `fileSize` (int?)
- Added: `contentType` (String?)
- Added: `uploadedAt` (DateTime?)
- Added: `storagePath` (String?)
- Added: `disabledAt` (DateTime?)
- Added: `disabledBy` (String?)
- Added: `disabledReason` (String?)

### ContractTemplateModel
- Same compliance fields as ContractModel

### New Models
- `RightsAttestationModel` - Stores attestation records
- `TermsAcceptanceModel` - Stores facility-level terms acceptance

## Migration

**File:** `functions/src/migrations/backfill_contract_compliance.ts`

**Purpose:** Backfill existing contracts and templates with default compliance values

**Usage:**
```typescript
// Call Cloud Function: backfillContractComplianceFields
// Only super admins can run this
```

**What it does:**
- Sets `complianceStatus: 'active'` for all existing contracts/templates
- Sets `isLicensedForm: false` for all existing contracts/templates
- Leaves other compliance fields as null (they'll be populated on next upload)

## Testing Checklist

### Manual Testing Steps

1. **Terms Acceptance:**
   - [ ] Navigate to contract creation screen
   - [ ] Verify terms modal appears on first use
   - [ ] Accept terms and verify acceptance is recorded
   - [ ] Verify terms modal doesn't appear again after acceptance

2. **Rights Attestation:**
   - [ ] Upload a contract PDF
   - [ ] Verify rights attestation checkbox is required
   - [ ] Try to submit without checking - should show error
   - [ ] Check box and submit - verify attestation is recorded
   - [ ] Check Firestore for attestation record

3. **Licensed Form:**
   - [ ] Check "This is an association/licensed form" checkbox
   - [ ] Verify warning message appears
   - [ ] Upload contract and verify `isLicensedForm: true` in Firestore

4. **Document Integrity:**
   - [ ] Upload a contract PDF
   - [ ] Verify SHA-256 hash is computed and stored
   - [ ] Verify file metadata (size, contentType, uploadedAt) is stored

5. **Disable Contract:**
   - [ ] Open contract list
   - [ ] Click menu on a contract → "Disable Contract"
   - [ ] Enter reason and confirm
   - [ ] Verify contract shows "Disabled" status
   - [ ] Verify "Disabled — cannot be used for new signatures" message
   - [ ] Verify disable action is logged in audit log

6. **Enable Contract:**
   - [ ] Open contract list
   - [ ] Click menu on disabled contract → "Enable Contract"
   - [ ] Verify contract status changes to "Active"
   - [ ] Verify enable action is logged

7. **Reconfirmation Banner:**
   - [ ] Create a licensed form contract
   - [ ] Manually set `lastReconfirmedAt` to 13 months ago in Firestore
   - [ ] Open contract list
   - [ ] Verify reconfirmation banner appears

8. **Security Rules:**
   - [ ] Verify tenants cannot access facility contracts (should fail)
   - [ ] Verify facility staff can read/write their facility's contracts
   - [ ] Verify attestations are immutable (try to update - should fail)
   - [ ] Verify terms acceptance is immutable (try to update - should fail)

9. **Audit Logging:**
   - [ ] Upload contract - verify CONTRACT_UPLOADED log
   - [ ] Attest rights - verify RIGHTS_ATTESTED log
   - [ ] Disable contract - verify CONTRACT_DISABLED log
   - [ ] Accept terms - verify TERMS_ACCEPTED log

10. **Migration:**
    - [ ] Run `backfillContractComplianceFields` Cloud Function
    - [ ] Verify existing contracts have `complianceStatus: 'active'`
    - [ ] Verify existing contracts have `isLicensedForm: false`

## Notes

- **User Agent Capture:** Currently returns null. Can be enhanced later with JavaScript interop for web.
- **Terms Version:** Current version is '1.0'. When updating terms, increment version and require re-acceptance.
- **Reconfirmation Period:** Currently 12 months. Can be adjusted in `ComplianceService.needsReconfirmation()`.
- **Legal Disclaimer:** Always shown in UI to avoid legal advice claims.

## Future Enhancements

1. Add JavaScript interop for user agent capture on web
2. Add email notifications for reconfirmation reminders
3. Add admin dashboard for viewing all disabled contracts across facilities
4. Add bulk disable/enable operations
5. Add document versioning with hash comparison
6. Add automated reconfirmation workflow (scheduled function)
