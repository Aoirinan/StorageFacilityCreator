export const SITE_VERSION = '1.3.4';

export const SITE_NAME = 'Storage Facility Creator';
/** Canonical public marketing origin (www). Apex host should 308 to this URL. */
export const SITE_DOMAIN = 'https://www.storagefacilitycreator.com';
export const SUPPORT_EMAIL = 'support@storagefacilitycreator.com';
export const SUPPORT_PHONE = '855-526-4544';

/** Website-domain login entry used by header/CTA links. */
export const APP_LOGIN_URL = '/login';
/** Final app destination for login redirect page. */
export const APP_LOGIN_REDIRECT_URL = 'https://app.storagefacilitycreator.com/#/login';

/** CTA hierarchy */
export const PRIMARY_CTA_LABEL = 'Start Free Trial';
export const PRIMARY_CTA_HREF = '/contact?intent=trial';
export const SECONDARY_CTA_LABEL = 'Book a Demo';
export const SECONDARY_CTA_HREF = '/contact?intent=demo';
export const TERTIARY_CTA_LABEL = 'View Product Tour';
export const TERTIARY_CTA_HREF = '/product-tour';

/** Assets */
export const LOGO_PATH = '/logo-mark.svg';
export const DEMO_IMAGE_PATH = '/demo.png';
export const HERO_IMAGE_PATH = '/sfc_dashboard_hero_clean.png';
export const DEFAULT_OG_IMAGE = '/sfc_dashboard_hero_clean.png';

export const PAGE_OG_IMAGES: Record<string, string> = {
  home: '/sfc_dashboard_hero_clean.png',
  features: '/sfc_dashboard_hero_clean.png',
  pricing: '/sfc_dashboard_hero_clean.png',
  security: '/sfc_dashboard_hero_clean.png',
  faq: '/sfc_dashboard_hero_clean.png',
  contact: '/sfc_dashboard_hero_clean.png',
  integrations: '/sfc_dashboard_hero_clean.png',
  'why-sfc': '/sfc_dashboard_hero_clean.png',
  compare: '/sfc_dashboard_hero_clean.png',
  'product-tour': '/sfc_dashboard_hero_clean.png',
  migration: '/sfc_dashboard_hero_clean.png',
};

/** Optional extra screenshots */
export const EXTRA_DEMO_IMAGES: { src: string; alt: string }[] = [
  { src: '/sfc_dashboard_hero_clean.png', alt: 'Storage Facility Creator dashboard overview' },
];

export const HERO_HEADLINE = 'Modern self-storage management software built for operators.';
export const HERO_SUBHEADLINE =
  'Run operations, billing, delinquency workflows, messaging, reporting, and integrations from one modern, focused platform — not an enterprise suite you have to grow into.';

export const PRICE_MONTHLY = 75;
/** Optional public facility website: online unit rentals and SEO-oriented marketing pages. */
export const ONLINE_RENTALS_ADDON_MONTHLY = 25;
export const PRICE_UNIT = 'per facility';
export const PRICE_LINE_SHORT = `$${PRICE_MONTHLY}/month per facility`;
export const PRICE_LINE_LONG = `$${PRICE_MONTHLY} per facility, per month — unlimited users, all features included`;
export const TRIAL_DAYS = 30;
export const TRIAL_LINE = '30-day trial + first month free';

export const MICROCOPY_POINTS = [
  'No onboarding fee',
  'Published per-facility pricing',
  'Unlimited users per facility',
  'QuickBooks integration',
] as const;

export const TRUST_STRIP_ITEMS = [
  'Per-facility published pricing',
  'Unlimited users per facility',
  'Stripe payments',
  'Twilio messaging',
  'QuickBooks integration',
  'E-sign ready',
  'Published legal/compliance pages',
  'Role-based access',
  `Optional: rent units online on your site (+$${ONLINE_RENTALS_ADDON_MONTHLY}/mo)`,
] as const;

export const NAV_LINKS = [
  { href: '/features', label: 'Features' },
  { href: '/pricing', label: 'Pricing' },
  { href: '/integrations', label: 'Integrations' },
  { href: '/why-sfc', label: 'Why SFC' },
  { href: '/security', label: 'Security' },
  { href: '/faq', label: 'FAQ' },
] as const;

export const A2P_COMPLIANCE_PARAGRAPH =
  'If a tenant provides a phone number and opts in, they may receive account-related SMS messages such as payment reminders and important updates. Message frequency varies. Message and data rates may apply. Reply STOP to opt out at any time. Reply HELP for help. Consent is not a condition of purchase.';

/**
 * Exact SMS consent checkbox text shown to tenants during onboarding/move-in.
 * Quoted verbatim on /sms-terms and reproduced on /sms-consent-demo for
 * carrier (A2P 10DLC) review. Keep in sync with the Flutter tenant creation
 * and public move-in screens.
 */
export const SMS_CONSENT_CHECKBOX_TEXT =
  'I consent to receive SMS notifications regarding my storage account. Message frequency varies. Message & data rates may apply. Reply STOP to opt out, HELP for help.';
