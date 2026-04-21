import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator features';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Features',
    title: 'Everything you need to run your facility.',
    subtitle: 'Tenant and unit management, billing, delinquency, messaging, reporting, and integrations.',
    accent: 'indigo',
  });
}
