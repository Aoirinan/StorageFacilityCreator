# Stripe Connect Smoke Test Checklist

**Purpose:** Verify all Stripe functionality works correctly after deployment  
**Frequency:** After each deployment, before enabling features for new facilities  
**Estimated Time:** 30-45 minutes

---

## Pre-Test Setup

### 1. Verify Configuration

- [ ] `appConfig/stripe` document exists in Firestore
- [ ] All flags set to `false` (default state)
- [ ] Test facility ID added to `allowlistFacilityIds` (for new feature testing)
- [ ] `killSwitch` set to `false`

### 2. Stripe Dashboard

- [ ] Webhook endpoint active and receiving events
- [ ] Test mode enabled (for testing without real charges)
- [ ] Test cards available: `4242 4242 4242 4242` (success), `4000 0000 0000 0002` (decline)

### 3. Test Data

- [ ] Test facility created in Firestore
- [ ] Test tenant created under test facility
- [ ] Test user authenticated and has access to test facility

---

## Test 1: Existing Subscription Flow (MUST PASS)

**Purpose:** Verify existing platform billing still works with flags OFF.

### Steps:

1. Call `createSubscriptionCheckout` with test facility account ID
2. Complete checkout using test card `4242 4242 4242 4242`
3. Verify webhook `checkout.session.completed` received
4. Verify `facilityCreatorAccounts/{accountId}` updated with subscription status
5. Verify subscription status is `active`

### Expected Results:

- ✅ Checkout session created successfully
- ✅ Payment processed successfully
- ✅ Webhook received and processed
- ✅ Subscription status updated in Firestore
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If subscription flow fails, DO NOT proceed with new features
- ❌ Revert deployment if critical

---

## Test 2: Connect Onboarding (NEW FEATURE)

**Purpose:** Verify Connect account creation and onboarding works.

### Prerequisites:

- [ ] Test facility ID in `allowlistFacilityIds` OR `connectEnabledGlobal: true`

### Steps:

1. Call `createStripeConnectAccount` with test facility ID
2. Verify `facilities/{facilityId}` updated with `stripeConnectAccountId`
3. Call `createStripeConnectAccountLink` to get onboarding URL
4. Complete onboarding in Stripe Dashboard (test mode)
5. Call `getStripeConnectAccountStatus` to verify status
6. Verify `facilities/{facilityId}` updated with:
   - `stripeConnectStatus: 'active'`
   - `chargesEnabled: true`
   - `payoutsEnabled: true`
   - `stripeConnectUpdatedAt` timestamp

### Expected Results:

- ✅ Connect account created successfully
- ✅ Onboarding link generated
- ✅ Status updates correctly after onboarding
- ✅ Firestore fields persisted correctly
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If Connect onboarding fails, remove facility from allowlist
- ❌ Check function logs for errors

---

## Test 3: Tenant SetupIntent on Connected Account (NEW FEATURE)

**Purpose:** Verify tenant payment method capture on connected account works.

### Prerequisites:

- [ ] Test facility has completed Connect onboarding
- [ ] Test facility ID in `allowlistFacilityIds` OR `tenantAutopayEnabledGlobal: true`

### Steps:

1. Call `createTenantSetupIntent` with test facility ID and tenant ID
2. Verify `clientSecret` returned
3. Use Stripe Elements to capture test card `4242 4242 4242 4242`
4. Confirm SetupIntent with Stripe
5. Call `attachTenantPaymentMethod` with `paymentMethodId` from SetupIntent
6. Verify payment method stored in Firestore:
   - `facilities/{facilityId}/tenants/{tenantId}/paymentMethods/{pmId}`
   - Contains: `stripePaymentMethodId`, `stripeConnectedAccountId`, `last4`, `brand`, `expiryMonth`, `expiryYear`
7. Verify webhook `setup_intent.succeeded` received (if subscribed)

### Expected Results:

- ✅ SetupIntent created on connected account
- ✅ Card captured successfully
- ✅ Payment method attached to connected account customer
- ✅ Payment method stored in Firestore with correct fields
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If SetupIntent fails, check Connect account status
- ❌ Verify feature flag is enabled

---

## Test 4: Off-Session Charge (NEW FEATURE)

**Purpose:** Verify tenant autopay charge on connected account works.

### Prerequisites:

- [ ] Test tenant has payment method saved (from Test 3)
- [ ] Test facility ID in `allowlistFacilityIds` OR `tenantAutopayEnabledGlobal: true`

### Steps:

1. Call `chargeTenantOffSession` with:
   - Test facility ID
   - Test tenant ID
   - Payment method ID from Test 3
   - Amount: $10.00
   - Description: "Test autopay charge"
2. Verify PaymentIntent created on connected account
3. Verify `tenantCharges` collection updated:
   - `tenantCharges/{chargeId}` contains: `stripePaymentIntentId`, `amount`, `status`, `facilityId`, `tenantId`
4. Verify webhook `payment_intent.succeeded` received
5. Verify webhook updates Firestore payment record
6. Verify idempotency: Send same webhook event twice → no duplicate writes

### Expected Results:

- ✅ PaymentIntent created on connected account
- ✅ Charge recorded in `tenantCharges` collection
- ✅ Webhook received and processed
- ✅ Payment record updated in Firestore
- ✅ Idempotency works (no duplicate writes)
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If charge fails, check payment method validity
- ❌ Verify Connect account has `chargesEnabled: true`

---

## Test 5: Store Checkout (NEW FEATURE)

**Purpose:** Verify one-time store checkout on connected account works.

### Prerequisites:

- [ ] Test facility has completed Connect onboarding
- [ ] Test facility ID in `allowlistFacilityIds` OR `storeEnabledGlobal: true`

### Steps:

1. Call `createStoreCheckout` with:
   - Test facility ID
   - Line items: `[{ name: "Lock", price: 15.00, quantity: 1 }]`
   - Customer email: test email
2. Verify `clientSecret` returned
3. Use Stripe Elements to complete payment with test card `4242 4242 4242 4242`
4. Verify sale recorded in Firestore:
   - `facilities/{facilityId}/sales/{saleId}` contains: `lineItems`, `totalAmount`, `stripePaymentIntentId`
5. Verify webhook `payment_intent.succeeded` received
6. Verify sale status updated to `completed`

### Expected Results:

- ✅ Store checkout created on connected account
- ✅ Payment processed successfully
- ✅ Sale recorded in Firestore with line items
- ✅ Webhook received and processed
- ✅ Sale status updated correctly
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If store checkout fails, check Connect account status
- ❌ Verify feature flag is enabled

---

## Test 6: Webhook Idempotency (CRITICAL)

**Purpose:** Verify webhook events are not processed twice.

### Steps:

1. Trigger a test webhook event (e.g., `payment_intent.succeeded`)
2. Verify event processed and Firestore updated
3. Check `stripeWebhookEvents/{eventId}` exists with:
   - `eventType`
   - `account` (if available)
   - `facilityId` (if available)
   - `tenantId` (if available)
   - `processedAt` timestamp
4. Send SAME webhook event again (simulate retry)
5. Verify webhook returns `{ received: true, duplicate: true }`
6. Verify NO duplicate writes to Firestore

### Expected Results:

- ✅ First webhook event processed successfully
- ✅ Event marked as processed in `stripeWebhookEvents`
- ✅ Second webhook event acknowledged but not reprocessed
- ✅ No duplicate Firestore writes
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If idempotency fails, CRITICAL ISSUE - investigate immediately
- ❌ Check `isStripeEventProcessed()` function

---

## Test 7: Feature Flag Enforcement (CRITICAL)

**Purpose:** Verify feature flags work correctly.

### Steps:

1. **Test with flags OFF:**
   - Set all flags to `false` and clear `allowlistFacilityIds`
   - Try to call `createStripeConnectAccount` → Should fail with "not enabled" error
   - Try to call `createTenantSetupIntent` → Should fail with "not enabled" error
   - Try to call `createStoreCheckout` → Should fail with "not enabled" error

2. **Test with facility in allowlist:**
   - Add test facility ID to `allowlistFacilityIds`
   - Try to call `createStripeConnectAccount` → Should succeed
   - Try to call `createTenantSetupIntent` → Should succeed
   - Try to call `createStoreCheckout` → Should succeed

3. **Test with global flag ON:**
   - Set `connectEnabledGlobal: true`
   - Remove facility from allowlist
   - Try to call `createStripeConnectAccount` → Should succeed

4. **Test kill switch:**
   - Set `killSwitch: true`
   - Try to call any new feature function → Should fail with "kill switch" error
   - Set `killSwitch: false` → Should work again

### Expected Results:

- ✅ Features disabled when flags are OFF
- ✅ Features enabled when facility in allowlist
- ✅ Features enabled when global flag is ON
- ✅ Kill switch disables all features
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If feature flags don't work, CRITICAL ISSUE - fix immediately
- ❌ Check `isStripeFeatureEnabled()` function

---

## Test 8: Refund & Dispute Webhooks (NEW)

**Purpose:** Verify new webhook handlers work correctly.

### Steps:

1. **Test refund webhook:**
   - Create a test payment (from Test 4 or 5)
   - Issue refund in Stripe Dashboard (test mode)
   - Verify webhook `charge.refunded` received
   - Verify payment record updated to `status: 'refunded'`
   - Verify ledger entry created for refund

2. **Test dispute webhook:**
   - Create a test payment
   - Create dispute in Stripe Dashboard (test mode)
   - Verify webhook `charge.dispute.created` received
   - Verify payment record updated to `status: 'disputed'`
   - Verify ledger entry created for dispute

### Expected Results:

- ✅ Refund webhook processed correctly
- ✅ Dispute webhook processed correctly
- ✅ Payment records updated correctly
- ✅ Ledger entries created correctly
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If webhook handlers fail, check function logs
- ❌ Verify events are subscribed in Stripe Dashboard

---

## Test 9: Connect Login Link (NEW FEATURE)

**Purpose:** Verify Connect dashboard login link works.

### Prerequisites:

- [ ] Test facility has completed Connect onboarding
- [ ] Test facility ID in `allowlistFacilityIds` OR `connectEnabledGlobal: true`

### Steps:

1. Call `createStripeConnectLoginLink` with test facility ID
2. Verify login URL returned
3. Open URL in browser
4. Verify redirects to Stripe Dashboard (test mode)
5. Verify can access connected account dashboard

### Expected Results:

- ✅ Login link created successfully
- ✅ URL redirects to Stripe Dashboard
- ✅ Can access connected account
- ✅ No errors in function logs

### Rollback Criteria:

- ❌ If login link fails, check Connect account status
- ❌ Verify feature flag is enabled

---

## Post-Test Verification

After all tests complete:

- [ ] Review function logs for any errors
- [ ] Verify Firestore data is correct
- [ ] Verify no duplicate webhook events processed
- [ ] Verify feature flags work as expected
- [ ] Document any issues found

---

## Test Results Template

```
Test Date: ___________
Tester: ___________
Environment: [ ] Production [ ] Staging [ ] Test

Test 1: Existing Subscription Flow
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 2: Connect Onboarding
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 3: Tenant SetupIntent
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 4: Off-Session Charge
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 5: Store Checkout
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 6: Webhook Idempotency
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 7: Feature Flag Enforcement
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 8: Refund & Dispute Webhooks
  [ ] PASS [ ] FAIL
  Notes: ___________

Test 9: Connect Login Link
  [ ] PASS [ ] FAIL
  Notes: ___________

Overall Result: [ ] PASS [ ] FAIL
Issues Found: ___________
```

---

## Critical Failure Scenarios

If any of these tests fail, **DO NOT** enable features for production:

1. ❌ Test 1 (Existing Subscription Flow) - CRITICAL
2. ❌ Test 6 (Webhook Idempotency) - CRITICAL
3. ❌ Test 7 (Feature Flag Enforcement) - CRITICAL

If these pass but others fail, investigate and fix before proceeding.
