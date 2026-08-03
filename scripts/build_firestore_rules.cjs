/**
 * Concatenates firestore-rules-src/**\/*.rules (per manifest.json order) into
 * firestore.rules. Run after editing any file under firestore-rules-src/.
 * CI (`--check`) fails if firestore.rules is out of sync with the fragments.
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const srcDir = path.join(root, 'firestore-rules-src');
const outFile = path.join(root, 'firestore.rules');

const manifest = JSON.parse(fs.readFileSync(path.join(srcDir, 'manifest.json'), 'utf8'));

const parts = manifest.fragments.map((relPath) => {
  const content = fs.readFileSync(path.join(srcDir, relPath), 'utf8').replace(/\n$/, '');
  return content;
});

let output = parts.join('\n');
if (manifest.hadTrailingNewline) output += '\n';

const checkOnly = process.argv.includes('--check');

if (checkOnly) {
  const current = fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : null;
  if (current !== output) {
    console.error('firestore.rules is out of date with firestore-rules-src/. Run: node scripts/build_firestore_rules.cjs');
    process.exit(1);
  }
  console.log('OK: firestore.rules matches firestore-rules-src/');
} else {
  fs.writeFileSync(outFile, output);
  console.log(`Wrote ${outFile} from ${manifest.fragments.length} fragments.`);
}
