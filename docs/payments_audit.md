# Payment Architecture Audit Report

**Date:** 2024  
**Scope:** Complete codebase audit for PCI compliance and payment security

## Executive Summary

The codebase currently uses Stripe for payment processing with a **mostly PCI-safe architecture**. No raw card numbers, CVV, or PAN data were found in the codebase. However, several improvements are needed to fully align with PCI best practices and enhance security posture.

## Current State

### ✅ Good Practices Found

1. **No Raw Card Data Collection**
   - No `cardNumber`, `cvv`, `cvc`, or `pan` fields found in UI code
   - Payment methods store only safe metadata: `stripePaymentMethodId`, `last4`, `brand`, `expiryMonth`, `expiryYear`
   - All payment processing happens server-side via Firebase Functions

2. **Stripe Integration**
   - Stripe.js v3 loaded in `web/index.html`
   - Server-side Stripe client initialized with secrets from Firebase Secret Manager
   - Webhook handler exists with signature verification
   - PaymentIntent creation is server-side only

3. **Data Storage**
   - Payment methods stored in Firestore with only tokenized IDs
   - No full card numbers in database
   - Safe metadata only (last4, brand, expiry)

### ⚠️ Areas for Improvement

1. **Missing SetupIntent Flow**
   - No SetupIntent creation for saving cards for autopay
   - Autopay currently relies on existing `stripePaymentMethodId` but no secure capture flow exists

2. **Card Capture Method**
   - No Stripe Elements integration found in Flutter Web UI
   - Need to implement secure card capture using Stripe Elements or hosted iframe

3. **Security Headers**
   - Basic headers exist but CSP is minimal (`upgrade-insecure-requests` only)
   - Need comprehensive CSP with frame-src for Stripe

4. **Error Monitoring**
   - No Sentry or Crashlytics integration found
   - Need structured error tracking for payment failures

5. **Log Scrubbing**
   - Payment-related logs may contain sensitive metadata
   - Need to redact PII from logs

6. **Webhook Event Coverage**
   - Missing `setup_intent.succeeded` handler
   - Should add more comprehensive event handling

## Risk Assessment

### Low Risk ✅
- No raw card data in codebase
- Server-side payment processing
- Secrets stored in Firebase Secret Manager

### Medium Risk ⚠️
- No secure card capture UI (users may enter cards elsewhere)
- Limited CSP protection
- No error monitoring for payment failures

### High Risk ❌
- None identified

## Proposed Architecture

### Phase 1: Stripe-First PCI-Safe Flow

1. **Customer Setup**
   - Server-side function to create/attach Stripe Customer when billing enabled
   - Store: `stripeCustomerId`, `defaultPaymentMethodId`, `subscriptionId`
   - Never store full card details

2. **Card Capture (Web)**
   - Implement Stripe Elements via isolated HTML/JS component
   - Use `postMessage` to communicate PaymentMethod ID back to Flutter
   - Client only receives PaymentMethod ID, never card data

3. **Autopay Setup**
   - Use SetupIntents for saving cards
   - Server creates SetupIntent → client confirms → server attaches to customer
   - Store PaymentMethod ID + display info (brand/last4/exp)

4. **Charges**
   - PaymentIntents for one-time and off-session charges
   - All intents created server-side
   - Client only confirms if 3DS required

5. **Webhooks**
   - Enhanced webhook handler with full event coverage
   - Idempotent updates to Firestore
   - Handle: `payment_intent.*`, `setup_intent.succeeded`, `invoice.*`, `customer.subscription.*`

### Phase 2: Security Headers + CSP

- Add comprehensive security headers
- Implement strict CSP with Stripe domains whitelisted
- Frame-ancestors for Stripe iframes

### Phase 3: Monitoring + Logging

- Add Sentry for error tracking
- Implement log scrubbing for payment endpoints
- Add alerting for webhook failures

### Phase 4: Marketing Security Pitch

- Add security messaging to marketing landing page
- Highlight PCI compliance and Stripe-powered payments

## Files to Modify

### New Files
- `docs/payments_architecture.md` - Architecture documentation
- `web/stripe_card_capture.html` - Isolated Stripe Elements page
- `lib/services/setup_intent_service.dart` - SetupIntent service
- `lib/services/error_monitoring_service.dart` - Sentry integration

### Modified Files
- `functions/src/index.ts` - Add SetupIntent creation, enhance webhooks, add log scrubbing
- `firebase.json` - Add comprehensive security headers and CSP
- `web/index.html` - Update CSP meta tag
- `lib/screens/marketing_landing_page.dart` - Add security pitch section
- `functions/package.json` - Add Sentry dependency

## Migration Notes

- Existing payment methods using `stripePaymentMethodId` are safe and will continue to work
- New card capture flow will be opt-in for new payment methods
- No breaking changes to existing autopay functionality

## Acceptance Criteria

1. ✅ No raw card fields in UI or API payloads (verified via grep)
2. ⏳ Payment capture uses Stripe Elements and only returns PaymentMethod IDs
3. ⏳ Webhooks update billing state correctly
4. ⏳ Error monitoring enabled and receives test exceptions
5. ⏳ CSP + headers don't break app, Stripe still works
6. ⏳ Marketing copy visible on site
