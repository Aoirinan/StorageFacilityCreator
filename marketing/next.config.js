/** @type {import('next').NextConfig} */

/** Compliance/legal pages must propagate content updates quickly at the edge. */
const LEGAL_PAGE_HEADERS = [
  {
    key: 'Cache-Control',
    value: 'public, max-age=0, must-revalidate',
  },
  {
    key: 'CDN-Cache-Control',
    value: 'max-age=0, s-maxage=60, stale-while-revalidate=300',
  },
];

const LEGAL_ROUTES = [
  'privacy',
  'sms-terms',
  'terms',
  'cookies',
  'acceptable-use',
  'billing',
  'esign-disclosure',
  'dnr-policy',
  'subprocessors',
  'dpa',
  'sms-consent-demo',
];

/** Baseline browser hardening for every response (HSTS is added by Vercel). */
const SECURITY_HEADERS = [
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=()' },
];

const nextConfig = {
  images: {
    formats: ['image/avif', 'image/webp'],
  },
  async headers() {
    return [
      { source: '/(.*)', headers: SECURITY_HEADERS },
      ...LEGAL_ROUTES.map((route) => ({
        source: `/${route}`,
        headers: LEGAL_PAGE_HEADERS,
      })),
    ];
  },
};

module.exports = nextConfig;
