import test from 'node:test';
import assert from 'node:assert/strict';

import {
  expenseId,
  exportTokenHash,
  incomeIdAirbnb,
  incomeIdManual,
  isValidDocId,
  isValidExportToken,
  isValidRequestId,
  jobId,
  lockBucketId,
  newExportToken,
  normalizeAirbnbCode,
  notificationId,
  sha256Hex,
  stayIdForAirbnb,
  stayIdForFeed,
  stayIdManual,
  taskIdTurnover,
} from '../stays/ids';

const REQ = '0123456789abcdef0123456789abcdef';

test('the same inputs always give the same ids', () => {
  assert.equal(stayIdForFeed('lst_a', 'vrbo', 'uid-1@vrbo'), stayIdForFeed('lst_a', 'vrbo', 'uid-1@vrbo'));
  assert.equal(
    incomeIdAirbnb('fac1', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 0),
    incomeIdAirbnb('fac1', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 0),
  );
  assert.equal(sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('an Airbnb reservation is airbnb_{CODE}; other feed events are ical_{hash}', () => {
  assert.equal(stayIdForAirbnb('hmabc12345'), 'airbnb_HMABC12345');
  assert.equal(stayIdForAirbnb(' HMABC12345 '), 'airbnb_HMABC12345');
  const feed = stayIdForFeed('lst_a', 'vrbo', 'uid-1');
  assert.match(feed, /^ical_[a-f0-9]{40}$/);
  assert.notEqual(feed.slice(5), 'HMABC12345');
  assert.throws(() => stayIdForAirbnb('not a code!'));
  assert.equal(normalizeAirbnbCode('HM1'), null);
});

test('a feed id does not depend on the channel, so re-adding a feed finds the same stays', () => {
  // The signature has no channel id at all; the provider and listing do matter.
  assert.notEqual(stayIdForFeed('lst_a', 'vrbo', 'u'), stayIdForFeed('lst_b', 'vrbo', 'u'));
  assert.notEqual(stayIdForFeed('lst_a', 'vrbo', 'u'), stayIdForFeed('lst_a', 'booking', 'u'));
});

test('manual ids come from the requestId and refuse anything else', () => {
  assert.equal(stayIdManual(REQ), `man_${REQ}`);
  assert.equal(incomeIdManual(REQ), `man_${REQ}`);
  assert.equal(expenseId(REQ), `exp_${REQ}`);
  assert.throws(() => stayIdManual('ABC'));
  assert.throws(() => stayIdManual(REQ.toUpperCase()));
  assert.equal(isValidRequestId(REQ), true);
  assert.equal(isValidRequestId(`${REQ}0`), false);
  assert.equal(isValidRequestId(123), false);
});

test('the Airbnb CSV id is stable when a listing is renamed', () => {
  // The listing title is not an input; only the code, type, date, amount and occurrence are.
  const first = incomeIdAirbnb('fac1', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 0);
  const again = incomeIdAirbnb('fac1', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 0);
  assert.equal(first, again);
  assert.match(first, /^abnb_[a-f0-9]{40}$/);
  // Two identical rows in one file differ only by occurrence.
  assert.notEqual(first, incomeIdAirbnb('fac1', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 1));
  // Another facility never collides.
  assert.notEqual(first, incomeIdAirbnb('fac2', 'HMABC12345', 'Reservation', '2026-10-03', 45000, 0));
  assert.throws(() => incomeIdAirbnb('fac1', 'X', 'Payout', '2026-10-03', 12.5, 0));
});

test('bucket, task, job and notification ids', () => {
  assert.equal(lockBucketId('lst_a', '2026-10'), 'lst_a_2026-10');
  assert.equal(taskIdTurnover('airbnb_HMABC12345'), 'turnover_airbnb_HMABC12345');
  assert.equal(jobId('2026-10-03T14:30', 'fac1'), '2026-10-03T14:30_fac1');
  assert.equal(
    notificationId({ kind: 'stay', type: 'STAY_BOOKING_IMPORTED', stayId: 'airbnb_HM1234567', version: 3 }),
    'stay_booking_imported_airbnb_HM1234567_3',
  );
  assert.equal(notificationId({ kind: 'brief', ymd: '2026-10-03' }), 'stay_brief_2026-10-03');
  assert.equal(notificationId({ kind: 'turnover_done', taskId: 't1' }), 'stay_turnover_done_t1');
  assert.equal(notificationId({ kind: 'unassigned', taskId: 't1', dueDate: '2026-10-03' }), 'stay_unassigned_t1_2026-10-03');
  assert.equal(
    notificationId({ kind: 'feed', channelId: 'ch1', status: 'gone', ymd: '2026-10-03' }),
    'stay_feed_ch1_gone_2026-10-03',
  );
  // The conflict id does not depend on the order the other stays are listed in.
  assert.equal(
    notificationId({ kind: 'conflict', stayId: 's1', conflictStayIds: ['b', 'a'] }),
    notificationId({ kind: 'conflict', stayId: 's1', conflictStayIds: ['a', 'b'] }),
  );
  // A changed issue note is a new notification; the same note is not.
  assert.notEqual(
    notificationId({ kind: 'turnover_issue', taskId: 't1', note: 'Broken lamp' }),
    notificationId({ kind: 'turnover_issue', taskId: 't1', note: 'Broken lamp and window' }),
  );
});

test('export tokens are 48 hex and looked up only by their hash', () => {
  const token = newExportToken();
  assert.equal(isValidExportToken(token), true);
  assert.notEqual(newExportToken(), token);
  assert.equal(exportTokenHash(token), sha256Hex(token));
  assert.equal(isValidExportToken('0'.repeat(47)), false);
});

test('doc ids refuse slashes and reserved names', () => {
  assert.equal(isValidDocId('lst_abc'), true);
  assert.equal(isValidDocId('a/b'), false);
  assert.equal(isValidDocId(''), false);
  assert.equal(isValidDocId('..'), false);
  assert.equal(isValidDocId('__name__'), false);
  assert.equal(isValidDocId('x'.repeat(129)), false);
});
