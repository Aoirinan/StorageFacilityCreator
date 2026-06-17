import * as admin from 'firebase-admin';

export const OTP_COOLDOWN_SECONDS = 45;

export function isValidOtpCodeFormat(code: string): boolean {
  return code.length === 6 && /^\d+$/.test(code);
}

export function getOtpCooldownRemainingSeconds(
  lastSentAt: admin.firestore.Timestamp | null | undefined,
  nowMs: number,
): number {
  if (!lastSentAt) {
    return 0;
  }
  const secondsSinceLastOtp = (nowMs - lastSentAt.toMillis()) / 1000;
  if (secondsSinceLastOtp >= OTP_COOLDOWN_SECONDS) {
    return 0;
  }
  return Math.ceil(OTP_COOLDOWN_SECONDS - secondsSinceLastOtp);
}
