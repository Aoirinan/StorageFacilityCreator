import type { Metadata } from 'next';
import { PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Contact',
  description:
    'Schedule a demo, ask about pricing, or get support for Storage Facility Creator. Our team responds promptly to every inquiry.',
  alternates: { canonical: '/contact' },
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
