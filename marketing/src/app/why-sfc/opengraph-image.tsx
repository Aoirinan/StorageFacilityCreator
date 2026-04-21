import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Why Storage Facility Creator';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Why SFC',
    title: 'Built for operators. Not committees.',
    subtitle: 'Operator-first workflows for independent and multi-facility teams.',
    accent: 'blue',
  });
}
