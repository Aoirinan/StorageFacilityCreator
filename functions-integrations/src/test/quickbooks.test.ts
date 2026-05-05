import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { quickBooksTestUtils } from '../accounting/quickbooks';

test('getApiBase selects sandbox and production hosts', () => {
  assert.equal(
    quickBooksTestUtils.getApiBase('sandbox'),
    'https://sandbox-quickbooks.api.intuit.com',
  );
  assert.equal(
    quickBooksTestUtils.getApiBase('production'),
    'https://quickbooks.api.intuit.com',
  );
});

test('oauth endpoints remain stable', () => {
  assert.equal(
    quickBooksTestUtils.getAuthorizeBase(),
    'https://appcenter.intuit.com/connect/oauth2',
  );
  assert.equal(
    quickBooksTestUtils.tokenEndpoint(),
    'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer',
  );
});

test('asNumber normalizes numeric input safely', () => {
  assert.equal(quickBooksTestUtils.asNumber(12.5), 12.5);
  assert.equal(quickBooksTestUtils.asNumber('33.21'), 33.21);
  assert.equal(quickBooksTestUtils.asNumber('abc'), 0);
  assert.equal(quickBooksTestUtils.asNumber(null), 0);
});

test('formatDate supports Timestamp, Date, and fallback', () => {
  const timestamp = admin.firestore.Timestamp.fromDate(new Date('2026-03-10T12:00:00.000Z'));
  assert.equal(quickBooksTestUtils.formatDate(timestamp), '2026-03-10');

  const fromDate = new Date('2026-02-01T12:00:00.000Z');
  assert.equal(quickBooksTestUtils.formatDate(fromDate), '2026-02-01');

  const fallback = quickBooksTestUtils.formatDate(undefined);
  assert.match(fallback, /^\d{4}-\d{2}-\d{2}$/);
});
