/**
 * Site configuration. Edit these values to update nav, CTAs, and content.
 */

/** Marketing site version. Bump when you ship changes (e.g. 1.1.0, 1.2.0). */
export const SITE_VERSION = '1.1.0';

/** Replace with your production app login URL. Used for the Login button in header/footer. */
export const APP_LOGIN_URL = 'REPLACE_ME';

/** Paths for logo and demo image. Copy logo.png and demo.png into marketing/public/ */
export const LOGO_PATH = '/logo.png';
export const DEMO_IMAGE_PATH = '/demo.png';

export const SITE_NAME = 'Storage Facility Creator';
export const SUPPORT_EMAIL = 'support@example.com';
export const SUPPORT_PHONE = '(555) 123-4567';

export const HERO_HEADLINE = 'Modern self-storage management. Flat-rate $75/month.';
export const HERO_SUBHEADLINE =
  'Manage tenants and units, track billing and payments, and automate opt-in SMS/email reminders—without per-unit pricing.';

export const PRICE_MONTHLY = 75;
export const TRIAL_DAYS = 30;
export const TRIAL_LINE = '30-day trial + first month free';

export const TRUST_STRIP_ITEMS = [
  'Flat-rate $75/month',
  'No onboarding fee',
  '30-day trial + first month free',
  'Opt-in SMS (STOP/HELP)',
] as const;

export const A2P_COMPLIANCE_PARAGRAPH =
  'If a tenant provides a phone number and opts in, they may receive account-related SMS messages such as payment reminders and important updates. Message frequency varies. Message & data rates may apply. Reply STOP to opt out at any time. Reply HELP for help.';
