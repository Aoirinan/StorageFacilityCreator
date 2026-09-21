import test from 'node:test';
import assert from 'node:assert/strict';
import { globalEntryMatchesStrict } from '../dnrScreening';

const ENTRY = {
  fullName: 'Jordan Fairweather',
  email: 'jordan.fairweather@example.com',
  phone: '+1 (903) 555-0142',
};

// --- the person the list exists to block is still blocked ---------------------

test('a full email match blocks the rental', () => {
  assert.equal(globalEntryMatchesStrict(ENTRY, '', 'JORDAN.FAIRWEATHER@example.com', ''), true);
});

test('a full phone match blocks the rental regardless of formatting', () => {
  assert.equal(globalEntryMatchesStrict(ENTRY, '', '', '9035550142'), true);
  assert.equal(globalEntryMatchesStrict(ENTRY, '', '', '+1-903-555-0142'), true);
});

test('a complete name match blocks the rental', () => {
  assert.equal(globalEntryMatchesStrict(ENTRY, '  Jordan   Fairweather ', '', ''), true);
});

// --- the endpoint must not be readable one character at a time ----------------

test('single-character and prefix name probes do not match', () => {
  // The old two-way substring rule matched any entry CONTAINING the probe, so a
  // caller could walk the alphabet and read names out of a platform-wide list of
  // named people. Each of these used to return true.
  for (const probe of ['a', 'jo', 'jord', 'Jordan', 'fair', 'Fairweather']) {
    assert.equal(
      globalEntryMatchesStrict(ENTRY, probe, '', ''),
      false,
      `name probe ${JSON.stringify(probe)} must not match`,
    );
  }
});

test('partial phone probes do not match', () => {
  // `endsWith` in both directions meant a single digit matched.
  for (const probe of ['2', '42', '0142', '5550142']) {
    assert.equal(
      globalEntryMatchesStrict(ENTRY, '', '', probe),
      false,
      `phone probe ${JSON.stringify(probe)} must not match`,
    );
  }
});

test('partial email probes do not match', () => {
  for (const probe of ['j', 'jordan', '@example.com', 'example.com']) {
    assert.equal(
      globalEntryMatchesStrict(ENTRY, '', probe, ''),
      false,
      `email probe ${JSON.stringify(probe)} must not match`,
    );
  }
});

test('an empty probe never matches an entry with empty fields', () => {
  const sparse = { fullName: '', email: '', phone: '' };
  assert.equal(globalEntryMatchesStrict(sparse, '', '', ''), false);
  assert.equal(globalEntryMatchesStrict(ENTRY, '', '', ''), false);
});

test('a different person does not match', () => {
  assert.equal(
    globalEntryMatchesStrict(ENTRY, 'Jordan Fairweathers', 'jordan@example.com', '9035550143'),
    false,
  );
});
