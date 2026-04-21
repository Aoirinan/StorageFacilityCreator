import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Contact Storage Facility Creator';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Contact',
    title: "Let's talk about your operation.",
    subtitle: 'Book a demo or start a 30-day trial. No onboarding fee.',
    accent: 'rose',
  });
}
