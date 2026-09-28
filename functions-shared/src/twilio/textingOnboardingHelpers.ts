/** SMS keyword normalization and Twilio A2P status helpers (shared by messaging + tests). */

export type A2PStatus = 'draft' | 'submitted' | 'pending' | 'approved' | 'rejected';

export function normalizeKeyword(input: string): string {
  return (input || '').trim().toUpperCase();
}

export function isStopKeyword(input: string): boolean {
  const keyword = normalizeKeyword(input);
  return ['STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT'].includes(keyword);
}

export function isStartKeyword(input: string): boolean {
  const keyword = normalizeKeyword(input);
  return ['START', 'YES', 'UNSTOP'].includes(keyword);
}

export function isHelpKeyword(input: string): boolean {
  const keyword = normalizeKeyword(input);
  return keyword === 'HELP' || keyword === 'INFO';
}

/**
 * Fold Twilio's brand and campaign states into the facility's A2P status.
 *
 * Twilio reports a brand as PENDING / IN_REVIEW / APPROVED / FAILED and a
 * campaign (`usAppToPerson.campaignStatus`) as PENDING / IN_PROGRESS /
 * VERIFIED / FAILED. Only a verified (or approved) *campaign* means the number
 * can send: an approved brand with its campaign still in review is pending, not
 * approved, because platform approval keys off `approved`.
 */
export function computeA2PStatus(
  currentStatus: A2PStatus,
  brandStatus?: string | null,
  campaignStatus?: string | null,
): A2PStatus {
  const brand = (brandStatus || '').toLowerCase();
  const campaign = (campaignStatus || '').toLowerCase();
  const failed = (s: string) =>
    s.includes('reject') || s.includes('denied') || s.includes('fail') || s.includes('suspend');

  if (failed(brand) || failed(campaign)) {
    return 'rejected';
  }
  if (campaign.includes('approv') || campaign.includes('verified')) {
    return 'approved';
  }
  // Nothing reported (no brand or campaign filed yet): leave the status alone.
  if (!brand && !campaign) return currentStatus;
  return 'pending';
}

export async function ensureIdempotentResource<T>(
  existingSid: string | null | undefined,
  createFn: () => Promise<T>,
  getSid: (resource: T) => string,
): Promise<{ sid: string; created: boolean; resource?: T }> {
  if (existingSid && existingSid.trim()) {
    return { sid: existingSid, created: false };
  }

  const resource = await createFn();
  const sid = getSid(resource);
  return { sid, created: true, resource };
}
