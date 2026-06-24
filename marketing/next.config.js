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
  'subprocessors',
  'dpa',
];

const nextConfig = {
  images: {
    formats: ['image/avif', 'image/webp'],
  },
  async headers() {
    return LEGAL_ROUTES.map((route) => ({
      source: `/${route}`,
      headers: LEGAL_PAGE_HEADERS,
    }));
  },
};

module.exports = nextConfig;
