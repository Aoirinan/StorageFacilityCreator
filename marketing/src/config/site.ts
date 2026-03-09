/**
 * Site configuration. Edit these values to update nav, CTAs, and content.
 */

/** Marketing site version. Bump when you ship changes (e.g. 1.2.0, 1.3.0). */
export const SITE_VERSION = '1.2.1';

/** Production app login URL. Used for the Login button in header/footer. */
export const APP_LOGIN_URL = 'https://storage-facility-creator.web.app/#/login';

/** Paths for logo and demo image. Copy logo.png and demo.png into marketing/public/ */
export const LOGO_PATH = '/logo.png';
export const DEMO_IMAGE_PATH = '/demo.png';

/** Optional extra screenshots for Features or "See the app" section. Add paths like '/demo2.png', '/delinquency.png'. */
export const EXTRA_DEMO_IMAGES: { src: string; alt: string }[] = [
  // Example: { src: '/demo2.png', alt: 'Delinquency and past due view' },
];

export const SITE_NAME = 'Storage Facility Creator';
export const SUPPORT_EMAIL = 'support@storagefacilitycreator.com';
export const SUPPORT_PHONE = '903-715-7504';

export const HERO_HEADLINE = 'Run your storage facility from one place.';
export const HERO_SUBHEADLINE =
  'Tenants and units, billing and ledgers, late notices and reminders—all in one system. See what’s paid, what’s past due, and what’s empty at a glance. Simple, flat-rate pricing when you’re ready.';

export const PRICE_MONTHLY = 75;
export const TRIAL_DAYS = 30;
export const TRIAL_LINE = '30-day trial + first month free';

export const TRUST_STRIP_ITEMS = [
  'Tenant & unit management',
  'Billing, ledger & payment tracking',
  'Late notices & delinquency tools',
  'SMS/email reminders (opt-in, STOP/HELP)',
  'Reports & activity logs',
] as const;

export const A2P_COMPLIANCE_PARAGRAPH =
  'If a tenant provides a phone number and opts in, they may receive account-related SMS messages such as payment reminders and important updates. Message frequency varies. Message & data rates may apply. Reply STOP to opt out at any time. Reply HELP for help.';
