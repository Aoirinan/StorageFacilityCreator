/**
 * Deciding whether an owner may link their own facility to their own platform
 * account.
 *
 * `facilities/{id}.facilityCreatorAccountId` is backend-only for a good
 * reason: entitlement is resolved by reading that id and checking whether the
 * named account's subscription is active, without checking who owns that
 * account. A client that could write it could point its facility at any paying
 * operator's account and inherit premium entitlements without paying.
 *
 * But the ordinary signup path has to set it, on the owner's own facility,
 * immediately after creating it. Locking the field without providing that path
 * left self-serve facility creation failing at the link step. So the rule
 * stays shut and the legitimate case goes through a server check instead,
 * which is this.
 */

export type LinkRefusalCode = 'not-found' | 'permission-denied' | 'already-linked';

export type FacilityAccountLinkDecision =
  | { ok: true; alreadyLinked: boolean }
  | { ok: false; code: LinkRefusalCode; message: string };

export interface LinkableFacility {
  ownerUid?: unknown;
  facilityCreatorAccountId?: unknown;
}

export interface LinkableAccount {
  ownerUid?: unknown;
}

function str(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export function decideFacilityAccountLink(input: {
  callerUid: string;
  accountId: string;
  facility: LinkableFacility | null | undefined;
  account: LinkableAccount | null | undefined;
}): FacilityAccountLinkDecision {
  const caller = str(input.callerUid);
  const accountId = str(input.accountId);
  if (!caller) {
    return { ok: false, code: 'permission-denied', message: 'Not signed in.' };
  }
  if (!accountId) {
    return { ok: false, code: 'not-found', message: 'accountId is required.' };
  }
  if (!input.facility) {
    return { ok: false, code: 'not-found', message: 'Facility not found.' };
  }
  if (!input.account) {
    return { ok: false, code: 'not-found', message: 'Account not found.' };
  }

  // Both halves must belong to the caller. Checking only one would let an
  // owner attach their facility to a stranger's paying account, which is the
  // entitlement theft the Firestore rule exists to stop.
  if (str(input.facility.ownerUid) !== caller) {
    return { ok: false, code: 'permission-denied', message: 'You do not own this facility.' };
  }
  if (str(input.account.ownerUid) !== caller) {
    return { ok: false, code: 'permission-denied', message: 'You do not own this account.' };
  }

  const existing = str(input.facility.facilityCreatorAccountId);
  if (existing && existing !== accountId) {
    // Re-pointing a facility at a different account is how a lapsed operator
    // would inherit a paying one's entitlements. Support can move it; the
    // owner cannot.
    return {
      ok: false,
      code: 'already-linked',
      message: 'This facility is already linked to a different account.',
    };
  }

  return { ok: true, alreadyLinked: existing === accountId };
}
