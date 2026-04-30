#!/usr/bin/env node
/**
 * Fails if generated/build output paths are tracked in git.
 * Run from repo root: node scripts/check_tracked_generated_artifacts.js
 */

const { execSync } = require('child_process');
const path = require('path');

const root = path.join(__dirname, '..');
const PREFIXES = ['build/', '.dart_tool/', 'functions/lib/', '.firebase/'];

let tracked;
try {
  tracked = execSync('git ls-files', { cwd: root, encoding: 'utf8' });
} catch (e) {
  console.error(e);
  process.exit(1);
}

const files = tracked.split(/\r?\n/).filter(Boolean);
const bad = files.filter((f) => PREFIXES.some((p) => f.startsWith(p)));

if (bad.length) {
  console.error('Tracked generated artifacts (remove from index with git rm --cached):');
  for (const f of bad) {
    console.error(`  ${f}`);
  }
  process.exit(1);
}

console.log('OK: no tracked paths under build/, .dart_tool/, functions/lib/, .firebase/');
