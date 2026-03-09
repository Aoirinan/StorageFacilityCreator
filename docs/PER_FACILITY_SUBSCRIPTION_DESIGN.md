# Per-Facility Platform Subscription Design

## Problem
Users need **different payment methods (cards) per facility**. Currently one card pays for all facilities.

## Solution
**One Stripe subscription per facility** – each facility gets its own $75/mo subscription and its own card.

## Data Model

### Facility document (facilities/{facilityId})
New fields for platform (SFC) subscription:
- `stripePlatformSubscriptionId` – Stripe subscription ID (sub_xxx)
- `platformSubscriptionStatus` – active | trialing | past_due | cancelled | unpaid
- `platformSubscriptionCurrentPeriodEnd` – Timestamp
- `platformSubscriptionCancelAtPeriodEnd` – boolean

### Account document (facilityCreatorAccounts) – legacy support
Keep existing fields for backwards compatibility. New per-facility flow does NOT use account-level subscription.

## Stripe Model
- **One Stripe Customer per account** (shared)
- **One Subscription per facility** – each created via its own checkout, so each can have different payment method
- Subscription metadata: `accountId`, `facilityId` (tenant subscriptions use `tenantId` too – we exclude those)

## Flow
1. User creates/owns facility
2. Facility needs subscription → "Subscribe" button opens checkout for THAT facility
3. User enters card in Stripe Checkout
4. Checkout completes → subscription created with metadata.accountId, metadata.facilityId
5. Webhook → update facility doc with subscription info
6. Facility is "unlocked" for use

## Access Control
- **Legacy**: Account has stripeSubscriptionId + facility in facilityIds → facility has access
- **Per-facility**: Facility has stripePlatformSubscriptionId + platformSubscriptionStatus active/trialing → facility has access
- User can access app if they have at least one facility with access
