import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..');

// The rules tests by default. Functions packages pass their own command
// (their test:emulator scripts) to run Admin SDK tests on the same emulator
// setup; it runs from the repo root.
//
// One file at a time: storage rules read facility docs with firestore.get(),
// which the storage emulator looks up in this run's project, so
// stays.rules.test.mjs seeds its facility there, and a clearFirestore() in a
// file running alongside would delete it mid-test.
const testCommand =
  process.argv[2] || 'node --test --test-concurrency=1 firestore-rules-test/test/*.test.mjs';

const result = spawnSync(
  `npx -y firebase-tools@latest emulators:exec --only firestore,storage --project sfc-rules-test "${testCommand}"`,
  {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: true,
  },
);

process.exit(result.status ?? 1);
