import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_OUTBOUND_GATE,
  isCustomerRecipientAllowed,
} from '../email/customerOutboundGate';

const admins = new Set(['russell_forsyth_1992@outlook.com']);
const isAdmin = (e: string) => admins.has(e);

test('by default nothing reaches a customer', () => {
  assert.equal(DEFAULT_OUTBOUND_GATE.customerEmailsEnabled, false);
  assert.equal(isCustomerRecipientAllowed('tenant@example.com', DEFAULT_OUTBOUND_GATE, isAdmin), false);
  assert.equal(isCustomerRecipientAllowed('', DEFAULT_OUTBOUND_GATE, isAdmin), false);
});

test('super admins always get through, regardless of case or spacing', () => {
  assert.equal(isCustomerRecipientAllowed('  Russell_Forsyth_1992@Outlook.com ', DEFAULT_OUTBOUND_GATE, isAdmin), true);
});

test('an allowlisted test recipient gets through, others do not', () => {
  const cfg = { customerEmailsEnabled: false, allowedTestRecipients: ['Tester@Example.com', '+19035551234'] };
  assert.equal(isCustomerRecipientAllowed('tester@example.com', cfg, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('+19035551234', cfg, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('someone@example.com', cfg, isAdmin), false);
});

test('flipping the launch flag opens the gate for everyone', () => {
  const cfg = { customerEmailsEnabled: true, allowedTestRecipients: [] };
  assert.equal(isCustomerRecipientAllowed('tenant@example.com', cfg, isAdmin), true);
});
