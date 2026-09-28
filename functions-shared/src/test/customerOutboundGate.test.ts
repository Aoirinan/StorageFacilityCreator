import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_OUTBOUND_GATE,
  decideCustomerRecipient,
  isCustomerRecipientAllowed,
  OutboundGateConfig,
  OutboundTarget,
  parseOutboundGateConfig,
} from '../email/customerOutboundGate';

const admins = new Set(['russell_forsyth_1992@outlook.com']);
const isAdmin = (e: string) => admins.has(e);

const KEEPSAKE = 'eXnWPuwuqzBVFcZWv1ZL';
const OTHER = 'facilityOther123';

const email = (facilityId: string | null | undefined): OutboundTarget => ({ facilityId, channel: 'email' });
const sms = (facilityId: string | null | undefined): OutboundTarget => ({ facilityId, channel: 'sms' });

function cfg(overrides: Partial<OutboundGateConfig> = {}): OutboundGateConfig {
  return { ...DEFAULT_OUTBOUND_GATE, ...overrides };
}

test('by default nothing reaches a customer', () => {
  assert.equal(DEFAULT_OUTBOUND_GATE.customerEmailsEnabled, false);
  assert.deepEqual(DEFAULT_OUTBOUND_GATE.blockedFacilityIds, []);
  assert.equal(isCustomerRecipientAllowed('tenant@example.com', email(OTHER), DEFAULT_OUTBOUND_GATE, isAdmin), false);
  assert.equal(isCustomerRecipientAllowed('+19035550000', sms(OTHER), DEFAULT_OUTBOUND_GATE, isAdmin), false);
  assert.equal(isCustomerRecipientAllowed('', email(OTHER), DEFAULT_OUTBOUND_GATE, isAdmin), false);
});

test('super admins always get through, regardless of case or spacing', () => {
  assert.equal(
    isCustomerRecipientAllowed('  Russell_Forsyth_1992@Outlook.com ', email(OTHER), DEFAULT_OUTBOUND_GATE, isAdmin),
    true,
  );
});

test('an allowlisted test recipient gets through, others do not', () => {
  const c = cfg({ allowedTestRecipients: ['Tester@Example.com', '+19035551234'] });
  assert.equal(isCustomerRecipientAllowed('tester@example.com', email(OTHER), c, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('+19035551234', sms(OTHER), c, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('someone@example.com', email(OTHER), c, isAdmin), false);
});

test('flipping the launch flag opens the gate for every facility not blocked', () => {
  const c = cfg({ customerEmailsEnabled: true });
  assert.equal(isCustomerRecipientAllowed('tenant@example.com', email(OTHER), c, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('+19035550000', sms(OTHER), c, isAdmin), true);
});

// The full matrix the owner asked for on 2026-09-27.
test('decision matrix: flag x blocked facility x recipient kind x channel', () => {
  const tester = '+19035551234';
  const admin = 'russell_forsyth_1992@outlook.com';
  const tenant = 'tenant@example.com';
  for (const channel of ['email', 'sms'] as const) {
    for (const flag of [true, false]) {
      const c = cfg({
        customerEmailsEnabled: flag,
        allowedTestRecipients: [tester],
        blockedFacilityIds: [KEEPSAKE],
      });
      const t = (f: string | null) => ({ facilityId: f, channel });
      const label = `${channel} flag=${flag}`;

      // Super admins and test recipients pass everywhere, even a blocked facility.
      for (const who of [tester, admin]) {
        for (const f of [KEEPSAKE, OTHER, null]) {
          const d = decideCustomerRecipient(who, t(f), c, isAdmin);
          assert.equal(d.allowed, true, `${label} ${who} ${f}`);
          assert.equal(d.reason, 'test_recipient');
        }
      }

      // A blocked facility never reaches a customer, whatever the flag says.
      assert.deepEqual(decideCustomerRecipient(tenant, t(KEEPSAKE), c, isAdmin), {
        allowed: false,
        reason: 'facility_blocked',
      });

      // Any other facility follows the flag.
      assert.deepEqual(
        decideCustomerRecipient(tenant, t(OTHER), c, isAdmin),
        flag ? { allowed: true, reason: 'open' } : { allowed: false, reason: 'launch_flag_off' },
        label,
      );

      // No facility id while a block list exists: fail closed.
      for (const f of [null, undefined, '', '   ']) {
        assert.deepEqual(
          decideCustomerRecipient(tenant, { facilityId: f, channel }, c, isAdmin),
          { allowed: false, reason: 'missing_facility' },
          `${label} facilityId=${JSON.stringify(f)}`,
        );
      }
    }
  }
});

test('with no block list, a send without a facility id follows the flag as before', () => {
  assert.equal(
    isCustomerRecipientAllowed('tenant@example.com', email(null), cfg({ customerEmailsEnabled: true }), isAdmin),
    true,
  );
  assert.equal(isCustomerRecipientAllowed('tenant@example.com', email(null), cfg(), isAdmin), false);
});

test('the block list matches whole ids only, trimmed', () => {
  const c = cfg({ customerEmailsEnabled: true, blockedFacilityIds: [KEEPSAKE] });
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(` ${KEEPSAKE} `), c, isAdmin), false);
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(KEEPSAKE.toLowerCase()), c, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(KEEPSAKE.slice(0, 10)), c, isAdmin), true);
});

test('config parsing defaults closed and ignores junk', () => {
  assert.deepEqual(parseOutboundGateConfig(undefined), DEFAULT_OUTBOUND_GATE);
  assert.deepEqual(
    parseOutboundGateConfig({
      customerEmailsEnabled: 'true',
      allowedTestRecipients: ['a@b.com', 5, null],
      blockedFacilityIds: [` ${KEEPSAKE} `, '', 7],
    }),
    { customerEmailsEnabled: false, allowedTestRecipients: ['a@b.com'], blockedFacilityIds: [KEEPSAKE] },
  );
  assert.deepEqual(
    parseOutboundGateConfig({ customerEmailsEnabled: true, blockedFacilityIds: [KEEPSAKE] }),
    { customerEmailsEnabled: true, allowedTestRecipients: [], blockedFacilityIds: [KEEPSAKE] },
  );
});
