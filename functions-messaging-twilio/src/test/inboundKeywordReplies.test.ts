import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildHelpReply,
  buildStartReply,
  helpFacilityIds,
  isStartRestorable,
  PLATFORM_SENDER_NAME,
  startRestorableMatches,
} from '../inboundKeywordReplies';
import { TenantPhoneMatch } from '../tenantPhoneLookup';

const oakvale = { name: 'Oakvale Storage', phone: '(806) 555-0142' };

function match(overrides: Partial<TenantPhoneMatch>): TenantPhoneMatch {
  return {
    facilityId: 'fA',
    id: 't1',
    phone: '903-555-0100',
    isActive: true,
    smsOptOut: true,
    smsConsentStatus: 'opted_out',
    smsConsentSource: 'inbound_stop',
    ...overrides,
  };
}

// N2: START must not create consent that was never given.
test('START restores only an active tenancy that this person opted out by STOP', () => {
  assert.equal(isStartRestorable(match({})), true);
  assert.equal(isStartRestorable(match({ smsOptOut: false, smsConsentStatus: 'opted_out' })), true);
  // No consent history at all.
  assert.equal(
    isStartRestorable(match({ smsOptOut: false, smsConsentStatus: null, smsConsentSource: null })),
    false,
  );
  // Opted out some other way (operator, form): START does not override it.
  assert.equal(isStartRestorable(match({ smsConsentSource: 'operator' })), false);
  assert.equal(isStartRestorable(match({ smsConsentSource: null })), false);
  // A former tenancy is never re-subscribed.
  assert.equal(isStartRestorable(match({ isActive: false })), false);
  // Already opted in: nothing to restore.
  assert.equal(
    isStartRestorable(match({ smsOptOut: false, smsConsentStatus: 'opted_in', smsConsentSource: 'inbound_start' })),
    false,
  );
});

test('START on the shared number restores only the restorable tenancies', () => {
  const matches = [
    match({ facilityId: 'fA', id: 't1' }),
    match({ facilityId: 'fB', id: 't2', smsOptOut: false, smsConsentStatus: null, smsConsentSource: null }),
    match({ facilityId: 'fC', id: 't3', isActive: false }),
  ];
  assert.deepEqual(startRestorableMatches(matches, null).map((m) => m.id), ['t1']);
  // On a facility's own line, only that facility.
  assert.deepEqual(startRestorableMatches(matches, 'fB').map((m) => m.id), []);
  assert.deepEqual(startRestorableMatches(matches, 'fA').map((m) => m.id), ['t1']);
  // Nothing restorable: the reply is the generic one and names no facility.
  assert.ok(buildStartReply([]).startsWith(`${PLATFORM_SENDER_NAME}:`));
});

// N4: HELP must not reveal tenancies.
test('HELP names only active tenancies, and only the texted facility on its own line', () => {
  const matches = [
    match({ facilityId: 'fA', id: 't1', isActive: true }),
    match({ facilityId: 'fB', id: 't2', isActive: false }),
    match({ facilityId: 'fC', id: 't3', isActive: true }),
    match({ facilityId: 'fA', id: 't4', isActive: true }),
  ];
  assert.deepEqual(helpFacilityIds(matches, null), ['fA', 'fC']);
  assert.deepEqual(helpFacilityIds(matches, 'fC'), ['fC']);
  // Texted a facility where the number is only a former tenant: generic help.
  assert.deepEqual(helpFacilityIds(matches, 'fB'), []);
  // Only former tenancies anywhere: generic help.
  assert.deepEqual(helpFacilityIds([match({ isActive: false })], null), []);
  assert.ok(buildHelpReply([]).startsWith(`${PLATFORM_SENDER_NAME}:`));
});

test('START from a tenant names the facility, in the wording filed with the campaign', () => {
  assert.equal(
    buildStartReply([oakvale]),
    "Oakvale Storage: you're opted in to account texts about your storage unit. " +
      'Msg frequency varies. Msg & data rates may apply. Reply HELP for help, STOP to opt out.',
  );
});

test('START from a number that matches no tenant gets a generic compliant reply', () => {
  const reply = buildStartReply([]);
  assert.ok(reply.startsWith(`${PLATFORM_SENDER_NAME}:`));
  assert.match(reply, /Msg & data rates may apply/);
  assert.match(reply, /STOP to opt out/);
  assert.match(reply, /HELP/);
});

test('one number at two facilities is told both names', () => {
  const reply = buildStartReply([oakvale, { name: 'Pinewood Self Storage', phone: null }]);
  assert.ok(reply.startsWith('Oakvale Storage, Pinewood Self Storage:'));
});

test('HELP names the facility and gives its phone', () => {
  const reply = buildHelpReply([oakvale]);
  assert.equal(
    reply,
    'Oakvale Storage: account texts about your storage unit. For help call (806) 555-0142. ' +
      'Msg & data rates may apply. Reply STOP to opt out.',
  );
});

test("HELP uses the facility's own wording when set, still under its name", () => {
  assert.equal(
    buildHelpReply([{ ...oakvale, helpMessage: 'Call us at 806-555-0142.' }]),
    'Oakvale Storage: Call us at 806-555-0142.',
  );
  assert.equal(
    buildHelpReply([{ ...oakvale, helpMessage: 'Oakvale Storage help: 806-555-0142.' }]),
    'Oakvale Storage help: 806-555-0142.',
  );
});

test('HELP without a facility phone, or from an unknown number, still answers', () => {
  assert.match(buildHelpReply([{ name: 'Oakvale Storage' }]), /contact your facility directly/);
  const unknown = buildHelpReply([]);
  assert.ok(unknown.startsWith(`${PLATFORM_SENDER_NAME}:`));
  assert.match(unknown, /STOP to opt out/);
});

test('HELP for a number at two facilities lists both phones', () => {
  const reply = buildHelpReply([oakvale, { name: 'Pinewood Self Storage', phone: '903-555-0177' }]);
  assert.match(reply, /Oakvale Storage \(806\) 555-0142 or Pinewood Self Storage 903-555-0177/);
});

test('replies fit in two SMS segments', () => {
  const long = { name: 'A Very Long Facility Name Self Storage And RV', phone: '(806) 555-0142' };
  assert.ok(buildStartReply([long]).length <= 306);
  assert.ok(buildHelpReply([long]).length <= 306);
});
