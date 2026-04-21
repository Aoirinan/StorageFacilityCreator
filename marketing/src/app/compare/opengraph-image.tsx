import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Compare Storage Facility Creator';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Compare',
    title: 'SFC vs. the incumbents.',
    subtitle: 'How we stack up against Sitelink, storEDGE, and Easy Storage Solutions.',
    accent: 'amber',
  });
}
