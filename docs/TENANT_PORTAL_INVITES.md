# Tenant portal invites

Operators email tenants the portal link and their access code from the app.
Nothing else ever told a tenant their code; it was shown once at creation.

## Where
- Tenants list: the per-tenant menu → "Email portal invite".
- Tenants list: Select Multiple → "Email invites (N)".
- Tenant detail: Tenant Portal card → "Email portal invite" (or "Enable portal & email invite").

## What it does
`sendTenantPortalInvites` (functions-tenant-lifecycle) takes a facility and either
`tenantIds` or `allActive: true` (cap 200 per call). For each tenant it:
1. skips blank or `@example.com` emails (counted as `skippedNoEmail`),
2. sets `portalEnabled: true` and mints an 8-character code from the phone-safe
   alphabet (no 0/O/1/I) if none exists (`codesGenerated`),
3. sends the invite through `sendFacilityEmailWithCompliance`, so unsubscribes
   and the pre-launch customer contact gate both apply,
4. on a real send stamps `portalInviteSentAt` and increments `portalInviteCount`.

The result is shown to the operator in one sentence, naming how many were held by
the pre-launch gate so a zero is not mistaken for a failure.

## Copy
`buildTenantPortalInviteEmail` in `functions-shared/src/portal/portalInviteEmail.ts`,
tested in `functions-shared/src/test/portalInviteEmail.test.ts`. The autopay pitch
appears only when the facility's Stripe account can take cards.

## Authorization
Caller must be the facility owner or a manager (`getFacilityDataForUserOrThrow`),
with App Check enforced.

## "Forgot your access code?"

On the portal login (which every public facility site links to) a tenant can
enter the email or phone number on file. `requestPortalAccessCodeReminder`
(functions-tenant-lifecycle) is unauthenticated and behaves like a password
reset: same reply whether or not anything matched, rate-limited per identifier
and IP with the portal login limiter (misses count as failed logins), and the
code goes only to the email already on the tenant record, never to the address
typed in. A code is minted if the record has none. Public sites also carry a
footer link "Forgot your portal access code?" that opens the dialog directly
(`?forgot=1` before the hash route).

Delivery is email only until Twilio texting is live; the phone lookup is in
place so adding an SMS there is one call.

## Coming back from Stripe (card save and Pay now)

The app routes by hash, so any Stripe return URL must put its query before the
hash route: `https://app…/?portal_payment=success&session_id=…#/tenant-portal`.
A path-style URL such as `/portal/payment/success` has no route and lands the
tenant on the facility-manager login. Before Stripe opens (same tab), the portal
parks the tenant's lookup in sessionStorage (`TenantPortalSessionStore`, 15 min,
used once); the access screen reads `redirect_status` (Payment Element) or
`portal_payment` (Checkout), resumes the session, and shows "Card saved" or
"Payment received". The webhook, not the return, is what records the payment
and posts the ledger entry.
