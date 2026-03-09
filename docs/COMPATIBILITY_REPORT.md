# Compatibility Report - Tenant Creation + CSV Import + E-Sign Integration

**Date:** January 23, 2026  
**Purpose:** Audit existing codebase before implementing new features

## Current Firestore Structure

### Tenants
- **Path:** `facilities/{facilityId}/tenants/{tenantId}`
- **Key Fields:**
  - `facilityId` (string, required)
  - `name`, `email`, `phone` (required)
  - `unitNumber`, `monthlyRate` (required)
  - `contractUrl` (string, optional) - currently just a URL string
  - `emergencyContacts[]`, `vehicles[]`, `occupants[]`, `addresses[]` (arrays)
  - `createdBy` (uid, required for security rules)
  - `isActive`, `isOnDNR` (booleans)
  - Search fields: `nameLower`, `emailLower`, `phoneDigits`
- **Service:** `TenantService` in `lib/services/tenant_service.dart`
- **Model:** `TenantModel` in `lib/models/tenant_model.dart`

### Units
- **Path:** `facilities/{facilityId}/units/{unitId}`
- **Key Fields:**
  - `tenantId`, `tenantName` (set when occupied)
  - `status` (enum: available, occupied, reserved, etc.)
  - `unitNumber`, `monthlyRate`
  - `moveInDate`, `moveOutDate`
- **Relationship:** Tenant creation automatically creates/updates unit occupancy via `_updateUnitOccupancy()`

### Contracts
- **Path:** `facilities/{facilityId}/contracts/{contractId}`
- **Key Fields:**
  - `facilityId`, `facilityOwnerUid`, `tenantId` (required)
  - `title`, `description`, `type`, `status`
  - `templateId` (string, optional) - already exists!
  - `fileUrl`, `signedFileUrl` (strings, optional)
  - `sentAt`, `signedAt`, `expiresAt` (timestamps)
  - `createdBy`, `sentBy`, `signedBy` (uids)
- **Service:** `ContractService` in `lib/services/contract_service.dart`
- **Model:** `ContractModel` in `lib/models/contract_model.dart`
- **Status Enum:** draft, sent, signed, expired, cancelled

## Current Routes & Screens

### Tenant Routes
- `/tenants` → `ClientListScreen` (tenant list with search/filter)
- `/tenant-detail` → `ClientDetailScreen` (tenant details view)
- Tenant creation: `TenantCreationScreen` (comprehensive form, already exists)

### Contract Routes
- `/contracts` → `ContractListScreen`
- `/contracts/create` → `ContractCreationScreen`
- `/contracts/:id` → `ContractDetailScreen`

## Current Services/Repositories

1. **TenantService** (`lib/services/tenant_service.dart`)
   - `createTenant()` - creates tenant + updates unit
   - `getTenantsForFacilityStream()` - real-time stream
   - `updateTenant()`, `archiveTenant()`, `deleteTenant()`
   - `_updateUnitOccupancy()` - helper for unit linkage

2. **ContractService** (`lib/services/contract_service.dart`)
   - `createContract()` - creates contract
   - `getContractsForFacilityStream()` - real-time stream
   - `getContractsForTenant()` - tenant-specific contracts

3. **UnitService** (`lib/services/unit_service.dart`)
   - Unit CRUD operations
   - Auto-creates units if missing during tenant creation

## Facility Scoping

- **Method:** Dropdown in `ClientListScreen` selects `_selectedFacilityId`
- **Provider:** `facilityTenantsProvider` (StreamProvider.family) scoped by facilityId
- **Security:** Firestore rules check `isFacilityOwnerOrManager(facilityId)`
- **Current Pattern:** All tenant queries filter by `facilityId` field

## CSV Import (Current State)

- **Location:** `ClientListScreen._importTenantsFromCsv()` (lines 599-663)
- **Current Implementation:**
  - Basic file picker
  - Simple CSV parsing (expects fixed column order: Name, Email, Phone, Unit, Rate, Notes)
  - No column mapping wizard
  - No duplicate detection
  - No preview/validation step
  - Direct import loop (no batch/transaction)

## Risks & Mitigation Strategy

### Risk 1: Breaking Existing Tenant Creation
- **Mitigation:** Keep `TenantCreationScreen` unchanged. Add new enhanced version alongside or enhance existing one incrementally.

### Risk 2: Firestore Schema Changes
- **Mitigation:** All new fields will be OPTIONAL. Existing queries will continue to work.

### Risk 3: Breaking Contracts Module
- **Mitigation:** E-sign fields added to contracts will be optional. Existing contract flows remain unchanged.

### Risk 4: Unit Relationship Changes
- **Mitigation:** Reuse existing `_updateUnitOccupancy()` pattern. No changes to unit structure.

### Risk 5: Route Conflicts
- **Mitigation:** Use new route paths for CSV import wizard. Add E-sign as tab/section in existing screens.

### Risk 6: Security Rules
- **Mitigation:** Add new collections/fields to Firestore rules incrementally. Test with existing rules first.

## Implementation Plan

### Phase A: Enhanced Tenant Creation + CSV Import
1. Enhance `TenantCreationScreen` with multi-section UI (already comprehensive, may add E-sign section)
2. Create `TenantCsvImportWizardScreen` with:
   - Upload step
   - Column mapping step
   - Preview/validation step
   - Duplicate handling step
   - Import progress + results
3. Add "Import CSV" button to `ClientListScreen` (replace existing basic import)

### Phase B: E-Sign Integration
1. Create E-sign models (`EsignEnvelopeModel`, `LeaseTemplateModel`)
2. Create E-sign service (`EsignService`) - client-side wrapper
3. Create Cloud Functions:
   - `esignCreateEnvelope`
   - `esignWebhookDropboxSign`
   - `esignResendEnvelope` (optional)
   - `esignVoidEnvelope` (optional)
4. Add E-sign section to `TenantCreationScreen` (Lease & Docs section)
5. Add E-sign tab to `ClientDetailScreen` or `ContractDetailScreen`
6. Create `LeaseTemplatesScreen` for template management
7. Update Firestore rules for new collections

## Backward Compatibility Guarantees

✅ **Tenant Model:** All new fields optional, existing code unaffected  
✅ **Contract Model:** E-sign fields optional, existing contracts work  
✅ **Routes:** New routes added, existing routes unchanged  
✅ **Services:** New methods added, existing methods unchanged  
✅ **Firestore Rules:** Additive changes only  
✅ **UI:** New screens/buttons added, existing UI unchanged  

## Testing Checklist

- [ ] `/tenants` page loads without errors
- [ ] Facility dropdown works
- [ ] Existing tenant creation works
- [ ] Existing tenant detail view works
- [ ] CSV import wizard works (small files)
- [ ] E-sign hidden when not configured
- [ ] E-sign visible when configured
- [ ] No secrets in client code
- [ ] Build passes
- [ ] Firestore rules allow new collections

---

**Status:** ✅ Ready to proceed with implementation
