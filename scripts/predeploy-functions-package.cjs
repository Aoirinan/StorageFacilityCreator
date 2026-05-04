/**
 * Firebase predeploy hook: vendor functions-shared, then npm install + build
 * for one codebase directory (functions | functions-ai | functions-marketing).
 * Uses cwd-based npm — avoids broken `npm install --prefix <dir>` on Windows npm 10.
 */
const path = require('path');
const { execSync } = require('child_process');

const pkgDir = process.argv[2];
if (!pkgDir || /^-/.test(pkgDir)) {
  console.error('Usage: node predeploy-functions-package.cjs <functions|functions-ai|functions-marketing>');
  process.exit(1);
}

const root = path.join(__dirname, '..');
execSync('node scripts/vendor-functions-shared.cjs', { cwd: root, stdio: 'inherit' });
const cwd = path.join(root, pkgDir);
execSync('npm install', { cwd, stdio: 'inherit', env: process.env });
execSync('npm run build', { cwd, stdio: 'inherit', env: process.env });
