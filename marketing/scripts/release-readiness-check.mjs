import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const srcRoot = path.join(root, 'src');

function read(filePath) {
  return fs.readFileSync(path.join(root, filePath), 'utf8');
}

function exists(filePath) {
  return fs.existsSync(path.join(root, filePath));
}

function assertIncludes(haystack, needle, message, failures) {
  if (!haystack.includes(needle)) {
    failures.push(message);
  }
}

function runChecks() {
  const failures = [];

  const siteConfig = read('src/config/site.ts');
  assertIncludes(siteConfig, "PRIMARY_CTA_HREF = '/contact?intent=trial'", 'Primary CTA href mismatch.', failures);
  assertIncludes(siteConfig, "SECONDARY_CTA_HREF = '/contact?intent=demo'", 'Secondary CTA href mismatch.', failures);
  assertIncludes(siteConfig, "TERTIARY_CTA_HREF = '/product-tour'", 'Tertiary CTA href mismatch.', failures);
  assertIncludes(siteConfig, "SITE_DOMAIN = 'https://storagefacilitycreator.com'", 'Canonical domain mismatch.', failures);

  const contactPage = read('src/app/contact/page.tsx');
  assertIncludes(contactPage, 'href="/terms"', 'Contact consent links missing Terms link.', failures);
  assertIncludes(contactPage, 'href="/privacy"', 'Contact consent links missing Privacy link.', failures);
  assertIncludes(contactPage, 'href="/sms-terms"', 'Contact consent links missing SMS Terms link.', failures);

  const header = read('src/components/Header.tsx');
  assertIncludes(header, "aria-current={pathname === href ? 'page' : undefined}", 'Header active-state aria-current missing.', failures);

  const footer = read('src/components/Footer.tsx');
  [
    '/product-tour',
    '/integrations',
    '/why-sfc',
    '/features',
    '/pricing',
    '/faq',
    '/migration',
    '/terms',
    '/privacy',
    '/cookies',
    '/acceptable-use',
    '/billing',
    '/sms-terms',
    '/esign-disclosure',
    '/security',
    '/subprocessors',
    '/dpa',
  ].forEach((href) => assertIncludes(footer, `href: '${href}'`, `Footer missing link ${href}.`, failures));

  ['integrations', 'why-sfc', 'product-tour', 'migration'].forEach((slug) => {
    if (!exists(`src/app/${slug}/page.tsx`)) {
      failures.push(`Missing required page route /${slug}.`);
    }
  });

  const css = read('src/app/globals.css');
  assertIncludes(css, '.skip-link', 'Skip link styles missing.', failures);
  assertIncludes(css, '.tap-target', '44px tap target utility missing.', failures);
  assertIncludes(css, 'focus-visible', 'Focus-visible styles missing.', failures);

  const homePage = read('src/app/page.tsx');
  assertIncludes(homePage, "'@type': 'Organization'", 'Organization JSON-LD missing on homepage.', failures);
  assertIncludes(homePage, "'@type': 'SoftwareApplication'", 'SoftwareApplication JSON-LD missing on homepage.', failures);
  assertIncludes(homePage, 'DemoFrame src={HERO_IMAGE_PATH} alt=', 'Homepage hero alt text missing.', failures);

  const faqPage = read('src/app/faq/page.tsx');
  assertIncludes(faqPage, "'@type': 'FAQPage'", 'FAQPage JSON-LD missing.', failures);

  const robots = read('src/app/robots.ts');
  assertIncludes(robots, 'sitemap:', 'robots.ts missing sitemap directive.', failures);

  const sitemap = read('src/app/sitemap.ts');
  assertIncludes(sitemap, '/product-tour', 'sitemap missing /product-tour.', failures);
  assertIncludes(sitemap, '/integrations', 'sitemap missing /integrations.', failures);
  assertIncludes(sitemap, '/why-sfc', 'sitemap missing /why-sfc.', failures);
  assertIncludes(sitemap, '/migration', 'sitemap missing /migration.', failures);

  const smsTerms = read('src/app/sms-terms/page.tsx');
  ['STOP', 'HELP', 'Message frequency varies'].forEach((term) => {
    assertIncludes(smsTerms, term, `SMS terms missing compliance language: ${term}`, failures);
  });

  const eSign = read('src/app/esign-disclosure/page.tsx');
  ['Withdrawing Your Consent', 'Requesting Paper Copies', 'Updating Your Email Address'].forEach((section) => {
    assertIncludes(eSign, section, `E-Sign section missing: ${section}`, failures);
  });

  return failures;
}

const failures = runChecks();
if (failures.length > 0) {
  console.error('Release readiness checks failed:');
  failures.forEach((failure) => {
    console.error(`- ${failure}`);
  });
  process.exit(1);
}

console.log('Release readiness checks passed.');
