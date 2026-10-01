import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_OUTBOUND_GATE,
  decideCustomerRecipient,
  isCustomerRecipientAllowed,
  OutboundGateConfig,
  OutboundTarget,
  parseOutboundGateConfig,
  parseOutboundGateConfigWithProblems,
} from '../email/customerOutboundGate';

const admins = new Set(['russell_forsyth_1992@outlook.com']);
const isAdmin = (e: string) => admins.has(e);

const PINEWOOD = 'kT4mZ8vLr2QpWx7NbY3d';
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
        blockedFacilityIds: [PINEWOOD],
      });
      const t = (f: string | null) => ({ facilityId: f, channel });
      const label = `${channel} flag=${flag}`;

      // Super admins and test recipients pass everywhere, even a blocked facility.
      for (const who of [tester, admin]) {
        for (const f of [PINEWOOD, OTHER, null]) {
          const d = decideCustomerRecipient(who, t(f), c, isAdmin);
          assert.equal(d.allowed, true, `${label} ${who} ${f}`);
          assert.equal(d.reason, 'test_recipient');
        }
      }

      // A blocked facility never reaches a customer, whatever the flag says.
      assert.deepEqual(decideCustomerRecipient(tenant, t(PINEWOOD), c, isAdmin), {
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
  const c = cfg({ customerEmailsEnabled: true, blockedFacilityIds: [PINEWOOD] });
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(` ${PINEWOOD} `), c, isAdmin), false);
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(PINEWOOD.toLowerCase()), c, isAdmin), true);
  assert.equal(isCustomerRecipientAllowed('t@example.com', email(PINEWOOD.slice(0, 10)), c, isAdmin), true);
});

test('config parsing defaults closed and ignores junk in the allowlist', () => {
  assert.deepEqual(parseOutboundGateConfig(undefined), DEFAULT_OUTBOUND_GATE);
  assert.deepEqual(
    parseOutboundGateConfig({
      customerEmailsEnabled: 'true',
      allowedTestRecipients: ['a@b.com', 5, null],
      blockedFacilityIds: [` ${PINEWOOD} `],
    }),
    { customerEmailsEnabled: false, allowedTestRecipients: ['a@b.com'], blockedFacilityIds: [PINEWOOD] },
  );
  assert.deepEqual(
    parseOutboundGateConfig({ customerEmailsEnabled: true, blockedFacilityIds: [PINEWOOD] }),
    { customerEmailsEnabled: true, allowedTestRecipients: [], blockedFacilityIds: [PINEWOOD] },
  );
  // Absent means nothing is blocked; an empty list says the same.
  for (const data of [{ customerEmailsEnabled: true }, { customerEmailsEnabled: true, blockedFacilityIds: [] }]) {
    const parsed = parseOutboundGateConfigWithProblems(data);
    assert.deepEqual(parsed.problems, []);
    assert.equal(parsed.config.customerEmailsEnabled, true);
  }
});

// A damaged block list must close the gate, not quietly unblock Pinewood.
test('a malformed blockedFacilityIds turns customer contact off for everyone', () => {
  const malformed: unknown[] = [
    PINEWOOD, // a string, not a list
    null,
    {},
    5,
    [PINEWOOD, 7],
    [PINEWOOD, ''],
    [PINEWOOD, '   '],
    [PINEWOOD, null],
  ];
  for (const blockedFacilityIds of malformed) {
    const label = JSON.stringify(blockedFacilityIds);
    const parsed = parseOutboundGateConfigWithProblems({
      customerEmailsEnabled: true,
      allowedTestRecipients: ['+19035551234'],
      blockedFacilityIds,
    });
    assert.equal(parsed.problems.length, 1, label);
    assert.equal(parsed.config.customerEmailsEnabled, false, label);
    for (const f of [PINEWOOD, OTHER]) {
      assert.equal(isCustomerRecipientAllowed('tenant@example.com', email(f), parsed.config, isAdmin), false, label);
      assert.equal(isCustomerRecipientAllowed('+19035550000', sms(f), parsed.config, isAdmin), false, label);
    }
    // The team can still test end to end.
    assert.equal(isCustomerRecipientAllowed('+19035551234', sms(OTHER), parsed.config, isAdmin), true, label);
    // Whatever valid ids were readable stay blocked.
    if (Array.isArray(blockedFacilityIds)) assert.ok(parsed.config.blockedFacilityIds.includes(PINEWOOD), label);
  }
});
