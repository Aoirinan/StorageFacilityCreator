#!/usr/bin/env node
'use strict';

/**
 * Every file that hands a message to SendGrid or Twilio must first ask whether
 * the recipient is allowed to hear from us, or be listed below with a reason.
 *
 * This exists because sendEmail in functions-outbound-email went straight to
 * SendGrid without consulting the pre-launch gate, while the SMS callable and
 * sendFacilityEmailWithCompliance both enforced it. Nothing failed, no test
 * caught it, and the switch read as closed from every side but that one. A new
 * send path added tomorrow would repeat it, so the check is structural rather
 * than a unit test of any single function.
 */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');

// Direct provider handoffs. A file matching any of these is a send path.
const SEND_PATTERNS = [
  /getSgMail\(\)[\s\S]{0,120}?\.send\(/,
  /sgMail\s*\.\s*send\(/,
  /\.messages\s*\.\s*create\(/,
];

// A client bound once and used further down. orphanedSubscriptionSweep.ts does
// `const mail = getSgMail() as {...}` and calls mail.send inside a loop a few
// lines later: exactly 120 characters on, the edge of the proximity pattern
// above. A Windows checkout's CRLF endings pushed it to 123, the check reported
// the file as no longer sending, and it asked for the allowlist entry to be
// removed, which would have left a real send path unlisted. Following the
// binding does not depend on how far away the send is.
const SEND_CLIENT_BINDING = /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*getSgMail\(\)/g;

/** Names bound to a SendGrid client anywhere in [text]. */
function sendClientNames(text) {
  const names = new Set();
  SEND_CLIENT_BINDING.lastIndex = 0;
  let match;
  while ((match = SEND_CLIENT_BINDING.exec(text))) names.add(match[1]);
  return names;
}

/** Whether [text] hands a message to a provider, directly or via [clientNames]. */
function sendsIn(text, clientNames) {
  if (SEND_PATTERNS.some((re) => re.test(text))) return true;
  for (const name of clientNames) {
    const escaped = name.replace(/\$/g, '\\$');
    if (new RegExp('(^|[^\\w$.])' + escaped + '\\s*\\.\\s*send\\(').test(text)) return true;
  }
  return false;
}

// Any one of these means the file asked permission before sending.
const GATE_PATTERNS = [
  /isCustomerEmailAllowed/,
  /isCustomerRecipientAllowed/,
  /getOutboundGateConfig/,
  /isOwnerOnboardingEmailAllowed/,
  /getOwnerOnboardingGateConfig/,
  /sendFacilityEmailWithCompliance/,
];

// Send paths that legitimately skip the customer gate. Each needs a reason,
// and the reason has to survive someone reading it a year from now.
const ALLOWLIST = new Map([
  [
    'functions-account-security/src/otp.ts',
    'Login verification code. Gating it locks people out of their own accounts, ' +
      'including before launch.',
  ],
  [
    'functions-admin/src/superAdminCallables.ts',
    'Super-admin initiated: password resets and deliberate broadcasts. The ' +
      'person sending is the one the gate would otherwise protect against.',
  ],
  [
    'functions-automation/src/orphanedSubscriptionSweep.ts',
    'Summary to getSuperAdminEmails() only; never reaches an owner or tenant.',
  ],
  [
    'functions-messaging-twilio/src/a2pAdminAlerts.ts',
    'Texting registration status mail to getSuperAdminEmails() only; the owner ' +
      'is never a recipient.',
  ],
  [
    'functions-messaging-twilio/src/twilioAccountHealth.ts',
    'Internal health alert to super admins only.',
  ],
  [
    'functions-shared/src/email/complianceSend.ts',
    'This file is the gate. It calls isCustomerEmailAllowed itself.',
  ],
]);

const BACKSLASH = String.fromCharCode(92);
const BACKTICK = String.fromCharCode(96);

/**
 * Comments are not enforcement. The first draft matched the gate names anywhere
 * in the file, and a doc comment that merely mentioned
 * sendFacilityEmailWithCompliance was enough to pass a file whose gate had been
 * deleted. Strip comments and string bodies before looking for a real call.
 */
function stripCommentsAndStrings(source) {
  // Scan left to right rather than running one regex per quote type.
  //
  // Doing it in passes is not sound, and it silently broke this check. Single
  // quotes were stripped before backticks, so an apostrophe inside a template
  // literal — "doesn't", "owner's" — opened a string that ran on to the next
  // quote character anywhere in the file, swallowing the code between. On
  // outboundRaw.ts that pass cut the source from 36,063 characters to 13,530
  // and took the sgMail.send call with it, so the file stopped looking like a
  // send path at all and was skipped. The ungated callable this whole check
  // exists to catch passed it cleanly.
  //
  // One pass cannot get the nesting order wrong: whichever delimiter opens
  // first wins, which is what the language does too.
  let out = '';
  let i = 0;
  let lastSignificant = '';
  while (i < source.length) {
    const char = source[i];
    const pair = char + source[i + 1];

    if (pair === '/*') {
      const end = source.indexOf('*/', i + 2);
      i = end === -1 ? source.length : end + 2;
      out += ' ';
      continue;
    }
    if (pair === '//') {
      while (i < source.length && source[i] !== '\n') i++;
      out += ' ';
      continue;
    }
    // A regex literal is not a string, but it can contain quote characters,
    // and then everything after it reads as string content. outboundRaw.ts
    // matches an invite URL with /https?:\/\/[^\s"']+/ — that double quote
    // opened a literal that ran 5,797 characters and swallowed the sgMail.send
    // call below it, which is why the file did not register as a send path.
    //
    // Telling a regex from division needs to know whether a value or an
    // operator is expected. The last significant character is enough here: a
    // slash following one of these, or opening a line, starts a pattern.
    if (char === '/' && isRegexPosition(lastSignificant)) {
      i++;
      let inClass = false;
      while (i < source.length) {
        const c = source[i];
        if (c === BACKSLASH) {
          i += 2;
          continue;
        }
        if (c === '[') inClass = true;
        else if (c === ']') inClass = false;
        else if (c === '/' && !inClass) {
          i++;
          break;
        } else if (c === '\n') break;
        i++;
      }
      while (i < source.length && /[a-z]/.test(source[i])) i++;
      out += ' ';
      lastSignificant = ')';
      continue;
    }

    if (char === "'" || char === '"' || char === BACKTICK) {
      const quote = char;
      i++;
      while (i < source.length) {
        if (source[i] === BACKSLASH) {
          i += 2;
          continue;
        }
        if (source[i] === quote) {
          i++;
          break;
        }
        i++;
      }
      out += quote + quote;
      lastSignificant = quote;
      continue;
    }

    out += char;
    if (!/\s/.test(char)) lastSignificant = char;
    i++;
  }
  return out;
}

/** Whether a slash after [previous] opens a pattern rather than divides. */
function isRegexPosition(previous) {
  return previous === '' || '(,=:[!&|?{};+-*%~^<>'.includes(previous);
}

function listSourceFiles(dir) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules' || entry.name === 'lib' || entry.name === 'vendor') continue;
        stack.push(full);
        continue;
      }
      if (!entry.name.endsWith('.ts')) continue;
      if (entry.name.endsWith('.d.ts') || entry.name.endsWith('.test.ts')) continue;
      if (full.split(path.sep).includes('test')) continue;
      out.push(full);
    }
  }
  return out;
}

const packages = fs
  .readdirSync(repoRoot, { withFileTypes: true })
  .filter((e) => e.isDirectory() && /^functions(-|$)/.test(e.name))
  .map((e) => path.join(repoRoot, e.name, 'src'))
  .filter((p) => fs.existsSync(p));

/**
 * Split a file into the module scope and one region per exported symbol.
 *
 * Checking a whole file at once is not enough, and this is not hypothetical:
 * run the original check against the commit that introduced it and it passes.
 * outboundRaw.ts exports sendEmail, sendDigest and sendDailyDigests. The two
 * digests call sendFacilityEmailWithCompliance, which is a gate name, so the
 * file matched a gate pattern while sendEmail — the ungated path that motivated
 * the whole check — sat beside them unexamined. A gate anywhere in a file
 * vouched for every send in it.
 *
 * A region runs from its export keyword to the next one. Sends in private
 * helpers land in the module scope region and are checked there, which is where
 * their gate belongs too.
 */
function regionsOf(text) {
  const exportPattern = /^export\s+(?:const|async\s+function|function)\s+([A-Za-z0-9_]+)/gm;
  const marks = [];
  let match;
  while ((match = exportPattern.exec(text))) {
    marks.push({ name: match[1], start: match.index });
  }

  const regions = [
    { name: '<module scope>', start: 0, end: marks.length ? marks[0].start : text.length },
  ];
  for (let i = 0; i < marks.length; i++) {
    regions.push({
      name: marks[i].name,
      start: marks[i].start,
      end: i + 1 < marks.length ? marks[i + 1].start : text.length,
    });
  }
  return regions;
}

const ungated = [];
const staleAllowlist = new Set(ALLOWLIST.keys());

for (const src of packages) {
  for (const file of listSourceFiles(src)) {
    const rel = path.relative(repoRoot, file).split(path.sep).join('/');
    // CRLF on a Windows checkout lengthens every gap the proximity pattern
    // measures, so a local run could pass what CI's LF checkout fails.
    const text = stripCommentsAndStrings(fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n'));
    const clientNames = sendClientNames(text);
    if (!sendsIn(text, clientNames)) continue;
    staleAllowlist.delete(rel);
    if (ALLOWLIST.has(rel)) continue;

    for (const region of regionsOf(text)) {
      const body = text.slice(region.start, region.end);
      if (!sendsIn(body, clientNames)) continue;
      if (GATE_PATTERNS.some((re) => re.test(body))) continue;
      ungated.push(rel + '  (' + region.name + ')');
    }
  }
}

let failed = false;

if (ungated.length) {
  failed = true;
  console.error('Outbound send paths with no recipient gate:');
  console.error('');
  for (const rel of ungated) console.error('  ' + rel);
  console.error('');
  console.error('Each of these hands a message to SendGrid or Twilio without asking whether');
  console.error('the recipient is allowed to receive it before launch. Either route it through');
  console.error('a gate (isCustomerEmailAllowed, isCustomerRecipientAllowed,');
  console.error('isOwnerOnboardingEmailAllowed, or sendFacilityEmailWithCompliance), or add it');
  console.error('to ALLOWLIST in scripts/check_outbound_gate_coverage.js with a reason.');
}

if (staleAllowlist.size) {
  failed = true;
  console.error('');
  console.error('Allowlist entries that no longer send anything:');
  console.error('');
  for (const rel of staleAllowlist) console.error('  ' + rel);
  console.error('');
  console.error('Remove them so the allowlist keeps meaning what it says.');
}

if (failed) process.exit(1);

console.log(
  'OK: every outbound send path is gated or allowlisted (' +
    ALLOWLIST.size +
    ' allowlisted, reasons recorded in the script).',
);
