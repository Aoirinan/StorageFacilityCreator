import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator security and compliance';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Security & Compliance',
    title: 'We never see or store your card numbers.',
    subtitle: 'Role-based access, secure cloud infrastructure, Stripe-handled payments, and published policy pages.',
    accent: 'emerald',
  });
}
