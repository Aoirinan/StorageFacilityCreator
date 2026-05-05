/**
 * Copies built functions-shared into each Cloud Functions codebase under
 * vendor/functions-shared so package.json can use "file:vendor/functions-shared".
 * Firebase uploads each codebase directory without the repo root, so "file:../functions-shared"
 * does not exist in Cloud Build.
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const root = path.join(__dirname, '..');
const sharedRoot = path.join(root, 'functions-shared');
const libSrc = path.join(sharedRoot, 'lib');
const pkgSrc = path.join(sharedRoot, 'package.json');

const packages = ['functions', 'functions-ai', 'functions-marketing', 'functions-integrations', 'functions-admin', 'functions-public-website', 'functions-tenant-lifecycle', 'functions-automation', 'functions-facility-ops', 'functions-account-security'];

execSync('npm run build', { cwd: sharedRoot, stdio: 'inherit' });

if (!fs.existsSync(libSrc)) {
  console.error('vendor-functions-shared: missing functions-shared/lib — build failed?');
  process.exit(1);
}

for (const pkg of packages) {
  const dest = path.join(root, pkg, 'vendor', 'functions-shared');
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  fs.cpSync(libSrc, path.join(dest, 'lib'), { recursive: true });
  fs.copyFileSync(pkgSrc, path.join(dest, 'package.json'));
  console.log(`Vendored functions-shared → ${pkg}/vendor/functions-shared`);
}
