import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..');

// The rules tests by default. Functions packages pass their own command
// (their test:emulator scripts) to run Admin SDK tests on the same emulator
// setup; it runs from the repo root.
const testCommand = process.argv[2] || 'node --test firestore-rules-test/test/*.test.mjs';

const result = spawnSync(
  `npx -y firebase-tools@latest emulators:exec --only firestore,storage --project sfc-rules-test "${testCommand}"`,
  {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: true,
  },
);

process.exit(result.status ?? 1);
