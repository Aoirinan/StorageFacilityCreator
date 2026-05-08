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

export function computeA2PStatus(
  currentStatus: A2PStatus,
  brandStatus?: string | null,
  campaignStatus?: string | null,
): A2PStatus {
  const brand = (brandStatus || '').toLowerCase();
  const campaign = (campaignStatus || '').toLowerCase();

  if (brand.includes('reject') || campaign.includes('reject') || brand.includes('denied') || campaign.includes('denied')) {
    return 'rejected';
  }
  if (campaign.includes('approv') || brand.includes('approv')) {
    return 'approved';
  }
  if (currentStatus === 'submitted' || brand.includes('submit') || campaign.includes('submit')) {
    return 'pending';
  }
  return currentStatus;
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
