import { renderOgImage, OG_SIZE, OG_CONTENT_TYPE } from '@/lib/og';
import { PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

export const alt = 'Storage Facility Creator pricing';
export const size = OG_SIZE;
export const contentType = OG_CONTENT_TYPE;

export default function Image() {
  return renderOgImage({
    eyebrow: 'Pricing',
    title: `$${PRICE_MONTHLY}/month. Flat rate. No surprises.`,
    subtitle: `Unlimited facilities and users. All features included. ${TRIAL_LINE}.`,
    accent: 'amber',
  });
}
