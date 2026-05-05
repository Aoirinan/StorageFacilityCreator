/**
 * Firebase predeploy hook: vendor functions-shared, then npm install + build
 * for one codebase directory (functions | functions-ai | functions-marketing | functions-integrations).
 * Uses cwd-based npm — avoids broken `npm install --prefix <dir>` on Windows npm 10.
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

/**
 * Firebase CLI needs a per-codebase `.env` for defineString in non-interactive deploy/dry-run.
 * Copy QuickBooks keys from default `functions/.env` when present; otherwise minimal stubs.
 */
function ensureIntegrationsDotenv(root) {
  const dest = path.join(root, 'functions-integrations', '.env');
  if (fs.existsSync(dest)) return;
  const src = path.join(root, 'functions', '.env');
  let redirect = '';
  let env = 'sandbox';
  if (fs.existsSync(src)) {
    const raw = fs.readFileSync(src, 'utf8');
    const pick = (name) => {
      const m = raw.match(new RegExp(`^${name}=(.*)$`, 'm'));
      return m ? m[1].trim() : '';
    };
    redirect = pick('QUICKBOOKS_REDIRECT_URI');
    env = pick('QUICKBOOKS_ENV') || 'sandbox';
  }
  fs.writeFileSync(
    dest,
    `QUICKBOOKS_REDIRECT_URI=${redirect}\nQUICKBOOKS_ENV=${env}\n`,
    'utf8',
  );
  console.log('predeploy: wrote functions-integrations/.env (from functions/.env or defaults)');
}

const pkgDir = process.argv[2];
if (!pkgDir || /^-/.test(pkgDir)) {
  console.error('Usage: node predeploy-functions-package.cjs <functions|functions-ai|functions-marketing|functions-integrations>');
  process.exit(1);
}

const root = path.join(__dirname, '..');
execSync('node scripts/vendor-functions-shared.cjs', { cwd: root, stdio: 'inherit' });
if (pkgDir === 'functions-integrations') {
  ensureIntegrationsDotenv(root);
}
const cwd = path.join(root, pkgDir);
execSync('npm install', { cwd, stdio: 'inherit', env: process.env });
execSync('npm run build', { cwd, stdio: 'inherit', env: process.env });
