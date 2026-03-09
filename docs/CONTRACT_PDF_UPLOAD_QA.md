# Contract PDF Upload – QA Checklist

## Bug fixed
- **Symptom:** "Uploading file…" spinner never stopped; PDF did upload and appeared after navigating back.
- **Causes addressed:** (1) `computeDocumentHash` callable could hang and block completion. (2) No `finally` to always clear `_isUploading`. (3) Success path did not set `_isLoading = false` before showing dialog.

## Changes made
- **ContractService.uploadContractFile:** `computeDocumentHash` call is wrapped in a 10s timeout so upload completion is not blocked.
- **Contract creation screen:** `try`/`finally` always clears `_isUploading` (with `mounted` check). Success path sets `_isLoading = false` and `_uploadedFileName`. Same pattern in _updateContract for edit mode.
- **UI:** After upload, show filename, View (open URL), Replace (pick new file), Remove. Error path leaves upload button enabled for retry.

## QA checklist

- [ ] **Small PDF:** Choose a small PDF → Create Contract → spinner appears → within a few seconds spinner stops → "File uploaded" / filename with View, Replace, Remove → success dialog.
- [ ] **Larger PDF:** Same flow with a larger file; spinner stops when upload completes (no infinite spinner).
- [ ] **Error handling:** Simulate error (e.g. turn off network after selecting file, then Create Contract) → spinner stops → error message shown → user can pick file again and retry.
- [ ] **Navigate away mid-upload:** Start create with file, then tap Back before upload finishes → no crash; on next open of New Contract, no stuck spinner.
- [ ] **Replace PDF:** After upload, tap Replace → pick another PDF → Create Contract → new file is uploaded and shown.
- [ ] **View PDF:** After upload, tap View → PDF opens in browser/external app.
- [ ] **Edit contract:** Edit existing contract, attach new PDF → upload spinner stops → success; Replace/Remove work.

## Files touched
- `lib/services/contract_service.dart` – timeout on `computeDocumentHash`.
- `lib/screens/contract_creation_screen.dart` – `_isUploading` in `finally`, `_uploadedFileName`, View/Replace/Remove UI, `_openPdfUrl`, same pattern in _updateContract.
