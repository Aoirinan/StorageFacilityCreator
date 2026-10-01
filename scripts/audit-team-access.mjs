#!/usr/bin/env node
/**
 * Read-only audit of team access: facility roles maps, user_roles rows and
 * invites, for signs of the invite holes the fix/invite-access-hardening
 * rules close, and for acceptances or removals that stopped part-way. Run it
 * before deploying those rules (what it finds was written under the old
 * ones) and decide each finding by hand; it never writes to Firestore.
 *
 * Findings (kind):
 * - invite-moved: an invite whose facilityId names another facility than the
 *   one it is stored under. The invitee's acceptance could change that field,
 *   and as owner of a facility of their own they could then reopen the
 *   invite, as a manager invite, after every removal.
 * - row-invite-unspent: an active role row written for an invite that is
 *   still pending, or is gone. The old rules let an invitee write their row
 *   and leave the invite pending, to use again after a removal; the old
 *   two-write acceptance also left these when it stopped part-way.
 * - map-entry-without-row: someone in a roles map (or the legacy managers
 *   map) with no active role row there. A roles-map write alone could join a
 *   team; the old removal deactivated the rows first, so one that failed
 *   after them left a removed member in the map, which the rules read.
 * - row-without-map-entry: an active role row for someone not in either map.
 *   The rules ignore it, but the callables that charge saved cards and take
 *   payments accept an active row as access.
 * - role-mismatch: someone's active rows at a facility disagree with each
 *   other or with the roles map. Those callables take any one active row.
 * - owner-or-admin-grant: an 'owner' or 'admin' roles-map entry for someone
 *   other than the facility's owner. Managers could grant these through
 *   invites; a co-owner the owner added is expected here.
 * - invite-reopened: a pending invite that records an acceptance
 *   (acceptedBy or acceptedAt). The app never sets an accepted invite back
 *   to pending; the invitee did, as owner of the facility they had moved it
 *   to, and may have moved it back since (so invite-moved no longer shows).
 * - invite-reused: two or more role rows, active or not, written for the
 *   same invite. One acceptance writes (or finishes) one row; a second row
 *   for the same invite is it being used again after a removal.
 *
 * And the worst of what an invitee could do while accepting under the old
 * rules, in the same write: they checked the facility merge with
 * changedKeys, which leaves out keys added and removed, so an invitee (or an
 * owner accepting an invite to their own address) could take any field off
 * the facility or add any it did not have yet, and could add or take out
 * other people's roles-map entries (both show as the kinds above).
 * - facility-without-owner: a facility whose ownerUid is gone. Taking it off
 *   locked the owner out of editing the facility and out of their owner
 *   queries.
 * - entitlement-on-invited-facility: a facility someone has accepted an
 *   invite to (it carries acceptingInviteId, which only that write sets)
 *   with a field that gives something away, in `reasons`: billingExempt
 *   (a free subscription), a platform or website subscription 'active' or
 *   'trialing' with no Stripe subscription id (and, for the website, no
 *   admin trial), no ownerAccountStanding (what lets invited staff in while
 *   the owner is suspended; the nightly sync puts it back only while
 *   ownerUid is there), a facilityCreatorAccountId naming an account that is
 *   not the owner's (another operator's paid plan), or texting approved.
 *   Each one may be genuine: check it against Stripe, the account doc and
 *   the super admin's own approvals. `fields` has what to check.
 * - connect-account-shared: a Stripe Connect account id on facilities with
 *   different owners. One could be added to a facility that had none, to
 *   take its tenants' payments. Check it against the account's
 *   metadata.facilityId in Stripe.
 * - legacy-manager-grant: someone the legacy managers map names a manager
 *   while the roles map gives them a lower role. The rules take the managers
 *   map as manager access; an invitee could add it, and a demotion left it.
 * - row-email-not-invitee: an active role row written for an invite whose
 *   userEmail is not that invite's address. The invitee writes userEmail,
 *   and the old removal cancelled the pending invites to it.
 * - invite-uncancelled: an accepted invite that records a cancellation. The
 *   old rules let a removed member mark their cancelled invite accepted.
 *
 * It also reads facilityCreatorAccounts (for the account check above).
 *
 * Credentials: Application Default Credentials
 * (`gcloud auth application-default login`), project from --project,
 * GOOGLE_CLOUD_PROJECT, or storage-facility-creator. Every run writes its
 * findings to --out (default backfill-records/ at the repo root, in
 * .gitignore: the findings hold user ids and email addresses).
 *
 * Usage:
 *   node scripts/audit-team-access.mjs [--facility <id> ...] [--project <id>] [--out <dir>]
 */
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/** backfill-records/ at the repo root (in .gitignore), wherever this is run from. */
export function defaultOutDir() {
  return path.join(repoRoot, 'backfill-records');
}

const isString = (value) => typeof value === 'string' && value.length > 0;

/** The uids a facility's maps give a role, with each one's role ('manager' for the legacy map). */
function mapRoles(facility) {
  const out = new Map();
  const managers = facility.managers;
  if (managers && typeof managers === 'object') {
    for (const [uid, on] of Object.entries(managers)) if (on === true) out.set(uid, 'manager');
  }
  const roles = facility.roles;
  if (roles && typeof roles === 'object') {
    for (const [uid, role] of Object.entries(roles)) if (role != null) out.set(uid, String(role));
  }
  return out;
}

const lower = (value) => (isString(value) ? value.trim().toLowerCase() : null);
const ACTIVE_STATUSES = new Set(['active', 'trialing']);

/**
 * Why [facility] (its data), which someone accepted an invite to, is worth
 * checking by hand: the fields an invitee could have added or taken off as
 * they accepted that give something away. [accountsById]: the
 * facilityCreatorAccounts read, or null when they were not.
 */
function entitlementReasons(facility, accountsById) {
  const reasons = [];
  if (facility.billingExempt === true) reasons.push('billing-exempt');
  if (ACTIVE_STATUSES.has(facility.platformSubscriptionStatus) && !isString(facility.stripePlatformSubscriptionId)) {
    reasons.push('platform-active-without-subscription');
  }
  if (
    ACTIVE_STATUSES.has(facility.websiteSubscriptionStatus) &&
    !isString(facility.stripeWebsiteSubscriptionId) &&
    facility.websiteAdminTrialEndsAt == null
  ) {
    reasons.push('website-active-without-subscription');
  }
  if (facility.ownerAccountStanding == null) reasons.push('no-owner-account-standing');
  if (accountsById && isString(facility.facilityCreatorAccountId)) {
    const account = accountsById.get(facility.facilityCreatorAccountId);
    if (!account || account.ownerUid !== facility.ownerUid) reasons.push('account-of-another-owner');
  }
  if (facility.textingPlatformApproved === true) reasons.push('texting-approved');
  return reasons;
}

/**
 * The findings for [facilities], [invites] and [roleRows] (every user_roles
 * row, active or not), each `{ id, data }` as read (an invite also has
 * `facilityId`, the facility it is stored under), [accounts] (every
 * facilityCreatorAccounts doc, or null to skip the account check) and
 * [allFacilities] (every facility, when [facilities] is narrowed: a Connect
 * account one of them shares with a facility outside it still shows).
 * Pure. Returns `{ findings, counts }`; each finding has `kind`, `facilityId`
 * and what identifies it (uid, inviteId, rowIds).
 */
export function auditTeamAccess({ facilities, invites, roleRows, accounts = null, allFacilities = facilities }) {
  const findings = [];
  const accountsById = accounts ? new Map(accounts.map((a) => [a.id, a.data ?? {}])) : null;
  const invitesAt = new Map();
  for (const invite of invites) {
    invitesAt.set(`${invite.facilityId}/${invite.id}`, invite);
    const named = invite.data?.facilityId;
    if (named !== invite.facilityId) {
      findings.push({
        kind: 'invite-moved',
        facilityId: invite.facilityId,
        inviteId: invite.id,
        namedFacilityId: named ?? null,
        status: invite.data?.status ?? null,
        roleType: invite.data?.roleType ?? null,
        emailLower: invite.data?.emailLower ?? null,
        acceptedBy: invite.data?.acceptedBy ?? null,
      });
    }
    if (invite.data?.status === 'pending' && (invite.data?.acceptedBy != null || invite.data?.acceptedAt != null)) {
      findings.push({
        kind: 'invite-reopened',
        facilityId: invite.facilityId,
        inviteId: invite.id,
        roleType: invite.data?.roleType ?? null,
        emailLower: invite.data?.emailLower ?? null,
        acceptedBy: invite.data?.acceptedBy ?? null,
      });
    }
    if (
      invite.data?.status === 'accepted' &&
      (invite.data?.cancelledAt != null || invite.data?.cancelledReason != null)
    ) {
      findings.push({
        kind: 'invite-uncancelled',
        facilityId: invite.facilityId,
        inviteId: invite.id,
        roleType: invite.data?.roleType ?? null,
        emailLower: invite.data?.emailLower ?? null,
        acceptedBy: invite.data?.acceptedBy ?? null,
        cancelledReason: invite.data?.cancelledReason ?? null,
      });
    }
  }

  const rowsByInvite = new Map();
  for (const row of roleRows) {
    const data = row.data ?? {};
    if (!isString(data.facilityId) || !isString(data.inviteId)) continue;
    const key = `${data.facilityId}/${data.inviteId}`;
    if (!rowsByInvite.has(key)) rowsByInvite.set(key, []);
    rowsByInvite.get(key).push(row);
  }
  for (const [key, rows] of rowsByInvite) {
    if (rows.length < 2) continue;
    const [facilityId, inviteId] = key.split('/');
    findings.push({
      kind: 'invite-reused',
      facilityId,
      inviteId,
      rows: rows.map((r) => ({
        rowId: r.id,
        uid: r.data?.userId ?? null,
        roleType: r.data?.roleType ?? null,
        isActive: r.data?.isActive === true,
      })),
    });
  }

  const activeRows = new Map();
  for (const row of roleRows) {
    const data = row.data ?? {};
    if (data.isActive !== true || !isString(data.userId) || !isString(data.facilityId)) continue;
    const key = `${data.facilityId}/${data.userId}`;
    if (!activeRows.has(key)) activeRows.set(key, []);
    activeRows.get(key).push(row);
    if (isString(data.inviteId)) {
      const invite = invitesAt.get(`${data.facilityId}/${data.inviteId}`);
      const status = invite ? invite.data?.status ?? null : 'missing';
      const rowEmail = lower(data.userEmail);
      if (invite && rowEmail != null && rowEmail !== lower(invite.data?.emailLower)) {
        findings.push({
          kind: 'row-email-not-invitee',
          facilityId: data.facilityId,
          uid: data.userId,
          rowId: row.id,
          inviteId: data.inviteId,
          userEmail: rowEmail,
          inviteEmailLower: invite.data?.emailLower ?? null,
        });
      }
      if (status !== 'accepted') {
        findings.push({
          kind: 'row-invite-unspent',
          facilityId: data.facilityId,
          uid: data.userId,
          rowId: row.id,
          inviteId: data.inviteId,
          inviteStatus: status,
          roleType: data.roleType ?? null,
        });
      }
    }
  }

  const facilityIds = new Set();
  for (const facility of facilities) {
    const data = facility.data ?? {};
    facilityIds.add(facility.id);
    const ownerUid = data.ownerUid;
    if (!isString(ownerUid)) {
      findings.push({
        kind: 'facility-without-owner',
        facilityId: facility.id,
        acceptingInviteId: data.acceptingInviteId ?? null,
      });
    }
    if (isString(data.acceptingInviteId)) {
      const reasons = entitlementReasons(data, accountsById);
      if (reasons.length > 0) {
        findings.push({
          kind: 'entitlement-on-invited-facility',
          facilityId: facility.id,
          acceptingInviteId: data.acceptingInviteId,
          reasons,
          fields: {
            ownerUid: ownerUid ?? null,
            billingExempt: data.billingExempt ?? null,
            platformSubscriptionStatus: data.platformSubscriptionStatus ?? null,
            stripePlatformSubscriptionId: data.stripePlatformSubscriptionId ?? null,
            websiteSubscriptionStatus: data.websiteSubscriptionStatus ?? null,
            stripeWebsiteSubscriptionId: data.stripeWebsiteSubscriptionId ?? null,
            hasWebsiteAdminTrial: data.websiteAdminTrialEndsAt != null,
            hasOwnerAccountStanding: data.ownerAccountStanding != null,
            facilityCreatorAccountId: data.facilityCreatorAccountId ?? null,
            accountOwnerUid: accountsById?.get(data.facilityCreatorAccountId)?.ownerUid ?? null,
            stripeConnectAccountId: data.stripeConnectAccountId ?? null,
            textingPlatformApproved: data.textingPlatformApproved ?? null,
          },
        });
      }
    }
    const roles = data.roles && typeof data.roles === 'object' ? data.roles : {};
    const managers = data.managers && typeof data.managers === 'object' ? data.managers : {};
    for (const [uid, on] of Object.entries(managers)) {
      const role = roles[uid];
      if (on === true && uid !== ownerUid && role != null && !['manager', 'owner', 'admin'].includes(String(role))) {
        findings.push({ kind: 'legacy-manager-grant', facilityId: facility.id, uid, mapRole: String(role) });
      }
    }
    const inMaps = mapRoles(data);
    for (const [uid, role] of inMaps) {
      if (uid === ownerUid) continue;
      const rows = activeRows.get(`${facility.id}/${uid}`) ?? [];
      if (rows.length === 0) {
        findings.push({ kind: 'map-entry-without-row', facilityId: facility.id, uid, role });
      }
      if (role === 'owner' || role === 'admin') {
        findings.push({ kind: 'owner-or-admin-grant', facilityId: facility.id, uid, role });
      }
      const rowRoles = new Set(rows.map((r) => String(r.data?.roleType ?? '')));
      if (rows.length > 0 && (rowRoles.size > 1 || !rowRoles.has(role))) {
        findings.push({
          kind: 'role-mismatch',
          facilityId: facility.id,
          uid,
          mapRole: role,
          rows: rows.map((r) => ({ rowId: r.id, roleType: r.data?.roleType ?? null })),
        });
      }
    }
    for (const [key, rows] of activeRows) {
      const [rowFacility, uid] = key.split('/');
      if (rowFacility !== facility.id || uid === ownerUid || inMaps.has(uid)) continue;
      findings.push({
        kind: 'row-without-map-entry',
        facilityId: facility.id,
        uid,
        rows: rows.map((r) => ({ rowId: r.id, roleType: r.data?.roleType ?? null, inviteId: r.data?.inviteId ?? null })),
      });
    }
  }

  const byConnectAccount = new Map();
  for (const facility of allFacilities) {
    const accountId = facility.data?.stripeConnectAccountId;
    if (!isString(accountId)) continue;
    if (!byConnectAccount.has(accountId)) byConnectAccount.set(accountId, []);
    byConnectAccount.get(accountId).push({ facilityId: facility.id, ownerUid: facility.data?.ownerUid ?? null });
  }
  for (const [accountId, holders] of byConnectAccount) {
    if (new Set(holders.map((h) => h.ownerUid)).size < 2) continue;
    for (const holder of holders) {
      if (!facilityIds.has(holder.facilityId)) continue;
      findings.push({
        kind: 'connect-account-shared',
        facilityId: holder.facilityId,
        stripeConnectAccountId: accountId,
        ownerUid: holder.ownerUid,
        sharedWith: holders.filter((h) => h.facilityId !== holder.facilityId),
      });
    }
  }

  const order = (f) => [f.facilityId, f.kind, f.uid ?? '', f.inviteId ?? ''].join('\u0000');
  findings.sort((a, b) => (order(a) < order(b) ? -1 : order(a) > order(b) ? 1 : 0));
  const counts = {};
  for (const finding of findings) counts[finding.kind] = (counts[finding.kind] ?? 0) + 1;
  return { findings, counts, facilitiesRead: facilityIds.size };
}

/** Parses argv; throws on anything it does not know. */
export function parseArgs(argv) {
  const out = { facilities: [], project: null, outDir: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${arg} needs a value`);
      return v;
    };
    if (arg === '--facility') out.facilities.push(value());
    else if (arg === '--project') out.project = value();
    else if (arg === '--out') out.outDir = value();
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = args.project || process.env.GOOGLE_CLOUD_PROJECT || 'storage-facility-creator';
  // firebase-admin is not a root dependency; borrow functions-tenant-lifecycle's copy.
  const require = createRequire(path.join(repoRoot, 'functions-tenant-lifecycle', 'package.json'));
  const { initializeApp, applicationDefault } = require('firebase-admin/app');
  const { getFirestore } = require('firebase-admin/firestore');
  initializeApp({ credential: applicationDefault(), projectId });
  const db = getFirestore();

  const only = new Set(args.facilities);
  const keep = (facilityId) => only.size === 0 || only.has(facilityId);
  const [facilitySnap, inviteSnap, rowSnap, accountSnap] = await Promise.all([
    // Every facility even with --facility: a Connect account shared with a
    // facility outside the list still shows (only listed ones are reported).
    db.collection('facilities').get(),
    db.collectionGroup('invites').get(),
    // Every row, not just active ones: a row reused after a removal sits
    // beside the inactive one first written for that invite.
    db.collection('user_roles').get(),
    db.collection('facilityCreatorAccounts').get(),
  ]);
  const allFacilities = facilitySnap.docs.map((d) => ({ id: d.id, data: d.data() }));
  const facilities = allFacilities.filter((f) => keep(f.id));
  const accounts = accountSnap.docs.map((d) => ({ id: d.id, data: d.data() }));
  const invites = inviteSnap.docs
    // Facility invites only (facilities/{id}/invites/{id}).
    .filter((d) => d.ref.parent.parent?.parent?.id === 'facilities' && keep(d.ref.parent.parent.id))
    .map((d) => ({ id: d.id, facilityId: d.ref.parent.parent.id, data: d.data() }));
  const roleRows = rowSnap.docs.filter((d) => keep(String(d.get('facilityId') ?? ''))).map((d) => ({ id: d.id, data: d.data() }));

  const result = auditTeamAccess({ facilities, invites, roleRows, accounts, allFacilities });
  const outDir = path.resolve(args.outDir || defaultOutDir());
  mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const file = path.join(outDir, `team-access-audit-${stamp}.json`);
  const record = {
    mode: 'read-only',
    projectId,
    ranAt: new Date().toISOString(),
    read: {
      facilities: facilities.length,
      invites: invites.length,
      roleRows: roleRows.length,
      activeRoleRows: roleRows.filter((r) => r.data.isActive === true).length,
      accounts: accounts.length,
    },
    counts: result.counts,
    findings: result.findings,
  };
  writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);

  console.log(`READ ONLY: team access audit, project ${projectId}`);
  console.log(`  read: ${JSON.stringify(record.read)}`);
  console.log(`  findings: ${result.findings.length === 0 ? 'none' : JSON.stringify(result.counts)}`);
  for (const f of result.findings) {
    console.log(
      `  ${f.kind} facility ${f.facilityId}${f.uid ? ` uid ${f.uid}` : ''}${f.inviteId ? ` invite ${f.inviteId}` : ''}` +
        (f.reasons ? ` (${f.reasons.join(', ')})` : ''),
    );
  }
  console.log(`  record: ${file}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e?.message ?? e);
    process.exit(1);
  });
}
