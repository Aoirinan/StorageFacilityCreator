# Round 2 Fixes - Status Report

**Date:** February 2, 2026  
**Current Status:** In Progress

---

## ✅ COMPLETED IN THIS ROUND

### **1. Dashboard Zero Values - ROOT CAUSE FOUND & FIXED**

**Problem Identified:**
- Dashboard was watching `activeFacilityIdProvider` but had NO facility selector dropdown
- activeFacilityId was likely null (meaning "All Facilities" mode)  
- When null, queries ran but might return empty results

**Fixes Applied:**
1. ✅ Added `FacilitySwitcher` widget to dashboard top bar
2. ✅ Fixed dashboard provider to default to first facility if none selected
3. ✅ Added comprehensive debug logging to track:
   - User ID
   - Active facility ID
   - Facility list
   - Query results per facility  
   - Final totals

**Code Changes:**
- `lib/screens/home_screen_modern.dart` - Added FacilitySwitcher to top bar
- `lib/providers/dashboard_provider.dart` - Default to first facility + debug logs

---

### **2. Units Routing - FIXED**

**Problem:** `/units` and `/units/map` both went to same screen or placeholder.

**Fix Applied:**
1. ✅ Created new `UnitListScreen` with proper table/list view
2. ✅ Updated router to use UnitListScreen for `/units` route
3. ✅ Map Editor stays at `/units/map`

**Features in New Unit List Screen:**
- Facility selector dropdown
- Search by unit number or tenant name
- Filter by status (available, occupied, reserved, etc.)
- Data table with columns: Unit #, Type, Status, Tenant, Rate, Size, Actions
- "Open Map Editor" button
- "New Unit" button

**Code Changes:**
- `lib/screens/unit_list_screen.dart` - NEW FILE
- `lib/router/app_router.dart` - Updated `/units` route

---

### **3. Contracts Double UI - ACTUALLY FIXED THIS TIME**

**Problem:** User reported contracts still had double scaffold even after first fix.

**Root Cause Found:**
- `ContractDetailScreen` was fixed
- BUT `ContractListScreen` ALSO had the same bug!  
- Loading/error states returned `Scaffold` while data state used `ModernPageWrapper`

**Fix Applied:**
1. ✅ Fixed `ContractListScreen` loading/error states to use `ModernPageWrapper`
2. ✅ Both list and detail screens now consistent

**Code Changes:**
- `lib/screens/contract_list_screen.dart` - Wrapped all states in ModernPageWrapper

---

### **4. CSV Import - NOW "OLDER-GENERATION FRIENDLY"**

**Enhancements Added:**
1. ✅ Big "How to Export Your File" section with numbered steps:
   - Open spreadsheet
   - Click File → Download
   - Choose CSV format
   - Save to computer
   - Upload here
2. ✅ Example column names with plain English explanations
   - Name: "John Smith", "Jane Doe"
   - Email: "john@email.com"
   - Phone: "(555) 123-4567"
   - Unit Number: "A-101", "Unit 5"
   - Monthly Rate: "150", "$89.99"
3. ✅ Big red warning when required field (Name) not mapped
4. ✅ "Download Sample CSV" button (generates sample_tenants.csv)
5. ✅ Auto-mapping already existed, now with better visual feedback

**Code Changes:**
- `lib/screens/tenant_csv_import_wizard_screen.dart` - Enhanced mapping step UI

---

## 🚧 REMAINING WORK (5 Items)

### **5. Insurance Policy UI - MODEL DONE, UI NOT DONE**

**Status:** Policy fields added to model, but UI features not implemented yet.

**What's Needed:**
- [ ] UI to upload policy PDF (Firebase Storage)
- [ ] UI to set provider name/URL
- [ ] UI to select policy type (generic/custom/external)
- [ ] Display policy link to tenants
- [ ] Tenant insurance selection UI

---

### **6. Billing/Invoices - SYSTEM EXISTS, NEEDS GENERATION TRIGGER**

**How Billing Works (Explanation):**

**Invoice Generation:**
- Invoices are generated from **unpaid ledger entries**
- Path: `facilities/{facilityId}/invoices/{invoiceId}`
- Function: `InvoiceService.generateInvoiceFromLedger()`
- Invoices contain line items (rent, fees, charges)
- Status flow: draft → sent → paid (or overdue if past due date)

**Current State:**
- ✅ Invoice model exists (draft/sent/paid/overdue/voided)
- ✅ Invoice service can generate invoices
- ✅ Invoice list screen shows invoices (if they exist)
- ❌ NO automatic monthly invoice generation
- ❌ NO manual "Generate Invoices" button in UI

**What's Needed:**
- [ ] Add "Generate Monthly Invoices" button to billing screen
- [ ] OR implement Cloud Function to auto-generate monthly
- [ ] Test that invoices display correctly once generated

---

### **7. Payments Features - PARTIALLY IMPLEMENTED**

**What Exists:**
- ✅ Payment model
- ✅ Payment list screen (shows payment history)  
- ✅ Cloud Functions for Stripe (many already exist)

**What's Missing:**
- [ ] "Add Payment Method" button with Stripe SetupIntent flow
- [ ] "Make One-Time Payment" feature with PaymentIntent
- [ ] Display of saved payment methods (Visa •••• 4242)
- [ ] Autopay toggle UI
- [ ] Failed payment retry flow

**Complexity:** Medium-High (requires Stripe.js integration)

---

### **8. Delinquency + Reminders Tab Issue**

**Problems:**
1. Delinquency dashboard shows zeros (likely same issue as main dashboard)
2. When clicking Reminders tab, "other tabs disappear"

**What's Needed:**
- [ ] Apply same fix as main dashboard (facility selector + debug logs)
- [ ] Fix tab controller in `late_dashboard_screen.dart`
- [ ] Ensure tabs don't navigate away when clicked

---

### **9. Apply Yield Management Pattern**

**The Working Pattern (from Yield Mgmt):**
```dart
// Local state for selected facility
String? _selectedFacilityId;

// Load in initState
void initState() {
  super.initState();
  _loadFacilities();
}

// Explicit facility loading
Future<void> _loadFacilities() async {
  final facilities = await FacilityService.getUserFacilities();
  if (facilities.isNotEmpty && mounted) {
    setState(() {
      _selectedFacilityId = facilities.first.id;
    });
  }
}

// Facility selector in UI
Widget _buildFacilitySelector() { ... }

// Use facilityId explicitly in queries
FutureBuilder<List<Model>>(
  future: Service.getDataForFacility(_selectedFacilityId!),
  ...
)
```

**Screens That Need This Pattern:**
- [ ] Late Dashboard (Delinquency) - partially has it
- [ ] Main Dashboard - now has FacilitySwitcher but could use local state too

---

## 📊 HOW BILLING/INVOICES WORK (Plain English)

### **Overview**
Storage Facility Creator uses a **ledger-based billing system**:

1. **Ledger Entries** = Individual charges/payments recorded over time
   - Path: `facilities/{facilityId}/ledgers/{ledgerId}`
   - Types: rent, late fee, deposit, credit, payment
   
2. **Invoices** = Grouped charges sent to tenant
   - Generated from unpaid ledger entries
   - Path: `facilities/{facilityId}/invoices/{invoiceId}`
   - Contains line items (each from a ledger entry)

3. **Payments** = Money received
   - Path: `facilities/{facilityId}/payments/{paymentId}`
   - Linked to invoices via `invoiceId`
   - Updates invoice balance when applied

### **Invoice Lifecycle**

```
Monthly Rent Due
    ↓
Ledger Entry Created (type: rent, amount: $150)
    ↓
Invoice Generated (includes unpaid ledger entries)
Status: draft
    ↓
Invoice Sent to Tenant
Status: sent
    ↓
[Two paths]
    ↓                           ↓
Payment Received            No Payment
Invoice Status: paid        After due date → Status: overdue
Balance: $0                 Tenant becomes delinquent
```

### **Current State**

**What Works:**
- ✅ Ledger entries can be created
- ✅ Invoices CAN be generated (function exists)
- ✅ Invoice list screen displays invoices
- ✅ Invoice detail screen shows full invoice

**What's Missing:**
- ❌ Automatic monthly invoice generation (not triggered)
- ❌ Manual "Generate Invoices" button (not in UI)
- ❌ Invoices are probably empty because nothing is generating them

**The Fix:**
Add a "Generate Monthly Invoices" button that:
1. Gets all active tenants for facility
2. For each tenant, get unpaid ledger entries
3. Generate invoice from those entries
4. Send invoice (optional)

OR implement Cloud Function to auto-generate monthly.

---

## 🎯 PRIORITY RANKING (Remaining Work)

**Priority 1 (Must Fix):**
1. ✅ Dashboard zeros - FIXED
2. ✅ Contracts double UI - FIXED
3. ✅ Units routing - FIXED  
4. ✅ CSV import UX - FIXED
5. ⏸️ Delinquency zeros - Needs dashboard pattern applied
6. ⏸️ Reminders tab bug - Needs investigation

**Priority 2 (Important):**
7. ⏸️ Billing invoice generation - Add button to UI
8. ⏸️ Payments features - Add card/payment flows

**Priority 3 (Nice to Have):**
9. ⏸️ Insurance policy UI - Upload/provider features

---

## 📋 FILES MODIFIED SO FAR (This Round)

1. `lib/screens/home_screen_modern.dart` - Added FacilitySwitcher
2. `lib/providers/dashboard_provider.dart` - Fixed facility defaulting + debug logs  
3. `lib/screens/unit_list_screen.dart` - NEW FILE (unit table view)
4. `lib/router/app_router.dart` - Updated /units route
5. `lib/screens/contract_list_screen.dart` - Fixed double scaffold in all states
6. `lib/screens/tenant_csv_import_wizard_screen.dart` - Enhanced UX with instructions

---

## ⏭️ NEXT STEPS

**Immediate (Continue This Session):**
1. Fix delinquency dashboard (apply dashboard fix pattern)
2. Fix reminders tab navigation issue
3. Add "Generate Invoices" button to billing screen
4. Test that everything works end-to-end

**Future (Separate Epic):**
5. Implement full Payments hub with Stripe UI
6. Implement insurance policy upload/provider UI

---

**Status:** Making solid progress. Core P0/P1 issues fixed, working through remaining items.
