# Twilio sender registration (toll-free verification and A2P 10DLC)

Current state of SFC's carrier registration, what actually broke, and the
prepared answers for any future registration form. Findings dated
2026-09-13, with the saloon-vs-SFC comparison added 2026-09-21. See `docs/TEXTING_ONBOARDING_README.md` for the per-facility (ISV)
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
| +1 855 526 4544 | Toll-free | `TWILIO_PHONE_NUMBER` and `SFC_LEAD_LINE_NUMBER` in every `functions-*/.env`. Global fallback sender for every facility whose own number is not A2P-approved, i.e. all traffic today. Webhook: `handleIncomingSMS`. | **Messaging enabled.** Toll-free verification approved 2026-03-24. Verified 2026-09-21: it *is* in messaging service `Storage Facility Creator` MGdd467da0e9859b606b2b768f5d5b2b84. The service is unused at send time (sends post a raw `From`), but **do not delete it**. |
| +1 903 500 9941 | Local (Longview TX) | Keepsake Self Storage (`facilities/eXnWPuwuqzBVFcZWv1ZL`), `twilioMessagingServiceSid` MG2e4413797b3da7e5bd014abf9c027d99, `a2pStatus: draft`, `textingPlatformApproved: false`. Never used as `From` because not approved. | Messaging disabled, "Complete A2P registration". |
| ~~+1 903 300 2119~~ | Local (Cooper TX) | **RELEASED 2026-09-21.** Was unused: no facility document, env file or code referenced it. Twilio allows repurchase within 10 days of release, i.e. until 2026-10-01; after that the number is gone for good. | Gone from inventory. Its messaging service MGadd2cfcf38986cd041a759d449b6349f was deleted the same day. |
| +1 580 407 4317 | Local (Idabel OK) | Hochatown Saloon. Separate service MG9ddcb24e0946df41ba42ea88f57f29ab. **Do not touch from this repo.** | Campaign CMf0d82519b5f45690c695db70775e4efb rejected 2026-09-13; replaced by CMa93db02b94977b90572ccf880f2abeae under the saloon's **own** brand BNabb4e1bbc9cde29508c021c16fe82137, **Approved 2026-09-20** (see "Why the saloon passed" below). |

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
| CM762f51debc93cd324bd4b37fd3976ad4 — **DELETED 2026-09-21** (created 2026-01-10, service MGadd2cfcf38986cd041a759d449b6349f, no numbers) | SFC | **30909**: "rejected due to issues verifying the Call to Action (CTA) provided for the campaign." The reviewer could not verify where and how the tenant opts in. The fix is a consent description that names the exact form, quotes the checkbox text, and links a live page showing it (https://www.storagefacilitycreator.com/sms-consent-demo now exists for this). Not worth resubmitting: SFC does not send from a local number. |
| CMf0d82519b5f45690c695db70775e4efb (created 2026-09-13, service MG9ddcb24e0946df41ba42ea88f57f29ab) | Hochatown Saloon | **30907**: "the provided website URL does not match the Brand and Campaign registered." **30886**: "invalid campaign description." The brand is Storage Facility Creator LLC; the campaign's website and description are the saloon's, a different business. Carriers match campaign website against brand. The saloon needs its own brand (its own legal entity and EIN) or, if it is legally the same LLC, a campaign whose website URL and description say Storage Facility Creator LLC / storagefacilitycreator.com. This is brand-level: any non-SFC business filed under this brand will bounce the same way. **Resolved 2026-09-20** by giving the saloon its own brand and a fresh campaign; see below. |

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

## Calls to the toll-free line (added 2026-09-14)

The number's voice webhook points at `handleSfcLeadCall`
(`functions-marketing/src/sfcLeadWebhooks.ts`); it used to point at Twilio's
demo greeting. The handler logs the caller as a marketing lead, plays a
greeting and a one-digit menu, and forwards to `SFC_LEAD_FORWARD_TO_NUMBER`:

| Key | What happens |
|---|---|
| 1 | Demo: forwards to the cell with the whisper "Demo request from the Storage Facility Creator eight five five line". Lead gets `lastCallMenuChoice: demo`. |
| 2 | Support: same forward, whisper says "Support call". |
| 3 | Reads out storagefacilitycreator.com, then repeats the menu. |
| nothing / other | Repeats the menu once, then forwards with a generic whisper. |

The whisper is a `<Number url="...?whisper=...">` leg back into the same
function; menu presses come back as `?step=choice&lead=<id>`. Both carry a
query string, which the shared `twilioWebhookUrl` keeps when rebuilding the
signed URL. If the forward number is empty the caller is asked to text
instead.

## Why the saloon passed and SFC did not (read 2026-09-21)

The saloon's second attempt, campaign CMa93db02b94977b90572ccf880f2abeae, was
created and **approved on the same day, 2026-09-20**. SFC's CM762f51... is
still Rejected on 30909 from 2026-01-10. Both sit in the same Twilio account,
so the difference is entirely in how each was filed.

| | Saloon (approved) | SFC (rejected) |
|---|---|---|
| Brand | **Hochatown Saloon LLC** BNabb4e1bbc9cde29508c021c16fe82137, its own legal entity | STORAGE FACILITY CREATOR LLC BN689de2fc..., Low volume standard, approved |
| Use case | **LOW_VOLUME** (Low Volume Mixed) | **ACCOUNT_NOTIFICATION** |
| Who the messages go to | the saloon's own staff and its own guests | **another company's tenants, on that company's behalf** |
| Consent story | "Both kinds of recipient opt in verbally, in person at the venue, and no one is added any other way." First-party, self-contained, nothing for a reviewer to go and check. | a checkbox on a facility's move-in form the reviewer cannot reach, described in prose and linked to `/sms-terms` (a terms page, not the form) |
| Sample messages | lead with the literal brand: "Hochatown Saloon: your [Sat 19 Sep] off is approved..." | lead with "**[Facility Name]**: ..." — no sample names the registered brand |
| Terms / privacy | `tickets.hochatownsaloon.com`, same domain as the brand website | `www.storagefacilitycreator.com/...` while the brand website is recorded as the apex `https://storagefacilitycreator.com` |

What that adds up to, in order of how much it matters:

1. **The campaign describes a third-party sending pattern under a direct
   brand.** SFC's filed description says the platform "sends transactional SMS
   notifications to a facility's tenants **on the facility's behalf**." A
   direct Standard / Low-Volume-Standard brand campaign is meant to cover the
   brand's own messages to the brand's own customers. As filed, the call to
   action belongs to each facility, not to SFC, so there is nothing about SFC
   that a reviewer can verify — which is exactly what 30909 says. This is the
   root cause, and it is why a cosmetic rewrite alone may bounce again.
2. **No sample message identifies the registered brand.** Every sample starts
   with the placeholder `[Facility Name]`. Reviewers look for the brand name
   in the sample text; the saloon's samples all start "Hochatown Saloon:".
3. **The opt-in field pointed at the wrong page.** It links `/sms-terms`.
   `/sms-consent-demo` — a public, login-free reproduction of the actual
   checkbox, built for precisely this review — did not exist on 2026-01-10 and
   is still not referenced by the campaign. It is live now and `/sms-terms`
   links to it.
4. **Use case tier.** ACCOUNT_NOTIFICATION draws the manual CTA review that
   rejected this. LOW_VOLUME is the lightest tier and is what sailed through
   for the saloon. SFC's real volume is nil, so nothing is given up by filing
   Low Volume Mixed.
5. **Apex vs www.** Brand website is `https://storagefacilitycreator.com`;
   the campaign's terms and privacy URLs are `https://www.` The apex 308s to
   www, so it resolves, but this is the exact class of mismatch that produced
   30907 for the saloon. Align them.

### The part worth saying out loud

**SFC does not currently need an approved 10DLC campaign.** Its only live
sender is the toll-free +1 855 526 4544, confirmed **Approved** again on
2026-09-21 (HH8589d700c3a7c4c995bedbf410351655, Storage Facility Creator LLC,
last updated Mar 24 2026). Toll-free verification is a separate regime from
10DLC; the toll-free number is fully registered and sending. CM762f51... has
no phone numbers assigned and has never carried traffic. Fixing it buys the
ability to send from **local** numbers, nothing else.

### If the campaign is resubmitted anyway

Two routes, and they are not the same product:

- **Route A — refile SFC's own campaign (Edit & resubmit on CM762f51...).**
  Switch the use case to Low Volume Mixed, reframe the description so the
  sender is SFC to *its own* users rather than SFC on behalf of facilities,
  name the brand in the samples, and point the opt-in field at
  `/sms-consent-demo`. Text below. A resubmission is likely to be charged the
  vetting fee (~$15) again — confirm the price shown in the flow before
  submitting. Risk: the "on behalf of" objection is structural, so this can
  bounce a second time.
- **Route B — do what the saloon did, per facility.** Each facility registers
  its own brand and its own campaign against its own number, which is the ISV
  shape the app already models (`a2pStatus`, `a2pBusinessInfo`, the
  sole-proprietor path in `functions-shared`, and the in-app texting setup in
  `docs/TEXTING_ONBOARDING_README.md`). This is the route that actually
  matches how the product sends, and it is the one that just demonstrably
  worked in this account in under a day. It needs each owner's own legal
  details, so it cannot be done for them.

**Decided 2026-09-21: neither, for now.** Stay on the approved toll-free for
every facility. SFC's own campaign is not being refiled — it buys a local
number nobody is asking for, at a vetting fee and a fair chance of a second
30909. Route B stays built and flagged off (`TEXTING_ONBOARDING_V1`), to be run
for a single facility on the day a paying customer actually asks for their own
local number. The two code changes made that day-one ready are in
`docs/TEXTING_ONBOARDING_README.md`: a per-facility campaign description, and
`LOW_VOLUME` instead of `ACCOUNT_NOTIFICATION` as the filed use case.

### Route A field text, ready to paste

- **Use case:** Low Volume Mixed.
- **Campaign description:** "Storage Facility Creator LLC operates
  storagefacilitycreator.com, self-storage management software. This campaign
  covers text messages Storage Facility Creator sends to people who have given
  the company their mobile number and asked to be texted: account and billing
  notifications for its own software subscribers, replies in conversations the
  recipient started, and responses to enquiries made through the company's
  website or its published phone line 855-526-4544. Consent is collected on a
  separate, un-prechecked checkbox at the point the number is given, and is
  never a condition of purchase. The consent step is reproduced publicly at
  https://storagefacilitycreator.com/sms-consent-demo and the full programme
  terms at https://storagefacilitycreator.com/sms-terms. No marketing lists,
  no purchased or rented numbers, no affiliate traffic."
- **Sample messages** (each names the brand; no unresolved placeholder in the
  sender position):
  1. "Storage Facility Creator: you're set up for account notification texts.
     Msg frequency varies. Msg & data rates may apply. Reply STOP to opt out,
     HELP for help."
  2. "Storage Facility Creator: your subscription payment of $99.00 was
     received. Thanks. Reply STOP to opt out, HELP for help."
  3. "Storage Facility Creator: we got your demo request and will call you
     today. Reply to this text any time. Reply STOP to opt out, HELP for
     help."
  4. "Storage Facility Creator: your card on file was declined, so your
     account is past due. Update it at storagefacilitycreator.com/billing.
     Reply STOP to opt out, HELP for help."
- **How do end-users opt in:** "The person enters their own mobile number and
  ticks a separate checkbox that is unchecked by default and is not a
  condition of purchase. The checkbox reads: 'I consent to receive SMS
  notifications regarding my storage account. Message frequency varies.
  Message & data rates may apply. Reply STOP to opt out, HELP for help.' The
  phone number, timestamp, consent text version and source are recorded. A
  publicly accessible copy of this exact step, with no login required, is at
  https://storagefacilitycreator.com/sms-consent-demo. Numbers reached by
  someone who called or texted 855-526-4544 first are treated as consent given
  by that person starting the conversation. No numbers are purchased, rented
  or imported."
- **Opt-in message:** "Storage Facility Creator: you're now opted in to
  account notification texts. Msg frequency varies. Msg & data rates may
  apply. Reply STOP to opt out, HELP for help."
- **Terms / privacy URLs:** use the **apex** to match the brand website:
  `https://storagefacilitycreator.com/terms` and
  `https://storagefacilitycreator.com/privacy`.
- **Embedded links:** yes. **Phone numbers:** yes. **Lending:** no.
  **Age-gated:** no.
- Leave the opt-out and help keywords/messages as they already are.

## What is left to do

1. Send one real text from a facility to a known phone to prove the path end
   to end now that the account is live (cost about one cent). Watch Monitor >
   Logs > Messaging for the delivery status.
2. Keepsake: finish the in-app texting setup (bundle, brand, campaign under
   the facility's secondary profile). Consent text for that form is below.
   Details still needed from Russell: legal name as on the EIN letter, full
   EIN, postal code, authorized representative.
3. ~~Saloon: register its own brand~~ — done 2026-09-20, approved same day.
4. ~~Decide whether to release +1 903 300 2119 and whether to delete the unused
   CM762f... campaign and its service.~~ All done 2026-09-21: campaign deleted,
   number released, messaging service MGadd2cfcf... deleted. Brand
   BN689de2fc... (STORAGE FACILITY CREATOR LLC) deliberately kept.

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

## The toll-free verification does not describe what we actually send (2026-09-22)

Read straight from the API
(`GET /v1/Tollfree/Verifications/HH8589d700c3a7c4c995bedbf410351655`), the
approved submission says this:

| Field | Approved content |
|---|---|
| Status | `TWILIO_APPROVED` |
| Use case | `ACCOUNT_NOTIFICATIONS` |
| Summary | "Storage Facility Creator uses this toll-free number for demo requests, support, onboarding follow-up, and account notifications. **Users opt in through our public web form**…" |
| Opt-in type | `WEB_FORM`, evidenced by `https://www.storagefacilitycreator.com/contact?intent=trial` |
| Sample | "Storage Facility Creator: Thanks for contacting us about a demo or trial…" |
| Volume | 1,000 |
| Additional info | "This toll-free number is the **primary business text line for Storage Facility Creator**… for Storage Facility Creator." |

Every word of that describes SFC texting **its own prospects and customers**,
the operators, who opted in on our contact form.

It does not describe what the platform actually sends. Production traffic on
this number goes to **facility tenants** — people who have never visited
storagefacilitycreator.com, whose consent was collected by the *operator* at
move-in, on a signed agreement or on the facility's own rental page. That is
the traffic the rent reminder job sends, and it is the traffic Keepsake's test
message was.

This is the same structural mismatch that produced **30909** on the 10DLC
campaign: the call to action belongs to a facility the reviewer cannot reach.
It is now true of the toll-free as well, and the toll-free is the number every
facility shares, so a carrier complaint or audit takes texting down for every
customer at once rather than one.

The public site is not the problem. `/sms-terms` already states the ISV model
correctly — that SFC sends "on the Customer's behalf", that "the Customer is
the responsible party for obtaining lawful consent from their tenants", and it
quotes the tenant consent checkbox, with `/sms-consent-demo` showing it live.
The filing is simply narrower than the product and older than it.

### What to file (Russell submits; this is a filing, not a code change)

Edit the toll-free verification and replace these fields:

**Use case summary**

> Storage Facility Creator LLC is a SaaS platform used by self-storage
> facility operators to manage their facilities. Messages on this number are
> sent by Storage Facility Creator on behalf of those operators to their own
> storage tenants, and every message names the facility it is from. Content is
> account notifications only: rent reminders before a due date, past-due
> notices, payment receipts, gate access codes, and move-in and move-out
> confirmations. Tenants give express written consent to their facility
> operator — on the facility's online rental page, on a signed rental
> agreement, or on a move-in form — and the operator records that consent per
> tenant in the software before any message can be sent. Msg frequency varies.
> Msg & data rates may apply. Reply STOP to opt out, HELP for help.

**Production message sample**

> Caprock Storage: Hi Doug, a reminder that rent for unit 2 of $130.00 is due
> Oct 1. Reply STOP to opt out, HELP for help.

**Opt-in type / evidence**

Keep `WEB_FORM`, and point the evidence URL at
`https://www.storagefacilitycreator.com/sms-consent-demo`, which shows the
exact unchecked consent checkbox a tenant sees, rather than
`/contact?intent=trial`, which is the form our *operators* fill in.

**Additional information**

> Storage Facility Creator is the messaging platform; the sending party for
> tenant messages is the facility operator who subscribes to it. Each outbound
> message is prefixed with the facility's name so the recipient can identify
> the sender, and carries the STOP/HELP footer. Consent is captured and stored
> per tenant, with the date and source, and STOP is honoured automatically for
> that tenant across the platform. Program terms are published at
> https://www.storagefacilitycreator.com/sms-terms and a live demonstration of
> the tenant opt-in checkbox is at
> https://www.storagefacilitycreator.com/sms-consent-demo .

**Volume**

1,000 is the current registered figure. One facility of Caprock's size sending
a monthly rent reminder plus receipts is a few hundred segments a month, so
this binds at roughly a dozen active facilities. Raise it in the same edit.

### The direction this points

Per-facility 10DLC (Route B) remains the structurally correct shape, because
then the brand, the campaign and the consent all belong to the business whose
tenants are being texted. The shared toll-free is the right answer for a trial
and the wrong answer at scale. The app now asks operators to start their own
registration during the trial, for exactly this reason.
