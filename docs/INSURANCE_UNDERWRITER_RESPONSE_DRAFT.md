# Insurance Underwriter Response — FINAL (v2, July 18 2026)

**Re: Storage Facility Creator LLC — Client ID: 14074292**

> Status: FINAL TEXT — decisions filled in (breach notice = 7 days; vendor DPAs = standard
> terms). Before sending: (1) deploy the app + rules + marketing site so every referenced
> safeguard is live, and (2) attorney review of answers 3–5 is still strongly recommended
> (defamation / Fair Housing / FCRA-adjacent exposure).

---

Hello,

Thank you for the follow-up. Answers to each of your five questions are below.

## 1. Indemnification and liability terms with Stripe, Twilio, SendGrid, and Firebase

We do not hold custom negotiated contracts with these providers. We operate under each
vendor's standard commercial terms and Data Processing Addendum, under which each vendor
is responsible for the security and availability of its own platform:

- **Stripe** — Stripe Services Agreement + Stripe DPA. All card data is collected and
  vaulted entirely within Stripe's PCI-DSS Level 1 environment via Stripe's embedded
  payment elements. Our systems never store, process, or transmit raw card numbers; we
  retain only tokenized identifiers and display metadata (brand / last four / expiration).
- **Twilio and SendGrid** — Twilio Terms of Service + Twilio DPA (SendGrid is a Twilio
  company). Used solely for SMS and transactional email delivery.
- **Google Cloud / Firebase** — Google Cloud Platform Terms of Service + Cloud Data
  Processing Addendum, which include Google's breach-notification commitments to us as
  the customer.

These agreements are incorporated into the standard service terms we operate under for
each account; copies or links are available on request.

On the customer-facing side, our Terms of Service provide the Service "as is," cap our
aggregate liability at fees paid in the trailing twelve months, and require customers
(facility operators) to indemnify us for claims arising from their Customer Data and
their messaging activities.

## 2. Where and how tenant data is stored and transmitted; notification obligations

**Storage.** All tenant data is stored in Google Cloud (United States region) using
Firebase services: Cloud Firestore (structured records), Cloud Storage (documents such
as signed leases and uploaded evidence), and Firebase Authentication (operator
credentials). Data is encrypted in transit (TLS 1.2+) and at rest (Google-managed
encryption). Access is role-based and scoped per facility: staff of one facility cannot
read another facility's tenant records.

**Transmission to subprocessors.** Tenant data flows to subprocessors only as needed to
deliver a specific function:

| Subprocessor | Data transmitted | Purpose |
|---|---|---|
| Stripe | Tenant name, email, tokenized payment method | Payment processing (Stripe Connect) |
| Twilio | Tenant phone number, message body | SMS delivery (opt-in only) |
| SendGrid | Tenant email address, message body | Transactional email delivery |
| Google Cloud / Firebase | All Customer Data | Core infrastructure |
| OpenAI | Staff-typed assistant questions (no bulk tenant records) | Optional in-app AI assistant |
| Intuit (QuickBooks) | Tenant name, email, phone, invoice/payment references | Optional accounting sync, per-customer opt-in |

Our public subprocessor list at [marketing site]/subprocessors reflects this table.

**Notification obligations.** If we confirm a breach of security affecting personal data
we process on a customer's behalf, we notify affected customers **without undue delay
and in any event within seven (7) days of confirmation**, with a description of the
incident, the categories of data involved, and remediation steps, so customers can meet
their own obligations to tenants and regulators. This commitment is published in our
Privacy Policy. Each subprocessor is contractually obligated (via its DPA) to notify us
of breaches on its platform, and we pass those notifications through on the same
timeline.

## 3. Review / verification before a Do Not Rent entry becomes visible

Entries can be created only by authenticated facility owners or managers on active paid
subscriptions — never by anonymous users or tenants. Controls applied at creation:

- **Identity and role verification:** creation is restricted (enforced server-side by
  Firestore security rules) to the owner/manager of the submitting facility, and every
  entry is permanently attributed to the named individual user and facility that
  submitted it.
- **Facility email verification:** facility-level entries additionally require a
  six-digit verification code sent to the facility's registered email address before the
  entry can be saved.
- **Mandatory accuracy attestation:** before any entry (facility-level or shared) can be
  published, the submitting user must affirmatively attest that the entry is factual,
  based on documented business experience, and not based on any protected
  characteristic. The attestation is recorded with the entry and enforced by server-side
  security rules.
- **Audit trail:** creation, modification, deactivation, and deletion of entries are
  written to an immutable audit log.

- **Participation gate:** shared entries are visible only to *participating* operators —
  accounts holding an active paid subscription that have recorded a one-time acceptance
  of our Do Not Rent terms (covering accuracy, non-discrimination, and the dispute
  process). Both conditions are enforced server-side by our database security rules on
  every read, so lapsed or non-participating accounts lose access automatically. Shared
  entries are never visible to the public or to tenants.

Entries become visible to other participating facilities upon completion of these steps;
there is not currently a centralized human moderation queue staffed by SFC. However, SFC
maintains an internal moderation panel through which platform administrators can review,
deactivate, or permanently delete any entry on the platform (facility-level or shared) at
any time. Our Terms of Service and Do Not Rent Data Policy reserve this removal right at
our sole discretion, and we remove entries that violate the policy upon report or
discovery.

## 4. Safeguards against discriminatory, inaccurate, or unsupported entries; disputes

**Preventive safeguards:**
- Only verified facility owners/managers can create entries (subscription-gated,
  role-checked server-side).
- Both reading and contributing to the shared list require registered DNR
  participation: an active paid subscription plus a recorded acceptance of our Do Not
  Rent terms, enforced by server-side security rules.
- A documented, business-related reason is mandatory on every entry.
- The mandatory accuracy attestation (described above) explicitly prohibits entries
  based on race, color, religion, national origin, sex, familial status, disability, or
  any other protected characteristic, and requires that entries be supported by the
  facility's internal records.
- Compliance guidance is displayed directly on the entry-creation screens, and our
  Acceptable Use Policy and Do Not Rent Data Policy prohibit discriminatory,
  retaliatory, or unsupported entries.
- Supporting evidence (photos/documents) can be attached to shared entries.
- Full attribution: every entry records who created it, at which facility, and when.

**Disputes and corrections:** Our published Do Not Rent Data Policy provides a
correction/removal process: an individual (or a facility acting on their behalf) may
dispute an entry by contacting us; we route the dispute to the submitting facility,
which must substantiate or correct the entry, and we deactivate or remove entries that
cannot be substantiated or that violate policy. Entries can be deactivated or given
expiration dates by the submitting facility at any time, and disputed shared entries are
flagged with an "appealed" status while under review.

The platform is a tool for facilities to document their own direct business experience;
it is not a consumer reporting agency, and we advise customers that if they use
third-party consumer reports for rental decisions, FCRA obligations are theirs.

## 5. Does SFC carry liability exposure for entries submitted by client facilities?

Risk is allocated contractually to the submitting facility:

- Our Terms of Service make the customer solely responsible for the accuracy,
  legality, and non-discriminatory nature of all Customer Data they enter, explicitly
  including Do Not Rent entries.
- Customers indemnify SFC for claims arising from their Customer Data, their Do Not
  Rent entries, and their messaging activities.
- The Service is provided "as is," and our aggregate liability is capped at trailing
  twelve months of fees.
- Each entry is attributed to the submitting facility and user, so responsibility for
  any individual entry is traceable to its source.
- SFC does not verify, endorse, or adopt the content of customer-submitted entries and
  expressly disclaims the role of consumer reporting agency; we act as a neutral
  technology provider hosting customer-generated business records.
- Every participant affirmatively accepts a participation agreement (published on our
  Do Not Rent Data Policy page) before gaining access, which includes an express
  no-liability disclaimer and a defend-and-indemnify obligation in SFC's favor, and
  acknowledges SFC's unilateral right to remove any entry. Acceptances are recorded
  with user identity, account, timestamp, and terms version.

We are seeking coverage in part for the residual platform risk associated with hosting
this shared data. If you need more detail on any of these controls, I'm happy to answer
further questions by email.

---

Our published policies are available for your review: Terms of Service (/terms), Privacy
Policy (/privacy), Do Not Rent Data Policy (/dnr-policy), Subprocessor List
(/subprocessors), and Security Overview (/security) on our website. Please let me know
by reply if you need any supporting documentation.

Thank you,
Russell Forsyth
Storage Facility Creator LLC

---

## Internal checklist before sending (not part of the email)

- [ ] Deploy the app + Firestore rules changes (accuracy attestation, audit logging,
      archive fix) — **deploy the web app first or simultaneously with rules**, since
      the new rules require the attestation field on create.
- [ ] Deploy the marketing site (subprocessor list, Privacy Policy breach clause,
      ToS DNR clause, DNR Data Policy page).
- [ ] Spot-check vendor DPA acceptance in each dashboard (Stripe/Google auto-incorporate;
      Twilio may require accepting in console) so "available on request" holds up.
- [ ] Attorney review of: DNR Data Policy page, ToS section 9 (DNR), 7-day breach
      commitment, and answers 3–5 above.
- [x] ~~Decide whether the platform-wide global DNR list should remain readable by every
      authenticated operator or be scoped/consented~~ — RESOLVED: shared DNR reads and
      creates are now gated (in Firestore/Storage rules) on "DNR participation" = active
      paid subscription + recorded one-time DNR terms acceptance (`dnr_participants/{uid}`).
      Existing DNR users will be prompted to accept the terms once on next use.
