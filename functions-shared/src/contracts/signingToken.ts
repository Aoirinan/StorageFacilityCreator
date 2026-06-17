import * as admin from 'firebase-admin';
import * as crypto from 'crypto';

/** Returns true when the signing token expiry timestamp is in the past or missing. */
export function isSigningTokenExpired(
  expiresAt: admin.firestore.Timestamp | undefined | null,
): boolean {
  if (!expiresAt || typeof expiresAt.toDate !== 'function') {
    return true;
  }
  return expiresAt.toDate() < new Date();
}

/** Rate limit signing-token attempts: max 25 calls per IP per minute. */
export async function checkSigningTokenRateLimit(ipKey: string): Promise<boolean> {
  const RATE_LIMIT_WINDOW_MS = 60 * 1000;
  const RATE_LIMIT_MAX = 25;
  const docId = `signingToken_${crypto.createHash('sha256').update(ipKey).digest('hex').substring(0, 24)}`;
  const ref = admin.firestore().collection('rateLimits').doc(docId);

  const now = Date.now();
  const doc = await ref.get();
  const data = doc.exists ? (doc.data() as Record<string, unknown>) : null;
  const windowStart = (data?.windowStart as number) ?? 0;

  if (now - windowStart >= RATE_LIMIT_WINDOW_MS) {
    await ref.set({ count: 1, windowStart: now });
    return true;
  }

  const count = ((data?.count as number) ?? 0) + 1;
  if (count > RATE_LIMIT_MAX) {
    return false;
  }

  await ref.update({ count: admin.firestore.FieldValue.increment(1) });
  return true;
}

/**
 * Validate a contract signing token for a specific facility/contract pair.
 * Token must match, contract status must be `sent`, and token must not be expired.
 */
export async function validateSigningTokenForContract(
  signingToken: string,
  facilityId: string,
  contractId: string,
): Promise<boolean> {
  const token = signingToken.trim();
  const fid = facilityId.trim();
  const cid = contractId.trim();
  if (!token || !fid || !cid) {
    return false;
  }

  const contractDoc = await admin
    .firestore()
    .collection('facilities')
    .doc(fid)
    .collection('contracts')
    .doc(cid)
    .get();

  if (!contractDoc.exists) {
    return false;
  }

  const d = contractDoc.data() as Record<string, unknown>;
  if (d.signingToken !== token || d.status !== 'sent') {
    return false;
  }

  if (isSigningTokenExpired(d.signingTokenExpiresAt as admin.firestore.Timestamp | undefined)) {
    return false;
  }

  return true;
}
