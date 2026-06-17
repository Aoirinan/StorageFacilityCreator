import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import {
  getOtpCooldownRemainingSeconds,
  isValidOtpCodeFormat,
  OTP_COOLDOWN_SECONDS,
} from '../otpHelpers';
import { appendPlatformSecurityEmailFooter } from '../emailOtpFooter';

test('isValidOtpCodeFormat accepts 6-digit codes only', () => {
  assert.equal(isValidOtpCodeFormat('123456'), true);
  assert.equal(isValidOtpCodeFormat('12345'), false);
  assert.equal(isValidOtpCodeFormat('abcdef'), false);
  assert.equal(isValidOtpCodeFormat(''), false);
});

test('getOtpCooldownRemainingSeconds returns 0 when no prior send', () => {
  assert.equal(getOtpCooldownRemainingSeconds(null, Date.now()), 0);
  assert.equal(getOtpCooldownRemainingSeconds(undefined, Date.now()), 0);
});

test('getOtpCooldownRemainingSeconds enforces 45s cooldown', () => {
  const nowMs = Date.UTC(2026, 5, 15, 12, 0, 0);
  const lastSent = admin.firestore.Timestamp.fromMillis(nowMs - 44_000);
  assert.equal(getOtpCooldownRemainingSeconds(lastSent, nowMs), 1);

  const expired = admin.firestore.Timestamp.fromMillis(
    nowMs - OTP_COOLDOWN_SECONDS * 1000,
  );
  assert.equal(getOtpCooldownRemainingSeconds(expired, nowMs), 0);
});

test('appendPlatformSecurityEmailFooter adds non-promotional disclaimer', () => {
  const { html, text } = appendPlatformSecurityEmailFooter('<p>Code</p>', 'Code');
  assert.match(html, /automated security message/i);
  assert.match(text, /not promotional/i);
  assert.doesNotMatch(html, /List-Unsubscribe/i);
});
