#!/usr/bin/env node
'use strict';

/**
 * Stays (short-term rentals) must stay out of storage: no guest, stay or stay
 * money ever touches tenants, units, ledgers, payments, invoices,
 * reservations or publicReservations, and v1 sends nothing to anyone. This
 * check makes that structural rather than a promise (spec §6.1, §9).
 *
 * It scans the Stays code:
 *   functions-stays/src/**, functions-shared/src/stays/**,
 *   functions-shared/src/net/**, lib/**\/stays/**, lib/providers/stays_*.dart
 * (test/ directories excluded) and fails on:
 *   - collection('tenants'|'units'|'ledgers'|'payments'|'invoices'|
 *     'reservations'|'publicReservations'|'publicPaymentLinks'), and path
 *     strings containing /tenants/, /units/, /ledgers/, /payments/, /invoices/;
 *   - tenantId;
 *   - vpcConnector, QUICKBOOKS_VPC_CONNECTOR, defineSecret, STRIPE_, and the
 *     shared Stripe, email and Twilio helpers;
 *   - fetch(, https.request, http.request or axios outside
 *     functions-shared/src/net/safeFetch.ts;
 *   - getSgMail, sgMail, .messages.create(, api.twilio.com,
 *     sendFacilityEmailWithCompliance;
 *   - Dart imports of ledger_service, payment_service, tenant_service,
 *     unit_service or invoice_service.
 *
 * Comments are ignored (they are not code); string contents are checked.
 *
 * Usage: node scripts/check_stays_isolation.cjs [--self-test]
 * --self-test plants every violation in memory and fails unless each is caught.
 */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const SAFE_FETCH = 'functions-shared/src/net/safeFetch.ts';
const EXTENSIONS = new Set(['.ts', '.js', '.mjs', '.cjs', '.dart']);

const STORAGE_COLLECTIONS = [
  'tenants',
  'units',
  'ledgers',
  'payments',
  'invoices',
  'reservations',
  'publicReservations',
  'publicPaymentLinks',
];

/** Each rule: an id, what it guards, a pattern, and optionally files it does not apply to. */
const RULES = [
  {
    id: 'storage-collection',
    why: 'Stays never opens a storage collection',
    re: new RegExp(`collection(?:Group)?\\s*\\(\\s*['"\`](?:${STORAGE_COLLECTIONS.join('|')})['"\`]\\s*\\)`),
  },
  {
    id: 'storage-path',
    why: 'Stays never builds a path into a storage collection',
    re: /['"`][^'"`\n]*\/(?:tenants|units|ledgers|payments|invoices)\/[^'"`\n]*['"`]/,
  },
  { id: 'tenant-id', why: 'No stay doc carries a tenant id', re: /tenantId|tenant_id/i },
  { id: 'vpc-connector', why: 'functions-stays has no VPC connector (the Intuit NAT IP)', re: /vpcConnector|VPC_CONNECTOR/ },
  { id: 'define-secret', why: 'functions-stays has no secrets', re: /defineSecret/ },
  { id: 'stripe', why: 'No Stripe in Stays v1', re: /STRIPE_|['"]stripe['"]|@sfc\/functions-shared\/stripe\// },
  {
    id: 'raw-network',
    why: 'Network access only through net/safeFetch.ts',
    re: /\bfetch\s*\(|\bhttps?\.(?:request|get)\s*\(|\baxios\b|['"]node-fetch['"]|['"]undici['"]|package:(?:http|dio)\//,
    except: [SAFE_FETCH],
  },
  {
    id: 'send-primitive',
    why: 'Stays v1 sends no email or texts',
    re: /getSgMail|sgMail|\.messages\s*\.\s*create\s*\(|api\.twilio\.com|sendFacilityEmailWithCompliance|@sfc\/functions-shared\/(?:email|twilio)\//,
  },
  {
    id: 'storage-service-import',
    why: 'Stays Dart code never imports the storage services',
    re: /import\s+['"][^'"]*(?:^|\/)(?:ledger_service|payment_service|tenant_service|unit_service|invoice_service)\.dart['"]/,
  },
];

function toPosix(p) {
  return p.split(path.sep).join('/');
}

/** Whether a repo-relative path is Stays code this check covers. */
function inScope(rel) {
  const p = toPosix(rel);
  if (!EXTENSIONS.has(path.extname(p))) return false;
  if (p.split('/').some((seg) => seg === 'test' || seg === 'node_modules' || seg === 'lib' && p.startsWith('functions'))) {
    // Tests, installed modules and compiled output are not the source of truth.
    return false;
  }
  if (p.startsWith('functions-stays/src/')) return true;
  if (p.startsWith('functions-shared/src/stays/') || p.startsWith('functions-shared/src/net/')) return true;
  if (p.startsWith('lib/')) {
    const parts = p.split('/');
    if (parts.slice(1, -1).includes('stays')) return true;
    if (parts.length === 3 && parts[1] === 'providers' && /^stays_.*\.dart$/.test(parts[2])) return true;
  }
  return false;
}

/**
 * Blanks out comments, keeping strings and line numbers. A scan, not regex
 * passes: a quote inside a comment (or "//" inside a URL string) must not
 * change what the rest of the file means.
 */
function stripComments(source, lang) {
  const out = [];
  const n = source.length;
  let i = 0;
  const blank = (ch) => (ch === '\n' ? '\n' : ' ');
  while (i < n) {
    const c = source[i];
    const d = source[i + 1];
    if (c === '/' && d === '/') {
      while (i < n && source[i] !== '\n') {
        out.push(' ');
        i++;
      }
      continue;
    }
    if (c === '/' && d === '*') {
      let depth = 1;
      out.push('  ');
      i += 2;
      while (i < n && depth > 0) {
        if (lang === 'dart' && source[i] === '/' && source[i + 1] === '*') {
          depth++;
          out.push('  ');
          i += 2;
        } else if (source[i] === '*' && source[i + 1] === '/') {
          depth--;
          out.push('  ');
          i += 2;
        } else {
          out.push(blank(source[i]));
          i++;
        }
      }
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      const raw = lang === 'dart' && source[i - 1] === 'r';
      const triple = lang === 'dart' && source.startsWith(c.repeat(3), i);
      const close = triple ? c.repeat(3) : c;
      out.push(triple ? close : c);
      i += close.length;
      while (i < n) {
        if (!raw && source[i] === '\\') {
          out.push(source.slice(i, i + 2));
          i += 2;
          continue;
        }
        if (source.startsWith(close, i)) {
          out.push(close);
          i += close.length;
          break;
        }
        // An unterminated single-line string ends at the line.
        if (!triple && c !== '`' && source[i] === '\n') break;
        out.push(source[i]);
        i++;
      }
      continue;
    }
    out.push(c);
    i++;
  }
  return out.join('');
}

function languageOf(rel) {
  return path.extname(rel) === '.dart' ? 'dart' : 'js';
}

/** Violations in one file's text. */
function checkSource(rel, source) {
  const p = toPosix(rel);
  const code = stripComments(source, languageOf(p));
  const lines = code.split('\n');
  const found = [];
  for (const rule of RULES) {
    if (rule.except && rule.except.includes(p)) continue;
    lines.forEach((line, idx) => {
      const m = rule.re.exec(line);
      if (m) found.push({ file: p, line: idx + 1, rule: rule.id, why: rule.why, match: m[0].slice(0, 80) });
    });
  }
  return found;
}

function walk(dirAbs, out) {
  if (!fs.existsSync(dirAbs)) return;
  for (const entry of fs.readdirSync(dirAbs, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'build') continue;
    const abs = path.join(dirAbs, entry.name);
    if (entry.isDirectory()) walk(abs, out);
    else out.push(abs);
  }
}

function scanTree() {
  const files = [];
  for (const dir of ['functions-stays/src', 'functions-shared/src/stays', 'functions-shared/src/net', 'lib']) {
    walk(path.join(repoRoot, dir), files);
  }
  const rels = files.map((abs) => toPosix(path.relative(repoRoot, abs))).filter(inScope).sort();
  const violations = [];
  for (const rel of rels) {
    violations.push(...checkSource(rel, fs.readFileSync(path.join(repoRoot, rel), 'utf8')));
  }
  return { files: rels, violations };
}

function selfTest() {
  const ts = 'functions-stays/src/bookings/planted.ts';
  const shared = 'functions-shared/src/stays/planted.ts';
  const dart = 'lib/screens/stays/planted.dart';
  const provider = 'lib/providers/stays_planted.dart';
  const planted = [
    [ts, "db.collection('tenants').doc(id)", 'storage-collection'],
    [ts, 'db.collection("units")', 'storage-collection'],
    [ts, "db.collectionGroup('ledgers')", 'storage-collection'],
    [ts, "x.collection('payments')", 'storage-collection'],
    [ts, "x.collection('invoices')", 'storage-collection'],
    [ts, "x.collection('reservations')", 'storage-collection'],
    [ts, "x.collection('publicReservations')", 'storage-collection'],
    [ts, "x.collection('publicPaymentLinks')", 'storage-collection'],
    [dart, "FirebaseFirestore.instance.collection('tenants')", 'storage-collection'],
    [ts, 'db.doc(`facilities/${fid}/tenants/${id}`)', 'storage-path'],
    [ts, "db.doc('facilities/' + fid + '/units/' + u)", 'storage-path'],
    [shared, "const p = 'facilities/x/ledgers/y';", 'storage-path'],
    [dart, "final p = 'facilities/$fid/payments/$id';", 'storage-path'],
    [ts, "const p = `facilities/${f}/invoices/${i}`;", 'storage-path'],
    [ts, 'const row = { tenantId: null };', 'tenant-id'],
    [dart, "final m = {'tenantId': t};", 'tenant-id'],
    [ts, "functions.runWith({ vpcConnector: 'x' })", 'vpc-connector'],
    [ts, 'process.env.QUICKBOOKS_VPC_CONNECTOR', 'vpc-connector'],
    [ts, "const key = defineSecret('X');", 'define-secret'],
    [ts, 'process.env.STRIPE_SECRET_KEY', 'stripe'],
    [ts, "import Stripe from 'stripe';", 'stripe'],
    [ts, "import { x } from '@sfc/functions-shared/stripe/client';", 'stripe'],
    [ts, 'await fetch(url)', 'raw-network'],
    [ts, 'https.request(opts)', 'raw-network'],
    [ts, 'http.request(opts)', 'raw-network'],
    [ts, "import axios from 'axios';", 'raw-network'],
    ['functions-shared/src/net/other.ts', 'https.request(opts)', 'raw-network'],
    [dart, "import 'package:http/http.dart' as http;", 'raw-network'],
    [ts, 'getSgMail().send(msg)', 'send-primitive'],
    [ts, 'sgMail.send(msg)', 'send-primitive'],
    [ts, 'client.messages.create({ to })', 'send-primitive'],
    [ts, "const u = 'https://api.twilio.com/2010-04-01';", 'send-primitive'],
    [ts, 'await sendFacilityEmailWithCompliance(x)', 'send-primitive'],
    [ts, "import { x } from '@sfc/functions-shared/email/complianceSend';", 'send-primitive'],
    [dart, "import 'package:sfcapp/services/ledger_service.dart';", 'storage-service-import'],
    [dart, "import 'package:sfcapp/services/payment_service.dart';", 'storage-service-import'],
    [dart, "import '../../services/tenant_service.dart';", 'storage-service-import'],
    [provider, "import 'package:sfcapp/services/unit_service.dart';", 'storage-service-import'],
    [dart, "import 'package:sfcapp/services/invoice_service.dart';", 'storage-service-import'],
  ];
  // Must pass: comments, the safeFetch exemption, test files, code outside Stays, and look-alikes.
  const clean = [
    [ts, "// db.collection('tenants') is never used here\nconst a = 1;"],
    [ts, '/* tenantId: never */ const b = 2;'],
    [dart, "/// Never reads 'facilities/x/tenants/y'.\nfinal c = 3;"],
    [ts, "const url = 'https://www.airbnb.com/hosting/reservations/details/HM1'; // not storage"],
    [SAFE_FETCH, 'const req = https.request(opts);'],
    [ts, 'const n = refetchCount + prefetch(1);'],
    [ts, "db.collection('stays').doc(id)"],
    [dart, "import 'package:sfcapp/services/stays/stays_repository.dart';"],
  ];
  const outOfScope = [
    'functions-stays/src/test/guards.test.ts',
    'functions-shared/src/test/staysIds.test.ts',
    'lib/services/tenant_service.dart',
    'lib/providers/tenant_provider.dart',
    'functions-stays/lib/common/guards.js',
    'functions-automation/src/processExportJob.ts',
  ];
  const inScopeFiles = [
    'functions-stays/src/common/guards.ts',
    'functions-shared/src/stays/contracts.ts',
    'functions-shared/src/net/safeFetch.ts',
    'lib/screens/stays/stay_detail_screen.dart',
    'lib/services/stays/stays_repository.dart',
    'lib/models/stays/stay.dart',
    'lib/providers/stays_providers.dart',
  ];

  const failures = [];
  for (const [file, text, rule] of planted) {
    if (!inScope(file)) failures.push(`planted file is not in scope: ${file}`);
    const hits = checkSource(file, text).map((v) => v.rule);
    if (!hits.includes(rule)) failures.push(`missed ${rule} in ${file}: ${text}`);
  }
  for (const [file, text] of clean) {
    const hits = checkSource(file, text);
    if (hits.length) failures.push(`false positive in ${file}: ${text} → ${hits.map((h) => h.rule).join(', ')}`);
  }
  for (const file of outOfScope) if (inScope(file)) failures.push(`should not be scanned: ${file}`);
  for (const file of inScopeFiles) if (!inScope(file)) failures.push(`should be scanned: ${file}`);

  if (failures.length) {
    console.error('check_stays_isolation --self-test FAILED:');
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log(`check_stays_isolation --self-test: OK (${planted.length} planted violations caught, ${clean.length} clean samples passed)`);
}

function main() {
  if (process.argv.includes('--self-test')) {
    selfTest();
    return;
  }
  const { files, violations } = scanTree();
  if (violations.length) {
    console.error(`Stays isolation check FAILED (${violations.length} violation(s)):`);
    for (const v of violations) console.error(`  ${v.file}:${v.line}  [${v.rule}] ${v.why}: ${v.match}`);
    process.exit(1);
  }
  console.log(`OK: Stays isolation holds (${files.length} files scanned).`);
}

module.exports = { checkSource, inScope, stripComments, RULES };

if (require.main === module) main();
