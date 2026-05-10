import fs from 'node:fs';
import path from 'node:path';

/** CI runs with `working-directory: functions`; integrations live alongside. */
const functionsDir = process.cwd();
const repoRoot = path.join(functionsDir, '..');
const integrationsSrc = path.join(repoRoot, 'functions-integrations', 'src');
const indexPath = path.join(integrationsSrc, 'index.ts');
const secretsPath = path.join(integrationsSrc, 'secrets.ts');
const quickbooksPath = path.join(integrationsSrc, 'accounting', 'quickbooks.ts');

for (const p of [indexPath, secretsPath, quickbooksPath]) {
  if (!fs.existsSync(p)) {
    console.error(`QuickBooks readiness: missing file ${path.relative(repoRoot, p)}`);
    process.exit(1);
  }
}

const indexSource = fs.readFileSync(indexPath, 'utf8');
const secretsSource = fs.readFileSync(secretsPath, 'utf8');
const quickbooksSource = fs.readFileSync(quickbooksPath, 'utf8');

const failures = [];

function mustInclude(source, needle, message) {
  if (!source.includes(needle)) {
    failures.push(message);
  }
}

mustInclude(secretsSource, "defineSecret('QUICKBOOKS_CLIENT_ID')", 'Missing QUICKBOOKS_CLIENT_ID secret.');
mustInclude(secretsSource, "defineSecret('QUICKBOOKS_CLIENT_SECRET')", 'Missing QUICKBOOKS_CLIENT_SECRET secret.');
mustInclude(secretsSource, 'QUICKBOOKS_REDIRECT_URI', 'Missing QUICKBOOKS_REDIRECT_URI parameter.');
mustInclude(secretsSource, "defineString('QUICKBOOKS_ENV', { default: 'sandbox' })", 'Missing QUICKBOOKS_ENV parameter.');

[
  'getQuickBooksConnectionStatus',
  'getQuickBooksConnectUrl',
  'completeQuickBooksConnect',
  'disconnectQuickBooks',
  'syncInvoiceToQuickBooks',
  'syncPaymentToQuickBooks',
  'setQuickBooksAutoSync',
  'autoSyncInvoiceToQuickBooks',
  'autoSyncPaymentToQuickBooks',
].forEach((fnName) => {
  mustInclude(indexSource, fnName, `Missing QuickBooks export: ${fnName}`);
});

mustInclude(quickbooksSource, "scope: 'com.intuit.quickbooks.accounting'", 'Missing Intuit OAuth scope.');
mustInclude(quickbooksSource, "exchangeToken(config, 'authorization_code'", 'Missing authorization code exchange path.');
mustInclude(quickbooksSource, "exchangeToken(config, 'refresh_token'", 'Missing refresh token exchange path.');
mustInclude(quickbooksSource, 'autoSyncEnabled: true', 'Missing default autoSync enablement.');
mustInclude(quickbooksSource, "lastSyncStatus: 'error'", 'Missing error tracking on auto-sync failures.');

if (failures.length > 0) {
  console.error('QuickBooks readiness checks failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log('QuickBooks readiness checks passed.');
