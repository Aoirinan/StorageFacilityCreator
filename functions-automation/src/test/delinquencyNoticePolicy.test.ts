import assert from 'node:assert/strict';
import test from 'node:test';
import {
  delinquencyEpisodeKey,
  isDelinquencyEligibleTenant,
  noticeStageFor,
  readDelinquencyNoticeSettings,
  shouldSendDelinquencyNotice,
} from '../delinquencyNoticePolicy';

const rules = { noticeDays: 7, finalNoticeDays: 14 };
const DAY = 24 * 60 * 60 * 1000;
const now = new Date('2026-10-20T03:00:00Z');

test('notices are off for a facility that never switched them on', () => {
  assert.deepEqual(readDelinquencyNoticeSettings({}), { enabled: false, email: true });
  assert.deepEqual(readDelinquencyNoticeSettings(undefined), { enabled: false, email: true });
  assert.equal(readDelinquencyNoticeSettings({ enableAutoNotices: false }).enabled, false);
  assert.equal(readDelinquencyNoticeSettings({ enableAutoNotices: 'true' }).enabled, false);
});

test('switched on, notices go by email unless the operator said otherwise', () => {
  assert.deepEqual(readDelinquencyNoticeSettings({ enableAutoNotices: true }), { enabled: true, email: true });
  assert.equal(readDelinquencyNoticeSettings({ enableAutoNotices: true, delinquencyChannel: 'both' }).email, true);
});

test('the Notification Settings switch and channel are honoured', () => {
  assert.equal(
    readDelinquencyNoticeSettings({ enableAutoNotices: true, enableDelinquencyNotifications: false }).enabled,
    false,
  );
  assert.equal(readDelinquencyNoticeSettings({ enableAutoNotices: true, delinquencyChannel: 'sms' }).email, false);
});

test('stages follow the configured day counts', () => {
  assert.equal(noticeStageFor(6, rules), null);
  assert.equal(noticeStageFor(7, rules), 'late');
  assert.equal(noticeStageFor(13, rules), 'late');
  assert.equal(noticeStageFor(14, rules), 'final');
  assert.equal(noticeStageFor(90, rules), 'final');
});

// The old dedupe was "not already sent today": a tenant 14+ days late got the
// same final notice every morning until they paid.
test('each stage goes out once per episode, not every day', () => {
  const episode = '2026-09-30';
  assert.equal(shouldSendDelinquencyNotice({ stage: 'late', episode, last: null, now }), true);
  const afterLate = { stage: 'late', episode, at: new Date(now.getTime() - DAY) };
  assert.equal(shouldSendDelinquencyNotice({ stage: 'late', episode, last: afterLate, now }), false);
  // Weeks later, same episode, same stage: still no repeat.
  const longAgo = { stage: 'late', episode, at: new Date(now.getTime() - 30 * DAY) };
  assert.equal(shouldSendDelinquencyNotice({ stage: 'late', episode, last: longAgo, now }), false);
  // Escalation goes out when reached.
  assert.equal(shouldSendDelinquencyNotice({ stage: 'final', episode, last: afterLate, now }), true);
  const afterFinal = { stage: 'final', episode, at: new Date(now.getTime() - DAY) };
  assert.equal(shouldSendDelinquencyNotice({ stage: 'final', episode, last: afterFinal, now }), false);
});

test('a new episode (paidThrough moved) may notify again, but not within 7 days', () => {
  const last = { stage: 'final', episode: '2026-08-31', at: new Date(now.getTime() - 3 * DAY) };
  assert.equal(shouldSendDelinquencyNotice({ stage: 'late', episode: '2026-09-30', last, now }), false);
  const older = { ...last, at: new Date(now.getTime() - 7 * DAY) };
  assert.equal(shouldSendDelinquencyNotice({ stage: 'late', episode: '2026-09-30', last: older, now }), true);
});

test('no stage, no notice', () => {
  assert.equal(shouldSendDelinquencyNotice({ stage: null, episode: 'x', last: null, now }), false);
});

test('episode keys', () => {
  assert.equal(delinquencyEpisodeKey(null), 'never-paid');
  assert.equal(delinquencyEpisodeKey(new Date('invalid')), 'never-paid');
  assert.equal(delinquencyEpisodeKey(new Date('2026-09-30T05:00:00Z')), '2026-09-30');
});

// The job built this filter and then looped over the unfiltered snapshot.
test('moved-out and inactive tenants are not processed', () => {
  assert.equal(isDelinquencyEligibleTenant({ isActive: true }), true);
  assert.equal(isDelinquencyEligibleTenant({ isActive: true, moveOutDate: new Date() }), false);
  assert.equal(isDelinquencyEligibleTenant({ isActive: false }), false);
  assert.equal(isDelinquencyEligibleTenant({}), false);
});
