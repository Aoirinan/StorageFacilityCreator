# Global DNR – Dev Notes & Testing

## Summary

- **New collection**: `global_dnr_entries` (root-level). Shared across all facilities; any authenticated SFC user can read. Create/update/delete restricted to facility owner/manager (and superadmin).
- **Evidence**: Subcollection `global_dnr_entries/{entryId}/evidence/{evidenceId}`. Storage path: `dnrEvidence/{entryId}/{evidenceId}/{filename}`.
- **Existing behavior**: Facility-scoped DNR at `facilities/{facilityId}/dnr` is unchanged. When a facility is selected in the DNR screen, the list still shows that facility’s local DNR entries.
- **Permission fix**: The previous "Error loading DNR entries: permission-denied" came from using a collection group over `facilities/.../dnr`, which required ownership of each facility. The **Global** list (tab "All Facilities") now reads from `global_dnr_entries`, which has a rule `allow read: if isAuthenticated()`, so any logged-in user can see the global list.

## How to test with two facility accounts

1. **Deploy rules and indexes**
   - Deploy Firestore rules: `firebase deploy --only firestore:rules`
   - Deploy Storage rules: `firebase deploy --only storage`
   - Deploy indexes: `firebase deploy --only firestore:indexes` (ensures `global_dnr_entries` index for `status` + `createdAt`)

2. **Account A (e.g. Texas facility)**
   - Log in as a user who is owner or manager of Facility A.
   - Go to **Delinquency** (or **DNR** from menu) → ensure **All Facilities** is selected in the facility dropdown.
   - Click **Add to Global DNR** and create an entry (name, email, phone, reason, facility = Facility A). Save.
   - Confirm the new entry appears in the Global DNR list.

3. **Account B (e.g. New York facility)**
   - Log in as a different user (owner/manager of Facility B, different Firebase Auth account).
   - Go to **DNR** → **All Facilities**.
   - Confirm you see the entry created by Account A (no permission-denied).
   - Use the search bar (name/email/phone) and confirm search works.
   - Open the entry (tap row) → detail screen with evidence section.
   - Optionally add evidence (Upload photo or document) and confirm it appears.
   - Optionally mark the entry **inactive** or **appealed** (if your user is staff of the creating facility or superadmin).

4. **Facility-scoped list (unchanged)**
   - With Account A, select **Facility A** in the dropdown. You should see only Facility A’s **facility-scoped** DNR list (`facilities/{id}/dnr`), not the global list.
   - Add/edit/archive entries there; confirm Tenants, Units, Contracts, Billing, Payments, and other Delinquency tabs still work as before.

## Files touched (additive only)

- **Firestore**: `firestore.rules` – new block for `global_dnr_entries` and `evidence` subcollection.
- **Storage**: `storage.rules` – new block for `dnrEvidence/`.
- **Indexes**: `firestore.indexes.json` – one composite index for `global_dnr_entries` (status, createdAt).
- **Models**: `lib/models/global_dnr_model.dart` (new).
- **Service**: `lib/services/global_dnr_service.dart` (new).
- **Providers**: `lib/providers/dnr_provider.dart` – new providers for global list, detail, evidence, search.
- **Screens**: `lib/screens/global_dnr_entry_screen.dart`, `lib/screens/global_dnr_detail_screen.dart` (new); `lib/screens/dnr_list_screen.dart` – when "All Facilities" is selected, list and search use the new global collection and "Add to Global DNR" / detail navigation added.

No existing collections, fields, routes, or components were renamed or removed.
