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
