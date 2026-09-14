# Facility offboarding (Stripe Connect + tenant data)

When a facility leaves the platform, the platform must stop being able to act on
that facility's Stripe account and must stop holding its tenants' personal data.
Before this existed, every Standard Connect account ever created stayed attached
to the platform forever, and tenant records of departed facilities stayed in
Firestore indefinitely.

## Three paths, one outcome

| Trigger | Where | What happens |
| --- | --- | --- |
| Facility document deleted (the Flutter client deletes directly) | `functions-integrations` `onFacilityDeletedDisconnectStripe` (Firestore `onDelete` on `facilities/{id}`) | Immediately calls Stripe `oauth.deauthorize` for the facility's connected account and turns off tenant autopay flags. |
| Owner disconnects the platform from their own Stripe dashboard | `functions-integrations` `stripeWebhook`, event `account.application.deauthorized` (arrives on the Connect destination) | Marks the facility `DISCONNECTED`, clears `stripeConnectAccountId`, turns off tenant autopay. No Stripe call needed. |
| Platform subscription cancelled | `functions-automation` `processFacilityOffboarding` (daily 06:00 UTC) | Waits `OFFBOARDING_GRACE_DAYS` (30) from `platformSubscriptionCancelledAt`, then deauthorizes, marks the facility offboarded, blanks tenant PII, deletes saved payment-method records, turns off autopay. |

The daily job also sweeps the platform's connected accounts: any account whose
`metadata.facilityId` no longer matches a facility document is detached. This is
the safety net for deletions that happened before the `onDelete` trigger existed
and for any trigger failure.

## What "offboarded" means on the data

Facility document:

- `stripeConnectAccountId: null`, `stripeConnectPreviousAccountId: <acct>`
- `stripeConnectDisconnectedAt`, `stripeConnectDisconnectReason`
  (`facility_deleted` | `subscription_cancelled` | `owner_deauthorized` | `orphaned_account` | `manual`)
- `stripeStatus.state: 'DISCONNECTED'` (the Flutter model already understands this state)
- `offboardedAt`, `offboardingReason` (subscription path only)

Tenant documents (`tenants` and `oldTenants`):

- `name` becomes `Redacted tenant`; `email`, `phone`, government-ID fields,
  notes, portal codes, insurance and contract URLs become `null`; contact,
  vehicle, occupant and address lists become empty; `portalEnabled: false`.
- `piiRedactedAt`, `piiRedactedReason` are set so the job never redacts twice.
- Unit number, rate, dates, `isActive` and every ledger entry are untouched, so
  accounting history still adds up.
- `paymentMethods` sub-documents are deleted; `billing/*` gets `autopayEnabled: false`.

## Grace period and re-subscription

A cancelled facility is not touched for 30 days. If it re-subscribes in that
window, `platformSubscriptionStatus` stops being `cancelled` and it drops out of
the candidate set. Facilities cancelled before this job existed have no
`platformSubscriptionCancelledAt`; the first sweep stamps one, so their 30 days
start from the first run, not from the original cancellation.

## Secrets

Deauthorize needs the platform's Connect client id, `STRIPE_CONNECT_CLIENT_ID`,
which `functions-integrations` already binds and `functions-automation` now
binds too. If it is missing, the job logs an error and leaves the facility
untouched rather than redacting data the platform can still charge against.

## Standard accounts are not closed

Deauthorize revokes the platform's access. The facility's Stripe account keeps
existing and keeps working for the facility owner, with their customers' saved
cards still inside it. That is their business relationship, not the platform's.
Closing the account itself is something only the account owner can do from
their Stripe dashboard.

## Pure helpers and tests

All decisions live in `functions-shared/src/stripe/connectOffboarding.ts` and are
covered by `functions-shared/src/test/connectOffboarding.test.ts`. The two
packages only wire Firestore and Stripe around them.

## Emails (nobody has to remember to write these)

The daily job sends three kinds of mail, all built by pure functions in
`functions-shared/src/stripe/offboardingEmails.ts`:

| Who | When | Says |
| --- | --- | --- |
| Facility owner | First sweep after the platform subscription ends (once, `offboardingNoticeSentAt`) | Subscription ended, nothing removed yet, the exact date tenant data is removed and Stripe is detached, what stays theirs, export before then, reactivate to keep everything. |
| Facility owner | The sweep that offboards them (once, `offboardedNoticeSentAt`) | Removal is done, Stripe access ended, their Stripe account still works, welcome back any time, removed details cannot be restored. |
| Super admins | Only on nights with activity | What was offboarded, which notices went out, which orphaned accounts were detached, any errors. Quiet nights send nothing. |

Owner addresses come from Firebase Auth via the facility's `ownerUid`, with
facility-level contact fields as fallback. These are transactional platform
mails sent through SendGrid without an unsubscribe group; the sender address
doubles as the support contact in the copy.

## Pre-launch switch: owner emails are off by default

No email or text may reach a customer until the build is finished. The owner
notices above only send when `appConfig/offboarding` has
`ownerEmailsEnabled: true`. While it is off, the removal step is paused as
well, because a facility must never lose tenant data without being told
first. The nightly job still starts grace clocks, still detaches orphaned
Stripe accounts, and still emails the super admins, listing any facility that
is past its grace period and waiting on the switch. Flip the flag at launch;
no redeploy needed.
