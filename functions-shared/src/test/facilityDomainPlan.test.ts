import test from 'node:test';
import assert from 'node:assert/strict';
import {
  combineHostnameStatuses,
  isDomainLive,
  isValidDomain,
  mergeDomainRecords,
  normalizeDomainInput,
  planDomainPair,
} from '../hosting/facilityDomainPlan';

// --- normalizing what an operator types --------------------------------------

test('normalizeDomainInput strips whatever the operator pasted', () => {
  assert.equal(normalizeDomainInput('https://www.Example.com/rent?a=1'), 'www.example.com');
  assert.equal(normalizeDomainInput('  EXAMPLE.COM.  '), 'example.com');
  assert.equal(normalizeDomainInput('example.com:443'), 'example.com');
  assert.equal(normalizeDomainInput('http://example.com#top'), 'example.com');
  assert.equal(normalizeDomainInput(undefined), '');
});

test('isValidDomain rejects things that cannot be registered', () => {
  assert.equal(isValidDomain('example.com'), true);
  assert.equal(isValidDomain('rent.example.co.uk'), true);
  assert.equal(isValidDomain('localhost'), false, 'single label');
  assert.equal(isValidDomain('*.example.com'), false, 'wildcard');
  assert.equal(isValidDomain('under_score.com'), false);
  assert.equal(isValidDomain('-bad.com'), false);
  assert.equal(isValidDomain('bad-.com'), false);
  assert.equal(isValidDomain(''), false);
});

// --- apex / www planning -----------------------------------------------------

test('planDomainPair registers both apex and www for an apex domain', () => {
  assert.deepEqual(planDomainPair('keepsakeselfstorage.com'), {
    apex: 'keepsakeselfstorage.com',
    www: 'www.keepsakeselfstorage.com',
  });
});

test('planDomainPair treats a www input as naming the apex', () => {
  // Operators type their site the way they say it out loud.
  assert.deepEqual(planDomainPair('https://www.keepsakeselfstorage.com'), {
    apex: 'keepsakeselfstorage.com',
    www: 'www.keepsakeselfstorage.com',
  });
});

test('planDomainPair does not invent www for an existing subdomain', () => {
  // www.rent.example.com is not a hostname anyone will type, and each extra
  // hostname eats into the 20-subdomains-per-apex certificate limit.
  assert.deepEqual(planDomainPair('rent.example.com'), {
    apex: 'rent.example.com',
    www: null,
  });
});

test('planDomainPair rejects unusable input', () => {
  for (const bad of ['', 'localhost', '*.example.com', 'not a domain', undefined]) {
    assert.equal(planDomainPair(bad), null, JSON.stringify(bad));
  }
});

// --- record merging ----------------------------------------------------------

test('mergeDomainRecords removes rows duplicated across hostnames', () => {
  // Registering apex and www each return the apex A record; showing it twice
  // invites the operator to create a duplicate.
  const merged = mergeDomainRecords([
    [
      { type: 'A', name: 'example.com', value: '199.36.158.100' },
      { type: 'TXT', name: 'example.com', value: 'hosting-site=sfc', requiredAction: 'ADD' },
    ],
    [
      { type: 'A', name: 'example.com', value: '199.36.158.100' },
      { type: 'CNAME', name: 'www.example.com', value: 'sfc.web.app', requiredAction: 'ADD' },
    ],
  ]);
  assert.equal(merged.length, 3);
  assert.equal(merged.filter((r) => r.type === 'A').length, 1);
});

test('mergeDomainRecords puts the rows needing action first', () => {
  const merged = mergeDomainRecords([
    [
      { type: 'A', name: 'example.com', value: '1.2.3.4' },
      { type: 'TXT', name: 'example.com', value: 'hosting-site=sfc', requiredAction: 'ADD' },
    ],
  ]);
  assert.equal(merged[0].requiredAction, 'ADD');
});

test('mergeDomainRecords drops malformed rows', () => {
  const merged = mergeDomainRecords([
    [
      { type: '', name: 'example.com', value: 'x' },
      { type: 'A', name: '', value: 'x' },
      { type: 'A', name: 'example.com', value: '' },
      { type: 'A', name: 'example.com', value: '1.2.3.4' },
    ],
  ]);
  assert.deepEqual(merged, [{ type: 'A', name: 'example.com', value: '1.2.3.4' }]);
});

// --- combined status ---------------------------------------------------------

test('combineHostnameStatuses reports the worst hostname, not the best', () => {
  // Saying "live" while www serves a cert error is how you get a ticket that
  // says "you told me it was done".
  assert.equal(
    combineHostnameStatuses([
      { hostname: 'example.com', status: 'connected' },
      { hostname: 'www.example.com', status: 'pending_dns' },
    ]),
    'pending_dns',
  );
});

test('combineHostnameStatuses reports connected only when all are', () => {
  assert.equal(
    combineHostnameStatuses([
      { hostname: 'example.com', status: 'connected' },
      { hostname: 'www.example.com', status: 'connected' },
    ]),
    'connected',
  );
});

test('combineHostnameStatuses surfaces an unrecognised status rather than hiding it', () => {
  assert.equal(
    combineHostnameStatuses([
      { hostname: 'example.com', status: 'connected' },
      { hostname: 'www.example.com', status: 'something_new' },
    ]),
    'something_new',
  );
});

test('combineHostnameStatuses handles empty and all-unknown input', () => {
  assert.equal(combineHostnameStatuses([]), 'unknown');
  assert.equal(
    combineHostnameStatuses([{ hostname: 'a.com', status: 'unknown' }]),
    'unknown',
  );
});

test('isDomainLive requires every hostname to be serving', () => {
  assert.equal(
    isDomainLive([
      { hostname: 'example.com', status: 'connected' },
      { hostname: 'www.example.com', status: 'connected' },
    ]),
    true,
  );
  assert.equal(
    isDomainLive([
      { hostname: 'example.com', status: 'connected' },
      { hostname: 'www.example.com', status: 'provisioning_ssl' },
    ]),
    false,
  );
  assert.equal(isDomainLive([]), false);
});
