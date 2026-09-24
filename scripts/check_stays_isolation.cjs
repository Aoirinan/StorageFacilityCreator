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
 * leaving out only the functions-stays/src/test/ tree (its fakes seed
 * storage paths on purpose), node_modules and a functions package's own
 * build output (functions-*\/lib/). It fails on:
 *   - collection('tenants'|'units'|'ledgers'|'payments'|'invoices'|
 *     'reservations'|'publicReservations'|'publicPaymentLinks'), across
 *     lines and with a trailing comma, and any string that names one as a
 *     path segment ('/tenants/', `.../${id}/units`, 'ledgers/' + id);
 *   - tenantId;
 *   - vpcConnector, QUICKBOOKS_VPC_CONNECTOR, defineSecret, STRIPE_, 'stripe'
 *     and the shared Stripe helpers;
 *   - fetch(, http(s).request/get, axios and other HTTP clients, and any
 *     import or require of http, https, http2, net, tls, dgram or dns
 *     (node: or not) outside functions-shared/src/net/safeFetch.ts;
 *   - getSgMail, sgMail, .messages.create(, api.twilio.com,
 *     sendFacilityEmailWithCompliance, and imports of twilio, @sendgrid/*,
 *     nodemailer and the shared email and Twilio helpers;
 *   - imports of the storage-side shared code (@sfc/functions-shared/
 *     tenants, portal, subscription), of the functions-shared root barrel
 *     (it re-exports the portal helpers), and canAccessFacility;
 *   - Dart imports or exports of ledger_service, payment_service,
 *     tenant_service, unit_service or invoice_service.
 *
 * Each rule runs over the whole file with comments blanked out, so a call
 * split across lines is still one call. String contents are checked.
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
const STORAGE_NAMES = STORAGE_COLLECTIONS.join('|');

/** A module specifier in an import, export ... from, dynamic import() or require(). */
function moduleSpecifier(pattern) {
  return new RegExp(`(?:\\bfrom|\\bimport|\\brequire)\\s*\\(?\\s*['"\`](?:${pattern})['"\`]`);
}

const NET_MODULES = '(?:node:)?(?:https?|http2|net|tls|dgram|dns)(?:/[\\w/]*)?';
const HTTP_CLIENTS = 'axios|node-fetch|undici|got|superagent|cross-fetch|isomorphic-fetch';
const SEND_MODULES = 'twilio(?:/[^\'"`]*)?|@sendgrid/[^\'"`]+|nodemailer|postmark|mailgun\\.js|@aws-sdk/client-(?:ses|sesv2|sns)';

/** Each rule: an id, what it guards, a pattern, and optionally files it does not apply to. */
const RULES = [
  {
    id: 'storage-collection',
    why: 'Stays never opens a storage collection',
    re: new RegExp(`collection(?:Group)?\\s*\\(\\s*['"\`](?:${STORAGE_NAMES})['"\`]\\s*,?\\s*\\)`),
  },
  {
    id: 'storage-path',
    why: 'Stays never builds a path into a storage collection',
    // A path segment inside a string: '/tenants/', `.../${id}/units`, or a
    // relative 'ledgers/' + id. A bare 'reservations' (a CSV kind, a JSON
    // field) is not a path, and Airbnb's /hosting/reservations/ URLs are not storage.
    re: new RegExp(`(?<!hosting)/(?:${STORAGE_NAMES})(?:/|['"\`])|['"\`](?:${STORAGE_NAMES})/`),
  },
  { id: 'tenant-id', why: 'No stay doc carries a tenant id', re: /tenantId|tenant_id/i },
  { id: 'vpc-connector', why: 'functions-stays has no VPC connector (the Intuit NAT IP)', re: /vpcConnector|VPC_CONNECTOR/ },
  { id: 'define-secret', why: 'functions-stays has no secrets', re: /defineSecret/ },
  { id: 'stripe', why: 'No Stripe in Stays v1', re: /STRIPE_|['"`]stripe['"`]|@sfc\/functions-shared\/stripe\// },
  {
    id: 'raw-network',
    why: 'Network access only through net/safeFetch.ts',
    re: new RegExp(
      [
        /\bfetch\s*\(/.source,
        /\bhttps?\s*\.\s*(?:request|get)\s*\(/.source,
        /\baxios\b/.source,
        moduleSpecifier(NET_MODULES).source,
        moduleSpecifier(HTTP_CLIENTS).source,
        /package:(?:http|dio)\//.source,
        /\bHttpClient\s*\(/.source,
        /\bHttpRequest\s*\.\s*(?:request|getString)\b/.source,
      ].join('|'),
    ),
    except: [SAFE_FETCH],
  },
  {
    id: 'send-primitive',
    why: 'Stays v1 sends no email or texts',
    re: new RegExp(
      [
        /getSgMail|sgMail/.source,
        /\.\s*messages\s*\.\s*create\s*\(/.source,
        /api\.twilio\.com/.source,
        /sendFacilityEmailWithCompliance/.source,
        /@sfc\/functions-shared\/(?:email|twilio)\//.source,
        moduleSpecifier(SEND_MODULES).source,
      ].join('|'),
    ),
  },
  {
    id: 'storage-shared-import',
    why: 'Stays never uses the storage-side shared code or the facility access shortcut',
    re: new RegExp(
      [
        /@sfc\/functions-shared\/(?:tenants|portal|subscription)\//.source,
        moduleSpecifier('@sfc/functions-shared').source,
        /\bcanAccessFacility\b/.source,
      ].join('|'),
    ),
  },
  {
    id: 'storage-service-import',
    why: 'Stays Dart code never imports the storage services',
    re: /\b(?:import|export)\s+['"][^'"]*(?:^|\/)(?:ledger_service|payment_service|tenant_service|unit_service|invoice_service)\.dart['"]/,
  },
];

function toPosix(p) {
  return p.split(path.sep).join('/');
}

/** Whether a repo-relative path is Stays code this check covers. */
function inScope(rel) {
  const p = toPosix(rel);
  if (!EXTENSIONS.has(path.extname(p))) return false;
  if (p.split('/').includes('node_modules')) return false;
  // A functions package's build output is compiled from its src/.
  if (/^functions[^/]*\/lib\//.test(p)) return false;
  // The functions-stays tests: their fakes seed storage paths to prove isolation.
  if (p.startsWith('functions-stays/src/test/')) return false;
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

/** 1-based line of a character offset. */
function lineAt(text, index) {
  let line = 1;
  for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

/** Violations in one file's text: every match of every rule, over the whole file. */
function checkSource(rel, source) {
  const p = toPosix(rel);
  const code = stripComments(source, languageOf(p));
  const found = [];
  for (const rule of RULES) {
    if (rule.except && rule.except.includes(p)) continue;
    const re = new RegExp(rule.re.source, rule.re.flags.includes('g') ? rule.re.flags : `${rule.re.flags}g`);
    for (const m of code.matchAll(re)) {
      found.push({
        file: p,
        line: lineAt(code, m.index),
        rule: rule.id,
        why: rule.why,
        match: m[0].replace(/\s+/g, ' ').slice(0, 80),
      });
    }
  }
  return found;
}

function walk(dirAbs, out) {
  if (!fs.existsSync(dirAbs)) return;
  for (const entry of fs.readdirSync(dirAbs, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
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
  const nestedLib = 'functions-stays/src/bookings/lib/planted.ts';
  const sharedLib = 'functions-shared/src/stays/lib/planted.ts';
  const planted = [
    [ts, "db.collection('tenants').doc(id)", 'storage-collection'],
    [ts, 'db.collection("units")', 'storage-collection'],
    [ts, "db.collectionGroup('ledgers')", 'storage-collection'],
    [ts, "x.collection('payments')", 'storage-collection'],
    [ts, "x.collection('invoices')", 'storage-collection'],
    [ts, "x.collection('reservations')", 'storage-collection'],
    [ts, "x.collection('publicReservations')", 'storage-collection'],
    [ts, "x.collection('publicPaymentLinks')", 'storage-collection'],
    [ts, "x.collection('tenants',)", 'storage-collection'],
    [ts, "x.collection(\n  'tenants',\n)", 'storage-collection'],
    [ts, 'x\n  .collectionGroup(\n    "units"\n  )', 'storage-collection'],
    [dart, "FirebaseFirestore.instance.collection('tenants')", 'storage-collection'],
    [ts, 'db.doc(`facilities/${fid}/tenants/${id}`)', 'storage-path'],
    [ts, 'db.collection(`facilities/${fid}/tenants`)', 'storage-path'],
    [ts, "db.doc('facilities/' + fid + '/units/' + u)", 'storage-path'],
    [ts, "db.collection('facilities/'+fid+'/units')", 'storage-path'],
    [ts, "facility.doc('ledgers/' + id)", 'storage-path'],
    [shared, "const p = 'facilities/x/ledgers/y';", 'storage-path'],
    [dart, "final p = 'facilities/$fid/payments/$id';", 'storage-path'],
    [dart, "final c = db.collection('facilities/$fid/reservations');", 'storage-path'],
    [ts, 'const p = `facilities/${f}/invoices/${i}`;', 'storage-path'],
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
    [ts, "import { request } from 'node:https';", 'raw-network'],
    [ts, "import * as net from 'net';", 'raw-network'],
    [ts, "import tls from 'node:tls';", 'raw-network'],
    [ts, "import { lookup } from 'node:dns/promises';", 'raw-network'],
    [ts, "const h2 = await import('node:http2');", 'raw-network'],
    [ts, "require('https').get(url, cb)", 'raw-network'],
    [ts, 'const d = require("dgram");', 'raw-network'],
    [ts, "import { request } from 'undici';", 'raw-network'],
    [ts, "import got from 'got';", 'raw-network'],
    ['functions-shared/src/net/other.ts', 'https.request(opts)', 'raw-network'],
    ['functions-shared/src/net/other.ts', "import { request } from 'node:https';", 'raw-network'],
    [dart, "import 'package:http/http.dart' as http;", 'raw-network'],
    [dart, 'final c = HttpClient();', 'raw-network'],
    [ts, 'getSgMail().send(msg)', 'send-primitive'],
    [ts, 'sgMail.send(msg)', 'send-primitive'],
    [ts, 'client.messages.create({ to })', 'send-primitive'],
    [ts, 'client\n  .messages\n  .create({ to })', 'send-primitive'],
    [ts, "const u = 'https://api.twilio.com/2010-04-01';", 'send-primitive'],
    [ts, 'await sendFacilityEmailWithCompliance(x)', 'send-primitive'],
    [ts, "import { x } from '@sfc/functions-shared/email/complianceSend';", 'send-primitive'],
    [ts, "import twilio from 'twilio';", 'send-primitive'],
    [ts, "const twilio = require('twilio');", 'send-primitive'],
    [ts, "import sgMail from '@sendgrid/mail';", 'send-primitive'],
    [ts, "import nodemailer from 'nodemailer';", 'send-primitive'],
    [ts, "import { x } from '@sfc/functions-shared/tenants/tenantLookup';", 'storage-shared-import'],
    [ts, "import { x } from '@sfc/functions-shared/portal/portalAuth';", 'storage-shared-import'],
    [ts, "import { x } from '@sfc/functions-shared/subscription/plans';", 'storage-shared-import'],
    [ts, "import { canAccessFacility } from '@sfc/functions-shared';", 'storage-shared-import'],
    [ts, 'if (await canAccessFacility(uid, fid)) return;', 'storage-shared-import'],
    [dart, "import 'package:sfcapp/services/ledger_service.dart';", 'storage-service-import'],
    [dart, "import 'package:sfcapp/services/payment_service.dart';", 'storage-service-import'],
    [dart, "import '../../services/tenant_service.dart';", 'storage-service-import'],
    [provider, "import 'package:sfcapp/services/unit_service.dart';", 'storage-service-import'],
    [dart, "import 'package:sfcapp/services/invoice_service.dart';", 'storage-service-import'],
    [dart, "export 'package:sfcapp/services/ledger_service.dart';", 'storage-service-import'],
    // A folder named lib (or test) inside the Stays source is still scanned.
    [nestedLib, "db.collection('tenants')", 'storage-collection'],
    [sharedLib, "import { request } from 'node:https';", 'raw-network'],
  ];
  // Must pass: comments, the safeFetch exemption, code outside Stays, and look-alikes.
  const clean = [
    [ts, "// db.collection('tenants') is never used here\nconst a = 1;"],
    [ts, '/* tenantId: never */ const b = 2;'],
    [dart, "/// Never reads 'facilities/x/tenants/y'.\nfinal c = 3;"],
    [ts, "const url = 'https://www.airbnb.com/hosting/reservations/details/HM1'; // not storage"],
    [dart, "final url = 'https://www.airbnb.com/hosting/reservations/details/$code';"],
    [ts, 'const CODE_RE = /\\/hosting\\/reservations\\/details\\/([A-Z0-9]{6,14})/;'],
    [SAFE_FETCH, "import { request } from 'node:https';\nconst req = https.request(opts);"],
    [ts, 'const n = refetchCount + prefetch(1);'],
    [ts, "db.collection('stays').doc(id)"],
    [ts, "import { createHash } from 'node:crypto';"],
    [ts, "import { StayDoc } from '@sfc/functions-shared/stays/contracts';"],
    [ts, 'const perUnit = total / units / 2;'],
    [ts, "const kind = 'reservation';"],
    [dart, "import 'package:sfcapp/services/stays/stays_repository.dart';"],
  ];
  const outOfScope = [
    'functions-stays/src/test/guards.test.ts',
    'functions-stays/src/test/support/fakeFirestore.ts',
    'functions-shared/src/test/staysIds.test.ts',
    'lib/services/tenant_service.dart',
    'lib/providers/tenant_provider.dart',
    'functions-stays/lib/common/guards.js',
    'functions-shared/lib/stays/contracts.js',
    'functions-stays/node_modules/twilio/index.js',
    'functions-automation/src/processExportJob.ts',
  ];
  const inScopeFiles = [
    'functions-stays/src/common/guards.ts',
    'functions-stays/src/bookings/lib/helper.ts',
    'functions-stays/src/sync/test/fixtures.ts',
    'functions-shared/src/stays/contracts.ts',
    'functions-shared/src/stays/lib/x.ts',
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
    if (!hits.includes(rule)) failures.push(`missed ${rule} in ${file}: ${JSON.stringify(text)}`);
  }
  for (const [file, text] of clean) {
    const hits = checkSource(file, text);
    if (hits.length) failures.push(`false positive in ${file}: ${JSON.stringify(text)} → ${hits.map((h) => h.rule).join(', ')}`);
  }
  // Line numbers survive whole-file matching.
  const lines = checkSource(ts, "const a = 1;\n\nconst b = 2;\nx.collection(\n  'units',\n);");
  if (lines.length !== 1 || lines[0].line !== 4) failures.push(`wrong line for a multi-line match: ${JSON.stringify(lines)}`);
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
