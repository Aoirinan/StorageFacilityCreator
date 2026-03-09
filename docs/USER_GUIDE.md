# User Guide - Tenant Creation + CSV Import + E-Sign

## 🎉 What's New

Your Storage Facility Creator app now has three major new features:

1. **Enhanced Tenant Creation** - Create tenants with lease documents and E-signature support
2. **CSV Import Wizard** - Import multiple tenants at once from a spreadsheet
3. **E-Sign Integration** - Send lease agreements for electronic signature (Dropbox Sign)

---

## 📥 CSV Import - How to Use

### Step 1: Prepare Your CSV File
Create a CSV file with these columns (in any order):
- **Name** (required) - Tenant's full name
- **Email** (required) - Tenant's email address
- **Phone** (required) - Tenant's phone number
- **Unit Number** (required) - The storage unit number
- **Monthly Rate** (required) - Monthly rental rate (e.g., 150.00)
- **Notes** (optional) - Any additional notes

**Example CSV:**
```csv
Name,Email,Phone,Unit Number,Monthly Rate,Notes
John Doe,john@example.com,555-1234,A101,150.00,New tenant
Jane Smith,jane@example.com,555-5678,B205,200.00,Premium unit
```

### Step 2: Import the File
1. Go to the **Tenants** page (`/#/tenants`)
2. Select a facility from the dropdown
3. Click the **"Import CSV"** button
4. Follow the 5-step wizard:
   - **Step 1:** Upload your CSV file
   - **Step 2:** Map columns (auto-mapped, but you can adjust)
   - **Step 3:** Preview and validate the data
   - **Step 4:** Review duplicates (skip or include)
   - **Step 5:** See import results

### What Happens During Import
- ✅ System validates all required fields
- ✅ Detects duplicates by email, phone, or occupied unit
- ✅ Shows you exactly what will be imported
- ✅ Creates tenants and links them to units automatically
- ✅ Reports any errors with row numbers

---

## ✍️ E-Sign (Electronic Signature) - How to Use

### Setup (One-Time)

**Note:** E-sign requires Dropbox Sign API keys. Contact support or configure in Firebase Console.

1. **Create Lease Templates:**
   - Navigate to Lease Templates (from Settings or Contracts menu)
   - Click "Create Template"
   - Enter template name and Dropbox Sign template ID
   - Save the template

2. **Configure Secrets** (Admin only):
   - Set `DROPBOX_SIGN_API_KEY` in Firebase Functions secrets
   - Set `DROPBOX_SIGN_WEBHOOK_SECRET` in Firebase Functions secrets
   - Deploy E-sign Cloud Functions

### Using E-Sign When Creating Tenants

1. **Create a Tenant:**
   - Go to Tenants page → Click "Create Tenant"
   - Fill in tenant information
   - Scroll to **"Lease & Documents"** section

2. **Enable E-Sign:**
   - Toggle the E-sign switch ON
   - Select a lease template from the dropdown
   - Complete tenant creation

3. **What Happens:**
   - Tenant is created normally
   - E-sign envelope is automatically created
   - Lease agreement is sent to tenant's email
   - Tenant receives signing link

### Viewing E-Sign Status

1. **On Tenant Detail Page:**
   - Open any tenant's detail page
   - Scroll to **"E-Sign Documents"** section
   - See all envelopes and their status:
     - **Sent** - Email sent to tenant
     - **Viewed** - Tenant opened the document
     - **Signed** - Tenant completed signature
     - **Declined** - Tenant declined to sign
     - **Voided** - You cancelled the envelope

2. **Actions Available:**
   - **Resend** - Send the signing link again
   - **Void** - Cancel the envelope
   - **Download** - Get the signed PDF (when signed)

---

## 🔍 Where to Find Everything

### CSV Import
- **Location:** Tenants page (`/#/tenants`)
- **Button:** "Import CSV" (next to "Create Tenant")

### E-Sign Templates
- **Location:** `/lease-templates?facilityId=YOUR_FACILITY_ID`
- **Access:** From Settings or Contracts menu (add link as needed)

### E-Sign Status
- **Location:** Tenant Detail page
- **Section:** "E-Sign Documents" (appears when envelopes exist)

---

## ⚠️ Important Notes

### CSV Import
- ✅ Works immediately - no configuration needed
- ✅ Handles up to ~2000 rows (client-side)
- ✅ Larger files may need server-side import (future enhancement)
- ✅ Duplicates are detected but you can choose to skip or include them

### E-Sign
- ⚠️ Requires Dropbox Sign API keys to be configured
- ⚠️ Cloud Functions must be deployed with secrets
- ✅ App works fine without E-sign - features are simply hidden
- ✅ Once configured, E-sign works automatically

### Safety
- ✅ All new features are **additive** - nothing was removed
- ✅ Existing functionality **unchanged**
- ✅ All new fields are **optional**
- ✅ **No breaking changes** to existing data

---

## 🐛 Troubleshooting

### CSV Import Issues
- **"No tenants found"** - Check your CSV has a header row
- **"Column not mapped"** - Use the mapping step to assign columns
- **"Duplicate detected"** - Review duplicates and choose to skip or include

### E-Sign Issues
- **"E-sign not configured"** - API keys not set in Firebase
- **"No templates found"** - Create templates first in Lease Templates screen
- **"Envelope not sent"** - Check Cloud Functions are deployed and secrets are set

---

## 📞 Support

If you encounter issues:
1. Check the browser console for errors
2. Verify Firestore rules are deployed
3. Check Firebase Functions logs
4. Ensure all required fields are filled

---

**Last Updated:** January 23, 2026  
**Version:** 1.0.0
