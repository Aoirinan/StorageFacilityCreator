import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Compare Storage Facility Creator';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Compare',
    title: 'SFC vs. SiteLink, storEDGE, and Easy Storage Solutions.',
    subtitle: 'A fair side-by-side on pricing model, deployment, and operator fit.',
    accent: 'amber',
  });
}
