# UI Copy Update Summary

**Date:** January 27, 2026  
**Purpose:** Update UI text strings to match exact legal copy provided

## Files Changed

### 1. `lib/services/compliance_service.dart`
- **Updated:** `termsText` constant - Replaced with exact modal body text (preserving line breaks)
- **Added:** `rightsAttestationText` constant - Exact checkbox label text
- **Note:** `getTermsTextHash()` now hashes the exact modal body text

### 2. `lib/screens/contract_creation_screen.dart`
- **Updated:** Terms acceptance modal:
  - Title: "Contract Upload & e-Signing Terms"
  - Body: Exact text with numbered points (1) through 5)
  - Primary button: "I Agree & Enable"
  - Secondary button: "Decline"
  - Footnote: "We store an audit record of your acceptance..."
- **Updated:** Rights attestation checkbox:
  - Label: Exact text from `ComplianceService.rightsAttestationText`
  - Helper text: "You are responsible for ensuring you have any required rights, licenses, or memberships to use this document."
- **Updated:** Licensed form checkbox:
  - Label: "This is an association/licensed form (e.g., TSSA)."
  - Inline note: "You are responsible for maintaining any required membership/license to use this form. SFC does not verify membership status."
- **Removed:** Old legal disclaimer from compliance section (moved to Contract Library screen)
- **Updated:** `attestationText` variable to use `ComplianceService.rightsAttestationText` constant

### 3. `lib/screens/contract_list_screen.dart`
- **Added:** Disclaimer banner at top of contract list:
  - "Disclaimer: SFC provides document and e-signature tooling only. You are responsible for the documents you upload and use, including any licensing or membership requirements."

## Text Strings (Exact Copy)

### A) Rights Attestation Checkbox
**Label (required):**
"I confirm I have the legal right to upload and use this document and to request signatures for it (including any association or licensed forms)."

**Helper text:**
"You are responsible for ensuring you have any required rights, licenses, or memberships to use this document."

### C) Licensed Form Checkbox
**Label (optional):**
"This is an association/licensed form (e.g., TSSA)."

**Inline note (shown when checked):**
"You are responsible for maintaining any required membership/license to use this form. SFC does not verify membership status."

### D) Terms Acceptance Modal
**Title:**
"Contract Upload & e-Signing Terms"

**Body:**
"Storage Facility Creator ("SFC") provides tools to upload documents and request electronic signatures. SFC does not provide legal advice and does not create, own, or license the documents you upload.

By enabling contract upload and e-signing for your facility, you agree that:

1) Your documents; your responsibility. You are solely responsible for the documents you upload, send, and use (including any association or licensed forms).

2) Rights and permissions. You represent and warrant that you have all necessary rights, permissions, licenses, and consents to upload, store, send, and request signatures on the documents you use in SFC.

3) No distribution by SFC. You understand SFC does not provide association forms or distribute third-party contracts to other customers.

4) Takedown / disabling. If SFC receives a complaint, legal notice, or otherwise believes a document may be unauthorized, SFC may disable the document/template and suspend its use for new signature requests.

5) Indemnification. You agree to defend and indemnify SFC from claims, damages, liabilities, and expenses (including reasonable attorneys' fees) arising out of your documents, your use of third-party or licensed forms, or your violation of any rights or laws."

**Buttons:**
- Primary: "I Agree & Enable"
- Secondary: "Decline"

**Footnote:**
"We store an audit record of your acceptance (date/time, facility, and Terms version)."

### I) Disclaimer (Contract Library Screen)
"Disclaimer: SFC provides document and e-signature tooling only. You are responsible for the documents you upload and use, including any licensing or membership requirements."

## Data Storage

- **`attestationText`** in Firestore: Stored exactly as the checkbox label text (from `ComplianceService.rightsAttestationText`)
- **`termsAcceptance.textHash`** in Firestore: SHA-256 hash of the exact modal body text (from `ComplianceService.getTermsTextHash()`)

## Quick UI Check Checklist

- [ ] Terms modal shows exact title "Contract Upload & e-Signing Terms"
- [ ] Terms modal body matches exact text with numbered points (1) through 5)
- [ ] Terms modal has "I Agree & Enable" and "Decline" buttons
- [ ] Terms modal shows footnote about audit record
- [ ] Rights attestation checkbox shows exact label text
- [ ] Helper text appears below rights attestation checkbox
- [ ] Licensed form checkbox shows exact label text
- [ ] Licensed form note shows "SFC does not verify membership status" when checked
- [ ] Disclaimer appears at top of Contract Library screen
- [ ] All text wraps properly on web (no overflow)
- [ ] Terms modal scrolls if content is long
- [ ] Attestation text stored in Firestore matches checkbox label exactly

## Notes

- No architecture changes made
- No data model changes made
- No new dependencies added
- Audit log events remain unchanged (TERMS_ACCEPTED, RIGHTS_ATTESTED, RIGHTS_RECONFIRMED)
- All functionality preserved - only UI text strings updated
