import * as admin from 'firebase-admin';

/** Returns true when the signing token expiry timestamp is in the past. */
export function isSigningTokenExpired(
  expiresAt: admin.firestore.Timestamp | undefined | null,
): boolean {
  if (!expiresAt || typeof expiresAt.toDate !== 'function') {
    return false;
  }
  return expiresAt.toDate() < new Date();
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
