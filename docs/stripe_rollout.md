# Stripe Connect Rollout Plan

**Status:** Ready for deployment  
**Last Updated:** 2024-12-XX  
**Default State:** All features OFF (preserves production behavior)

---

## Overview

This rollout plan ensures safe, gradual deployment of the enhanced Stripe Connect architecture. All new features are behind feature flags with default values that preserve existing production behavior.

---

## Pre-Deployment Checklist

### 1. Verify Existing Production Flows

- [ ] Test facility subscription checkout (`createSubscriptionCheckout`)
- [ ] Test subscription webhook processing (`stripeWebhook`)
- [ ] Test existing tenant payment processing (if any)
- [ ] Verify webhook idempotency works (send duplicate event → no duplicate writes)
- [ ] Confirm no breaking changes to existing function signatures

### 2. Stripe Dashboard Configuration

- [ ] Verify only ONE webhook endpoint exists in Stripe Dashboard
- [ ] Verify webhook endpoint URL: `https://[region]-[project].cloudfunctions.net/stripeWebhook`
- [ ] Verify webhook secret matches Firebase Secret: `STRIPE_WEBHOOK_SECRET`
- [ ] Verify all required events are subscribed:
  - `checkout.session.completed`
  - `customer.subscription.*`
  - `invoice.payment_*`
  - `account.updated`
  - `payment_intent.*`
  - `setup_intent.succeeded`
  - `charge.refunded` (NEW)
  - `charge.dispute.created` (NEW)
- [ ] Verify products exist: `sfc_base_monthly_75`, `sfc_addon_monthly_75`
- [ ] Verify Connect is enabled in Stripe Dashboard
- [ ] Test Connect account creation manually (if possible)

### 3. Firestore Configuration

- [ ] Create `appConfig/stripe` document with default values:
  ```json
  {
    "connectEnabledGlobal": false,
    "tenantAutopayEnabledGlobal": false,
    "storeEnabledGlobal": false,
    "checkoutEnabledGlobal": false,
    "allowlistFacilityIds": [],
    "killSwitch": false
  }
  ```
- [ ] Verify Firestore security rules allow read access to `appConfig/stripe` for authenticated users
- [ ] Verify Firestore security rules allow write access to `appConfig/stripe` for super admins only

### 4. Code Deployment

- [ ] Deploy Cloud Functions: `firebase deploy --only functions`
- [ ] Verify all functions deploy successfully
- [ ] Check function logs for errors
- [ ] Verify no breaking changes to existing function signatures

---

## Rollout Phases

### Phase 1: Deploy with Flags OFF (Day 1)

**Goal:** Deploy code without enabling any new features. Verify existing flows still work.

**Actions:**
1. Deploy Cloud Functions
2. Verify `appConfig/stripe` document exists with all flags OFF
3. Test existing subscription flow
4. Test existing payment processing (if any)
5. Monitor function logs for errors

**Success Criteria:**
- ✅ All existing flows work as before
- ✅ No errors in function logs
- ✅ Webhook processing continues normally
- ✅ No new features are accessible

**Rollback Plan:**
- If issues occur, revert Cloud Functions deployment
- No data changes required (flags are OFF)

---

### Phase 2: Enable for Internal Test Facility (Day 2-3)

**Goal:** Test new features with one internal facility (KeepSake or similar).

**Actions:**
1. Add test facility ID to `allowlistFacilityIds` in `appConfig/stripe`
2. Test Connect onboarding:
   - Create Connect account
   - Complete onboarding flow
   - Verify status updates in Firestore
3. Test tenant SetupIntent on connected account:
   - Create SetupIntent
   - Capture card via Stripe Elements
   - Attach payment method
   - Verify stored in Firestore
4. Test off-session charge:
   - Charge tenant using stored payment method
   - Verify PaymentIntent created on connected account
   - Verify webhook updates Firestore
5. Test one-time store checkout:
   - Create store checkout
   - Complete payment
   - Verify sale recorded in Firestore
6. Test webhook idempotency:
   - Send same test event twice
   - Verify no duplicate writes

**Success Criteria:**
- ✅ Connect onboarding completes successfully
- ✅ Tenant payment methods saved on connected account
- ✅ Off-session charges work
- ✅ Store checkout works
- ✅ Webhook idempotency confirmed
- ✅ All payments route to connected account (0% platform fee)

**Rollback Plan:**
- Remove facility ID from `allowlistFacilityIds`
- Features immediately disabled for that facility
- No data cleanup required

---

### Phase 3: Expand Allowlist Gradually (Day 4-7)

**Goal:** Add more facilities to allowlist one at a time, testing each.

**Actions:**
1. Add one facility ID to `allowlistFacilityIds`
2. Notify facility owner about new features
3. Monitor for issues for 24-48 hours
4. If successful, add next facility
5. Repeat until all interested facilities are added

**Success Criteria:**
- ✅ Each facility can use new features without issues
- ✅ No increase in error rates
- ✅ Payments process correctly
- ✅ Webhooks process correctly

**Rollback Plan:**
- Remove facility ID from allowlist
- Features disabled immediately
- Existing payments/charges remain valid

---

### Phase 4: Enable Global Flags (Week 2+)

**Goal:** Enable features globally after successful allowlist testing.

**Actions:**
1. Set `connectEnabledGlobal: true`
2. Set `tenantAutopayEnabledGlobal: true`
3. Set `storeEnabledGlobal: true`
4. Set `checkoutEnabledGlobal: true` (if needed)
5. Monitor for 24-48 hours
6. If issues occur, set flags back to `false`

**Success Criteria:**
- ✅ All facilities can use new features
- ✅ No increase in error rates
- ✅ Payments process correctly
- ✅ Webhooks process correctly

**Rollback Plan:**
- Set global flags back to `false`
- Features disabled immediately
- Existing payments/charges remain valid

---

## Emergency Kill Switch

**If critical issues occur:**

1. Set `killSwitch: true` in `appConfig/stripe`
2. All payment actions immediately disabled (regardless of other flags)
3. Investigate and fix issues
4. Set `killSwitch: false` to re-enable

**Kill switch disables:**
- Connect account creation
- Tenant SetupIntent creation
- Off-session charges
- Store checkout
- All new payment processing

**Kill switch does NOT affect:**
- Existing subscription billing (platform billing)
- Webhook processing (read-only)
- Existing payment records

---

## Monitoring & Alerts

### Key Metrics to Monitor

1. **Function Error Rates**
   - Monitor Cloud Functions logs for errors
   - Alert if error rate > 1%

2. **Webhook Processing**
   - Monitor webhook delivery success rate
   - Alert if webhook failures > 5%

3. **Payment Success Rates**
   - Monitor PaymentIntent success rates
   - Alert if success rate drops > 10%

4. **Connect Account Status**
   - Monitor Connect account onboarding completion rate
   - Alert if completion rate drops

### Logs to Review

- Cloud Functions logs: `firebase functions:log`
- Stripe Dashboard: Webhook delivery logs
- Firestore: `stripeWebhookEvents` collection (idempotency tracking)

---

## Testing Without Charging Real Cards

### Stripe Test Mode

1. Use Stripe test mode API keys:
   - Set `STRIPE_SECRET_KEY` to test key (`sk_test_...`)
   - Set `STRIPE_WEBHOOK_SECRET` to test webhook secret
   - Use test publishable key in Flutter app

2. Use Stripe test cards:
   - Success: `4242 4242 4242 4242`
   - Decline: `4000 0000 0000 0002`
   - 3DS required: `4000 0025 0000 3155`

3. Test webhooks using Stripe CLI:
   ```bash
   stripe listen --forward-to localhost:5001/stripeWebhook
   stripe trigger payment_intent.succeeded
   ```

### Local Testing

1. Use Firebase Emulator Suite:
   ```bash
   firebase emulators:start
   ```

2. Test functions locally:
   ```bash
   firebase functions:shell
   ```

3. Test webhooks locally using Stripe CLI

---

## Post-Deployment Verification

After each phase, verify:

- [ ] Existing subscription billing still works
- [ ] Webhook processing continues normally
- [ ] No errors in function logs
- [ ] Firestore updates correctly
- [ ] Idempotency works (no duplicate writes)
- [ ] Feature flags work as expected
- [ ] Kill switch works (if tested)

---

## Support & Troubleshooting

### Common Issues

1. **Feature not enabled even though flag is true**
   - Check `killSwitch` is `false`
   - Verify facility ID is in `allowlistFacilityIds` OR global flag is `true`
   - Check function logs for errors

2. **Webhook not processing**
   - Verify webhook secret matches
   - Check webhook endpoint URL is correct
   - Verify event is subscribed in Stripe Dashboard
   - Check function logs for errors

3. **Payment not routing to connected account**
   - Verify Connect account is created and onboarded
   - Check `stripeConnectAccountId` exists on facility doc
   - Verify `chargesEnabled` and `payoutsEnabled` are `true`
   - Check function logs for errors

### Contact

- Technical issues: Check function logs and Stripe Dashboard
- Business questions: Contact product team
- Emergency: Use kill switch immediately

---

## Success Metrics

**Week 1:**
- ✅ All features deployed with flags OFF
- ✅ Existing flows verified working
- ✅ Test facility successfully using new features

**Week 2:**
- ✅ 5-10 facilities added to allowlist
- ✅ No critical issues
- ✅ Payment success rate maintained

**Week 3+:**
- ✅ Global flags enabled (if desired)
- ✅ All facilities can use new features
- ✅ 0% platform fee confirmed for Connect payments
