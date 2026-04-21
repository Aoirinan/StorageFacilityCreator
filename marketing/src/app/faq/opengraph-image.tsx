import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator FAQ';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Frequently Asked',
    title: 'Buyer questions, answered.',
    subtitle: 'Pricing, setup, migration, messaging, security, and integrations.',
    accent: 'violet',
  });
}
