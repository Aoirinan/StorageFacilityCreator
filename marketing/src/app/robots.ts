import type { MetadataRoute } from 'next';
import { SITE_DOMAIN } from '@/config/site';

export default function robots(): MetadataRoute.Robots {
  const hostname = new URL(SITE_DOMAIN).hostname;
  return {
    rules: {
      userAgent: '*',
      allow: '/',
    },
    sitemap: `${SITE_DOMAIN}/sitemap.xml`,
    host: hostname,
  };
}
