import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

function digitsOnly(phone: string): string {
  return String(phone || '').replace(/\D/g, '');
}

function isDnrEntryExpired(expiresAt: admin.firestore.Timestamp | undefined): boolean {
  if (!expiresAt) return false;
  return expiresAt.toDate().getTime() < Date.now();
}

/** Same fuzzy name/email/phone rules as `GlobalDNRService.globalEntryMatchesTenantSearch` (Dart). */
function globalEntryMatchesTenantSearch(
  entry: { fullName: string; email: string; phone: string },
  name: string,
  email: string,
  phone: string,
): boolean {
  let isMatch = false;
  const n = name.trim();
  const e = email.trim();
  const p = phone.trim();
  if (n.length > 0) {
    const nameLower = n.toLowerCase();
    const entryNameLower = String(entry.fullName || '').toLowerCase();
    if (entryNameLower.includes(nameLower) || nameLower.includes(entryNameLower)) {
      isMatch = true;
    }
  }
  if (e.length > 0) {
    const emailLower = e.toLowerCase();
    const entryEmail = String(entry.email || '').toLowerCase();
    if (entryEmail.includes(emailLower) || emailLower.includes(entryEmail)) {
      isMatch = true;
    }
  }
  if (p.length > 0) {
    const phoneDigits = digitsOnly(p);
    if (phoneDigits.length > 0) {
      const entryDigits = digitsOnly(entry.phone);
      if (entryDigits.endsWith(phoneDigits) || phoneDigits.endsWith(entryDigits)) {
        isMatch = true;
      }
    }
  }
  return isMatch;
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
    if (globalEntryMatchesTenantSearch(entry, params.name, params.email, params.phone)) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Online move-in is not available. Please contact the facility directly.',
      );
    }
  }
}
