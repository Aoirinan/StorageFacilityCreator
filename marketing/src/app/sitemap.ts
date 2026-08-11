import type { MetadataRoute } from 'next';
import { SITE_DOMAIN } from '@/config/site';

const CORE_ROUTES = [
  '',
  '/features',
  '/pricing',
  '/compare',
  '/why-sfc',
  '/security',
  '/integrations',
  '/product-tour',
  '/faq',
  '/contact',
  '/migration',
];

const LEGAL_ROUTES = [
  '/terms',
  '/privacy',
  '/cookies',
  '/acceptable-use',
  '/billing',
  '/sms-terms',
  '/esign-disclosure',
  '/dnr-policy',
  '/subprocessors',
  '/dpa',
];

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    ...CORE_ROUTES.map((path) => ({
      url: `${SITE_DOMAIN}${path}`,
      changeFrequency: (path === '' ? 'weekly' : 'monthly') as MetadataRoute.Sitemap[number]['changeFrequency'],
      priority: path === '' ? 1 : 0.8,
    })),
    ...LEGAL_ROUTES.map((path) => ({
      url: `${SITE_DOMAIN}${path}`,
      changeFrequency: 'monthly' as MetadataRoute.Sitemap[number]['changeFrequency'],
      priority: 0.4,
    })),
  ];
}
