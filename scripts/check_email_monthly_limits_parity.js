#!/usr/bin/env node
/**
 * Ensures transactional email monthly caps match between Flutter and Cloud Functions.
 * Run from repo root: node scripts/check_email_monthly_limits_parity.js
 */

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const dartFile = path.join(root, 'lib', 'constants', 'email_monthly_limits.dart');
const tsFile = path.join(root, 'functions', 'src', 'constants', 'emailMonthlyLimits.ts');

function read(p) {
  if (!fs.existsSync(p)) {
    console.error(`Missing file: ${path.relative(root, p)}`);
    process.exit(1);
  }
  return fs.readFileSync(p, 'utf8');
}

function parseDart(src) {
  const trialing = src.match(/kEmailMonthlyLimitTrialing\s*=\s*(\d+)/);
  const paid = src.match(/kEmailMonthlyLimitPaid\s*=\s*(\d+)/);
  if (!trialing || !paid) {
    console.error('Could not parse trial/paid ints from lib/constants/email_monthly_limits.dart');
    process.exit(1);
  }
  return { trialing: Number(trialing[1]), paid: Number(paid[1]) };
}

function parseTs(src) {
  const trialing = src.match(/EMAIL_MONTHLY_LIMIT_TRIALING\s*=\s*(\d+)/);
  const paid = src.match(/EMAIL_MONTHLY_LIMIT_PAID\s*=\s*(\d+)/);
  if (!trialing || !paid) {
    console.error('Could not parse trial/paid ints from functions/src/constants/emailMonthlyLimits.ts');
    process.exit(1);
  }
  return { trialing: Number(trialing[1]), paid: Number(paid[1]) };
}

const dart = parseDart(read(dartFile));
const ts = parseTs(read(tsFile));

if (dart.trialing !== ts.trialing || dart.paid !== ts.paid) {
  console.error('Email monthly limits mismatch between Dart and TypeScript:\n');
  console.error(`  Dart:  trialing=${dart.trialing}, paid=${dart.paid}`);
  console.error(`  TS:    trialing=${ts.trialing}, paid=${ts.paid}`);
  console.error('\nUpdate lib/constants/email_monthly_limits.dart and');
  console.error('functions/src/constants/emailMonthlyLimits.ts to match.');
  process.exit(1);
}

console.log(
  `OK: email monthly limits match (trialing=${dart.trialing}, paid=${dart.paid}).`,
);
