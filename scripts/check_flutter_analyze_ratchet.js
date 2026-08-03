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

if (current > baseline) {
  console.error(`FAIL: issue count increased (${current} > ${baseline}). Fix the new issue(s) or, if this is a false positive, understand why before touching the baseline.`);
  process.exit(1);
}

if (current < baseline) {
  console.log(`Issue count dropped below baseline. Lower flutter_analyze_baseline.txt to ${current} to lock in the improvement.`);
}

console.log('OK');
