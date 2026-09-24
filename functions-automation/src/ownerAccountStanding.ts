import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  OWNER_ACCOUNT_STANDING_FIELD,
  accountWriteAffectsStanding,
  listOwnerAccountDocs,
  syncOwnerAccountStanding,
  type OwnerStandingSyncDeps,
} from '@sfc/functions-shared';

/**
 * Keeps `facilities/{id}.ownerAccountStanding` in step with the owner's
 * platform account.
 *
 * Invited team members have no account of their own and cannot read the
 * owner's (the rules only let its owner), so the app decides whether the
 * owner's billing still covers them from this copy on each facility they work
 * at. It is backend-only (facilityEntitlementWriteForbiddenKeys): an owner who
 * could write it could keep their staff in after their own access lapsed.
 */

/** Cap per nightly run so one bad night cannot spend the whole budget. */
const MAX_OWNERS_PER_RUN = 5000;

export function firestoreOwnerStandingDeps(db: admin.firestore.Firestore): OwnerStandingSyncDeps {
  return {
    listOwnerAccounts: (ownerUid) => listOwnerAccountDocs(db, ownerUid),
    listOwnerFacilities: async (ownerUid) =>
      (await db.collection('facilities').where('ownerUid', '==', ownerUid).get()).docs,
    writeFacilityStanding: async (facilityId, standing) => {
      // Not updatedAt: this is not an edit anyone made to the facility.
      await db
        .collection('facilities')
        .doc(facilityId)
        .update({ [OWNER_ACCOUNT_STANDING_FIELD]: standing ?? admin.firestore.FieldValue.delete() });
    },
  };
}

function ownerUidOf(data: Record<string, unknown> | undefined): string | null {
  const uid = typeof data?.ownerUid === 'string' ? data.ownerUid.trim() : '';
  return uid || null;
}

/**
 * The trigger's body. Every owner the write touches (both, in the unlikely
 * case ownerUid itself changed) is re-synced from all of their accounts, not
 * from this one doc, so a write to a duplicate can never displace the
 * preferred account's standing.
 */
export async function handleAccountWriteForStanding(
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
  deps: OwnerStandingSyncDeps,
): Promise<{ owners: number; updated: number }> {
  if (!accountWriteAffectsStanding(before, after)) return { owners: 0, updated: 0 };
  const owners = new Set(
    [ownerUidOf(before), ownerUidOf(after)].filter((uid): uid is string => uid != null),
  );
  let updated = 0;
  for (const ownerUid of owners) {
    updated += (await syncOwnerAccountStanding(ownerUid, deps)).updated;
  }
  return { owners: owners.size, updated };
}

export type StandingSweepSummary = { owners: number; updated: number; failed: number };

/**
 * Re-syncs every owner that has an account: the backfill for facilities
 * written before the trigger existed, and a backstop for a trigger run that
 * failed. One owner failing does not stop the rest.
 */
export async function syncAllOwnerAccountStanding(
  listAccountOwnerUids: () => Promise<string[]>,
  deps: OwnerStandingSyncDeps,
): Promise<StandingSweepSummary> {
  const owners = [...new Set(await listAccountOwnerUids())].slice(0, MAX_OWNERS_PER_RUN);
  const summary: StandingSweepSummary = { owners: owners.length, updated: 0, failed: 0 };
  for (const ownerUid of owners) {
    try {
      summary.updated += (await syncOwnerAccountStanding(ownerUid, deps)).updated;
    } catch (err: unknown) {
      summary.failed += 1;
      functions.logger.error('Owner account standing sync failed', { ownerUid, err });
    }
  }
  return summary;
}

export const mirrorOwnerAccountStanding = functions
  .runWith({ timeoutSeconds: 120, memory: '256MB' })
  .firestore.document('facilityCreatorAccounts/{accountId}')
  .onWrite(async (change, context) => {
    const before = change.before.exists ? (change.before.data() as Record<string, unknown>) : undefined;
    const after = change.after.exists ? (change.after.data() as Record<string, unknown>) : undefined;
    const result = await handleAccountWriteForStanding(
      before,
      after,
      firestoreOwnerStandingDeps(admin.firestore()),
    );
    if (result.updated > 0) {
      functions.logger.info('Owner account standing mirrored', {
        accountId: context.params.accountId,
        ...result,
      });
    }
  });

export const syncOwnerAccountStandingNightly = functions
  .runWith({ timeoutSeconds: 540, memory: '256MB' })
  .pubsub.schedule('45 5 * * *') // 05:45 UTC, after the 05:30 trial sweep
  .timeZone('UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const summary = await syncAllOwnerAccountStanding(
      async () =>
        (await db.collection('facilityCreatorAccounts').select('ownerUid').get()).docs
          .map((d) => ownerUidOf(d.data()))
          .filter((uid): uid is string => uid != null),
      firestoreOwnerStandingDeps(db),
    );
    functions.logger.info('Owner account standing sweep finished', summary);
    return null;
  });
