import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator — Self-storage management software';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Self-Storage SaaS',
    title: 'Stop running your facility on spreadsheets.',
    subtitle: 'Operations, billing, delinquency, messaging, and reporting — in one reliable platform.',
    accent: 'blue',
  });
}
