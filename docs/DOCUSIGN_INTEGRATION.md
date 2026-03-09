# DocuSign Integration (Planned)

This doc describes where and how **DocuSign eSignature API** will plug into Storage Facility Creator for sending lease/contract envelopes and handling completed signatures.

---

## Current contract flow (in-app signing)

1. **Create contract** – `ContractService.createContract()` → Firestore `facilities/{facilityId}/contracts/{contractId}` (draft).
2. **Send for signature** – `ContractService.sendContractForSignature()` generates a signing token, stores it on the contract, and (optionally) emails a link to the tenant.
3. **Tenant signs** – Tenant opens link → `ContractSigningScreen` (Flutter): in-app signature pad + PDF generation via `pdf`/`printing` packages; signed PDF uploaded to Storage, contract updated with `signedAt`, `signedFileUrl`, `signedBy`.

**Relevant code:**

- **Flutter:** `lib/services/contract_service.dart`, `lib/screens/contract_signing_screen.dart`
- **Firestore:** `facilities/{facilityId}/contracts/{contractId}` with `signingToken`, `signingTokenExpiresAt`, `signedAt`, `signedFileUrl`, `signedBy`
- **Security:** Contract lookup by `signingToken` (e.g. via callable or rules) for unauthenticated tenant access

---

## Where DocuSign will integrate

### Option A: DocuSign as alternative to in-app signing

- When facility sends a contract for signature, offer **“Send with DocuSign”** (in addition to or instead of “Send link”).
- **Backend (Cloud Function):**
  - New callable, e.g. `createDocuSignEnvelope(contractId, facilityId, signerEmail, signerName)`.
  - Call DocuSign API: create envelope from contract PDF (or template), add signer, send. Store `envelopeId` (and optionally `envelopeStatus`) on the contract document or a subcollection.
- **Webhook:** DocuSign Connect (webhook) → HTTPS Cloud Function when envelope is completed (or declined).
  - On “completed”: download signed document from DocuSign, upload to Firebase Storage, update contract with `signedAt`, `signedFileUrl`, `signedBy`, clear `signingToken` if desired.
- **Flutter:** Contract detail can show “Sent via DocuSign” and link to DocuSign signing URL if still pending; after webhook, show as signed like current flow.

### Option B: DocuSign-only (replace in-app signing)

- Same as above but remove or deprecate in-app signature pad for lease contracts; all contracts go through DocuSign.

### Data to store for DocuSign

- On contract (or `facilities/{fid}/contracts/{cid}/docusign` subcollection):
  - `docusignEnvelopeId`
  - `docusignEnvelopeStatus` (e.g. `sent`, `completed`, `declined`)
  - `docusignSentAt`
  - Keep existing `signedAt`, `signedFileUrl`, `signedBy` for the final signed PDF (filled by webhook).

---

## Implementation checklist (when building)

- [ ] DocuSign developer account and API credentials (Integration Key, Secret); store in Firebase Secret Manager.
- [ ] Cloud Function: create envelope (upload document or use template), set signer, return signing URL; save `envelopeId` on contract.
- [ ] Cloud Function: DocuSign Connect webhook (signature completed) → verify webhook secret, fetch signed document, upload to Storage, update contract.
- [ ] Flutter: “Send with DocuSign” from contract detail/creation; optional “View in DocuSign” link for pending envelopes.
- [ ] Firestore rules: allow webhook to update contract (or use Admin SDK in the function).
- [ ] Cost: DocuSign charges per envelope (see `docs/SIMULATION_100_FACILITIES.md` §7 and `scripts/simulate_100_facilities.js --cost`). Plan choice (Starter / Pro / etc.) and volume affect monthly cost.

---

## References

- DocuSign eSignature REST API: create envelope, get document, webhooks (Connect).
- Current contract model: `lib/models/contract_model.dart`
- Current send/sign flow: `ContractService.sendContractForSignature()`, `ContractSigningScreen`, `ContractService.getContractBySigningToken()`
