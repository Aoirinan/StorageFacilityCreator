import type { MetadataRoute } from 'next';
import { SITE_DOMAIN } from '@/config/site';

const routes = [
  '',
  '/features',
  '/pricing',
  '/security',
  '/faq',
  '/contact',
  '/integrations',
  '/compare',
  '/product-tour',
  '/why-sfc',
  '/migration',
  '/terms',
  '/privacy',
  '/cookies',
  '/acceptable-use',
  '/billing',
  '/sms-terms',
  '/esign-disclosure',
  '/subprocessors',
  '/dpa',
];

export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();
  return routes.map((path) => ({
    url: `${SITE_DOMAIN}${path}`,
    lastModified: now,
    changeFrequency: path === '' ? 'weekly' : 'monthly',
    priority: path === '' ? 1 : 0.7,
  }));
}
