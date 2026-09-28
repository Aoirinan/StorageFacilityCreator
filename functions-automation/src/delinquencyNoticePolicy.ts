/**
 * When the daily delinquency job may email a tenant a past-due notice.
 *
 * Kept free of the Admin SDK so the rules can be tested directly.
 *
 * Three things were wrong before customer contact opened:
 *
 * * Notices went out unless the operator had switched them OFF
 *   (`enableAutoNotices !== false`), so every facility that never opened the
 *   Delinquency Rules screen emailed tenants. They are now off unless the
 *   operator switched them on, and the app shows the same default.
 * * The Notification Settings screen's "Delinquency notifications" switch and
 *   channel were never read. Switched off, or set to SMS only, the job still
 *   emailed.
 * * The only dedupe was "not already sent today", so a tenant 14 days late got
 *   the same final notice every morning until they paid. Now a tenant gets
 *   each stage once per delinquency episode.
 */

export type DelinquencyNoticeStage = 'late' | 'final';

export interface DelinquencyNoticeSettings {
  /** Whether the job may send tenant notices at all. */
  enabled: boolean;
  /** Whether the notice goes by email (the only channel this job sends). */
  email: boolean;
}

/** Minimum gap before a new episode's first notice repeats a stage. */
export const NOTICE_REPEAT_MIN_DAYS = 7;

const DAY_MS = 24 * 60 * 60 * 1000;

export function readDelinquencyNoticeSettings(
  billingSettings: Record<string, unknown> | null | undefined,
): DelinquencyNoticeSettings {
  const b = billingSettings ?? {};
  // Delinquency Rules screen: "Automatically Send Notices". Off when unset.
  const autoNotices = b.enableAutoNotices === true;
  // Notification Settings screen: "Enable Delinquency Notifications", shown on
  // when unset. An explicit false vetoes.
  const notificationsOn = b.enableDelinquencyNotifications !== false;
  // Same screen: channel, shown as email when unset.
  const channel = String(b.delinquencyChannel ?? 'email').toLowerCase();
  const email = channel === 'email' || channel === 'both';
  return { enabled: autoNotices && notificationsOn, email };
}

/** The notice stage for [daysLate], or null when no notice is due yet. */
export function noticeStageFor(
  daysLate: number,
  rules: { noticeDays: number; finalNoticeDays: number },
): DelinquencyNoticeStage | null {
  if (daysLate >= rules.finalNoticeDays) return 'final';
  if (daysLate >= rules.noticeDays) return 'late';
  return null;
}

/**
 * One delinquency episode runs from the last paid-through date: a payment that
 * moves paidThrough starts a new one, so a tenant who pays and falls behind
 * again is told again.
 */
export function delinquencyEpisodeKey(paidThrough: Date | null | undefined): string {
  if (!(paidThrough instanceof Date) || Number.isNaN(paidThrough.getTime())) return 'never-paid';
  return paidThrough.toISOString().slice(0, 10);
}

function rank(stage: string | null | undefined): number {
  if (stage === 'final') return 2;
  if (stage === 'late') return 1;
  return 0;
}

export interface LastDelinquencyNotice {
  stage?: string | null;
  episode?: string | null;
  at?: Date | null;
}

/**
 * Whether to send [stage] now. Each stage goes out once per episode, and an
 * escalation (late to final) goes out when it is reached. A new episode may
 * repeat a stage, but not within NOTICE_REPEAT_MIN_DAYS of the last notice.
 */
export function shouldSendDelinquencyNotice(params: {
  stage: DelinquencyNoticeStage | null;
  episode: string;
  last: LastDelinquencyNotice | null;
  now: Date;
}): boolean {
  const { stage, episode, last, now } = params;
  if (!stage) return false;
  if (!last || !last.stage) return true;
  if (last.episode === episode) {
    return rank(stage) > rank(last.stage);
  }
  const lastAt = last.at instanceof Date ? last.at.getTime() : null;
  return lastAt == null || now.getTime() - lastAt >= NOTICE_REPEAT_MIN_DAYS * DAY_MS;
}

/** Only tenants still in the unit: active, and no move-out recorded. */
export function isDelinquencyEligibleTenant(data: Record<string, unknown>): boolean {
  if (data.isActive !== true) return false;
  if (data.moveOutDate) return false;
  return true;
}
