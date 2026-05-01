import * as crypto from 'crypto';

export function getEmailUnsubscribeSecretKey(sendGridApiKey: string): string {
  return crypto.createHash('sha256').update(`sfc-email-unsub-v1|${sendGridApiKey}`).digest('hex');
}

export function buildEmailUnsubscribeToken(
  sendGridApiKey: string,
  facilityId: string,
  emailLower: string,
  tenantId: string,
): string {
  const exp = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
  const payload = `${facilityId}|${emailLower}|${tenantId}|${exp}`;
  const key = getEmailUnsubscribeSecretKey(sendGridApiKey);
  const sig = crypto.createHmac('sha256', key).update(payload).digest('hex');
  return Buffer.from(`${payload}|${sig}`).toString('base64url');
}

export function parseEmailUnsubscribeToken(
  sendGridApiKey: string,
  token: string,
): { facilityId: string; emailLower: string; tenantId: string; exp: number } | null {
  try {
    const raw = Buffer.from(String(token).trim(), 'base64url').toString('utf8');
    const idx = raw.lastIndexOf('|');
    if (idx === -1) return null;
    const sig = raw.slice(idx + 1);
    const payload = raw.slice(0, idx);
    const parts = payload.split('|');
    if (parts.length !== 4) return null;
    const [facilityId, emailLower, tenantId, expStr] = parts;
    const exp = parseInt(expStr, 10);
    if (!Number.isFinite(exp) || Date.now() / 1000 > exp) return null;
    const key = getEmailUnsubscribeSecretKey(sendGridApiKey);
    const expected = crypto.createHmac('sha256', key).update(payload).digest('hex');
    const a = Buffer.from(sig, 'utf8');
    const b = Buffer.from(expected, 'utf8');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    return { facilityId, emailLower, tenantId, exp };
  } catch {
    return null;
  }
}
