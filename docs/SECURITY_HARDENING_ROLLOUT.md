# Security hardening rollout

This release closes the role-retargeting, client-writable entitlement, public
token, DNR evidence, and public export findings.

## Safety rules

- Run the cleanup tool in dry-run mode first.
- Treat its JSON output as sensitive: it contains replacement bearer tokens.
- Do not run `--apply` until the new public callables and updated web client are
  deployed.
- Keep the dry-run output so facility operators can reissue rotated payment and
  move-in links.

## Rollout order

1. Deploy the new `public-website` and `automation` callables.
2. Deploy the updated Flutter web client and confirm `/pay`,
   `/public-move-in`, and export downloads use callables.
3. Run the cleanup tool in dry-run mode and review counts and suspicious-state
   audit results.
4. Apply token rotation and export ACL cleanup.
5. Deploy Firestore and Storage rules.
6. Smoke-test invite acceptance, billing webhooks, DNR evidence, public payment
   and move-in flows, and private export downloads.

The role, entitlement, and DNR rule changes do not require a client migration,
but deploying all rule changes in step 5 keeps the release easy to roll back.

Before enabling signed export downloads, ensure the runtime service account for
the `automation` functions can sign blobs for itself (normally by granting it
`roles/iam.serviceAccountTokenCreator`). Without `iam.serviceAccounts.signBlob`,
`getExportDownloadUrl` cannot mint a V4 signed URL.

## Cleanup commands

From `functions-admin` with Application Default Credentials configured:

```powershell
npm run security:cleanup -- --project=<project-id> > security-cleanup-dry-run.json
```

Review the report, then explicitly apply:

```powershell
npm run security:cleanup -- --project=<project-id> --apply --confirm-project=<project-id> > security-cleanup-applied.json
```

The applied run:

- replaces pending public payment-link tokens and revokes old documents;
- rotates pending/confirmed reservation tokens;
- removes public ACLs from current exports and deletes exports older than the
  retention window;
- reports active accounts missing Stripe subscription IDs; and
- reports role records whose assigner is no longer facility management.

The audit findings are report-only. The tool never changes subscriptions or
role assignments.

## Verification

Run before deployment:

```powershell
npm test --prefix firestore-rules-test
npm run build --prefix functions-public-website
npm test --prefix functions-public-website
npm run build --prefix functions-automation
npm run build --prefix functions-admin
flutter analyze
flutter test
firebase deploy --only functions:public-website,functions:automation --dry-run
```

After cleanup and rules deployment, verify:

- old rotated links fail and replacement links work;
- anonymous Firestore reads of `publicPaymentLinks` and
  `publicReservations` fail;
- a facility-A manager cannot retarget a role to facility B;
- account/facility owners cannot edit subscription entitlement fields;
- lapsed DNR participants cannot download evidence;
- anonymous export object URLs return access denied; and
- fresh signed export URLs expire after one hour.

## Rollback

Function and client changes are backward-compatible with existing document
shapes. If rollback is necessary, redeploy the previous functions/client and
rules. Rotated bearer tokens and revoked export ACLs must not be restored;
operators should continue using replacement links and authenticated downloads.
