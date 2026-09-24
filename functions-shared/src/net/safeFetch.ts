/**
 * SSRF-safe fetch of a calendar feed (spec §6.8). The only network code in
 * Stays: scripts/check_stays_isolation.cjs forbids fetch(), http(s) and the
 * socket modules everywhere else in the Stays tree.
 *
 * A pasted feed URL is attacker-controllable text that our server will
 * request, so everything about the request is fixed here:
 *  - the URL: https only (an http link on an allowlisted host is upgraded,
 *    never fetched in plaintext), port 443, no userinfo, and a host that is
 *    exactly one of the allowlisted names (no wildcard or suffix match);
 *  - the address: every address the name resolves to must be public, and the
 *    connection goes to the address that was checked (SNI and certificate
 *    checks still use the real host), so a DNS answer that changes between
 *    the check and the connect (rebinding) cannot reach an internal address;
 *  - redirects are followed by hand, at most 3, re-validating every hop;
 *  - fixed headers (no caller headers), identity encoding, a 10 s total
 *    budget and a 2 MB streamed cap;
 *  - the body must be a calendar (so an HTML login page is `invalid_feed`).
 *
 * Logs name the host and the URL fingerprint only: a feed URL is a bearer
 * secret, and its path and query string are never logged or put in an error.
 */
import { createHash } from 'crypto';
import * as dns from 'node:dns';
import type { IncomingHttpHeaders, IncomingMessage } from 'node:http';
import * as https from 'node:https';
import { BlockList, isIP } from 'node:net';

export type SafeFetchErrorCode =
  | 'invalid_url'
  | 'blocked_host'
  | 'blocked_ip'
  | 'timeout'
  | 'too_large'
  | 'http_error'
  | 'gone'
  | 'invalid_feed'
  | 'network';

/** A typed failure. Its message never contains the URL. */
export class SafeFetchError extends Error {
  constructor(
    readonly code: SafeFetchErrorCode,
    message: string,
    readonly httpStatus: number | null = null,
    readonly host: string | null = null,
  ) {
    super(message);
    this.name = 'SafeFetchError';
  }
}

export interface SafeFetchOptions {
  allowedHosts: ReadonlySet<string>;
  etag?: string | null;
  lastModified?: string | null;
  /** Default 2_000_000. */
  maxBytes?: number;
  /** The whole call, DNS and redirects included. Default 10_000. */
  timeoutMs?: number;
  /** Default 3. */
  maxRedirects?: number;
}

export interface ResolvedAddress {
  address: string;
  family: number;
}

export interface SafeFetchLogEntry {
  host: string;
  urlFingerprint: string;
  outcome: string;
  httpStatus?: number | null;
}

export interface SafeFetchDeps {
  resolveAll?: (host: string) => Promise<ResolvedAddress[]>;
  request?: typeof https.request;
  now?: () => number;
  /** Receives host + fingerprint only. */
  log?: (entry: SafeFetchLogEntry) => void;
}

export interface SafeFetchResult {
  status: 200 | 304;
  body?: string;
  etag?: string;
  lastModified?: string;
  finalHost: string;
}

/**
 * The hosts a feed may come from. Exact names only. Airbnb's own domains
 * are listed per country site; others (Hipcamp, a PMS) are added through
 * staysServerConfig.extraIcalHosts once a real URL has been seen.
 */
export const BUILTIN_ICAL_HOSTS: readonly string[] = [
  'www.airbnb.com',
  'airbnb.com',
  'www.airbnb.ca',
  'www.airbnb.co.uk',
  'www.airbnb.com.au',
  'www.airbnb.ie',
  'www.airbnb.co.nz',
  'www.vrbo.com',
  'vrbo.com',
  'www.homeaway.com',
  'admin.booking.com',
  'ical.booking.com',
  'calendar.google.com',
];

export const SAFE_FETCH_DEFAULTS = {
  maxBytes: 2_000_000,
  timeoutMs: 10_000,
  maxRedirects: 3,
} as const;

const USER_AGENT = 'SFC-CalendarSync/1.0';
const ACCEPT = 'text/calendar, text/plain;q=0.9';
const ALLOWED_CONTENT_TYPES = new Set(['text/calendar', 'text/plain', 'application/octet-stream']);
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
/** The channel says the link is dead or not ours any more. */
const GONE_STATUSES = new Set([401, 403, 404, 410]);
const MAX_URL_LENGTH = 2048;

/** Names that are never fetched, whatever an allowlist says. */
function isForbiddenName(host: string): boolean {
  return (
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.internal') ||
    host.endsWith('.local') ||
    host === 'metadata.google.internal' ||
    host === 'metadata'
  );
}

/**
 * An extra host from staysServerConfig: lowercase, contains a dot, is not an
 * IP literal, and is not localhost, *.internal or *.local.
 */
export function isAcceptableExtraHost(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 253) return false;
  if (value !== value.toLowerCase()) return false;
  if (!value.includes('.') || value.startsWith('.') || value.endsWith('.') || value.includes('..')) return false;
  if (!/^[a-z0-9.-]+$/.test(value)) return false;
  if (isIP(value) !== 0) return false;
  if (/^[0-9.]+$/.test(value)) return false;
  return !isForbiddenName(value);
}

/** The built-in list plus the acceptable extras. */
export function allowedIcalHosts(extraHosts: readonly string[] = []): Set<string> {
  const hosts = new Set(BUILTIN_ICAL_HOSTS);
  for (const h of extraHosts) if (isAcceptableExtraHost(h)) hosts.add(h);
  return hosts;
}

/** sha256(url)[0:12]: names a feed in logs and on the channel doc without revealing it. */
export function urlFingerprint(url: string): string {
  return createHash('sha256').update(url, 'utf8').digest('hex').slice(0, 12);
}

export interface ValidatedFeedUrl {
  /** https://host/path?query, fragment dropped. */
  url: string;
  host: string;
  /** True when an http: link was upgraded. */
  upgraded: boolean;
}

/**
 * Checks a feed URL without touching the network: scheme, port, userinfo and
 * an exact host match. Throws SafeFetchError('invalid_url' | 'blocked_host').
 */
export function validateFeedUrl(raw: unknown, allowedHosts: ReadonlySet<string>): ValidatedFeedUrl {
  if (typeof raw !== 'string') throw new SafeFetchError('invalid_url', 'That is not a link.');
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.length > MAX_URL_LENGTH) {
    throw new SafeFetchError('invalid_url', 'That is not a calendar link.');
  }
  let u: URL;
  try {
    u = new URL(trimmed);
  } catch {
    throw new SafeFetchError('invalid_url', 'That is not a calendar link.');
  }
  const host = u.hostname.toLowerCase();
  if (u.protocol !== 'https:' && u.protocol !== 'http:') {
    throw new SafeFetchError('blocked_host', 'Only https calendar links can be used.', null, host || null);
  }
  if (u.username || u.password) {
    throw new SafeFetchError('blocked_host', 'A calendar link cannot contain a user name or password.', null, host);
  }
  if (u.port !== '' && u.port !== '443') {
    throw new SafeFetchError('blocked_host', 'A calendar link must use the standard https port.', null, host);
  }
  if (isForbiddenName(host) || isIP(host.replace(/^\[|\]$/g, '')) !== 0 || !allowedHosts.has(host)) {
    throw new SafeFetchError('blocked_host', 'Calendar links from that site are not supported.', null, host);
  }
  const upgraded = u.protocol === 'http:';
  // Never plaintext: http on an allowlisted host becomes https on 443.
  const url = `https://${host}${u.pathname}${u.search}`;
  return { url, host, upgraded };
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

const BLOCKED = (() => {
  const list = new BlockList();
  const v4: [string, number][] = [
    ['0.0.0.0', 8],
    ['10.0.0.0', 8],
    ['100.64.0.0', 10],
    ['127.0.0.0', 8],
    ['169.254.0.0', 16],
    ['172.16.0.0', 12],
    ['192.0.0.0', 24],
    ['192.168.0.0', 16],
    ['198.18.0.0', 15],
    ['224.0.0.0', 4],
    ['240.0.0.0', 4],
  ];
  for (const [net, prefix] of v4) list.addSubnet(net, prefix, 'ipv4');
  const v6: [string, number][] = [
    ['::', 128],
    ['::1', 128],
    ['fc00::', 7],
    ['fe80::', 10],
    // Beyond the spec's list, the same way: IPv4-compatible and NAT64 forms
    // can carry an internal IPv4 address.
    ['::', 96],
    ['64:ff9b::', 96],
  ];
  for (const [net, prefix] of v6) list.addSubnet(net, prefix, 'ipv6');
  return list;
})();

/**
 * Eight 16-bit groups of a well-formed IPv6 address (net.isIP already said
 * so), an embedded IPv4 tail ('::ffff:1.2.3.4') included; null otherwise.
 */
function ipv6Groups(address: string): number[] | null {
  let a = address.toLowerCase().split('%')[0];
  let tail: number[] = [];
  const lastColon = a.lastIndexOf(':');
  if (lastColon < 0) return null;
  const last = a.slice(lastColon + 1);
  if (last.includes('.')) {
    if (isIP(last) !== 4) return null;
    const o = last.split('.').map(Number);
    tail = [(o[0] << 8) | o[1], (o[2] << 8) | o[3]];
    // '::ffff:1.2.3.4' → '::ffff'; '::1.2.3.4' → '::' (keep the double colon).
    a = a[lastColon - 1] === ':' ? a.slice(0, lastColon + 1) : a.slice(0, lastColon);
  }
  const want = 8 - tail.length;
  const parse = (s: string): number[] | null => {
    if (s === '') return [];
    const out: number[] = [];
    for (const g of s.split(':')) {
      if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
      out.push(parseInt(g, 16));
    }
    return out;
  };
  const parts = a.split('::');
  if (parts.length > 2) return null;
  const head = parse(parts[0]);
  if (!head) return null;
  if (parts.length === 1) return head.length === want ? [...head, ...tail] : null;
  const rest = parse(parts[1]);
  if (!rest) return null;
  const fill = want - head.length - rest.length;
  if (fill < 0) return null;
  return [...head, ...new Array<number>(fill).fill(0), ...rest, ...tail];
}

/**
 * The address to check: an IPv4-mapped IPv6 address (::ffff:a.b.c.d, in any
 * spelling) is checked as the IPv4 address it carries.
 */
export function normalizeAddress(address: string): { address: string; family: 4 | 6 } | null {
  const bare = address.replace(/^\[|\]$/g, '');
  const kind = isIP(bare.split('%')[0]);
  if (kind === 4) return { address: bare, family: 4 };
  if (kind !== 6) return null;
  const groups = ipv6Groups(bare);
  if (!groups) return null;
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    const v4 = [groups[6] >> 8, groups[6] & 255, groups[7] >> 8, groups[7] & 255].join('.');
    return { address: v4, family: 4 };
  }
  return { address: groups.map((g) => g.toString(16)).join(':'), family: 6 };
}

/** Whether an address is private, loopback, link-local, reserved or otherwise not the public internet. */
export function isBlockedAddress(address: string): boolean {
  const n = normalizeAddress(address);
  if (!n) return true;
  return BLOCKED.check(n.address, n.family === 4 ? 'ipv4' : 'ipv6');
}

async function defaultResolveAll(host: string): Promise<ResolvedAddress[]> {
  const found = await dns.promises.lookup(host, { all: true, verbatim: true });
  return found.map((a) => ({ address: a.address, family: a.family }));
}

// ---------------------------------------------------------------------------
// The fetch
// ---------------------------------------------------------------------------

interface HopResult {
  statusCode: number;
  headers: IncomingHttpHeaders;
  body: Buffer | null;
}

function headerValue(headers: IncomingHttpHeaders, name: string): string | undefined {
  const v = headers[name];
  if (Array.isArray(v)) return v[0];
  return typeof v === 'string' ? v : undefined;
}

/** Body text: BOM and leading whitespace are not part of the check. */
function looksLikeCalendar(text: string): boolean {
  return text.replace(/^﻿/, '').trimStart().slice(0, 15).toUpperCase() === 'BEGIN:VCALENDAR';
}

export async function safeFetchText(
  rawUrl: string,
  opts: SafeFetchOptions,
  deps: SafeFetchDeps = {},
): Promise<SafeFetchResult> {
  const maxBytes = opts.maxBytes ?? SAFE_FETCH_DEFAULTS.maxBytes;
  const timeoutMs = opts.timeoutMs ?? SAFE_FETCH_DEFAULTS.timeoutMs;
  const maxRedirects = opts.maxRedirects ?? SAFE_FETCH_DEFAULTS.maxRedirects;
  const resolveAll = deps.resolveAll ?? defaultResolveAll;
  const request = deps.request ?? https.request;
  const log = deps.log ?? (() => undefined);

  const first = validateFeedUrl(rawUrl, opts.allowedHosts);
  const fingerprint = urlFingerprint(first.url);

  let expired = false;
  let onExpire: (() => void) | null = null;
  const timer = setTimeout(() => {
    expired = true;
    onExpire?.();
  }, timeoutMs);
  const timeoutError = (host: string) => new SafeFetchError('timeout', 'The calendar took too long to answer.', null, host);

  /** Races a step against the one overall deadline. */
  const withinBudget = <T>(host: string, work: (setAbort: (fn: () => void) => void) => Promise<T>): Promise<T> =>
    new Promise<T>((resolve, reject) => {
      if (expired) {
        reject(timeoutError(host));
        return;
      }
      let abort: () => void = () => undefined;
      onExpire = () => {
        abort();
        reject(timeoutError(host));
      };
      work((fn) => {
        abort = fn;
      }).then(resolve, reject);
    });

  const hop = (target: URL, pinned: ResolvedAddress): Promise<HopResult> =>
    withinBudget(target.hostname, (setAbort) =>
      new Promise<HopResult>((resolve, reject) => {
        const host = target.hostname;
        const headers: Record<string, string> = {
          Host: host,
          'User-Agent': USER_AGENT,
          Accept: ACCEPT,
          'Accept-Encoding': 'identity',
        };
        if (opts.etag) headers['If-None-Match'] = opts.etag;
        if (opts.lastModified) headers['If-Modified-Since'] = opts.lastModified;
        let settled = false;
        const fail = (error: SafeFetchError) => {
          if (settled) return;
          settled = true;
          reject(error);
        };
        const req = request(
          {
            protocol: 'https:',
            // Connect to the address that was checked, never a fresh lookup.
            host: pinned.address,
            port: 443,
            path: `${target.pathname}${target.search}`,
            method: 'GET',
            servername: host,
            headers,
            agent: false,
            lookup: ((_hostname: string, options: unknown, callback?: unknown) => {
              const cb = (typeof options === 'function' ? options : callback) as (
                err: Error | null,
                address: string | ResolvedAddress[],
                family?: number,
              ) => void;
              const all = typeof options === 'object' && options !== null && (options as { all?: boolean }).all === true;
              if (all) cb(null, [{ address: pinned.address, family: pinned.family }]);
              else cb(null, pinned.address, pinned.family);
            }) as never,
          },
          (res: IncomingMessage) => {
            const statusCode = res.statusCode ?? 0;
            if (statusCode !== 200) {
              res.resume();
              settled = true;
              resolve({ statusCode, headers: res.headers, body: null });
              return;
            }
            const declared = Number(headerValue(res.headers, 'content-length'));
            if (Number.isFinite(declared) && declared > maxBytes) {
              res.destroy();
              fail(new SafeFetchError('too_large', 'The calendar is too large.', 200, host));
              return;
            }
            const chunks: Buffer[] = [];
            let bytes = 0;
            res.on('data', (chunk: Buffer | string) => {
              const buf = typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : chunk;
              bytes += buf.length;
              if (bytes > maxBytes) {
                res.destroy();
                req.destroy();
                fail(new SafeFetchError('too_large', 'The calendar is too large.', 200, host));
                return;
              }
              chunks.push(buf);
            });
            res.on('end', () => {
              if (settled) return;
              settled = true;
              resolve({ statusCode, headers: res.headers, body: Buffer.concat(chunks) });
            });
            res.on('error', () => fail(new SafeFetchError('network', 'The calendar connection failed.', null, host)));
            res.on('aborted', () => fail(new SafeFetchError('network', 'The calendar connection failed.', null, host)));
          },
        );
        setAbort(() => {
          settled = true;
          req.destroy();
        });
        req.on('error', () => fail(new SafeFetchError('network', 'The calendar connection failed.', null, host)));
        req.end();
      }),
    );

  try {
    let current = first;
    for (let redirects = 0; ; redirects++) {
      const target = new URL(current.url);
      const host = target.hostname;
      const addresses = await withinBudget(host, async () => {
        try {
          return await resolveAll(host);
        } catch {
          throw new SafeFetchError('network', 'The calendar site could not be found.', null, host);
        }
      });
      if (addresses.length === 0) {
        throw new SafeFetchError('network', 'The calendar site could not be found.', null, host);
      }
      // Any private answer blocks the host: an attacker controls which one a client would use.
      if (addresses.some((a) => isBlockedAddress(a.address))) {
        throw new SafeFetchError('blocked_ip', 'That calendar site resolves to a private address.', null, host);
      }
      const res = await hop(target, addresses[0]);

      if (REDIRECT_STATUSES.has(res.statusCode)) {
        const location = headerValue(res.headers, 'location');
        if (!location) throw new SafeFetchError('http_error', 'The calendar sent a redirect with no address.', res.statusCode, host);
        if (redirects >= maxRedirects) {
          throw new SafeFetchError('http_error', 'The calendar redirected too many times.', res.statusCode, host);
        }
        let next: URL;
        try {
          next = new URL(location, target);
        } catch {
          throw new SafeFetchError('http_error', 'The calendar sent a bad redirect.', res.statusCode, host);
        }
        // Every hop is re-validated: scheme, port, userinfo, host, then DNS.
        current = validateFeedUrl(next.toString(), opts.allowedHosts);
        continue;
      }
      if (res.statusCode === 304) {
        log({ host, urlFingerprint: fingerprint, outcome: 'not_modified', httpStatus: 304 });
        return {
          status: 304,
          etag: headerValue(res.headers, 'etag') ?? opts.etag ?? undefined,
          lastModified: headerValue(res.headers, 'last-modified') ?? opts.lastModified ?? undefined,
          finalHost: host,
        };
      }
      if (GONE_STATUSES.has(res.statusCode)) {
        throw new SafeFetchError('gone', 'The calendar link no longer works.', res.statusCode, host);
      }
      if (res.statusCode !== 200) {
        throw new SafeFetchError('http_error', 'The calendar site returned an error.', res.statusCode, host);
      }
      const encoding = (headerValue(res.headers, 'content-encoding') ?? 'identity').trim().toLowerCase();
      if (encoding !== '' && encoding !== 'identity') {
        throw new SafeFetchError('invalid_feed', 'The calendar was sent in an encoding we do not read.', 200, host);
      }
      const contentType = (headerValue(res.headers, 'content-type') ?? '').split(';')[0].trim().toLowerCase();
      if (!ALLOWED_CONTENT_TYPES.has(contentType)) {
        throw new SafeFetchError('invalid_feed', 'That link did not return a calendar.', 200, host);
      }
      const body = (res.body ?? Buffer.alloc(0)).toString('utf8');
      if (!looksLikeCalendar(body)) {
        throw new SafeFetchError('invalid_feed', 'That link did not return a calendar.', 200, host);
      }
      log({ host, urlFingerprint: fingerprint, outcome: 'ok', httpStatus: 200 });
      return {
        status: 200,
        body,
        etag: headerValue(res.headers, 'etag'),
        lastModified: headerValue(res.headers, 'last-modified'),
        finalHost: host,
      };
    }
  } catch (error) {
    if (error instanceof SafeFetchError) {
      log({ host: error.host ?? first.host, urlFingerprint: fingerprint, outcome: error.code, httpStatus: error.httpStatus });
      throw error;
    }
    log({ host: first.host, urlFingerprint: fingerprint, outcome: 'network' });
    throw new SafeFetchError('network', 'The calendar connection failed.', null, first.host);
  } finally {
    clearTimeout(timer);
    onExpire = null;
  }
}
