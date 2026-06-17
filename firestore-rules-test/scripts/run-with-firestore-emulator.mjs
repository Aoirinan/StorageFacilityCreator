import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..');

const result = spawnSync(
  'npx -y firebase-tools@latest emulators:exec --only firestore --project sfc-rules-test "node --test test/*.test.mjs"',
  {
    cwd: join(repoRoot, 'firestore-rules-test'),
    stdio: 'inherit',
    shell: true,
  },
);

process.exit(result.status ?? 1);
