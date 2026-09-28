import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';

import { refreshChannelsFirst } from '../bookings/shared';
import { loadStaysGate, resetStaysGateCacheForTests } from '../common/serverConfig';
import { reconcileTurnovers } from '../tasks/onStayWrite';
import { FakeFirestore } from './support/fakeFirestore';
import { FAC, NOW, makeStay } from './support/staysFixtures';
import { P, listingInput, seedListing, setupEnv } from './support/bookingFixtures';

// The firebase-functions logger writes the log text into the entry's
// `message` key, over any `message` in the structured data. A failure logged
// as { message: error.message } therefore reached Cloud Logging without its
// error text. The error goes under `error`.
const all: FakeFirestore[] = [];

type Entry = Record<string, unknown>;

/**
 * The structured entries the real logger writes (one JSON line each) at
 * WARNING and above, which go to stderr, while `fn` runs. Only stderr: the
 * test runner reports results over stdout, and swallowing those would drop
 * this file's own test results.
 */
async function captureLogs(fn: () => Promise<unknown>): Promise<Entry[]> {
  const lines: string[] = [];
  const original = process.stderr.write;
  process.stderr.write = ((chunk: unknown, ...rest: unknown[]) => {
    lines.push(String(chunk));
    const done = rest.find((r) => typeof r === 'function') as (() => void) | undefined;
    done?.();
    return true;
  }) as typeof process.stderr.write;
  try {
    await fn();
  } finally {
    process.stderr.write = original;
  }
  const entries: Entry[] = [];
  for (const line of lines.flatMap((chunk) => chunk.split('\n'))) {
    try {
      const parsed = JSON.parse(line) as unknown;
      if (parsed && typeof parsed === 'object') entries.push(parsed as Entry);
    } catch {
      // Not a logger line.
    }
  }
  return entries;
}

function entryFor(entries: Entry[], text: string): Entry {
  const entry = entries.find((e) => typeof e.message === 'string' && e.message.includes(text));
  assert.ok(entry, `no log entry containing "${text}" in ${JSON.stringify(entries)}`);
  return entry;
}

test('a gate that cannot be read is logged with the reason it could not be read', async () => {
  const e = setupEnv(all);
  resetStaysGateCacheForTests();
  e.fake.failReads = (p) => p.startsWith('staysServerConfig/');
  const entries = await captureLogs(() => loadStaysGate(e.fake.firestore(), NOW + 1));
  e.fake.failReads = null;
  resetStaysGateCacheForTests();
  const entry = entryFor(entries, 'could not read staysServerConfig');
  assert.match(String(entry.error), /UNAVAILABLE/);
});

test('a fresh sync that fails before a booking is logged with its error', async () => {
  const entries = await captureLogs(() =>
    refreshChannelsFirst({
      sync: async () => {
        throw new Error('airbnb.com answered 503');
      },
      channels: [{ channelId: 'ch1', provider: 'airbnb', lastSuccessMs: null }],
      facilityId: FAC,
      syncEnabled: true,
      nowMs: NOW,
    }),
  );
  assert.equal(entryFor(entries, 'fresh sync before booking failed').error, 'airbnb.com answered 503');
});

test('a booking the turnover catch-up skips is logged with why', async () => {
  const e = setupEnv(all, { controls: { turnoverTasksEnabled: true } });
  seedListing(e.fake, 'lst_a', listingInput());
  e.fake.seed(`${P}/stays/man_bad`, makeStay('lst_a', '2026-10-02', '2026-10-04') as never);
  e.fake.failReads = (p) => p.endsWith('/stayTasks/turnover_man_bad');
  const entries = await captureLogs(() => reconcileTurnovers(e.fake.firestore(), FAC, NOW));
  e.fake.failReads = null;
  const entry = entryFor(entries, 'turnover catch-up skipped a booking');
  assert.equal(entry.stayId, 'man_bad');
  assert.match(String(entry.error), /UNAVAILABLE: read of .*turnover_man_bad failed/);
});

/** Every `logger.x(...)` call's argument text in a source file (parentheses matched, strings skipped). */
function loggerCalls(text: string): string[] {
  const calls: string[] = [];
  const re = /logger\.(?:debug|info|log|warn|error|write)\(/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    let depth = 1;
    let i = m.index + m[0].length;
    let quote: string | null = null;
    for (; i < text.length && depth > 0; i++) {
      const c = text[i];
      if (quote) {
        if (c === '\\') i++;
        else if (c === quote) quote = null;
      } else if (c === "'" || c === '"' || c === '`') quote = c;
      else if (c === '(') depth++;
      else if (c === ')') depth--;
    }
    calls.push(text.slice(m.index, i));
  }
  return calls;
}

test('no Stays log call puts anything under the `message` key, where the logger would overwrite it', () => {
  const src = path.resolve(__dirname, '..', '..', 'src');
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      if (fs.statSync(full).isDirectory()) {
        if (name !== 'test') walk(full);
      } else if (name.endsWith('.ts')) files.push(full);
    }
  };
  walk(src);
  assert.ok(files.length > 10, `expected the Stays sources under ${src}`);
  const offenders: string[] = [];
  for (const file of files) {
    for (const call of loggerCalls(fs.readFileSync(file, 'utf8'))) {
      if (/[{,]\s*message\s*[:,}]/.test(call)) offenders.push(`${path.relative(src, file)}: ${call.split('\n')[0]}`);
    }
  }
  assert.deepEqual(offenders, []);
});

test('logging never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});
