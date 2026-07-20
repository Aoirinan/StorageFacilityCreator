import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..');

const result = spawnSync(
  'npx -y firebase-tools@latest emulators:exec --only firestore,storage --project sfc-rules-test "node --test firestore-rules-test/test/*.test.mjs"',
  {
    cwd: repoRoot,
    stdio: 'inherit',
    shell: true,
  },
);

process.exit(result.status ?? 1);
