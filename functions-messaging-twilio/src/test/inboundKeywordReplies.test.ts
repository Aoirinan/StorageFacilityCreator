import assert from 'node:assert/strict';
import test from 'node:test';
import { buildHelpReply, buildStartReply, PLATFORM_SENDER_NAME } from '../inboundKeywordReplies';

const caprock = { name: 'Caprock Storage', phone: '(806) 555-0142' };

test('START from a tenant names the facility, in the wording filed with the campaign', () => {
  assert.equal(
    buildStartReply([caprock]),
    "Caprock Storage: you're opted in to account texts about your storage unit. " +
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
  const reply = buildStartReply([caprock, { name: 'Keepsake Self Storage', phone: null }]);
  assert.ok(reply.startsWith('Caprock Storage, Keepsake Self Storage:'));
});

test('HELP names the facility and gives its phone', () => {
  const reply = buildHelpReply([caprock]);
  assert.equal(
    reply,
    'Caprock Storage: account texts about your storage unit. For help call (806) 555-0142. ' +
      'Msg & data rates may apply. Reply STOP to opt out.',
  );
});

test("HELP uses the facility's own wording when set, still under its name", () => {
  assert.equal(
    buildHelpReply([{ ...caprock, helpMessage: 'Call us at 806-555-0142.' }]),
    'Caprock Storage: Call us at 806-555-0142.',
  );
  assert.equal(
    buildHelpReply([{ ...caprock, helpMessage: 'Caprock Storage help: 806-555-0142.' }]),
    'Caprock Storage help: 806-555-0142.',
  );
});

test('HELP without a facility phone, or from an unknown number, still answers', () => {
  assert.match(buildHelpReply([{ name: 'Caprock Storage' }]), /contact your facility directly/);
  const unknown = buildHelpReply([]);
  assert.ok(unknown.startsWith(`${PLATFORM_SENDER_NAME}:`));
  assert.match(unknown, /STOP to opt out/);
});

test('HELP for a number at two facilities lists both phones', () => {
  const reply = buildHelpReply([caprock, { name: 'Keepsake Self Storage', phone: '903-555-0177' }]);
  assert.match(reply, /Caprock Storage \(806\) 555-0142 or Keepsake Self Storage 903-555-0177/);
});

test('replies fit in two SMS segments', () => {
  const long = { name: 'A Very Long Facility Name Self Storage And RV', phone: '(806) 555-0142' };
  assert.ok(buildStartReply([long]).length <= 306);
  assert.ok(buildHelpReply([long]).length <= 306);
});
