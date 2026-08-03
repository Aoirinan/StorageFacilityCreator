# Storage Facility Creator - Deployment Guide for Product Fixes

**Date:** February 2, 2026

## 🎯 Overview

This guide provides step-by-step instructions for deploying the critical product fixes to production.

---

## ✅ WHAT WAS FIXED

**Completed (P0-P1, P3-P5):**
- ✅ Dashboard metrics (tenants/units/revenue/past due)
- ✅ Delinquency consistency across app
- ✅ Contracts page double UI bug
- ✅ Removed Stripe Connect from sidebar
- ✅ Added insurance policy support + disclaimers
- ✅ Clarified Billing vs Payments naming
- ✅ Added Cloud Functions for automatic stats updates

**Deferred (Complex, Recommend Separate Epics):**
- ⏸️ Map editor tooltip positioning improvements
- ⏸️ Map editor drag/resize enhancements
- ⏸️ Payments hub complete redesign

---

## 📋 PRE-DEPLOYMENT CHECKLIST

### 1. Review Changes

**Modified Files:**
```
lib/services/facility_stats_service.dart         ✅ Enhanced stats computation
lib/providers/dashboard_provider.dart            ✅ Uses precomputed stats
lib/widgets/modern_sidebar.dart                  ✅ Removed Stripe Connect, renamed items
lib/screens/contract_detail_screen.dart          ✅ Fixed double scaffold
lib/screens/insurance_screen.dart                ✅ Added disclaimer banner
lib/models/insurance_plan_model.dart             ✅ Added policy fields
functions/src/facility_stats.ts                  ✅ NEW: Cloud Functions for stats
functions/src/index.ts                           ✅ Exports new functions
```

### 2. Verify Configuration

- [ ] Firebase project is set to correct environment (production/staging)
- [ ] Cloud Functions have sufficient memory allocation (recommend 512MB+)
- [ ] Firestore indexes are up to date
- [ ] Flutter dependencies are up to date (`flutter pub get`)

### 3. Backup Current State

```bash
# Export Firestore data (optional but recommended)
gcloud firestore export gs://YOUR_BUCKET/backups/$(date +%Y%m%d)

# Tag current production state in git
git tag -a production-pre-fixes -m "Production state before product fixes"
git push origin production-pre-fixes
```

---

## 🚀 DEPLOYMENT STEPS

### **Step 1: Deploy Cloud Functions**

```bash
# Navigate to functions directory
cd functions

# Install dependencies
npm install

# Build TypeScript
npm run build

# Deploy ONLY the new stats functions (safer than deploying all)
firebase deploy --only functions:onTenantWrite,functions:onUnitWrite,functions:updateAllFacilityStatsNightly,functions:updateFacilityStatsManual

# Verify deployment
firebase functions:log --only onTenantWrite --limit 5
```

**Expected Output:**
```
✔ functions[onTenantWrite]: Successful create operation.
✔ functions[onUnitWrite]: Successful create operation.
✔ functions[updateAllFacilityStatsNightly]: Successful create operation.
✔ functions[updateFacilityStatsManual]: Successful create operation.
```

**⚠️ CRITICAL:** If deployment fails with permission errors:
1. Verify Firebase project has Functions API enabled
2. Check IAM permissions for Cloud Functions service account
3. Ensure billing is enabled on project

---

### **Step 2: Initialize Facility Stats (One-Time)**

After deploying functions, you need to populate the stats documents for existing facilities.

**Option A: Use Firebase Console (Recommended for few facilities)**

1. Go to Firebase Console → Firestore
2. Open Firestore query tool
3. For each facility:
   - Navigate to `facilities/{facilityId}/stats`
   - Create document `current` if it doesn't exist
   - Leave it empty - the function will populate it

**Option B: Use Cloud Function (Recommended for many facilities)**

```javascript
// Run this script in Firebase Console → Functions → Test function
// Or create a temporary callable function

const admin = require('firebase-admin');
admin.initializeApp();

async function initAllStats() {
  const facilities = await admin.firestore().collection('facilities').get();
  
  for (const facilityDoc of facilities.docs) {
    console.log(`Initializing stats for ${facilityDoc.id}...`);
    try {
      // Trigger the manual update function
      const result = await admin.functions().httpsCallable('updateFacilityStatsManual')({
        facilityId: facilityDoc.id
      });
      console.log(`✅ ${facilityDoc.id}: ${result.data.success}`);
    } catch (error) {
      console.error(`❌ ${facilityDoc.id}:`, error.message);
    }
  }
}

initAllStats();
```

**Option C: Wait for Scheduled Function**

- Stats will auto-populate at next 2 AM ET run
- Monitor Cloud Functions logs after 2 AM

---

### **Step 3: Deploy Flutter Web App**

```bash
# Clean build artifacts
flutter clean

# Get dependencies
flutter pub get

# Build for web (production)
flutter build web --release --web-renderer canvaskit

# Test build locally (optional)
cd build/web
python3 -m http.server 8000
# Open http://localhost:8000 and test

# Deploy to Firebase Hosting
firebase deploy --only hosting

# Verify deployment
firebase hosting:channel:deploy production
```

**Expected Output:**
```
✔ hosting: version created and deployed
✔ Deploy complete!

Project Console: https://console.firebase.google.com/project/YOUR_PROJECT
Hosting URL: https://YOUR_PROJECT.web.app
```

---

### **Step 4: Verify Deployment**

**Immediate Checks (< 5 minutes):**

1. **Dashboard Loads**
   - Navigate to dashboard
   - Verify no console errors
   - Check that metrics show (even if zeros initially)

2. **Navigation Works**
   - Click through sidebar menu items
   - Verify "Billing (Invoices)" and "Payments (Transactions)" labels are correct
   - Verify "Stripe Connect" is NOT in sidebar

3. **Contracts Page**
   - Open Contracts page
   - Verify single sidebar (no duplication)
   - Open a contract detail
   - Verify clean layout

4. **Insurance Disclaimer**
   - Navigate to Insurance page
   - Verify disclaimer banner is visible and readable

---

### **Step 5: Trigger Stats Computation (If Not Done in Step 2)**

**For each facility with data:**

```bash
# Option 1: Via Firebase Console Functions tab
# Call: updateFacilityStatsManual
# Params: { "facilityId": "YOUR_FACILITY_ID" }

# Option 2: Via Flutter app (if you add a button)
# Call: FirebaseFunctions.instance.httpsCallable('updateFacilityStatsManual')

# Option 3: Wait for next tenant/unit change
# The onTenantWrite and onUnitWrite triggers will populate stats automatically
```

---

### **Step 6: Smoke Test Critical Flows**

**Test 1: Dashboard Metrics (5 min)**
1. Navigate to Dashboard
2. Verify tenant count shows correct number
3. Verify units count shows correct number
4. Verify revenue shows non-zero (if facility has active tenants)
5. Switch facility (if multiple) - verify metrics update

**Test 2: Delinquency Flow (3 min)**
1. Navigate to Delinquency page
2. Verify counts match dashboard "Past Due" count
3. If any late tenants, verify they appear in correct category

**Test 3: Contracts (2 min)**
1. Navigate to Contracts
2. Open a contract detail
3. Verify no double UI
4. Go back - verify navigation works

**Test 4: Insurance (2 min)**
1. Navigate to Insurance
2. Verify disclaimer is visible
3. Create or edit a plan - verify policy fields are present

---

## 🔍 MONITORING POST-DEPLOYMENT

### **Cloud Functions Logs**

Monitor for first 24 hours:

```bash
# View stats function logs
firebase functions:log --only onTenantWrite,onUnitWrite,updateFacilityStatsManual

# Watch for errors
firebase functions:log --only onTenantWrite --limit 50 | grep "❌"
```

**What to Watch For:**
- ✅ "Stats updated for facility" messages
- ❌ Any error messages about missing data
- ⚠️ Slow execution times (> 10 seconds per facility)

### **Firestore Monitoring**

1. Go to Firebase Console → Firestore → Usage
2. Check for spike in reads/writes (expected due to stats updates)
3. Verify document count increases in `facilities/{id}/stats` collection

### **User Feedback**

Monitor support channels for:
- Dashboard showing zeros (should be fixed)
- Contracts page layout issues (should be fixed)
- Missing delinquency data (should be fixed)

---

## 🐛 ROLLBACK PLAN

If critical issues arise:

### **Rollback Flutter App**

```bash
# Revert to previous hosting release
firebase hosting:rollback

# Or deploy previous git commit
git checkout production-pre-fixes
flutter build web --release
firebase deploy --only hosting
```

### **Rollback Cloud Functions**

```bash
# Functions are versioned, can rollback via Console
# Firebase Console → Functions → Select function → Rollback

# Or delete new functions
firebase functions:delete onTenantWrite
firebase functions:delete onUnitWrite
firebase functions:delete updateAllFacilityStatsNightly
firebase functions:delete updateFacilityStatsManual
```

---

## 📊 SUCCESS METRICS (7 Days Post-Deployment)

**Quantitative:**
- Dashboard load time < 2 seconds (avg)
- Zero "dashboard showing zeros" support tickets
- Zero "contracts double UI" support tickets
- Facility stats documents exist for 100% of active facilities
- Cloud Functions success rate > 99%

**Qualitative:**
- Users report accurate dashboard metrics
- Delinquency tracking is reliable and consistent
- Navigation is clearer and less confusing
- No new bugs introduced

---

## 🔗 ADDITIONAL RESOURCES

- Full Summary: `PRODUCT_FIXES_SUMMARY.md`
- Test Checklist: See PRODUCT_FIXES_SUMMARY.md Section "TEST CHECKLIST"
- Cloud Functions Code: `functions/src/facility_stats.ts`
- Firebase Console: https://console.firebase.google.com

---

## 📞 SUPPORT CONTACTS

**Deployment Issues:**
- Check Cloud Functions logs first
- Review Firestore security rules if permission errors
- Verify Firebase project billing is active

**Code Issues:**
- Review `PRODUCT_FIXES_SUMMARY.md` for detailed changes
- Check git commits for exact code changes
- Test locally with `flutter run -d chrome` before deploying

---

**End of Deployment Guide** | February 2, 2026
