import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

function digitsOnly(phone: string): string {
  return String(phone || '').replace(/\D/g, '');
}

function isDnrEntryExpired(expiresAt: admin.firestore.Timestamp | undefined): boolean {
  if (!expiresAt) return false;
  return expiresAt.toDate().getTime() < Date.now();
}

function normalizedName(value: string): string {
  return String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

/** Last ten digits, so +1 and formatting differences still compare equal. */
function comparablePhone(value: string): string {
  const digits = digitsOnly(value);
  return digits.length > 10 ? digits.slice(-10) : digits;
}

/**
 * Strict match for the UNAUTHENTICATED screening path.
 *
 * The operator-facing Dart rules (`GlobalDNRService.globalEntryMatchesTenantSearch`)
 * match on two-way substrings, which is reasonable when a signed-in manager is
 * searching their own screen. Exposed to the public move-in endpoint it became
 * an extraction oracle over a platform-wide list of named people: because the
 * probe could be SHORTER than the entry, a caller could submit "a", then "ab",
 * then "abc", and read names and phone numbers out of the Do Not Rent list one
 * character at a time. Single-digit phone probes behaved the same way via the
 * two-way `endsWith`.
 *
 * Here the probe must be at least as specific as the entry: full email, full
 * ten-digit phone, or the complete name. That still blocks the person the list
 * is meant to block, while reducing the endpoint to confirming an identity the
 * caller already knows in full — which is what the per-facility path, with its
 * exact-equality queries, has always done.
 */
export function globalEntryMatchesStrict(
  entry: { fullName: string; email: string; phone: string },
  name: string,
  email: string,
  phone: string,
): boolean {
  const probeEmail = String(email || '').trim().toLowerCase();
  const entryEmail = String(entry.email || '').trim().toLowerCase();
  if (probeEmail.length > 0 && entryEmail.length > 0 && probeEmail === entryEmail) {
    return true;
  }

  const probePhone = comparablePhone(phone);
  const entryPhone = comparablePhone(entry.phone);
  if (probePhone.length === 10 && entryPhone.length === 10 && probePhone === entryPhone) {
    return true;
  }

  const probeName = normalizedName(name);
  const entryName = normalizedName(entry.fullName);
  // A bare given name is not specific enough to act on, and matching one would
  // reopen the oracle for common names.
  if (probeName.length >= 5 && probeName.includes(' ') && probeName === entryName) {
    return true;
  }

  return false;
}

/**
 * Blocks public / online move-in when the person matches an active facility DNR (any facility)
 * or platform-wide global DNR, mirroring in-app `checkDNRScreening` / `findActiveMatchingEntries`.
 */
export async function assertOnlineRentalNotOnDnrList(
  db: admin.firestore.Firestore,
  params: { name: string; email: string; phone: string },
): Promise<void> {
  const nameLower = params.name.trim().toLowerCase();
  const emailLower = params.email.trim().toLowerCase();
  const phoneDigits = digitsOnly(params.phone);

  const dnrGroup = db.collectionGroup('dnr');
  const queries: Promise<admin.firestore.QuerySnapshot>[] = [];
  if (nameLower.length > 0) {
    queries.push(dnrGroup.where('active', '==', true).where('nameLower', '==', nameLower).limit(50).get());
  }
  if (emailLower.length > 0) {
    queries.push(dnrGroup.where('active', '==', true).where('emailLower', '==', emailLower).limit(50).get());
  }
  if (phoneDigits.length > 0) {
    queries.push(dnrGroup.where('active', '==', true).where('phoneDigits', '==', phoneDigits).limit(50).get());
  }

  const snapshots = await Promise.all(queries);
  const seen = new Set<string>();
  for (const snap of snapshots) {
    for (const doc of snap.docs) {
      if (seen.has(doc.ref.path)) continue;
      seen.add(doc.ref.path);
      const row = doc.data() as Record<string, any>;
      if (row.active !== true) continue;
      if (isDnrEntryExpired(row.expiresAt as admin.firestore.Timestamp | undefined)) continue;
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Online move-in is not available. Please contact the facility directly.',
      );
    }
  }

  const globalSnap = await db
    .collection('global_dnr_entries')
    .where('status', '==', 'active')
    .orderBy('createdAt', 'desc')
    .limit(500)
    .get();

  for (const doc of globalSnap.docs) {
    const d = doc.data() as Record<string, any>;
    if (String(d.status || '').toLowerCase() !== 'active') continue;
    const entry = {
      fullName: String(d.fullName || ''),
      email: String(d.email || ''),
      phone: String(d.phone || ''),
    };
    if (globalEntryMatchesStrict(entry, params.name, params.email, params.phone)) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Online move-in is not available. Please contact the facility directly.',
      );
    }
  }
}
