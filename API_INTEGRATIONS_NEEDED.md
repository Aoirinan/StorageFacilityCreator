# API Integrations Needed
**Date:** January 23, 2026  
**Status:** Post-Stage 8 Implementation Review

---

## Overview

After completing all 8 stages, here are the API integrations that need to be implemented to make the new features fully functional.

---

## 1. AI Assistant - LLM API Integration ⚠️ **HIGH PRIORITY**

### Current Status
- ✅ Infrastructure complete (models, services, Cloud Functions)
- ❌ **Missing:** Actual LLM API integration

### What's Needed
- **Provider Options:**
  - OpenAI (GPT-4, GPT-3.5)
  - Anthropic (Claude)
  - Google (Gemini)
  - Azure OpenAI

### Implementation Steps
1. **Choose Provider** (recommend OpenAI or Anthropic)
2. **Add API Key to Firebase Secrets:**
   ```bash
   firebase functions:secrets:set OPENAI_API_KEY
   # or
   firebase functions:secrets:set ANTHROPIC_API_KEY
   ```
3. **Update `functions/src/index.ts`:**
   - Install SDK: `npm install openai` or `npm install @anthropic-ai/sdk`
   - Replace placeholder in `aiAssistant()` function
   - Implement prompt engineering for action detection
   - Handle API errors gracefully
4. **Configure in Firestore:**
   - Set `appConfig/aiAssistant.provider` to chosen provider

### Files to Modify
- `functions/src/index.ts` - `aiAssistant()` function (~150 lines to update)
- `functions/package.json` - Add LLM SDK dependency

### Estimated Effort
- **2-3 hours** for basic integration
- **4-6 hours** for proper prompt engineering and action detection

---

## 2. 2FA - Email OTP Generation ⚠️ **MEDIUM PRIORITY**

### Current Status
- ✅ Models ready (user model can store 2FA fields)
- ✅ SendGrid already integrated
- ❌ **Missing:** OTP generation/verification Cloud Functions

### What's Needed
- **OTP Generation:**
  - Generate 6-digit code
  - Store in Firestore with expiration (5-10 minutes)
  - Send via SendGrid email
- **OTP Verification:**
  - Verify code against stored value
  - Check expiration
  - Clear code after successful verification

### Implementation Steps
1. **Add Cloud Functions:**
   ```typescript
   export const generateOTP = functions.https.onCall(...)
   export const verifyOTP = functions.https.onCall(...)
   ```
2. **Create OTP Storage:**
   - Store in `users/{userId}/otpCodes/{codeId}` or temporary collection
   - Include: code, expiresAt, purpose (e.g., "sensitive_action")
3. **Send Email via SendGrid:**
   - Use existing `sendEmail` function or create dedicated OTP email template
4. **Add 2FA Service:**
   - `lib/services/two_factor_service.dart`
   - Methods: `requestOTP()`, `verifyOTP()`, `is2FAEnabled()`

### Files to Create/Modify
- `functions/src/index.ts` - Add `generateOTP()` and `verifyOTP()` functions
- `lib/services/two_factor_service.dart` - NEW
- `lib/models/user_model.dart` - Already has fields ready

### Estimated Effort
- **2-3 hours** for complete implementation

---

## 3. E-Signing - Dropbox Sign API ⚠️ **MEDIUM PRIORITY**

### Current Status
- ✅ Infrastructure complete (models, Cloud Functions skeleton)
- ✅ Webhook handler exists
- ❌ **Missing:** Actual Dropbox Sign API calls

### What's Needed
- **API Integration:**
  - Create signature requests
  - Send signature requests
  - Download signed PDFs
  - Handle webhook events (already partially done)

### Implementation Steps
1. **Add API Key to Firebase Secrets:**
   ```bash
   firebase functions:secrets:set DROPBOX_SIGN_API_KEY
   ```
2. **Install SDK:**
   ```bash
   cd functions
   npm install @dropbox/sign
   ```
3. **Update `esignCreateEnvelope()` function:**
   - Replace placeholder with actual API call
   - Create signature request
   - Store envelope ID
4. **Update Webhook Handler:**
   - Download signed PDF when `signature_request_signed` event received
   - Upload to Firebase Storage
   - Update contract status

### Files to Modify
- `functions/src/index.ts` - `esignCreateEnvelope()` function
- `functions/src/index.ts` - `esignWebhook()` function (download PDF part)
- `functions/package.json` - Add `@dropbox/sign` dependency

### Estimated Effort
- **3-4 hours** for complete integration

---

## 4. Portal Upgrades - Stripe Setup Intent ⚠️ **LOW PRIORITY**

### Current Status
- ✅ Stripe already integrated
- ✅ Setup Intent functionality exists in codebase
- ❌ **Missing:** Portal-specific Setup Intent flow

### What's Needed
- **Setup Intent for Portal:**
  - Create Setup Intent for tenant portal
  - Allow tenants to update payment methods
  - Store payment method for autopay

### Implementation Steps
1. **Add Cloud Function:**
   ```typescript
   export const createPortalSetupIntent = functions.https.onCall(...)
   ```
2. **Update Portal Service:**
   - Add method to create Setup Intent
   - Handle payment method updates
3. **Update Portal UI:**
   - Add payment method update section
   - Add autopay toggle

### Files to Modify
- `functions/src/index.ts` - Add Setup Intent function
- `lib/services/tenant_portal_service.dart` - Add payment method methods
- `lib/screens/tenant_portal_screen.dart` - Add UI for payment method update

### Estimated Effort
- **2-3 hours** for complete implementation

---

## 5. Portal Upgrades - Invoice/Receipt Download ⚠️ **LOW PRIORITY**

### Current Status
- ✅ Invoice generation exists
- ❌ **Missing:** PDF download for portal

### What's Needed
- **PDF Generation:**
  - Generate invoice/receipt PDFs
  - Store in Firebase Storage
  - Provide signed URLs for download

### Implementation Steps
1. **Use Existing PDF Generation:**
   - Check if PDF generation already exists in codebase
   - If not, add PDF library (e.g., `pdf` package)
2. **Add Download Endpoint:**
   - Cloud Function to generate PDF on-demand
   - Or pre-generate and store in Storage
3. **Update Portal UI:**
   - Add download buttons for invoices/receipts

### Files to Modify
- `functions/src/index.ts` - Add PDF generation function (if needed)
- `lib/screens/tenant_portal_screen.dart` - Add download buttons

### Estimated Effort
- **2-3 hours** if PDF generation exists, **4-6 hours** if needs to be built

---

## Summary Table

| Feature | API/Service | Priority | Effort | Status |
|---------|------------|----------|--------|--------|
| AI Assistant | OpenAI/Anthropic | HIGH | 2-6 hours | ❌ Not Integrated |
| 2FA OTP | SendGrid (existing) | MEDIUM | 2-3 hours | ❌ Not Integrated |
| E-Signing | Dropbox Sign | MEDIUM | 3-4 hours | ❌ Not Integrated |
| Portal Setup Intent | Stripe (existing) | LOW | 2-3 hours | ❌ Not Integrated |
| Portal PDF Download | PDF Generation | LOW | 2-6 hours | ❌ Not Integrated |

---

## Recommended Implementation Order

1. **AI Assistant (LLM)** - Most visible feature, high value
2. **2FA OTP** - Security enhancement, relatively quick
3. **E-Signing** - Business value, moderate complexity
4. **Portal Setup Intent** - User convenience, low complexity
5. **Portal PDF Download** - Nice-to-have, depends on existing PDF generation

---

## Already Integrated APIs ✅

These APIs are already integrated and working:
- ✅ **Stripe** - Payments, Connect, Payment Intents
- ✅ **SendGrid** - Email sending
- ✅ **Twilio** - SMS sending and receiving
- ✅ **Firebase** - Auth, Firestore, Storage, Functions

---

## Configuration Needed

### Firebase Secrets to Add
```bash
# AI Assistant
firebase functions:secrets:set OPENAI_API_KEY
# or
firebase functions:secrets:set ANTHROPIC_API_KEY

# 2FA (if using separate service, otherwise uses SendGrid)
# No additional secrets needed

# E-Signing
firebase functions:secrets:set DROPBOX_SIGN_API_KEY
```

### Firestore Config Documents to Create
```json
// appConfig/aiAssistant
{
  "enabled": false,
  "allowlistFacilityIds": [],
  "killSwitch": false,
  "provider": "openai" // or "anthropic"
}

// appConfig/newFeatures
{
  "twoFactorEnabled": false,
  "leadPipelineEnabled": false,
  "workOrdersEnabled": false,
  "portalUpgradesEnabled": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

---

## Next Steps

1. **Choose LLM Provider** - Recommend OpenAI (GPT-4) or Anthropic (Claude)
2. **Set up API Keys** - Add to Firebase Secrets
3. **Implement AI Assistant** - Replace placeholder with actual API calls
4. **Implement 2FA** - Add OTP generation/verification
5. **Implement E-Signing** - Complete Dropbox Sign integration
6. **Implement Portal Upgrades** - Add Setup Intent and PDF download

---

**Total Estimated Effort:** 11-22 hours for all integrations
