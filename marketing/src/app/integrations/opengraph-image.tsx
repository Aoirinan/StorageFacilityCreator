import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';

export const alt = 'Storage Facility Creator integrations';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Integrations',
    title: 'Built on infrastructure you already trust.',
    subtitle: 'Stripe, Twilio, SendGrid, QuickBooks, and Firebase — wired into daily operations.',
    accent: 'indigo',
  });
}
