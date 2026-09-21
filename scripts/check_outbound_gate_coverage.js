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

// Body of a quoted string: any run of non-quote, non-backslash characters, or
// an escaped character. Built from char codes because the delimiters and the
// escape character are exactly what a source literal cannot carry cleanly.
function stringLiteralPattern(quote) {
  const q = quote === BACKTICK ? BACKTICK : quote;
  return new RegExp(
    q + '(?:[^' + q + BACKSLASH + BACKSLASH + ']|' + BACKSLASH + BACKSLASH + '.)*' + q,
    'g',
  );
}

/**
 * Comments are not enforcement. The first draft matched the gate names anywhere
 * in the file, and a doc comment that merely mentioned
 * sendFacilityEmailWithCompliance was enough to pass a file whose gate had been
 * deleted. Strip comments and string bodies before looking for a real call.
 */
function stripCommentsAndStrings(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\r\n]*/g, ' ')
    .replace(stringLiteralPattern("'"), "''")
    .replace(stringLiteralPattern('"'), '""')
    .replace(stringLiteralPattern(BACKTICK), BACKTICK + BACKTICK);
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

const ungated = [];
const staleAllowlist = new Set(ALLOWLIST.keys());

for (const src of packages) {
  for (const file of listSourceFiles(src)) {
    const rel = path.relative(repoRoot, file).split(path.sep).join('/');
    const text = stripCommentsAndStrings(fs.readFileSync(file, 'utf8'));
    if (!SEND_PATTERNS.some((re) => re.test(text))) continue;
    staleAllowlist.delete(rel);
    if (ALLOWLIST.has(rel)) continue;
    if (GATE_PATTERNS.some((re) => re.test(text))) continue;
    ungated.push(rel);
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
