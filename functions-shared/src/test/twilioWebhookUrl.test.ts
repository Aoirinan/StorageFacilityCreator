import test from 'node:test';
import assert from 'node:assert/strict';
import { twilioWebhookUrl } from '../twilio/webhooks';

function fakeReq(opts: { host: string; originalUrl: string; proto?: string }) {
  const headers: Record<string, string> = { host: opts.host };
  if (opts.proto) headers['x-forwarded-proto'] = opts.proto;
  return {
    headers,
    originalUrl: opts.originalUrl,
    url: opts.originalUrl,
    get: (name: string) => headers[name.toLowerCase()],
  } as unknown as Parameters<typeof twilioWebhookUrl>[0];
}

function withEnv(vars: Record<string, string | undefined>, fn: () => void) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(vars)) {
    saved[k] = process.env[k];
    if (vars[k] === undefined) delete process.env[k];
    else process.env[k] = vars[k];
  }
  try {
    fn();
  } finally {
    for (const k of Object.keys(vars)) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

test('1st-gen Cloud Functions: bare "/" path gets the function name back', () => {
  withEnv({ FUNCTION_TARGET: 'handleIncomingSMS', K_SERVICE: undefined, FUNCTIONS_EMULATOR: undefined }, () => {
    const req = fakeReq({ host: 'us-central1-storage-facility-creator.cloudfunctions.net', originalUrl: '/' });
    assert.equal(
      twilioWebhookUrl(req),
      'https://us-central1-storage-facility-creator.cloudfunctions.net/handleIncomingSMS',
    );
  });
});

test('a query string on the bare path is kept after the function name', () => {
  withEnv({ FUNCTION_TARGET: 'handleSfcLeadCall', FUNCTIONS_EMULATOR: undefined }, () => {
    const req = fakeReq({ host: 'us-central1-storage-facility-creator.cloudfunctions.net', originalUrl: '/?x=1' });
    assert.equal(
      twilioWebhookUrl(req),
      'https://us-central1-storage-facility-creator.cloudfunctions.net/handleSfcLeadCall?x=1',
    );
  });
});

test('a path that already carries the function name is left alone', () => {
  withEnv({ FUNCTION_TARGET: 'handleIncomingSMS', FUNCTIONS_EMULATOR: undefined }, () => {
    const req = fakeReq({ host: 'us-central1-storage-facility-creator.cloudfunctions.net', originalUrl: '/handleIncomingSMS' });
    assert.equal(
      twilioWebhookUrl(req),
      'https://us-central1-storage-facility-creator.cloudfunctions.net/handleIncomingSMS',
    );
  });
});

test('emulator paths and hosts are used verbatim over http', () => {
  withEnv({ FUNCTION_TARGET: 'handleIncomingSMS', FUNCTIONS_EMULATOR: 'true' }, () => {
    const req = fakeReq({ host: 'localhost:5001', originalUrl: '/storage-facility-creator/us-central1/handleIncomingSMS' });
    assert.equal(
      twilioWebhookUrl(req),
      'http://localhost:5001/storage-facility-creator/us-central1/handleIncomingSMS',
    );
  });
});

test('x-forwarded-proto wins when present', () => {
  withEnv({ FUNCTION_TARGET: 'handleIncomingSMS', FUNCTIONS_EMULATOR: undefined }, () => {
    const req = fakeReq({ host: 'us-central1-storage-facility-creator.cloudfunctions.net', originalUrl: '/', proto: 'https' });
    assert.equal(
      twilioWebhookUrl(req),
      'https://us-central1-storage-facility-creator.cloudfunctions.net/handleIncomingSMS',
    );
  });
});
