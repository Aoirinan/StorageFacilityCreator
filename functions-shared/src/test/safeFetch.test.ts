import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import type * as https from 'node:https';
import { PassThrough } from 'node:stream';

import {
  BUILTIN_ICAL_HOSTS,
  ResolvedAddress,
  SafeFetchDeps,
  SafeFetchError,
  SafeFetchLogEntry,
  allowedIcalHosts,
  connectOrder,
  isAcceptableExtraHost,
  isBlockedAddress,
  normalizeAddress,
  safeFetchText,
  urlFingerprint,
  validateFeedUrl,
} from '../net/safeFetch';

const HOSTS = allowedIcalHosts();
const PUBLIC_IP = '52.44.10.20';
const SECRET_PATH = '/calendar/ical/123456.ics?s=SUPERSECRETTOKEN';
const FEED_URL = `https://www.airbnb.com${SECRET_PATH}`;
const ICS = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n';

interface FakeReply {
  status: number;
  headers?: Record<string, string>;
  chunks?: (string | Buffer)[];
  chunkDelayMs?: number;
}

interface Call {
  host: string;
  servername: string;
  port: number;
  path: string;
  headers: Record<string, string>;
  lookup: (h: string, o: unknown, cb: (err: Error | null, address: unknown, family?: number) => void) => void;
  agent: unknown;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** A fake https.request: replies by "Host header + path", records every call. */
function fakeServer(routes: Record<string, FakeReply>) {
  const calls: Call[] = [];
  const request = ((options: Call, cb: (res: PassThrough & { statusCode: number; headers: Record<string, string> }) => void) => {
    calls.push(options);
    const req = new EventEmitter() as EventEmitter & { end(): void; destroy(): void };
    let destroyed = false;
    req.destroy = () => {
      destroyed = true;
    };
    req.end = () => {
      setImmediate(() => {
        if (destroyed) return;
        const reply = routes[`${options.headers.Host}${options.path}`];
        if (!reply) {
          req.emit('error', new Error('ECONNREFUSED'));
          return;
        }
        const res = new PassThrough() as PassThrough & { statusCode: number; headers: Record<string, string> };
        res.statusCode = reply.status;
        res.headers = Object.fromEntries(Object.entries(reply.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
        cb(res);
        void (async () => {
          for (const chunk of reply.chunks ?? []) {
            if (reply.chunkDelayMs) await sleep(reply.chunkDelayMs);
            if (destroyed || res.destroyed) return;
            res.write(chunk);
          }
          if (!res.destroyed) res.end();
        })();
      });
    };
    return req;
  }) as unknown as typeof https.request;
  return { request, calls };
}

function resolver(map: Record<string, string[] | string[][]>) {
  const counts: Record<string, number> = {};
  const resolveAll = async (host: string): Promise<ResolvedAddress[]> => {
    counts[host] = (counts[host] ?? 0) + 1;
    const entry = map[host];
    if (!entry) throw new Error('ENOTFOUND');
    // An array of arrays: a different answer each time (rebinding).
    const answer = Array.isArray(entry[0]) ? (entry as string[][])[Math.min(counts[host] - 1, entry.length - 1)] : (entry as string[]);
    return answer.map((address) => ({ address, family: address.includes(':') ? 6 : 4 }));
  };
  return { resolveAll, counts };
}

const calendarOk: FakeReply = { status: 200, headers: { 'Content-Type': 'text/calendar; charset=utf-8', ETag: '"v1"' }, chunks: [ICS] };

async function codeOf(p: Promise<unknown>): Promise<string> {
  try {
    await p;
    return 'ok';
  } catch (error) {
    return error instanceof SafeFetchError ? error.code : `untyped: ${String(error)}`;
  }
}

function deps(routes: Record<string, FakeReply>, dns: Record<string, string[] | string[][]> = { 'www.airbnb.com': [PUBLIC_IP] }, extra: Partial<SafeFetchDeps> = {}) {
  const server = fakeServer(routes);
  const r = resolver(dns);
  const logs: SafeFetchLogEntry[] = [];
  return { server, r, logs, deps: { request: server.request, resolveAll: r.resolveAll, log: (e: SafeFetchLogEntry) => logs.push(e), ...extra } };
}

test('every private, loopback, link-local and reserved range is blocked, IPv4-mapped forms included', () => {
  const blocked = [
    '0.1.2.3',
    '10.0.0.1',
    '100.64.0.1',
    '100.127.255.254',
    '127.0.0.1',
    '169.254.169.254',
    '172.16.0.1',
    '172.31.255.255',
    '192.0.0.8',
    '192.168.1.1',
    '198.18.0.1',
    '198.19.255.255',
    '224.0.0.1',
    '239.255.255.250',
    '240.0.0.1',
    '255.255.255.255',
    '::',
    '::1',
    'fc00::1',
    'fd12:3456::1',
    'fe80::1',
    'fe80::1%eth0',
    '::ffff:127.0.0.1',
    '::ffff:7f00:1',
    '::ffff:10.0.0.1',
    '0:0:0:0:0:ffff:a9fe:a9fe',
    '::ffff:169.254.169.254',
    '::127.0.0.1',
    '64:ff9b::10.0.0.1',
    '64:ff9b:1::a00:1',
    // IPv4-translated, 6to4 and Teredo carry an IPv4 address too.
    '::ffff:0:7f00:1',
    '::ffff:0:10.0.0.1',
    '2002:7f00:1::',
    '2002:a9fe:a9fe::1',
    '2001:0:4136:e378:8000:63bf:3fff:fdd2',
    'fec0::1',
    'ff02::1',
    '100::1',
    '2001:db8::1',
    'not-an-ip',
  ];
  for (const a of blocked) assert.equal(isBlockedAddress(a), true, a);
  const open = ['8.8.8.8', PUBLIC_IP, '172.32.0.1', '100.128.0.1', '198.20.0.1', '2606:4700:4700::1111', '::ffff:8.8.8.8', '2a03:2880:f10d:83:face:b00c:0:25de', '2001:4860:4860::8888'];
  for (const a of open) assert.equal(isBlockedAddress(a), false, a);
  assert.deepEqual(normalizeAddress('::ffff:7f00:1'), { address: '127.0.0.1', family: 4 });
});

test('a host that resolves to any private address is refused before connecting', async () => {
  for (const answer of [['10.0.0.5'], [PUBLIC_IP, '127.0.0.1'], ['::ffff:169.254.169.254']]) {
    const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk }, { 'www.airbnb.com': answer });
    assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps)), 'blocked_ip', answer.join(','));
    assert.equal(h.server.calls.length, 0);
  }
});

test('the connection is pinned to the checked address, so a rebinding DNS answer is never used', async () => {
  const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk }, { 'www.airbnb.com': [[PUBLIC_IP], ['127.0.0.1']] });
  const res = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps);
  assert.equal(res.status, 200);
  assert.equal(h.r.counts['www.airbnb.com'], 1);
  const call = h.server.calls[0];
  assert.equal(call.host, PUBLIC_IP);
  assert.equal(call.servername, 'www.airbnb.com');
  assert.equal(call.port, 443);
  assert.equal(call.agent, false);
  // Whatever the socket layer asks, the answer is the checked address.
  const got: unknown[] = [];
  call.lookup('www.airbnb.com', {}, (_e, address) => got.push(address));
  call.lookup('www.airbnb.com', { all: true }, (_e, address) => got.push(address));
  assert.deepEqual(got, [PUBLIC_IP, [{ address: PUBLIC_IP, family: 4 }]]);
});

test('IPv4 is tried first, and a checked address that will not connect falls through to the next', async () => {
  const V6 = '2606:4700:4700::1111';
  assert.deepEqual(
    connectOrder([
      { address: V6, family: 6 },
      { address: PUBLIC_IP, family: 4 },
      { address: '52.44.10.21', family: 4 },
    ]).map((a) => a.address),
    [PUBLIC_IP, '52.44.10.21', V6],
  );

  // The resolver lists IPv6 first and this egress has no IPv6 route.
  const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk }, { 'www.airbnb.com': [V6, PUBLIC_IP] });
  const res = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps);
  assert.equal(res.status, 200);
  assert.deepEqual(h.server.calls.map((c) => c.host), [PUBLIC_IP]);

  // The first IPv4 address refuses the connection: the next checked one is used, never a fresh lookup.
  const unreachable = new Set([PUBLIC_IP]);
  const inner = fakeServer({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk });
  const request = ((options: Call, cb: never) => {
    if (!unreachable.has(options.host)) return (inner.request as unknown as (o: Call, c: never) => unknown)(options, cb);
    inner.calls.push(options);
    const req = new EventEmitter() as EventEmitter & { end(): void; destroy(): void };
    req.destroy = () => undefined;
    req.end = () => setImmediate(() => req.emit('error', new Error('ENETUNREACH')));
    return req;
  }) as unknown as typeof https.request;
  const r = resolver({ 'www.airbnb.com': [PUBLIC_IP, '52.44.10.21'] });
  const fallback = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, { request, resolveAll: r.resolveAll });
  assert.equal(fallback.status, 200);
  assert.deepEqual(inner.calls.map((c) => c.host), [PUBLIC_IP, '52.44.10.21']);
  assert.equal(r.counts['www.airbnb.com'], 1);

  // No address connects: a network failure, after trying each once.
  unreachable.add('52.44.10.21');
  inner.calls.length = 0;
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, { request, resolveAll: r.resolveAll })), 'network');
  assert.equal(inner.calls.length, 2);
  // An HTTP answer is final: an error status is not retried on another address.
  const err = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 503 } }, { 'www.airbnb.com': [PUBLIC_IP, '52.44.10.21'] });
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, err.deps)), 'http_error');
  assert.equal(err.server.calls.length, 1);
});

test('a redirect to a private or unlisted address is refused at the hop', async () => {
  for (const location of ['https://127.0.0.1/cal.ics', 'https://169.254.169.254/computeMetadata/v1/', 'http://metadata.google.internal/', 'https://evil.example.com/x.ics']) {
    const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 302, headers: { Location: location } } });
    assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps)), 'blocked_host', location);
    assert.equal(h.server.calls.length, 1);
  }
  // An allowlisted host that resolves privately is caught on the hop's own DNS check.
  const h = deps(
    { [`www.airbnb.com${SECRET_PATH}`]: { status: 301, headers: { Location: 'https://airbnb.com/next.ics' } } },
    { 'www.airbnb.com': [PUBLIC_IP], 'airbnb.com': ['10.1.2.3'] },
  );
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps)), 'blocked_ip');
});

test('redirects are followed by hand, re-checked, and capped at 3', async () => {
  const hop = (to: string): FakeReply => ({ status: 302, headers: { Location: to } });
  const ok = deps(
    {
      [`www.airbnb.com${SECRET_PATH}`]: hop('https://airbnb.com/a.ics'),
      'airbnb.com/a.ics': hop('/b.ics'),
      'airbnb.com/b.ics': calendarOk,
    },
    { 'www.airbnb.com': [PUBLIC_IP], 'airbnb.com': ['52.44.10.21'] },
  );
  const res = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, ok.deps);
  assert.equal(res.finalHost, 'airbnb.com');
  assert.equal(ok.server.calls.length, 3);

  const loop = deps({ [`www.airbnb.com${SECRET_PATH}`]: hop(FEED_URL) });
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, loop.deps)), 'http_error');
  assert.equal(loop.server.calls.length, 4);
});

test('bad URLs are refused without touching the network', async () => {
  const cases: [string, string][] = [
    ['https://user:pw@www.airbnb.com/cal.ics', 'blocked_host'],
    ['https://www.airbnb.com:8443/cal.ics', 'blocked_host'],
    ['https://airbnb.com.evil.com/cal.ics', 'blocked_host'],
    ['https://evil-airbnb.com/cal.ics', 'blocked_host'],
    ['https://www.airbnb.com./cal.ics', 'blocked_host'],
    ['https://10.0.0.1/cal.ics', 'blocked_host'],
    ['https://[::1]/cal.ics', 'blocked_host'],
    ['ftp://www.airbnb.com/cal.ics', 'blocked_host'],
    ['webcal://www.airbnb.com/cal.ics', 'blocked_host'],
    ['file:///etc/passwd', 'blocked_host'],
    ['not a url', 'invalid_url'],
    ['', 'invalid_url'],
  ];
  for (const [url, code] of cases) {
    const h = deps({});
    assert.equal(await codeOf(safeFetchText(url, { allowedHosts: HOSTS }, h.deps)), code, url);
    assert.equal(h.server.calls.length, 0);
    assert.equal(Object.keys(h.r.counts).length, 0);
  }
});

test('an http link on an allowlisted host is upgraded to https, never fetched in plaintext', async () => {
  const v = validateFeedUrl(`http://www.airbnb.com${SECRET_PATH}#frag`, HOSTS);
  assert.deepEqual(v, { url: FEED_URL, host: 'www.airbnb.com', upgraded: true });
  const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk });
  await safeFetchText(`http://www.airbnb.com${SECRET_PATH}`, { allowedHosts: HOSTS }, h.deps);
  assert.equal(h.server.calls[0].port, 443);
  assert.equal((h.server.calls[0] as unknown as { protocol: string }).protocol, 'https:');
});

test('fixed request headers; conditional headers only from the stored ETag and Last-Modified', async () => {
  const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 304, headers: { ETag: '"v2"' } } });
  const res = await safeFetchText(FEED_URL, { allowedHosts: HOSTS, etag: '"v1"', lastModified: 'Wed, 30 Sep 2026 10:00:00 GMT' }, h.deps);
  assert.deepEqual(res, { status: 304, etag: '"v2"', lastModified: 'Wed, 30 Sep 2026 10:00:00 GMT', finalHost: 'www.airbnb.com' });
  assert.deepEqual(h.server.calls[0].headers, {
    Host: 'www.airbnb.com',
    'User-Agent': 'SFC-CalendarSync/1.0',
    Accept: 'text/calendar, text/plain;q=0.9',
    'Accept-Encoding': 'identity',
    'If-None-Match': '"v1"',
    'If-Modified-Since': 'Wed, 30 Sep 2026 10:00:00 GMT',
  });
  const ok = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk }).deps);
  assert.deepEqual([ok.status, ok.body, ok.etag], [200, ICS, '"v1"']);
});

test('a body over the cap is cut off, whether declared or streamed', async () => {
  const declared = deps({
    [`www.airbnb.com${SECRET_PATH}`]: { status: 200, headers: { 'Content-Type': 'text/calendar', 'Content-Length': '5000' }, chunks: [ICS] },
  });
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS, maxBytes: 1000 }, declared.deps)), 'too_large');
  const streamed = deps({
    [`www.airbnb.com${SECRET_PATH}`]: { status: 200, headers: { 'Content-Type': 'text/calendar' }, chunks: [ICS, 'X'.repeat(600), 'X'.repeat(600)] },
  });
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS, maxBytes: 1000 }, streamed.deps)), 'too_large');
});

test('a slow body times out on the overall budget', async () => {
  const slow = deps({
    [`www.airbnb.com${SECRET_PATH}`]: { status: 200, headers: { 'Content-Type': 'text/calendar' }, chunks: ['BEGIN:VCALENDAR\r\n', 'END:VCALENDAR\r\n'], chunkDelayMs: 150 },
  });
  const started = Date.now();
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS, timeoutMs: 60 }, slow.deps)), 'timeout');
  assert.ok(Date.now() - started < 1000);
  // A resolver that never answers is bounded by the same budget.
  const hang = deps({}, {}, { resolveAll: () => new Promise<ResolvedAddress[]>(() => undefined) });
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS, timeoutMs: 40 }, hang.deps)), 'timeout');
});

test('an HTML page, a wrong content type or a compressed body is invalid_feed', async () => {
  const html = '<!DOCTYPE html><html><body>Log in</body></html>';
  const replies: FakeReply[] = [
    { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' }, chunks: [html] },
    { status: 200, headers: { 'Content-Type': 'text/plain' }, chunks: [html] },
    { status: 200, headers: {}, chunks: [ICS] },
    { status: 200, headers: { 'Content-Type': 'text/calendar', 'Content-Encoding': 'gzip' }, chunks: [ICS] },
  ];
  for (const reply of replies) {
    const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: reply });
    assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps)), 'invalid_feed', JSON.stringify(reply.headers));
  }
  // A BOM and leading blank lines before BEGIN:VCALENDAR are fine; octet-stream is accepted.
  const bom = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 200, headers: { 'Content-Type': 'application/octet-stream' }, chunks: [`﻿\r\n  ${ICS}`] } });
  assert.equal((await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, bom.deps)).status, 200);
});

test('401/403/404/410 mean the link is gone; other errors are http_error with the status', async () => {
  for (const status of [401, 403, 404, 410]) {
    const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status } });
    assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps)), 'gone', String(status));
  }
  const h = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 503 } });
  const err = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, h.deps).catch((e: unknown) => e);
  assert.ok(err instanceof SafeFetchError);
  assert.equal(err.code, 'http_error');
  assert.equal(err.httpStatus, 503);
  const refused = deps({});
  assert.equal(await codeOf(safeFetchText(FEED_URL, { allowedHosts: HOSTS }, refused.deps)), 'network');
});

test('logs and errors carry the host and URL fingerprint only, never the path or query', async () => {
  const ok = deps({ [`www.airbnb.com${SECRET_PATH}`]: calendarOk });
  await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, ok.deps);
  const fail = deps({ [`www.airbnb.com${SECRET_PATH}`]: { status: 404 } });
  const err = await safeFetchText(FEED_URL, { allowedHosts: HOSTS }, fail.deps).catch((e: unknown) => e);
  const all = JSON.stringify([...ok.logs, ...fail.logs]) + String((err as Error).message) + JSON.stringify(err);
  assert.equal(all.includes('SUPERSECRETTOKEN'), false);
  assert.equal(all.includes('/calendar/ical'), false);
  assert.deepEqual(ok.logs, [{ host: 'www.airbnb.com', urlFingerprint: urlFingerprint(FEED_URL), outcome: 'ok', httpStatus: 200 }]);
  assert.match(urlFingerprint(FEED_URL), /^[a-f0-9]{12}$/);
});

test('extra hosts from the server config are exact names only', () => {
  for (const good of ['www.hipcamp.com', 'calendar.example.org']) assert.equal(isAcceptableExtraHost(good), true, good);
  for (const bad of ['localhost', 'metadata.google.internal', 'printer.local', 'x.internal', '10.0.0.1', '1.2.3.4', 'Upper.Example.com', '*.example.com', 'nodot', '.lead.com', 'trail.com.', 'a..b.com']) {
    assert.equal(isAcceptableExtraHost(bad), false, bad);
  }
  const hosts = allowedIcalHosts(['www.hipcamp.com', 'localhost', '10.0.0.1']);
  assert.ok(hosts.has('www.hipcamp.com'));
  assert.equal(hosts.has('localhost'), false);
  assert.equal(hosts.has('10.0.0.1'), false);
  for (const h of BUILTIN_ICAL_HOSTS) assert.ok(hosts.has(h));
});
