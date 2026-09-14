# Twilio sender registration (toll-free verification and A2P 10DLC)

Current state of SFC's carrier registration, why texts are not delivering, and
the prepared answers for the registration forms. Findings dated 2026-09-13.
See `docs/TEXTING_ONBOARDING_README.md` for the per-facility (ISV) texting flow
in code.

## What actually sends SMS

Both outbound paths post a raw `From` number to the Twilio Messages API. A
messaging-service SID is stored per facility but never used at send time
(`functions-messaging-twilio/src/twilioCallables.ts`, sender resolution around
line 381).

| Number | Type | Role | Registration state (console, 2026-09-13) |
|---|---|---|---|
| +1 855 526 4544 | Toll-free | `TWILIO_PHONE_NUMBER` and `SFC_LEAD_LINE_NUMBER` in every `functions-*/.env`. The global fallback sender for every facility whose own number is not A2P-approved, i.e. all traffic today. Webhook: `handleIncomingSMS`. | **Messaging disabled, "Submit registration"** (toll-free verification never submitted). Not in any messaging service. |
| +1 903 500 9941 | Local (Longview TX) | Keepsake Self Storage (`facilities/eXnWPuwuqzBVFcZWv1ZL`), `twilioMessagingServiceSid` MG2e4413797b3da7e5bd014abf9c027d99, `a2pStatus: draft`, `textingPlatformApproved: false`. Never used as `From` because not approved. | Messaging disabled, "Complete A2P registration". |
| +1 903 300 2119 | Local (Cooper TX) | Not referenced by any facility document or env file. Has the SFC `handleIncomingSMS` webhook, so it was configured for SFC at some point. Probably the number in the failed campaign's service (see below). | Messaging disabled, "Complete A2P registration". Costs ~$1.15/month. |
| +1 580 407 4317 | Local (Idabel OK) | Hochatown Saloon. Separate service MG9ddcb24e0946df41ba42ea88f57f29ab. **Do not touch.** | Campaign submitted 2026-09-13. |

Traffic volume: zero `sendSMS` executions in Cloud Functions logs since
2026-06-01. Monthly Twilio bills Feb-Aug 2026 were $3.51-$4.53, i.e. number
rental only. Nothing is being filtered because nothing is being sent; the
registration gap only bites once a facility starts sending.

## Findings, 2026-09-13

1. **The account is suspended.** Billing overview shows balance **-$5.07**,
   pay-as-you-go, auto-recharge "enabled" but evidently not recharging (card
   declined or removed). September month-to-date spend $19.45 is the saloon's
   registration fees. While suspended, One Console returns "Access is
   required" on: A2P campaigns, messaging services, messaging logs, toll-free
   verification, and the number "Compliance registration" tab. Only billing
   pages and the number inventory load. **Nothing below can be filed until
   funds are added.**
2. **The failed campaign's rejection reason could not be read** for the reason
   above. Where to read it once unsuspended: One Console > Communications >
   Trust Hub > Registrations > A2P 10DLC Campaigns > CM762f51debc93cd324bd4b37fd3976ad4,
   or the API: `GET /v1/Services/MGadd2cfcf38986cd041a759d449b6349f/Compliance/Usa2p`
   and read `failure_reason` / `errors` on the record. Record it in this file.
   If the reason is brand-level (EIN/name mismatch, website, privacy policy),
   the saloon's 2026-09-13 campaign under the same brand
   (BN689de2fc941ce72a2ab470a2c2091335) will fail for the same reason.
3. **The 10DLC campaign was for the wrong number type.** SFC's only live sender
   is toll-free. 10DLC brands and campaigns do not cover toll-free numbers at
   all; toll-free needs **Toll-Free Verification** (free, no vetting fee,
   separate form, typically 1-3 business days). Since Nov 2023 US carriers
   block every unverified toll-free message (Twilio error 30032). Registering
   a new 10DLC campaign, as originally planned, would not have fixed a single
   SFC text. The 10DLC path only matters for local numbers such as Keepsake's.
4. **Console URLs have changed.** `console.twilio.com/...` now redirects
   through `1console.twilio.com/travel?deeplink=...` to One Console. The
   classic campaign dialog is no longer reachable for this account.
5. **Privacy policy is already compliant.** Live
   https://www.storagefacilitycreator.com/privacy contains: "Mobile opt-in
   information and SMS consent data are never sold, rented, or shared with
   third parties or affiliates for marketing or promotional purposes. Phone
   numbers are shared only with our messaging subprocessor (Twilio) solely to
   deliver the messages a Tenant has opted in to receive." `/terms`,
   `/sms-terms` and `/sms-consent-demo` all return 200. No change needed.
6. **Sample-message caveat, fixed 2026-09-13.** Outbound bodies used to carry
   no brand prefix, and the STOP/HELP footer (`smsComplianceHelpers.ts`,
   `addOptOutFooter`) was only appended when the facility had the
   `enhancedOptOut` compliance flag. `sendSMS` now appends the footer on every
   send (facility can still override the wording via
   `smsSettings.optOutFooter`), and when the shared toll-free number is the
   sender it prefixes the facility name, e.g. "Keepsake Self Storage: Hi Jane,
   ...". Real traffic therefore matches the samples below. A facility's own
   registered number gets no prefix because the number already identifies it.

## Order of operations

1. Russell: add funds / fix the payment method so the suspension lifts
   (Billing > Overview > "Add more funds"). Check auto-recharge afterwards.
2. Submit **Toll-Free Verification** for +1 855 526 4544 with the answers
   below. One Console > Communications > Trust Hub > Registrations >
   Toll-free. Free.
3. Read and record the CM762f... rejection reason (finding 2). Tell the saloon
   project if it is brand-level.
4. Keepsake (and any future facility with a local number): use the in-app
   texting setup, which files a secondary customer profile, brand and campaign
   under SFC's primary profile BU74b615863e8ea253d1c5756f5df974f8 (ISV model).
   If filing manually instead, use the 10DLC answers below. Vetting fee ~$15
   once per brand, campaign $1.50/month (Low Volume Mixed) or $10/month
   (Account Notification).
5. Decide whether to release +1 903 300 2119 (unused, $1.15/month). Russell's
   call, it may be referenced somewhere outside the repo.

## Toll-free verification answers (+1 855 526 4544)

- **Business name:** Storage Facility Creator LLC (as on the approved primary
  customer profile).
- **Website:** https://www.storagefacilitycreator.com
- **Business type / industry:** Software / SaaS for self-storage operators.
- **Use case category:** Account Notifications (2FA is not used; no marketing).
- **Use case summary:** Storage Facility Creator is a management platform for
  self-storage facilities. Facility operators use it to send their own tenants
  account notifications: rent-due and past-due reminders, contract expiry
  notices, and replies in two-way conversations the tenant started. No
  marketing or promotional content. Tenants opt in by ticking an un-prechecked
  consent box when they rent a unit (online move-in form or in-office intake),
  and can reply STOP at any time.
- **Estimated monthly volume:** under 1,000.
- **Opt-in type:** Web form (plus in-person intake recorded by staff).
- **Opt-in workflow description:** When a tenant rents a unit, either on the
  facility's public move-in page or in the office, they enter their mobile
  number and must tick a separate, un-prechecked checkbox that reads: "I
  consent to receive SMS notifications regarding my storage account. Message
  frequency varies. Message & data rates may apply. Reply STOP to opt out,
  HELP for help. Consent is not a condition of renting a unit." The consent,
  timestamp and source are stored on the tenant record. Tenants who have not
  ticked the box are never texted. A live copy of the form is at
  https://www.storagefacilitycreator.com/sms-consent-demo and the terms at
  https://www.storagefacilitycreator.com/sms-terms.
- **Opt-in image URL:** https://www.storagefacilitycreator.com/sms-consent-demo
- **Sample messages** (bodies as generated by the app: facility-name prefix
  and STOP/HELP footer are added by `sendSMS` on the shared number):
  1. "Keepsake Self Storage: Hi Jane, friendly reminder: your storage rent is
     due soon. Reply with any questions. Reply STOP to opt out. Reply HELP for
     help."
  2. "Keepsake Self Storage: Jane, we show a past-due balance for unit B12.
     Please contact us to arrange payment. Thank you. Reply STOP to opt out.
     Reply HELP for help."
  3. "Keepsake Self Storage: Hello Jane, your storage contract "Unit B12 lease"
     is scheduled to expire on Oct 31, 2026. Please contact us to renew or
     discuss next steps. Reply STOP to opt out. Reply HELP for help."
- **Privacy policy URL:** https://www.storagefacilitycreator.com/privacy
- **Terms URL:** https://www.storagefacilitycreator.com/terms
- **Additional information:** Messages are sent by the facility to its own
  tenants through the platform. STOP, START and HELP are handled automatically
  by the inbound webhook; STOP replies get "You have been unsubscribed from SMS
  messages. Reply START to opt back in."

## A2P 10DLC campaign answers (local numbers, e.g. Keepsake)

Use the existing approved brand BN689de2fc941ce72a2ab470a2c2091335 only if the
number is SFC's own. Facility numbers go under the facility's secondary profile
via the app (`registerA2PCampaign` uses `ACCOUNT_NOTIFICATION`).

- **Use case:** Low Volume Mixed ($1.50/mo) if under ~2,000/day and the
  facility also does two-way customer care; otherwise Account Notification
  ($10/mo).
- **Campaign description:** "Storage Facility Creator is a management platform
  for self-storage facilities. This campaign sends account notifications from a
  storage facility to its own tenants: rent due reminders, past-due notices,
  contract expiry notices, and replies in conversations the tenant started.
  Recipients are tenants who ticked an SMS consent box when renting a unit.
  No marketing or promotional messages are sent."
- **Sample messages:** the three above (same facility-name prefix), e.g.
  "Keepsake Self Storage: Hi Jane, friendly reminder: your storage rent is due
  soon. Reply with any questions. Reply STOP to opt out. Reply HELP for help."
- **How end users consent (message flow):** the opt-in workflow paragraph
  above, verbatim, including the checkbox text and the two URLs.
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
- **Message contents:** embedded links: no (a link to storagefacilitycreator.com
  is acceptable if a facility template adds one); phone numbers: no; lending:
  no; age-gated: no; direct lending: no.
- **Privacy / Terms URLs:** as above.

## Rejection reason for CM762f51debc93cd324bd4b37fd3976ad4

Not yet recorded. Fill in from finding 2 after the account is unsuspended.
