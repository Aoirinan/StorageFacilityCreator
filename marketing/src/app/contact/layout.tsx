import type { Metadata } from 'next';
import { PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Contact',
  description: 'Schedule a demo or contact Storage Facility Creator. We respond promptly.',
  openGraph: { images: [PAGE_OG_IMAGES.contact] },
  twitter: { images: [PAGE_OG_IMAGES.contact] },
};

export default function ContactLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
