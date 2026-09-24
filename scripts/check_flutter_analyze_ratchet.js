#!/usr/bin/env node
/**
 * Fails if `flutter analyze` reports more issues than the committed baseline.
 * This is a ratchet, not a gate: it stops the legacy lint backlog from growing
 * without requiring it to be fixed all at once. Lower the baseline in
 * flutter_analyze_baseline.txt as issues get fixed — never raise it to make
 * a failing run pass.
 * Run from repo root: node scripts/check_flutter_analyze_ratchet.js
 */
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const baselinePath = path.join(root, 'flutter_analyze_baseline.txt');

// An error line. flutter_tools separates fields with '-' on Windows and '•'
// everywhere else, so '- ' alone never matched on the Linux CI runner.
const ERROR_LINE = /^\s*error [•-] /;

// Self-check, so a filter that stops matching either platform fails loudly
// instead of letting every error through.
for (const [line, isError] of [
  ['  error - Undefined name - lib/a.dart:1:1 - undefined_identifier', true],
  ['  error • Undefined name • lib/a.dart:1:1 • undefined_identifier', true],
  ['warning • Unused import • lib/a.dart:1:8 • unused_import', false],
  ['   info - Prefer const - lib/a.dart:2:3 - prefer_const_constructors', false],
]) {
  if (ERROR_LINE.test(line) !== isError) {
    console.error(`FAIL: the error-line filter ${isError ? 'misses' : 'wrongly matches'}: ${line}`);
    process.exit(1);
  }
}
const baseline = parseInt(fs.readFileSync(baselinePath, 'utf8').trim(), 10);

let output;
try {
  output = execSync('flutter analyze', { cwd: root, encoding: 'utf8' });
} catch (e) {
  // flutter analyze exits non-zero whenever it finds any issue (including info-level),
  // which is expected here — we care about the count, not its exit code.
  output = (e.stdout || '') + (e.stderr || '');
}

const match = output.match(/(\d+) issues? found/);
if (!match) {
  console.error('Could not parse issue count from `flutter analyze` output:');
  console.error(output);
  process.exit(1);
}

const current = parseInt(match[1], 10);
console.log(`flutter analyze: ${current} issues (baseline: ${baseline})`);

// Errors fail whatever the count: a screen no test imports can stop
// compiling and `flutter test` still passes (a removed argument did).
const errors = output.split(/\r?\n/).filter((line) => ERROR_LINE.test(line));
if (errors.length > 0) {
  console.error(`FAIL: flutter analyze reports ${errors.length} error(s):`);
  console.error(errors.join('\n'));
  process.exit(1);
}

if (current > baseline) {
  console.error(`FAIL: issue count increased (${current} > ${baseline}). Fix the new issue(s) or, if this is a false positive, understand why before touching the baseline.`);
  process.exit(1);
}

if (current < baseline) {
  console.log(`Issue count dropped below baseline. Lower flutter_analyze_baseline.txt to ${current} to lock in the improvement.`);
}

console.log('OK');
