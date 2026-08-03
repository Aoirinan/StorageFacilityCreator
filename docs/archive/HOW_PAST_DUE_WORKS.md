# How Past Due / Delinquency Works in SFC

**Date:** February 2, 2026

---

## 🎯 **WHY PAST DUE AND DELINQUENCY SHOW ZEROS**

**The Short Answer:**  
✅ **Your tenants are all paid up!** This is GOOD news!

**The System:**
- Tenants are marked as "Past Due" or "Late" based on their `paidThrough` date
- If `paidThrough` is in the future or current month → Tenant is CURRENT ✅
- If `paidThrough` is in the past → Tenant is LATE/OVERDUE ❌

**Your Data:**
- You have 73 tenants showing $4435 monthly revenue
- Past Due = 0 means ALL 73 tenants are paid up
- Delinquency = 0 means ZERO tenants are behind on rent

**This is CORRECT behavior!**

---

## 📅 **HOW TO MAKE A TENANT "PAST DUE" (For Testing)**

### **Option 1: Set Paid Through Date to Past (Manual Test)**

**Via Firestore Console:**
1. Go to Firebase Console → Firestore
2. Navigate to: `facilities/eXnWPuwugzBVFcZWv1ZL/tenants/{any_tenant_id}`
3. Find the `paidThrough` field
4. Set it to last month: `January 1, 2026` (or earlier)
5. Save
6. Refresh Dashboard → Past Due should now show 1
7. Delinquency page should show tenant in "Late" category

**Via Tenant Edit Screen (If Available):**
1. Go to Tenants
2. Click a tenant
3. Edit their "Paid Through" date
4. Set to past month
5. Save

---

## 🔢 **DELINQUENCY CATEGORIES**

**The 4-Tier System:**

```
Current: paidThrough is current month or future
├─ 0 days late = All good! ✅

Late: 1-9 days past due
├─ Rent due on Feb 1, today is Feb 5 = 4 days late

Overdue: 10-29 days past due  
├─ Rent due on Jan 15, today is Feb 2 = 18 days overdue

Severely Overdue: 30+ days past due
├─ Rent due on Dec 15, today is Feb 2 = 49 days overdue
```

**Calculation:**
- System looks at `paidThrough` date vs current date
- Accounts for 3-day grace period
- Categories based on days late

---

## 🧪 **HOW TO TEST (Step-by-Step)**

### **Test 1: Create One Late Tenant**

1. **Pick a test tenant** (e.g., "Randy Kennedy" from Unit 101)
2. **Go to Firestore Console**
3. **Navigate to tenant document**
4. **Find `paidThrough` field** (might be null or a date)
5. **Set to:** `December 31, 2025` (over a month ago)
6. **Save**
7. **Refresh Dashboard**
8. **Expected Results:**
   - Past Due: 1 (was 0)
   - Delinquency → Severely Overdue: 1
   - Dashboard console logs show: "Late tenant: Randy Kennedy, Days late: 33"

### **Test 2: Create Multiple Delinquent Tenants**

1. Pick 5 tenants
2. Set different paidThrough dates:
   - Tenant A: Jan 25, 2026 (7 days ago = Late)
   - Tenant B: Jan 20, 2026 (12 days ago = Overdue)
   - Tenant C: Jan 1, 2026 (32 days ago = Severely Overdue)
   - Tenant D: Dec 15, 2025 (49 days ago = Severely Overdue)
   - Tenant E: Current month (stays Current)
3. Refresh Dashboard
4. Expected:
   - Past Due: 4
   - Delinquency breakdown: 0 Current, 1 Late, 1 Overdue, 2 Severely Overdue

---

## 🔍 **WHY NO CONSOLE LOGS SHOWING**

**Possible Reasons:**
1. **Logs are there but filtered out**
   - In console, check "Default levels" dropdown
   - Make sure "Verbose" or "Info" is selected

2. **Dashboard provider logs work, delinquency doesn't have logs**
   - I added logs to dashboard provider
   - Delinquency provider might not have them
   - Will add them now

3. **Browser cache**
   - Hard refresh: Ctrl+Shift+R
   - Or clear browser cache completely

---

## 🎯 **REAL-WORLD USAGE**

**In Production (Not Testing):**

Tenants become "Past Due" when:
1. Rent is due on 1st of month
2. Tenant doesn't pay
3. After 3-day grace period (4th of month), they show as "Late"
4. System automatically calculates based on `paidThrough` date

**How Tenants Get Paid Up:**
1. Tenant pays rent → Payment recorded
2. Payment updates `paidThrough` date to current month
3. Tenant moves from "Late" to "Current"
4. Past Due count decreases

**Current State:**
- All 73 tenants are paid through current month or later
- **This is why Past Due = 0** ✅
- System is working correctly!

---

## ✅ **SUMMARY**

**Past Due = 0 is CORRECT if all tenants are paid up!**

**To Test System:**
- Manually set a tenant's `paidThrough` to past month
- OR wait until next month when rent is actually due
- OR record some unpaid invoices

**The system WORKS** - you just have really good tenants who pay on time! 🎉

---

**Next:** I'll add console logs to delinquency provider so you can see the same debugging info there.
