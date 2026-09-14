# Twilio sender registration (toll-free verification and A2P 10DLC)

Current state of SFC's carrier registration, what actually broke, and the
prepared answers for any future registration form. Findings dated
2026-09-13. See `docs/TEXTING_ONBOARDING_README.md` for the per-facility (ISV)
texting flow in code.

## Short version

- SFC's live sender, toll-free **+1 855 526 4544**, has an **approved
  Toll-Free Verification** (HH8589d700c3a7c4c995bedbf410351655, approved
  2026-03-24) and shows "Messaging enabled". It is not subject to 10DLC at
  all. Nothing about SFC's own sending needed re-registering.
- What actually stopped texts on 2026-09-13 was the **Twilio account being
  suspended on a negative balance** (-$5.07). A new card was added, auto-
  recharge fired, balance went to $14.93 and the suspension lifted the same
  day. While suspended, One Console showed "Messaging disabled / Submit
  registration" against every number and "Access is required" on every
  registration page, which is what made the toll-free look unverified.
- The failed 10DLC campaign CM762f51debc93cd324bd4b37fd3976ad4 (Jan 2026)
  has **no phone numbers assigned** and SFC never sent through its messaging
  service. It is irrelevant to SFC traffic and does not need resubmitting.
- 10DLC only matters for **facility-owned local numbers** (Keepsake's), which
  register under the facility's secondary profile via the in-app texting
  setup.

## What actually sends SMS

Both outbound paths post a raw `From` number to the Twilio Messages API. A
messaging-service SID is stored per facility but never used at send time
(`functions-messaging-twilio/src/twilioCallables.ts`, sender resolution around
line 381).

| Number | Type | Role | Registration state (console, 2026-09-13, after unsuspension) |
|---|---|---|---|
| +1 855 526 4544 | Toll-free | `TWILIO_PHONE_NUMBER` and `SFC_LEAD_LINE_NUMBER` in every `functions-*/.env`. Global fallback sender for every facility whose own number is not A2P-approved, i.e. all traffic today. Webhook: `handleIncomingSMS`. | **Messaging enabled.** Toll-free verification approved 2026-03-24. Not in any messaging service (not needed). |
| +1 903 500 9941 | Local (Longview TX) | Keepsake Self Storage (`facilities/eXnWPuwuqzBVFcZWv1ZL`), `twilioMessagingServiceSid` MG2e4413797b3da7e5bd014abf9c027d99, `a2pStatus: draft`, `textingPlatformApproved: false`. Never used as `From` because not approved. | Messaging disabled, "Complete A2P registration". |
| +1 903 300 2119 | Local (Cooper TX) | Not referenced by any facility document or env file. Has the SFC `handleIncomingSMS` webhook. Not in any messaging service. | Messaging disabled, "Complete A2P registration". Costs ~$1.15/month. Candidate for release. |
| +1 580 407 4317 | Local (Idabel OK) | Hochatown Saloon. Separate service MG9ddcb24e0946df41ba42ea88f57f29ab. **Do not touch from this repo.** | Campaign CMf0d82519b5f45690c695db70775e4efb submitted and **rejected** 2026-09-13 (see below). |

Traffic volume: zero `sendSMS` executions in Cloud Functions logs since
2026-06-01. Monthly Twilio bills Feb-Aug 2026 were $3.51-$4.53, i.e. number
rental only.

## Campaign rejection reasons (read 2026-09-13)

Both campaigns sit under brand BN689de2fc941ce72a2ab470a2c2091335 (STORAGE
FACILITY CREATOR LLC, Standard, approved). One Console offers "Edit &
resubmit" on a rejected campaign, so a rejected campaign is editable after
all. Resubmission is likely to be charged the vetting fee again; check before
pressing it.

| Campaign | Owner | Rejection |
|---|---|---|
| CM762f51debc93cd324bd4b37fd3976ad4 (created 2026-01-10, service MGadd2cfcf38986cd041a759d449b6349f, no numbers) | SFC | **30909**: "rejected due to issues verifying the Call to Action (CTA) provided for the campaign." The reviewer could not verify where and how the tenant opts in. The fix is a consent description that names the exact form, quotes the checkbox text, and links a live page showing it (https://www.storagefacilitycreator.com/sms-consent-demo now exists for this). Not worth resubmitting: SFC does not send from a local number. |
| CMf0d82519b5f45690c695db70775e4efb (created 2026-09-13, service MG9ddcb24e0946df41ba42ea88f57f29ab) | Hochatown Saloon | **30907**: "the provided website URL does not match the Brand and Campaign registered." **30886**: "invalid campaign description." The brand is Storage Facility Creator LLC; the campaign's website and description are the saloon's, a different business. Carriers match campaign website against brand. The saloon needs its own brand (its own legal entity and EIN) or, if it is legally the same LLC, a campaign whose website URL and description say Storage Facility Creator LLC / storagefacilitycreator.com. This is brand-level: any non-SFC business filed under this brand will bounce the same way. |

## Other findings, 2026-09-13

1. **Console URLs have changed.** `console.twilio.com/...` now redirects
   through `1console.twilio.com/travel?deeplink=...` to One Console. The
   classic campaign dialog is no longer reachable for this account. One
   Console pages are ordinary same-origin pages and can be driven by browser
   automation once the account is not suspended.
2. **Privacy policy is compliant.** Live
   https://www.storagefacilitycreator.com/privacy contains: "Mobile opt-in
   information and SMS consent data are never sold, rented, or shared with
   third parties or affiliates for marketing or promotional purposes. Phone
   numbers are shared only with our messaging subprocessor (Twilio) solely to
   deliver the messages a Tenant has opted in to receive." `/terms`,
   `/sms-terms` and `/sms-consent-demo` all return 200.
3. **Outbound bodies now match the filed samples (fixed 2026-09-13).**
   `sendSMS` used to append the STOP/HELP footer only when the facility had
   the `enhancedOptOut` flag, and texts from the shared number carried no
   sender name. `addOptOutFooter` (`smsComplianceHelpers.ts`) now runs on
   every send (facility can still override the wording via
   `smsSettings.optOutFooter`), and when the shared toll-free number is the
   sender the body is prefixed with the facility name, e.g. "Keepsake Self
   Storage: Hi Jane, ...". A facility's own registered number gets no prefix
   because the number already identifies it.
4. **Auto-recharge.** Threshold $10, top-up to $20, single card ending 9200
   (added 2026-09-13). The old card ending 3935, which had stopped charging
   and caused the suspension, was deleted the same day. There is no backup
   payment method; if the 9200 card ever fails the account suspends again.

## Account health monitor (added 2026-09-13)

`checkTwilioAccountHealthScheduled` in
`functions-messaging-twilio/src/twilioAccountHealth.ts` runs every six hours.
It fetches the account status and balance from Twilio, writes them to
`platform/twilioAccountHealth`, and emails the super admins (the list in
`functions-shared/src/auth/superAdmin.ts`) when the status is not `active`,
the API cannot be reached (bad or rotated auth token), or the balance is
below `TWILIO_LOW_BALANCE_ALERT_USD` (default 10). Unchanged alerts repeat
once a day; a recovery email goes out when the account is healthy again.
Twilio's own low-balance email is also on (threshold $5, account owners);
this exists because that one was missed.

To run it by hand after a deploy:

```
gcloud scheduler jobs run firebase-schedule-checkTwilioAccountHealthScheduled-us-central1 --location us-central1 --project storage-facility-creator
```

## What is left to do

1. Send one real text from a facility to a known phone to prove the path end
   to end now that the account is live (cost about one cent). Watch Monitor >
   Logs > Messaging for the delivery status.
2. Keepsake: finish the in-app texting setup (bundle, brand, campaign under
   the facility's secondary profile). Consent text for that form is below.
   Details still needed from Russell: legal name as on the EIN letter, full
   EIN, postal code, authorized representative.
3. Saloon: register its own brand or align website/description with the SFC
   brand, then resubmit CMf0d8... (their project, not this repo).
4. Decide whether to release +1 903 300 2119 and whether to delete the unused
   CM762f... campaign and its empty service MGadd2....

## Prepared answers for a 10DLC campaign (facility local numbers)

- **Use case:** Low Volume Mixed ($1.50/mo) if under ~2,000/day and the
  facility also does two-way customer care; otherwise Account Notification
  ($10/mo). One-off vetting fee ~$15.
- **Campaign description:** "Storage Facility Creator is a management platform
  for self-storage facilities. This campaign sends account notifications from a
  storage facility to its own tenants: rent due reminders, past-due notices,
  contract expiry notices, and replies in conversations the tenant started.
  Recipients are tenants who ticked an SMS consent box when renting a unit.
  No marketing or promotional messages are sent."
- **Sample messages** (bodies as generated by the app: facility-name prefix
  and STOP/HELP footer are added by `sendSMS`):
  1. "Keepsake Self Storage: Hi Jane, friendly reminder: your storage rent is
     due soon. Reply with any questions. Reply STOP to opt out. Reply HELP for
     help."
  2. "Keepsake Self Storage: Jane, we show a past-due balance for unit B12.
     Please contact us to arrange payment. Thank you. Reply STOP to opt out.
     Reply HELP for help."
  3. "Keepsake Self Storage: Hello Jane, your storage contract "Unit B12 lease"
     is scheduled to expire on Oct 31, 2026. Please contact us to renew or
     discuss next steps. Reply STOP to opt out. Reply HELP for help."
- **How end users consent (message flow), the field that failed 30909 last
  time:** "When a tenant rents a unit, either on the facility's public
  move-in page or in the office, they enter their mobile number and must tick
  a separate, un-prechecked checkbox that reads: 'I consent to receive SMS
  notifications regarding my storage account. Message frequency varies.
  Message & data rates may apply. Reply STOP to opt out, HELP for help.
  Consent is not a condition of renting a unit.' The consent, timestamp and
  source are stored on the tenant record. Tenants who have not ticked the box
  are never texted. A live copy of the form is at
  https://www.storagefacilitycreator.com/sms-consent-demo and the terms at
  https://www.storagefacilitycreator.com/sms-terms."
- **Opt-in keywords:** blank (consent is collected on the form, not by SMS).
- **Opt-in message (required, 20-320 chars even though the form says
  optional):** "Storage Facility Creator: you're set up for account
  notification texts from your storage facility. Reply STOP to stop, HELP for
  help. Msg&data rates may apply."
- **Opt-out keywords / message:** STOP, STOPALL, UNSUBSCRIBE, CANCEL, END,
  QUIT / "You have been unsubscribed from SMS messages. Reply START to opt
  back in."
- **Help keywords / message:** HELP, INFO / "Reply STOP to opt out of SMS
  messages. Reply START to opt back in. For support, contact your facility
  directly."
- **Message contents:** embedded links: no; phone numbers: no; lending: no;
  age-gated: no; direct lending: no.
- **Privacy policy URL:** https://www.storagefacilitycreator.com/privacy
- **Terms URL:** https://www.storagefacilitycreator.com/terms
- **Website URL on the campaign must match the brand:**
  https://www.storagefacilitycreator.com (error 30907 otherwise).
