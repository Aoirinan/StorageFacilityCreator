import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator product tour';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Product Tour',
    title: 'See it in action.',
    subtitle: 'A guided look at dashboards, tenant records, billing, autopay, and delinquency workflows.',
    accent: 'violet',
  });
}
