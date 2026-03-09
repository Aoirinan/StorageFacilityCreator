# Urgent Fixes Based on Screenshots

**Date:** February 2, 2026  
**Version Deployed:** v2.1.0  
**Status:** Issues found in production testing

---

## 🔴 ISSUES CONFIRMED FROM SCREENSHOTS

### **1. Dashboard Still Shows Zeros** ❌

**What I See in Screenshot:**
- Dashboard shows: 0 tenants, 0 units, $0 revenue, 0 past due
- Welcome shows "Keepsake Self Storage" (facility IS selected)
- NO facility dropdown visible in top-right

**Root Causes:**
1. ✅ FacilitySwitcher IS in code (line 354 of home_screen_modern.dart)
2. ❌ BUT it hides itself if user has only 1 facility (line 34-36 of facility_switcher.dart)
3. ❌ Dashboard still queries using activeFacilityIdProvider which might be null
4. ❌ No console logs visible (either not running or filtered out)

**The REAL Fix Needed:**
- Don't hide FacilitySwitcher even with 1 facility ✅ FIXED
- Dashboard needs to explicitly query "Keepsake Self Storage" facility
- Add visible logging or status indicator

---

### **2. Contracts STILL Has Double Sidebar** ❌ CRITICAL

**What I See:**
- TWO complete sidebars side-by-side
- Left sidebar: Normal menu
- Middle sidebar: Duplicate menu with same items

**Root Cause FOUND:**
- AppShell (ShellRoute wrapper) provides outer Scaffold + Sidebar
- ContractListScreen uses ModernPageWrapper which creates ANOTHER Scaffold + Sidebar
- **Comment in code says:** "Pages inside ShellRoute should NOT use ModernPageWrapper"
- I removed ModernPageWrapper from loading/error states BUT NOT from data state!

**The REAL Fix:**
- Remove ModernPageWrapper completely from ContractListScreen ✅ IN PROGRESS
- Just return content widgets
- AppShell handles all layout

---

### **3. Units Table View** ✅ **WORKS!**

**Confirmed Working:**
- Unit List screen shows proper table
- Has facility selector
- Shows unit data
- "Open Map Editor" button
- Expansion menu shows "Unit List" and "Map Editor" options

**This proves the pattern WORKS when implemented correctly!**

---

###**4. Reminders Tab Navigation** ❌

**What I See:**
- Clicking Reminders tab navigates to `/reminders` route
- Shows standalone reminders screen
- Delinquency tabs are gone

**Root Cause:**
- Tab controller has navigation logic (lines 56-78 of late_dashboard_screen.dart)
- When Reminders tab clicked, it calls `context.go(AppRoute.reminders)`
- This navigates AWAY from delinquency page

**The Fix:**
- Remove navigation from tab controller
- Show reminders content INLINE in tab
- Don't navigate away

---

## 🔧 FIXES BEING APPLIED NOW

### **Fix 1: Dashboard - Make Facility Selector Always Show**
✅ Done - removed hide logic from FacilitySwitcher

### **Fix 2: Dashboard - Debug Why Zeros**
Need to check:
- Is facility ID actually being passed to queries?
- Are tenants marked as isActive?
- Check actual Firestore data

### **Fix 3: Contracts - Remove ModernPageWrapper Completely**
✅ In Progress - stripping out all ModernPageWrapper usage

### **Fix 4: Reminders - Don't Navigate, Show Inline**
Need to fix tab controller to show content instead of navigating

---

## 🎯 WHAT I'M DEPLOYING NEXT

**Critical Fixes:**
1. ✅ FacilitySwitcher always shows (even with 1 facility)
2. ✅ Contracts completely stripped of ModernPageWrapper
3. ⏸️ Dashboard query debugging
4. ⏸️ Reminders tab inline content

**Building and deploying now...**

---

## 📊 WHY DASHBOARD MIGHT STILL SHOW ZEROS

**Hypothesis:**
1. FacilitySwitcher was hidden (only 1 facility)
2. activeFacilityIdProvider returned null (no selection made)
3. Dashboard queried in "All Facilities" mode
4. Query returned empty or failed silently

**With facility switcher now visible:**
- User can explicitly select facility
- This should trigger dashboard refresh
- Metrics should populate

**Alternative Issue:**
- Tenants in Firestore might have `isActive: false`
- Dashboard only counts active tenants
- Need to check actual data in Firestore

---

**Rebuilding and deploying corrected version now...**
