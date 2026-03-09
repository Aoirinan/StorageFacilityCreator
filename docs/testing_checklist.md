# Testing Checklist - Tenant Creation + CSV Import + E-Sign

## ✅ Basic Functionality Tests

### 1. Tenants Page
- [ ] Navigate to `/#/tenants`
- [ ] Page loads without errors
- [ ] Facility dropdown displays and works
- [ ] Search functionality works
- [ ] Existing tenants display correctly

### 2. CSV Import (Ready to Test)
- [ ] Click "Import CSV" button
- [ ] Wizard opens with 5 steps
- [ ] **Step 1:** Upload CSV file
  - [ ] File picker works
  - [ ] CSV file loads correctly
  - [ ] Shows row count
- [ ] **Step 2:** Column Mapping
  - [ ] Auto-mapping works (recognizes common column names)
  - [ ] Can manually change mappings
  - [ ] Required fields marked with *
- [ ] **Step 3:** Preview & Validate
  - [ ] Shows parsed data preview
  - [ ] Validation errors displayed
  - [ ] Can proceed if valid
- [ ] **Step 4:** Duplicate Handling
  - [ ] Duplicates detected correctly
  - [ ] Shows duplicate reasons
  - [ ] Can toggle "Skip Duplicates"
- [ ] **Step 5:** Import Results
  - [ ] Shows success/error counts
  - [ ] Error details displayed
  - [ ] "Back to Tenants List" works

### 3. Tenant Creation
- [ ] Click "Create Tenant" button
- [ ] Form loads with all sections:
  - [ ] Basic info (name, email, phone, unit, rate)
  - [ ] Identification section
  - [ ] Contacts section
  - [ ] Vehicles section
  - [ ] Portal Access section
  - [ ] **Lease & Documents section** (NEW)
  - [ ] Notes section
- [ ] Fill in required fields
- [ ] Submit form
- [ ] Tenant created successfully
- [ ] Navigates to tenant detail or shows success message

### 4. Tenant Detail Page
- [ ] Open any tenant detail page
- [ ] All existing sections display
- [ ] **E-Sign Documents section** appears (if envelopes exist)
- [ ] Page loads without errors

---

## ⚠️ E-Sign Tests (After API Key Configuration)

### 5. Lease Templates
- [ ] Navigate to `/lease-templates?facilityId=YOUR_FACILITY_ID`
- [ ] Page loads
- [ ] "Create Template" button works
- [ ] Create template dialog opens
- [ ] Can create template with:
  - [ ] Template name
  - [ ] Description (optional)
  - [ ] Provider Template ID (optional)
  - [ ] Notes (optional)
- [ ] Template saved successfully
- [ ] Template appears in list
- [ ] Can activate/deactivate template
- [ ] Can delete template

### 6. E-Sign in Tenant Creation
- [ ] Create new tenant
- [ ] Scroll to "Lease & Documents" section
- [ ] Toggle E-sign switch ON
- [ ] Template dropdown appears (if templates exist)
- [ ] Select template
- [ ] Complete tenant creation
- [ ] E-sign envelope created (check Firestore)
- [ ] Error message if API key not configured (expected)

### 7. E-Sign Status in Tenant Details
- [ ] Open tenant with E-sign envelope
- [ ] "E-Sign Documents" section visible
- [ ] Envelope status displayed correctly
- [ ] Can resend envelope (if not signed/voided)
- [ ] Can void envelope (if not signed/voided)
- [ ] Can download signed PDF (if signed)

### 8. Cloud Functions (After API Key Config)
- [ ] Call `esignCreateEnvelope` - creates envelope
- [ ] Webhook receives events from Dropbox Sign
- [ ] Envelope status updates in Firestore
- [ ] Signed PDF downloaded and stored
- [ ] Contract status updated when signed

---

## 🐛 Error Scenarios to Test

### CSV Import Errors
- [ ] Upload invalid CSV (wrong format)
- [ ] Upload CSV with missing required columns
- [ ] Upload CSV with invalid data (bad email, negative rate)
- [ ] Import with duplicates - verify skip/include works
- [ ] Large file import (test performance)

### E-Sign Errors (Expected Until Configured)
- [ ] Try to create envelope without API key
- [ ] Verify error message is clear and helpful
- [ ] App continues to work normally
- [ ] Other features unaffected

---

## 📊 Data Verification

### After CSV Import
- [ ] Check Firestore: `facilities/{facilityId}/tenants`
- [ ] Verify all tenants created
- [ ] Verify units linked correctly
- [ ] Verify no duplicate tenants created
- [ ] Check tenant list page shows new tenants

### After E-Sign (When Configured)
- [ ] Check Firestore: `facilities/{facilityId}/esignEnvelopes`
- [ ] Verify envelope document created
- [ ] Verify status updates correctly
- [ ] Verify signed PDF stored in Storage
- [ ] Verify contract updated when signed

---

## 🎯 Success Criteria

✅ **CSV Import:**
- Can import 10+ tenants successfully
- Duplicates detected and handled
- Errors reported clearly
- All tenants appear in list

✅ **Tenant Creation:**
- Form works end-to-end
- All sections functional
- E-sign section visible (even if not configured)
- No errors in console

✅ **E-Sign (When Configured):**
- Templates can be created
- Envelopes created successfully
- Webhook processes events
- Status updates correctly
- Signed PDFs downloadable

---

## 📝 Notes

- All features are **additive** - nothing was removed
- App works **without E-sign configured**
- E-sign features **hidden/disabled** until API keys set
- **No breaking changes** to existing functionality

---

**Ready for testing!** 🚀
